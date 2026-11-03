%%
%% What to do with one packet once the router has deduplicated it.
%%
%% Plays the role of lorawan-server's lorawan_handler: the router hands
%% over one packet (the best copy) plus who heard it, and the handler
%% decodes the application payload by port number:
%%
%%   TEXT_MESSAGE_APP  (1)  -> {uplink, #mesh_rx{}} to the connector
%%   NODEINFO_APP      (4)  -> names and hardware in the registry
%%   POSITION_APP      (3)  -> position in the registry
%%   TELEMETRY_APP    (67)  -> battery and voltage in the registry
%%   every packet           -> last heard + who heard it, in the registry
%%
%% Plain functions, run in the router's process.
%%
-module(lora_mesh_handler).

-export([uplink/3]).
-export([heard/2]).
-export([heard_num/2]).
-export([node_info/2]).
-export([rxq/1]).

-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

%% Copies: [{Bridge, #mesh_rxq{}}], best reception first.
-spec uplink(#mesh_packet{}, [{atom(), #mesh_rxq{}}], pid() | atom()) -> ok.
uplink(#mesh_packet{from = From} = Packet, Copies, Subscriber) ->
    %% the payload first, then "heard": a new node's first registry record
    %% then already carries its name (NODEINFO) or position
    case Packet#mesh_packet.payload_variant of
        {decoded, #data{portnum = Port, payload = Payload}} ->
            app(Port, Payload, Packet, Copies, Subscriber);
        {encrypted, _} ->
            %% a channel this node has no key for
            ok;
        undefined ->
            logger:debug("lora_mesh_handler: empty packet from ~s",
                         [lora_mesh_node:node_id(From)])
    end,
    heard(Packet, Copies).

%% Record that these bridges heard the sender (also used for late copies).
-spec heard(#mesh_packet{}, [{atom(), #mesh_rxq{}}]) -> ok.
heard(#mesh_packet{from = From}, Copies) ->
    heard_num(From, Copies).

%% The same, by registry number (used for MeshCore senders too).
-spec heard_num(non_neg_integer(), [{atom(), #mesh_rxq{}}]) -> ok.
heard_num(Num, Copies) ->
    Now = erlang:system_time(second),
    lora_mesh_registry:update(
      Num,
      fun(#mesh_node{heard_by = HeardBy} = Node) ->
              HeardBy2 = lists:foldl(
                           fun({Bridge, RxQ}, Acc) ->
                                   Acc#{Bridge => #mesh_heard{bridge = Bridge,
                                                              rxq = RxQ,
                                                              at = Now}}
                           end,
                           HeardBy,
                           Copies),
              Node#mesh_node{last_heard = Now,
                             heard_by = HeardBy2}
      end).

%% A node's own database, sent once on connect (FromRadio node_info).
-spec node_info(atom(), #node_info{}) -> ok.
node_info(_Bridge, #node_info{num = Num} = Info) ->
    lora_mesh_registry:update(
      Num,
      fun(Node) ->
              Node2 = user(Info#node_info.user, Node),
              Node3 = position(Info#node_info.position, Node2),
              Node4 = device_metrics(Info#node_info.device_metrics, Node3),
              case Info#node_info.last_heard of
                  LastHeard when is_integer(LastHeard), LastHeard > 0,
                                 Node4#mesh_node.last_heard =:= undefined ->
                      Node4#mesh_node{last_heard = LastHeard};
                  _ ->
                      Node4
              end
      end).

%% Like lorawan_gw_forwarder:parse_rxpk/1: radio data out of the packet.
-spec rxq(#mesh_packet{}) -> #mesh_rxq{}.
rxq(#mesh_packet{} = P) ->
    #mesh_rxq{rx_snr = P#mesh_packet.rx_snr,
              rx_rssi = P#mesh_packet.rx_rssi,
              hop_start = P#mesh_packet.hop_start,
              hop_limit = P#mesh_packet.hop_limit,
              via_mqtt = P#mesh_packet.via_mqtt}.

%%====================================================================
%% By port
%%====================================================================

app('TEXT_MESSAGE_APP', Text, #mesh_packet{} = P, Copies, Subscriber) ->
    Rx = #mesh_rx{from = lora_mesh_node:node_id(P#mesh_packet.from),
                  to = lora_mesh_node:node_id(P#mesh_packet.to),
                  channel = P#mesh_packet.channel,
                  id = P#mesh_packet.id,
                  rxq = rxq(P),
                  bridges = [Bridge || {Bridge, _} <- Copies],
                  text = Text},
    catch Subscriber ! {uplink, Rx},
    ok;
app('NODEINFO_APP', Payload, #mesh_packet{from = From}, _Copies, _Subscriber) ->
    decoded(Payload, user, From,
            fun(User) -> fun(Node) -> user(User, Node) end end);
app('POSITION_APP', Payload, #mesh_packet{from = From}, _Copies, _Subscriber) ->
    decoded(Payload, position, From,
            fun(Pos) -> fun(Node) -> position(Pos, Node) end end);
app('TELEMETRY_APP', Payload, #mesh_packet{from = From}, _Copies, _Subscriber) ->
    decoded(Payload, telemetry, From,
            fun(#telemetry{variant = {device_metrics, M}}) ->
                    fun(Node) -> device_metrics(M, Node) end;
               (#telemetry{}) ->
                    %% environment, air quality, ...: not kept yet
                    fun(Node) -> Node end
            end);
app(_Port, _Payload, _Packet, _Copies, _Subscriber) ->
    %% routing, admin, traceroute, ...: ignored here
    ok.

%% Decode Payload as MsgName and apply the update it produces.
decoded(Payload, MsgName, From, MakeUpdate) ->
    try meshtastic_pb:decode_msg(Payload, MsgName) of
        Msg ->
            lora_mesh_registry:update(From, MakeUpdate(Msg))
    catch
        error:Reason ->
            logger:warning("lora_mesh_handler: bad ~p from ~s: ~p",
                           [MsgName, lora_mesh_node:node_id(From), Reason])
    end.

%%====================================================================
%% Record -> #mesh_node{} fields
%%====================================================================

user(undefined, Node) ->
    Node;
user(#user{} = U, Node) ->
    Node#mesh_node{long_name = U#user.long_name,
                   short_name = U#user.short_name,
                   hw_model = U#user.hw_model,
                   role = U#user.role}.

position(#position{latitude_i = Lat, longitude_i = Lon} = P, Node)
  when is_integer(Lat), is_integer(Lon), {Lat, Lon} =/= {0, 0} ->
    Node#mesh_node{position =
                       #mesh_position{latitude = Lat * 1.0e-7,
                                      longitude = Lon * 1.0e-7,
                                      altitude = P#position.altitude,
                                      time = P#position.time}};
position(_NoFix, Node) ->
    Node.

device_metrics(#device_metrics{} = M, Node) ->
    Node#mesh_node{battery_level = M#device_metrics.battery_level,
                   voltage = M#device_metrics.voltage};
device_metrics(undefined, Node) ->
    Node.
