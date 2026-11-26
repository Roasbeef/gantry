%% Deliver SIGTERM to one process as a message instead of running init:stop.
%% OTP reports operating-system signals as events of the erl_signal_server
%% gen_event manager, and the kernel's default handler stops the VM on
%% SIGTERM. A worker that drains must decide for itself when to stop, so
%% this handler replaces the default one and sends `gantry_terminate` to
%% the owner. SIGUSR1 and SIGQUIT keep the default handler's meaning.
-module(gantry_signal_ffi).
-behaviour(gen_event).
-export([forward_terminate/0, terminate_signal/1]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

%% Route SIGTERM to the calling process from now on.
forward_terminate() ->
    ok = os:set_signal(sigterm, handle),
    ok = gen_event:swap_handler(erl_signal_server,
                                {erl_signal_handler, []},
                                {?MODULE, self()}),
    nil.

%% Recognise the message that forward_terminate arranges.
terminate_signal(gantry_terminate) -> {ok, nil};
terminate_signal(_) -> {error, nil}.

%% swap_handler passes the owner with the old handler's terminate result.
init({Owner, _}) when is_pid(Owner) -> {ok, Owner}.

handle_event(sigterm, Owner) ->
    Owner ! gantry_terminate,
    {ok, Owner};
handle_event(sigusr1, Owner) ->
    erlang:halt("Received SIGUSR1"),
    {ok, Owner};
handle_event(sigquit, Owner) ->
    erlang:halt(),
    {ok, Owner};
handle_event(_, Owner) ->
    {ok, Owner}.

handle_call(_, Owner) -> {ok, ok, Owner}.
handle_info(_, Owner) -> {ok, Owner}.
terminate(_, _) -> ok.
code_change(_, Owner, _) -> {ok, Owner}.
