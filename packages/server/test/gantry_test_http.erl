%% A small HTTP/1.1 server for worker transport tests. It keeps connections
%% alive, counts accepted connections, and can answer in paced chunks.
-module(gantry_test_http).
-export([start/1, port/1, accepted/1, stop/1, ensure_gun/0]).

%% Script is {body, Bytes} for a fixed reply, {chunks, Count, DelayMs} for a
%% chunked reply paced by DelayMs, or {close_after, Bytes} to answer once and
%% close the connection.
start(Script) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listener),
    Counter = counters:new(1, []),
    Acceptor = spawn_link(fun() -> accept(Listener, Script, Counter) end),
    {Port, Listener, Counter, Acceptor}.

ensure_gun() ->
    {ok, _} = application:ensure_all_started(gun),
    nil.

port({Port, _, _, _}) -> Port.

accepted({_, _, Counter, _}) -> counters:get(Counter, 1).

stop({_, Listener, _, Acceptor}) ->
    unlink(Acceptor),
    exit(Acceptor, kill),
    gen_tcp:close(Listener).

accept(Listener, Script, Counter) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            counters:add(Counter, 1, 1),
            Handler = spawn(fun() -> receive go -> serve(Socket, Script, <<>>) end end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! go,
            accept(Listener, Script, Counter);
        {error, _} -> ok
    end.

serve(Socket, Script, Buffer) ->
    case read_request(Socket, Buffer) of
        {ok, Rest} ->
            case respond(Socket, Script) of
                keep -> serve(Socket, Script, Rest);
                close -> gen_tcp:close(Socket)
            end;
        closed -> gen_tcp:close(Socket)
    end.

read_request(Socket, Buffer) ->
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            Length = content_length(Head),
            read_body(Socket, Rest, Length);
        [_] ->
            case gen_tcp:recv(Socket, 0, 30000) of
                {ok, Data} -> read_request(Socket, <<Buffer/binary, Data/binary>>);
                {error, _} -> closed
            end
    end.

read_body(_Socket, Rest, Length) when byte_size(Rest) >= Length ->
    <<_:Length/binary, Tail/binary>> = Rest,
    {ok, Tail};
read_body(Socket, Rest, Length) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, Data} -> read_body(Socket, <<Rest/binary, Data/binary>>, Length);
        {error, _} -> closed
    end.

content_length(Head) ->
    Lines = binary:split(string:lowercase(Head), <<"\r\n">>, [global]),
    case [V || <<"content-length:", V/binary>> <- Lines] of
        [Value | _] -> binary_to_integer(string:trim(Value));
        [] -> 0
    end.

respond(Socket, {body, Bytes}) ->
    Head = ["HTTP/1.1 200 OK\r\ncontent-length: ", integer_to_list(byte_size(Bytes)), "\r\n\r\n"],
    gen_tcp:send(Socket, [Head, Bytes]),
    keep;
respond(Socket, {close_after, Bytes}) ->
    Head = ["HTTP/1.1 200 OK\r\ncontent-length: ", integer_to_list(byte_size(Bytes)),
            "\r\nconnection: close\r\n\r\n"],
    gen_tcp:send(Socket, [Head, Bytes]),
    close;
respond(Socket, {chunks, Count, Delay}) ->
    gen_tcp:send(Socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"),
    lists:foreach(fun(_) ->
        timer:sleep(Delay),
        gen_tcp:send(Socket, "4\r\nabcd\r\n")
    end, lists:seq(1, Count)),
    gen_tcp:send(Socket, "0\r\n\r\n"),
    keep.
