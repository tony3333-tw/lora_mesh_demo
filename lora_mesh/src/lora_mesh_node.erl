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
    schedule_reconnect(State);

handle_info({tcp_error, Sock, Reason}, #state{sock = Sock, id = Id} = State) ->
    logger:warning("lora_mesh_node ~p: tcp error ~p", [Id, Reason]),
    schedule_reconnect(State);

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
                        backoff = ?RECONNECT_MIN_MS},
            %% Ask the node to dump its config and node database;
            %% after that it streams packets.
            _ = send_to_radio(State2, {want_config_id, new_packet_id()}),
            erlang:send_after(?HEARTBEAT_MS, self(), heartbeat),
            {noreply, State2};
        {error, Reason} ->
            logger:warning("lora_mesh_node ~p: connect failed ~p", [Id, Reason]),
            schedule_reconnect(State)
    end.

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

handle_variant({my_info, #my_node_info{my_node_num = Num}}, #state{id = Id} = State) ->
    logger:notice("lora_mesh_node ~p: my node is ~s", [Id, node_id(Num)]),
    State#state{my_num = Num};
handle_variant({node_info, #node_info{} = Info}, #state{id = Id} = State) ->
    route(Id, lora_mesh_router:node_info(Id, Info)),
    State;
handle_variant({config_complete_id, _}, #state{id = Id} = State) ->
    logger:notice("lora_mesh_node ~p: config received, streaming packets", [Id]),
    State;
handle_variant({packet, #mesh_packet{} = Packet}, #state{id = Id} = State) ->
    route(Id, lora_mesh_router:uplink(Id, Packet)),
    State;
handle_variant(_Other, State) ->
    %% config, channel, log_record, undefined, ... ignored here
    State.

route(_Id, ok) ->
    ok;
route(Id, {error, no_router}) ->
    logger:warning("lora_mesh_node ~p: no router, packet dropped", [Id]).
