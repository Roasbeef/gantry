%% A per-controller record of the latest poll from each worker slot. OTP's
%% ETS gives concurrent writes from request handlers without a process round
%% trip. The table belongs to a process that does nothing else, so no request
%% handler's exit can drop it, and a lookup before `start/0` reads as empty.
-module(gantry_presence_ffi).
-export([start/0, record/3, all/0]).

-define(TABLE, gantry_presence).

start() ->
    case ets:whereis(?TABLE) of
        undefined ->
            Parent = self(),
            spawn(fun() ->
                ets:new(?TABLE, [named_table, public, set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]),
                Parent ! {?TABLE, ready},
                receive never -> ok end
            end),
            receive {?TABLE, ready} -> nil after 5000 -> nil end;
        _ ->
            nil
    end.

record(Worker, Pool, At) ->
    try ets:insert(?TABLE, {Worker, Pool, At}) of
        true -> nil
    catch
        error:badarg -> nil
    end.

all() ->
    try ets:tab2list(?TABLE)
    catch
        error:badarg -> []
    end.
