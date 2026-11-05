%%
%% A pretend node on MQTT, like MQTT/mqtt-client.py: publish a node info,
%% a position and a text message (as mqtt-send), then print every packet
%% on the channel's topic (as mqtt-receive). Ctrl-C ends.
%%
%%   mte mqtt-client
%%   mte mqtt-client --root msh/TW/2/e/ -m "hello"
%%
-module(mte_mqtt_client).

-export([run/1]).

run(Opts) ->
    Conn = mtq:connect(Opts),
    Bot = mte_mqtt_send:bot(Opts, "msh/US/Bots/2/e/"),
    Subscribe = mtq:root(Opts, "msh/US/Bots/2/e/") ++ maps:get(channel_name, Bot) ++ "/#",
    ok = mtq:subscribe(Conn, Subscribe),
    io:format("Subscribe Topic is: ~s~nPublish Topic is: ~s~n~n", [Subscribe, maps:get(topic, Bot)]),
    %% send from another process: received packets print meanwhile
    spawn_link(fun() -> mte_mqtt_send:send_all(Conn, Bot) end),
    loop(maps:get(key, Bot)).

loop(Key) ->
    receive
        {publish, #{payload := Payload}} ->
            case mtq:open(Payload, Key) of
                {ok, #{packet := Packet}} -> io:format("~p~n~n", [Packet]);
                {error, Reason} -> io:format("*** ServiceEnvelope: ~p~n", [Reason])
            end,
            loop(Key);
        {disconnected, ReasonCode, _Props} ->
            io:format("disconnected from the broker (~p)~n", [ReasonCode])
    end.
