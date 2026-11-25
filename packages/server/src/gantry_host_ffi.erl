%% Keep host arguments structured and redact the environment from errors.
%% This module holds the one OS-process runner shared by the daemon, the CLI
%% and the worker's Docker adapter.
-module(gantry_host_ffi).
-export([run/4, capture/6, sync_path/1]).

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

%% Run a host tool and return its status with UTF-8 text, for callers that
%% only need a short diagnostic.
run(Program, Args, Env, Milliseconds) ->
    case capture(Program, Args, {inherit, Env}, combined, ?LOG_LIMIT, Milliseconds) of
        {ok, {command, {exited, Status}, Log, Completeness}} ->
            Marker = case Completeness of
                clipped -> <<"\n[output truncated]\n">>;
                complete -> <<>>
            end,
            {ok, {Status, <<(utf8(Log))/binary, Marker/binary>>}};
        {ok, {command, timed_out, _, _}} ->
            {error, <<"host command did not return after its wall deadline">>};
        {error, _} = Error -> Error
    end.

%% The one port runner. Environment is {inherit, Overrides} for the VM's
%% environment plus overrides, or {clear, Settings} for exactly the KEY=VALUE
%% settings through env(1). Stream selects whether stderr joins the capture.
%% At the wall deadline the child is killed by pid and the bytes captured so
%% far return as `timed_out`. No wrapper process enforces the deadline.
capture(Program, Args, Environment, Stream, Limit, Milliseconds) ->
    case {os:find_executable(chars(Program)), os:find_executable("env")} of
        {false, _} -> {error, <<Program/binary, " executable not found">>};
        {Executable, Env} ->
            Arguments = lists:map(fun chars/1, Args),
            case spawn_spec(Environment, Executable, Env, Arguments) of
                {error, _} = Error -> Error;
                {Spawn, Options} ->
                    Streams = case Stream of
                        combined -> [stderr_to_stdout];
                        stdout -> []
                    end,
                    try
                        Port = open_port({spawn_executable, Spawn},
                                         [binary, exit_status, use_stdio | Streams ++ Options]),
                        Deadline = erlang:monotonic_time(millisecond) + Milliseconds,
                        collect(Port, Deadline, Limit, [], false)
                    catch
                        error:badarg -> {error, <<"could not start ", Program/binary>>};
                        error:system_limit -> {error, <<"host port limit reached">>}
                    end
            end
    end.

spawn_spec({inherit, Overrides}, Executable, _Env, Arguments) ->
    {Executable, [{args, Arguments},
                  {env, [{chars(Key), chars(Value)} || {Key, Value} <- Overrides]}]};
spawn_spec({clear, _}, _Executable, false, _Arguments) ->
    {error, <<"env executable not found">>};
spawn_spec({clear, Settings}, Executable, Env, Arguments) ->
    %% env execs the tool, so the port's os pid is the tool's pid.
    {Env, [{args, ["-i" | lists:map(fun chars/1, Settings)] ++ [Executable | Arguments]}]}.

collect(Port, Deadline, Remaining, Parts, Truncated) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            Size = min(byte_size(Data), Remaining),
            <<Keep:Size/binary, _/binary>> = Data,
            Next = case Size of 0 -> Parts; _ -> [Keep | Parts] end,
            collect(Port, Deadline, Remaining - Size, Next, Truncated orelse Size < byte_size(Data));
        {Port, {exit_status, Status}} ->
            {ok, {command, {exited, Status}, bytes(Parts), completeness(Truncated)}}
    after Wait ->
        kill(Port),
        {ok, {command, timed_out, bytes(Parts), completeness(Truncated)}}
    end.

%% Kill the child by operating system pid, then release the port. Closing the
%% port alone would only close its pipes and leave the child running.
kill(Port) ->
    case {erlang:port_info(Port, os_pid), os:find_executable("kill")} of
        {{os_pid, Pid}, Kill} when Kill =/= false ->
            try
                Killer = open_port({spawn_executable, Kill},
                                   [exit_status, {args, ["-KILL", integer_to_list(Pid)]}]),
                receive {Killer, {exit_status, _}} -> ok after 2000 -> ok end
            catch error:_ -> ok
            end;
        _ -> ok
    end,
    try port_close(Port) catch error:badarg -> ok end,
    flush(Port).

flush(Port) ->
    receive {Port, _} -> flush(Port) after 0 -> ok end.

bytes(Parts) -> iolist_to_binary(lists:reverse(Parts)).

completeness(false) -> complete;
completeness(true) -> clipped.

chars(Binary) -> unicode:characters_to_list(Binary).

utf8(Binary) ->
    case unicode:characters_to_binary(Binary) of
        Valid when is_binary(Valid) -> Valid;
        {incomplete, Good, _Tail} -> <<Good/binary, " [incomplete UTF-8]">>;
        {error, Good, _Tail} -> <<Good/binary, " [non-UTF-8 output omitted]">>
    end.
