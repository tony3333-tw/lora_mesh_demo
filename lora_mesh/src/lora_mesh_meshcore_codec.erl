%%
%% MeshCore companion protocol: frames, commands and responses.
%%
%% Pure functions, no processes. Every layout below is taken from the
%% MeshCore firmware source (meshcore-dev/MeshCore, commit 81dbae5):
%%   examples/companion_radio/MyMesh.cpp      commands and responses
%%   src/helpers/ArduinoSerialInterface.cpp   serial framing
%%   src/helpers/wifi/SerialWifiInterface.cpp TCP framing (same header)
%%
%% Framing, the same on USB serial and Wi-Fi TCP (port 5000):
%%   computer -> device:  $<  Len:16/little  Payload
%%   device -> computer:  $>  Len:16/little  Payload
%% The first payload byte is the command, response or push code.
%% Multi-byte integers are little-endian; text is UTF-8.
%%
-module(lora_mesh_meshcore_codec).

%% framing
-export([frame/1]).
-export([decode/1]).

%% commands
-export([device_query/1]).
-export([app_start/1]).
-export([set_device_time/1]).
-export([get_contacts/1]).
-export([sync_next_message/0]).
-export([send_txt_msg/4]).
-export([send_channel_txt_msg/3]).

%% responses and pushes
-export([response/1]).
-export([hops/1]).
-export([path_hashes/2]).
-export([packet/1]).
-export([max_text_len/0]).

%% command codes
-define(CMD_APP_START, 1).
-define(CMD_SEND_TXT_MSG, 2).
-define(CMD_SEND_CHANNEL_TXT_MSG, 3).
-define(CMD_GET_CONTACTS, 4).
-define(CMD_SET_DEVICE_TIME, 6).
-define(CMD_SYNC_NEXT_MESSAGE, 10).
-define(CMD_DEVICE_QUERY, 22).

%% response codes
-define(RESP_OK, 0).
-define(RESP_ERR, 1).
-define(RESP_CONTACTS_START, 2).
-define(RESP_CONTACT, 3).
-define(RESP_END_OF_CONTACTS, 4).
-define(RESP_SELF_INFO, 5).
-define(RESP_SENT, 6).
-define(RESP_CONTACT_MSG_RECV, 7).
-define(RESP_CHANNEL_MSG_RECV, 8).
-define(RESP_CURR_TIME, 9).
-define(RESP_NO_MORE_MESSAGES, 10).
-define(RESP_DEVICE_INFO, 13).
-define(RESP_DISABLED, 15).
-define(RESP_CONTACT_MSG_RECV_V3, 16).
-define(RESP_CHANNEL_MSG_RECV_V3, 17).

%% push codes (sent by the device at any time)
-define(PUSH_ADVERT, 16#80).
-define(PUSH_PATH_UPDATED, 16#81).
-define(PUSH_SEND_CONFIRMED, 16#82).
-define(PUSH_MSG_WAITING, 16#83).
-define(PUSH_LOG_RX_DATA, 16#88).
-define(PUSH_NEW_ADVERT, 16#8A).

%% raw packets (src/Packet.h)
-define(ROUTE_TRANSPORT_FLOOD, 0).
-define(ROUTE_FLOOD, 1).
-define(ROUTE_DIRECT, 2).
-define(ROUTE_TRANSPORT_DIRECT, 3).
-define(PAYLOAD_TXT_MSG, 16#02).
-define(PAYLOAD_GRP_TXT, 16#05).

-define(TXT_TYPE_PLAIN, 0).
-define(TXT_TYPE_SIGNED_PLAIN, 2).

-define(MAX_TEXT_LEN, 160).     % 10 * CIPHER_BLOCK_SIZE, BaseChatMesh.h
-define(MAX_FRAME, 255).        % firmware sends at most 176 (MAX_FRAME_SIZE)
-define(PATH_DIRECT, 16#FF).    % OUT_PATH_UNKNOWN: delivered by a direct route

%%====================================================================
%% Framing
%%====================================================================

%% Wrap one command payload for sending to the device.
-spec frame(iodata()) -> iodata().
frame(Payload) ->
    Len = iolist_size(Payload),
    [<<$<,
       Len:16/little>>,
     Payload].

%% Pull every complete device frame out of a buffer.
%% Bytes outside a frame (e.g. debug text on USB serial) are skipped.
-spec decode(binary()) -> {[binary()], binary()}.
decode(Buffer) ->
    decode(Buffer, []).

decode(<<$>,
         Len:16/little,
         Rest/binary>>,
       Acc)
  when Len > 0,
       Len =< ?MAX_FRAME ->
    case Rest of
        <<Payload:Len/binary,
          Tail/binary>> ->
            decode(Tail, [Payload | Acc]);
        _ ->
            %% frame not complete yet
            {lists:reverse(Acc),
             <<$>,
               Len:16/little,
               Rest/binary>>}
    end;
decode(<<$>,
         Rest/binary>>,
       Acc)
  when byte_size(Rest) >= 2 ->
    %% a '>' with an impossible length: not a frame, resync
    decode(Rest, Acc);
decode(<<$>>> = Partial, Acc) ->
    {lists:reverse(Acc), Partial};
decode(<<$>, _>> = Partial, Acc) ->
    {lists:reverse(Acc), Partial};
decode(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
decode(<<_Junk,
         Rest/binary>>,
       Acc) ->
    decode(Rest, Acc).

%%====================================================================
%% Commands (computer -> device), payloads without the frame header
%%====================================================================

%% Tell the device which protocol version we understand.
%% 3 or more makes it send SNR with every message (the *_V3 responses).
device_query(AppTargetVer) ->
    <<?CMD_DEVICE_QUERY,
      AppTargetVer>>.

%% Identify the app; the device answers with its own identity (SELF_INFO).
%% Bytes 1..7 are reserved, the app name follows.
app_start(AppName) ->
    <<?CMD_APP_START,
      0:56,
      (unicode:characters_to_binary(AppName))/binary>>.

%% Set the device clock (Unix seconds). The device refuses to go backwards.
set_device_time(UnixSecs) ->
    <<?CMD_SET_DEVICE_TIME,
      UnixSecs:32/little>>.

%% All contacts changed after Since (the 'lastmod' of an earlier listing).
get_contacts(0) ->
    <<?CMD_GET_CONTACTS>>;
get_contacts(Since) ->
    <<?CMD_GET_CONTACTS,
      Since:32/little>>.

%% Ask for the next queued message (answers a MSG_WAITING push).
sync_next_message() ->
    <<?CMD_SYNC_NEXT_MESSAGE>>.

%% Direct message to a contact, addressed by the first 6 bytes of its key.
send_txt_msg(<<_:6/binary>> = PubKeyPrefix, Text, UnixSecs, Attempt) ->
    <<?CMD_SEND_TXT_MSG,
      ?TXT_TYPE_PLAIN,
      Attempt,
      UnixSecs:32/little,
      PubKeyPrefix/binary,
      (unicode:characters_to_binary(Text))/binary>>.

%% Message to everyone on a channel slot (0 = Public by default).
send_channel_txt_msg(ChannelIdx, Text, UnixSecs) ->
    <<?CMD_SEND_CHANNEL_TXT_MSG,
      ?TXT_TYPE_PLAIN,
      ChannelIdx,
      UnixSecs:32/little,
      (unicode:characters_to_binary(Text))/binary>>.

%% Longest text the firmware accepts in one message, in bytes.
%% A channel message also carries "<sender name>: " inside this limit.
max_text_len() ->
    ?MAX_TEXT_LEN.

%%====================================================================
%% Responses and pushes (device -> computer)
%%====================================================================

-spec response(binary()) -> tuple() | atom().
response(<<?RESP_OK, _/binary>>) ->
    ok;
response(<<?RESP_ERR, ErrCode, _/binary>>) ->
    {err, err_code(ErrCode)};
response(<<?RESP_ERR>>) ->
    {err, unknown};
response(<<?RESP_DISABLED, _/binary>>) ->
    {err, disabled};
response(<<?RESP_CONTACTS_START,
           Count:32/little,
           _/binary>>) ->
    {contacts_start, Count};
response(<<?RESP_CONTACT,
           Contact/binary>>) ->
    {contact, contact(Contact)};
response(<<?RESP_END_OF_CONTACTS,
           LastMod:32/little,
           _/binary>>) ->
    {end_of_contacts, LastMod};
response(<<?RESP_SELF_INFO,
           AdvType,
           TxPower,
           _MaxTxPower,
           PubKey:32/binary,
           Lat:32/little-signed,
           Lon:32/little-signed,
           Rest/binary>>) ->
    {self_info, #{adv_type => adv_type(AdvType),
                  tx_power => TxPower,
                  pub_key => PubKey,
                  latitude => Lat / 1.0e6,
                  longitude => Lon / 1.0e6,
                  name => self_name(Rest)}};
response(<<?RESP_SENT,
           Flood,
           ExpectedAck:32/little,
           EstTimeoutMs:32/little,
           _/binary>>) ->
    {sent, #{flood => Flood =:= 1,
             expected_ack => ExpectedAck,
             timeout_ms => EstTimeoutMs}};
response(<<?RESP_CONTACT_MSG_RECV_V3,
           Snr4:8/signed,
           _Reserved:16,
           Msg/binary>>) ->
    contact_msg(Snr4 / 4, Msg);
response(<<?RESP_CONTACT_MSG_RECV,
           Msg/binary>>) ->
    contact_msg(undefined, Msg);
response(<<?RESP_CHANNEL_MSG_RECV_V3,
           Snr4:8/signed,
           _Reserved:16,
           Msg/binary>>) ->
    channel_msg(Snr4 / 4, Msg);
response(<<?RESP_CHANNEL_MSG_RECV,
           Msg/binary>>) ->
    channel_msg(undefined, Msg);
response(<<?RESP_CURR_TIME,
           Secs:32/little,
           _/binary>>) ->
    {curr_time, Secs};
response(<<?RESP_NO_MORE_MESSAGES, _/binary>>) ->
    no_more_messages;
response(<<?RESP_DEVICE_INFO,
           FirmwareVerCode,
           Rest/binary>>) ->
    {device_info, device_info(FirmwareVerCode, Rest)};
response(<<?PUSH_ADVERT,
           PubKey:32/binary,
           _/binary>>) ->
    {advert, PubKey};
response(<<?PUSH_PATH_UPDATED,
           PubKey:32/binary,
           _/binary>>) ->
    {path_updated, PubKey};
response(<<?PUSH_SEND_CONFIRMED,
           Ack:32/little,
           TripMs:32/little,
           _/binary>>) ->
    {send_confirmed, Ack, TripMs};
response(<<?PUSH_MSG_WAITING, _/binary>>) ->
    msg_waiting;
response(<<?PUSH_NEW_ADVERT,
           Contact/binary>>) ->
    {new_advert, contact(Contact)};
%% logRxRaw: every packet the radio hears, before it is checked or merged,
%% so copies relayed by several repeaters each arrive here
response(<<?PUSH_LOG_RX_DATA,
           Snr4:8/signed,
           Rssi:8/signed,
           Raw/binary>>) ->
    {rx_log, #{snr => Snr4 / 4,
               rssi => Rssi,
               raw => Raw}};
response(<<Code, Rest/binary>>) ->
    {unknown, Code, Rest}.

%% path_len -> hops: the low 6 bits count path hashes (one per repeater);
%% the top 2 bits give the hash size. 0xFF = direct route, hops unknown.
-spec hops(byte()) -> non_neg_integer() | direct.
hops(?PATH_DIRECT) ->
    direct;
hops(PathLen) ->
    PathLen band 63.

%% A path as the firmware stores it (Packet::getPathHashSize/Count):
%% PathLen's top 2 bits are the hash size - 1, the low 6 bits the number
%% of hashes; Bytes start with them. -> [Hash], first repeater first.
%% 0xFF (OUT_PATH_UNKNOWN in a contact) -> undefined.
-spec path_hashes(byte(), binary()) -> [binary()] | undefined.
path_hashes(?PATH_DIRECT, _Bytes) ->
    undefined;
path_hashes(PathLen, Bytes) ->
    Size = (PathLen bsr 6) + 1,
    Count = PathLen band 63,
    case Bytes of
        <<Path:(Size * Count)/binary, _/binary>> ->
            [H || <<H:Size/binary>> <= Path];
        _ ->
            undefined
    end.

%% A raw packet from rx_log (Packet::readFrom):
%%   header: version(2 bits) payload type(4) route type(2)
%%   [transport codes, 4 bytes, for the two transport route types]
%%   path_len, path, payload
%% Only what lora_mesh uses is decoded: for TXT_MSG the first payload
%% bytes are the destination and sender hashes (1 byte each,
%% PATH_HASH_SIZE), for GRP_TXT the channel hash.
-spec packet(binary()) -> {ok, map()} | error.
packet(<<Header, Rest/binary>>) ->
    Route = Header band 3,
    Type = (Header bsr 2) band 16#0F,
    After = case Route of
                ?ROUTE_TRANSPORT_FLOOD -> skip_transport(Rest);
                ?ROUTE_TRANSPORT_DIRECT -> skip_transport(Rest);
                _ -> Rest
            end,
    case After of
        <<PathLen, More/binary>> ->
            ByteLen = ((PathLen bsr 6) + 1) * (PathLen band 63),
            case More of
                <<Path:ByteLen/binary, Payload/binary>> when Payload =/= <<>> ->
                    {ok, maps:merge(#{route => route(Route),
                                      type => payload_type(Type),
                                      path_len => PathLen,
                                      path => path_hashes(PathLen, Path)},
                                    payload_ids(Type, Payload))};
                _ ->
                    error
            end;
        _ ->
            error
    end;
packet(_) ->
    error.

%%====================================================================
%% Internal
%%====================================================================

%% writeContactRespFrame: key, type, flags, path, name, times, position.
%% out_path: the route this radio uses to reach the contact, first hop
%% first ([] = in radio range, undefined = no route known: flood).
contact(<<PubKey:32/binary,
          Type,
          Flags,
          OutPathLen,
          OutPath:64/binary,
          Name:32/binary,
          LastAdvert:32/little,
          Lat:32/little-signed,
          Lon:32/little-signed,
          LastMod:32/little,
          _/binary>>) ->
    #{pub_key => PubKey,
      type => adv_type(Type),
      flags => Flags,
      out_path_len => OutPathLen,
      out_path => path_hashes(OutPathLen, OutPath),
      name => cstring(Name),
      last_advert => LastAdvert,
      latitude => Lat / 1.0e6,
      longitude => Lon / 1.0e6,
      lastmod => LastMod}.

%% queueMessage: sender key prefix, path, text type, sender time, text
contact_msg(Snr,
            <<Prefix:6/binary,
              PathLen,
              TxtType,
              SenderTime:32/little,
              Rest/binary>>) ->
    Text = case TxtType of
               ?TXT_TYPE_SIGNED_PLAIN ->
                   <<_SignerPrefix:4/binary, T/binary>> = Rest,
                   T;
               _ ->
                   Rest
           end,
    {contact_msg, #{from_prefix => Prefix,
                    snr => Snr,
                    path_len => PathLen,
                    txt_type => TxtType,
                    sender_time => SenderTime,
                    text => cstring(Text)}}.

%% onChannelMessageRecv: channel slot, path, text type, sender time, text.
%% The text is "<sender name>: <message>" (BaseChatMesh::sendGroupMessage).
channel_msg(Snr,
            <<ChannelIdx,
              PathLen,
              TxtType,
              SenderTime:32/little,
              Text/binary>>) ->
    {Sender, Body} = split_sender(cstring(Text)),
    {channel_msg, #{channel => ChannelIdx,
                    snr => Snr,
                    path_len => PathLen,
                    txt_type => TxtType,
                    sender_time => SenderTime,
                    sender_name => Sender,
                    text => Body}}.

device_info(FirmwareVerCode,
            <<MaxContactsHalf,
              MaxChannels,
              _BlePin:32/little,
              BuildDate:12/binary,
              Manufacturer:40/binary,
              Version:20/binary,
              _/binary>>) ->
    #{firmware_ver_code => FirmwareVerCode,
      max_contacts => MaxContactsHalf * 2,
      max_channels => MaxChannels,
      build_date => cstring(BuildDate),
      manufacturer => cstring(Manufacturer),
      version => cstring(Version)};
device_info(FirmwareVerCode, _Older) ->
    #{firmware_ver_code => FirmwareVerCode}.

%% SELF_INFO: after position come 4 setting bytes, frequency, bandwidth,
%% spreading factor and coding rate, then the node name.
self_name(<<_MultiAcks,
            _AdvLocPolicy,
            _Telemetry,
            _ManualAdd,
            _Freq:32/little,
            _Bw:32/little,
            _Sf,
            _Cr,
            Name/binary>>) ->
    cstring(Name);
self_name(_Older) ->
    <<>>.

skip_transport(<<_Codes:4/binary, Rest/binary>>) -> Rest;
skip_transport(_) -> <<>>.

route(?ROUTE_TRANSPORT_FLOOD) -> flood;
route(?ROUTE_FLOOD) -> flood;
route(?ROUTE_DIRECT) -> direct;
route(?ROUTE_TRANSPORT_DIRECT) -> direct.

payload_type(?PAYLOAD_TXT_MSG) -> txt_msg;
payload_type(?PAYLOAD_GRP_TXT) -> grp_txt;
payload_type(Other) -> Other.

payload_ids(?PAYLOAD_TXT_MSG, <<Dest, Src, _/binary>>) ->
    #{dest_hash => Dest, src_hash => Src};
payload_ids(?PAYLOAD_GRP_TXT, <<Channel, _/binary>>) ->
    #{channel_hash => Channel};
payload_ids(_Type, _Payload) ->
    #{}.

split_sender(Text) ->
    case binary:split(Text, <<": ">>) of
        [Sender, Body] -> {Sender, Body};
        [Body] -> {undefined, Body}
    end.

%% text up to the first NUL
cstring(Bin) ->
    case binary:split(Bin, <<0>>) of
        [Text | _] -> Text
    end.

adv_type(0) -> none;
adv_type(1) -> chat;
adv_type(2) -> repeater;
adv_type(3) -> room;
adv_type(4) -> sensor;
adv_type(N) -> N.

err_code(1) -> unsupported_cmd;
err_code(2) -> not_found;
err_code(3) -> table_full;
err_code(4) -> bad_state;
err_code(5) -> file_io_error;
err_code(6) -> illegal_arg;
err_code(N) -> N.
