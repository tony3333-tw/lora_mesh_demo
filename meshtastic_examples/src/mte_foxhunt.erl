%%
%% Fox hunt: keep asking one node for telemetry and print the SNR and
%% RSSI of each answer, to find it by walking around with the radio,
%% like foxhunt.py and test-rssi-snr.py.
%%
%%   mte foxhunt -d "Barn sensor"
%%   mte foxhunt -d '!2a2a2a2a' --pause 5 --wait 15
%%
%% After an answer it waits --pause seconds (2) before asking again
%% (the Python examples ask again at once); without an answer for
%% --wait seconds (10) it asks again. Ctrl-C ends.
%%
-module(mte_foxhunt).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Fox = mtc:dest(C, Opts),
    Pause = maps:get(pause, Opts, 2) * 1000,
    Wait = maps:get(wait, Opts, 10),
    io:format("Hunting ~ts. Ctrl-C ends.~n", [mtc:name(C, Fox)]),
    ask(C, Fox),
    loop(C, Fox, Pause, Wait, mtc:deadline(Wait * 1000)).

%% telemetry with battery_level 69, as in the Python examples
ask(C, Fox) ->
    io:format("Requesting data...~n"),
    mtc:send_data(C, 'TELEMETRY_APP',
                  {telemetry, #{device_metrics => #{battery_level => 69}}},
                  #{to => Fox, want_response => true}).

loop(C, Fox, Pause, Wait, Deadline) ->
    case mtc:next(C, mtc:left(Deadline)) of
        {packet, #{from := Fox} = P} ->
            io:format("~nSNR: ~p RSSI: ~p~n~n",
                      [maps:get(rx_snr, P, 0.0), maps:get(rx_rssi, P, 0)]),
            timer:sleep(Pause),
            ask(C, Fox),
            loop(C, Fox, Pause, Wait, mtc:deadline(Wait * 1000));
        {packet, _Other} ->
            loop(C, Fox, Pause, Wait, Deadline);
        timeout ->
            io:format("No response received for ~p seconds, retrying...~n", [Wait]),
            ask(C, Fox),
            loop(C, Fox, Pause, Wait, mtc:deadline(Wait * 1000));
        closed ->
            io:format("the radio closed the connection~n")
    end.
