%% OS resources that OTP ports and erl_tar can provide to the Gleam worker.
-module(gantry_worker_ffi).
-export([lock/1, entries/1, archive_open/1, archive_add/3, archive_close/1]).

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
