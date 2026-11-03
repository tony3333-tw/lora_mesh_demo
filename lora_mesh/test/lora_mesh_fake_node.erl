%% A fake Meshtastic node for tests: listens on TCP, answers
%% want_config_id with the FromRadio variants it was given, then reports
%% every ToRadio it receives to its owner as {fake_node_got, Name, Variant}.
-module(lora_mesh_fake_node).

-export([start/2]).
-export([text_packet/4]).
-export([app_packet/5]).
-export([stop/1]).

-include("meshtastic/mesh.hrl").

%% -> {ok, Port}
start(Name, Variants) ->
    Owner = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary,
                                      {active, false},
                                      {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    spawn_link(fun() ->
                       {ok, Sock} = gen_tcp:accept(Listen),
                       loop(Sock, Name, Owner, Variants, <<>>)
               end),
    {ok, Port}.

text_packet(From, Id, Snr, Text) ->
    app_packet(From, Id, Snr, 'TEXT_MESSAGE_APP', Text).

app_packet(From, Id, Snr, Port, Payload) ->
    #mesh_packet{
       from = From,
       to = 16#FFFFFFFF,
       id = Id,
       rx_snr = Snr,
       rx_rssi = -90,
       hop_start = 3,
       hop_limit = 2,
       payload_variant =
           {decoded,
            #data{portnum = Port,
                  payload = Payload}}}.

loop(Sock, Name, Owner, Variants, Buf) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, Data} ->
            {Frames, Rest} = lora_mesh_frame:decode(<<Buf/binary, Data/binary>>),
            lists:foreach(
                fun(F) -> handle(Sock, Name, Owner, Variants, F) end,
                Frames),
            loop(Sock, Name, Owner, Variants, Rest);
        {error, _} ->
            ok
    end.

handle(Sock, Name, Owner, Variants, Frame) ->
    #to_radio{payload_variant = Variant} =
        meshtastic_pb:decode_msg(Frame, to_radio),
    Owner ! {fake_node_got, Name, Variant},
    case Variant of
        {want_config_id, Id} ->
            send(Sock, {my_info, #my_node_info{my_node_num = erlang:phash2(Name)}}),
            [send(Sock, V) || V <- Variants],
            send(Sock, {config_complete_id, Id});
        _ ->
            ok
    end.

send(Sock, Variant) ->
    Bin = meshtastic_pb:encode_msg(#from_radio{payload_variant = Variant}),
    ok = gen_tcp:send(Sock, lora_mesh_frame:encode(Bin)).

%% Stop processes and wait until each is gone, so the next test can
%% register the same names.
stop(Pids) ->
    lists:foreach(
      fun(P) ->
              Ref = monitor(process, P),
              unlink(P),
              exit(P, shutdown),
              receive {'DOWN', Ref, process, P, _} -> ok
              after 5000 -> error({not_stopped, P})
              end
      end,
      Pids).
