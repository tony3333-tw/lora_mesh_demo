%%
%% MQTT connector (emqtt).
%%
%% Plays the role of lorawan-server's lorawan_connector_mqtt:
%%   {uplink, #mesh_rx{}}            -> publish JSON to <prefix>/rx/<from>
%%   {node, #mesh_node{}}            -> publish JSON, retained, to <prefix>/node/<id>
%%   {packet, #mesh_packet{}, Bs}    -> publish JSON to <prefix>/packet/<from>     (0.4)
%%   {bridge, Id, {info, Map}}       -> retained, to <prefix>/bridge/<id>/info     (0.4)
%%   {bridge, Id, {status, Map}}     -> retained, to <prefix>/bridge/<id>/status   (0.4)
%%   JSON published to <prefix>/tx   -> #mesh_tx{} -> lora_mesh_node:send/1,2
%%
%% A tx JSON with "bridge": "<id>" is sent through that bridge only.
%%
%% <prefix>/status (retained) says whether lora_mesh itself is up:
%% {"online": true}, or {"online": false} from the broker (MQTT last will)
%% when lora_mesh goes away without saying goodbye.
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
    conn = undefined   :: pid() | undefined,
    %% each bridge's last info and status, published again after a
    %% reconnect to the broker
    bridges = #{}      :: #{atom() => #{info | status => map()}}}).

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

% every packet (best copy), whatever its port: mesh/packet/<from>
handle_info({packet, _Packet, _Bridges}, #state{conn = undefined} = State) ->
    {noreply, State};
handle_info({packet, Packet, Bridges}, #state{conn = Conn, prefix = Prefix} = State) ->
    case encode_packet(Packet, Bridges) of
        {ok, From, Json} ->
            ok = emqtt:publish(Conn, <<Prefix/binary, "/packet/", From/binary>>, Json, 0);
        {error, Reason} ->
            logger:warning("lora_mesh_connector_mqtt: packet not published ~p", [Reason])
    end,
    {noreply, State};

% a bridge's info or status, retained: mesh/bridge/<id>/info, .../status
handle_info({bridge, Bridge, {Kind, Map}}, #state{bridges = Bridges} = State) ->
    Known = maps:get(Bridge, Bridges, #{}),
    State2 = State#state{bridges = Bridges#{Bridge => Known#{Kind => Map}}},
    publish_bridge(Bridge, Kind, Map, State2),
    {noreply, State2};

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
terminate(_Reason, #state{conn = Conn, prefix = Prefix}) ->
    %% a clean goodbye: the broker does not send the last will
    _ = emqtt:publish(Conn, <<Prefix/binary, "/status">>, json(#{online => false}),
                      [{qos, 1}, {retain, true}]),
    _ = emqtt:disconnect(Conn),
    ok.

%%====================================================================
%% Internal
%%====================================================================

do_connect(#state{opts = Opts, prefix = Prefix} = State) ->
    CArgs = [{host, maps:get(host, Opts, "localhost")},
             {port, maps:get(port, Opts, 1883)},
             {clientid, maps:get(clientid, Opts, <<"lora_mesh">>)},
             {clean_start, true},
             {will_topic, <<Prefix/binary, "/status">>},
             {will_payload, json(#{online => false})},
             {will_retain, true},
             {will_qos, 1}
             | credentials(Opts)],
    {ok, Conn} = emqtt:start_link(CArgs),
    case emqtt:connect(Conn) of
        {ok, _Props} ->
            TxTopic = <<Prefix/binary, "/tx">>,
            {ok, _, _} = emqtt:subscribe(Conn, TxTopic, 1),
            logger:notice("lora_mesh_connector_mqtt: connected, listening on ~s", [TxTopic]),
            State2 = State#state{conn = Conn},
            {ok, _} = emqtt:publish(Conn, <<Prefix/binary, "/status">>, json(#{online => true}),
                                    [{qos, 1}, {retain, true}]),
            maps:foreach(fun(Bridge, Known) ->
                                 maps:foreach(fun(Kind, Map) ->
                                                      publish_bridge(Bridge, Kind, Map, State2)
                                              end,
                                              Known)
                         end,
                         State#state.bridges),
            State2;
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

publish_bridge(_Bridge, _Kind, _Map, #state{conn = undefined}) ->
    ok;
publish_bridge(Bridge, Kind, Map, #state{conn = Conn, prefix = Prefix}) ->
    Topic = iolist_to_binary([Prefix, "/bridge/", atom_to_binary(Bridge), "/", atom_to_binary(Kind)]),
    %% QoS 1 like <prefix>/status, so the broker keeps them in order:
    %% "online" first, then each bridge
    {ok, _} = emqtt:publish(Conn, Topic, json(Map#{bridge => Bridge}), [{qos, 1}, {retain, true}]),
    ok.

%% #mesh_packet{} -> {ok, FromId, JSON}: every field that is set, the
%% payload decoded by port (lora_mesh_json), and the bridges that heard it
encode_packet(Packet, Bridges) ->
    try lora_mesh_json:packet(Packet) of
        #{from_id := From} = Map -> {ok, From, json(Map#{bridges => Bridges})}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

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
