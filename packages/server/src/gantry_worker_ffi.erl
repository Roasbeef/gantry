%% Tar metadata and archive writing through erl_tar for the Gleam worker.
-module(gantry_worker_ffi).
-export([entries/1, archive_open/1, archive_add/3, archive_close/1]).

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
