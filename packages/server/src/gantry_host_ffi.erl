%% Keep host arguments structured and redact the environment from errors.
%% This module holds the one OS-process runner shared by the daemon, the CLI
%% and the worker's Docker adapter.
-module(gantry_host_ffi).
-export([run/4, capture/6, sync_path/1, lock/1, write_stdout/1, read_stdin/0,
         run_attached/3, halt/1, open_service/4, service_pid/1, service_event/1,
         tcp_open/3, default_terminate/0]).

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

%% Kill the child's process group, then release the port. erl_child_setup
%% starts every port child in a new session, so its pid is also its group ID,
%% and the negative pid reaches the children it started, such as the helpers
%% git runs for a fetch or push. Closing the port alone would only close its
%% pipes and leave them running.
kill(Port) ->
    case {erlang:port_info(Port, os_pid), os:find_executable("kill")} of
        {{os_pid, Pid}, Kill} when Kill =/= false ->
            try
                Killer = open_port({spawn_executable, Kill},
                                   [exit_status, {args, ["-KILL", "--", "-" ++ integer_to_list(Pid)]}]),
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

%% Start a supervised child whose standard output and error arrive as port
%% messages. The child inherits a fresh session from erl_child_setup, so its
%% pid is also its process group ID.
open_service(Program, Args, Env, Directory) ->
    case os:find_executable(chars(Program)) of
        false -> {error, <<Program/binary, " executable not found">>};
        Executable ->
            try
                {ok, open_port({spawn_executable, Executable}, [
                    binary, exit_status, use_stdio, stderr_to_stdout, hide,
                    {args, lists:map(fun chars/1, Args)},
                    {env, [{chars(Key), chars(Value)} || {Key, Value} <- Env]},
                    {cd, chars(Directory)}
                ])}
            catch
                error:badarg -> {error, <<"could not start ", Program/binary>>};
                error:system_limit -> {error, <<"host port limit reached">>}
            end
    end.

service_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} -> {ok, Pid};
        undefined -> {error, nil}
    end.

%% Translate a port message into the Gleam ServiceEvent variants.
service_event({Port, {data, Data}}) when is_port(Port) -> {ok, {service_output, Data}};
service_event({Port, {exit_status, Status}}) when is_port(Port) -> {ok, {service_exited, Status}};
service_event(_) -> {error, nil}.

%% Report whether something accepts TCP connections at the address.
tcp_open(Host, Port, Milliseconds) ->
    case gen_tcp:connect(chars(Host), Port, [], Milliseconds) of
        {ok, Socket} -> gen_tcp:close(Socket), true;
        {error, _} -> false
    end.

%% Restore the operating system's action for SIGTERM, so the VM ends with
%% status 143 at once instead of running init:stop and exiting 0.
default_terminate() ->
    os:set_signal(sigterm, default),
    nil.

%% Hold an exclusive OS lock on Path for the life of the calling VM, through
%% util-linux flock. The CLI takes it for a profile, so a second command on
%% the same profile fails at once. Closing the port, or the owner dying,
%% releases it.
lock(Path) ->
    case os:find_executable("flock") of
        false -> {error, <<"requires the flock executable">>};
        Flock ->
            Owner = self(),
            Ref = make_ref(),
            spawn(fun() -> hold_lock(Flock, Path, Owner, Ref) end),
            receive {Ref, Reply} -> Reply
            after 5000 -> {error, <<"lock did not respond">>}
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
                Owner ! {Ref, {error, <<"cannot acquire the lock">>}};
            {'DOWN', Monitor, process, Owner, _} -> port_close(Port)
        end
    catch
        error:badarg -> Owner ! {Ref, {error, <<"cannot start the lock">>}};
        error:system_limit -> Owner ! {Ref, {error, <<"lock port limit reached">>}}
    end.
