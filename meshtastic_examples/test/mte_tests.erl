%%
%% rebar3 eunit: the parts that need no broker. The examples themselves
%% are tried against lora_mesh's demo (see README.md).
%%
-module(mte_tests).

-include_lib("eunit/include/eunit.hrl").

sample_nodes() ->
    [#{<<"id">> => <<"!0a0b0c0d">>, <<"num">> => 168496141,
       <<"long_name">> => <<"Hill top">>, <<"short_name">> => <<"HILL">>},
     #{<<"id">> => <<"!0c0c0c0c">>, <<"num">> => 202116108,
       <<"long_name">> => null, <<"short_name">> => null}].

find_test() ->
    [Hill, NoName] = sample_nodes(),
    ?assertEqual({ok, Hill}, mtc:find(sample_nodes(), "hill top")),
    ?assertEqual({ok, Hill}, mtc:find(sample_nodes(), "HILL")),
    ?assertEqual({ok, Hill}, mtc:find(sample_nodes(), "168496141")),
    ?assertEqual({ok, NoName}, mtc:find(sample_nodes(), "!0C0C0C0C")),
    ?assertEqual(error, mtc:find(sample_nodes(), "nobody")).

names_test() ->
    Names = mtc:names(sample_nodes()),
    ?assertEqual(<<"Hill top">>, mtc:name(Names, <<"!0a0b0c0d">>)),
    ?assertEqual(<<"!0c0c0c0c">>, mtc:name(Names, <<"!0c0c0c0c">>)),
    ?assertEqual(<<"Bob">>, mtc:sender(#{<<"sender_name">> => <<"Bob">>}, Names)),
    ?assertEqual(<<"Hill top">>, mtc:sender(#{<<"from">> => <<"!0a0b0c0d">>}, Names)).

dest_test() ->
    %% an id needs no broker: it is used as it is
    ?assertEqual(<<"!0a0b0c0d">>, mtc:dest(no_client, #{dest => "!0A0B0C0D"})),
    ?assertError({missing_option, _}, mtc:dest(no_client, #{})).

rx_test() ->
    Rx = #{<<"to">> => <<"!ffffffff">>,
           <<"rxq">> => #{<<"hop_start">> => 3, <<"hop_limit">> => 2}},
    ?assert(mtc:is_channel(Rx)),
    ?assertEqual(1, mtc:hops(Rx)).

decode_test() ->
    C = #{prefix => <<"mesh">>},
    ?assertEqual({rx, #{<<"text">> => <<"hi">>}},
                 mtc:decode(C, #{topic => <<"mesh/rx/!0a0b0c0d">>, payload => <<"{\"text\":\"hi\"}">>})),
    %% a removed retained node record
    ?assertEqual(ignore, mtc:decode(C, #{topic => <<"mesh/node/!0a0b0c0d">>, payload => <<>>})),
    ?assertEqual(ignore, mtc:decode(C, #{topic => <<"other/rx/x">>, payload => <<"{}">>})).

tx_test() ->
    ?assertEqual(#{<<"text">> => <<"hi">>, <<"channel">> => 1, <<"protocol">> => <<"meshtastic">>},
                 mte_mqtt_send:tx(#{message => "hi", channel => 1})),
    ?assertEqual(#{<<"text">> => <<"hi">>, <<"channel">> => 0, <<"to">> => <<"!0a0b0c0d">>},
                 mte_mqtt_send:tx(#{message => "hi", dest => "!0a0b0c0d"})),
    %% the LFE twin builds the same JSON
    ?assertEqual(mte_mqtt_send:tx(#{message => "hi", dest => "!0a0b0c0d"}),
                 mtl_mqtt_send:tx(#{message => "hi", dest => "!0a0b0c0d"})).

compact_test() ->
    Full = mtp:decode(mtp:encode(#{to => 5, decoded => #{portnum => 'TEXT_MESSAGE_APP'}},
                                 mesh_packet),
                      mesh_packet),
    ?assertEqual(#{to => 5, decoded => #{portnum => 'TEXT_MESSAGE_APP'}},
                 mtp:compact(Full, mesh_packet)).
