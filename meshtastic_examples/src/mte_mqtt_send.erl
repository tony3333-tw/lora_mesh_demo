%%
%% Publish a node info, a position and a text message to a Meshtastic
%% MQTT broker as a made-up node, like MQTT/send-mqtt-packets.py: the
%% packets are built and encrypted here, as a radio would, and radios
%% that download from that broker put them on the air.
%%
%%   mte mqtt-send                                   to msh/US/Bots/2/e/LongFast/!abcdXXXX
%%   mte mqtt-send -m "hello" --root msh/TW/2/e/
%%   mte mqtt-send --broker localhost
%%
%% The node is "Bottastic" (BOT), number !abcd + 4 random hex digits.
%% Options: --channel-name (LongFast), --key (AQ==), --lat/--lon/--alt
%% (0), --pause S between packets (4).
%%
-module(mte_mqtt_send).

-export([run/1]).
-export([bot/2]).
-export([send_all/2]).

run(Opts) ->
    Conn = mtq:connect(Opts),
    Bot = bot(Opts, "msh/US/Bots/2/e/"),
    io:format("Connected to server: ~s~n", [maps:get(broker, Opts, "mqtt.meshtastic.org")]),
    io:format("Publish Topic is: ~s~n~n", [maps:get(topic, Bot)]),
    send_all(Conn, Bot),
    mtq:disconnect(Conn),
    io:format("Client Disconnected~n").

%% Who we are and where we publish
bot(Opts, DefaultRoot) ->
    Node = mtq:random_node(),
    Channel = maps:get(channel_name, Opts, "LongFast"),
    #{node => Node,
      key => mtq:key(maps:get(key, Opts, "AQ==")),
      channel_name => Channel,
      topic => mtq:root(Opts, DefaultRoot) ++ Channel ++ "/" ++ binary_to_list(mtc:node_id(Node)),
      pause => maps:get(pause, Opts, 4) * 1000,
      message => maps:get(message, Opts, "Hello from Erlang"),
      position => #{latitude_i => trunc(maps:get(lat, Opts, 0) * 10000000),
                    longitude_i => trunc(maps:get(lon, Opts, 0) * 10000000),
                    altitude => round(maps:get(alt, Opts, 0))}}.

send_all(Conn, #{pause := Pause} = Bot) ->
    send_node_info(Conn, Bot),
    timer:sleep(Pause),
    send_position(Conn, Bot),
    timer:sleep(Pause),
    send_message(Conn, Bot),
    timer:sleep(Pause).

send_node_info(Conn, #{node := Node} = Bot) ->
    io:format("Sending NodeInfo Packet to ~p~n", [16#FFFFFFFF]),
    User = #{id => mtc:node_id(Node),
             long_name => <<"Bottastic">>,
             short_name => <<"BOT">>,
             hw_model => 'PRIVATE_HW'},
    publish(Conn, Bot, 'NODEINFO_APP', mtc:encode(User, user)).

send_position(Conn, #{position := Pos} = Bot) ->
    io:format("Sending Position Packet to ~p~n", [16#FFFFFFFF]),
    publish(Conn, Bot, 'POSITION_APP',
            mtc:encode(Pos#{time => erlang:system_time(second)}, position)).

send_message(Conn, #{message := Text} = Bot) ->
    io:format("Sending Text Message Packet to ~p~n", [16#FFFFFFFF]),
    publish(Conn, Bot, 'TEXT_MESSAGE_APP', unicode:characters_to_binary(Text)).

%% generate_mesh_packet(): Data -> encrypted MeshPacket -> ServiceEnvelope
%% bitfield 1: the sender is OK with the packet going to MQTT
publish(Conn, #{node := Node, key := Key, channel_name := Channel, topic := Topic}, Port, Payload) ->
    Data = #{portnum => Port, payload => Payload, bitfield => 1},
    Packet = mtq:packet(Data, Key, Node, #{channel_name => Channel}),
    Envelope = mtq:envelope(Packet, Channel, mtc:node_id(Node)),
    mtq:publish(Conn, Topic, Envelope).
