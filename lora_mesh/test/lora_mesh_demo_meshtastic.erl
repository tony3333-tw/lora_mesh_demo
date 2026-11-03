%%
%% A live demo of lora_mesh with Meshtastic only: fake Meshtastic nodes,
%% real lora_mesh, real MQTT broker. Teammates watch and reply from their
%% laptops with the Python client (examples/demo_bot.py).
%%
%%   rebar3 as test shell --start-clean
%%   1> lora_mesh_demo_meshtastic:start().
%%   ...
%%   2> lora_mesh_demo_meshtastic:stop().
%%
%% Options (all optional):
%%   lora_mesh_demo_meshtastic:start(#{mqtt_host => "localhost",
%%                                     mqtt_port => 1883,
%%                                     prefix => <<"mesh">>,
%%                                     every_ms => 8000}).
%%
%% The picture it imitates: two Heltec V4 boards with Wi-Fi on, "home"
%% and "hill", each a lora_mesh bridge (TCP 4403), both inside one
%% Meshtastic mesh of four nodes:
%%
%%   Hill top  !0a0b0c0d  a Heltec V4 on a hill, sends temperatures
%%   School    !0c0c0c0c  a RAK4631, sends direct messages to home
%%   Farm      !0b0b0b0b  a sensor, reports its battery (telemetry)
%%   Tracker   !0d0d0d0d  a T1000-E tracker, reports its position
%%   Dave      !0e0e0e0e  joins later (NODEINFO)
%%
%% Every few seconds something happens on air; anything a teammate sends
%% is printed here, and a node that gets a direct message answers
%% "got it: ...".
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

-record(state, {
    home            :: pid(),
    hill            :: pid(),
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
    {Home, HomePort} = start_board(home, ?HOME, <<"Home gw">>),
    {Hill, HillPort} = start_board(hill, ?HILL, <<"Hill gw">>),

    ok = load(lora_mesh),
    application:set_env(lora_mesh, role, full),
    application:set_env(lora_mesh, dedup_ms, 200),
    application:set_env(lora_mesh, bridges,
                        [#{id => home, host => "127.0.0.1", port => HomePort},
                         #{id => hill, host => "127.0.0.1", port => HillPort}]),
    application:set_env(lora_mesh, mqtt,
                        #{host => maps:get(mqtt_host, Opts, "localhost"),
                          port => maps:get(mqtt_port, Opts, 1883),
                          prefix => maps:get(prefix, Opts, <<"mesh">>)}),
    {ok, _} = application:ensure_all_started(lora_mesh),

    EveryMs = maps:get(every_ms, Opts, 8000),
    say("Meshtastic demo running: bridges home and hill (two Heltec V4 with Wi-Fi)"),
    say("a message every ~p s; lora_mesh_demo_meshtastic:stop() to end", [EveryMs div 1000]),
    erlang:send_after(3000, self(), tick),
    {ok, #state{home = Home,
                hill = Hill,
                every_ms = EveryMs}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(tick, #state{tick = N, every_ms = EveryMs} = State) ->
    State2 = scene(N rem 5, State),
    maybe_dave(N, State2),
    erlang:send_after(EveryMs, self(), tick),
    {noreply, State2#state{tick = N + 1}};

% a teammate's message reached one of the boards (lora_mesh sent it)
handle_info({board_got, Board, #mesh_packet{to = To,
                                            payload_variant = {decoded, #data{portnum = 'TEXT_MESSAGE_APP',
                                                                              payload = Text}}}},
            State) ->
    case To of
        ?MESH_BROADCAST ->
            say("<- teammate sent to everyone through ~p: ~ts", [Board, Text]);
        _ ->
            say("<- teammate sent to ~ts through ~p: ~ts", [name(To), Board, Text]),
            Pid = board_pid(Board, State),
            Gateway = board_num(Board),
            later(fun() ->
                          text(Pid, To, Gateway, <<"got it: ", Text/binary>>, 7.5, 1)
                  end)
    end,
    {noreply, State};

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{home = Home, hill = Hill}) ->
    application:stop(lora_mesh),
    exit(Home, shutdown),
    exit(Hill, shutdown),
    say("demo stopped"),
    ok.

%%====================================================================
%% The script
%%====================================================================

% Hill top broadcasts a temperature; BOTH boards hear the same packet
% (same sender, same packet id), so lora_mesh publishes it once
scene(0, #state{home = Home, hill = Hill} = State) ->
    Text = fmt("temperature ~.1f C", [20 + rand:uniform() * 8]),
    Id = new_id(),
    push(Home, text_packet(?HILL_TOP, ?MESH_BROADCAST, Id, Text, 3.0, 1)),
    push(Hill, text_packet(?HILL_TOP, ?MESH_BROADCAST, Id, Text, 9.25, 0)),
    say("-> Hill top to everyone, heard by home (SNR 3.0, 1 hop) and hill (SNR 9.25, direct): ~ts", [Text]),
    State;

% the farm sensor reports its battery (TELEMETRY_APP, not text)
scene(1, #state{home = Home, battery = Battery} = State) ->
    Battery2 = max(Battery - rand:uniform(3), 15),
    Metrics = #device_metrics{battery_level = Battery2,
                              voltage = 3.3 + Battery2 / 100},
    Payload = meshtastic_pb:encode_msg(#telemetry{time = now_s(),
                                                  variant = {device_metrics, Metrics}},
                                       telemetry),
    push(Home, app_packet(?FARM, 'TELEMETRY_APP', Payload, 5.5, 1)),
    say("-> Farm reports battery ~p% (telemetry; watch mesh/node/!0b0b0b0b)", [Battery2]),
    State#state{battery = Battery2};

% the tracker moves (POSITION_APP)
scene(2, #state{hill = Hill, lat = Lat, lon = Lon} = State) ->
    Lat2 = Lat + 300 + rand:uniform(400),
    Lon2 = Lon + 200 + rand:uniform(400),
    Payload = meshtastic_pb:encode_msg(#position{latitude_i = Lat2,
                                                 longitude_i = Lon2,
                                                 altitude = 85,
                                                 time = now_s()},
                                       position),
    push(Hill, app_packet(?TRACKER, 'POSITION_APP', Payload, 6.0, 2)),
    say("-> Tracker at ~.5f, ~.5f (position; watch mesh/node/!0d0d0d0d)",
        [Lat2 * 1.0e-7, Lon2 * 1.0e-7]),
    State#state{lat = Lat2, lon = Lon2};

% the school sends a direct message to the home board
scene(3, #state{home = Home} = State) ->
    Text = <<"school gate closed">>,
    push(Home, text_packet(?SCHOOL, ?HOME, new_id(), Text, 4.25, 1)),
    say("-> School to home gw (direct): ~ts", [Text]),
    State;

% a question for the Python bot
scene(4, #state{hill = Hill} = State) ->
    push(Hill, text_packet(?HILL_TOP, ?MESH_BROADCAST, new_id(), <<"ping?">>, 8.0, 0)),
    say("-> Hill top to everyone: ping?  (a bot may answer)"),
    State.

% once, early on: a new node introduces itself (NODEINFO_APP)
maybe_dave(5, #state{home = Home}) ->
    User = #user{id = <<"!0e0e0e0e">>,
                 long_name = <<"Dave">>,
                 short_name = <<"DAVE">>,
                 hw_model = 'HELTEC_V4'},
    push(Home, app_packet(?DAVE, 'NODEINFO_APP', meshtastic_pb:encode_msg(User, user), 4.0, 1)),
    say("-> a new node, Dave, introduces itself (watch mesh/node/!0e0e0e0e)");
maybe_dave(_N, _State) ->
    ok.

%%====================================================================
%% A fake Heltec V4 with Wi-Fi: the Meshtastic TCP API on a free port
%%====================================================================

%% -> {Pid, Port}
start_board(Name, MyNum, LongName) ->
    Demo = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Pid = spawn_link(fun() -> board_accept(Listen, Name, MyNum, LongName, Demo) end),
    {Pid, Port}.

board_accept(Listen, Name, MyNum, LongName, Demo) ->
    {ok, Sock} = gen_tcp:accept(Listen),
    ok = inet:setopts(Sock, [{active, true}]),
    board_loop(Listen, Sock, Name, MyNum, LongName, Demo, <<>>).

board_loop(Listen, Sock, Name, MyNum, LongName, Demo, Buf) ->
    receive
        {tcp, Sock, Data} ->
            {Frames, Rest} = lora_mesh_frame:decode(<<Buf/binary, Data/binary>>),
            [board_frame(Sock, Name, MyNum, LongName, Demo, F) || F <- Frames],
            board_loop(Listen, Sock, Name, MyNum, LongName, Demo, Rest);
        {tcp_closed, Sock} ->
            board_accept(Listen, Name, MyNum, LongName, Demo);
        {push, Variant} ->
            board_send(Sock, Variant),
            board_loop(Listen, Sock, Name, MyNum, LongName, Demo, Buf)
    end.

%% what the firmware does when an app (here lora_mesh) asks for its config:
%% my_info, its node database, then config_complete_id
board_frame(Sock, Name, MyNum, LongName, Demo, Frame) ->
    case meshtastic_pb:decode_msg(Frame, to_radio) of
        #to_radio{payload_variant = {want_config_id, Id}} ->
            board_send(Sock, {my_info, #my_node_info{my_node_num = MyNum}}),
            [board_send(Sock, {node_info, Info}) || Info <- node_db(MyNum, LongName)],
            board_send(Sock, {config_complete_id, Id});
        #to_radio{payload_variant = {packet, Packet}} ->
            Demo ! {board_got, Name, Packet};
        _ ->
            ok          % heartbeats
    end.

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

text(Board, From, To, Text, Snr, Hops) ->
    push(Board, text_packet(From, To, new_id(), Text, Snr, Hops)).

push(Board, Packet) ->
    Board ! {push, {packet, Packet}}.

new_id() ->
    rand:uniform(16#7fffffff).

%%====================================================================
%% Helpers
%%====================================================================

board_pid(home, #state{home = Pid}) -> Pid;
board_pid(hill, #state{hill = Pid}) -> Pid.

board_num(home) -> ?HOME;
board_num(hill) -> ?HILL.

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
