%% One Ra system per controller VM, with a fixed store and path. Elastic
%% executors never join Erlang distribution or vote on this state.
-module(gantry_khepri_ffi).
-export([boot/3, ready/0, read/0, confirm/1, confirm_quiet/0, remember_quiet/1, swap/2]).

-define(SYSTEM, gantry_queue_ra).
-define(STORE, gantry_queue).
-define(PATH, [queue_snapshot_v1]).
-define(TIMEOUT, 5000).
-define(QUIET, gantry_last_quiet_snapshot).

boot(DataDir, Seed, Empty) ->
    try
        Dir = filename:join(unicode:characters_to_list(DataDir), "queue-ra"),
        ok = filelib:ensure_dir(filename:join(Dir, "member")),
        {ok, _} = application:ensure_all_started(khepri),
        Config = (ra_system:default_config())#{
            name => ?SYSTEM, data_dir => Dir, wal_data_dir => Dir,
            names => ra_system:derive_names(?SYSTEM)},
        case ra_system:start(Config) of
            {ok, _} -> ok;
            {error, {already_started, _}} -> ok
        end,
        Marker = filename:join(Dir, "member"),
        ok = open_replica(Marker, Seed),
        case khepri:create(?STORE, ?PATH, Empty, #{timeout => ?TIMEOUT}) of
            ok -> open_hint();
            {error, {khepri, mismatching_node, _}} -> open_hint();
            Other -> failure(Other)
        end
    catch Class:Why -> failure({Class, Why})
    end.

%% The controller owns one local hint. The quorum remains the authority.
open_hint() ->
    case ets:whereis(?QUIET) of
        undefined -> ets:new(?QUIET, [named_table, public, {read_concurrency, true}]);
        _ -> ok
    end,
    {ok, nil}.

remember_quiet(Bytes) ->
    try ets:insert(?QUIET, {quiet, Bytes}) of
        true -> nil
    catch error:badarg -> nil
    end.

confirm_quiet() ->
    try
        case ets:lookup(?QUIET, quiet) of
            [{quiet, Expected} = Entry] ->
                case confirm(Expected) of
                    {ok, false} = Miss ->
                        true = ets:delete_object(?QUIET, Entry),
                        Miss;
                    Other -> Other
                end;
            [] -> {ok, false}
        end
    catch error:badarg -> {ok, false}
    end.

open_replica(Marker, Seed) ->
    Name = atom_to_binary(node(), utf8),
    case file:read_file(Marker) of
        {ok, Name} ->
            %% Khepri creates a new singleton if Ra cannot find the server.
            %% An established voter must refuse that fallback after disk loss.
            case ra_directory:uid_of(?SYSTEM, ?STORE) of
                undefined -> error(missing_durable_member);
                _ -> start_store()
            end;
        {ok, _} -> error(member_node_name_changed);
        {error, enoent} ->
            ok = start_store(),
            case Seed of
                <<>> -> ok;
                Name -> ok;
                _ when byte_size(Seed) =< 255 ->
                    %% The seed is a single operator-configured distribution
                    %% name supplied once during boot, never a wire field.
                    Remote = binary_to_atom(Seed, utf8),
                    ok = khepri_cluster:join(?STORE, Remote, ?TIMEOUT)
            end,
            {ok, Table} = ra_system:lookup_name(?SYSTEM, directory_rev),
            ok = dets:sync(Table),
            ok = file:write_file(Marker ++ ".tmp", Name, [sync]),
            file:rename(Marker ++ ".tmp", Marker);
        {error, Reason} -> error(Reason)
    end.

start_store() ->
    {ok, ?STORE} = khepri:start(?SYSTEM, ?STORE, ?TIMEOUT),
    ok.

%% A gateway can probe a majority without transferring the queue snapshot.
%% This OTP function is also available on voters running an older release.
ready() ->
    with_deadline(fun() ->
        try ra:consistent_query({?STORE, node()}, {erlang, is_tuple, []}, ?TIMEOUT) of
            {ok, true, _Leader} -> {ok, nil};
            {timeout, _} -> {error, <<"queue readiness timed out">>};
            Other -> failure(Other)
        catch Class:Why -> failure({Class, Why})
        end
    end).

read() ->
    with_deadline(fun fenced_read/0).

confirm(Expected) ->
    with_deadline(fun() -> confirm_snapshot(Expected) end).

%% Khepri's preliminary query and Ra leader redirects can exceed their own
%% timeouts. Bound the total request wait.
with_deadline(Read) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({snapshot, Read()}) end),
    receive
        {'DOWN', Ref, process, Pid, {snapshot, Reply}} -> Reply;
        {'DOWN', Ref, process, Pid, _} -> {error, <<"queue read failed">>}
    after ?TIMEOUT ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        {error, <<"queue quorum read timed out">>}
    end.

fenced_read() ->
    case khepri:fence(?STORE, ?TIMEOUT) of
        ok ->
            case khepri:get(?STORE, ?PATH, #{favor => low_latency, timeout => ?TIMEOUT}) of
                {ok, Bytes} when is_binary(Bytes), byte_size(Bytes) =< 4194304 -> {ok, Bytes};
                {ok, _} -> {error, <<"invalid durable queue snapshot">>};
                Other -> failure(Other)
            end;
        Other -> failure(Other)
    end.

%% Fetch the one-path tree after the leader confirms its authority with a
%% quorum. Use Khepri's accessor on the leader so an older Gantry voter can
%% answer during a rolling update. This adapter owns the dependency on
%% Khepri 0.19.3's tree interface.
confirm_snapshot(Expected) ->
    Path = ?PATH,
    try ra:consistent_query(
          {?STORE, node()}, {khepri_machine, get_tree, []}, ?TIMEOUT) of
        {ok, Tree, _Leader} ->
            case khepri_tree:find_matching_nodes(Tree, Path, #{props_to_return => [payload]}) of
                {ok, #{Path := #{data := Bytes}}}
                  when is_binary(Bytes), byte_size(Bytes) =< 4194304 ->
                    {ok, Bytes =:= Expected};
                _ -> {error, <<"invalid durable queue snapshot">>}
            end;
        {timeout, _} -> {error, <<"queue quorum read timed out">>};
        Other -> failure(Other)
    catch Class:Why -> failure({Class, Why})
    end.

swap(Expected, Proposed) ->
    try khepri:compare_and_swap(?STORE, ?PATH, Expected, Proposed, #{timeout => ?TIMEOUT}) of
        ok -> {ok, true};
        {error, {khepri, mismatching_node, _}} -> {ok, false};
        Other -> failure(Other)
    catch Class:Why -> failure({Class, Why})
    end.

failure(Reason) ->
    {error, iolist_to_binary(io_lib:format("queue storage failure ~P", [Reason, 5]))}.
