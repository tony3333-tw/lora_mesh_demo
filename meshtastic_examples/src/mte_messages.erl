%%
%% Print every text message lora_mesh receives, like print-messages.py.
%% With --seconds S it stops after S seconds, like get-all-messages.py
%% (which listens for 10 seconds).
%%
%%   mte messages
%%   mte messages --seconds 10
%%
-module(mte_messages).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    ok = mtc:subscribe(C, rx),
    Deadline = case maps:find(seconds, Opts) of
                   {ok, S} -> mtc:deadline(S * 1000);
                   error -> infinity
               end,
    loop(C, Deadline),
    mtc:disconnect(C).

loop(C, Deadline) ->
    case mtc:next(C, mtc:left(Deadline)) of
        {rx, #{<<"text">> := Text}} ->
            io:format("~ts~n", [Text]),
            loop(C, Deadline);
        {node, _} ->
            loop(C, Deadline);
        timeout ->
            ok
    end.
