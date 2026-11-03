%% Router and registry, fed directly (no sockets).
%% The test process is both the connector (uplinks) and the registry's
%% notify target (node updates).
-module(lora_mesh_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

-define(FROM, 16#0A0B0C0D).

router_test_() ->
    [{"two bridges, one publish, best copy first", with(fun dedup/0)},
     {"late copy only updates heard_by", with(fun late_copy/0)},
     {"packet id 0 is not deduplicated", with(fun id_zero/0)},
     {"nodeinfo, position and telemetry fill the registry", with(fun registry/0)},
     {"node database from a bridge seeds the registry", with(fun node_info/0)}].

%% Start the components inside the test's own process, so their
%% messages reach it, and stop them afterwards.
with(Test) ->
    fun() ->
            Pids = setup(),
            try Test()
            after cleanup(Pids)
            end
    end.

setup() ->
    {ok, Scope} = pg:start_link(?PG_SCOPE),
    {ok, Reg} = lora_mesh_registry:start_link(#{notify => self()}),
    {ok, Router} = lora_mesh_router:start_link(#{dedup_ms => 100,
                                                 subscriber => self()}),
    [Router, Reg, Scope].

cleanup(Pids) ->
    lora_mesh_fake_node:stop(Pids),
    flush().

dedup() ->
    P = fun(Snr) -> lora_mesh_fake_node:text_packet(?FROM, 7, Snr, <<"hi">>) end,
    ok = lora_mesh_router:uplink(home, P(2.5)),
    ok = lora_mesh_router:uplink(hill, P(9.0)),
    ok = lora_mesh_router:uplink(town, P(-4.0)),
    Rx = receive {uplink, R} -> R after 1000 -> error(no_uplink) end,
    ?assertMatch(#mesh_rx{from = <<"!0a0b0c0d">>,
                          text = <<"hi">>,
                          bridges = [hill, home, town],
                          rxq = #mesh_rxq{rx_snr = 9.0}},
                 Rx),
    receive {uplink, _} -> error(published_twice) after 300 -> ok end,
    ?assertMatch(#{published := 1, duplicates := 2},
                 lora_mesh_router:stats()),
    {ok, Node} = wait_node(?FROM, fun(N) -> map_size(N#mesh_node.heard_by) =:= 3 end),
    ?assertEqual([hill, home, town], lists:sort(maps:keys(Node#mesh_node.heard_by))).

late_copy() ->
    P = fun(Snr) -> lora_mesh_fake_node:text_packet(?FROM, 8, Snr, <<"hi">>) end,
    ok = lora_mesh_router:uplink(home, P(2.5)),
    receive {uplink, #mesh_rx{bridges = [home]}} -> ok after 1000 -> error(no_uplink) end,
    ok = lora_mesh_router:uplink(hill, P(9.0)),     % window already closed
    receive {uplink, _} -> error(published_twice) after 300 -> ok end,
    ?assertMatch(#{published := 1, late := 1}, lora_mesh_router:stats()),
    {ok, _} = wait_node(?FROM, fun(N) -> is_map_key(hill, N#mesh_node.heard_by) end).

id_zero() ->
    P = lora_mesh_fake_node:text_packet(?FROM, 0, 1.0, <<"no id">>),
    ok = lora_mesh_router:uplink(home, P),
    ok = lora_mesh_router:uplink(hill, P),
    [receive {uplink, #mesh_rx{text = <<"no id">>}} -> ok after 1000 -> error(no_uplink) end
     || _ <- [1, 2]],
    ok.

registry() ->
    User = meshtastic_pb:encode_msg(#user{long_name = <<"Hill top">>,
                                          short_name = <<"HILL">>,
                                          hw_model = 'HELTEC_V3'}),
    Pos = meshtastic_pb:encode_msg(#position{latitude_i = 241477000,
                                             longitude_i = 1206736000,
                                             altitude = 85}),
    Tel = meshtastic_pb:encode_msg(#telemetry{variant =
                                                  {device_metrics,
                                                   #device_metrics{battery_level = 87,
                                                                   voltage = 4.05}}}),
    App = fun(Id, Port, Payload) ->
                  lora_mesh_fake_node:app_packet(?FROM, Id, 5.0, Port, Payload)
          end,
    ok = lora_mesh_router:uplink(home, App(11, 'NODEINFO_APP', User)),
    ok = lora_mesh_router:uplink(home, App(12, 'POSITION_APP', Pos)),
    ok = lora_mesh_router:uplink(home, App(13, 'TELEMETRY_APP', Tel)),
    {ok, Node} = wait_node(?FROM, fun(N) -> N#mesh_node.battery_level =:= 87 end),
    ?assertMatch(#mesh_node{id = <<"!0a0b0c0d">>,
                            long_name = <<"Hill top">>,
                            short_name = <<"HILL">>,
                            hw_model = 'HELTEC_V3'},
                 Node),
    #mesh_position{latitude = Lat, longitude = Lon, altitude = 85} = Node#mesh_node.position,
    ?assert(abs(Lat - 24.1477) < 1.0e-6),
    ?assert(abs(Lon - 120.6736) < 1.0e-6),
    ?assert(abs(Node#mesh_node.voltage - 4.05) < 1.0e-6),
    %% none of these is a text message
    receive {uplink, _} -> error(unexpected_uplink) after 200 -> ok end.

node_info() ->
    ok = lora_mesh_router:node_info(home,
                                    #node_info{num = 16#11223344,
                                               user = #user{long_name = <<"Market">>},
                                               last_heard = 1793170000}),
    {ok, Node} = wait_node(16#11223344, fun(_) -> true end),
    ?assertMatch(#mesh_node{id = <<"!11223344">>,
                            long_name = <<"Market">>,
                            last_heard = 1793170000},
                 Node).

%% Wait for the registry's {node, ...} notification that satisfies Pred.
wait_node(Num, Pred) ->
    receive
        {node, #mesh_node{num = Num} = N} ->
            case Pred(N) of
                true -> {ok, N};
                false -> wait_node(Num, Pred)
            end
    after 1000 ->
        error({no_node_update, Num})
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
