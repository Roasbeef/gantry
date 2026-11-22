#!/usr/bin/env escript
-mode(compile).

-define(CORPUS_LIMIT, 1024).

main(Args) ->
    ok = code:add_pathsa(filelib:wildcard("build/dev/erlang/*/ebin")),
    run(Args).

run(["swarm", S, C, E]) ->
    Seed = number(S, 1, 2147483646),
    Count = number(C, 1, 1000000),
    Events = number(E, 1, 4096),
    {Micros, ok} = timer:tc(fun() -> swarm(Seed, 1, Count, Events) end),
    io:format("swarm seed=~B schedules=~B events=~B seconds=~.3f schedules_per_second=~.1f~n",
        [Seed, Count, Events, Micros / 1000000, Count * 1000000 / max(1, Micros)]);
run(["replay", S, E]) ->
    io:format("~tp~n", [queue_dst:replay_seed(number(S, 1, 2147483646), number(E, 1, 4096))]);
run(["ops", Mask | Ops]) when length(Ops) =< 4096 ->
    io:format("~tp~n", [queue_dst:replay(number(Mask, 0, 127), [number(Op, 0, 255) || Op <- Ops])]);
run(["guided", S, C]) ->
    Seed = number(S, 1, 2147483646),
    Count = number(C, 1, 10000),
    Modules = ['gantry_core@queue', 'gantry_core@protocol'],
    [{ok, Mod} = cover:compile_beam(Mod) || Mod <- Modules],
    Path = os:getenv("GANTRY_DST_CORPUS"),
    Initial = load_corpus(Path),
    {Micros, {Corpus, Seen}} = timer:tc(fun() ->
        Seen0 = lists:foldl(fun({Index, Input}, Acc) ->
            ordsets:union(coverage(Input, "corpus", Index, Modules), Acc)
        end, [], lists:enumerate(Initial)),
        guided(Seed, 1, Count, Modules, Initial, Seen0)
    end),
    save_corpus(Path, Corpus),
    io:format("guided seed=~B inputs=~B corpus=~B covered_lines=~B seconds=~.3f~n",
        [Seed, Count, length(Corpus), length(Seen), Micros / 1000000]);
run(_) ->
    io:format(standard_error,
        "Usage: scripts/queue-dst.sh swarm SEED COUNT EVENTS | replay SEED EVENTS | ops MASK [BYTE ...] | guided SEED COUNT~n", []),
    halt(2).

number(Text, Low, High) ->
    case string:to_integer(Text) of
        {N, ""} when N >= Low, N =< High -> N;
        _ -> io:format(standard_error, "Expected integer between ~B and ~B~n", [Low, High]), halt(2)
    end.

next(Seed) -> Seed * 48271 rem 2147483647.

swarm(_, Index, Count, _) when Index > Count -> ok;
swarm(Seed, Index, Count, Events) ->
    try
        First = queue_dst:run_seed(Seed, Events),
        First = queue_dst:run_seed(Seed, Events)
    catch Class:Reason:Stack ->
        io:format(standard_error, "swarm failed at index ~B. Replay: scripts/queue-dst.sh replay ~B ~B~n",
            [Index, Seed, Events]),
        erlang:raise(Class, Reason, Stack)
    end,
    swarm(advance(Seed, Events + 1), Index + 1, Count, Events).

%% Skip the mask and event draws consumed by this schedule.
advance(Seed, 0) -> Seed;
advance(Seed, N) -> advance(next(Seed), N - 1).

guided(_, Index, Count, _, Corpus, Seen) when Index > Count -> {Corpus, Seen};
guided(Seed, Index, Count, Modules, Corpus, Seen) ->
    Choice = next(Seed),
    Parent = lists:nth(Choice rem length(Corpus) + 1, Corpus),
    Input = mutate(Parent, next(Choice)),
    Hit = coverage(Input, "mutation", Index, Modules),
    %% Seen is exactly the coverage a later campaign can recover from Corpus.
    case length(Corpus) < ?CORPUS_LIMIT andalso not ordsets:is_subset(Hit, Seen) of
        true -> guided(next(Choice), Index + 1, Count, Modules, lists:usort([Input | Corpus]), ordsets:union(Hit, Seen));
        false -> guided(next(Choice), Index + 1, Count, Modules, Corpus, Seen)
    end.

coverage(Input, Phase, Index, Modules) ->
    [ok = cover:reset(Mod) || Mod <- Modules],
    evaluate(Input, Phase, Index),
    ordsets:from_list(lists:append([covered(Mod) || Mod <- Modules])).

evaluate({Mask, Ops}, Phase, Index) ->
    try
        First = queue_dst:run(Mask, Ops),
        First = queue_dst:run(Mask, Ops),
        ok
    catch Class:Reason:Stack ->
        io:format(standard_error, "guided failed at ~s index ~B. Replay: scripts/queue-dst.sh ops ~B~s~n",
            [Phase, Index, Mask, [io_lib:format(" ~B", [Op]) || Op <- Ops]]),
        erlang:raise(Class, Reason, Stack)
    end.

covered(Mod) ->
    {ok, Lines} = cover:analyse(Mod, coverage, line),
    [{Mod, Line} || {{_, Line}, {Hit, _}} <- Lines, Hit > 0].

mutate({Mask, Ops}, Seed) ->
    Byte = next(Seed) rem 256,
    {Left, Right} = lists:split(Seed rem (length(Ops) + 1), Ops),
    case {Seed rem 4, Right, length(Ops) < 192} of
        {0, _, _} -> {Byte rem 128, Ops};
        {1, [_ | Rest], _} -> {Mask, Left ++ Rest};
        {2, _, true} -> {Mask, Left ++ [Byte | Right]};
        {_, [_ | Rest], _} -> {Mask, Left ++ [Byte | Rest]};
        {_, [], true} -> {Mask, [Byte | Ops]};
        _ -> {Mask, Ops}
    end.


load_corpus(false) -> default_corpus();
load_corpus(Path) ->
    case file:read_file(Path) of
        {error, enoent} -> default_corpus();
        {ok, Data} when byte_size(Data) =< 1048576 ->
            {gantry_dst_v1, Cases} = binary_to_term(Data, [safe]),
            true = is_list(Cases) andalso Cases =/= [],
            true = lists:all(fun valid_input/1, Cases),
            %% Older campaigns could persist more cases than their loader accepted.
            lists:sublist(lists:usort(Cases), ?CORPUS_LIMIT);
        Error -> error({cannot_load_corpus, Error})
    end.

default_corpus() -> [{127, [0, 2, 34, 4, 9, 11, 13]}].

valid_input({Mask, Ops}) when is_integer(Mask), Mask >= 0, Mask =< 127, is_list(Ops), length(Ops) =< 192 ->
    lists:all(fun(Op) -> is_integer(Op) andalso Op >= 0 andalso Op =< 255 end, Ops);
valid_input(_) -> false.

save_corpus(false, _) -> ok;
save_corpus(Path, Cases) ->
    ok = filelib:ensure_dir(Path),
    {ok, Tmp} = file:open(Path ++ ".next", [write, binary, exclusive]),
    try
        ok = file:write(Tmp, term_to_binary({gantry_dst_v1, Cases})),
        ok = file:close(Tmp),
        ok = file:rename(Path ++ ".next", Path)
    after
        _ = file:close(Tmp),
        _ = file:delete(Path ++ ".next")
    end.
