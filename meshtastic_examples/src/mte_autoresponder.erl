%%
%% Answer every text message, like autoresponder.py: "Message Received"
%% to everyone, on channel 0. With -c 1 it answers on channel 1, like
%% send-secondary.py.
%%
%%   mte autoresponder
%%   mte autoresponder -c 1 -m "got it"
%%
%% It does not answer its own reply text, so two autoresponders on one
%% mesh do not answer each other for ever. Every answer is a broadcast
%% through lora_mesh: on a real mesh, run it on a private channel.
%%
-module(mte_autoresponder).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    ok = mtc:subscribe(C, rx),
    Reply = unicode:characters_to_binary(maps:get(message, Opts, "Message Received")),
    Channel = maps:get(channel, Opts, 0),
    io:format("Answering every text message with \"~ts\" on channel ~p. Ctrl-C ends.~n",
              [Reply, Channel]),
    loop(C, Reply, Channel).

loop(C, Reply, Channel) ->
    case mtc:next(C, infinity) of
        {rx, #{<<"text">> := Text}} when Text =/= Reply ->
            io:format("Received: ~ts~n", [Text]),
            ok = mtc:send_text(C, Reply, #{channel => Channel}),
            io:format("Sent: ~ts~n", [Reply]),
            loop(C, Reply, Channel);
        _Other ->
            loop(C, Reply, Channel)
    end.
