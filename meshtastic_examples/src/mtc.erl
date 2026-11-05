%%
%% mtc: a small Erlang client for one Meshtastic radio, over TCP.
%%
%% What meshtastic.tcp_interface.TCPInterface does for the Python
%% examples, for the Erlang and LFE examples here. It speaks the radio's
%% client API (the "stream API": TCP port 4403, frames 0x94 0xC3 len16
%% + protobuf), the same API lora_mesh's Meshtastic bridges use.
%%
%%   C = mtc:connect(#{host => "192.168.1.42"}),   % radio ready, config read
%%   mtc:nodes(C)                                   % iface.nodes
%%   mtc:send_text(C, "hello", #{})                 % iface.sendText("hello")
%%   {packet, P} = mtc:next(C, infinity)            % pub.subscribe(onReceive)
%%   mtc:close(C)
%%
%% Received packets arrive in the process that called connect/1 as
%%
%%   {mtc, C, packet, Packet}
%%   {mtc, C, closed, Reason}       the radio closed the connection
%%
%% A Packet is a map, like the dict onReceive gets in Python: the
%% MeshPacket fields that are set (rx_snr, hop_limit, ... in snake_case),
%% from_id / to_id ("!a1b2c3d4"), and in decoded the payload decoded by
%% port number, under the key Python uses:
%%
%%   #{from => 2711462381, from_id => <<"!a19e8bed">>, rx_snr => 6.25,
%%     decoded => #{portnum => 'TEXT_MESSAGE_APP', payload => <<"hi">>,
%%                  text => <<"hi">>}}
%%
%% Unset (default) fields are left out, as in Python's dicts: use
%% maps:get(Key, Map, Default) or get/3.
%%
%% Messages are maps of the generated module mt_pb (gpb, maps mode,
%% oneofs flat): #{decoded => ...} rather than {decoded, ...}.
%%
%% A radio serves one client API connection at a time: connecting
%% closes the radio's previous connection (lora_mesh's bridge to it, the
%% phone app over WiFi). See README.md.
%%
-module(mtc).

%% our nodes/1 is the radio's node list, not erlang:nodes/1
-compile({no_auto_import, [nodes/1]}).

-export([connect/1]).
-export([close/1]).
-export([info/1]).
-export([my_num/1]).
-export([my_info/1]).
-export([nodes/1]).
-export([node/2]).
-export([channels/1]).
-export([config/2]).
-export([module_config/2]).
-export([metadata/1]).
-export([send_text/3]).
-export([send_data/4]).
-export([send_position/2]).
-export([send_telemetry/3]).
-export([send_traceroute/3]).
-export([admin/2]).
-export([next/2]).
-export([reply/4]).
-export([ack/3]).
-export([node_num/2]).
-export([node_id/1]).
-export([name/2]).
-export([admin_index/1]).
-export([get/3]).
-export([dest/2]).
-export([deadline/1]).
-export([left/1]).
-export([decode_app/1]).
-export([degrees/1]).
-export([compact/2]).
-export([encode/2]).
-export([decode/2]).
-export([show/1]).
-export([json/1]).
-export([json_term/1]).
-export([frame/1]).
-export([unframe/1]).

-define(BROADCAST, 16#FFFFFFFF).
-define(PORT, 4403).
-define(HEARTBEAT_MS, 60000).
-define(MAX_FRAME, 512).

-record(st, {
    owner,
    ref,                  % the reply connect/1 waits for
    sock,
    buf = <<>>,
    config_id,
    ready = false,
    my_info = #{},
    nodes = #{},          % num => node map
    channels = #{},       % index => channel map
    config = #{},         % lora => ..., device => ...
    module_config = #{},  % mqtt => ..., telemetry => ...
    metadata = #{}}).

%%====================================================================
%% Connection
%%====================================================================

%% Opts: host ("localhost"), port (4403), timeout (30000 ms).
%% Returns the client once the radio has sent its configuration and
%% node list, like TCPInterface(hostname=...). Raises
%% error({radio_connect, Reason}) when that fails.
connect(Opts) ->
    Owner = self(),
    Ref = make_ref(),
    C = spawn_link(fun() -> init(Owner, Ref, Opts) end),
    receive
        {Ref, ready} ->
            C;
        {Ref, {error, Reason}} ->
            error({radio_connect, Reason})
    after maps:get(timeout, Opts, 30000) ->
        unlink(C),
        exit(C, kill),
        error({radio_connect, timeout})
    end.

close(C) ->
    catch call(C, close),
    ok.

%%====================================================================
%% What the radio told us on connect (kept up to date)
%%====================================================================

%% Everything: my_num, my_info, nodes, channels, config, module_config,
%% metadata.
info(C) ->
    call(C, info).

my_num(C) ->
    maps:get(my_num, info(C)).

%% MyNodeInfo (my_node_num, reboot_count, ...)
my_info(C) ->
    maps:get(my_info, info(C)).

%% The radio's node database, like iface.nodes.values(): node maps
%% (num, user, position, device_metrics, snr, last_heard, hops_away, ...)
%% sorted by node number.
nodes(C) ->
    maps:get(nodes, info(C)).

%% One node by number, like iface.nodesByNum[num]: {ok, Node} | error
node(C, Num) ->
    case [N || #{num := X} = N <- nodes(C), X =:= Num] of
        [Node] -> {ok, Node};
        [] -> error
    end.

%% All 8 channel slots: [#{index, role, settings}], full maps (with
%% defaults), like node.channels.
channels(C) ->
    maps:get(channels, info(C)).

%% One config section, full map: config(C, lora) is
%% node.localConfig.lora.
config(C, Section) ->
    maps:get(Section, maps:get(config, info(C)), #{}).

%% One module config section: module_config(C, mqtt).
module_config(C, Section) ->
    maps:get(Section, maps:get(module_config, info(C)), #{}).

%% DeviceMetadata (firmware_version, hw_model, ...)
metadata(C) ->
    maps:get(metadata, info(C)).

%%====================================================================
%% Sending
%%====================================================================

%% Opts for every send: to (node number, default broadcast),
%% channel (0), want_ack (false), want_response (false), hop_limit
%% (the radio's lora.hop_limit). Each returns the packet id.

%% iface.sendText(text, destinationId=..., channelIndex=..., wantAck=...)
send_text(C, Text, Opts) ->
    send_data(C, 'TEXT_MESSAGE_APP', unicode:characters_to_binary(Text), Opts).

%% iface.sendData(pb, destinationId=..., portNum=...)
%% Payload: a binary, or {MsgName, Map} to encode with mt_pb.
send_data(C, Port, {MsgName, Map}, Opts) ->
    send_data(C, Port, encode(Map, MsgName), Opts);
send_data(C, Port, Payload, Opts) when is_binary(Payload) ->
    call(C, {send, Port, Payload, Opts}).

%% iface.sendPosition(latitude=..., longitude=..., altitude=...)
%% Opts: lat, lon (degrees), alt (m), plus the send options. Zero (or
%% missing) values are left out, as in Python.
send_position(C, Opts) ->
    Pos = maps:from_list(
            [{K, V} || {K, V} <- [{latitude_i, degrees_i(maps:get(lat, Opts, 0))},
                                  {longitude_i, degrees_i(maps:get(lon, Opts, 0))},
                                  {altitude, round(maps:get(alt, Opts, 0))}],
                       V =/= 0]),
    send_data(C, 'POSITION_APP', {position, Pos}, Opts).

%% iface.sendTelemetry(destinationId, wantResponse, channelIndex, telemetryType)
%% Type: device_metrics (filled from our own node, as Python does) |
%% environment_metrics | air_quality_metrics | power_metrics | local_stats
%% (sent empty: as a request, they ask for that kind).
send_telemetry(C, Type, Opts) ->
    Metrics = case Type of
                  device_metrics ->
                      Info = info(C),
                      My = maps:get(my_num, Info),
                      case [N || #{num := X} = N <- maps:get(nodes, Info), X =:= My] of
                          [#{device_metrics := DM}] -> DM;
                          _ -> #{}
                      end;
                  _ ->
                      #{}
              end,
    send_data(C, 'TELEMETRY_APP',
              {telemetry, #{time => erlang:system_time(second), Type => Metrics}},
              Opts).

%% iface.sendTraceRoute(dest, hopLimit, channelIndex=...)
send_traceroute(C, Dest, HopLimit) ->
    send_data(C, 'TRACEROUTE_APP', {route_discovery, #{}},
              #{to => Dest, hop_limit => HopLimit, want_response => true}).

%% An AdminMessage to our own radio, as node._sendAdmin does for the
%% local node: #{set_channel => Channel}, #{set_config => #{lora => ...}},
%% #{get_device_metadata_request => true}, ...
%% The radio trusts its own client connection: no session key needed.
admin(C, Admin) ->
    Info = info(C),
    send_data(C, 'ADMIN_APP', {admin_message, Admin},
              #{to => maps:get(my_num, Info),
                channel => admin_index(Info),
                want_ack => true,
                want_response => true}).

%%====================================================================
%% Receiving (in the process that called connect/1)
%%====================================================================

%% The next packet: {packet, P} | closed | timeout
next(C, Timeout) ->
    receive
        {mtc, C, packet, P} -> {packet, P};
        {mtc, C, closed, _} -> closed
    after Timeout ->
        timeout
    end.

%% Wait for the answer to request Id on Port (the packet whose
%% decoded.request_id is Id): {ok, P} | {error, Reason} (a routing error
%% for Id: NO_RESPONSE, MAX_RETRANSMIT, ...) | timeout | closed.
%% Other packets that arrive meanwhile are dropped.
reply(C, Id, Port, Timeout) ->
    Deadline = deadline(Timeout),
    wait(C, Deadline,
         fun(#{decoded := #{request_id := R, portnum := P}} = Pkt)
               when R =:= Id, P =:= Port ->
                 {ok, Pkt};
            (#{decoded := #{request_id := R, routing := Routing}}) when R =:= Id ->
                 case maps:get(error_reason, Routing, 'NONE') of
                     'NONE' -> skip;
                     Error -> {error, Error}
                 end;
            (_) ->
                 skip
         end).

%% Wait for the ACK of packet Id (sent with want_ack): ok | {error,
%% Reason} | timeout | closed. Other packets are dropped.
ack(C, Id, Timeout) ->
    wait(C, deadline(Timeout),
         fun(#{decoded := #{request_id := R, routing := Routing}}) when R =:= Id ->
                 case maps:get(error_reason, Routing, 'NONE') of
                     'NONE' -> ok;
                     Error -> {error, Error}
                 end;
            (_) ->
                 skip
         end).

%% A point in time Ms milliseconds from now (infinity stays infinity),
%% and the milliseconds left until it: for loops that stop after a while.
deadline(infinity) -> infinity;
deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.

left(infinity) -> infinity;
left(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

wait(C, Deadline, Match) ->
    case next(C, left(Deadline)) of
        {packet, P} ->
            case Match(P) of
                skip -> wait(C, Deadline, Match);
                Result -> Result
            end;
        Other ->
            Other
    end.

%%====================================================================
%% Node numbers and names
%%====================================================================

%% The -d option of an example as a node number. Raises
%% error({missing_option, "-d NODE"}) when it was not given.
dest(C, Opts) ->
    case maps:find(dest, Opts) of
        {ok, Dest} -> node_num(C, Dest);
        error -> error({missing_option, "-d NODE"})
    end.

%% A destination as the examples take it -> node number:
%%   1623194643 | "1623194643" | "!60c0ffee" | "^all" | a long or short name
%% Names are looked up in the radio's node database. Raises
%% error({unknown_node, Dest}) when nothing matches.
node_num(_C, Num) when is_integer(Num) ->
    Num;
node_num(C, Dest) when is_binary(Dest) ->
    node_num(C, unicode:characters_to_list(Dest));
node_num(_C, Dest) when Dest =:= "^all"; Dest =:= "all"; Dest =:= "broadcast" ->
    ?BROADCAST;
node_num(C, [$! | Hex] = Dest) ->
    try list_to_integer(Hex, 16)
    catch error:badarg -> node_by_name(C, Dest)
    end;
node_num(C, Dest) ->
    try list_to_integer(Dest)
    catch error:badarg -> node_by_name(C, Dest)
    end.

node_by_name(C, Dest) ->
    Want = string:casefold(unicode:characters_to_binary(Dest)),
    Match = [Num || #{num := Num} = N <- nodes(C),
                    lists:member(Want, [string:casefold(get(N, [user, K], <<>>))
                                        || K <- [long_name, short_name]])],
    case Match of
        [Num | _] -> Num;
        [] -> error({unknown_node, Dest})
    end.

%% 1623194643 -> <<"!60c0ffee">>
node_id(Num) ->
    iolist_to_binary(io_lib:format("!~8.16.0b", [Num band 16#FFFFFFFF])).

%% The long name of a node, else its id. C may be a client or info(C).
name(_C, ?BROADCAST) ->
    <<"^all">>;
name(C, Num) when is_pid(C) ->
    name(info(C), Num);
name(#{nodes := Nodes}, Num) ->
    case [get(N, [user, long_name], <<>>) || #{num := X} = N <- Nodes, X =:= Num] of
        [Name] when Name =/= <<>> -> Name;
        _ -> node_id(Num)
    end.

%% The channel admin messages use: the one named "admin", else 0
%% (node._getAdminChannelIndex).
admin_index(#{channels := Channels}) ->
    case [I || #{index := I, settings := #{name := <<"admin">>}} <- Channels] of
        [I | _] -> I;
        [] -> 0
    end.

%%====================================================================
%% Maps
%%====================================================================

%% get(P, [decoded, telemetry, device_metrics], #{}): follow a path of
%% keys, like packet.get("decoded", {}).get("telemetry", {}) in Python.
get(Map, [], _Default) ->
    Map;
get(Map, [Key | Rest], Default) when is_map(Map) ->
    case Map of
        #{Key := V} -> get(V, Rest, Default);
        _ -> Default
    end;
get(_Other, _Path, Default) ->
    Default.

%% A Data map: add the decoded payload under the key Python uses
%% (text, position, user, telemetry, routing, traceroute, admin, ...).
decode_app(#{payload := Payload} = Data) ->
    case app(maps:get(portnum, Data, 'UNKNOWN_APP')) of
        none ->
            Data;
        {Key, text} ->
            Data#{Key => Payload};
        {position, position} ->
            try
                Data#{position => degrees(compact(decode(Payload, position), position))}
            catch
                _:_ -> Data#{decode_error => position}
            end;
        {Key, MsgName} ->
            try
                Data#{Key => compact(decode(Payload, MsgName), MsgName)}
            catch
                _:_ -> Data#{decode_error => MsgName}
            end
    end;
decode_app(Data) ->
    Data.

%% Like Python's _fixupPosition: latitude and longitude in degrees next
%% to latitude_i and longitude_i.
degrees(Pos) ->
    maps:merge(Pos,
               maps:from_list([{K, maps:get(KI, Pos) / 10000000}
                               || {K, KI} <- [{latitude, latitude_i}, {longitude, longitude_i}],
                                  maps:is_key(KI, Pos)])).

app('TEXT_MESSAGE_APP') -> {text, text};
app('RANGE_TEST_APP') -> {text, text};
app('DETECTION_SENSOR_APP') -> {text, text};
app('ALERT_APP') -> {text, text};
app('POSITION_APP') -> {position, position};
app('NODEINFO_APP') -> {user, user};
app('TELEMETRY_APP') -> {telemetry, telemetry};
app('ROUTING_APP') -> {routing, routing};
app('TRACEROUTE_APP') -> {traceroute, route_discovery};
app('ADMIN_APP') -> {admin, admin_message};
app('WAYPOINT_APP') -> {waypoint, waypoint};
app('NEIGHBORINFO_APP') -> {neighborinfo, neighbor_info};
app('PAXCOUNTER_APP') -> {paxcounter, paxcount};
app('STORE_FORWARD_APP') -> {store_forward, store_and_forward};
app('MAP_REPORT_APP') -> {map_report, map_report};
app(_) -> none.

%% Leave out the fields that have their default value (0, false, <<>>,
%% [], the first enum value), recursively, as protobuf's MessageToDict
%% does for Python.
compact(Map, MsgName) ->
    lists:foldl(fun compact_field/2, Map, mt_pb:find_msg_def(MsgName)).

compact_field(#{fields := Alternatives}, Acc) ->
    %% a oneof: at most one alternative is present
    lists:foldl(
      fun(#{name := N, type := T}, A) ->
              case A of
                  #{N := V} -> A#{N := compact_value(T, V)};
                  _ -> A
              end
      end,
      Acc,
      Alternatives);
compact_field(#{name := N, type := T, occurrence := Occurrence}, Acc) ->
    case Acc of
        #{N := V} ->
            case Occurrence of
                defaulty ->
                    case is_default(T, V) of
                        true -> maps:remove(N, Acc);
                        false -> Acc#{N := compact_value(T, V)}
                    end;
                repeated when V =:= [] ->
                    maps:remove(N, Acc);
                repeated ->
                    Acc#{N := [compact_value(T, X) || X <- V]};
                _ ->
                    Acc#{N := compact_value(T, V)}
            end;
        _ ->
            Acc
    end.

compact_value({msg, MsgName}, V) when is_map(V) -> compact(V, MsgName);
compact_value(_Type, V) -> V.

is_default({enum, E}, V) -> V =:= mt_pb:enum_symbol_by_value(E, 0);
is_default({msg, _}, _V) -> false;
is_default(bool, V) -> V =:= false;
is_default(string, V) -> V =:= <<>>;
is_default(bytes, V) -> V =:= <<>>;
is_default(_Number, V) -> V == 0.

%% mt_pb:encode_msg / decode_msg
encode(Map, MsgName) ->
    mt_pb:encode_msg(Map, MsgName).

decode(Bin, MsgName) ->
    mt_pb:decode_msg(Bin, MsgName).

%% A value as text, the way Python's print() shows it: names without
%% quotes, text as text, other bytes as base64, numbers as numbers.
show(V) when is_atom(V) -> atom_to_binary(V);
show(V) when is_float(V) -> float_to_binary(V, [short]);
show(V) when is_binary(V) -> json_term(V);
show(V) -> io_lib:format("~p", [V]).

%% Pretty JSON (iodata) of a packet, node or any map from here, like
%% json.dumps(packet, indent=2). Bytes that are not text are written as
%% "base64:...".
json(Term) ->
    json:format(json_term(Term)).

json_term(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_term(V)} || {K, V} <- maps:to_list(Map)]);
json_term(List) when is_list(List) ->
    [json_term(X) || X <- List];
json_term(Bin) when is_binary(Bin) ->
    case is_text(Bin) of
        true -> Bin;
        false -> <<"base64:", (base64:encode(Bin))/binary>>
    end;
json_term(Tuple) when is_tuple(Tuple) ->
    iolist_to_binary(io_lib:format("~p", [Tuple]));
json_term(Other) ->
    Other.

json_key(K) when is_integer(K) -> integer_to_binary(K);
json_key(K) -> K.

is_text(Bin) ->
    case unicode:characters_to_list(Bin) of
        Chars when is_list(Chars) -> io_lib:printable_unicode_list(Chars);
        _ -> false
    end.

%%====================================================================
%% Framing (the stream API)
%%====================================================================

frame(Payload) ->
    Len = iolist_size(Payload),
    true = Len =< ?MAX_FRAME,
    [<<16#94, 16#C3, Len:16>>, Payload].

%% Buffer -> {[Payload], Rest}. Bytes outside frames are skipped.
unframe(Buf) ->
    unframe(Buf, []).

unframe(<<16#94, 16#C3, Len:16, Rest/binary>> = Buf, Acc) when Len =< ?MAX_FRAME ->
    case Rest of
        <<Payload:Len/binary, Tail/binary>> -> unframe(Tail, [Payload | Acc]);
        _ -> {lists:reverse(Acc), Buf}
    end;
unframe(<<16#94, 16#C3, _:16, Rest/binary>>, Acc) ->
    unframe(<<16#C3, Rest/binary>>, Acc);
unframe(<<16#94>> = Buf, Acc) ->
    {lists:reverse(Acc), Buf};
unframe(<<16#94, 16#C3>> = Buf, Acc) ->
    {lists:reverse(Acc), Buf};
unframe(<<16#94, 16#C3, _>> = Buf, Acc) ->
    {lists:reverse(Acc), Buf};
unframe(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
unframe(<<_, Rest/binary>>, Acc) ->
    unframe(Rest, Acc).

%%====================================================================
%% The client process
%%====================================================================

call(C, Request) ->
    Ref = monitor(process, C),
    C ! {call, self(), Ref, Request},
    receive
        {Ref, Result} ->
            demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, C, Reason} ->
            error({radio_closed, Reason})
    after 10000 ->
        demonitor(Ref, [flush]),
        error({radio_timeout, Request})
    end.

init(Owner, Ref, Opts) ->
    Host = maps:get(host, Opts, "localhost"),
    Port = maps:get(port, Opts, ?PORT),
    case gen_tcp:connect(Host, Port, [binary, {active, true}, {nodelay, true}], 10000) of
        {ok, Sock} ->
            ConfigId = rand:uniform(16#7FFFFFFF),
            ok = to_radio(Sock, #{want_config_id => ConfigId}),
            erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
            loop(#st{owner = Owner, ref = Ref, sock = Sock, config_id = ConfigId});
        {error, Reason} ->
            Owner ! {Ref, {error, Reason}}
    end.

loop(#st{sock = Sock, owner = Owner} = St) ->
    receive
        {tcp, Sock, Data} ->
            {Frames, Rest} = unframe(<<(St#st.buf)/binary, Data/binary>>),
            St2 = lists:foldl(fun from_radio/2, St#st{buf = Rest}, Frames),
            loop(St2);
        {tcp_closed, Sock} ->
            closed(St, tcp_closed);
        {tcp_error, Sock, Reason} ->
            closed(St, Reason);
        heartbeat ->
            ok = to_radio(Sock, #{heartbeat => #{}}),
            erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
            loop(St);
        {call, From, Tag, close} ->
            _ = to_radio(Sock, #{disconnect => true}),
            gen_tcp:close(Sock),
            From ! {Tag, ok};
        {call, From, Tag, Request} ->
            From ! {Tag, handle_call(Request, St)},
            loop(St);
        {'EXIT', Owner, _} ->
            gen_tcp:close(Sock)
    end.

closed(#st{ready = true, owner = Owner}, Reason) ->
    Owner ! {mtc, self(), closed, Reason};
closed(#st{owner = Owner, ref = Ref}, Reason) ->
    Owner ! {Ref, {error, Reason}}.

handle_call(info, St) ->
    #{my_num => maps:get(my_node_num, St#st.my_info, 0),
      my_info => St#st.my_info,
      nodes => [N || {_, N} <- lists:sort(maps:to_list(St#st.nodes))],
      channels => [Ch || {_, Ch} <- lists:sort(maps:to_list(St#st.channels))],
      config => St#st.config,
      module_config => St#st.module_config,
      metadata => St#st.metadata};
handle_call({send, Port, Payload, Opts}, #st{sock = Sock, config = Config}) ->
    Id = maps:get(id, Opts, rand:uniform(16#FFFFFFFE)),
    DefaultHops = case maps:get(hop_limit, maps:get(lora, Config, #{}), 0) of
                      0 -> 3;
                      H -> H
                  end,
    Packet = #{to => maps:get(to, Opts, ?BROADCAST),
               id => Id,
               channel => maps:get(channel, Opts, 0),
               hop_limit => maps:get(hop_limit, Opts, DefaultHops),
               want_ack => maps:get(want_ack, Opts, false),
               decoded => #{portnum => Port,
                            payload => Payload,
                            want_response => maps:get(want_response, Opts, false)}},
    case to_radio(Sock, #{packet => Packet}) of
        ok -> Id;
        {error, Reason} -> error({send_failed, Reason})
    end.

to_radio(Sock, ToRadio) ->
    gen_tcp:send(Sock, frame(encode(ToRadio, to_radio))).

%% One FromRadio from the radio
from_radio(Bin, St) ->
    try decode(Bin, from_radio) of
        FromRadio -> from_radio_variant(FromRadio, St)
    catch
        _:_ -> St
    end.

from_radio_variant(#{my_info := MyInfo}, St) ->
    St#st{my_info = MyInfo};
from_radio_variant(#{node_info := Info}, St) ->
    Node = case compact(Info, node_info) of
               #{position := Pos} = N -> N#{position := degrees(Pos)};
               N -> N
           end,
    St#st{nodes = (St#st.nodes)#{maps:get(num, Info) => Node}};
from_radio_variant(#{config := Config}, St) ->
    St#st{config = maps:merge(St#st.config, Config)};
from_radio_variant(#{moduleConfig := Config}, St) ->
    St#st{module_config = maps:merge(St#st.module_config, Config)};
from_radio_variant(#{channel := Channel}, St) ->
    St#st{channels = (St#st.channels)#{maps:get(index, Channel) => Channel}};
from_radio_variant(#{metadata := Metadata}, St) ->
    St#st{metadata = Metadata};
from_radio_variant(#{config_complete_id := Id}, #st{config_id = Id, owner = Owner, ref = Ref} = St) ->
    Owner ! {Ref, ready},
    St#st{ready = true};
from_radio_variant(#{packet := Raw}, St) ->
    P = packet(Raw),
    St2 = St#st{nodes = heard(P, St#st.nodes)},
    case St#st.ready of
        true -> St#st.owner ! {mtc, self(), packet, P};
        false -> ok
    end,
    St2;
from_radio_variant(_Other, St) ->
    St.

packet(Raw) ->
    P = compact(Raw, mesh_packet),
    P2 = P#{from_id => node_id(maps:get(from, P, 0)),
            to_id => node_id(maps:get(to, P, 0))},
    case P2 of
        #{decoded := Data} -> P2#{decoded := decode_app(Data)};
        _ -> P2
    end.

%% Keep the node database up to date, as the Python interface does.
heard(#{from := From} = P, Nodes) ->
    Node0 = maps:get(From, Nodes, #{num => From}),
    Node1 = maps:merge(Node0,
                       maps:from_list(
                         [{K, V} || {K, V} <- [{last_heard, maps:get(rx_time, P, undefined)},
                                               {snr, maps:get(rx_snr, P, undefined)},
                                               {hops_away, hops(P)}],
                                    V =/= undefined])),
    Node2 = case maps:get(decoded, P, #{}) of
                #{user := User} -> Node1#{user => User};
                #{position := Pos} -> Node1#{position => Pos};
                #{telemetry := #{device_metrics := DM}} -> Node1#{device_metrics => DM};
                _ -> Node1
            end,
    Nodes#{From => Node2};
heard(_P, Nodes) ->
    Nodes.

hops(#{hop_start := Start} = P) -> Start - maps:get(hop_limit, P, 0);
hops(_P) -> undefined.

degrees_i(Degrees) ->
    trunc(Degrees * 10000000).
