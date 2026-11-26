%% A per-controller record of the recent past for the dashboard: each lease
%% this controller granted, each result it accepted, and the ready work it
%% counted when the snapshot was read. OTP's ETS lets request handlers write
%% it concurrently. The table belongs to a process that does nothing else, so
%% no handler's exit drops it, and every call before `start/1` is a no-op.
%%
%% Keys make replays idempotent: a grant is keyed by its lease serial, so a
%% replayed poll that returns the same lease records nothing new, and a
%% result is keyed by the same serial. `prune/2` drops what is older than the
%% window and then the oldest entries past a fixed cap, so the table and the
%% snapshot stay bounded whatever the throughput.
-module(gantry_history_ffi).
-export([start/1, granted/7, settled/3, sample/2, prune/2, since/0,
         grants/0, settlements/0, samples/0]).

-define(TABLE, gantry_history).
-define(CAP, 3000).

start(Now) ->
    case ets:whereis(?TABLE) of
        undefined ->
            Parent = self(),
            spawn(fun() ->
                ets:new(?TABLE, [named_table, public, set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]),
                ets:insert(?TABLE, {started, Now}),
                Parent ! {?TABLE, ready},
                receive never -> ok end
            end),
            receive {?TABLE, ready} -> nil after 5000 -> nil end;
        _ ->
            nil
    end.

granted(Serial, Run, Action, Worker, Pool, At, Until) ->
    safe(fun() ->
        ets:insert_new(?TABLE, {{granted, Serial}, At,
                                {Run, Action, Worker, Pool, Until}})
    end).

settled(Serial, Succeeded, At) ->
    safe(fun() -> ets:insert_new(?TABLE, {{settled, Serial}, At, Succeeded}) end).

sample(At, Ready) ->
    safe(fun() -> ets:insert(?TABLE, {{sample, At}, At, Ready}) end).

prune(Now, Window) ->
    safe(fun() ->
        Cutoff = Now - Window,
        ets:select_delete(?TABLE,
            [{{{'_', '_'}, '$1', '_'}, [{'<', '$1', Cutoff}], [true]}]),
        Size = ets:info(?TABLE, size),
        case Size > ?CAP of
            true ->
                Keyed = ets:select(?TABLE,
                    [{{{'$1', '$2'}, '$3', '_'}, [], [{{'$3', {{'$1', '$2'}}}}]}]),
                Oldest = lists:sublist(lists:sort(Keyed), Size - ?CAP),
                [ets:delete(?TABLE, Key) || {_, Key} <- Oldest],
                {Newest, _} = lists:last(Oldest),
                ets:insert(?TABLE, {floor, Newest + 1});
            false ->
                ok
        end
    end).

%% The oldest second the record still covers: the controller's start, or
%% just after the newest entry the cap dropped, whichever is later.
since() ->
    try
        [{started, Started}] = ets:lookup(?TABLE, started),
        case ets:lookup(?TABLE, floor) of
            [{floor, Floor}] -> max(Started, Floor);
            [] -> Started
        end
    catch
        _:_ -> 0
    end.

grants() ->
    rows(fun() ->
        [{Serial, Run, Action, Worker, Pool, At, Until}
         || {{granted, Serial}, At, {Run, Action, Worker, Pool, Until}}
                <- ets:tab2list(?TABLE)]
    end).

settlements() ->
    rows(fun() ->
        [{Serial, Succeeded, At}
         || {{settled, Serial}, At, Succeeded} <- ets:tab2list(?TABLE)]
    end).

samples() ->
    rows(fun() ->
        [{At, Ready} || {{sample, _}, At, Ready} <- ets:tab2list(?TABLE)]
    end).

safe(Work) ->
    try Work() of
        _ -> nil
    catch
        error:badarg -> nil
    end.

rows(Read) ->
    try Read()
    catch
        error:badarg -> []
    end.
