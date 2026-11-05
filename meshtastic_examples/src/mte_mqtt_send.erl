%%
%% Send text messages by publishing to lora_mesh's mesh/tx, like
%% MQTT/send-mqtt-packets.py publishes to a Meshtastic MQTT broker.
%% Plain emqtt and json, without mtc: what any MQTT client can do.
%%
%%   mte mqtt-send                              "Hello from Erlang" to everyone
%%   mte mqtt-send -m "hello" -c 1              on channel 1
%%   mte mqtt-send -m "hello" -d '!0a0b0c0d'    a direct message
%%
%% send-mqtt-packets.py makes up a node ("Bottastic") and publishes its
%% node info, position and a text. Through lora_mesh the texts go out
%% from a bridge's radio, as that radio, so there is no made-up node;
%% node info and position wait for lora_mesh 0.4.
%%
-module(mte_mqtt_send).

-export([run/1]).
-export([tx/1]).
-export([send/3]).

run(Opts) ->
    Conn = mte_mqtt_receive:connect(Opts),
    Topic = maps:get(prefix, Opts, "mesh") ++ "/tx",
    io:format("Connected to server: ~s~n", [maps:get(host, Opts, "localhost")]),
    io:format("Publish Topic is: ~s~n~n", [Topic]),
    send(Conn, Topic, tx(Opts)),
    _ = emqtt:disconnect(Conn),
    io:format("Client Disconnected~n").

%% The mesh/tx JSON: text, to (or protocol meshtastic: a broadcast to
%% the Meshtastic mesh), channel
tx(Opts) ->
    Text = unicode:characters_to_binary(maps:get(message, Opts, "Hello from Erlang")),
    Base = #{<<"text">> => Text,
             <<"channel">> => maps:get(channel, Opts, 0)},
    case maps:find(dest, Opts) of
        {ok, To} -> Base#{<<"to">> => unicode:characters_to_binary(To)};
        error -> Base#{<<"protocol">> => <<"meshtastic">>}
    end.

send(Conn, Topic, Tx) ->
    Json = iolist_to_binary(json:encode(Tx)),
    io:format("Sending ~ts~n", [Json]),
    {ok, _} = emqtt:publish(Conn, unicode:characters_to_binary(Topic), Json, 1),
    ok.
