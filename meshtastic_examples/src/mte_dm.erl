%%
%% Send one direct message and wait for its ACK, like
%% send-direct-message.py (which sends with wantAck and waits).
%%
%%   mte dm -d "Hill top" -m "Test Message"
%%   mte dm -d '!60c0ffee' -m hello --wait 30
%%
%% Then it prints what that node sends us for --wait seconds (10).
%%
-module(mte_dm).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Dest = mtc:dest(C, Opts),
    Text = maps:get(message, Opts, "Test Message"),
    Id = mtc:send_text(C, Text, #{to => Dest, want_ack => true, want_response => true}),
    io:format("Sent \"~ts\" to ~ts, waiting for the ACK...~n", [Text, mtc:name(C, Dest)]),
    case mtc:ack(C, Id, 60000) of
        ok -> io:format("ACK: ~ts has it~n", [mtc:name(C, Dest)]);
        {error, Reason} -> io:format("NAK: ~s~n", [Reason]);
        timeout -> io:format("no ACK within 60 s~n");
        closed -> io:format("the radio closed the connection~n")
    end,
    answers(C, Dest, mtc:deadline(maps:get(wait, Opts, 10) * 1000)),
    mtc:close(C).

answers(C, Dest, Deadline) ->
    case mtc:next(C, mtc:left(Deadline)) of
        {packet, #{from := Dest, decoded := #{portnum := 'TEXT_MESSAGE_APP', text := Text}}} ->
            io:format("~ts: ~ts~n", [mtc:name(C, Dest), Text]),
            answers(C, Dest, Deadline);
        {packet, _Other} ->
            answers(C, Dest, Deadline);
        _TimeoutOrClosed ->
            ok
    end.
