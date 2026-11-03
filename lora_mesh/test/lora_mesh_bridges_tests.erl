%% Two bridges, two fake nodes, both hearing the same packet:
%% the whole stage-2 path over real TCP.
-module(lora_mesh_bridges_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

two_bridges_test_() ->
    {timeout, 15, fun two_bridges/0}.

two_bridges() ->
    {ok, Scope} = pg:start_link(?PG_SCOPE),
    {ok, Reg} = lora_mesh_registry:start_link(#{notify => self()}),
    {ok, Router} = lora_mesh_router:start_link(#{dedup_ms => 200,
                                                 subscriber => self()}),
    From = 16#0A0B0C0D,
    Info = #node_info{num = From, user = #user{long_name = <<"Hill top">>}},
    Same = fun(Snr) -> lora_mesh_fake_node:text_packet(From, 99, Snr, <<"哈囉 mesh"/utf8>>) end,
    {ok, PortA} = lora_mesh_fake_node:start(home, [{node_info, Info}, {packet, Same(3.0)}]),
    {ok, PortB} = lora_mesh_fake_node:start(hill, [{node_info, Info}, {packet, Same(8.5)}]),
    {ok, A} = lora_mesh_node:start_link(#{id => home, host => "127.0.0.1", port => PortA}),
    {ok, B} = lora_mesh_node:start_link(#{id => hill, host => "127.0.0.1", port => PortB}),

    Rx = receive {uplink, R} -> R after 5000 -> error(no_uplink) end,
    ?assertMatch(#mesh_rx{from = <<"!0a0b0c0d">>,
                          id = 99,
                          text = <<"哈囉 mesh"/utf8>>,
                          rxq = #mesh_rxq{rx_snr = 8.5},
                          bridges = [hill, home]},
                 Rx),
    receive {uplink, _} -> error(published_twice) after 500 -> ok end,

    {ok, Node} = lora_mesh_registry:lookup(From),
    ?assertEqual(<<"Hill top">>, Node#mesh_node.long_name),
    ?assertEqual([hill, home], lists:sort(maps:keys(Node#mesh_node.heard_by))),
    ?assertEqual([hill, home], lora_mesh_node:bridges()),

    lora_mesh_fake_node:stop([A, B, Router, Reg, Scope]).
