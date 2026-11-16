%%
%% A live demo of lora_mesh with Meshtastic only: fake Meshtastic boards,
%% real lora_mesh, real MQTT broker. Teammates watch and reply from their
%% laptops with the Python client (examples/demo_bot.py).
%%
%% One machine (both boards, everything in one Erlang VM):
%%
%%   rebar3 as test shell --start-clean
%%   1> lora_mesh_demo_meshtastic:start().
%%   2> lora_mesh_demo_meshtastic:stop().
%%
%% Two machines, rpi4-a and rpi4-b (same cookie, e.g. in one VLAN):
%%
%%   rpi4-a$ rebar3 as test shell --start-clean --sname lora_mesh --setcookie demo
%%   1> lora_mesh_demo_meshtastic:start(#{boards => [home]}).
%%
%%   rpi4-b$ rebar3 as test shell --start-clean --sname lora_mesh --setcookie demo
%%   1> lora_mesh_demo_meshtastic:start(#{role => bridge,
%%                                        boards => [hill],
%%                                        connect => ['lora_mesh@rpi4-a']}).
%%
%%   rpi4-a runs lora_mesh in role full (router, registry, MQTT) with board
%%   home, and directs the script. rpi4-b runs lora_mesh in role bridge with
%%   board hill; lora_mesh_cluster connects it to rpi4-a and pg lets its
%%   bridge reach the router there. The director on rpi4-a drives boards on
%%   both machines through pg, so a packet "heard by both boards" really
%%   arrives through two machines and is merged by the one router.
%%
%% Options (all optional):
%%   role      => full | bridge          lora_mesh's role here (default full)
%%   boards    => [home, hill]           fake boards started here (default both)
%%   connect   => [Node]                 Erlang nodes to stay connected to
%%   director  => true | false           run the script here (default: role full)
%%   mqtt_host => "localhost", mqtt_port => 1883, prefix => <<"mesh">>
%%   every_ms  => 8000
%%
%% The mesh it imitates, around the two boards:
%%
%%   Hill top  !0a0b0c0d  a Heltec V4 on a hill, sends temperatures
%%   School    !0c0c0c0c  a RAK4631, sends direct messages to home
%%   Farm      !0b0b0b0b  a sensor, reports its battery (telemetry)
%%   Tracker   !0d0d0d0d  a T1000-E tracker, reports its position
%%   Dave      !0e0e0e0e  joins later (NODEINFO)
%%
%% Every few seconds something happens on air; anything a teammate sends
%% is printed by the director, and a node that gets a direct message
%% answers "got it: ...".
%%
-module(lora_mesh_demo_meshtastic).
-behaviour(gen_server).

-export([start/0]).
-export([start/1]).
-export([stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

%% the two gateway boards (each one a lora_mesh bridge)
-define(HOME, 16#0600d1e5).
-define(HILL, 16#0600d1e6).

%% the mesh
-define(HILL_TOP, 16#0a0b0c0d).
-define(SCHOOL, 16#0c0c0c0c).
-define(FARM, 16#0b0b0b0b).
-define(TRACKER, 16#0d0d0d0d).
-define(DAVE, 16#0e0e0e0e).

%% pg groups (in lora_mesh's scope) that let the parts find each other
%% across machines
-define(PG_DEMO_BOARD(Name), {demo_board, Name}).
-define(PG_DEMO_DIRECTOR, demo_director).

-record(state, {
    boards          :: [{atom(), pid()}],     % started here
    director        :: boolean(),
    every_ms        :: pos_integer(),
    tick = 0        :: non_neg_integer(),
    battery = 97    :: non_neg_integer(),
    lat = 241477000 :: integer(),
    lon = 1206736000 :: integer()}).

%%====================================================================
%% API
%%====================================================================

start() ->
    start(#{}).

start(Opts) ->
    gen_server:start({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:stop(?MODULE).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Role = maps:get(role, Opts, full),
    Names = maps:get(boards, Opts, [home, hill]),
    Director = maps:get(director, Opts, Role =:= full),

    %% the fake boards first: lora_mesh's bridges need their ports
    Started = [{Name, start_board(Name)} || Name <- Names],

    ok = load(lora_mesh),
    application:set_env(lora_mesh, role, Role),
    application:set_env(lora_mesh, dedup_ms, 200),
    application:set_env(lora_mesh, connect, maps:get(connect, Opts, [])),
    application:set_env(lora_mesh, bridges,
                        [#{id => Name, host => "127.0.0.1", port => Port}
                         || {Name, {_Pid, Port}} <- Started]),
    application:set_env(lora_mesh, mqtt,
                        #{host => maps:get(mqtt_host, Opts, "localhost"),
                          port => maps:get(mqtt_port, Opts, 1883),
                          prefix => maps:get(prefix, Opts, <<"mesh">>)}),
    {ok, _} = application:ensure_all_started(lora_mesh),

    %% lora_mesh started the pg scope: now the parts can be found
    Boards = [{Name, Pid} || {Name, {Pid, _Port}} <- Started],
    [ok = pg:join(?PG_SCOPE, ?PG_DEMO_BOARD(Name), Pid) || {Name, Pid} <- Boards],
    EveryMs = maps:get(every_ms, Opts, 8000),
    say("lora_mesh role ~p on ~p, boards here: ~p", [Role, node(), Names]),
    case Director of
        true ->
            ok = pg:join(?PG_SCOPE, ?PG_DEMO_DIRECTOR, self()),
            say("directing the script: a message every ~p s; "
                "lora_mesh_demo_meshtastic:stop() to end", [EveryMs div 1000]),
            erlang:send_after(3000, self(), tick);
        false ->
            say("boards only: the director on another machine drives them")
    end,
    {ok, #state{boards = Boards,
                director = Director,
                every_ms = EveryMs}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(tick, #state{tick = N, every_ms = EveryMs} = State) ->
    State2 = scene(N rem 6, State),
    maybe_dave(N),
    erlang:send_after(EveryMs, self(), tick),
    {noreply, State2#state{tick = N + 1}};

% a teammate's message reached one of the boards (lora_mesh sent it)
handle_info({board_got, Board, #mesh_packet{to = To,
                                            payload_variant = {decoded, #data{portnum = 'TEXT_MESSAGE_APP',
                                                                              payload = Text}}}},
            #state{director = Director} = State) ->
    case {To, Director} of
        {?MESH_BROADCAST, _} ->
            say("<- teammate sent to everyone through ~p: ~ts", [Board, Text]);
        {_, true} ->
            say("<- teammate sent to ~ts through ~p: ~ts", [name(To), Board, Text]),
            later(fun() ->
                          push(Board, text_packet(To, board_num(Board), new_id(),
                                                  <<"got it: ", Text/binary>>, 7.5, 1))
                  end);
        {_, false} ->
            say("<- teammate sent to ~ts through ~p: ~ts (the director answers)",
                [name(To), Board, Text])
    end,
    {noreply, State};

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{boards = Boards}) ->
    application:stop(lora_mesh),
    [exit(Pid, shutdown) || {_Name, Pid} <- Boards],
    say("demo stopped"),
    ok.

%%====================================================================
%% The script (run by the director)
%%====================================================================

% Hill top broadcasts a temperature; BOTH boards hear the same packet
% (same sender, same packet id), so lora_mesh publishes it once, even
% when the boards are on two machines
scene(0, State) ->
    Text = fmt("temperature ~.1f C", [20 + rand:uniform() * 8]),
    Id = new_id(),
    push(home, text_packet(?HILL_TOP, ?MESH_BROADCAST, Id, Text, 3.0, 1)),
    push(hill, text_packet(?HILL_TOP, ?MESH_BROADCAST, Id, Text, 9.25, 0)),
    say("-> Hill top to everyone, heard by home (SNR 3.0, 1 hop) and hill (SNR 9.25, direct): ~ts", [Text]),
    State;

% the farm sensor reports its battery (TELEMETRY_APP, not text)
scene(1, #state{battery = Battery} = State) ->
    Battery2 = max(Battery - rand:uniform(3), 15),
    Metrics = #device_metrics{battery_level = Battery2,
                              voltage = 3.3 + Battery2 / 100},
    Payload = meshtastic_pb:encode_msg(#telemetry{time = now_s(),
                                                  variant = {device_metrics, Metrics}},
                                       telemetry),
    push(home, app_packet(?FARM, 'TELEMETRY_APP', Payload, 5.5, 1)),
    say("-> Farm reports battery ~p% (telemetry; watch mesh/node/!0b0b0b0b)", [Battery2]),
    State#state{battery = Battery2};

% the tracker moves (POSITION_APP)
scene(2, #state{lat = Lat, lon = Lon} = State) ->
    Lat2 = Lat + 300 + rand:uniform(400),
    Lon2 = Lon + 200 + rand:uniform(400),
    Payload = meshtastic_pb:encode_msg(#position{latitude_i = Lat2,
                                                 longitude_i = Lon2,
                                                 altitude = 85,
                                                 time = now_s()},
                                       position),
    push(hill, app_packet(?TRACKER, 'POSITION_APP', Payload, 6.0, 2)),
    say("-> Tracker at ~.5f, ~.5f (position; watch mesh/node/!0d0d0d0d)",
        [Lat2 * 1.0e-7, Lon2 * 1.0e-7]),
    State#state{lat = Lat2, lon = Lon2};

% the school sends a direct message to the home board
scene(3, State) ->
    Text = <<"school gate closed">>,
    push(home, text_packet(?SCHOOL, ?HOME, new_id(), Text, 4.25, 1)),
    say("-> School to home gw (direct): ~ts", [Text]),
    State;

% a question for the Python bot
scene(4, State) ->
    push(hill, text_packet(?HILL_TOP, ?MESH_BROADCAST, new_id(), <<"ping?">>, 8.0, 0)),
    say("-> Hill top to everyone: ping?  (a bot may answer)"),
    State;

% each board's radio reports its own statistics to lora_mesh, as
% firmware does every few minutes (LOCAL_STATS telemetry, from itself;
% watch mesh/packet/!0600d1e5)
scene(5, State) ->
    [push(Board, local_stats_packet(Board)) || Board <- [home, hill]],
    say("-> home and hill gw report their local stats (telemetry; watch mesh/packet/)"),
    State.

% once, early on: a new node introduces itself (NODEINFO_APP)
maybe_dave(5) ->
    User = #user{id = <<"!0e0e0e0e">>,
                 long_name = <<"Dave">>,
                 short_name = <<"DAVE">>,
                 hw_model = 'HELTEC_V4'},
    push(home, app_packet(?DAVE, 'NODEINFO_APP', meshtastic_pb:encode_msg(User, user), 4.0, 1)),
    say("-> a new node, Dave, introduces itself (watch mesh/node/!0e0e0e0e)");
maybe_dave(_N) ->
    ok.

%% Hand a packet to a board "on air", wherever it runs (pg finds it on
%% this machine or another one).
push(Board, Packet) ->
    case pg:get_members(?PG_SCOPE, ?PG_DEMO_BOARD(Board)) of
        [Pid | _] ->
            Pid ! {push, {packet, Packet}};
        [] ->
            say("   (board ~p is not up, so it heard nothing)", [Board])
    end.

%%====================================================================
%% A fake Heltec V4 with Wi-Fi: the Meshtastic TCP API on a free port
%%====================================================================

%% -> {Pid, Port}
start_board(Name) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Pid = spawn_link(fun() -> board_accept(Listen, Name) end),
    {Pid, Port}.

board_accept(Listen, Name) ->
    {ok, Sock} = gen_tcp:accept(Listen),
    ok = inet:setopts(Sock, [{active, true}]),
    board_loop(Listen, Sock, Name, <<>>).

board_loop(Listen, Sock, Name, Buf) ->
    receive
        {tcp, Sock, Data} ->
            {Frames, Rest} = lora_mesh_frame:decode(<<Buf/binary, Data/binary>>),
            [board_frame(Sock, Name, F) || F <- Frames],
            board_loop(Listen, Sock, Name, Rest);
        {tcp_closed, Sock} ->
            board_accept(Listen, Name);
        {push, Variant} ->
            board_send(Sock, Variant),
            board_loop(Listen, Sock, Name, Buf)
    end.

%% what the firmware does when an app (here lora_mesh) asks for its config:
%% my_info, metadata, its node database, channels, config, module
%% config, then config_complete_id
board_frame(Sock, Name, Frame) ->
    case meshtastic_pb:decode_msg(Frame, to_radio) of
        #to_radio{payload_variant = {want_config_id, Id}} ->
            MyNum = board_num(Name),
            board_send(Sock, {my_info, #my_node_info{my_node_num = MyNum,
                                                     reboot_count = 3,
                                                     min_app_version = 30200,
                                                     nodedb_count = 6}}),
            board_send(Sock, {metadata, #device_metadata{firmware_version = <<"2.7.15.demo">>,
                                                         device_state_version = 24,
                                                         hasWifi = true,
                                                         hasBluetooth = true,
                                                         hasPKC = true,
                                                         role = 'CLIENT',
                                                         hw_model = 'HELTEC_V4'}}),
            [board_send(Sock, {node_info, Info}) || Info <- node_db(MyNum, board_name(Name))],
            [board_send(Sock, {channel, Channel}) || Channel <- channels()],
            [board_send(Sock, {config, #config{payload_variant = Section}}) || Section <- config()],
            [board_send(Sock, {moduleConfig, #module_config{payload_variant = Section}})
             || Section <- module_config()],
            board_send(Sock, {config_complete_id, Id});
        #to_radio{payload_variant = {packet, Packet}} ->
            report({board_got, Name, Packet});
        _ ->
            ok          % heartbeats
    end.

%% tell the director (on any machine), and this machine's demo if it
%% is not the director
report(Msg) ->
    Directors = pg:get_members(?PG_SCOPE, ?PG_DEMO_DIRECTOR),
    [Pid ! Msg || Pid <- Directors],
    case whereis(?MODULE) of
        undefined -> ok;
        Local ->
            case lists:member(Local, Directors) of
                true -> ok;
                false -> Local ! Msg
            end
    end.

%% the default channel LongFast (key "AQ==") and a private "team" channel
channels() ->
    [#channel{index = 0,
              role = 'PRIMARY',
              settings = #channel_settings{psk = <<1>>}},
     #channel{index = 1,
              role = 'SECONDARY',
              settings = #channel_settings{name = <<"team">>,
                                           psk = binary:copy(<<16#5a>>, 16)}}
     | [#channel{index = I, role = 'DISABLED', settings = #channel_settings{}}
        || I <- lists:seq(2, 7)]].

%% a Taiwan radio on the default preset; Wi-Fi on (the password is
%% hidden in mesh/bridge/<id>/info unless show_secrets is on)
config() ->
    [{device, #config_device_config{role = 'CLIENT'}},
     {lora, #config_lo_ra_config{use_preset = true,
                                 modem_preset = 'LONG_FAST',
                                 region = 'TW',
                                 hop_limit = 3,
                                 tx_enabled = true,
                                 tx_power = 27}},
     {network, #config_network_config{wifi_enabled = true,
                                      wifi_ssid = <<"farm-wifi">>,
                                      wifi_psk = <<"not-for-mqtt">>}}].

module_config() ->
    [{mqtt, #module_config_mqtt_config{enabled = false}},
     {telemetry, #module_config_telemetry_config{device_update_interval = 900}}].

local_stats_packet(Board) ->
    Stats = #local_stats{uptime_seconds = 3600 + rand:uniform(600),
                         channel_utilization = 5.0 + rand:uniform(50) / 10,
                         air_util_tx = 0.5 + rand:uniform(10) / 10,
                         num_packets_tx = 40 + rand:uniform(20),
                         num_packets_rx = 300 + rand:uniform(100),
                         num_packets_rx_bad = rand:uniform(5),
                         num_online_nodes = 5,
                         num_total_nodes = 6},
    Payload = meshtastic_pb:encode_msg(#telemetry{time = now_s(),
                                                  variant = {local_stats, Stats}},
                                       telemetry),
    Num = board_num(Board),
    (packet(Num, ?MESH_BROADCAST, new_id(), 'TELEMETRY_APP', Payload, 0.0, 0))
        #mesh_packet{rx_rssi = 0, hop_start = 0, hop_limit = 0}.

node_db(MyNum, LongName) ->
    [node(MyNum, LongName, <<"GW">>, 'HELTEC_V4', 'CLIENT', 101, undefined),
     node(?HILL_TOP, <<"Hill top">>, <<"HILL">>, 'HELTEC_V4', 'ROUTER', 88, {241477000, 1206736000}),
     node(?SCHOOL, <<"School">>, <<"SCHL">>, 'RAK4631', 'CLIENT', 74, {241460000, 1206790000}),
     node(?FARM, <<"Farm">>, <<"FARM">>, 'HELTEC_RC52', 'SENSOR', 97, {241430000, 1206700000}),
     node(?TRACKER, <<"Tracker">>, <<"TRAK">>, 'TRACKER_T1000_E', 'TRACKER', 63, undefined)].

node(Num, Long, Short, Hw, Role, Battery, Position) ->
    #node_info{num = Num,
               user = #user{id = lora_mesh_node:node_id(Num),
                            long_name = Long,
                            short_name = Short,
                            hw_model = Hw,
                            role = Role},
               position = case Position of
                              undefined -> undefined;
                              {Lat, Lon} -> #position{latitude_i = Lat, longitude_i = Lon}
                          end,
               device_metrics = #device_metrics{battery_level = Battery},
               last_heard = now_s()}.

board_send(Sock, Variant) ->
    Bin = meshtastic_pb:encode_msg(#from_radio{payload_variant = Variant}),
    gen_tcp:send(Sock, lora_mesh_frame:encode(Bin)).

%%====================================================================
%% Packets
%%====================================================================

text_packet(From, To, Id, Text, Snr, Hops) ->
    packet(From, To, Id, 'TEXT_MESSAGE_APP', Text, Snr, Hops).

app_packet(From, Port, Payload, Snr, Hops) ->
    packet(From, ?MESH_BROADCAST, new_id(), Port, Payload, Snr, Hops).

%% Hops = how many times it was relayed before the board heard it
packet(From, To, Id, Port, Payload, Snr, Hops) ->
    #mesh_packet{from = From,
                 to = To,
                 id = Id,
                 rx_snr = Snr,
                 rx_rssi = round(-100 + Snr * 3) - 8 * Hops,
                 hop_start = 3,
                 hop_limit = 3 - Hops,
                 payload_variant = {decoded, #data{portnum = Port,
                                                   payload = Payload}}}.

new_id() ->
    rand:uniform(16#7fffffff).

%%====================================================================
%% Helpers
%%====================================================================

board_num(home) -> ?HOME;
board_num(hill) -> ?HILL.

board_name(home) -> <<"Home gw">>;
board_name(hill) -> <<"Hill gw">>.

name(?HILL_TOP) -> <<"Hill top">>;
name(?SCHOOL) -> <<"School">>;
name(?FARM) -> <<"Farm">>;
name(?TRACKER) -> <<"Tracker">>;
name(?DAVE) -> <<"Dave">>;
name(Num) -> lora_mesh_node:node_id(Num).

later(Fun) ->
    spawn(fun() ->
                  timer:sleep(1500),
                  Fun()
          end).

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

now_s() ->
    erlang:system_time(second).

fmt(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).

say(Text) ->
    say(Text, []).

say(Format, Args) ->
    {_, {H, M, S}} = calendar:local_time(),
    io:format("~2..0w:~2..0w:~2..0w [demo] " ++ Format ++ "~n", [H, M, S | Args]).
