%%
%% One bridge to a MeshCore companion radio, over USB serial or Wi-Fi TCP.
%%
%% The MeshCore counterpart of lora_mesh_node (Meshtastic): same pg
%% groups, same {send, #mesh_tx{}} call, same records out, so the router,
%% registry, MQTT connector and Python client work unchanged.
%%
%% How a companion talks (examples/companion_radio/MyMesh.cpp):
%%   - one command at a time; the device answers each with a response
%%     code below 0x80 (a contact listing answers with several frames);
%%   - push codes (0x80 and up) arrive at any time;
%%   - messages are pulled: PUSH MSG_WAITING, then CMD_SYNC_NEXT_MESSAGE
%%     until RESP NO_MORE_MESSAGES.
%%
%% Startup: DEVICE_QUERY (protocol 3, so messages carry SNR), APP_START
%% (our identity), SET_DEVICE_TIME, GET_CONTACTS, then one sync round.
%%
%% Node numbers: the first 6 bytes of a public key, as an integer with
%% bit 48 set so they never collide with 32-bit Meshtastic numbers.
%% Ids: <<"@0a0b0c0d0e0f">>.
%%
-module(lora_mesh_meshcore).
-behaviour(gen_server).

-export([start_link/1]).
-export([node_num/1]).
-export([node_id/1]).
-export([is_node_num/1]).
-export([prefix/1]).
-export([num_from_hex/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("lora_mesh.hrl").

-define(CODEC, lora_mesh_meshcore_codec).
-define(TAG, (1 bsl 48)).
-define(APP_NAME, "lora_mesh").
-define(PROTOCOL_VERSION, 3).
-define(TCP_PORT, 5000).
-define(BAUD, 115200).
-define(COMMAND_TIMEOUT_MS, 5000).
-define(RECONNECT_MIN_MS, 1000).
-define(RECONNECT_MAX_MS, 30000).

-record(state, {
    id                              :: atom(),
    transport                       :: tcp | serial,
    host                            :: inet:hostname() | inet:ip_address() | undefined,
    port                            :: inet:port_number() | undefined,
    device                          :: string() | undefined,
    baud                            :: pos_integer(),
    start_delay_ms                  :: non_neg_integer(),
    conn = undefined                :: undefined
                                     | {tcp, gen_tcp:socket()}
                                     | {serial, port(), file:fd(), integer()},
    buffer = <<>>                   :: binary(),
    self = undefined                :: map() | undefined,
    queue = queue:new()             :: queue:queue({binary(), atom(), term()}),
    current = undefined             :: undefined | {atom(), term(), reference()},
    sync_queued = false             :: boolean(),
    contacts_queued = false         :: boolean(),
    contacts_since = 0              :: non_neg_integer(),
    backoff = ?RECONNECT_MIN_MS     :: pos_integer()}).

%%====================================================================
%% API
%%====================================================================

%% Opts: #{id => home,
%%         transport => serial, device => "/dev/ttyUSB0", baud => 115200}
%%    or #{id => home,
%%         transport => tcp, host => "192.168.1.60", port => 5000}
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% 6-byte key prefix -> registry number
node_num(<<Prefix:48>>) ->
    ?TAG bor Prefix.

%% registry number -> <<"@0a0b0c0d0e0f">>
node_id(Num) ->
    iolist_to_binary(io_lib:format("@~12.16.0b", [Num band (?TAG - 1)])).

is_node_num(Num) ->
    is_integer(Num) andalso Num >= ?TAG andalso Num < 2 * ?TAG.

%% registry number -> 6-byte key prefix
prefix(Num) ->
    <<(Num band (?TAG - 1)):48>>.

%% <<"0a0b0c0d0e0f">> (12 hex digits) -> registry number
num_from_hex(Hex) when byte_size(Hex) =:= 12 ->
    ?TAG bor binary_to_integer(Hex, 16).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    Id = maps:get(id, Opts),
    Transport = maps:get(transport, Opts, serial),
    %% so terminate/2 runs on shutdown and stops the serial reader
    process_flag(trap_exit, true),
    ok = pg:join(?PG_SCOPE, ?PG_BRIDGES, self()),
    ok = pg:join(?PG_SCOPE, ?PG_BRIDGE(Id), self()),
    ok = pg:join(?PG_SCOPE, ?PG_PROTOCOL(meshcore), self()),
    self() ! connect,
    {ok, #state{
            id = Id,
            transport = Transport,
            host = maps:get(host, Opts, undefined),
            port = maps:get(port, Opts, ?TCP_PORT),
            device = maps:get(device, Opts, undefined),
            baud = maps:get(baud, Opts, ?BAUD),
            %% opening a USB serial port can reset the board; let it boot
            start_delay_ms = maps:get(start_delay_ms, Opts,
                                      case Transport of
                                          serial -> 2000;
                                          tcp -> 0
                                      end)}}.

handle_call({send, _Tx}, _From, #state{conn = undefined} = State) ->
    {reply, {error, not_connected}, State};
handle_call({send, #mesh_tx{to = To, channel = Channel, text = Text}}, From, State) ->
    Bin = unicode:characters_to_binary(Text),
    Now = erlang:system_time(second),
    Max = ?CODEC:max_text_len(),
    case To of
        ?MESH_BROADCAST ->
            %% the device sends "<its name>: <text>", all within Max bytes
            NameLen = byte_size(self_name(State)) + 2,
            case NameLen + byte_size(Bin) =< Max of
                true ->
                    {noreply, enqueue(?CODEC:send_channel_txt_msg(Channel, Bin, Now),
                                      send, From, State)};
                false ->
                    {reply, {error, too_long}, State}
            end;
        _ ->
            case is_node_num(To) of
                false ->
                    {reply, {error, wrong_protocol}, State};
                true when byte_size(Bin) > Max ->
                    {reply, {error, too_long}, State};
                true ->
                    {noreply, enqueue(?CODEC:send_txt_msg(prefix(To), Bin, Now, 0),
                                      send, From, State)}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect, State) ->
    do_connect(State);

handle_info(start, #state{conn = undefined} = State) ->
    {noreply, State};
handle_info(start, State) ->
    State2 = enqueue(?CODEC:device_query(?PROTOCOL_VERSION), device_query, undefined, State),
    State3 = enqueue(?CODEC:app_start(?APP_NAME), app_start, undefined, State2),
    State4 = enqueue(?CODEC:set_device_time(erlang:system_time(second)),
                     set_time, undefined, State3),
    {noreply, queue_sync(queue_contacts(State4))};

% bytes from the device
handle_info({tcp, Sock, Data}, #state{conn = {tcp, Sock}} = State) ->
    {noreply, received(Data, State)};
handle_info({Port, {data, Data}}, #state{conn = {serial, Port, _, _}} = State) ->
    {noreply, received(Data, State)};

% connection lost
handle_info({tcp_closed, Sock}, #state{conn = {tcp, Sock}} = State) ->
    lost(closed, State);
handle_info({tcp_error, Sock, Reason}, #state{conn = {tcp, Sock}} = State) ->
    lost(Reason, State);
handle_info({Port, {exit_status, Status}}, #state{conn = {serial, Port, _, _}} = State) ->
    lost({serial_exit, Status}, State);

% the device did not answer the current command
handle_info({timeout, Ref, Kind}, #state{current = {Kind, From, Ref}, id = Id} = State) ->
    logger:warning("lora_mesh_meshcore ~p: no answer to ~p", [Id, Kind]),
    reply(From, {error, timeout}),
    {noreply, next(clear_flag(Kind, State#state{current = undefined}))};

% the serial reader ended (its exit_status already came) / we are shut down
handle_info({'EXIT', _From, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', _From, Reason}, State) ->
    {stop, Reason, State};

handle_info(Unknown, #state{id = Id} = State) ->
    logger:debug("lora_mesh_meshcore ~p: unknown message ~p", [Id, Unknown]),
    {noreply, State}.

terminate(_Reason, State) ->
    close(State#state.conn).

%%====================================================================
%% Connection
%%====================================================================

do_connect(#state{id = Id} = State) ->
    case open(State) of
        {ok, Conn} ->
            logger:notice("lora_mesh_meshcore ~p: connected (~s)", [Id, describe(State)]),
            erlang:send_after(State#state.start_delay_ms, self(), start),
            {noreply, State#state{conn = Conn,
                                  buffer = <<>>,
                                  backoff = ?RECONNECT_MIN_MS}};
        {error, Reason} ->
            logger:warning("lora_mesh_meshcore ~p: cannot open ~s: ~p",
                           [Id, describe(State), Reason]),
            schedule_reconnect(State)
    end.

open(#state{transport = tcp, host = Host, port = Port}) ->
    case gen_tcp:connect(Host, Port, [binary,
                                      {active, true},
                                      {packet, raw},
                                      {nodelay, true},
                                      {keepalive, true}], 5000) of
        {ok, Sock} -> {ok, {tcp, Sock}};
        {error, _} = Error -> Error
    end;
open(#state{transport = serial, device = Device, baud = Baud}) ->
    %% stty sets raw mode and speed; `cat` streams the device to us;
    %% writes go straight to the device file.
    Dev = shell_quote(Device),
    Stty = "stty -F " ++ Dev ++ " " ++ integer_to_list(Baud)
        ++ " raw -echo -echoe -echok -hupcl 2>&1",
    case os:cmd(Stty) of
        "" ->
            Port = open_port({spawn_executable, "/bin/sh"},
                             [{args, ["-c", "exec cat " ++ Dev]},
                              binary,
                              stream,
                              exit_status,
                              use_stdio]),
            {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            case file:open(Device, [write, raw, binary]) of
                {ok, Fd} ->
                    {ok, {serial, Port, Fd, OsPid}};
                {error, _} = Error ->
                    close({serial, Port, undefined, OsPid}),
                    Error
            end;
        Output ->
            {error, {stty, string:trim(Output)}}
    end.

close(undefined) ->
    ok;
close({tcp, Sock}) ->
    gen_tcp:close(Sock);
close({serial, Port, Fd, OsPid}) ->
    catch port_close(Port),
    %% cat blocks in read() on the tty; stop it explicitly
    _ = os:cmd("kill " ++ integer_to_list(OsPid) ++ " 2>/dev/null"),
    case Fd of
        undefined -> ok;
        _ -> file:close(Fd)
    end.

lost(Reason, #state{id = Id} = State) ->
    logger:warning("lora_mesh_meshcore ~p: connection lost ~p", [Id, Reason]),
    schedule_reconnect(State).

schedule_reconnect(#state{conn = Conn, backoff = Backoff, current = Current, queue = Q} = State) ->
    close(Conn),
    %% callers waiting for an answer will not get one
    case Current of
        {_, From, Ref} ->
            erlang:cancel_timer(Ref),
            reply(From, {error, not_connected});
        undefined ->
            ok
    end,
    [reply(From, {error, not_connected}) || {_, _, From} <- queue:to_list(Q)],
    erlang:send_after(Backoff, self(), connect),
    {noreply, State#state{conn = undefined,
                          buffer = <<>>,
                          queue = queue:new(),
                          current = undefined,
                          sync_queued = false,
                          contacts_queued = false,
                          backoff = min(Backoff * 2, ?RECONNECT_MAX_MS)}}.

write(#state{conn = {tcp, Sock}}, Payload) ->
    gen_tcp:send(Sock, ?CODEC:frame(Payload));
write(#state{conn = {serial, _, Fd, _}}, Payload) ->
    file:write(Fd, ?CODEC:frame(Payload)).

describe(#state{transport = tcp, host = Host, port = Port}) ->
    io_lib:format("tcp ~s:~p", [inet_name(Host), Port]);
describe(#state{transport = serial, device = Device, baud = Baud}) ->
    io_lib:format("serial ~s ~p", [Device, Baud]).

inet_name(Host) when is_list(Host) -> Host;
inet_name(Host) -> inet:ntoa(Host).

shell_quote(String) ->
    "'" ++ string:replace(String, "'", "'\\''", all) ++ "'".

%%====================================================================
%% Command queue: one command in flight at a time
%%====================================================================

enqueue(Payload, Kind, From, #state{queue = Q} = State) ->
    next(State#state{queue = queue:in({Payload, Kind, From}, Q)}).

next(#state{current = undefined, conn = Conn, queue = Q} = State) when Conn =/= undefined ->
    case queue:out(Q) of
        {{value, {Payload, Kind, From}}, Q2} ->
            case write(State, Payload) of
                ok ->
                    Ref = erlang:start_timer(?COMMAND_TIMEOUT_MS, self(), Kind),
                    State#state{queue = Q2, current = {Kind, From, Ref}};
                {error, Reason} ->
                    reply(From, {error, Reason}),
                    next(clear_flag(Kind, State#state{queue = Q2}))
            end;
        {empty, _} ->
            State
    end;
next(State) ->
    State.

%% the current command is answered
done(Result, #state{current = {_, From, Ref}} = State) ->
    erlang:cancel_timer(Ref),
    reply(From, Result),
    next(State#state{current = undefined}).

%% a multi-frame answer continues: restart the timeout
continue(#state{current = {Kind, From, Ref}} = State) ->
    erlang:cancel_timer(Ref),
    Ref2 = erlang:start_timer(?COMMAND_TIMEOUT_MS, self(), Kind),
    State#state{current = {Kind, From, Ref2}}.

queue_sync(#state{sync_queued = true} = State) ->
    State;
queue_sync(State) ->
    enqueue(?CODEC:sync_next_message(), sync, undefined, State#state{sync_queued = true}).

queue_contacts(#state{contacts_queued = true} = State) ->
    State;
queue_contacts(#state{contacts_since = Since} = State) ->
    enqueue(?CODEC:get_contacts(Since), contacts, undefined,
            State#state{contacts_queued = true}).

clear_flag(sync, State) -> State#state{sync_queued = false};
clear_flag(contacts, State) -> State#state{contacts_queued = false};
clear_flag(_, State) -> State.

reply(undefined, _Result) -> ok;
reply(From, Result) -> gen_server:reply(From, Result).

%%====================================================================
%% Frames from the device
%%====================================================================

received(Data, #state{buffer = Buf} = State) ->
    {Frames, Rest} = ?CODEC:decode(<<Buf/binary, Data/binary>>),
    lists:foldl(fun frame/2, State#state{buffer = Rest}, Frames).

frame(Payload, #state{id = Id} = State) ->
    try ?CODEC:response(Payload) of
        Response ->
            handle_response(Response, State)
    catch
        error:Reason ->
            logger:warning("lora_mesh_meshcore ~p: bad frame ~p (~p)", [Id, Payload, Reason]),
            State
    end.

%% --- pushes: any time ---------------------------------------------------

handle_response(msg_waiting, State) ->
    queue_sync(State);
handle_response({new_advert, Contact}, State) ->
    contact(Contact),
    State;
handle_response({advert, _PubKey}, State) ->
    %% a known contact advertised again: fetch what changed
    queue_contacts(State);
handle_response({path_updated, _PubKey}, State) ->
    State;
handle_response({send_confirmed, Ack, TripMs}, #state{id = Id} = State) ->
    logger:debug("lora_mesh_meshcore ~p: message ~.16b delivered in ~p ms", [Id, Ack, TripMs]),
    State;

%% --- answers to the current command -------------------------------------

handle_response(Response, #state{current = undefined, id = Id} = State) ->
    logger:debug("lora_mesh_meshcore ~p: unexpected ~p", [Id, Response]),
    State;

handle_response({device_info, Info}, #state{current = {device_query, _, _}, id = Id} = State) ->
    logger:notice("lora_mesh_meshcore ~p: firmware ~s (protocol ~p)",
                  [Id, maps:get(version, Info, <<"?">>), maps:get(firmware_ver_code, Info)]),
    done(ok, State);

handle_response({self_info, Self}, #state{current = {app_start, _, _}, id = Id} = State) ->
    #{pub_key := PubKey, name := Name} = Self,
    Num = node_num(binary:part(PubKey, 0, 6)),
    logger:notice("lora_mesh_meshcore ~p: my node is ~s (~ts)", [Id, node_id(Num), Name]),
    contact(#{pub_key => PubKey,
              type => maps:get(adv_type, Self),
              name => Name,
              last_advert => 0,
              latitude => maps:get(latitude, Self),
              longitude => maps:get(longitude, Self)}),
    done(ok, State#state{self = Self#{num => Num}});

handle_response({contacts_start, _Count}, #state{current = {contacts, _, _}} = State) ->
    continue(State);
handle_response({contact, Contact}, #state{current = {contacts, _, _}} = State) ->
    contact(Contact),
    continue(State);
handle_response({end_of_contacts, LastMod}, #state{current = {contacts, _, _}} = State) ->
    done(ok, State#state{contacts_queued = false,
                         contacts_since = max(LastMod, State#state.contacts_since)});

handle_response({contact_msg, Msg}, #state{current = {sync, _, _}} = State) ->
    contact_message(Msg, State),
    resync(State);
handle_response({channel_msg, Msg}, #state{current = {sync, _, _}} = State) ->
    channel_message(Msg, State),
    resync(State);
handle_response(no_more_messages, #state{current = {sync, _, _}} = State) ->
    done(ok, State#state{sync_queued = false});

handle_response({sent, _Info}, #state{current = {send, _, _}} = State) ->
    done(ok, State);
handle_response(ok, #state{current = {Kind, _, _}} = State)
  when Kind =:= send;
       Kind =:= set_time ->
    done(ok, State);

handle_response({err, Reason}, #state{current = {Kind, _, _}, id = Id} = State) ->
    case Kind of
        set_time -> ok;     % the device clock was already ahead: harmless
        _ -> logger:warning("lora_mesh_meshcore ~p: ~p failed: ~p", [Id, Kind, Reason])
    end,
    done({error, Reason}, clear_flag(Kind, State));

handle_response(Response, #state{current = {Kind, _, _}, id = Id} = State) ->
    logger:debug("lora_mesh_meshcore ~p: ~p while waiting for ~p", [Id, Response, Kind]),
    State.

%% one message taken from the device's queue: ask for the next
resync(State) ->
    State2 = done(ok, State#state{sync_queued = false}),
    queue_sync(State2).

%%====================================================================
%% Into the registry and the router
%%====================================================================

contact(#{pub_key := PubKey, name := Name, type := Type} = C) ->
    Num = node_num(binary:part(PubKey, 0, 6)),
    LastAdvert = maps:get(last_advert, C, 0),
    Position = case {maps:get(latitude, C, 0.0), maps:get(longitude, C, 0.0)} of
                   {Lat, Lon} when Lat == 0, Lon == 0 -> undefined;
                   {Lat, Lon} -> #mesh_position{latitude = Lat, longitude = Lon}
               end,
    registry_update(
      Num,
      fun(Node) ->
              Node#mesh_node{
                protocol = meshcore,
                long_name = Name,
                role = Type,
                position = case Position of
                               undefined -> Node#mesh_node.position;
                               _ -> Position
                           end,
                last_heard = latest(Node#mesh_node.last_heard, LastAdvert)}
      end).

contact_message(#{from_prefix := Prefix, text := Text, sender_time := Time} = Msg,
                #state{id = Id, self = Self}) ->
    FromNum = node_num(Prefix),
    Rx = #mesh_rx{from = node_id(FromNum),
                  to = case Self of
                           #{num := SelfNum} -> node_id(SelfNum);
                           _ -> <<"?">>
                       end,
                  channel = 0,
                  id = Time,
                  rxq = rxq(Msg),
                  text = Text,
                  protocol = meshcore},
    route(Id, {meshcore, dm, FromNum, Time, erlang:phash2(Text)}, FromNum, Rx).

channel_message(#{channel := Channel, sender_name := Name, text := Text,
                  sender_time := Time} = Msg,
                #state{id = Id}) ->
    %% channel messages name the sender but carry no key: look it up
    FromNum = num_by_name(Name),
    Rx = #mesh_rx{from = case FromNum of
                             undefined -> <<"?">>;
                             _ -> node_id(FromNum)
                         end,
                  to = <<"!ffffffff">>,
                  channel = Channel,
                  id = Time,
                  rxq = rxq(Msg),
                  text = Text,
                  protocol = meshcore,
                  sender_name = Name},
    %% the slot number can differ between companions: not in the key
    route(Id, {meshcore, channel, Name, Time, erlang:phash2(Text)}, FromNum, Rx).

route(Id, Key, FromNum, Rx) ->
    case lora_mesh_router:message(Id, Key, FromNum, Rx) of
        ok -> ok;
        {error, no_router} ->
            logger:warning("lora_mesh_meshcore ~p: no router, message dropped", [Id])
    end.

%% MeshCore gives SNR and hops; no RSSI. hop_start - hop_limit = hops,
%% as for Meshtastic (0 when delivered by a direct route).
rxq(#{snr := Snr, path_len := PathLen}) ->
    Hops = case ?CODEC:hops(PathLen) of
               direct -> 0;
               N -> N
           end,
    #mesh_rxq{rx_snr = case Snr of
                           undefined -> 0.0;
                           _ -> Snr
                       end,
              rx_rssi = 0,
              hop_start = Hops,
              hop_limit = 0}.

%% The registry may live on another Erlang node (role bridge); then
%% names cannot be resolved here and updates are skipped.
num_by_name(undefined) ->
    undefined;
num_by_name(Name) ->
    try lora_mesh_registry:all() of
        Nodes ->
            case [N || #mesh_node{num = N, protocol = meshcore, long_name = L} <- Nodes,
                       L =:= Name] of
                [Num] -> Num;
                _ -> undefined          % unknown, or two nodes share the name
            end
    catch
        error:badarg -> undefined
    end.

registry_update(Num, Fun) ->
    case whereis(lora_mesh_registry) of
        undefined -> ok;
        _ -> lora_mesh_registry:update(Num, Fun)
    end.

latest(undefined, 0) -> undefined;
latest(undefined, T) -> T;
latest(Old, T) -> max(Old, T).

self_name(#state{self = #{name := Name}}) -> Name;
self_name(_) -> <<>>.
