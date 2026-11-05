%%
%% A live demo of lora_mesh without radios: fake radios, real lora_mesh,
%% real MQTT broker. Teammates watch and reply from their own laptops
%% with the Python client.
%%
%%   rebar3 as test shell --start-clean
%%   1> lora_mesh_demo:start().
%%   ...
%%   2> lora_mesh_demo:stop().
%%
%% Options (all optional):
%%   lora_mesh_demo:start(#{mqtt_host => "localhost",
%%                          mqtt_port => 1883,
%%                          prefix => <<"mesh">>,
%%                          every_ms => 8000}).
%%
%% What runs:
%%   - two fake MeshCore companions, "field" and "barn", built from the
%%     firmware source (lora_mesh_fake_companion), with the same contacts:
%%     Alice, Bob, Pump (a sensor) and Ridge (a repeater);
%%   - one fake Meshtastic node, "home", that knows Hill top, School and
%%     Tower (a router);
%%
%% Paths (0.3.2): field reaches Alice through the repeater Ridge (d1),
%% Pump's reports pass Ridge and an unknown repeater (77), Bob is in range
%% of barn; Hill top's broadcasts are relayed by Tower. lora_mesh puts
%% these in every message's rxq (path / relay) and every node's routes.
%%   - lora_mesh with three bridges to them, publishing to your broker.
%%
%% Every few seconds a scripted message arrives on air: direct messages,
%% a channel message heard by both MeshCore radios (published once), a
%% Meshtastic broadcast, a "ping?" for a Python bot to answer, and once a
%% new node, Dave, appears. Anything a teammate sends is printed here and
%% answered by the node it was sent to ("got it: ...").
%%
-module(lora_mesh_demo).
-behaviour(gen_server).

-export([start/0]).
-export([start/1]).
-export([stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

%% a 32-byte public key starting First, First+1, ... (prefix @a1a2a3a4a5a6 for 16#a1)
-define(KEY(First, N), <<(First),
                         (First + 1),
                         (First + 2),
                         (First + 3),
                         (First + 4),
                         (First + 5),
                         (N):(26 * 8)>>).
-define(ALICE, ?KEY(16#a1, 0)).
-define(BOB, ?KEY(16#b1, 1)).
-define(PUMP, ?KEY(16#c1, 2)).
-define(RIDGE, ?KEY(16#d1, 3)).
-define(DAVE, ?KEY(16#e1, 4)).

-define(HILL_TOP, 16#0a0b0c0d).
-define(SCHOOL, 16#0c0c0c0c).
-define(HOME_NODE, 16#0600d1e5).
-define(TOWER, 16#0d0d0dee).
-define(R_RIDGE, <<16#d1>>).            % path hashes: first key byte
-define(R_FAR, <<16#77>>).              % a repeater no radio knows

-define(POLL_MS, 1000).

-record(state, {
    field       :: pid(),
    barn        :: pid(),
    tastic      :: pid(),
    every_ms    :: pos_integer(),
    tick = 0    :: non_neg_integer(),
    seen = #{}  :: #{pid() => non_neg_integer()}}).

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
    {ok, Field} = lora_mesh_fake_companion:start(#{name => <<"Field gw">>,
                                                   pub_key => ?KEY(16#5e, 10),
                                                   contacts => contacts(field)}),
    {ok, Barn} = lora_mesh_fake_companion:start(#{name => <<"Barn gw">>,
                                                  pub_key => ?KEY(16#6e, 11),
                                                  contacts => contacts(barn)}),
    {ok, FieldPort} = lora_mesh_fake_companion:port(Field),
    {ok, BarnPort} = lora_mesh_fake_companion:port(Barn),
    {Tastic, TasticPort} = start_tastic(),

    ok = load(lora_mesh),
    application:set_env(lora_mesh, role, full),
    application:set_env(lora_mesh, dedup_ms, 200),
    application:set_env(lora_mesh, bridges,
                        [#{id => home, host => "127.0.0.1", port => TasticPort},
                         #{id => field, type => meshcore, transport => tcp,
                           host => "127.0.0.1", port => FieldPort},
                         #{id => barn, type => meshcore, transport => tcp,
                           host => "127.0.0.1", port => BarnPort}]),
    application:set_env(lora_mesh, mqtt,
                        #{host => maps:get(mqtt_host, Opts, "localhost"),
                          port => maps:get(mqtt_port, Opts, 1883),
                          prefix => maps:get(prefix, Opts, <<"mesh">>)}),
    {ok, _} = application:ensure_all_started(lora_mesh),

    EveryMs = maps:get(every_ms, Opts, 8000),
    say("lora_mesh demo running: bridges home (Meshtastic), field and barn (MeshCore)"),
    say("a message every ~p s; lora_mesh_demo:stop() to end", [EveryMs div 1000]),
    erlang:send_after(3000, self(), tick),
    erlang:send_after(?POLL_MS, self(), poll),
    {ok, #state{field = Field,
                barn = Barn,
                tastic = Tastic,
                every_ms = EveryMs}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(tick, #state{tick = N, every_ms = EveryMs} = State) ->
    scene(N rem 5, N, State),
    erlang:send_after(EveryMs, self(), tick),
    {noreply, State#state{tick = N + 1}};

% what teammates sent through the MeshCore radios
handle_info(poll, #state{field = Field, barn = Barn, seen = Seen} = State) ->
    Seen2 = lists:foldl(fun(Radio, Acc) -> new_sends(Radio, Acc) end,
                        Seen,
                        [{field, Field}, {barn, Barn}]),
    erlang:send_after(?POLL_MS, self(), poll),
    {noreply, State#state{seen = Seen2}};

% what teammates sent through the Meshtastic node
handle_info({tastic_sent, #mesh_packet{to = To, payload_variant = {decoded, #data{payload = Text}}}},
            #state{tastic = Tastic} = State) ->
    case To of
        ?MESH_BROADCAST ->
            say("<- teammate sent to everyone on Meshtastic: ~ts", [Text]);
        _ ->
            say("<- teammate sent to ~ts on Meshtastic: ~ts", [tastic_name(To), Text]),
            reply_later(fun() ->
                                tastic_say(Tastic, To, ?HOME_NODE, <<"got it: ", Text/binary>>)
                        end)
    end,
    {noreply, State};

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{field = Field, barn = Barn, tastic = Tastic}) ->
    application:stop(lora_mesh),
    lora_mesh_fake_companion:stop(Field),
    lora_mesh_fake_companion:stop(Barn),
    exit(Tastic, shutdown),
    say("demo stopped"),
    ok.

%%====================================================================
%% The script
%%====================================================================

%% The same contacts on both radios, each with its own route to them
%% (out_path: [] = in range; none given = no route yet, the radio floods)
contacts(Radio) ->
    Routes = case Radio of
                 field -> #{ridge => [], alice => [?R_RIDGE], pump => [?R_RIDGE, ?R_FAR]};
                 %% first hop first: barn -> 77 -> Ridge -> Pump (Pump's reports
                 %% come the other way: Ridge, then 77)
                 barn -> #{ridge => [], bob => [], pump => [?R_FAR, ?R_RIDGE]}
             end,
    Route = fun(Who) ->
                    case Routes of
                        #{Who := Path} -> #{out_path => Path};
                        #{} -> #{}
                    end
            end,
    [lora_mesh_fake_companion:contact(?RIDGE, <<"Ridge">>,
                                      maps:merge(#{type => 2, lastmod => 1}, Route(ridge))),
     lora_mesh_fake_companion:contact(?ALICE, <<"Alice">>,
                                      maps:merge(#{lat => 24147700, lon => 120673600, lastmod => 2},
                                                 Route(alice))),
     lora_mesh_fake_companion:contact(?BOB, <<"Bob">>,
                                      maps:merge(#{lat => 24150200, lon => 120680100, lastmod => 3},
                                                 Route(bob))),
     lora_mesh_fake_companion:contact(?PUMP, <<"Pump">>,
                                      maps:merge(#{type => 4, lastmod => 4}, Route(pump)))].

% Alice reports soil moisture, by a direct message to the field radio
scene(0, N, #state{field = Field} = State) ->
    Text = fmt("soil moisture ~p%", [28 + rand:uniform(10)]),
    lora_mesh_fake_companion:receive_dm(Field, ?ALICE, Text,
                                        #{snr => snr(4, 9), path => [?R_RIDGE], sender_time => now_s()}),
    say("-> Alice to field gw (direct, via Ridge): ~ts", [Text]),
    maybe_dave(N, State);

% Bob speaks on the channel; both radios hear him, lora_mesh publishes once
scene(1, _N, #state{field = Field, barn = Barn}) ->
    Text = <<"rain starting at the north gate">>,
    Time = now_s(),
    lora_mesh_fake_companion:receive_channel(Field, 0, <<"Bob">>, Text,
                                             #{snr => 3.5, path => [?R_RIDGE], sender_time => Time}),
    %% barn hears Bob himself, then Ridge's rebroadcast (dropped as a copy)
    lora_mesh_fake_companion:receive_channel(Barn, 0, <<"Bob">>, Text,
                                             #{snr => 8.0, path => [], later_copies => [[?R_RIDGE]],
                                               sender_time => Time}),
    say("-> Bob on channel 0, heard by field via Ridge (SNR 3.5) and barn directly (SNR 8.0): ~ts",
        [Text]);

% Hill top broadcasts a temperature on Meshtastic
scene(2, _N, #state{tastic = Tastic}) ->
    Text = fmt("temperature ~.1f C", [20 + rand:uniform() * 8]),
    tastic_say(Tastic, ?HILL_TOP, ?MESH_BROADCAST, Text),
    say("-> Hill top (Meshtastic, to everyone, relayed by Tower): ~ts", [Text]);

% the pump controller, a sensor node, reports
scene(3, _N, #state{barn = Barn}) ->
    Text = fmt("pump on, flow ~p L/min", [10 + rand:uniform(5)]),
    lora_mesh_fake_companion:receive_dm(Barn, ?PUMP, Text,
                                        #{snr => snr(-2, 3), path => [?R_RIDGE, ?R_FAR],
                                          sender_time => now_s()}),
    say("-> Pump to barn gw (direct, 2 hops: Ridge, then repeater 77): ~ts", [Text]);

% a question a Python bot can answer (examples/demo_bot.py)
scene(4, _N, #state{field = Field}) ->
    lora_mesh_fake_companion:receive_channel(Field, 0, <<"Bob">>, <<"ping?">>,
                                             #{snr => snr(2, 6), path => [?R_RIDGE], sender_time => now_s()}),
    say("-> Bob on channel 0 (via Ridge): ping?  (a bot may answer)").

% once, early on: a new node appears
maybe_dave(5, #state{field = Field}) ->
    lora_mesh_fake_companion:hear_advert(Field, ?DAVE, #{name => <<"Dave">>,
                                                          lat => 24152000,
                                                          lon => 120676000}),
    say("-> a new node, Dave, advertises itself (watch mesh/node/@e1e2e3e4e5e6)");
maybe_dave(_N, _State) ->
    ok.

%%====================================================================
%% Answering teammates
%%====================================================================

new_sends({Name, Radio}, Seen) ->
    Sent = lora_mesh_fake_companion:sent(Radio),
    Old = maps:get(Radio, Seen, 0),
    New = lists:nthtail(Old, Sent),
    lists:foreach(fun(S) -> answer(Name, Radio, S) end, New),
    Seen#{Radio => length(Sent)}.

answer(Name, Radio, {dm, PrefixHex, Text, Ack}) ->
    case key_by_prefix(PrefixHex) of
        {ok, Key, Who} ->
            say("<- teammate sent to ~ts through ~p: ~ts", [Who, Name, Text]),
            reply_later(fun() ->
                                lora_mesh_fake_companion:confirm(Radio, Ack),
                                lora_mesh_fake_companion:receive_dm(Radio, Key,
                                                                    <<"got it: ", Text/binary>>,
                                                                    #{snr => snr(3, 8),
                                                                      path => [?R_RIDGE],
                                                                      sender_time => now_s()})
                        end);
        error ->
            say("<- teammate sent to @~ts through ~p: ~ts", [PrefixHex, Name, Text])
    end;
answer(Name, _Radio, {channel, Idx, AirText}) ->
    say("<- teammate sent on channel ~p through ~p: ~ts", [Idx, Name, AirText]).

key_by_prefix(PrefixHex) ->
    Keys = [{?ALICE, <<"Alice">>}, {?BOB, <<"Bob">>}, {?PUMP, <<"Pump">>},
            {?RIDGE, <<"Ridge">>}, {?DAVE, <<"Dave">>}],
    case [{K, W} || {<<P:6/binary, _/binary>> = K, W} <- Keys,
                    binary:encode_hex(P, lowercase) =:= PrefixHex] of
        [{Key, Who}] -> {ok, Key, Who};
        [] -> error
    end.

reply_later(Fun) ->
    spawn(fun() ->
                  timer:sleep(1500),
                  Fun()
          end).

%%====================================================================
%% A fake Meshtastic node with Wi-Fi (TCP 4403 protocol)
%%====================================================================

start_tastic() ->
    Demo = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Pid = spawn_link(fun() -> tastic_accept(Listen, Demo) end),
    {Pid, Port}.

tastic_accept(Listen, Demo) ->
    {ok, Sock} = gen_tcp:accept(Listen),
    ok = inet:setopts(Sock, [{active, true}]),
    tastic_loop(Listen, Sock, Demo, <<>>).

tastic_loop(Listen, Sock, Demo, Buf) ->
    receive
        {tcp, Sock, Data} ->
            {Frames, Rest} = lora_mesh_frame:decode(<<Buf/binary, Data/binary>>),
            [tastic_frame(Sock, Demo, F) || F <- Frames],
            tastic_loop(Listen, Sock, Demo, Rest);
        {tcp_closed, Sock} ->
            tastic_accept(Listen, Demo);
        {push, Variant} ->
            tastic_send(Sock, Variant),
            tastic_loop(Listen, Sock, Demo, Buf)
    end.

tastic_frame(Sock, Demo, Frame) ->
    case meshtastic_pb:decode_msg(Frame, to_radio) of
        #to_radio{payload_variant = {want_config_id, Id}} ->
            tastic_send(Sock, {my_info, #my_node_info{my_node_num = ?HOME_NODE}}),
            tastic_send(Sock, {node_info, tastic_node(?HILL_TOP, <<"Hill top">>, <<"HILL">>,
                                                      241477000, 1206736000)}),
            tastic_send(Sock, {node_info, tastic_node(?SCHOOL, <<"School">>, <<"SCHL">>,
                                                      241460000, 1206790000)}),
            Tower = tastic_node(?TOWER, <<"Tower">>, <<"TOWR">>, 241500000, 1206750000),
            tastic_send(Sock, {node_info, Tower#node_info{user = (Tower#node_info.user)#user{role = 'ROUTER'}}}),
            tastic_send(Sock, {config_complete_id, Id});
        #to_radio{payload_variant = {packet, Packet}} ->
            Demo ! {tastic_sent, Packet};
        _ ->
            ok
    end.

tastic_node(Num, Long, Short, Lat, Lon) ->
    #node_info{num = Num,
               user = #user{long_name = Long,
                            short_name = Short,
                            hw_model = 'HELTEC_V4'},
               position = #position{latitude_i = Lat,
                                    longitude_i = Lon},
               last_heard = now_s()}.

tastic_send(Sock, Variant) ->
    Bin = meshtastic_pb:encode_msg(#from_radio{payload_variant = Variant}),
    gen_tcp:send(Sock, lora_mesh_frame:encode(Bin)).

%% one hop (hop_start 3, hop_limit 2), rebroadcast by Tower: relay_node
%% is the last byte of its node number
tastic_say(Tastic, From, To, Text) ->
    Packet = lora_mesh_fake_node:text_packet(From, rand:uniform(16#7fffffff), snr(2, 9), Text),
    Tastic ! {push, {packet, Packet#mesh_packet{to = To, relay_node = ?TOWER band 16#ff}}}.

tastic_name(?HILL_TOP) -> <<"Hill top">>;
tastic_name(?SCHOOL) -> <<"School">>;
tastic_name(?TOWER) -> <<"Tower">>;
tastic_name(Num) -> lora_mesh_node:node_id(Num).

%%====================================================================
%% Helpers
%%====================================================================

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

snr(Low, High) ->
    Low + rand:uniform(High - Low + 1) - 1 + 0.25 * (rand:uniform(4) - 1).

now_s() ->
    erlang:system_time(second).

fmt(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).

say(Text) ->
    say(Text, []).

say(Format, Args) ->
    {_, {H, M, S}} = calendar:local_time(),
    io:format("~2..0w:~2..0w:~2..0w [demo] " ++ Format ++ "~n", [H, M, S | Args]).
