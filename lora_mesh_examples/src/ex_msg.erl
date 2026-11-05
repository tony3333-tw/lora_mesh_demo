%%
%% Send one direct message to a contact by name, like serial_msg.py and
%% tcp_mchome_msg.py.
%%
%% serial_msg.py then waits for the radio's ACK. lora_mesh 0.3 does not
%% pass delivery ACKs on to MQTT, so this waits for an answer from the
%% contact instead (the demo's nodes answer "got it: ...").
%%
%%   lme msg -d Alice -m "hello from Erlang"
%%   lme msg -d Alice -m "hi" --wait 0      do not wait
%%
-module(ex_msg).

-export([run/1]).

run(Opts) ->
    Dest = maps:get(dest, Opts, "Alice"),
    Text = maps:get(message, Opts, "hello from Erlang"),
    Wait = maps:get(wait, Opts, 10),
    Client = lmc:connect(Opts),
    Nodes = lmc:nodes(Client, 1000),
    case lmc:find(Nodes, Dest) of
        error ->
            io:format("Contact '~ts' not found. Available contacts:~n", [Dest]),
            [io:format("- ~ts (~ts)~n", [maps:get(<<"long_name">>, N), maps:get(<<"id">>, N)])
             || N <- Nodes, maps:get(<<"long_name">>, N) =/= null];
        {ok, Node} ->
            Id = maps:get(<<"id">>, Node),
            io:format("Found contact: ~ts (~ts)~n", [maps:get(<<"long_name">>, Node), Id]),
            %% listen first, so a fast answer is not missed
            ok = lmc:subscribe(Client, rx),
            io:format("Sending message: '~ts'~n", [Text]),
            ok = lmc:send(Client, #{to => Id, text => Text}),
            wait_answer(Client, Id, Wait)
    end,
    lmc:disconnect(Client).

wait_answer(_Client, _Id, 0) ->
    io:format("Sent.~n");
wait_answer(Client, Id, Seconds) ->
    io:format("Sent, waiting ~p s for an answer...~n", [Seconds]),
    Deadline = erlang:monotonic_time(millisecond) + Seconds * 1000,
    wait_loop(Client, Id, Deadline).

wait_loop(Client, Id, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case lmc:next(Client, Left) of
        {rx, #{<<"from">> := Id} = Rx} ->
            io:format("Answer: ~ts ~ts~n", [maps:get(<<"text">>, Rx), lmc:path_info(Rx)]);
        timeout ->
            io:format("No answer (lora_mesh 0.3 does not report the radio's ACK; "
                      "the message may still have arrived)~n");
        _Other ->
            wait_loop(Client, Id, Deadline)
    end.
