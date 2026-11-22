%% Keep host arguments structured and redact the environment from errors.
-module(gantry_host_ffi).
-export([run/4, sync_path/1]).

-define(LOG_LIMIT, 16384).

%% Persist file bytes before rename and the containing directory afterwards.
sync_path(Path) ->
    Name = chars(Path),
    Options = case filelib:is_dir(Name) of
        true -> [read, raw, directory];
        false -> [read, raw, binary]
    end,
    case file:open(Name, Options) of
        {ok, Handle} ->
            Reply = file:sync(Handle),
            _ = file:close(Handle),
            sync_result(Reply);
        Error -> sync_result(Error)
    end.

sync_result(ok) -> {ok, nil};
sync_result({error, _}) -> {error, <<"cannot sync durable file or directory">>}.

run(Program, Args, Env, Milliseconds) ->
    case {os:find_executable(chars(Program)), os:find_executable("timeout")} of
        {false, _} -> {error, <<Program/binary, " executable not found">>};
        {_, false} -> {error, <<"GNU timeout executable not found">>};
        {Executable, Timeout} ->
            Seconds = integer_to_list((Milliseconds + 999) div 1000) ++ "s",
            Arguments = ["--kill-after=5s", Seconds, Executable | lists:map(fun chars/1, Args)],
            Overrides = [{chars(Key), chars(Value)} || {Key, Value} <- Env],
            try
                Port = open_port({spawn_executable, Timeout}, [
                    binary, exit_status, stderr_to_stdout, use_stdio, {args, Arguments},
                    {env, Overrides}
                ]),
                Deadline = erlang:monotonic_time(millisecond) + Milliseconds + 7000,
                collect(Port, Deadline, <<>>, false)
            catch
                error:badarg -> {error, <<"could not start ", Program/binary>>};
                error:system_limit -> {error, <<"host port limit reached">>}
            end
    end.

collect(Port, Deadline, Log, Truncated) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            Size = min(byte_size(Data), ?LOG_LIMIT - byte_size(Log)),
            <<Keep:Size/binary, _/binary>> = Data,
            collect(Port, Deadline, <<Log/binary, Keep/binary>>, Truncated orelse Size < byte_size(Data));
        {Port, {exit_status, Status}} ->
            Marker = case Truncated of
                true -> <<"\n[output truncated]\n">>;
                false -> <<>>
            end,
            {ok, {Status, <<(utf8(Log))/binary, Marker/binary>>}}
    after Remaining ->
        try port_close(Port) catch error:badarg -> ok end,
        {error, <<"host command did not return after its wall deadline">>}
    end.

chars(Binary) -> unicode:characters_to_list(Binary).

utf8(Binary) ->
    case unicode:characters_to_binary(Binary) of
        Valid when is_binary(Valid) -> Valid;
        {incomplete, Good, _Tail} -> <<Good/binary, " [incomplete UTF-8]">>;
        {error, Good, _Tail} -> <<Good/binary, " [non-UTF-8 output omitted]">>
    end.
