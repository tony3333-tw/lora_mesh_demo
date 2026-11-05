%%
%% Send one direct message, like send-direct-message.py.
%%
%%   mte dm -d "Hill top" -m "Test Message"
%%   mte dm -d '!0a0b0c0d' -m hello --wait 30
%%
%% send-direct-message.py waits for the radio's ACK. lora_mesh 0.3 does
%% not pass ACKs on to MQTT, so this prints what that node sends back
%% for --wait seconds (10) instead. (lora_mesh 0.4: the ACK.)
%%
-module(mte_dm).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Nodes = mtc:nodes(C, Opts),
    Dest = mtc:dest(C, Opts),
    Name = mtc:name(mtc:names(Nodes), Dest),
    Text = maps:get(message, Opts, "Test Message"),
    %% listen first, so a fast answer is not missed
    ok = mtc:subscribe(C, rx),
    ok = mtc:send_text(C, Text, #{to => Dest}),
    Wait = maps:get(wait, Opts, 10),
    io:format("Sent \"~ts\" to ~ts, waiting ~p s for an answer...~n", [Text, Name, Wait]),
    case answers(C, Dest, Name, mtc:deadline(Wait * 1000), 0) of
        0 -> io:format("No answer (lora_mesh 0.3 does not report the ACK; "
                       "the message may still have arrived)~n");
        _ -> ok
    end,
    mtc:disconnect(C).

answers(C, Dest, Name, Deadline, Count) ->
    case mtc:next(C, mtc:left(Deadline)) of
        {rx, #{<<"from">> := Dest, <<"text">> := Text}} ->
            io:format("~ts: ~ts~n", [Name, Text]),
            answers(C, Dest, Name, Deadline, Count + 1);
        timeout ->
            Count;
        _Other ->
            answers(C, Dest, Name, Deadline, Count)
    end.
