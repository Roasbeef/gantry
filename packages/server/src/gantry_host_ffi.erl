%% Keep host arguments structured and redact the environment from errors.
-module(gantry_host_ffi).
-export([run/4, sync_path/1, write_stdout/1, read_stdin/0, run_attached/3, halt/1]).

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

%% Standard output is an io server whose encoding a launcher may set to
%% UTF-8, which would re-encode every byte above 127. Switch it to latin1
%% so put_chars passes bytes through unchanged, then write synchronously:
%% the io request returns only after the port has the bytes.
write_stdout(Bytes) ->
    try
        ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
        ok = file:write(standard_io, Bytes),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

%% Read standard input to end of file as raw bytes.
read_stdin() ->
    case io:setopts(standard_io, [binary, {encoding, latin1}]) of
        ok -> read_stdin(<<>>);
        _ -> {error, nil}
    end.

read_stdin(Acc) ->
    case file:read(standard_io, 65536) of
        {ok, Data} -> read_stdin(<<Acc/binary, (iolist_to_binary(Data))/binary>>);
        eof -> {ok, Acc};
        {error, _} -> {error, nil}
    end.

%% Run a child that inherits the VM's standard input, output, and error.
%% nouse_stdio moves the port's own pipe to descriptors 3 and 4, so the
%% child sees the caller's terminal or redirections on 0, 1, and 2.
run_attached(Program, Args, Env) ->
    case os:find_executable(chars(Program)) of
        false -> {error, <<Program/binary, " executable not found">>};
        Executable ->
            try
                Port = open_port({spawn_executable, Executable}, [
                    nouse_stdio, exit_status, binary, {args, lists:map(fun chars/1, Args)},
                    {env, [{chars(Key), chars(Value)} || {Key, Value} <- Env]}
                ]),
                attached(Port)
            catch
                error:badarg -> {error, <<"could not start ", Program/binary>>};
                error:system_limit -> {error, <<"host port limit reached">>}
            end
    end.

attached(Port) ->
    receive
        {Port, {exit_status, Status}} -> {ok, Status};
        {Port, _} -> attached(Port)
    end.

%% Flush buffered port output, then stop the VM with the given status.
halt(Status) ->
    erlang:halt(Status, [{flush, true}]).
