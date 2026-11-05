%%
%% mtfake: a fake Meshtastic radio on TCP, to try every example without
%% hardware (the same idea as lora_mesh's demo boards).
%%
%%   mte fake-radio                  listens on port 4403
%%   mte nodedb                      (in another terminal) talks to it
%%
%% It behaves like a radio's client API (TCP port 4403):
%%   - on want_config_id it sends my_info, its node, metadata, 8 channels,
%%     config, module config, the other nodes, then config_complete_id;
%%   - while a client is connected, the fake mesh is heard: texts,
%%     positions, telemetry, node info, neighbor info, ... (one packet
%%     every few seconds);
%%   - it answers requests the way the mesh would: ACKs (want_ack),
%%     telemetry / position / node info replies (want_response),
%%     traceroutes, a "got it: ..." answer to a direct message;
%%   - admin messages to itself change its channels and config, and it
%%     answers get_device_metadata, get_channel and get_config requests;
%%   - one client at a time: a new connection closes the previous one,
%%     as a real radio does.
%%
%% The fake mesh:
%%
%%   Pi Gateway  !1a2b3c4d   this radio
%%   Tower       !0d0d0dee   ROUTER, heard directly
%%   Barn sensor !2a2a2a2a   SENSOR, heard directly
%%   Hill top    !60c0ffee   heard through Tower (1 hop)
%%   anything else           unknown: requests to it fail (MAX_RETRANSMIT)
%%
-module(mtfake).

-export([run/1]).
-export([start/1]).
-export([stop/1]).
-export([my_num/0]).

-define(ME, 16#1a2b3c4d).
-define(TOWER, 16#0d0d0dee).
-define(BARN, 16#2a2a2a2a).
-define(HILL, 16#60c0ffee).
-define(BROADCAST, 16#FFFFFFFF).

-record(st, {
    listen,
    sock = undefined,
    buf = <<>>,
    quiet = false,
    interval,
    timer = undefined,
    step = 0,
    channels,        % index => channel
    config,          % section => map
    module_config,
    owner_key}).

my_num() ->
    ?ME.

%%====================================================================
%% Start
%%====================================================================

%% Run in the foreground (mte fake-radio). Opts: port (4403),
%% interval (ms between mesh packets, 5000), quiet (false).
run(Opts) ->
    {ok, Pid, Port} = start(Opts),
    io:format("fake radio !~8.16.0b (Pi Gateway) listening on port ~p; Ctrl-C ends~n",
              [?ME, Port]),
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    end.

%% -> {ok, Pid, Port}. Port 0 picks a free port (tests).
start(Opts) ->
    Parent = self(),
    Pid = spawn(fun() -> init(Parent, Opts) end),
    receive
        {Pid, {ok, Port}} -> {ok, Pid, Port};
        {Pid, {error, Reason}} -> error({fake_radio, Reason})
    end.

stop(Pid) ->
    exit(Pid, kill),
    ok.

init(Parent, Opts) ->
    case gen_tcp:listen(maps:get(port, Opts, 4403),
                        [binary, {active, false}, {reuseaddr, true}]) of
        {ok, Listen} ->
            {ok, Port} = inet:port(Listen),
            Parent ! {self(), {ok, Port}},
            Self = self(),
            spawn_link(fun() -> accept(Self, Listen) end),
            loop(#st{listen = Listen,
                     quiet = maps:get(quiet, Opts, false),
                     interval = maps:get(interval, Opts, 5000),
                     channels = channels(),
                     config = config(),
                     module_config = module_config()});
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept(Radio, Listen) ->
    {ok, Sock} = gen_tcp:accept(Listen),
    ok = gen_tcp:controlling_process(Sock, Radio),
    Radio ! {client, Sock},
    accept(Radio, Listen).

%%====================================================================
%% The radio
%%====================================================================

loop(#st{sock = Sock} = St) ->
    receive
        {client, New} ->
            case Sock of
                undefined ->
                    log(St, "client connected");
                _ ->
                    log(St, "new client: closing the previous connection, as a radio does"),
                    gen_tcp:close(Sock)
            end,
            ok = inet:setopts(New, [{active, true}]),
            loop(stop_timer(St#st{sock = New, buf = <<>>}));
        {tcp, Sock, Data} ->
            {Frames, Rest} = mtc:unframe(<<(St#st.buf)/binary, Data/binary>>),
            St2 = lists:foldl(fun to_radio/2, St#st{buf = Rest}, Frames),
            loop(St2);
        {tcp_closed, Sock} ->
            log(St, "client disconnected"),
            loop(stop_timer(St#st{sock = undefined}));
        {tcp_error, Sock, _} ->
            loop(stop_timer(St#st{sock = undefined}));
        mesh_tick when Sock =/= undefined ->
            St2 = mesh_tick(St),
            loop(St2#st{timer = erlang:send_after(St#st.interval, self(), mesh_tick)});
        {later, Sock, Packet} ->
            send_packet(St, Packet),
            loop(St);
        _Stale ->
            loop(St)
    end.

stop_timer(#st{timer = undefined} = St) ->
    St;
stop_timer(#st{timer = T} = St) ->
    erlang:cancel_timer(T),
    St#st{timer = undefined}.

%% One ToRadio from the client
to_radio(Bin, St) ->
    try mtc:decode(Bin, to_radio) of
        ToRadio -> to_radio_variant(ToRadio, St)
    catch
        _:_ -> St
    end.

to_radio_variant(#{want_config_id := Id}, St) ->
    log(St, "want_config_id ~p: sending config and node list", [Id]),
    Variants = [#{my_info => my_info()},
                #{node_info => node_info(?ME)},
                #{metadata => metadata()}]
        ++ [#{channel => Ch} || {_, Ch} <- lists:sort(maps:to_list(St#st.channels))]
        ++ [#{config => #{K => V}} || {K, V} <- maps:to_list(St#st.config)]
        ++ [#{moduleConfig => #{K => V}} || {K, V} <- maps:to_list(St#st.module_config)]
        ++ [#{node_info => node_info(N)} || N <- [?TOWER, ?BARN, ?HILL]]
        ++ [#{config_complete_id => Id}],
    lists:foreach(fun(V) -> from_radio(St, V) end, Variants),
    St2 = stop_timer(St),
    St2#st{timer = erlang:send_after(St#st.interval, self(), mesh_tick)};
to_radio_variant(#{packet := Packet}, St) ->
    from_client(Packet, St);
to_radio_variant(#{disconnect := true}, #st{sock = Sock} = St) ->
    log(St, "client said disconnect"),
    gen_tcp:close(Sock),
    stop_timer(St#st{sock = undefined});
to_radio_variant(_Heartbeat, St) ->
    St.

%%====================================================================
%% Packets from the client
%%====================================================================

from_client(#{to := To, id := Id, decoded := Data} = Packet, St) ->
    Port = maps:get(portnum, Data),
    WantAck = maps:get(want_ack, Packet, false),
    WantResponse = maps:get(want_response, Data, false),
    log(St, "client sent ~s to ~ts (id ~p~s~s)",
        [Port, name(To), Id, flag(WantAck, ", want_ack"), flag(WantResponse, ", want_response")]),
    if
        To =:= ?ME ->
            local(Port, Id, Data, St);
        To =:= ?BROADCAST ->
            St;
        true ->
            case lists:member(To, [?TOWER, ?BARN, ?HILL]) of
                true ->
                    remote(To, Port, Id, Data, WantAck, WantResponse, St);
                false when WantAck; WantResponse ->
                    %% nobody answers: the radio gives up after its retries
                    later(St, 2000, routing(?ME, Id, 'MAX_RETRANSMIT')),
                    St;
                false ->
                    St
            end
    end;
from_client(_Encrypted, St) ->
    St.

flag(true, Text) -> Text;
flag(false, _Text) -> "".

%% A packet to a node of the fake mesh
remote(To, Port, Id, Data, WantAck, WantResponse, St) ->
    Delay = case To of
                ?HILL -> 900;
                _ -> 300
            end,
    case WantAck of
        true -> later(St, Delay, routing(To, Id, 'NONE'));
        false -> ok
    end,
    case {Port, WantResponse} of
        {'TEXT_MESSAGE_APP', _} ->
            Text = maps:get(payload, Data),
            later(St, Delay + 700, packet(To, ?ME, 'TEXT_MESSAGE_APP',
                                          <<"got it: ", Text/binary>>, #{}));
        {'TELEMETRY_APP', true} ->
            Asked = mtc:decode(maps:get(payload, Data), telemetry),
            later(St, Delay + 400, packet(To, ?ME, 'TELEMETRY_APP',
                                          mtc:encode(telemetry(To, Asked), telemetry),
                                          #{request_id => Id}));
        {'POSITION_APP', true} ->
            later(St, Delay + 400, packet(To, ?ME, 'POSITION_APP',
                                          mtc:encode(position(To), position),
                                          #{request_id => Id}));
        {'NODEINFO_APP', true} ->
            later(St, Delay + 400, packet(To, ?ME, 'NODEINFO_APP',
                                          mtc:encode(user(To), user),
                                          #{request_id => Id}));
        {'TRACEROUTE_APP', true} ->
            later(St, Delay + 600, packet(To, ?ME, 'TRACEROUTE_APP',
                                          mtc:encode(trace(To), route_discovery),
                                          #{request_id => Id}));
        _ ->
            ok
    end,
    St.

%% Admin messages to this radio
local('ADMIN_APP', Id, Data, St) ->
    Admin = mtc:decode(maps:get(payload, Data), admin_message),
    St2 = admin(Admin, Id, St),
    later(St2, 100, routing(?ME, Id, 'NONE')),
    St2;
local(_Port, Id, _Data, St) ->
    later(St, 100, routing(?ME, Id, 'NONE')),
    St.

admin(#{set_channel := #{index := I} = Ch}, _Id, St) ->
    log(St, "admin: set channel ~p (~ts, ~s)",
        [I, mtc:get(Ch, [settings, name], <<>>), maps:get(role, Ch, 'DISABLED')]),
    St#st{channels = (St#st.channels)#{I => Ch}};
admin(#{set_config := Config}, _Id, St) ->
    [{Section, Map}] = maps:to_list(Config),
    log(St, "admin: set config ~p", [Section]),
    case Section of
        security ->
            [log(St, "  admin key ~s", [base64:encode(K)]) || K <- maps:get(admin_key, Map, [])];
        _ ->
            ok
    end,
    St#st{config = maps:merge(St#st.config, Config)};
admin(#{get_device_metadata_request := true}, Id, St) ->
    log(St, "admin: get device metadata"),
    admin_reply(St, Id, #{get_device_metadata_response => metadata()}),
    St;
admin(#{get_channel_request := N}, Id, St) ->
    log(St, "admin: get channel ~p", [N - 1]),
    admin_reply(St, Id, #{get_channel_response => maps:get(N - 1, St#st.channels)}),
    St;
admin(#{get_config_request := Type}, Id, St) ->
    Section = config_section(Type),
    log(St, "admin: get config ~p", [Section]),
    admin_reply(St, Id, #{get_config_response => #{Section => maps:get(Section, St#st.config, #{})}}),
    St;
admin(Other, _Id, St) ->
    log(St, "admin: ~p (ignored by the fake radio)", [hd(maps:keys(maps:remove(session_passkey, Other)))]),
    St.

admin_reply(St, Id, Admin) ->
    later(St, 50, packet(?ME, ?ME, 'ADMIN_APP', mtc:encode(Admin, admin_message),
                         #{request_id => Id})).

config_section('DEVICE_CONFIG') -> device;
config_section('POSITION_CONFIG') -> position;
config_section('POWER_CONFIG') -> power;
config_section('NETWORK_CONFIG') -> network;
config_section('DISPLAY_CONFIG') -> display;
config_section('LORA_CONFIG') -> lora;
config_section('BLUETOOTH_CONFIG') -> bluetooth;
config_section('SECURITY_CONFIG') -> security;
config_section(_) -> device.

%%====================================================================
%% The fake mesh talking
%%====================================================================

mesh_tick(#st{step = Step} = St) ->
    Events = [fun() -> text(?HILL, "temperature " ++ temperature() ++ " C") end,
              fun() -> app(?HILL, 'POSITION_APP', position(?HILL), position) end,
              fun() -> app(?BARN, 'TELEMETRY_APP', telemetry(?BARN, #{device_metrics => #{}}), telemetry) end,
              fun() -> app(?HILL, 'TELEMETRY_APP', telemetry(?HILL, #{environment_metrics => #{}}), telemetry) end,
              fun() -> app(?TOWER, 'NODEINFO_APP', user(?TOWER), user) end,
              fun() -> local_stats() end,
              fun() -> text(?BARN, "door opened") end,
              fun() -> app(?TOWER, 'NEIGHBORINFO_APP', neighbors(), neighbor_info) end,
              fun() -> app(?BARN, 'PAXCOUNTER_APP',
                           #{wifi => 3 + rand:uniform(5), ble => 8 + rand:uniform(9),
                             uptime => uptime()}, paxcount) end,
              fun() -> packet(?BARN, ?BROADCAST, 'RANGE_TEST_APP',
                              iolist_to_binary(["seq ", integer_to_list(Step)]), #{}) end,
              fun() -> app(?TOWER, 'STORE_FORWARD_APP',
                           #{rr => 'ROUTER_HEARTBEAT', heartbeat => #{period => 900}},
                           store_and_forward) end,
              fun() -> app(?TOWER, 'TELEMETRY_APP', telemetry(?TOWER, #{device_metrics => #{}}), telemetry) end],
    Event = lists:nth(Step rem length(Events) + 1, Events),
    send_packet(St, Event()),
    St#st{step = Step + 1}.

text(From, Text) ->
    packet(From, ?BROADCAST, 'TEXT_MESSAGE_APP', unicode:characters_to_binary(Text), #{}).

app(From, Port, Map, MsgName) ->
    packet(From, ?BROADCAST, Port, mtc:encode(Map, MsgName), #{}).

%% Our own radio's statistics (sent to the client, from itself)
local_stats() ->
    Stats = #{uptime_seconds => uptime(),
              channel_utilization => 6.5 + rand:uniform(30) / 10,
              air_util_tx => 0.9 + rand:uniform(5) / 10,
              num_packets_tx => 120 + rand:uniform(20),
              num_packets_rx => 900 + rand:uniform(80),
              num_packets_rx_bad => rand:uniform(4),
              num_online_nodes => 4,
              num_total_nodes => 4,
              num_rx_dupe => 40 + rand:uniform(10),
              num_tx_relay => 30 + rand:uniform(10),
              noise_floor => -106 - rand:uniform(4)},
    packet(?ME, ?ME, 'TELEMETRY_APP',
           mtc:encode(#{time => now_s(), local_stats => Stats}, telemetry), #{}).

routing(From, Id, Error) ->
    packet(From, ?ME, 'ROUTING_APP', mtc:encode(#{error_reason => Error}, routing),
           #{request_id => Id}).

%% A packet as the radio hands it to its client. Hill top is heard
%% through Tower (one hop, relay_node = Tower's last byte).
packet(From, To, Port, Payload, DataExtra) ->
    Hops = case From of
               ?HILL -> 1;
               _ -> 0
           end,
    Base = #{from => From,
             to => To,
             id => rand:uniform(16#FFFFFFFE),
             rx_time => now_s(),
             hop_start => 3,
             hop_limit => 3 - Hops,
             decoded => maps:merge(#{portnum => Port, payload => Payload}, DataExtra)},
    case From of
        ?ME ->
            Base;
        _ ->
            Base#{rx_snr => snr(From),
                  rx_rssi => rssi(From),
                  relay_node => case Hops of
                                    1 -> ?TOWER band 16#FF;
                                    0 -> 0
                                end}
    end.

later(#st{sock = Sock}, Ms, Packet) ->
    erlang:send_after(Ms, self(), {later, Sock, Packet}).

send_packet(St, Packet) ->
    from_radio(St, #{packet => Packet}).

from_radio(#st{sock = undefined}, _Variant) ->
    ok;
from_radio(#st{sock = Sock}, Variant) ->
    %% FromRadio = #{id => N, <variant> => Value}
    FromRadio = Variant#{id => rand:uniform(16#FFFFFF)},
    _ = gen_tcp:send(Sock, mtc:frame(mtc:encode(FromRadio, from_radio))),
    ok.

%%====================================================================
%% The fake mesh's data
%%====================================================================

my_info() ->
    #{my_node_num => ?ME,
      reboot_count => 3,
      min_app_version => 30200,
      nodedb_count => 4}.

metadata() ->
    #{firmware_version => <<"2.7.15.fake">>,
      device_state_version => 24,
      canShutdown => true,
      hasWifi => true,
      hasBluetooth => true,
      role => 'CLIENT',
      hw_model => 'HELTEC_V4',
      hasPKC => true}.

node_info(Num) ->
    Base = #{num => Num,
             user => user(Num),
             position => position(Num),
             device_metrics => device_metrics(Num),
             last_heard => now_s() - 60 * (Num rem 7)},
    case Num of
        ?ME -> Base;
        ?HILL -> Base#{snr => snr(Num), hops_away => 1};
        _ -> Base#{snr => snr(Num)}
    end.

user(Num) ->
    {Long, Short, Hw, Role} = case Num of
                                  ?ME -> {<<"Pi Gateway">>, <<"PIGW">>, 'HELTEC_V4', 'CLIENT'};
                                  ?TOWER -> {<<"Tower">>, <<"TWR">>, 'RAK4631', 'ROUTER'};
                                  ?BARN -> {<<"Barn sensor">>, <<"BARN">>, 'HELTEC_WIRELESS_TRACKER', 'SENSOR'};
                                  ?HILL -> {<<"Hill top">>, <<"HILL">>, 'HELTEC_V3', 'CLIENT'}
                              end,
    #{id => mtc:node_id(Num),
      long_name => Long,
      short_name => Short,
      macaddr => <<16#48, 16#ca, Num:32>>,
      hw_model => Hw,
      role => Role,
      public_key => crypto:hash(sha256, <<"fake key", Num:32>>)}.

position(Num) ->
    {Lat, Lon, Alt} = case Num of
                          ?ME -> {25.0330, 121.5654, 12};
                          ?TOWER -> {25.0478, 121.5170, 180};
                          ?BARN -> {25.0105, 121.5370, 20};
                          ?HILL -> {25.1693, 121.5578, 1092}
                      end,
    #{latitude_i => trunc(Lat * 10000000),
      longitude_i => trunc(Lon * 10000000),
      altitude => Alt,
      time => now_s(),
      location_source => 'LOC_INTERNAL',
      sats_in_view => 7 + rand:uniform(5),
      precision_bits => 32}.

device_metrics(Num) ->
    #{battery_level => case Num of
                           ?TOWER -> 101;     % 101 = powered
                           _ -> 60 + (Num rem 37)
                       end,
      voltage => 3.9 + (Num rem 3) / 10,
      channel_utilization => 7.5 + rand:uniform(20) / 10,
      air_util_tx => 0.5 + rand:uniform(10) / 10,
      uptime_seconds => uptime()}.

%% The answer to a telemetry request: the kind that was asked for
telemetry(_Num, #{environment_metrics := _}) ->
    #{time => now_s(),
      environment_metrics => #{temperature => list_to_float(temperature()),
                               relative_humidity => 60.0 + rand:uniform(25),
                               barometric_pressure => 1009.0 + rand:uniform(8)}};
telemetry(_Num, #{local_stats := _}) ->
    #{decoded := #{payload := Payload}} = local_stats(),
    mtc:decode(Payload, telemetry);
telemetry(Num, #{power_metrics := _}) ->
    #{time => now_s(),
      power_metrics => #{ch1_voltage => 5.1, ch1_current => 120.0 + Num rem 50}};
telemetry(Num, _DeviceMetrics) ->
    #{time => now_s(), device_metrics => device_metrics(Num)}.

neighbors() ->
    #{node_id => ?TOWER,
      last_sent_by_id => ?TOWER,
      node_broadcast_interval_secs => 900,
      neighbors => [#{node_id => ?ME, snr => 10.25},
                    #{node_id => ?BARN, snr => 6.5},
                    #{node_id => ?HILL, snr => -3.75}]}.

%% route: the nodes between us and the destination; snr in dB * 4
trace(?HILL) ->
    #{route => [?TOWER], snr_towards => [38, -14], route_back => [?TOWER], snr_back => [-12, 41]};
trace(_Direct) ->
    #{snr_towards => [snr4()], snr_back => [snr4()]}.

snr(?HILL) -> -3.0 - rand:uniform(8) / 4;
snr(?TOWER) -> 9.0 + rand:uniform(8) / 4;
snr(_) -> 5.0 + rand:uniform(12) / 4.

snr4() -> 20 + rand:uniform(20).

rssi(?HILL) -> -112 - rand:uniform(6);
rssi(_) -> -80 - rand:uniform(15).

channels() ->
    Primary = #{index => 0,
                role => 'PRIMARY',
                settings => #{psk => <<1>>,
                              name => <<>>,
                              module_settings => #{position_precision => 13}}},
    maps:from_list([{0, Primary} | [{I, #{index => I, role => 'DISABLED', settings => #{}}}
                                    || I <- lists:seq(1, 7)]]).

config() ->
    #{device => #{role => 'CLIENT', node_info_broadcast_secs => 10800},
      position => #{position_broadcast_secs => 900},
      power => #{},
      network => #{wifi_enabled => true, wifi_ssid => <<"farm-wifi">>},
      display => #{screen_on_secs => 60},
      lora => #{use_preset => true,
                modem_preset => 'LONG_FAST',
                region => 'TW',
                hop_limit => 3,
                tx_enabled => true,
                tx_power => 27},
      bluetooth => #{enabled => true, fixed_pin => 123456},
      security => #{public_key => crypto:hash(sha256, <<"fake key", ?ME:32>>),
                    admin_key => []}}.

module_config() ->
    #{mqtt => #{enabled => false, address => <<"mqtt.meshtastic.org">>,
                username => <<"meshdev">>, password => <<"large4cats">>,
                root => <<"msh/TW">>},
      telemetry => #{device_update_interval => 1800},
      neighbor_info => #{enabled => true, update_interval => 900},
      range_test => #{},
      store_forward => #{}}.

%%====================================================================
%% Helpers
%%====================================================================

temperature() ->
    float_to_list(22.0 + rand:uniform(40) / 10, [{decimals, 1}]).

uptime() ->
    {Ms, _} = erlang:statistics(wall_clock),
    3600 + Ms div 1000.

now_s() ->
    erlang:system_time(second).

name(?BROADCAST) -> <<"everyone">>;
name(Num) -> mtc:node_id(Num).

log(St, Text) ->
    log(St, Text, []).

log(#st{quiet = true}, _Format, _Args) ->
    ok;
log(#st{}, Format, Args) ->
    io:format("fake radio: " ++ Format ++ "~n", Args).
