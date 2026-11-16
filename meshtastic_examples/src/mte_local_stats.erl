%%
%% Print each bridge's radio statistics (packets sent and received,
%% channel use, ...) whenever the radio reports them, like
%% get-local-stats.py. A radio sends them every few minutes; lora_mesh's
%% demo boards every 24 s (lora_mesh 0.4: mesh/packet/<my id>).
%%
%%   mte local-stats
%%   mte local-stats --bridge hill
%%
-module(mte_local_stats).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    %% each bridge's radio: <<"!0600d1e5">> => <<"home">>
    Mine = maps:from_list([{maps:get(<<"my_id">>, B), maps:get(<<"bridge">>, B)}
                           || B <- mtc:bridges(C, Opts)]),
    case map_size(Mine) of
        0 -> io:format("no Meshtastic bridge has reported its radio yet (lora_mesh 0.4 needed)~n");
        _ -> io:format("Waiting for local stats from ~ts. Ctrl-C ends.~n",
                       [lists:join(", ", lists:sort(maps:values(Mine)))])
    end,
    ok = mtc:subscribe(C, packets),
    loop(C, Mine).

loop(C, Mine) ->
    case mtc:next(C, infinity) of
        {packet, #{<<"from_id">> := From} = P} when is_map_key(From, Mine) ->
            case mtc:get(P, [<<"decoded">>, <<"telemetry">>, <<"local_stats">>], undefined) of
                undefined ->
                    ok;
                Stats ->
                    io:format("LOCAL STATS (~ts):~n", [maps:get(From, Mine)]),
                    [io:format("  ~-22ts : ~ts~n", [K, mtc:show(V)])
                     || {K, V} <- lists:sort(maps:to_list(Stats))]
            end,
            loop(C, Mine);
        _Other ->
            loop(C, Mine)
    end.
