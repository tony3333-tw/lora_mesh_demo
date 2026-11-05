%%
%% mtq: Meshtastic over MQTT, without a radio, for the MQTT examples
%% (MQTT/*.py).
%%
%% A radio with its MQTT module on publishes every packet it hears as a
%% ServiceEnvelope (protobuf) to
%%
%%   <root>/<channel name>/<gateway id>    e.g. msh/US/2/e/LongFast/!a1b2c3d4
%%
%% and the payload of a channel packet is AES-CTR encrypted with the
%% channel key. This module does what the Python examples do with paho,
%% meshtastic.protobuf and cryptography:
%%
%%   key/1             "AQ==" (the default key) or a base64 PSK -> key bytes
%%   channel_hash/2    the 1-byte channel number a packet carries
%%   crypt/4           AES-128/256-CTR, nonce = packet id, from node (LE)
%%   packet/4          a Data map -> an encrypted MeshPacket map
%%   envelope/3        MeshPacket -> ServiceEnvelope bytes to publish
%%   open/2            ServiceEnvelope bytes -> decrypted, decoded map
%%
%% lora_mesh is not involved: these examples talk to an MQTT broker the
%% radios publish to (mqtt.meshtastic.org by default, as in Python).
%%
-module(mtq).

-export([connect/1]).
-export([disconnect/1]).
-export([subscribe/2]).
-export([publish/3]).
-export([key/1]).
-export([psk/1]).
-export([channel_hash/2]).
-export([crypt/4]).
-export([packet/4]).
-export([envelope/3]).
-export([open/2]).
-export([random_node/0]).
-export([root/2]).

%% The default channel key ("AQ==" stands for it)
-define(DEFAULT_KEY, <<16#d4, 16#f1, 16#bb, 16#3a, 16#20, 16#29, 16#07, 16#59,
                       16#f0, 16#bc, 16#ff, 16#ab, 16#cf, 16#4e, 16#69, 16#01>>).

%%====================================================================
%% Broker
%%====================================================================

%% Opts: broker ("mqtt.meshtastic.org"), mqtt_port (1883), username
%% ("meshdev"), password ("large4cats"): the public broker's settings
%% from the Python examples. Raises error({mqtt_connect, Reason}).
connect(Opts) ->
    {ok, _} = application:ensure_all_started(emqtt),
    Args = [{host, maps:get(broker, Opts, "mqtt.meshtastic.org")},
            {port, maps:get(mqtt_port, Opts, 1883)},
            {username, unicode:characters_to_binary(maps:get(username, Opts, "meshdev"))},
            {password, unicode:characters_to_binary(maps:get(password, Opts, "large4cats"))},
            {clientid, iolist_to_binary(io_lib:format("mte-~8.16.0b", [rand:uniform(16#FFFFFFFF)]))},
            {clean_start, true}],
    {ok, Conn} = emqtt:start_link(Args),
    %% emqtt exits when the broker cannot be reached: unlinked while
    %% connecting, so that becomes an error here instead of killing us
    unlink(Conn),
    case emqtt:connect(Conn) of
        {ok, _Props} ->
            link(Conn),
            Conn;
        {error, Reason} ->
            catch emqtt:stop(Conn),
            error({mqtt_connect, Reason})
    end.

disconnect(Conn) ->
    _ = emqtt:disconnect(Conn),
    ok.

%% Messages then arrive as {publish, #{topic := T, payload := P}}.
subscribe(Conn, Topic) ->
    {ok, _, _} = emqtt:subscribe(Conn, unicode:characters_to_binary(Topic), 0),
    ok.

publish(Conn, Topic, Payload) ->
    ok = emqtt:publish(Conn, unicode:characters_to_binary(Topic), Payload, 0).

%%====================================================================
%% Keys and encryption
%%====================================================================

%% A channel PSK as base64 (standard or URL-safe, padding optional) ->
%% the AES key. One-byte PSKs are the firmware's shorthands: 0 = no
%% encryption (<<>>), 1 = the default key ("AQ=="), N = the default key
%% with N - 1 added to its last byte.
key(Base64) ->
    case psk(Base64) of
        <<>> -> <<>>;
        <<0>> -> <<>>;
        <<Index>> ->
            <<Head:15/binary, Last>> = ?DEFAULT_KEY,
            <<Head/binary, ((Last + Index - 1) band 16#FF)>>;
        Key ->
            Key
    end.

%% Base64 (standard or URL-safe, padding optional) -> bytes, as stored
%% in a channel's settings.psk ("AQ==" -> <<1>>).
psk(Base64) ->
    B = unicode:characters_to_binary(Base64),
    Std = binary:replace(binary:replace(B, <<"-">>, <<"+">>, [global]),
                         <<"_">>, <<"/">>, [global]),
    Padded = case byte_size(Std) rem 4 of
                 0 -> Std;
                 N -> <<Std/binary, (binary:copy(<<"=">>, 4 - N))/binary>>
             end,
    base64:decode(Padded).

%% The channel number on the air: xor of the name's bytes, xor of the
%% key's bytes (generate_hash in the Python examples). LongFast with
%% the default key -> 8.
channel_hash(Name, Key) ->
    xor_bytes(unicode:characters_to_binary(Name)) bxor xor_bytes(Key).

xor_bytes(Bin) ->
    lists:foldl(fun(B, Acc) -> B bxor Acc end, 0, binary_to_list(Bin)).

%% Encrypt or decrypt (CTR mode is its own inverse). The nonce is the
%% packet id and the sender's node number, each 8 bytes little-endian.
crypt(<<>>, _Id, _From, Data) ->
    Data;
crypt(Key, Id, From, Data) ->
    Cipher = case byte_size(Key) of
                 16 -> aes_128_ctr;
                 32 -> aes_256_ctr
             end,
    Nonce = <<Id:64/little, From:64/little>>,
    crypto:crypto_one_time(Cipher, Key, Nonce, Data, true).

%%====================================================================
%% Packets and envelopes
%%====================================================================

%% A MeshPacket map carrying Data (#{portnum => ..., payload => ...}),
%% encrypted with Key, as generate_mesh_packet() in the Python examples.
%% Opts: from (node number), to (broadcast), id (random), channel_name
%% ("LongFast"), hop_limit (3), want_ack (false).
packet(Data, Key, From, Opts) ->
    Id = maps:get(id, Opts, rand:uniform(16#FFFFFFFE)),
    HopLimit = maps:get(hop_limit, Opts, 3),
    Base = #{from => From,
             to => maps:get(to, Opts, 16#FFFFFFFF),
             id => Id,
             channel => channel_hash(maps:get(channel_name, Opts, "LongFast"), Key),
             hop_limit => HopLimit,
             hop_start => HopLimit,
             want_ack => maps:get(want_ack, Opts, false)},
    case Key of
        <<>> -> Base#{decoded => Data};
        _ -> Base#{encrypted => crypt(Key, Id, From, mtc:encode(Data, data))}
    end.

%% ServiceEnvelope bytes to publish to <root>/<channel>/<gateway id>
envelope(Packet, ChannelId, GatewayId) ->
    mtc:encode(#{packet => Packet,
                 channel_id => unicode:characters_to_binary(ChannelId),
                 gateway_id => unicode:characters_to_binary(GatewayId)},
               service_envelope).

%% ServiceEnvelope bytes -> {ok, #{gateway_id, channel_id, packet}} |
%% {error, Reason}. An encrypted packet is decrypted with Key; it gets
%% decoded (and decoded's payload by port, as from a radio). When the
%% key does not fit (another channel, or a PKI direct message) the
%% packet keeps encrypted and gets decrypt_failed => true.
open(Bin, Key) ->
    try mtc:decode(Bin, service_envelope) of
        Envelope ->
            Packet = maps:get(packet, Envelope, #{}),
            {ok, (mtc:compact(Envelope, service_envelope))#{packet => open_packet(Packet, Key)}}
    catch
        _:Reason ->
            {error, {not_a_service_envelope, Reason}}
    end.

open_packet(#{encrypted := Encrypted} = Packet, Key) when Key =/= <<>> ->
    P = mtc:compact(Packet, mesh_packet),
    Plain = crypt(Key, maps:get(id, Packet), maps:get(from, Packet), Encrypted),
    try mtc:compact(mtc:decode(Plain, data), data) of
        #{portnum := _} = Data ->
            with_ids((maps:remove(encrypted, P))#{decoded => mtc:decode_app(Data)});
        _ ->
            with_ids(P#{decrypt_failed => true})
    catch
        _:_ -> with_ids(P#{decrypt_failed => true})
    end;
open_packet(Packet, _Key) ->
    P = mtc:compact(Packet, mesh_packet),
    case P of
        #{decoded := Data} -> with_ids(P#{decoded := mtc:decode_app(Data)});
        _ -> with_ids(P)
    end.

with_ids(P) ->
    P#{from_id => mtc:node_id(maps:get(from, P, 0)),
       to_id => mtc:node_id(maps:get(to, P, 0))}.

%% A node number like the Python examples' "!abcd" + 4 random hex digits
random_node() ->
    16#abcd0000 + rand:uniform(16#FFFF).

%% The --root option (or Default) as a topic prefix ending in "/"
root(Opts, Default) ->
    Root = maps:get(root, Opts, Default),
    case lists:last(Root) of
        $/ -> Root;
        _ -> Root ++ "/"
    end.
