%%
%% lora_mesh's own records, in the spirit of lorawan-server's
%% include/lorawan.hrl (#frame{}, #stat{}) and include/lorawan_db.hrl
%% (#rxq{}, #txq{}).
%%
%% The Meshtastic wire records (#to_radio{}, #mesh_packet{}, #data{}, ...)
%% live in include/meshtastic/*.hrl, generated from the .proto files.
%%

%% Like lorawan-server's #rxq{}: radio metadata of one received packet.
%%
%% A hop is #{hash => <<"d1">>, name => <<"Ridge">> | undefined}
%% (lora_mesh_path). path and relay say who passed the packet on:
%%   path   MeshCore: every repeater, first one first ([] = heard straight
%%          from the sender; undefined = not known, e.g. a direct-routed
%%          message, whose packet carries no path on arrival)
%%   relay  Meshtastic: the last node that rebroadcast it (the radio does
%%          not record the others); undefined if not relayed or not known
-record(mesh_rxq, {
    rx_snr = 0.0       :: number(),
    rx_rssi = 0        :: integer(),
    hop_start = 0      :: non_neg_integer(),
    hop_limit = 0      :: non_neg_integer(),
    via_mqtt = false   :: boolean(),
    path               :: [map()] | undefined,
    relay              :: map() | undefined}).

%% Like lorawan-server's #frame{}: one decoded text message from the mesh.
%%
%% Node ids: Meshtastic  <<"!0a0b0c0d">>     (32-bit node number)
%%           MeshCore    <<"@0a0b0c0d0e0f">> (first 6 bytes of the public key)
-record(mesh_rx, {
    from         :: binary(),          % sender id, or <<"?">> if unknown
    to           :: binary(),          % <<"!ffffffff">> = broadcast
    channel      :: non_neg_integer(),
    id           :: non_neg_integer(), % packet id (Meshtastic), sender time (MeshCore)
    rxq          :: #mesh_rxq{},       % the best copy's radio data
    bridges = [] :: [atom()],          % every bridge that heard it, best first
    text         :: binary(),
    protocol = meshtastic :: meshtastic | meshcore,
    sender_name  :: binary() | undefined}).  % MeshCore channel messages carry a name

%% One bridge hearing one node, like lorawan-server's per-gateway
%% reception data kept with each device.
-record(mesh_heard, {
    bridge   :: atom(),
    rxq      :: #mesh_rxq{},
    at       :: integer()}).           % erlang:system_time(second)

%% Last known position, in degrees and metres.
-record(mesh_position, {
    latitude    :: float(),
    longitude   :: float(),
    altitude    :: integer() | undefined,
    time        :: non_neg_integer() | undefined}).   % unix seconds, from the node

%% Like lorawan-server's #node{} / #device{}: what we know about one node.
-record(mesh_node, {
    num                     :: non_neg_integer(),   % key: node number / 48-bit key prefix
    id                      :: binary(),            % <<"!0a0b0c0d">> or <<"@0a0b0c0d0e0f">>
    protocol = meshtastic   :: meshtastic | meshcore,
    long_name               :: binary() | undefined,
    short_name              :: binary() | undefined,
    hw_model                :: atom() | integer() | undefined,
    role                    :: atom() | integer() | undefined,
    position                :: #mesh_position{} | undefined,
    battery_level           :: non_neg_integer() | undefined,   % percent, 101 = powered
    voltage                 :: float() | undefined,
    last_heard              :: integer() | undefined,           % unix seconds
    heard_by = #{}          :: #{atom() => #mesh_heard{}},
    %% MeshCore: the route each bridge's radio uses to reach this node,
    %% first hop first ([] = in radio range). A bridge with no route
    %% (it floods) has no entry.
    routes = #{}            :: #{atom() => [map()]}}).

%% Like lorawan-server's #txdata{}: one text message to send into the mesh.
-record(mesh_tx, {
    to = 16#FFFFFFFF :: non_neg_integer(),   % node number (MeshCore: bit 48 set), default broadcast
    channel = 0      :: non_neg_integer(),
    text             :: unicode:chardata()}).

%% Record -> map with every field, for JSON
%% (lorawan-server's ?to_map drops default values; here all fields are kept).
-define(to_map(Record, RecData),
    maps:from_list(
        lists:zip(record_info(fields, Record),
                  tl(tuple_to_list(RecData))))).

%% Meshtastic constants
-define(MESH_BROADCAST, 16#FFFFFFFF).
-define(MESH_DATA_PAYLOAD_LEN, 233).   % DATA_PAYLOAD_LEN in mesh.proto
-define(MESH_HOP_LIMIT, 3).
-define(MESH_TCP_PORT, 4403).

%% pg scope and groups (bridges and the router may run on other nodes)
-define(PG_SCOPE, lora_mesh).
-define(PG_ROUTER, router).
-define(PG_BRIDGES, bridges).
-define(PG_BRIDGE(Id), {bridge, Id}).
-define(PG_PROTOCOL(P), {protocol, P}).   % meshtastic | meshcore

% end of file
