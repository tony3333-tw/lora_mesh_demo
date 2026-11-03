%% One bridge against a fake node; the test process stands in for the router.
-module(lora_mesh_node_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

bridge_test_() ->
    {timeout, 15, fun bridge/0}.

bridge() ->
    {ok, Scope} = pg:start_link(?PG_SCOPE),
    ok = pg:join(?PG_SCOPE, ?PG_ROUTER, self()),
    Packet = lora_mesh_fake_node:text_packet(16#0A0B0C0D, 42, 6.25, <<"hi from mesh">>),
    NodeInfo = #node_info{num = 16#0A0B0C0D,
                          user = #user{long_name = <<"Hill">>, short_name = <<"HL">>}},
    {ok, Port} = lora_mesh_fake_node:start(home, [{node_info, NodeInfo},
                                                  {packet, Packet}]),
    {ok, Pid} = lora_mesh_node:start_link(#{id => home,
                                            host => "127.0.0.1",
                                            port => Port}),

    %% 1. config request first
    receive {fake_node_got, home, {want_config_id, _}} -> ok
    after 5000 -> error(no_want_config)
    end,

    %% 2. node database and packets go to the router, tagged with the bridge id
    receive {node_info, home, #node_info{num = 16#0A0B0C0D}} -> ok
    after 5000 -> error(no_node_info)
    end,
    receive {uplink, home, #mesh_packet{id = 42, rx_snr = 6.25}} -> ok
    after 5000 -> error(no_uplink)
    end,

    %% 3. the bridge is listed and reachable by id
    ?assertEqual([home], lora_mesh_node:bridges()),
    ok = lora_mesh_node:send(home, #mesh_tx{to = 16#12345678, text = "hello mesh"}),
    receive
        {fake_node_got, home, {packet, Sent}} ->
            ?assertMatch(#mesh_packet{
                            to = 16#12345678,
                            want_ack = true,
                            hop_limit = 3,
                            payload_variant =
                                {decoded,
                                 #data{portnum = 'TEXT_MESSAGE_APP',
                                       payload = <<"hello mesh">>}}},
                         Sent)
    after 5000 ->
        error(no_tx_packet)
    end,
    ?assertEqual({error, no_bridge}, lora_mesh_node:send(nowhere, #mesh_tx{text = "x"})),

    %% 4. 233 bytes fit, 234 do not (78 x 3-byte Chinese characters = 234)
    ok = lora_mesh_node:send(#mesh_tx{text = binary:copy(<<"x">>, 233)}),
    ?assertEqual({error, too_long},
                 lora_mesh_node:send(#mesh_tx{text = lists:duplicate(78, $哈)})),

    lora_mesh_fake_node:stop([Pid, Scope]).
