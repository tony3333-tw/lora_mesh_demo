%%
%% rebar3 eunit: the libraries against known values and the fake radio.
%%
-module(mte_tests).

-include_lib("eunit/include/eunit.hrl").

-define(HILL, 16#60c0ffee).
-define(TOWER, 16#0d0d0dee).

%%--------------------------------------------------------------------
%% mtq: keys, channel hash, AES-CTR, envelopes
%%--------------------------------------------------------------------

default_key_test() ->
    ?assertEqual(base64:decode(<<"1PG7OiApB1nwvP+rz05pAQ==">>), mtq:key("AQ==")),
    ?assertEqual(<<>>, mtq:key("AA==")),
    ?assertEqual(<<1>>, mtq:psk("AQ")).

simple_key_test() ->
    %% "Ag==" (2) is the default key with 1 added to its last byte
    <<Head:15/binary, Last>> = mtq:key("AQ=="),
    ?assertEqual(<<Head/binary, (Last + 1)>>, mtq:key("Ag==")).

channel_hash_test() ->
    %% the well-known number of the default channel
    ?assertEqual(8, mtq:channel_hash("LongFast", mtq:key("AQ=="))).

crypt_test() ->
    %% openssl enc -aes-128-ctr -K d4f1...6901 -iv 7856341200000000 3412cdab00000000
    Cipher = mtq:crypt(mtq:key("AQ=="), 16#12345678, 16#abcd1234, <<"hello meshtastic world">>),
    ?assertEqual(<<"a449f103b92b9cfd1be8a363c194f0e78b461cd33761">>,
                 binary:encode_hex(Cipher, lowercase)).

envelope_test() ->
    Key = mtq:key("AQ=="),
    Data = #{portnum => 'TEXT_MESSAGE_APP', payload => <<"hi">>},
    Packet = mtq:packet(Data, Key, 16#abcd0001, #{id => 77}),
    ?assert(maps:is_key(encrypted, Packet)),
    Bin = mtq:envelope(Packet, "LongFast", mtc:node_id(16#abcd0001)),
    {ok, #{gateway_id := <<"!abcd0001">>, packet := P}} = mtq:open(Bin, Key),
    ?assertMatch(#{id := 77, channel := 8, decoded := #{text := <<"hi">>}}, P),
    {ok, #{packet := Wrong}} = mtq:open(Bin, mtq:key("Ag==")),
    ?assertMatch(#{decrypt_failed := true}, Wrong).

%%--------------------------------------------------------------------
%% mtc: framing and helpers
%%--------------------------------------------------------------------

frame_test() ->
    Frame = iolist_to_binary(mtc:frame(<<"abc">>)),
    ?assertEqual(<<16#94, 16#C3, 0, 3, "abc">>, Frame),
    ?assertEqual({[<<"abc">>], <<16#94>>}, mtc:unframe(<<"log text", Frame/binary, 16#94>>)).

node_id_test() ->
    ?assertEqual(<<"!0d0d0dee">>, mtc:node_id(?TOWER)).

compact_test() ->
    Full = mtc:decode(mtc:encode(#{to => 5, decoded => #{portnum => 'TEXT_MESSAGE_APP'}},
                                 mesh_packet),
                      mesh_packet),
    ?assertEqual(#{to => 5, decoded => #{portnum => 'TEXT_MESSAGE_APP'}},
                 mtc:compact(Full, mesh_packet)).

%%--------------------------------------------------------------------
%% mtc against the fake radio
%%--------------------------------------------------------------------

fake_radio_test_() ->
    {setup,
     fun() ->
             {ok, Pid, Port} = mtfake:start(#{port => 0, quiet => true, interval => 200}),
             {Pid, Port}
     end,
     fun({Pid, _Port}) -> mtfake:stop(Pid) end,
     fun({_Pid, Port}) ->
             [{timeout, 30, fun() -> radio(Port) end}]
     end}.

radio(Port) ->
    C = mtc:connect(#{port => Port}),
    ?assertEqual(mtfake:my_num(), mtc:my_num(C)),
    ?assertEqual(4, length(mtc:nodes(C))),
    ?assertEqual(8, length(mtc:channels(C))),
    ?assertEqual('LONG_FAST', maps:get(modem_preset, mtc:config(C, lora))),
    ?assertEqual(?HILL, mtc:node_num(C, "hill top")),
    ?assertEqual(?HILL, mtc:node_num(C, "!60c0ffee")),
    %% the mesh talks
    {packet, _} = mtc:next(C, 5000),
    %% traceroute through Tower
    Id = mtc:send_traceroute(C, ?HILL, 3),
    {ok, Trace} = mtc:reply(C, Id, 'TRACEROUTE_APP', 5000),
    ?assertEqual([?TOWER], mtc:get(Trace, [decoded, traceroute, route], [])),
    %% ACK, and a NAK from nowhere
    Ack = mtc:send_text(C, "hi", #{to => ?HILL, want_ack => true}),
    ?assertEqual(ok, mtc:ack(C, Ack, 5000)),
    Nak = mtc:send_text(C, "hi", #{to => 16#99, want_ack => true}),
    ?assertEqual({error, 'MAX_RETRANSMIT'}, mtc:ack(C, Nak, 5000)),
    %% admin: change a channel, read it back after reconnecting
    #{settings := Settings} = lists:nth(2, mtc:channels(C)),
    Set = mtc:admin(C, #{set_channel => #{index => 1, role => 'SECONDARY',
                                          settings => Settings#{name => <<"farm">>}}}),
    ?assertEqual(ok, mtc:ack(C, Set, 5000)),
    mtc:close(C),
    C2 = mtc:connect(#{port => Port}),
    ?assertMatch(#{role := 'SECONDARY', settings := #{name := <<"farm">>}},
                 lists:nth(2, mtc:channels(C2))),
    mtc:close(C2).
