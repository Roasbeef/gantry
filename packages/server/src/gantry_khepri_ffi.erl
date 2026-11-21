%% One Ra system per controller VM, with a fixed store and path. Elastic
%% executors never join Erlang distribution or vote on this state.
-module(gantry_khepri_ffi).
-export([boot/3, read/0, swap/2]).

-define(SYSTEM, gantry_queue_ra).
-define(STORE, gantry_queue).
-define(PATH, [queue_snapshot_v1]).
-define(TIMEOUT, 5000).

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
            ok -> {ok, nil};
            {error, {khepri, mismatching_node, _}} -> {ok, nil};
            Other -> failure(Other)
        end
    catch Class:Why -> failure({Class, Why})
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

%% Khepri 0.19.3's consistency fence can exceed its own timeout without a
%% leader. A monitored helper keeps that wait out of the request process.
read() ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({snapshot, fenced_read()}) end),
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

swap(Expected, Proposed) ->
    try khepri:compare_and_swap(?STORE, ?PATH, Expected, Proposed, #{timeout => ?TIMEOUT}) of
        ok -> {ok, true};
        {error, {khepri, mismatching_node, _}} -> {ok, false};
        Other -> failure(Other)
    catch Class:Why -> failure({Class, Why})
    end.

failure(Reason) ->
    {error, iolist_to_binary(io_lib:format("queue storage failure ~P", [Reason, 5]))}.
