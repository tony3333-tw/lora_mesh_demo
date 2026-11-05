%%
%% mtc: a small Erlang client for lora_mesh, over MQTT.
%%
%% The Python examples talk to one radio through the meshtastic library.
%% These examples talk to lora_mesh instead, which holds the radios'
%% connections, through the MQTT broker lora_mesh uses:
%%
%%   mesh/rx/<id>     a text message from the mesh       (JSON)
%%   mesh/node/<id>   what lora_mesh knows about a node  (JSON, retained)
%%   mesh/tx          a text to send into the mesh       (JSON)
%%
%% Messages arrive in the process that called connect/1, as emqtt sends
%% them: {publish, #{topic := T, payload := P}}. next/2 waits for one and
%% decodes it to {rx, Rx} or {node, Node}. JSON keys stay binaries:
%%
%%   C = mtc:connect(#{host => "localhost"}),
%%   Nodes = mtc:nodes(C, #{}),                   % iface.nodes
%%   {ok, Hill} = mtc:find(Nodes, "hill top"),
%%   mtc:send_text(C, "hi", #{to => maps:get(<<"id">>, Hill)}),
%%   ok = mtc:subscribe(C, rx),
%%   {rx, Rx} = mtc:next(C, infinity),            % pub.subscribe(onReceive)
%%   maps:get(<<"text">>, Rx),
%%   mtc:disconnect(C).
%%
%% Only text messages and node records travel through lora_mesh 0.3;
%% see README.md for what waits for lora_mesh 0.4.
%%
-module(mtc).

%% our nodes/2 is lora_mesh's node list, not erlang:nodes/2
-compile({no_auto_import, [nodes/2]}).

-export([connect/1]).
-export([disconnect/1]).
-export([subscribe/2]).
-export([decode/2]).
-export([next/2]).
-export([nodes/2]).
-export([find/2]).
-export([dest/2]).
-export([names/1]).
-export([name/2]).
-export([sender/2]).
-export([send_text/3]).
-export([is_channel/1]).
-export([hops/1]).
-export([deadline/1]).
-export([left/1]).

-define(BROADCAST, <<"!ffffffff">>).

%% how long nodes/2 waits for more retained node records
-define(QUIET_MS, 1000).

%%====================================================================
%% Connection
%%====================================================================

%% Opts: host ("localhost"), port (1883), prefix ("mesh"), username,
%% password: the broker lora_mesh is connected to. Returns a client map.
%% Raises error({mqtt_connect, Reason}).
connect(Opts) ->
    {ok, _} = application:ensure_all_started(emqtt),
    Args = [{host, maps:get(host, Opts, "localhost")},
            {port, maps:get(port, Opts, 1883)},
            {clientid, client_id()},
            {clean_start, true}
            | credentials(Opts)],
    {ok, Conn} = emqtt:start_link(Args),
    %% emqtt exits when the broker cannot be reached: unlinked while
    %% connecting, so that becomes an error here instead of killing us
    unlink(Conn),
    case emqtt:connect(Conn) of
        {ok, _Props} ->
            link(Conn),
            #{conn => Conn,
              prefix => unicode:characters_to_binary(maps:get(prefix, Opts, "mesh"))};
        {error, Reason} ->
            catch emqtt:stop(Conn),
            error({mqtt_connect, Reason})
    end.

disconnect(#{conn := Conn}) ->
    _ = emqtt:disconnect(Conn),
    ok.

%% What = rx | nodes
subscribe(#{conn := Conn, prefix := Prefix}, What) ->
    Topic = case What of
                rx -> <<Prefix/binary, "/rx/#">>;
                nodes -> <<Prefix/binary, "/node/#">>
            end,
    {ok, _, _} = emqtt:subscribe(Conn, Topic, 0),
    ok.

%% One emqtt publish map -> {rx, Rx} | {node, Node} | ignore
decode(#{prefix := Prefix}, #{topic := Topic, payload := Payload}) ->
    Size = byte_size(Prefix),
    case Topic of
        <<Prefix:Size/binary, "/rx/", _/binary>> ->
            {rx, json:decode(Payload)};
        <<Prefix:Size/binary, "/node/", _/binary>> when Payload =/= <<>> ->
            {node, json:decode(Payload)};
        _ ->
            ignore
    end.

%% Wait up to Timeout ms for the next text message or node record:
%% {rx, Rx} | {node, Node} | timeout
next(Client, Timeout) ->
    receive
        {publish, Msg} ->
            case decode(Client, Msg) of
                ignore -> next(Client, Timeout);
                Decoded -> Decoded
            end
    after Timeout ->
        timeout
    end.

%%====================================================================
%% Nodes
%%====================================================================

%% The Meshtastic nodes lora_mesh knows, sorted by name (all nodes,
%% MeshCore too, with Opts all => true). lora_mesh keeps them retained
%% on the broker: this collects until nothing new arrives for a second.
nodes(Client, Opts) ->
    ok = subscribe(Client, nodes),
    All = collect(Client, #{}),
    Wanted = case maps:get(all, Opts, false) of
                 true -> All;
                 false -> [N || N <- All, maps:get(<<"protocol">>, N, null) =/= <<"meshcore">>]
             end,
    lists:sort(fun(A, B) -> sort_name(A) =< sort_name(B) end, Wanted).

collect(Client, Acc) ->
    case next(Client, ?QUIET_MS) of
        {node, #{<<"id">> := Id} = Node} -> collect(Client, Acc#{Id => Node});
        {rx, _} -> collect(Client, Acc);
        timeout -> maps:values(Acc)
    end.

sort_name(Node) ->
    string:casefold(display_name(Node)).

%% A node by long name, short name (either case), id ("!0a0b0c0d") or
%% node number (168496141): {ok, Node} | error
find(Nodes, Name) ->
    Want = string:casefold(unicode:characters_to_binary(Name)),
    Match = fun(Node) ->
                    Keys = [fold(maps:get(K, Node, null))
                            || K <- [<<"long_name">>, <<"short_name">>, <<"id">>]],
                    lists:member(Want, Keys)
                        orelse Want =:= integer_to_binary(maps:get(<<"num">>, Node, -1))
            end,
    case lists:filter(Match, Nodes) of
        [Node | _] -> {ok, Node};
        [] -> error
    end.

fold(null) -> null;
fold(Bin) -> string:casefold(Bin).

%% The -d NODE option -> that node's id (<<"!0a0b0c0d">>). An id is
%% taken as it is, so a node lora_mesh has not heard yet can be reached.
%% Raises error({missing_option, "-d NODE"}) or error({unknown_node, Dest}).
dest(Client, Opts) ->
    case maps:find(dest, Opts) of
        error ->
            error({missing_option, "-d NODE"});
        {ok, [$! | _] = Id} when length(Id) =:= 9 ->
            list_to_binary(string:lowercase(Id));
        {ok, Dest} ->
            case find(nodes(Client, Opts), Dest) of
                {ok, Node} -> maps:get(<<"id">>, Node);
                error -> error({unknown_node, Dest})
            end
    end.

%% Nodes -> #{Id => Name}, for printing senders
names(Nodes) ->
    maps:from_list([{maps:get(<<"id">>, N), display_name(N)} || N <- Nodes]).

%% An id as a name if known
name(Names, Id) ->
    maps:get(Id, Names, Id).

%% A message's sender, as a name if known (MeshCore channel messages
%% carry the sender's name themselves)
sender(Rx, Names) ->
    case maps:get(<<"sender_name">>, Rx, null) of
        null -> name(Names, maps:get(<<"from">>, Rx));
        Name -> Name
    end.

display_name(Node) ->
    case maps:get(<<"long_name">>, Node, null) of
        null -> maps:get(<<"id">>, Node);
        Name -> Name
    end.

%%====================================================================
%% Sending
%%====================================================================

%% Send a text through lora_mesh (mesh/tx), like iface.sendText(). Opts:
%%   to => Id        a direct message ("!0a0b0c0d"); without it, to
%%                   everyone on the channel
%%   channel => N    the channel index (0)
%%   bridge => Name  through that bridge (lora_mesh picks one otherwise)
%% A broadcast goes to the Meshtastic mesh, not MeshCore.
send_text(#{conn := Conn, prefix := Prefix}, Text, Opts) ->
    Base = #{<<"text">> => unicode:characters_to_binary(Text),
             <<"channel">> => maps:get(channel, Opts, 0)},
    Tx0 = case maps:find(to, Opts) of
              {ok, To} -> Base#{<<"to">> => unicode:characters_to_binary(To)};
              error -> Base#{<<"protocol">> => <<"meshtastic">>}
          end,
    Tx = case maps:find(bridge, Opts) of
             {ok, Bridge} -> Tx0#{<<"bridge">> => unicode:characters_to_binary(Bridge)};
             error -> Tx0
         end,
    {ok, _} = emqtt:publish(Conn, <<Prefix/binary, "/tx">>, iolist_to_binary(json:encode(Tx)), 1),
    ok.

%%====================================================================
%% Messages
%%====================================================================

is_channel(Rx) ->
    maps:get(<<"to">>, Rx) =:= ?BROADCAST.

%% hops the message took on its way
hops(Rx) ->
    #{<<"hop_start">> := Start, <<"hop_limit">> := Limit} = maps:get(<<"rxq">>, Rx),
    Start - Limit.

%%====================================================================
%% Time
%%====================================================================

%% deadline(Ms) and left(Deadline): wait "until then" across several
%% next/2 calls. infinity stays infinity.
deadline(infinity) -> infinity;
deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.

left(infinity) -> infinity;
left(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%%====================================================================
%% Internal
%%====================================================================

client_id() ->
    iolist_to_binary(["mte-", integer_to_list(erlang:unique_integer([positive])),
                      "-", integer_to_list(rand:uniform(1000000))]).

credentials(#{username := User, password := Pass}) ->
    [{username, unicode:characters_to_binary(User)},
     {password, unicode:characters_to_binary(Pass)}];
credentials(_) ->
    [].
