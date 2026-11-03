%%
%% MeshCore: the codec on hand-made bytes, then the bridge against the
%% fake companion (lora_mesh_fake_companion) over TCP and over a serial
%% pseudo-terminal, alone and as two bridges hearing the same channel.
%%
-module(lora_mesh_meshcore_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lora_mesh.hrl").

-define(CODEC, lora_mesh_meshcore_codec).

-define(ALICE, <<16#a1, 16#a2, 16#a3, 16#a4, 16#a5, 16#a6, 0:(26 * 8)>>).
-define(BOB, <<16#b1, 16#b2, 16#b3, 16#b4, 16#b5, 16#b6, 1:(26 * 8)>>).
-define(CAROL, <<16#c1, 16#c2, 16#c3, 16#c4, 16#c5, 16#c6, 2:(26 * 8)>>).
-define(SELF, <<16#5e, 16#1f, 16#00, 16#00, 16#00, 16#01, 3:(26 * 8)>>).

-define(ALICE_NUM, (1 bsl 48 + 16#a1a2a3a4a5a6)).
-define(BOB_NUM, (1 bsl 48 + 16#b1b2b3b4b5b6)).
-define(CAROL_NUM, (1 bsl 48 + 16#c1c2c3c4c5c6)).

%%====================================================================
%% Codec
%%====================================================================

frame_test() ->
    ?assertEqual(<<$<, 2, 0, 22, 3>>, iolist_to_binary(?CODEC:frame(?CODEC:device_query(3)))).

decode_test_() ->
    [?_assertEqual({[<<0>>, <<10>>], <<>>},
                   ?CODEC:decode(<<$>, 1, 0, 0, $>, 1, 0, 10>>)),
     %% junk before a frame is skipped; a half frame waits for more
     ?_assertEqual({[<<16#83>>], <<$>, 5, 0, 1, 2>>},
                   ?CODEC:decode(<<"junk", $>, 1, 0, 16#83, $>, 5, 0, 1, 2>>)),
     ?_assertEqual({[], <<$>>>}, ?CODEC:decode(<<$>>>)),
     %% a '>' with an impossible length is not a frame
     ?_assertEqual({[<<0>>], <<>>},
                   ?CODEC:decode(<<$>, 0, 16#7f, $>, 1, 0, 0>>))].

commands_test_() ->
    Prefix = binary:part(?ALICE, 0, 6),
    [?_assertEqual(<<1, 0:56, "lora_mesh">>, ?CODEC:app_start("lora_mesh")),
     ?_assertEqual(<<6, 16#00, 16#e1, 16#f5, 16#05>>, ?CODEC:set_device_time(100000000)),
     ?_assertEqual(<<4>>, ?CODEC:get_contacts(0)),
     ?_assertEqual(<<4, 7, 0, 0, 0>>, ?CODEC:get_contacts(7)),
     ?_assertEqual(<<2, 0, 0, 1, 0, 0, 0, Prefix/binary, "hi">>,
                   ?CODEC:send_txt_msg(Prefix, <<"hi">>, 1, 0)),
     ?_assertEqual(<<3, 0, 2, 1, 0, 0, 0, "早安"/utf8>>,
                   ?CODEC:send_channel_txt_msg(2, "早安", 1))].

responses_test_() ->
    Prefix = binary:part(?ALICE, 0, 6),
    [?_assertEqual(ok, ?CODEC:response(<<0>>)),
     ?_assertEqual({err, not_found}, ?CODEC:response(<<1, 2>>)),
     ?_assertEqual(no_more_messages, ?CODEC:response(<<10>>)),
     ?_assertEqual(msg_waiting, ?CODEC:response(<<16#83>>)),
     ?_assertEqual({send_confirmed, 5, 900}, ?CODEC:response(<<16#82, 5:32/little, 900:32/little>>)),
     ?_assertEqual({sent, #{flood => true, expected_ack => 9, timeout_ms => 3000}},
                   ?CODEC:response(<<6, 1, 9:32/little, 3000:32/little>>)),
     %% v3: SNR * 4 signed, two reserved bytes
     ?_assertMatch({contact_msg, #{from_prefix := Prefix, snr := -2.5, path_len := 3,
                                   sender_time := 77, text := <<"hello">>}},
                   ?CODEC:response(<<16, -10:8/signed, 0, 0, Prefix/binary, 3, 0,
                                     77:32/little, "hello">>)),
     %% signed text: 4 bytes of signer prefix before the text
     ?_assertMatch({contact_msg, #{txt_type := 2, text := <<"signed">>}},
                   ?CODEC:response(<<7, Prefix/binary, 16#ff, 2, 77:32/little,
                                     "abcd", "signed">>)),
     ?_assertMatch({channel_msg, #{channel := 1, snr := 4.0, sender_name := <<"Bob">>,
                                   text := <<"a: b">>}},
                   ?CODEC:response(<<17, 16, 0, 0, 1, 0, 0, 1:32/little, "Bob: a: b">>)),
     ?_assertEqual(2, ?CODEC:hops(2)),
     ?_assertEqual(2, ?CODEC:hops(16#42)),      % 2-byte hashes, 2 hops
     ?_assertEqual(direct, ?CODEC:hops(16#ff))].

ids_test_() ->
    [?_assertEqual(<<"@a1a2a3a4a5a6">>, lora_mesh_meshcore:node_id(?ALICE_NUM)),
     ?_assertEqual(?ALICE_NUM, lora_mesh_meshcore:node_num(binary:part(?ALICE, 0, 6))),
     ?_assertEqual(?ALICE_NUM, lora_mesh_meshcore:num_from_hex(<<"a1a2a3a4a5a6">>)),
     ?_assert(lora_mesh_meshcore:is_node_num(?ALICE_NUM)),
     ?_assertNot(lora_mesh_meshcore:is_node_num(16#FFFFFFFF)),
     ?_assertEqual(meshcore, lora_mesh_node:protocol_of(?ALICE_NUM)),
     ?_assertEqual(meshtastic, lora_mesh_node:protocol_of(16#0a0b0c0d))].

parse_tx_test_() ->
    [?_assertMatch({ok, {any, #mesh_tx{to = ?ALICE_NUM}}},
                   lora_mesh_connector_mqtt:parse_tx(
                     <<"{\"to\":\"@a1a2a3a4a5a6\",\"text\":\"hi\"}">>)),
     ?_assertMatch({ok, {{protocol, meshcore}, #mesh_tx{to = ?MESH_BROADCAST}}},
                   lora_mesh_connector_mqtt:parse_tx(
                     <<"{\"protocol\":\"meshcore\",\"text\":\"hi\"}">>)),
     ?_assertMatch({error, _},
                   lora_mesh_connector_mqtt:parse_tx(<<"{\"to\":\"@a1\",\"text\":\"hi\"}">>))].

%%====================================================================
%% One bridge over TCP
%%====================================================================

tcp_bridge_test_() ->
    {timeout, 30, fun tcp_bridge/0}.

tcp_bridge() ->
    Server = start_server(),
    Contacts = [lora_mesh_fake_companion:contact(?ALICE, <<"Alice">>,
                                                 #{lat => 25047000, lon => 121517000,
                                                   lastmod => 5}),
                lora_mesh_fake_companion:contact(?BOB, <<"Bob">>,
                                                 #{out_path_len => 1, lastmod => 6})],
    {ok, Fake} = lora_mesh_fake_companion:start(#{name => <<"Field gw">>,
                                                  pub_key => ?SELF,
                                                  contacts => Contacts,
                                                  %% the device clock is ahead of ours:
                                                  %% SET_DEVICE_TIME is refused, harmless
                                                  clock => erlang:system_time(second) + 3600}),
    {ok, Port} = lora_mesh_fake_companion:port(Fake),
    {ok, Bridge} = lora_mesh_meshcore:start_link(#{id => field,
                                                   transport => tcp,
                                                   host => "127.0.0.1",
                                                   port => Port}),

    %% contacts land in the registry
    wait_node(?ALICE_NUM, fun(N) -> N#mesh_node.long_name =:= <<"Alice">> end),
    {ok, Alice} = lora_mesh_registry:lookup(?ALICE_NUM),
    ?assertMatch(#mesh_node{id = <<"@a1a2a3a4a5a6">>,
                            protocol = meshcore,
                            role = chat,
                            last_heard = 1700000000,
                            position = #mesh_position{latitude = 25.047}},
                 Alice),
    wait_node(?BOB_NUM, fun(N) -> N#mesh_node.long_name =:= <<"Bob">> end),
    wait_node(1 bsl 48 + 16#5e1f00000001,
              fun(N) -> N#mesh_node.long_name =:= <<"Field gw">> end),
    wait(fun() -> lists:member(10, lora_mesh_fake_companion:commands(Fake)) end),
    ?assertEqual([22, 1, 6, 4, 10], lora_mesh_fake_companion:commands(Fake)),

    %% a direct message, flooded over 2 hops
    ok = lora_mesh_fake_companion:receive_dm(Fake, ?ALICE, <<"溫度 23.5"/utf8>>,
                                             #{snr => 6.25, path_len => 2, sender_time => 111}),
    Dm = uplink(),
    ?assertMatch(#mesh_rx{from = <<"@a1a2a3a4a5a6">>,
                          to = <<"@5e1f00000001">>,
                          id = 111,
                          text = <<"溫度 23.5"/utf8>>,
                          protocol = meshcore,
                          bridges = [field],
                          rxq = #mesh_rxq{rx_snr = 6.25, hop_start = 2, hop_limit = 0}},
                 Dm),
    {ok, #mesh_node{heard_by = #{field := _}}} = lora_mesh_registry:lookup(?ALICE_NUM),

    %% two messages queued before the bridge syncs: both come out, in order
    ok = lora_mesh_fake_companion:receive_channel(Fake, 0, <<"Bob">>, <<"one">>,
                                                  #{snr => -3.0, path_len => 16#ff,
                                                    sender_time => 200}),
    ok = lora_mesh_fake_companion:receive_channel(Fake, 0, <<"Nobody">>, <<"two">>,
                                                  #{sender_time => 201}),
    One = uplink(),
    ?assertMatch(#mesh_rx{from = <<"@b1b2b3b4b5b6">>,
                          to = <<"!ffffffff">>,
                          channel = 0,
                          sender_name = <<"Bob">>,
                          text = <<"one">>,
                          rxq = #mesh_rxq{rx_snr = -3.0, hop_start = 0}},
                 One),
    ?assertMatch(#mesh_rx{from = <<"?">>, sender_name = <<"Nobody">>, text = <<"two">>},
                 uplink()),

    %% sending
    ?assertEqual(ok, lora_mesh_node:send(#mesh_tx{to = ?ALICE_NUM, text = <<"ack">>})),
    ?assertEqual(ok, lora_mesh_node:send_protocol(meshcore, #mesh_tx{text = "大家好"})),
    ?assertEqual(ok, lora_mesh_node:send(field, #mesh_tx{channel = 0, text = <<"to all">>})),
    ?assertEqual({error, not_found},
                 lora_mesh_node:send(#mesh_tx{to = ?CAROL_NUM, text = <<"who?">>})),
    ?assertEqual({error, not_found},
                 lora_mesh_node:send(field, #mesh_tx{channel = 7, text = <<"no channel">>})),
    ?assertEqual({error, too_long},
                 lora_mesh_node:send(#mesh_tx{to = ?ALICE_NUM, text = binary:copy(<<"x">>, 161)})),
    %% "Field gw: " takes 10 of the 160 bytes
    ?assertEqual({error, too_long},
                 lora_mesh_node:send(field, #mesh_tx{text = binary:copy(<<"x">>, 151)})),
    ?assertEqual({error, wrong_protocol},
                 lora_mesh_node:send(field, #mesh_tx{to = 16#0a0b0c0d, text = <<"hi">>})),
    ?assertMatch([{dm, <<"a1a2a3a4a5a6">>, <<"ack">>, _},
                  {channel, 0, <<"Field gw: 大家好"/utf8>>},
                  {channel, 0, <<"Field gw: to all">>}],
                 lora_mesh_fake_companion:sent(Fake)),
    [{dm, _, _, Ack} | _] = lora_mesh_fake_companion:sent(Fake),
    ok = lora_mesh_fake_companion:confirm(Fake, Ack),

    %% a new node is heard: its channel messages now carry its id
    ok = lora_mesh_fake_companion:hear_advert(Fake, ?CAROL, #{name => <<"Carol">>}),
    wait_node(?CAROL_NUM, fun(N) -> N#mesh_node.long_name =:= <<"Carol">> end),
    ok = lora_mesh_fake_companion:receive_channel(Fake, 0, <<"Carol">>, <<"hi">>, #{}),
    ?assertMatch(#mesh_rx{from = <<"@c1c2c3c4c5c6">>}, uplink()),

    %% a known node advertises a new name: fetched with GET_CONTACTS since
    ok = lora_mesh_fake_companion:hear_advert(Fake, ?ALICE, #{name => <<"Alice 2">>}),
    wait_node(?ALICE_NUM, fun(N) -> N#mesh_node.long_name =:= <<"Alice 2">> end),

    %% the radio goes away and comes back: the bridge reconnects and resyncs
    ok = lora_mesh_fake_companion:disconnect(Fake),
    ?assertEqual({error, not_connected},
                 wait_result(fun() ->
                                     lora_mesh_node:send(#mesh_tx{to = ?ALICE_NUM, text = <<"x">>})
                             end,
                             {error, not_connected})),
    ok = lora_mesh_fake_companion:receive_dm(Fake, ?BOB, <<"while away">>, #{sender_time => 300}),
    ?assertMatch(#mesh_rx{from = <<"@b1b2b3b4b5b6">>, text = <<"while away">>}, uplink()),

    lora_mesh_fake_node:stop([Bridge]),
    lora_mesh_fake_companion:stop(Fake),
    stop_server(Server).

%%====================================================================
%% Two bridges hear the same channel message
%%====================================================================

two_bridges_test_() ->
    {timeout, 20, fun two_bridges/0}.

two_bridges() ->
    Server = start_server(),
    Bob = [lora_mesh_fake_companion:contact(?BOB, <<"Bob">>, #{})],
    {ok, FakeA} = lora_mesh_fake_companion:start(#{name => <<"A">>, contacts => Bob}),
    {ok, FakeB} = lora_mesh_fake_companion:start(#{name => <<"B">>, contacts => Bob}),
    {ok, PortA} = lora_mesh_fake_companion:port(FakeA),
    {ok, PortB} = lora_mesh_fake_companion:port(FakeB),
    {ok, A} = lora_mesh_meshcore:start_link(#{id => barn, transport => tcp,
                                              host => "127.0.0.1", port => PortA}),
    {ok, B} = lora_mesh_meshcore:start_link(#{id => hill, transport => tcp,
                                              host => "127.0.0.1", port => PortB}),
    wait(fun() -> lists:member(10, lora_mesh_fake_companion:commands(FakeA))
                      andalso lists:member(10, lora_mesh_fake_companion:commands(FakeB))
         end),
    wait_node(?BOB_NUM, fun(N) -> N#mesh_node.long_name =:= <<"Bob">> end),

    %% same message, same sender time; the slot number differs per radio
    ok = lora_mesh_fake_companion:receive_channel(FakeA, 0, <<"Bob">>, <<"rain">>,
                                                  #{snr => 2.0, path_len => 1, sender_time => 500}),
    ok = lora_mesh_fake_companion:receive_channel(FakeB, 3, <<"Bob">>, <<"rain">>,
                                                  #{snr => 9.5, path_len => 0, sender_time => 500}),
    Rx = uplink(),
    ?assertMatch(#mesh_rx{from = <<"@b1b2b3b4b5b6">>,
                          text = <<"rain">>,
                          channel = 3,
                          bridges = [hill, barn],
                          rxq = #mesh_rxq{rx_snr = 9.5}},
                 Rx),
    receive {uplink, _} -> error(published_twice) after 500 -> ok end,
    {ok, Node} = lora_mesh_registry:lookup(?BOB_NUM),
    ?assertEqual([barn, hill], lists:sort(maps:keys(Node#mesh_node.heard_by))),

    lora_mesh_fake_node:stop([A, B]),
    [lora_mesh_fake_companion:stop(F) || F <- [FakeA, FakeB]],
    stop_server(Server).

%%====================================================================
%% Serial: the bridge opens a pseudo-terminal like a /dev/ttyUSB0
%%====================================================================

serial_bridge_test_() ->
    {timeout, 20, fun serial_bridge/0}.

serial_bridge() ->
    Server = start_server(),
    {ok, Fake} = lora_mesh_fake_companion:start(
                   #{name => <<"USB">>,
                     contacts => [lora_mesh_fake_companion:contact(?ALICE, <<"Alice">>, #{})]}),
    {ok, Port} = lora_mesh_fake_companion:port(Fake),
    Script = filename:join(filename:dirname(?FILE), "meshcore_pty.py"),
    Pty = open_port({spawn_executable, os:find_executable("python3")},
                    [{args, [Script, integer_to_list(Port)]},
                     {line, 256},
                     binary,
                     use_stdio]),
    Device = receive
                 {Pty, {data, {eol, Path}}} -> binary_to_list(Path)
             after 5000 ->
                     error(no_pty)
             end,
    {ok, Bridge} = lora_mesh_meshcore:start_link(#{id => usb,
                                                   transport => serial,
                                                   device => Device,
                                                   start_delay_ms => 0}),
    wait_node(?ALICE_NUM, fun(N) -> N#mesh_node.long_name =:= <<"Alice">> end),
    ok = lora_mesh_fake_companion:receive_dm(Fake, ?ALICE, <<"over serial">>, #{}),
    ?assertMatch(#mesh_rx{text = <<"over serial">>, bridges = [usb]}, uplink()),
    ?assertEqual(ok, lora_mesh_node:send(#mesh_tx{to = ?ALICE_NUM, text = <<"back">>})),
    ?assertMatch([{dm, _, <<"back">>, _}], lora_mesh_fake_companion:sent(Fake)),

    lora_mesh_fake_node:stop([Bridge]),
    port_close(Pty),
    lora_mesh_fake_companion:stop(Fake),
    stop_server(Server).

%%====================================================================
%% Helpers
%%====================================================================

%% pg, registry and router, all reporting to this test process
start_server() ->
    {ok, Scope} = pg:start_link(?PG_SCOPE),
    {ok, Reg} = lora_mesh_registry:start_link(#{notify => self()}),
    {ok, Router} = lora_mesh_router:start_link(#{dedup_ms => 200, subscriber => self()}),
    [Router, Reg, Scope].

stop_server(Pids) ->
    lora_mesh_fake_node:stop(Pids),
    flush().

uplink() ->
    receive
        {uplink, Rx} -> Rx
    after 5000 ->
            error(no_uplink)
    end.

wait_node(Num, Pred) ->
    wait(fun() ->
                 case lora_mesh_registry:lookup(Num) of
                     {ok, Node} -> Pred(Node);
                     not_found -> false
                 end
         end).

wait(Pred) ->
    wait(Pred, 50).

wait(_Pred, 0) ->
    error(timeout);
wait(Pred, N) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait(Pred, N - 1)
    end.

%% call Fun until it returns Expected (or give up and return what it gave)
wait_result(Fun, Expected) ->
    wait_result(Fun, Expected, 30).

wait_result(Fun, _Expected, 0) ->
    Fun();
wait_result(Fun, Expected, N) ->
    case Fun() of
        Expected -> Expected;
        _ ->
            timer:sleep(50),
            wait_result(Fun, Expected, N - 1)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 ->
            ok
    end.
