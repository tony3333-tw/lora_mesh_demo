%%
%% Print the radio's own statistics (packets sent and received, channel
%% use, ...) whenever it reports them, like get-local-stats.py. A radio
%% sends them to its client every few minutes.
%%
%%   mte local-stats
%%
-module(mte_local_stats).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    loop(C, mtc:my_num(C)).

loop(C, MyNum) ->
    case mtc:next(C, infinity) of
        {packet, #{from := MyNum} = P} ->
            case mtc:get(P, [decoded, telemetry, local_stats], undefined) of
                undefined ->
                    ok;
                Stats ->
                    io:format("LOCAL STATS:~n"),
                    [io:format("  ~-20s : ~ts~n", [K, mtc:show(V)]) || {K, V} <- lists:sort(maps:to_list(Stats))]
            end,
            loop(C, MyNum);
        {packet, _Other} ->
            loop(C, MyNum);
        closed ->
            io:format("the radio closed the connection~n")
    end.
