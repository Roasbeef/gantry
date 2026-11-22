%% OS resources that OTP ports and erl_tar can provide to the Gleam worker.
-module(gantry_worker_ffi).
-export([lock/1, docker/5, entries/1, archive_open/1, archive_add/3, archive_close/1]).

lock(Path) ->
    case os:find_executable("flock") of
        false -> {error, <<"worker requires the flock executable">>};
        Flock ->
            Owner = self(),
            Ref = make_ref(),
            spawn(fun() -> hold_lock(Flock, Path, Owner, Ref) end),
            receive {Ref, Reply} -> Reply
            after 5000 -> {error, <<"worker lock did not respond">>}
            end
    end.

hold_lock(Flock, Path, Owner, Ref) ->
    Monitor = monitor(process, Owner),
    try
        Port = open_port({spawn_executable, Flock},
                         [binary, exit_status, use_stdio,
                          {args, ["-n", unicode:characters_to_list(Path), "/bin/sh", "-ec",
                                  "printf 'locked\\n'; exec cat >/dev/null"]}]),
        receive
            {Port, {data, <<"locked\n">>}} ->
                Owner ! {Ref, {ok, nil}},
                receive
                    {'DOWN', Monitor, process, Owner, _} -> port_close(Port);
                    {Port, {exit_status, _}} -> erlang:halt(1)
                end;
            {Port, {exit_status, _}} ->
                Owner ! {Ref, {error, <<"cannot acquire worker directory lock">>}};
            {'DOWN', Monitor, process, Owner, _} -> port_close(Port)
        end
    catch
        error:badarg -> Owner ! {Ref, {error, <<"cannot start worker directory lock">>}};
        error:system_limit -> Owner ! {Ref, {error, <<"worker lock port limit reached">>}}
    end.

docker(Args, Settings, Milliseconds, Limit, Stream) ->
    case {os:find_executable("docker"), os:find_executable("timeout"),
          os:find_executable("env")} of
        {false, _, _} -> {error, <<"Docker executable not found">>};
        {_, false, _} -> {error, <<"GNU timeout executable not found">>};
        {_, _, false} -> {error, <<"env executable not found">>};
        {Docker, Timeout, Env} ->
            Seconds = integer_to_list((Milliseconds + 999) div 1000) ++ "s",
            Arguments = ["-i" | lists:map(fun unicode:characters_to_list/1, Settings)] ++
                        [Timeout, "--kill-after=5s", Seconds, Docker |
                         lists:map(fun unicode:characters_to_list/1, Args)],
            Streams = case Stream of combined -> [stderr_to_stdout]; stdout -> [] end,
            try
                Port = open_port({spawn_executable, Env},
                                 [binary, exit_status, use_stdio, {args, Arguments} | Streams]),
                Deadline = erlang:monotonic_time(millisecond) + Milliseconds + 7000,
                collect(Port, Deadline, Limit, [], false)
            catch
                error:badarg -> {error, <<"could not start Docker">>};
                error:system_limit -> {error, <<"Docker port limit reached">>}
            end
    end.

collect(Port, Deadline, Remaining, Parts, Truncated) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            Size = min(byte_size(Data), Remaining),
            <<Keep:Size/binary, _/binary>> = Data,
            Next = case Size of 0 -> Parts; _ -> [Keep | Parts] end,
            collect(Port, Deadline, Remaining - Size, Next, Truncated orelse Size < byte_size(Data));
        {Port, {exit_status, Status}} ->
            {ok, {command, Status, iolist_to_binary(lists:reverse(Parts)), capture(Truncated)}}
    after Wait ->
        try port_close(Port) catch error:badarg -> ok end,
        {error, <<"Docker subprocess did not return after its wall deadline">>}
    end.

capture(false) -> complete;
capture(true) -> clipped.

entries(Bytes) ->
    try erl_tar:table({binary, Bytes}, [verbose]) of
        {ok, Headers} -> members(Headers, []);
        {error, _} -> {error, <<"invalid Git source archive">>}
    catch
        error:_ -> {error, <<"invalid Git source archive">>}
    end.

members([], Acc) -> {ok, lists:reverse(Acc)};
members([{Path, Type, _, _, _, _, _} | Rest], Acc)
  when Type =:= directory; Type =:= regular; Type =:= symlink ->
    case unicode:characters_to_binary(Path) of
        Name when is_binary(Name) -> members(Rest, [{Type, Name} | Acc]);
        _ -> {error, <<"invalid path in source archive">>}
    end;
members(_, _) -> {error, <<"unsupported entry in source archive">>}.

archive_open(Path) ->
    case erl_tar:open(unicode:characters_to_list(Path), [write]) of
        {ok, Archive} -> {ok, Archive};
        {error, _} -> {error, <<"cannot open dependency archive">>}
    end.

archive_add(Archive, Path, Bytes) ->
    Name = unicode:characters_to_list(Path),
    archive_result(erl_tar:add(Archive, Bytes, Name, [{mode, 8#644}, {mtime, 0}])).

archive_close(Archive) -> archive_result(erl_tar:close(Archive)).

archive_result(ok) -> {ok, nil};
archive_result({error, _}) -> {error, <<"cannot write dependency archive">>}.
