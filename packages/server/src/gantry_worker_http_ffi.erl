%% One Gun connection per controller origin, reused across exchanges.
%%
%% The connection belongs to the calling process, which is the worker loop:
%% Gun delivers its messages to the process that opened it, and a Gun
%% connection is linked to that process so it ends when the loop ends. The
%% pool is the loop's process dictionary because the loop is the only
%% caller and the connections must not outlive it. A reused connection that
%% proves dead before any response byte arrives is replaced once, which is
%% safe because every worker request is replay-safe by the controller's
%% design. Timeouts come from Gleam: a connect timeout, a bound for the
%% first response byte, and an idle bound that restarts at every chunk.
-module(gantry_worker_http_ffi).
-export([dispatch/2]).

dispatch({Scheme, Host, Port, Method, Target, Headers, Body, {Connect, FirstByte, Idle}}, Limit) ->
    Origin = {Scheme, Host, Port},
    Request = {Method, Target, Headers, Body},
    Bounds = {FirstByte, Idle},
    try
        case cached(Origin) of
            {ok, Pid} ->
                case exchange(Pid, Request, Bounds, Limit) of
                    {retry, _} ->
                        drop(Origin, Pid),
                        fresh(Origin, Connect, Request, Bounds, Limit);
                    Reply -> settle(Origin, Pid, Reply)
                end;
            none -> fresh(Origin, Connect, Request, Bounds, Limit)
        end
    catch
        error:_ -> {error, unavailable};
        exit:_ -> {error, unavailable}
    end.

fresh(Origin, Connect, Request, Bounds, Limit) ->
    case connect(Origin, Connect) of
        {ok, Pid} ->
            put({gantry_gun, Origin}, Pid),
            case exchange(Pid, Request, Bounds, Limit) of
                {retry, _} -> drop(Origin, Pid), {error, unavailable};
                Reply -> settle(Origin, Pid, Reply)
            end;
        error -> {error, unavailable}
    end.

%% Keep the connection after a complete response. Any failure leaves unread
%% bytes or a dead socket, so the connection goes with it.
settle(_Origin, _Pid, {ok, _} = Reply) -> Reply;
settle(Origin, Pid, {error, _} = Reply) -> drop(Origin, Pid), Reply.

cached(Origin) ->
    case get({gantry_gun, Origin}) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) andalso not went_down(Pid) of
                true -> {ok, Pid};
                false -> drop(Origin, Pid), none
            end;
        _ -> none
    end.

%% Gun reports a closed socket as a message before the process exits.
went_down(Pid) ->
    receive
        Message when element(1, Message) =:= gun_down, element(2, Message) =:= Pid -> true;
        Message when element(1, Message) =:= gun_error, element(2, Message) =:= Pid -> true
    after 0 -> false
    end.

drop(Origin, Pid) ->
    erase({gantry_gun, Origin}),
    %% Drain the closed connection's messages before the next exchange.
    try gun:close(Pid) catch _:_ -> ok end,
    try gun:flush(Pid) catch _:_ -> ok end,
    ok.

connect({Scheme, Host, Port}, Connect) ->
    Name = binary_to_list(Host),
    Address = case inet:parse_strict_address(Name) of
        {ok, Ip} -> Ip;
        {error, einval} -> Name
    end,
    Opts = #{
        retry => 0, protocols => [http],
        connect_timeout => Connect,
        domain_lookup_timeout => Connect,
        tls_handshake_timeout => Connect,
        http_opts => #{keepalive => infinity}
    },
    case gun:open(Address, Port, transport_opts(Scheme, Name, Opts)) of
        {ok, Pid} ->
            case gun:await_up(Pid, Connect) of
                {ok, http} -> {ok, Pid};
                _ -> try gun:close(Pid) catch _:_ -> ok end, error
            end;
        {error, _} -> error
    end.

transport_opts(http, _, Opts) ->
    Opts#{transport => tcp};
transport_opts(https, Name, Opts) ->
    Opts#{transport => tls, tls_opts => [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Name},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ]}.

exchange(Pid, {Method, Target, Headers, Body}, {FirstByte, Idle}, Limit) ->
    Stream = gun:request(Pid, Method, Target, Headers, Body, #{flow => 1}),
    response(Pid, Stream, FirstByte, Idle, Limit).

response(Pid, Stream, FirstByte, Idle, Limit) ->
    case gun:await(Pid, Stream, FirstByte) of
        {response, _, Status, _} when Status >= 500 ->
            %% Fail over as soon as the server reports failure.
            {error, unavailable};
        {response, fin, Status, _} ->
            {ok, {Status, <<>>}};
        {response, nofin, Status, _} ->
            read_body(Pid, Stream, Idle, Status, Limit, <<>>);
        {inform, _, _} ->
            response(Pid, Stream, FirstByte, Idle, Limit);
        {error, timeout} -> {error, unavailable};
        {error, Reason} -> {retry, Reason};
        _ -> {error, unavailable}
    end.

%% Each chunk restarts the idle bound, so a slow link that keeps delivering
%% completes however large the body is. The byte limit bounds memory.
read_body(Pid, Stream, Idle, Status, Limit, Body) ->
    case gun:await(Pid, Stream, Idle) of
        {data, _, Data} when byte_size(Body) + byte_size(Data) > Limit ->
            {error, too_large};
        {data, fin, Data} ->
            {ok, {Status, <<Body/binary, Data/binary>>}};
        {data, nofin, Data} ->
            %% Append before granting another credit so received chunks are
            %% released, even when the server sends very small fragments.
            NextBody = <<Body/binary, Data/binary>>,
            gun:update_flow(Pid, Stream, 1),
            read_body(Pid, Stream, Idle, Status, Limit, NextBody);
        {trailers, _} ->
            {ok, {Status, Body}};
        _ -> {error, unavailable}
    end.
