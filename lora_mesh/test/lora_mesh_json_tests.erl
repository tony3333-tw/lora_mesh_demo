%%
%% lora_mesh_json (0.4): records as the JSON of mesh/packet and
%% mesh/bridge/<id>/info, and the secrets the info topic hides.
%%
-module(lora_mesh_json_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

defaults_left_out_test() ->
    Channel = #channel{index = 1,
                       role = 'SECONDARY',
                       settings = #channel_settings{name = <<"team">>, psk = <<1>>}},
    ?assertEqual(#{index => 1,
                   role => 'SECONDARY',
                   settings => #{name => <<"team">>, psk => <<"base64:AQ==">>}},
                 lora_mesh_json:record(Channel)),
    %% index 0, role DISABLED, empty settings: all defaults
    ?assertEqual(#{settings => #{}}, lora_mesh_json:record(#channel{settings = #channel_settings{}})).

oneof_test() ->
    Lora = #config_lo_ra_config{use_preset = true, region = 'TW', hop_limit = 3},
    %% LONG_FAST is the first ModemPreset: a default, left out as in Python
    ?assertEqual(#{lora => #{use_preset => true, region => 'TW', hop_limit => 3}},
                 lora_mesh_json:record(#config{payload_variant = {lora, Lora}})).

text_packet_test() ->
    P = #mesh_packet{from = 16#0a0b0c0d, to = ?MESH_BROADCAST, id = 7, rx_snr = 6.25,
                     hop_start = 3, hop_limit = 2,
                     payload_variant = {decoded, #data{portnum = 'TEXT_MESSAGE_APP',
                                                       payload = <<"hi"/utf8>>}}},
    Map = lora_mesh_json:packet(P),
    ?assertMatch(#{from := 16#0a0b0c0d, from_id := <<"!0a0b0c0d">>, to_id := <<"!ffffffff">>,
                   id := 7, rx_snr := 6.25, hop_start := 3, hop_limit := 2,
                   decoded := #{portnum := 'TEXT_MESSAGE_APP', text := <<"hi">>}},
                 Map),
    %% it encodes as JSON
    ?assertMatch(#{<<"decoded">> := #{<<"text">> := <<"hi">>}},
                 json:decode(iolist_to_binary(json:encode(Map)))).

position_test() ->
    Pos = meshtastic_pb:encode_msg(#position{latitude_i = 241477000, longitude_i = 1206736000},
                                   position),
    #{position := P} = lora_mesh_json:app('POSITION_APP', Pos),
    ?assertEqual(24.1477, maps:get(latitude, P)),
    ?assertEqual(120.6736, maps:get(longitude, P)).

local_stats_test() ->
    T = meshtastic_pb:encode_msg(#telemetry{time = 5,
                                            variant = {local_stats,
                                                       #local_stats{uptime_seconds = 60,
                                                                    num_packets_rx = 9}}},
                                 telemetry),
    ?assertEqual(#{telemetry => #{time => 5,
                                  local_stats => #{uptime_seconds => 60, num_packets_rx => 9}}},
                 lora_mesh_json:app('TELEMETRY_APP', T)).

bad_payload_test() ->
    ?assertEqual(#{decode_error => position}, lora_mesh_json:app('POSITION_APP', <<255, 255>>)),
    ?assertEqual(#{}, lora_mesh_json:app('PRIVATE_APP', <<1, 2, 3>>)).

hide_secrets_test() ->
    Info = #{channels => [lora_mesh_json:record(#channel{index = 0, settings = #channel_settings{psk = <<1>>}}),
                          lora_mesh_json:record(#channel{index = 1, settings = #channel_settings{psk = binary:copy(<<7>>, 16)}})],
             config => #{network => #{wifi_ssid => <<"farm">>, wifi_psk => <<"secret">>},
                         security => #{private_key => <<"base64:abc">>, public_key => <<"base64:def">>}},
             module_config => #{mqtt => #{password => <<"pw">>, username => <<"u">>}}},
    #{channels := [C0, C1], config := Config, module_config := Module} =
        lora_mesh_node:hide_secrets(Info),
    ?assertEqual(<<"base64:AQ==">>, maps:get(psk, maps:get(settings, C0))),
    ?assertEqual(<<"(hidden)">>, maps:get(psk, maps:get(settings, C1))),
    ?assertEqual(#{wifi_ssid => <<"farm">>, wifi_psk => <<"(hidden)">>}, maps:get(network, Config)),
    ?assertEqual(#{private_key => <<"(hidden)">>, public_key => <<"base64:def">>},
                 maps:get(security, Config)),
    ?assertEqual(#{password => <<"(hidden)">>, username => <<"u">>}, maps:get(mqtt, Module)).
