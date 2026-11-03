%%
%% A fake MeshCore companion radio for tests, written from
%% examples/companion_radio/MyMesh.cpp (firmware v1.18, FIRMWARE_VER_CODE 14).
%%
%% It speaks the companion frame protocol on TCP, like the Wi-Fi firmware
%% on port 5000. Frames are built here byte by byte from the C++ source,
%% not with lora_mesh_meshcore_codec, so the codec is tested against an
%% independent reading of the firmware.
%%
%% What it does, as MyMesh::handleCmdFrame does:
%%   CMD_DEVICE_QUERY      -> RESP_DEVICE_INFO, remembers app_target_ver
%%   CMD_APP_START         -> RESP_SELF_INFO
%%   CMD_SET_DEVICE_TIME   -> OK if not going back in time, else ERR 6
%%   CMD_GET_CONTACTS      -> CONTACTS_START, CONTACT (lastmod > since)..., END_OF_CONTACTS
%%   CMD_SEND_TXT_MSG      -> RESP_SENT, or ERR 2 if the key prefix is unknown
%%   CMD_SEND_CHANNEL_TXT_MSG -> OK, or ERR 2 for an unknown channel
%%   CMD_SYNC_NEXT_MESSAGE -> the oldest queued message, or NO_MORE_MESSAGES
%%
%% The test plays the radio side: receive_dm/4 and receive_channel/5 queue
%% a message and push MSG_WAITING (MyMesh::queueMessage,
%% onChannelMessageRecv); hear_advert/3 pushes NEW_ADVERT or ADVERT
%% (onDiscoveredContact); confirm/2 pushes SEND_CONFIRMED (processAck).
%%
-module(lora_mesh_fake_companion).
-behaviour(gen_server).

-export([start/1]).
-export([port/1]).
-export([contact/3]).
-export([receive_dm/4]).
-export([receive_channel/5]).
-export([hear_advert/3]).
-export([confirm/2]).
-export([sent/1]).
-export([commands/1]).
-export([disconnect/1]).
-export([stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(FIRMWARE_VER_CODE, 14).
-define(FIRMWARE_VERSION, "v1.18.0").
-define(MAX_TEXT_LEN, 160).
-define(MAX_FRAME_SIZE, 176).
-define(OUT_PATH_UNKNOWN, 16#FF).
-define(ADV_TYPE_CHAT, 1).

-record(state, {
    name            :: binary(),
    pub_key         :: binary(),
    listen          :: gen_tcp:socket(),
    sock            :: gen_tcp:socket() | undefined,
    buffer = <<>>   :: binary(),
    app_target_ver = 0 :: byte(),
    clock           :: non_neg_integer(),
    contacts        :: [map()],
    channels        :: #{byte() => binary()},
    offline = []    :: [binary()],          % queued frames, oldest first
    sent = []       :: [tuple()],           % newest first
    commands = []   :: [byte()],            % newest first
    next_lastmod    :: non_neg_integer()}).

%%====================================================================
%% API
%%====================================================================

%% Opts: name, pub_key (32 bytes), contacts ([contact/3 maps]),
%%       channels (#{0 => <<"Public">>}), clock (device time, unix secs)
start(Opts) ->
    gen_server:start(?MODULE, Opts, []).

port(Fake) ->
    gen_server:call(Fake, port).

%% A contact as the companion keeps it (ContactInfo).
contact(PubKey, Name, Opts) ->
    maps:merge(#{pub_key => PubKey,
                 type => ?ADV_TYPE_CHAT,
                 flags => 0,
                 out_path_len => ?OUT_PATH_UNKNOWN,
                 name => Name,
                 last_advert => 1700000000,
                 lat => 0,                  % degrees * 1e6
                 lon => 0,
                 lastmod => 1},
               Opts).

%% A direct message arrives over the air from PubKey.
%% Opts: snr (dB), path_len (hops when flooded; 0xFF = direct route),
%%       sender_time
receive_dm(Fake, PubKey, Text, Opts) ->
    gen_server:call(Fake, {receive_dm, PubKey, Text, Opts}).

%% A channel message arrives: the air carries "<SenderName>: <Text>".
receive_channel(Fake, ChannelIdx, SenderName, Text, Opts) ->
    gen_server:call(Fake, {receive_channel, ChannelIdx, SenderName, Text, Opts}).

%% An advert is heard; a new contact is added (PUSH_NEW_ADVERT), a known
%% one is updated (PUSH_ADVERT with the key only).
hear_advert(Fake, PubKey, Changes) ->
    gen_server:call(Fake, {hear_advert, PubKey, Changes}).

%% The recipient acknowledged message Ack.
confirm(Fake, Ack) ->
    gen_server:call(Fake, {confirm, Ack}).

%% What the bridge asked the radio to send, oldest first:
%% {dm, PrefixHex, Text, Ack} | {channel, Idx, AirText}
sent(Fake) ->
    gen_server:call(Fake, sent).

%% Command codes received, oldest first.
commands(Fake) ->
    gen_server:call(Fake, commands).

%% Drop the connection, like Wi-Fi going away; the next one is accepted.
disconnect(Fake) ->
    gen_server:call(Fake, disconnect).

stop(Fake) ->
    gen_server:stop(Fake).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    {ok, Listen} = gen_tcp:listen(maps:get(port, Opts, 0), [binary,
                                                             {active, false},
                                                             {reuseaddr, true}]),
    Contacts = maps:get(contacts, Opts, []),
    State = #state{name = maps:get(name, Opts, <<"fake">>),
                   pub_key = maps:get(pub_key, Opts, crypto:strong_rand_bytes(32)),
                   listen = Listen,
                   clock = maps:get(clock, Opts, 1700000000),
                   contacts = Contacts,
                   channels = maps:get(channels, Opts, #{0 => <<"Public">>}),
                   next_lastmod = lists:max([0 | [L || #{lastmod := L} <- Contacts]]) + 1},
    accept(Listen),
    {ok, State}.

handle_call(port, _From, #state{listen = Listen} = State) ->
    {reply, inet:port(Listen), State};

handle_call({receive_dm, PubKey, Text, Opts}, _From, State) ->
    Frame = contact_msg_frame(PubKey, Text, Opts, State),
    {reply, ok, queue_message(Frame, State)};

handle_call({receive_channel, Idx, SenderName, Text, Opts}, _From, State) ->
    Frame = channel_msg_frame(Idx, <<SenderName/binary, ": ", Text/binary>>, Opts, State),
    {reply, ok, queue_message(Frame, State)};

handle_call({hear_advert, PubKey, Changes}, _From,
            #state{contacts = Contacts, next_lastmod = LastMod} = State) ->
    case lists:partition(fun(#{pub_key := K}) -> K =:= PubKey end, Contacts) of
        {[Old], Others} ->
            New = maps:merge(Old, Changes#{lastmod => LastMod}),
            write(State, <<16#80, PubKey/binary>>),                 % PUSH_CODE_ADVERT
            {reply, ok, State#state{contacts = Others ++ [New],
                                    next_lastmod = LastMod + 1}};
        {[], _} ->
            Name = maps:get(name, Changes, <<"new">>),
            New = contact(PubKey, Name, Changes#{lastmod => LastMod}),
            write(State, contact_frame(16#8A, New)),               % PUSH_CODE_NEW_ADVERT
            {reply, ok, State#state{contacts = Contacts ++ [New],
                                    next_lastmod = LastMod + 1}}
    end;

handle_call({confirm, Ack}, _From, State) ->
    write(State, <<16#82, Ack:32/little, 1234:32/little>>),        % PUSH_CODE_SEND_CONFIRMED
    {reply, ok, State};

handle_call(sent, _From, #state{sent = Sent} = State) ->
    {reply, lists:reverse(Sent), State};

handle_call(commands, _From, #state{commands = Cmds} = State) ->
    {reply, lists:reverse(Cmds), State};

handle_call(disconnect, _From, #state{sock = Sock, listen = Listen} = State) ->
    case Sock of
        undefined -> ok;
        _ -> gen_tcp:close(Sock)
    end,
    accept(Listen),
    {reply, ok, State#state{sock = undefined, buffer = <<>>}}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({accepted, Sock}, State) ->
    ok = inet:setopts(Sock, [{active, true}]),
    {noreply, State#state{sock = Sock, buffer = <<>>}};

handle_info({tcp, Sock, Data}, #state{sock = Sock, buffer = Buf} = State) ->
    {Frames, Rest} = frames(<<Buf/binary, Data/binary>>, []),
    {noreply, lists:foldl(fun command/2, State#state{buffer = Rest}, Frames)};

handle_info({tcp_closed, Sock}, #state{sock = Sock, listen = Listen} = State) ->
    accept(Listen),
    {noreply, State#state{sock = undefined}};

handle_info(_Other, State) ->
    {noreply, State}.

%%====================================================================
%% Connection: '<' + len16le from the app, '>' + len16le to the app
%% (ArduinoSerialInterface / SerialWifiInterface)
%%====================================================================

accept(Listen) ->
    Server = self(),
    spawn(fun() ->
                  case gen_tcp:accept(Listen) of
                      {ok, Sock} ->
                          ok = gen_tcp:controlling_process(Sock, Server),
                          Server ! {accepted, Sock};
                      {error, _} ->
                          ok
                  end
          end).

frames(<<$<, Len:16/little, Payload:Len/binary, Rest/binary>>, Acc) ->
    frames(Rest, [Payload | Acc]);
frames(<<$<, _/binary>> = Partial, Acc) ->
    {lists:reverse(Acc), Partial};
frames(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
frames(<<_Junk, Rest/binary>>, Acc) ->
    frames(Rest, Acc).

write(#state{sock = undefined}, _Payload) ->
    ok;
write(#state{sock = Sock}, Payload) ->
    gen_tcp:send(Sock, [<<$>, (byte_size(Payload)):16/little>>, Payload]).

ok_frame(State) ->
    write(State, <<0>>).

err_frame(State, Code) ->
    write(State, <<1, Code>>).

%%====================================================================
%% MyMesh::handleCmdFrame
%%====================================================================

command(<<Code, _/binary>> = Frame, #state{commands = Cmds} = State) ->
    handle_command(Frame, State#state{commands = [Code | Cmds]}).

% CMD_DEVICE_QUERY
handle_command(<<22, AppTargetVer, _/binary>>, State) ->
    write(State, <<13,                              % RESP_CODE_DEVICE_INFO
                   ?FIRMWARE_VER_CODE,
                   (350 div 2),                     % MAX_CONTACTS / 2
                   40,                              % MAX_GROUP_CHANNELS
                   123456:32/little,                % ble_pin
                   (pad(<<"16 Oct 2026">>, 12))/binary,
                   (pad(<<"Heltec V3">>, 40))/binary,
                   (pad(<<?FIRMWARE_VERSION>>, 20))/binary,
                   0,                               % repeat enabled (v9+)
                   0>>),                            % path_hash_mode (v10+)
    State#state{app_target_ver = AppTargetVer};

% CMD_APP_START: 7 reserved bytes, then the app name
handle_command(<<1, _Reserved:7/binary, _AppName/binary>>,
               #state{pub_key = PubKey, name = Name} = State) ->
    write(State, <<5,                               % RESP_CODE_SELF_INFO
                   ?ADV_TYPE_CHAT,
                   22,                              % tx_power_dbm
                   22,                              % MAX_LORA_TX_POWER
                   PubKey/binary,
                   25033000:32/little-signed,       % lat * 1e6 (Taipei)
                   121565000:32/little-signed,      % lon * 1e6
                   0, 0, 0, 0,                      % multi_acks, advert_loc_policy, telemetry, manual_add
                   923125000:32/little,             % freq * 1000
                   250000:32/little,                % bw * 1000
                   11, 5,                           % sf, cr
                   Name/binary>>),                  % no terminator
    State;

% CMD_SET_DEVICE_TIME: only forward in time
handle_command(<<6, Secs:32/little, _/binary>>, #state{clock = Clock} = State) ->
    case Secs >= Clock of
        true ->
            ok_frame(State),
            State#state{clock = Secs};
        false ->
            err_frame(State, 6),                    % ERR_CODE_ILLEGAL_ARG
            State
    end;

% CMD_GET_CONTACTS [since]
handle_command(<<4, Rest/binary>>, #state{contacts = Contacts} = State) ->
    Since = case Rest of
                <<S:32/little, _/binary>> -> S;
                _ -> 0
            end,
    write(State, <<2, (length(Contacts)):32/little>>),   % total, not filtered
    Newer = [C || #{lastmod := L} = C <- Contacts, L > Since],
    [write(State, contact_frame(3, C)) || C <- Newer],
    MostRecent = lists:max([0 | [L || #{lastmod := L} <- Newer]]),
    write(State, <<4, MostRecent:32/little>>),
    State;

% CMD_SEND_TXT_MSG: txt_type, attempt, timestamp, 6-byte key prefix, text
handle_command(<<2, TxtType, _Attempt, _Time:32/little, Prefix:6/binary, Text/binary>>,
               #state{contacts = Contacts, sent = Sent} = State) ->
    case [C || #{pub_key := <<P:6/binary, _/binary>>} = C <- Contacts, P =:= Prefix] of
        [Contact | _] when TxtType =:= 0 ->
            Ack = erlang:phash2({Prefix, Text}, 1 bsl 32),
            Flood = case maps:get(out_path_len, Contact) of
                        ?OUT_PATH_UNKNOWN -> 1;
                        _ -> 0
                    end,
            write(State, <<6, Flood, Ack:32/little, 3000:32/little>>),
            State#state{sent = [{dm, binary:encode_hex(Prefix, lowercase), Text, Ack} | Sent]};
        [_ | _] ->
            err_frame(State, 1),                    % ERR_CODE_UNSUPPORTED_CMD
            State;
        [] ->
            err_frame(State, 2),                    % ERR_CODE_NOT_FOUND
            State
    end;

% CMD_SEND_CHANNEL_TXT_MSG: txt_type, channel, timestamp, text
handle_command(<<3, 0, Idx, _Time:32/little, Text/binary>>,
               #state{channels = Channels, name = Name, sent = Sent} = State) ->
    case Channels of
        #{Idx := _} ->
            %% BaseChatMesh::sendGroupMessage: "<name>: <text>", cut to MAX_TEXT_LEN
            Air = <<Name/binary, ": ", Text/binary>>,
            Cut = binary:part(Air, 0, min(byte_size(Air), ?MAX_TEXT_LEN)),
            ok_frame(State),
            State#state{sent = [{channel, Idx, Cut} | Sent]};
        #{} ->
            err_frame(State, 2),
            State
    end;

% CMD_SYNC_NEXT_MESSAGE
handle_command(<<10, _/binary>>, #state{offline = Offline} = State) ->
    case Offline of
        [Frame | Rest] ->
            write(State, Frame),
            State#state{offline = Rest};
        [] ->
            write(State, <<10>>),                   % RESP_CODE_NO_MORE_MESSAGES
            State
    end;

handle_command(_Other, State) ->
    err_frame(State, 1),
    State.

%%====================================================================
%% Frames, as MyMesh.cpp writes them
%%====================================================================

%% writeContactRespFrame
contact_frame(Code, #{pub_key := PubKey, type := Type, flags := Flags,
                      out_path_len := PathLen, name := Name,
                      last_advert := LastAdvert, lat := Lat, lon := Lon,
                      lastmod := LastMod}) ->
    <<Code,
      PubKey:32/binary,
      Type,
      Flags,
      PathLen,
      0:(64 * 8),                                   % out_path, MAX_PATH_SIZE
      (pad(Name, 32))/binary,
      LastAdvert:32/little,
      Lat:32/little-signed,
      Lon:32/little-signed,
      LastMod:32/little>>.

%% queueMessage
contact_msg_frame(PubKey, Text, Opts, State) ->
    <<Prefix:6/binary, _/binary>> = PubKey,
    Body = <<Prefix/binary,
             (maps:get(path_len, Opts, 0)),
             0,                                     % TXT_TYPE_PLAIN
             (maps:get(sender_time, Opts, 1761700000)):32/little,
             Text/binary>>,
    cut(<<(msg_header(16#10, 7, Opts, State))/binary, Body/binary>>).

%% onChannelMessageRecv
channel_msg_frame(Idx, AirText, Opts, State) ->
    Body = <<Idx,
             (maps:get(path_len, Opts, 0)),
             0,
             (maps:get(sender_time, Opts, 1761700000)):32/little,
             AirText/binary>>,
    cut(<<(msg_header(16#11, 8, Opts, State))/binary, Body/binary>>).

%% v3 apps get SNR * 4 and two reserved bytes
msg_header(CodeV3, _Code, Opts, #state{app_target_ver = Ver}) when Ver >= 3 ->
    Snr4 = round(maps:get(snr, Opts, 0.0) * 4),
    <<CodeV3, Snr4:8/signed, 0, 0>>;
msg_header(_CodeV3, Code, _Opts, _State) ->
    <<Code>>.

queue_message(Frame, #state{offline = Offline} = State) ->
    write(State, <<16#83>>),                        % PUSH_CODE_MSG_WAITING
    State#state{offline = Offline ++ [Frame]}.

cut(Frame) ->
    binary:part(Frame, 0, min(byte_size(Frame), ?MAX_FRAME_SIZE)).

%% StrHelper::strzcpy: NUL-terminated within N bytes
pad(Bin, N) ->
    B = binary:part(Bin, 0, min(byte_size(Bin), N - 1)),
    <<B/binary, 0:((N - byte_size(B)) * 8)>>.
