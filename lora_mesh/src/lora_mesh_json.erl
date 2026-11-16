%%
%% Meshtastic records -> JSON-ready maps, for the 0.4 topics
%% mesh/packet/<from> and mesh/bridge/<id>/info.
%%
%% Works for any message of meshtastic_pb, from its definitions
%% (meshtastic_pb:find_msg_def/1), so a new firmware field shows up
%% without a change here. Like protobuf's MessageToDict in Python:
%%
%%   - fields with their default value (0, false, <<>>, [], the first
%%     enum value) and unset fields are left out;
%%   - a oneof shows only the alternative that is set, under its own
%%     name: #config{payload_variant = {lora, ...}} -> #{lora => ...};
%%   - enums are names ('LONG_FAST'), bytes that are not text are
%%     "base64:..."; keys stay snake_case (MessageToDict: camelCase).
%%
%% packet/1 adds what the Python library adds to a received packet:
%% from_id and to_id ("!0a0b0c0d"), and the payload decoded by port
%% number under the key Python uses (text, position, user, telemetry,
%% routing, traceroute, neighborinfo, ...).
%%
-module(lora_mesh_json).

-export([record/1]).
-export([packet/1]).
-export([app/2]).

-include("meshtastic/mesh.hrl").

%%====================================================================
%% API
%%====================================================================

%% Any meshtastic_pb record -> map
-spec record(tuple()) -> map().
record(Rec) when is_tuple(Rec) ->
    Name = element(1, Rec),
    lists:foldl(fun(Field, Acc) -> field(Field, Rec, Acc) end,
                #{},
                meshtastic_pb:find_msg_def(Name)).

%% A received #mesh_packet{} -> map, with from_id, to_id and the
%% decoded payload
-spec packet(#mesh_packet{}) -> map().
packet(#mesh_packet{from = From, to = To} = Packet) ->
    Map = record(Packet),
    Map2 = Map#{from_id => lora_mesh_node:node_id(From),
                to_id => lora_mesh_node:node_id(To)},
    case Packet#mesh_packet.payload_variant of
        {decoded, #data{portnum = Port, payload = Payload}} ->
            #{decoded := Data} = Map2,
            Map2#{decoded := maps:merge(Data, app(Port, Payload))};
        _ ->
            Map2
    end.

%% One application payload, decoded by port number:
%% #{text => ...} | #{position => ...} | ... | #{} when not known.
%% A payload that does not decode gets #{decode_error => MsgName}.
-spec app(atom() | integer(), binary()) -> map().
app(Port, Payload) ->
    case app_msg(Port) of
        none ->
            #{};
        {Key, text} ->
            #{Key => Payload};
        {Key, MsgName} ->
            try meshtastic_pb:decode_msg(Payload, MsgName) of
                Rec -> #{Key => fixup(MsgName, record(Rec))}
            catch
                _:_ -> #{decode_error => MsgName}
            end
    end.

%%====================================================================
%% Internal
%%====================================================================

%% the keys of Python's protocols table (meshtastic/__init__.py)
app_msg('TEXT_MESSAGE_APP') -> {text, text};
app_msg('RANGE_TEST_APP') -> {text, text};
app_msg('DETECTION_SENSOR_APP') -> {text, text};
app_msg('ALERT_APP') -> {text, text};
app_msg('POSITION_APP') -> {position, position};
app_msg('NODEINFO_APP') -> {user, user};
app_msg('TELEMETRY_APP') -> {telemetry, telemetry};
app_msg('ROUTING_APP') -> {routing, routing};
app_msg('TRACEROUTE_APP') -> {traceroute, route_discovery};
app_msg('ADMIN_APP') -> {admin, admin_message};
app_msg('WAYPOINT_APP') -> {waypoint, waypoint};
app_msg('NEIGHBORINFO_APP') -> {neighborinfo, neighbor_info};
app_msg('PAXCOUNTER_APP') -> {paxcounter, paxcount};
app_msg('STORE_FORWARD_APP') -> {store_forward, store_and_forward};
app_msg('MAP_REPORT_APP') -> {map_report, map_report};
app_msg(_) -> none.

%% Like Python's _fixupPosition: degrees next to latitude_i / longitude_i
fixup(position, Pos) ->
    maps:merge(Pos,
               maps:from_list([{K, maps:get(KI, Pos) / 10000000}
                               || {K, KI} <- [{latitude, latitude_i}, {longitude, longitude_i}],
                                  maps:is_key(KI, Pos)]));
fixup(_MsgName, Map) ->
    Map.

%% a oneof: only the alternative that is set, under its own name
field(#{fields := Alternatives, rnum := RNum}, Rec, Acc) ->
    case element(RNum, Rec) of
        {Tag, V} ->
            [#{type := Type}] = [A || #{name := N} = A <- Alternatives, N =:= Tag],
            Acc#{Tag => value(Type, V)};
        _ ->
            Acc
    end;
field(#{name := Name, type := Type, rnum := RNum, occurrence := Occurrence}, Rec, Acc) ->
    V = element(RNum, Rec),
    case is_default(Type, Occurrence, V) of
        true ->
            Acc;
        false when Occurrence =:= repeated ->
            Acc#{Name => repeated(Type, V)};
        false ->
            Acc#{Name => value(Type, V)}
    end.

repeated({map, _KeyType, ValueType}, Pairs) ->
    maps:from_list([{key(K), value(ValueType, V)} || {K, V} <- Pairs]);
repeated(Type, List) ->
    [value(Type, V) || V <- List].

is_default(_Type, _Occurrence, undefined) -> true;
is_default(_Type, repeated, []) -> true;
is_default(_Type, repeated, _) -> false;
is_default({msg, _}, _Occurrence, _V) -> false;
is_default(_Type, optional, _V) -> false;           % proto3 `optional': set means shown
is_default({enum, Enum}, _Occurrence, V) ->
    try meshtastic_pb:enum_symbol_by_value(Enum, 0) =:= V
    catch _:_ -> false
    end;
is_default(bool, _Occurrence, V) -> V =:= false;
is_default(string, _Occurrence, V) -> iolist_size(V) =:= 0;
is_default(bytes, _Occurrence, V) -> iolist_size(V) =:= 0;
is_default(_Number, _Occurrence, V) -> V == 0.

value({msg, _}, Rec) when is_tuple(Rec) -> record(Rec);
value({enum, _}, V) -> V;                            % an atom, or an unknown number
value(bytes, V) -> bytes(iolist_to_binary(V));
value(string, V) -> unicode:characters_to_binary(V);
value(_Float, V) when V =:= infinity; V =:= '-infinity'; V =:= nan -> null;
value(_Type, V) -> V.

%% text stays text; anything else (keys, macaddr, ...) as base64
bytes(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Bin -> case is_printable(Bin) of
                   true -> Bin;
                   false -> <<"base64:", (base64:encode(Bin))/binary>>
               end;
        _ -> <<"base64:", (base64:encode(Bin))/binary>>
    end.

is_printable(Bin) ->
    lists:all(fun(C) -> C >= 32 orelse C =:= $\n orelse C =:= $\t end,
              unicode:characters_to_list(Bin)).

key(K) when is_integer(K) -> integer_to_binary(K);
key(K) -> K.
