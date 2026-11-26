%% Primitive Khepri and Ra calls for one controller VM. Every policy decision
%% lives in Gleam: whether to bootstrap or join, the node-name marker, which
%% keys an operation reads, what a decision relied on and what it writes
%% (gantry_core/layout, gantry/store). This module performs one read, one
%% atomic compare-and-write, or one lock, and reports the outcome. Elastic
%% executors never join Erlang distribution or vote on this state.
%%
%% A key is a list of binaries below the `queue` root. Reads return
%% `{ok, none | {some, Bytes}}` and `{error, Detail}` where the detail is
%% text, which the caller maps to a fault. Other calls return
%% `{error, Fault}` where Fault is the Gleam representation of
%% gantry/fault.Unavailable (`{unavailable, Detail}`) or Internal
%% (`{internal, Detail}`).
%%
%% Mixed layouts cannot share a cluster. The leader runs `check_query/2` for
%% every follower's empty poll, so every voter must run this release.
-module(gantry_khepri_ffi).
-export([start_system/1, local_node/0, directory_known/0, start_store/0,
         join/1, sync_directory/0, ready/0, fence/0, get/1, many/1, list/1,
         commit/2, legacy/0, seal_legacy/1, gated/2, check_query/2]).

-define(SYSTEM, gantry_queue_ra).
-define(STORE, gantry_queue).
-define(LEGACY, [queue_snapshot_v1]).
-define(ROOT, <<"queue">>).
%% Khepri's `#if_path_matches{regex = any}` condition, which matches a node
%% and every node below it. The header's record has these two fields.
-define(BELOW, {if_path_matches, any, undefined}).
-define(GATE_WAIT, 15000).
-define(TIMEOUT, 5000).
%% The caller's wall bound. It exceeds ?TIMEOUT so that Khepri and Ra report
%% their own timeouts before this wrapper abandons the call.
-define(DEADLINE, 6000).

%% Start the Khepri application and this node's Ra system under Dir.
start_system(Directory) ->
    attempt(fun() ->
        Dir = unicode:characters_to_list(Directory),
        {ok, _} = application:ensure_all_started(khepri),
        Config = (ra_system:default_config())#{
            name => ?SYSTEM, data_dir => Dir, wal_data_dir => Dir,
            names => ra_system:derive_names(?SYSTEM)},
        case ra_system:start(Config) of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
        [start_gate(Name) || Name <- gates()],
        {ok, nil}
    end).

local_node() -> atom_to_binary(node(), utf8).

%% Whether Ra knows this store's server on disk. Khepri creates a new
%% singleton if Ra cannot find an established voter, so the caller must
%% refuse to start one.
directory_known() ->
    ra_directory:uid_of(?SYSTEM, ?STORE) =/= undefined.

start_store() ->
    attempt(fun() ->
        case khepri:start(?SYSTEM, ?STORE, ?TIMEOUT) of
            {ok, ?STORE} -> {ok, nil};
            Other -> failure(Other)
        end
    end).

%% Join the cluster of the named seed node. The seed is an operator
%% configured distribution name supplied once at boot, never a wire field,
%% so creating its atom is bounded.
join(Seed) ->
    attempt(fun() ->
        case khepri_cluster:join(?STORE, binary_to_atom(Seed, utf8), ?TIMEOUT) of
            ok -> {ok, nil};
            Other -> failure(Other)
        end
    end).

%% Flush Ra's directory so a restart recognizes the member that just joined.
sync_directory() ->
    attempt(fun() ->
        {ok, Table} = ra_system:lookup_name(?SYSTEM, directory_rev),
        ok = dets:sync(Table),
        {ok, nil}
    end).

%% A gateway can probe a majority without transferring the queue snapshot.
%% This OTP function is also available on voters running an older release.
ready() ->
    with_deadline(fun() ->
        try ra:consistent_query({?STORE, node()}, {erlang, is_tuple, []}, ?TIMEOUT) of
            {ok, true, _Leader} -> {ok, nil};
            {timeout, _} -> unavailable(<<"queue readiness timed out">>);
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

%% Read one key from the local replica. A replica that lags returns an older
%% value, which the commit's expectation refuses, so the read needs no fence.
get(Key) ->
    read_call(fun() -> one(path(Key)) end).

%% Read several keys from the local replica, in the order asked.
many(Keys) ->
    read_call(fun() -> many_values(Keys, []) end).

%% Read each key in turn, stopping at the first read that fails.
many_values([], Values) -> {ok, lists:reverse(Values)};
many_values([Key | Rest], Values) ->
    case one(path(Key)) of
        {ok, Value} -> many_values(Rest, [Value | Values]);
        {error, _} = Error -> Error
    end.

%% Wait until this replica has applied everything committed so far, so a read
%% that follows sees the effects of operations that finished on any voter.
fence() ->
    with_deadline(fun() ->
        try khepri:fence(?STORE, ?TIMEOUT) of
            ok -> {ok, nil};
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

%% Every key below Prefix that holds a value, with that value.
list(Prefix) ->
    read_call(fun() ->
        case khepri:get_many(?STORE, path(Prefix) ++ [?BELOW], #{favor => low_latency, timeout => ?TIMEOUT}) of
            {ok, Found} ->
                {ok, [{unroot(Path), Value} || {Path, Value} <- maps:to_list(Found), is_binary(Value)]};
            Other -> {error, detail(Other)}
        end
    end).

one(Path) ->
    case khepri:get(?STORE, Path, #{favor => low_latency, timeout => ?TIMEOUT}) of
        {ok, Value} when is_binary(Value) -> {ok, {some, Value}};
        {ok, _} -> {ok, none};
        {error, {khepri, node_not_found, _}} -> {ok, none};
        Other -> {error, detail(Other)}
    end.

%% Apply Writes if every expectation still holds, as one atomic step. A write
%% is `{put, Key, Bytes}` or `{delete, Key}`. An expectation is
%% `{is, Key, none | {some, Bytes}}` or `{keys, Prefix, Keys}`. With no writes
%% the leader confirms the expectations through a quorum read instead, so an
%% empty poll appends nothing to the log. A deadline leaves the outcome
%% unknown, because the command may commit after the wrapper stops waiting.
commit(Expects, Writes) ->
    Es = [rooted_expect(E) || E <- Expects],
    case Writes of
        [] -> confirm(Es);
        _ -> write(Es, [rooted_write(W) || W <- Writes])
    end.

confirm([]) -> {ok, accepted};
confirm(Es) ->
    with_deadline(fun() ->
        try ra:consistent_query({?STORE, node()}, {?MODULE, check_query, [Es]}, ?TIMEOUT) of
            {ok, {ok, true}, _Leader} -> {ok, accepted};
            {ok, {ok, false}, _Leader} -> {ok, stale};
            {ok, {error, Why}, _Leader} -> failure(Why);
            {timeout, _} -> unavailable(<<"queue quorum read timed out">>);
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

write(Es, Ws) ->
    with_deadline(fun() ->
        try khepri:transaction(?STORE, fun() ->
                case holds(Es) of
                    true -> apply_all(Ws), accepted;
                    false -> stale
                end
            end, rw, #{timeout => ?TIMEOUT}) of
            {ok, Outcome} -> {ok, Outcome};
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

%% The transaction body. It runs on every member and from the log, so it
%% calls only Khepri's transaction API and pure list functions.
holds([]) -> true;
holds([{is, Key, Want} | Rest]) ->
    Have = case khepri_tx:get(Key) of
               {ok, Value} when is_binary(Value) -> {some, Value};
               _ -> none
           end,
    Have =:= Want andalso holds(Rest);
holds([{keys, Prefix, Want} | Rest]) ->
    Have = case khepri_tx:get_many(Prefix ++ [?BELOW]) of
               {ok, Found} -> lists:sort([Path || {Path, Value} <- maps:to_list(Found), is_binary(Value)]);
               _ -> []
           end,
    Have =:= lists:sort(Want) andalso holds(Rest).

apply_all([]) -> ok;
apply_all([{put, Key, Bytes} | Rest]) -> ok = khepri_tx:put(Key, Bytes), apply_all(Rest);
apply_all([{delete, Key} | Rest]) -> ok = khepri_tx:delete(Key), apply_all(Rest).

%% Run on the Ra leader through `ra:consistent_query/3`, with the machine
%% state appended as the last argument. Ra applies a query without a catch, so
%% a crash here would stop the leader's server. Every failure is returned.
check_query(Es, MachineState) ->
    try
        Tree = khepri_machine:get_tree(MachineState),
        {ok, lists:all(fun(E) -> holds_in(Tree, E) end, Es)}
    catch Class:Why -> {error, {Class, Why}}
    end.

holds_in(Tree, {is, Key, Want}) ->
    Have = case khepri_tree:find_matching_nodes(Tree, khepri_path:compile(Key), #{props_to_return => [payload]}) of
               {ok, #{Key := #{data := Value}}} when is_binary(Value) -> {some, Value};
               _ -> none
           end,
    Have =:= Want;
holds_in(Tree, {keys, Prefix, Want}) ->
    Pattern = khepri_path:compile(Prefix ++ [?BELOW]),
    Have = case khepri_tree:find_matching_nodes(Tree, Pattern, #{props_to_return => [payload]}) of
               {ok, Found} -> lists:sort([Path || {Path, #{data := Value}} <- maps:to_list(Found), is_binary(Value)]);
               _ -> []
           end,
    Have =:= lists:sort(Want).

path(Key) -> [?ROOT | Key].

unroot([?ROOT | Key]) -> Key.

rooted_expect({is, Key, Want}) -> {is, path(Key), Want};
rooted_expect({keys, Prefix, Keys}) -> {keys, path(Prefix), [path(K) || K <- Keys]}.

rooted_write({put, Key, Bytes}) -> {put, path(Key), Bytes};
rooted_write({delete, Key}) -> {delete, path(Key)}.

%% The queue snapshot an earlier release stored, if any. Booting imports it.
legacy() ->
    attempt(fun() ->
        case khepri:get(?STORE, ?LEGACY, #{favor => consistency, timeout => ?TIMEOUT}) of
            {ok, Bytes} when is_binary(Bytes) -> {ok, {some, Bytes}};
            {ok, _} -> {ok, none};
            {error, {khepri, node_not_found, _}} -> {ok, none};
            Other -> failure(Other)
        end
    end).

%% Replace the old snapshot with bytes an earlier release cannot decode, so
%% that release refuses the store instead of creating an empty queue beside it.
seal_legacy(Bytes) ->
    attempt(fun() ->
        case khepri:put(?STORE, ?LEGACY, Bytes, #{timeout => ?TIMEOUT}) of
            ok -> {ok, nil};
            Other -> failure(Other)
        end
    end).

%% Run Fun while holding the named lock, so one controller's own operations
%% that write the same counter do not lose to each other. A lock is only an
%% ordering, never a decision: the commit's expectations still refuse a
%% competing controller. The lock is released if Fun crashes or this process
%% dies.
gated(Name, Fun) ->
    Gate = gate_name(Name),
    Ref = make_ref(),
    Gate ! {acquire, self(), Ref},
    receive
        {granted, Ref} ->
            try Fun()
            after Gate ! {release, Ref}
            end
    after ?GATE_WAIT ->
        Gate ! {release, Ref},
        receive {granted, Ref} -> Gate ! {release, Ref} after 0 -> ok end,
        unavailable(<<"queue is busy">>)
    end.

gates() -> [gantry_gate_admission, gantry_gate_claiming, gantry_gate_finishing].

gate_name(<<"admission">>) -> gantry_gate_admission;
gate_name(<<"claiming">>) -> gantry_gate_claiming;
gate_name(<<"finishing">>) -> gantry_gate_finishing.

start_gate(Name) ->
    case whereis(Name) of
        undefined ->
            Pid = spawn(fun() -> gate_loop(none, queue:new()) end),
            true = register(Name, Pid);
        _ -> ok
    end.

%% A mutex with a first-come queue. It monitors the holder, so a crash
%% releases it.
gate_loop(Holder, Waiting) ->
    receive
        {acquire, Pid, Ref} ->
            case Holder of
                none -> gate_loop(grant(Pid, Ref), Waiting);
                _ -> gate_loop(Holder, queue:in({Pid, Ref}, Waiting))
            end;
        {release, Ref} ->
            case Holder of
                {Ref, Mon} -> erlang:demonitor(Mon, [flush]), gate_next(Waiting);
                _ -> gate_loop(Holder, queue:filter(fun({_, R}) -> R =/= Ref end, Waiting))
            end;
        {'DOWN', Mon, process, _, _} ->
            case Holder of
                {_, Mon} -> gate_next(Waiting);
                _ -> gate_loop(Holder, Waiting)
            end
    end.

gate_next(Waiting) ->
    case queue:out(Waiting) of
        {{value, {Pid, Ref}}, Rest} -> gate_loop(grant(Pid, Ref), Rest);
        {empty, Rest} -> gate_loop(none, Rest)
    end.

grant(Pid, Ref) ->
    Pid ! {granted, Ref},
    {Ref, erlang:monitor(process, Pid)}.

read_call(Fun) ->
    case with_deadline(Fun) of
        {error, {unavailable, Detail}} -> {error, Detail};
        Other -> Other
    end.

detail(Reason) -> iolist_to_binary(io_lib:format("queue read failure ~P", [Reason, 5])).

%% Khepri's preliminary query and Ra leader redirects can exceed their own
%% timeouts. Bound the total request wait.
with_deadline(Call) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({done, Call()}) end),
    receive
        {'DOWN', Ref, process, Pid, {done, Reply}} -> Reply;
        {'DOWN', Ref, process, Pid, _} -> unavailable(<<"queue call failed">>)
    after ?DEADLINE ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        unavailable(<<"queue call timed out">>)
    end.

attempt(Call) ->
    try Call()
    catch Class:Why -> failure({Class, Why})
    end.

failure(Reason) ->
    unavailable(iolist_to_binary(io_lib:format("queue storage failure ~P", [Reason, 5]))).

unavailable(Detail) -> {error, {unavailable, Detail}}.

