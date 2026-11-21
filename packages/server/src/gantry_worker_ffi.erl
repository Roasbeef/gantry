%% Resolve the release's packaged host adapter. Packet boundaries preserve
%% arbitrary JSON content without treating build output as an Erlang message.
-module(gantry_worker_ffi).
-export([run/1]).

run(Check) ->
    case {code:priv_dir(gantry), os:find_executable("python3")} of
        {{error, _}, _} -> {error, <<"cannot locate Gantry priv directory">>};
        {_, false} -> {error, <<"worker requires Python 3">>};
        {Priv, Python} ->
            Script = filename:join(Priv, "worker_service.py"),
            Port = open_port({spawn_executable, Python},
                             [binary, {packet, 4}, exit_status, use_stdio,
                              {args, ["-B", Script, "--port"]}]),
            serve(Port, Check)
    end.

serve(Port, Check) ->
    receive
        {Port, {data, <<Kind, Payload/binary>>}} when Kind =:= $A; Kind =:= $C ->
            Type = case Kind of $A -> assignment; $C -> completion end,
            Reply = case Check(Type, Payload) of
                        {ok, Json} -> <<1, Json/binary>>;
                        {error, nil} -> <<0>>
                    end,
            port_command(Port, Reply),
            serve(Port, Check);
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, _}} -> {error, <<"worker stopped">>}
    end.
