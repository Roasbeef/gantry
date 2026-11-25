%% Primitive Khepri, Ra and ETS calls for one controller VM. Every policy
%% decision lives in Gleam (gantry/store.gleam): whether to bootstrap or
%% join, the node-name marker, the snapshot size limit and when a quiet
%% hint is trusted or dropped. This module only performs a call and reports
%% its outcome. Elastic executors never join Erlang distribution or vote on
%% this state.
%%
%% Errors are `{error, Fault}` where Fault is the Gleam representation of
%% gantry/fault.Unavailable (`{unavailable, Detail}`) or Internal
%% (`{internal, Detail}`).
-module(gantry_khepri_ffi).
-export([start_system/1, local_node/0, directory_known/0, start_store/0,
         join/1, sync_directory/0, create/1, ready/0, read/0, matches/1,
         swap/2, hint_open/0, hint_read/0, hint_remember/1, hint_forget/1]).

-define(SYSTEM, gantry_queue_ra).
-define(STORE, gantry_queue).
-define(PATH, [queue_snapshot_v1]).
-define(TIMEOUT, 5000).
%% The caller's wall bound. It exceeds ?TIMEOUT so that Khepri and Ra report
%% their own timeouts before this wrapper abandons the call.
-define(DEADLINE, 6000).
-define(QUIET, gantry_last_quiet_snapshot).

%% Start the Khepri application and this node's Ra system under Dir.
start_system(Directory) ->
    attempt(fun() ->
        Dir = unicode:characters_to_list(Directory),
        {ok, _} = application:ensure_all_started(khepri),
        Config = (ra_system:default_config())#{
            name => ?SYSTEM, data_dir => Dir, wal_data_dir => Dir,
            names => ra_system:derive_names(?SYSTEM)},
        case ra_system:start(Config) of
            {ok, _} -> {ok, nil};
            {error, {already_started, _}} -> {ok, nil}
        end
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

%% Initialize the snapshot unless some voter already did.
create(Empty) ->
    attempt(fun() ->
        case khepri:create(?STORE, ?PATH, Empty, #{timeout => ?TIMEOUT}) of
            ok -> {ok, nil};
            {error, {khepri, mismatching_node, _}} -> {ok, nil};
            Other -> failure(Other)
        end
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

%% Read the snapshot bytes after Khepri's fence.
read() ->
    with_deadline(fun() ->
        case khepri:fence(?STORE, ?TIMEOUT) of
            ok ->
                case khepri:get(?STORE, ?PATH, #{favor => low_latency, timeout => ?TIMEOUT}) of
                    {ok, Bytes} when is_binary(Bytes) -> {ok, Bytes};
                    {ok, _} -> corrupt(<<"invalid durable queue snapshot">>);
                    Other -> failure(Other)
                end;
            Other -> failure(Other)
        end
    end).

%% Ask the Ra leader, after it confirms its authority with a quorum, for the
%% tree, then compare the snapshot's hash here. The query names only
%% khepri_machine:get_tree/1, which every voter's Khepri exports, so a leader
%% still running an older Gantry build answers it. A Gantry function run on the
%% leader would crash an older leader's Ra server, because Ra applies the query
%% without a catch.
matches(Digest) ->
    with_deadline(fun() ->
        try ra:consistent_query(
              {?STORE, node()}, {khepri_machine, get_tree, []}, ?TIMEOUT) of
            {ok, Tree, _Leader} ->
                case khepri_tree:find_matching_nodes(Tree, ?PATH, #{props_to_return => [payload]}) of
                    {ok, #{?PATH := #{data := Bytes}}} when is_binary(Bytes) ->
                        case crypto:hash(sha256, Bytes) =:= Digest of
                            true -> {ok, accepted};
                            false -> {ok, snapshot_changed}
                        end;
                    _ -> corrupt(<<"invalid durable queue snapshot">>)
                end;
            {timeout, _} -> unavailable(<<"queue quorum read timed out">>);
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

%% Replace Expected with Proposed if the stored bytes are still Expected.
%% A deadline leaves the outcome unknown, because the command may commit
%% after the wrapper stops waiting.
swap(Expected, Proposed) ->
    with_deadline(fun() ->
        try khepri:compare_and_swap(?STORE, ?PATH, Expected, Proposed, #{timeout => ?TIMEOUT}) of
            ok -> {ok, accepted};
            {error, {khepri, mismatching_node, _}} -> {ok, snapshot_changed};
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

%% The controller owns one local hint, and the quorum remains the authority.
hint_open() ->
    case ets:whereis(?QUIET) of
        undefined -> ets:new(?QUIET, [named_table, public, {read_concurrency, true}]);
        _ -> ok
    end,
    nil.

%% The remembered digest, or an error when none is held or the table is gone.
hint_read() ->
    try ets:lookup(?QUIET, quiet) of
        [{quiet, Digest}] -> {ok, Digest};
        [] -> {error, nil}
    catch error:badarg -> {error, nil}
    end.

hint_remember(Digest) ->
    try ets:insert(?QUIET, {quiet, Digest}) of
        true -> nil
    catch error:badarg -> nil
    end.

%% Drop the hint only if it still holds Digest, so a concurrent remember of
%% a newer snapshot survives.
hint_forget(Digest) ->
    try ets:delete_object(?QUIET, {quiet, Digest}) of
        true -> nil
    catch error:badarg -> nil
    end.

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

corrupt(Detail) -> {error, {internal, Detail}}.
