-module(lora_mesh_frame_tests).

-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Frame = iolist_to_binary(lora_mesh_frame:encode(<<"hello">>)),
    ?assertEqual({[<<"hello">>], <<>>},
                 lora_mesh_frame:decode(Frame)).

two_frames_test() ->
    Bin = iolist_to_binary([lora_mesh_frame:encode(<<"a">>),
                            lora_mesh_frame:encode(<<"bc">>)]),
    ?assertEqual({[<<"a">>, <<"bc">>], <<>>},
                 lora_mesh_frame:decode(Bin)).

split_frame_test() ->
    <<Part1:3/binary, Part2/binary>> =
        iolist_to_binary(lora_mesh_frame:encode(<<"hello">>)),
    {[], Rest} = lora_mesh_frame:decode(Part1),
    ?assertEqual({[<<"hello">>], <<>>},
                 lora_mesh_frame:decode(<<Rest/binary, Part2/binary>>)).

skips_log_text_test() ->
    Bin = iolist_to_binary(["DEBUG | some log line\r\n",
                            lora_mesh_frame:encode(<<"x">>)]),
    ?assertEqual({[<<"x">>], <<>>},
                 lora_mesh_frame:decode(Bin)).

resync_on_bad_length_test() ->
    Bin = iolist_to_binary([<<16#94, 16#C3, 16#FF, 16#FF>>,
                            lora_mesh_frame:encode(<<"ok">>)]),
    ?assertEqual({[<<"ok">>], <<>>},
                 lora_mesh_frame:decode(Bin)).
