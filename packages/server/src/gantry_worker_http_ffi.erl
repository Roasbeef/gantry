%% Each dispatch owns a single HTTP stream with a bounded response and deadline.
-module(gantry_worker_http_ffi).
-export([dispatch/2]).

-define(REQUEST_TIMEOUT, 20000).

dispatch({controller_request, Scheme, Host, Port, Method, Target, Headers, Body}, Limit) ->
    Deadline = erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT,
    try
        Name = binary_to_list(Host),
        Address = case inet:parse_strict_address(Name) of
            {ok, Ip} -> Ip;
            {error, einval} -> Name
        end,
        Opts = #{
            retry => 0, protocols => [http],
            connect_timeout => ?REQUEST_TIMEOUT,
            domain_lookup_timeout => ?REQUEST_TIMEOUT,
            tls_handshake_timeout => ?REQUEST_TIMEOUT
        },
        case gun:open(Address, Port, transport_opts(Scheme, Name, Opts)) of
            {ok, Pid} ->
                try
                    case gun:await_up(Pid, remaining(Deadline)) of
                        {ok, http} ->
                            Stream = gun:request(Pid, Method, Target, Headers, Body, #{flow => 1}),
                            response(Pid, Stream, Deadline, Limit);
                        _ -> {error, unavailable}
                    end
                after
                    close(Pid)
                end;
            {error, _} -> {error, unavailable}
        end
    catch
        error:_ -> {error, unavailable};
        exit:_ -> {error, unavailable}
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

response(Pid, Stream, Deadline, Limit) ->
    case next(Pid, Stream, Deadline) of
        {response, _, Status, _} when Status >= 500 ->
            %% Fail over as soon as the server reports failure.
            {error, unavailable};
        {response, fin, Status, _} ->
            {ok, {Status, <<>>}};
        {response, nofin, Status, _} ->
            read_body(Pid, Stream, Deadline, Status, Limit, <<>>);
        {inform, _, _} ->
            response(Pid, Stream, Deadline, Limit);
        _ -> {error, unavailable}
    end.

read_body(Pid, Stream, Deadline, Status, Limit, Body) ->
    case next(Pid, Stream, Deadline) of
        {data, _, Data} when byte_size(Body) + byte_size(Data) > Limit ->
            {error, too_large};
        {data, fin, Data} ->
            {ok, {Status, <<Body/binary, Data/binary>>}};
        {data, nofin, Data} ->
            %% Append before granting another credit so received chunks are
            %% released, even when the server sends very small fragments.
            NextBody = <<Body/binary, Data/binary>>,
            gun:update_flow(Pid, Stream, 1),
            read_body(Pid, Stream, Deadline, Status, Limit, NextBody);
        {trailers, _} ->
            {ok, {Status, Body}};
        _ -> {error, unavailable}
    end.

next(Pid, Stream, Deadline) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        Timeout -> gun:await(Pid, Stream, Timeout)
    end.

remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

close(Pid) ->
    %% Drain the closed connection's messages before trying another controller.
    gun:close(Pid),
    gun:flush(Pid).
