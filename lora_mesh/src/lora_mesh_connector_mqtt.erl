%%
%% MQTT connector (emqtt).
%%
%% Plays the role of lorawan-server's lorawan_connector_mqtt:
%%   {uplink, #mesh_rx{}}            -> publish JSON to <prefix>/rx/<from>
%%   {node, #mesh_node{}}            -> publish JSON, retained, to <prefix>/node/<id>
%%   JSON published to <prefix>/tx   -> #mesh_tx{} -> lora_mesh_node:send/1,2
%%
%% A tx JSON with "bridge": "<id>" is sent through that bridge only.
%%
%% Much simpler than lorawan_connector_mqtt: one broker, fixed topics,
%% no per-node topic templates or connection hierarchy.
%%
%%   {"text": "hello"}                        broadcast, channel 0
%%   {"text": "hi", "to": "!a1b2c3d4"}        direct message
%%   {"text": "hi", "channel": 1}             other channel
%%
-module(lora_mesh_connector_mqtt).
-behaviour(gen_server).

-export([start_link/1]).
-export([parse_tx/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("lora_mesh.hrl").

-define(RETRY_MS, 5000).

-record(state, {
    opts               :: map(),
    prefix             :: binary(),
    conn = undefined   :: pid() | undefined}).

%%====================================================================
%% API
%%====================================================================

%% Opts: #{host => "localhost", port => 1883, prefix => <<"mesh">>,
%%         username => ..., password => ...}
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    self() ! connect,
    {ok, #state{
            opts = Opts,
            prefix = maps:get(prefix, Opts, <<"mesh">>)}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect, State) ->
    {noreply, do_connect(State)};

handle_info({'EXIT', Conn, Reason}, #state{conn = Conn} = State) ->
    logger:warning("lora_mesh_connector_mqtt: connection exited ~p", [Reason]),
    erlang:send_after(?RETRY_MS, self(), connect),
    {noreply, State#state{conn = undefined}};

handle_info({disconnected, _Code, _Props}, State) ->
    %% emqtt exits right after this; the 'EXIT' clause reconnects.
    {noreply, State};

% mesh -> MQTT
handle_info({uplink, #mesh_rx{}}, #state{conn = undefined} = State) ->
    logger:warning("lora_mesh_connector_mqtt: uplink dropped, broker not connected"),
    {noreply, State};
handle_info({uplink, #mesh_rx{from = From} = Rx},
            #state{conn = Conn, prefix = Prefix} = State) ->
    Topic = <<Prefix/binary, "/rx/", From/binary>>,
    ok = emqtt:publish(Conn, Topic, encode_rx(Rx), 0),
    {noreply, State};

% registry -> MQTT, retained so a new subscriber sees every node at once
handle_info({node, #mesh_node{}}, #state{conn = undefined} = State) ->
    {noreply, State};
handle_info({node, #mesh_node{id = Id} = Node},
            #state{conn = Conn, prefix = Prefix} = State) ->
    Topic = <<Prefix/binary, "/node/", Id/binary>>,
    ok = emqtt:publish(Conn, Topic, encode_node(Node), [{qos, 0}, {retain, true}]),
    {noreply, State};

% MQTT -> mesh
handle_info({publish, #{payload := Payload}}, State) ->
    case parse_tx(Payload) of
        {ok, {Bridge, Tx}} ->
            Result = case Bridge of
                         any -> lora_mesh_node:send(Tx);
                         {protocol, P} -> lora_mesh_node:send_protocol(P, Tx);
                         _ -> lora_mesh_node:send(Bridge, Tx)
                     end,
            case Result of
                ok -> ok;
                {error, Reason} ->
                    logger:warning("lora_mesh_connector_mqtt: send failed ~p", [Reason])
            end;
        {error, Reason} ->
            logger:warning("lora_mesh_connector_mqtt: bad tx ~p", [Reason])
    end,
    {noreply, State};

handle_info(Unknown, State) ->
    logger:debug("lora_mesh_connector_mqtt: unknown message ~p", [Unknown]),
    {noreply, State}.

terminate(_Reason, #state{conn = undefined}) ->
    ok;
terminate(_Reason, #state{conn = Conn}) ->
    _ = emqtt:disconnect(Conn),
    ok.

%%====================================================================
%% Internal
%%====================================================================

do_connect(#state{opts = Opts, prefix = Prefix} = State) ->
    CArgs = [{host, maps:get(host, Opts, "localhost")},
             {port, maps:get(port, Opts, 1883)},
             {clientid, maps:get(clientid, Opts, <<"lora_mesh">>)},
             {clean_start, true}
             | credentials(Opts)],
    {ok, Conn} = emqtt:start_link(CArgs),
    case emqtt:connect(Conn) of
        {ok, _Props} ->
            TxTopic = <<Prefix/binary, "/tx">>,
            {ok, _, _} = emqtt:subscribe(Conn, TxTopic, 1),
            logger:notice("lora_mesh_connector_mqtt: connected, listening on ~s", [TxTopic]),
            State#state{conn = Conn};
        {error, Reason} ->
            logger:warning("lora_mesh_connector_mqtt: connect failed ~p", [Reason]),
            %% Its 'EXIT' (if any) is ignored: conn stays undefined.
            catch emqtt:stop(Conn),
            erlang:send_after(?RETRY_MS, self(), connect),
            State
    end.

credentials(#{username := User, password := Pass}) ->
    [{username, User},
     {password, Pass}];
credentials(_) ->
    [].

%% #mesh_rx{} -> JSON, nested #mesh_rxq{} as an object
encode_rx(#mesh_rx{rxq = RxQ} = Rx) ->
    Map = ?to_map(mesh_rx, Rx),
    json(Map#{rxq := rxq_map(RxQ)}).

%% #mesh_node{} -> JSON, nested records as objects, bridges as keys
encode_node(#mesh_node{position = Pos, heard_by = HeardBy, routes = Routes} = Node) ->
    Map = ?to_map(mesh_node, Node),
    json(Map#{position := case Pos of
                              undefined -> undefined;
                              _ -> ?to_map(mesh_position, Pos)
                          end,
              heard_by := maps:map(
                            fun(_Bridge, #mesh_heard{rxq = RxQ, at = At}) ->
                                    #{rxq => rxq_map(RxQ),
                                      at => At}
                            end,
                            HeardBy),
              routes := maps:map(fun(_Bridge, Route) -> lora_mesh_path:fill(meshcore, Route) end,
                                 Routes)}).

%% path and relay with the repeater and router names known by now
rxq_map(#mesh_rxq{path = Path, relay = Relay} = RxQ) ->
    ?to_map(mesh_rxq, RxQ#mesh_rxq{path = lora_mesh_path:fill(meshcore, Path),
                                   relay = lora_mesh_path:fill(meshtastic, Relay)}).

json(Term) ->
    iolist_to_binary(json:encode(nulls(Term))).

%% 'undefined' -> null, so JSON readers see a missing value
nulls(undefined) -> null;
nulls(Map) when is_map(Map) -> maps:map(fun(_K, V) -> nulls(V) end, Map);
nulls(List) when is_list(List) -> [nulls(V) || V <- List];
nulls(Other) -> Other.

%% JSON -> {Bridge, #mesh_tx{}}; Bridge = any unless "bridge" is given
-spec parse_tx(binary()) ->
          {ok, {any | atom() | {protocol, atom()}, #mesh_tx{}}} | {error, term()}.
parse_tx(Payload) ->
    %% everything inside try: bad JSON, an unknown bridge name
    %% (binary_to_existing_atom) or a bad "to" all become {error, _}
    try
        tx(json:decode(Payload))
    catch
        error:Reason ->
            {error, Reason}
    end.

tx(#{<<"text">> := Text} = Cmd) ->
    Bridge = case Cmd of
                 #{<<"bridge">> := B} -> binary_to_existing_atom(B);
                 #{<<"protocol">> := <<"meshtastic">>} -> {protocol, meshtastic};
                 #{<<"protocol">> := <<"meshcore">>} -> {protocol, meshcore};
                 #{} -> any
             end,
    {ok, {Bridge,
          #mesh_tx{
             to = parse_to(maps:get(<<"to">>, Cmd, <<"broadcast">>)),
             channel = maps:get(<<"channel">>, Cmd, 0),
             text = Text}}};
tx(_) ->
    {error, no_text}.

%% "broadcast" | "!a1b2c3d4" (Meshtastic) | "@0a0b0c0d0e0f" (MeshCore) | 2712847316
parse_to(<<"broadcast">>) ->
    ?MESH_BROADCAST;
parse_to(<<"!", Hex:8/binary>>) ->
    binary_to_integer(Hex, 16);
parse_to(<<"@", Hex:12/binary>>) ->
    lora_mesh_meshcore:num_from_hex(Hex);
parse_to(Num) when is_integer(Num) ->
    Num.
