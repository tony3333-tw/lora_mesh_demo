%%
%% Print every packet published to a Meshtastic MQTT broker, decrypted
%% with the channel key, like MQTT/receive-mqtt-packets.py. No radio is
%% needed: radios with their MQTT module on publish what they hear.
%%
%%   mte mqtt-receive                               mqtt.meshtastic.org, msh/US/2/e/
%%   mte mqtt-receive --root msh/TW/2/e/            Taiwan's topics
%%   mte mqtt-receive --channel-name farm --key BASE64KEY
%%   mte mqtt-receive --broker localhost --topic 'msh/#'
%%
%% Subscribes to <root>PKI/# and <root><channel name>/# unless --topic
%% is given. Direct messages (PKI) cannot be decrypted with a channel
%% key: they are printed encrypted.
%%
-module(mte_mqtt_receive).

-export([run/1]).

run(Opts) ->
    Key = mtq:key(maps:get(key, Opts, "AQ==")),
    Root = mtq:root(Opts, "msh/US/2/e/"),
    Topics = maps:get(topics, Opts,
                      [Root ++ "PKI/#", Root ++ maps:get(channel_name, Opts, "LongFast") ++ "/#"]),
    Conn = mtq:connect(Opts),
    io:format("Connected to MQTT broker!~n"),
    [begin
         ok = mtq:subscribe(Conn, Topic),
         io:format("Subscribed to topic: ~ts~n", [Topic])
     end
     || Topic <- Topics],
    loop(Key).

loop(Key) ->
    receive
        {publish, #{topic := Topic, payload := Payload}} ->
            case mtq:open(Payload, Key) of
                {ok, Envelope} ->
                    case Envelope of
                        #{gateway_id := Gateway} -> io:format("Gateway ID: ~ts~n", [Gateway]);
                        _ -> ok
                    end,
                    Packet = maps:get(packet, Envelope),
                    case Packet of
                        #{decrypt_failed := true} ->
                            io:format("Decryption failed; retaining original encrypted payload~n");
                        _ ->
                            ok
                    end,
                    io:format("~p~n~n", [Packet]);
                {error, _} ->
                    io:format("~ts: not a ServiceEnvelope (~p bytes)~n~n", [Topic, byte_size(Payload)])
            end,
            loop(Key);
        {disconnected, ReasonCode, _Props} ->
            io:format("disconnected from the broker (~p)~n", [ReasonCode])
    end.
