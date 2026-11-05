%%
%% Both at once, like MQTT/mqtt-client.py: send a text (as mqtt-send),
%% then print every text message lora_mesh publishes (as mqtt-receive).
%% Ctrl-C ends.
%%
%%   mte mqtt-client
%%   mte mqtt-client -m "hello" -c 1
%%
-module(mte_mqtt_client).

-export([run/1]).

run(Opts) ->
    Conn = mte_mqtt_receive:connect(Opts),
    Prefix = maps:get(prefix, Opts, "mesh"),
    Subscribe = Prefix ++ "/rx/#",
    Publish = Prefix ++ "/tx",
    {ok, _, _} = emqtt:subscribe(Conn, list_to_binary(Subscribe), 0),
    io:format("Subscribe Topic is: ~s~nPublish Topic is: ~s~n~n", [Subscribe, Publish]),
    ok = mte_mqtt_send:send(Conn, Publish, mte_mqtt_send:tx(Opts)),
    loop().

loop() ->
    receive
        {publish, #{topic := Topic, payload := Payload}} ->
            mte_mqtt_receive:print(Topic, Payload),
            loop();
        {disconnected, ReasonCode, _Props} ->
            io:format("disconnected from the broker (~p)~n", [ReasonCode])
    end.
