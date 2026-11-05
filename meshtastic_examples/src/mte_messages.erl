%%
%% Print every text message the radio receives, like print-messages.py.
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
    Deadline = case maps:find(seconds, Opts) of
                   {ok, S} -> mtc:deadline(S * 1000);
                   error -> infinity
               end,
    loop(C, Deadline),
    mtc:close(C).

loop(C, Deadline) ->
    case mtc:next(C, mtc:left(Deadline)) of
        {packet, #{decoded := #{portnum := 'TEXT_MESSAGE_APP', text := Text}}} ->
            io:format("~ts~n", [Text]),
            loop(C, Deadline);
        {packet, _Other} ->
            loop(C, Deadline);
        closed ->
            io:format("the radio closed the connection~n");
        timeout ->
            ok
    end.
