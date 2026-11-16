%%
%% One bridge: the client API connection (TCP port 4403) to one
%% Meshtastic node. There can be several, each with its own id, on this
%% Erlang node or others in the cluster.
%%
%% Plays the role of lorawan-server's lorawan_gw_forwarder: it owns the
%% socket to the radio side, turns wire bytes into records, and hands
%% every received packet to the router:
%%
%%   #mesh_packet{}   -> lora_mesh_router:uplink(BridgeId, Packet)
%%   #node_info{}     -> lora_mesh_router:node_info(BridgeId, Info)
%%                       (the node's own database, sent on connect)
%%
%% and tells the router about itself (0.4), for mesh/bridge/<id>/...:
%%
%%   {status, #{connected => true}}    once the radio's config is read
%%   {status, #{connected => false}}   when the connection is lost
%%   {info, Map}                       what the radio sent on connect:
%%                                     my_info, metadata, channels, config,
%%                                     module_config (lora_mesh_json maps)
%%
%% Differences from lorawan_gw_forwarder:
%%   - TCP to one node, not UDP from many gateways;
%%   - protobuf frames (0x94 0xC3 len16), not Semtech JSON datagrams;
%%   - the node decrypts and routes; there is no MAC layer here.
%%
%% Each bridge joins two pg groups in scope ?PG_SCOPE:
%%   ?PG_BRIDGES        all bridges, used by send/1
%%   ?PG_BRIDGE(Id)     this bridge, used by send/2
%%
-module(lora_mesh_node).
-behaviour(gen_server).

-export([start_link/1]).
-export([send/1]).
-export([send/2]).
-export([send_protocol/2]).
-export([protocol_of/1]).
-export([bridges/0]).
-export([node_id/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([hide_secrets/1]).
-endif.

-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

-define(HEARTBEAT_MS, 60000).
-define(RECONNECT_MIN_MS, 1000).
-define(RECONNECT_MAX_MS, 30000).

-record(state, {
    id                            :: atom(),
    host                          :: inet:hostname() | inet:ip_address(),
    port                          :: inet:port_number(),
    sock = undefined              :: gen_tcp:socket() | undefined,
    buffer = <<>>                 :: binary(),
    my_num = undefined            :: non_neg_integer() | undefined,
    %% what the radio sends before config_complete_id, for the info topic
    info = #{}                    :: map(),
    %% undefined until the first connect works or fails
    ready = undefined             :: boolean() | undefined,
    backoff = ?RECONNECT_MIN_MS   :: pos_integer()}).

%%====================================================================
%% API
%%====================================================================

%% Opts: #{id => home, host => ..., port => 4403}
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% Send through any bridge that speaks the destination's protocol,
%% preferring one on this Erlang node. A broadcast goes through any
%% bridge; use send_protocol/2 or send/2 to choose the mesh.
-spec send(#mesh_tx{}) -> ok | {error, no_bridge | not_connected | too_long | term()}.
send(#mesh_tx{to = ?MESH_BROADCAST} = Tx) ->
    call_first(?PG_BRIDGES, Tx);
send(#mesh_tx{to = To} = Tx) ->
    send_protocol(protocol_of(To), Tx).

%% Send through any bridge of one protocol: meshtastic | meshcore.
-spec send_protocol(meshtastic | meshcore, #mesh_tx{}) ->
          ok | {error, no_bridge | not_connected | too_long | term()}.
send_protocol(Protocol, #mesh_tx{} = Tx) ->
    call_first(?PG_PROTOCOL(Protocol), Tx).

%% Which mesh a node number belongs to.
protocol_of(Num) ->
    case lora_mesh_meshcore:is_node_num(Num) of
        true -> meshcore;
        false -> meshtastic
    end.

%% A MeshCore bridge answers after the radio does (up to 5 s per
%% command, queued behind others): allow for it.
call(Pid, Tx) ->
    try
        gen_server:call(Pid, {send, Tx}, 15000)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, no_bridge}
    end.

call_first(Group, Tx) ->
    case pg:get_local_members(?PG_SCOPE, Group)
         ++ pg:get_members(?PG_SCOPE, Group) of
        [Pid | _] -> call(Pid, Tx);
        [] -> {error, no_bridge}
    end.

%% Send through one named bridge.
-spec send(atom(), #mesh_tx{}) -> ok | {error, no_bridge | not_connected | too_long | term()}.
send(Bridge, #mesh_tx{} = Tx) ->
    case pg:get_members(?PG_SCOPE, ?PG_BRIDGE(Bridge)) of
        [Pid | _] -> call(Pid, Tx);
        [] -> {error, no_bridge}
    end.

%% Ids of all bridges in the cluster.
-spec bridges() -> [atom()].
bridges() ->
    lists:usort([Id || {bridge, Id} <- pg:which_groups(?PG_SCOPE)]).

%% Node number -> the "!a1b2c3d4" form the apps show.
node_id(Num) ->
    iolist_to_binary(io_lib:format("!~8.16.0b", [Num])).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    Id = maps:get(id, Opts),
    ok = pg:join(?PG_SCOPE, ?PG_BRIDGES, self()),
    ok = pg:join(?PG_SCOPE, ?PG_BRIDGE(Id), self()),
    ok = pg:join(?PG_SCOPE, ?PG_PROTOCOL(meshtastic), self()),
    self() ! connect,
    {ok, #state{
            id = Id,
            host = maps:get(host, Opts),
            port = maps:get(port, Opts, ?MESH_TCP_PORT)}}.

handle_call({send, _Tx}, _From, #state{sock = undefined} = State) ->
    {reply, {error, not_connected}, State};
handle_call({send, #mesh_tx{to = To}}, _From, State) when To > 16#FFFFFFFF ->
    %% a MeshCore node: this bridge cannot reach it
    {reply, {error, wrong_protocol}, State};
handle_call({send, #mesh_tx{to = To, channel = Channel, text = Text}}, _From, State) ->
    Payload = unicode:characters_to_binary(Text),
    case byte_size(Payload) of
        Size when Size > ?MESH_DATA_PAYLOAD_LEN ->
            %% The node (nanopb, Data.payload max_size:233) cannot hold it.
            {reply, {error, too_long}, State};
        _ ->
            Packet =
                #mesh_packet{
                    to = To,
                    channel = Channel,
                    id = new_packet_id(),
                    hop_limit = ?MESH_HOP_LIMIT,
                    want_ack = To =/= ?MESH_BROADCAST,
                    payload_variant =
                        {decoded,
                         #data{portnum = 'TEXT_MESSAGE_APP',
                               payload = Payload}}},
            {reply, send_to_radio(State, {packet, Packet}), State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect, State) ->
    do_connect(State);

% bytes from the node
handle_info({tcp, Sock, Data}, #state{sock = Sock, buffer = Buf} = State) ->
    {Frames, Rest} = lora_mesh_frame:decode(<<Buf/binary, Data/binary>>),
    State2 = lists:foldl(
                fun from_radio/2,
                State#state{buffer = Rest},
                Frames),
    {noreply, State2};

handle_info({tcp_closed, Sock}, #state{sock = Sock, id = Id} = State) ->
    logger:warning("lora_mesh_node ~p: connection closed", [Id]),
    schedule_reconnect(lost(closed, State));

handle_info({tcp_error, Sock, Reason}, #state{sock = Sock, id = Id} = State) ->
    logger:warning("lora_mesh_node ~p: tcp error ~p", [Id, Reason]),
    schedule_reconnect(lost(Reason, State));

handle_info(heartbeat, #state{sock = undefined} = State) ->
    {noreply, State};
handle_info(heartbeat, State) ->
    _ = send_to_radio(State, {heartbeat, #heartbeat{}}),
    erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
    {noreply, State};

% something strange
handle_info(Unknown, #state{id = Id} = State) ->
    logger:warning("lora_mesh_node ~p: unknown message ~p", [Id, Unknown]),
    {noreply, State}.

terminate(_Reason, #state{sock = undefined}) ->
    ok;
terminate(_Reason, #state{sock = Sock} = State) ->
    _ = send_to_radio(State, {disconnect, true}),
    gen_tcp:close(Sock).

%%====================================================================
%% Connection
%%====================================================================

do_connect(#state{id = Id, host = Host, port = Port} = State) ->
    TcpOpts = [binary,
               {active, true},
               {packet, raw},
               {keepalive, true}],
    case gen_tcp:connect(Host, Port, TcpOpts, 5000) of
        {ok, Sock} ->
            logger:notice("lora_mesh_node ~p: connected to ~p:~p", [Id, Host, Port]),
            State2 = State#state{
                        sock = Sock,
                        buffer = <<>>,
                        info = #{},
                        backoff = ?RECONNECT_MIN_MS},
            %% Ask the node to dump its config and node database;
            %% after that it streams packets.
            _ = send_to_radio(State2, {want_config_id, new_packet_id()}),
            erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
            {noreply, State2};
        {error, Reason} ->
            logger:warning("lora_mesh_node ~p: connect failed ~p", [Id, Reason]),
            schedule_reconnect(lost(Reason, State))
    end.

%% Say "disconnected" once: when a ready connection goes, or when the
%% very first connect fails
lost(Reason, #state{ready = Ready, id = Id} = State) when Ready =/= false ->
    Status = status(false, State),
    Why = iolist_to_binary(io_lib:format("~p", [Reason])),
    _ = lora_mesh_router:bridge(Id, {status, Status#{reason => Why}}),
    State#state{ready = false};
lost(_Reason, State) ->
    State.

schedule_reconnect(#state{sock = Sock, backoff = Backoff} = State) ->
    _ = case Sock of
            undefined -> ok;
            _ -> gen_tcp:close(Sock)
        end,
    erlang:send_after(Backoff, self(), connect),
    {noreply, State#state{
                sock = undefined,
                buffer = <<>>,
                backoff = min(Backoff * 2, ?RECONNECT_MAX_MS)}}.

send_to_radio(#state{sock = Sock}, Variant) ->
    Bin = meshtastic_pb:encode_msg(#to_radio{payload_variant = Variant}),
    gen_tcp:send(Sock, lora_mesh_frame:encode(Bin)).

new_packet_id() ->
    rand:uniform(16#FFFFFFFE).

%%====================================================================
%% FromRadio
%%====================================================================

from_radio(Bin, State) ->
    try meshtastic_pb:decode_msg(Bin, from_radio) of
        #from_radio{payload_variant = Variant} ->
            handle_variant(Variant, State)
    catch
        error:Reason ->
            logger:warning("lora_mesh_node ~p: bad frame ~p", [State#state.id, Reason]),
            State
    end.

handle_variant({my_info, #my_node_info{my_node_num = Num} = MyInfo},
               #state{id = Id, info = Info} = State) ->
    logger:notice("lora_mesh_node ~p: my node is ~s", [Id, node_id(Num)]),
    State#state{my_num = Num,
                info = Info#{my_info => lora_mesh_json:record(MyInfo)}};
handle_variant({metadata, #device_metadata{} = Metadata}, #state{info = Info} = State) ->
    State#state{info = Info#{metadata => lora_mesh_json:record(Metadata)}};
handle_variant({channel, #channel{} = Channel}, #state{info = Info} = State) ->
    Channels = maps:get(channels, Info, []),
    State#state{info = Info#{channels => Channels ++ [channel(Channel)]}};
handle_variant({config, #config{} = Config}, #state{info = Info} = State) ->
    %% one section per message: #{lora => ..., device => ..., ...}
    State#state{info = Info#{config => maps:merge(maps:get(config, Info, #{}),
                                                  lora_mesh_json:record(Config))}};
handle_variant({moduleConfig, #module_config{} = Config}, #state{info = Info} = State) ->
    State#state{info = Info#{module_config => maps:merge(maps:get(module_config, Info, #{}),
                                                         lora_mesh_json:record(Config))}};
handle_variant({node_info, #node_info{} = Info}, #state{id = Id} = State) ->
    route(Id, lora_mesh_router:node_info(Id, Info)),
    State;
handle_variant({config_complete_id, _}, #state{id = Id, info = Info} = State) ->
    logger:notice("lora_mesh_node ~p: config received, streaming packets", [Id]),
    _ = lora_mesh_router:bridge(Id, {info, info_map(Info, State)}),
    _ = lora_mesh_router:bridge(Id, {status, status(true, State)}),
    State#state{ready = true};
handle_variant({packet, #mesh_packet{} = Packet}, #state{id = Id} = State) ->
    route(Id, lora_mesh_router:uplink(Id, Packet)),
    State;
handle_variant(_Other, State) ->
    %% config, channel, log_record, undefined, ... ignored here
    State.

%% a channel's index is shown even when it is 0 (MessageToDict leaves it out)
channel(#channel{index = Index} = Channel) ->
    (lora_mesh_json:record(Channel))#{index => Index}.

info_map(Info0, #state{my_num = Num}) ->
    Info = case application:get_env(lora_mesh, show_secrets, false) of
               true -> Info0;
               false -> hide_secrets(Info0)
           end,
    Info#{protocol => meshtastic,
          my_num => Num,
          my_id => case Num of
                       undefined -> null;
                       _ -> node_id(Num)
                   end,
          at => erlang:system_time(second)}.

%% Anyone who can read the broker reads the info topic, so by default it
%% leaves out what would let them into the radio, its Wi-Fi or a private
%% channel: channel keys (except the well-known one-byte ones such as
%% "AQ==", the default key), the Wi-Fi password, the radio's private key,
%% the MQTT password. {show_secrets, true} in lora_mesh's config keeps them.
hide_secrets(Info) ->
    Channels = [hide_in(C, [settings, psk], fun hide_psk/1) || C <- maps:get(channels, Info, [])],
    Config = hide_in(hide_in(maps:get(config, Info, #{}),
                             [network, wifi_psk], fun hidden/1),
                     [security, private_key], fun hidden/1),
    Module = hide_in(maps:get(module_config, Info, #{}), [mqtt, password], fun hidden/1),
    Info#{channels => Channels,
          config => Config,
          module_config => Module}.

%% apply Fun to the value at Path, if it is there
hide_in(Map, [Key], Fun) ->
    case Map of
        #{Key := V} -> Map#{Key := Fun(V)};
        _ -> Map
    end;
hide_in(Map, [Key | Rest], Fun) ->
    case Map of
        #{Key := Sub} when is_map(Sub) -> Map#{Key := hide_in(Sub, Rest, Fun)};
        _ -> Map
    end.

%% one byte (0 = none, 1 = default, 2..10 = default + N) is not secret
hide_psk(<<"base64:", B64/binary>> = Psk) ->
    case base64:decode(B64) of
        <<_>> -> Psk;
        _ -> hidden(Psk)
    end;
hide_psk(Psk) ->
    hidden(Psk).

hidden(_Secret) ->
    <<"(hidden)">>.

status(Connected, #state{host = Host, port = Port, my_num = Num}) ->
    #{connected => Connected,
      protocol => meshtastic,
      address => iolist_to_binary(io_lib:format("~s:~p", [host(Host), Port])),
      my_id => case Num of
                   undefined -> null;
                   _ -> node_id(Num)
               end,
      at => erlang:system_time(second)}.

host(Host) when is_tuple(Host) -> inet:ntoa(Host);
host(Host) -> Host.

route(_Id, ok) ->
    ok;
route(Id, {error, no_router}) ->
    logger:warning("lora_mesh_node ~p: no router, packet dropped", [Id]).
