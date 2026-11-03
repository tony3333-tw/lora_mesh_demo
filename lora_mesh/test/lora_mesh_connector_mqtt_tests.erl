-module(lora_mesh_connector_mqtt_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lora_mesh.hrl").

broadcast_test() ->
    ?assertEqual({ok, {any, #mesh_tx{to = 16#FFFFFFFF, channel = 0, text = <<"hello">>}}},
                 lora_mesh_connector_mqtt:parse_tx(<<"{\"text\":\"hello\"}">>)).

direct_test() ->
    ?assertEqual({ok, {any, #mesh_tx{to = 16#a1b2c3d4, channel = 1, text = <<"hi">>}}},
                 lora_mesh_connector_mqtt:parse_tx(
                   <<"{\"text\":\"hi\",\"to\":\"!a1b2c3d4\",\"channel\":1}">>)).

bridge_test() ->
    _ = home,   % bridge ids are atoms that already exist (from config)
    ?assertMatch({ok, {home, #mesh_tx{text = <<"hi">>}}},
                 lora_mesh_connector_mqtt:parse_tx(<<"{\"text\":\"hi\",\"bridge\":\"home\"}">>)).

unknown_bridge_test() ->
    ?assertMatch({error, _},
                 lora_mesh_connector_mqtt:parse_tx(
                   <<"{\"text\":\"hi\",\"bridge\":\"no_such_bridge_xyz\"}">>)).

no_text_test() ->
    ?assertEqual({error, no_text},
                 lora_mesh_connector_mqtt:parse_tx(<<"{\"to\":\"!a1b2c3d4\"}">>)).

bad_json_test() ->
    ?assertMatch({error, _},
                 lora_mesh_connector_mqtt:parse_tx(<<"not json">>)).
