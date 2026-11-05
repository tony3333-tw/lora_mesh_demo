%%
%% lmc: a small Erlang client for lora_mesh, over MQTT.
%%
%% What lora_mesh_client (Python) does, for the Erlang and LFE examples:
%% the examples never talk to a radio; they talk to lora_mesh through the
%% broker, like every other client.
%%
%%   mesh/rx/<id>     a text message from the mesh       (JSON)
%%   mesh/node/<id>   what is known about a node         (JSON, retained)
%%   mesh/tx          a text to send into the mesh       (JSON)
%%
%% Messages arrive in the process that called connect/1, as emqtt sends
%% them: {publish, #{topic := T, payload := P, retain := R}}. decode/2
%% turns one into {rx, Map} or {node, Map}. JSON keys stay binaries:
%% maps:get(<<"text">>, Rx).
%%
%%   C = lmc:connect(#{host => "localhost"}),
%%   Nodes = lmc:nodes(C, 1000),
%%   {ok, Alice} = lmc:find(Nodes, "alice"),
%%   lmc:send(C, #{to => maps:get(<<"id">>, Alice), text => "hi"}),
%%   lmc:disconnect(C).
%%
-module(lmc).

-export([connect/1]).
-export([disconnect/1]).
-export([subscribe/2]).
-export([decode/2]).
-export([next/2]).
-export([nodes/2]).
-export([find/2]).
-export([names/1]).
-export([add_name/2]).
-export([sender/2]).
-export([send/2]).
-export([is_channel/1]).
-export([hops/1]).
-export([path_info/1]).
-export([path_text/1]).
-export([hop_name/1]).
-export([route_text/1]).
-export([route/1]).
-export([describe/2]).
-export([kind/1]).

-define(BROADCAST, <<"!ffffffff">>).

%%====================================================================
%% Connection
%%====================================================================

%% Opts: host ("localhost"), port (1883), prefix (<<"mesh">>),
%%       username, password. Returns a client map.
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
              prefix => iolist_to_binary(maps:get(prefix, Opts, <<"mesh">>))};
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

%% Wait up to Timeout ms for the next rx or node: {rx, Rx} | {node, Node} | timeout
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

%% Every node lora_mesh knows (retained), sorted by name. Collects until
%% nothing new arrives for QuietMs.
nodes(Client, QuietMs) ->
    ok = subscribe(Client, nodes),
    collect(Client, QuietMs, #{}).

collect(Client, QuietMs, Acc) ->
    case next(Client, QuietMs) of
        {node, #{<<"id">> := Id} = Node} ->
            collect(Client, QuietMs, Acc#{Id => Node});
        {rx, _} ->
            collect(Client, QuietMs, Acc);
        timeout ->
            lists:sort(fun(A, B) -> sort_name(A) =< sort_name(B) end,
                       maps:values(Acc))
    end.

sort_name(Node) ->
    string:casefold(display_name(Node)).

%% By name (either case), short name or id.
find(Nodes, Name) ->
    Want = string:casefold(unicode:characters_to_binary(Name)),
    Match = fun(Node) ->
                    lists:member(Want, [fold(maps:get(K, Node, null))
                                        || K <- [<<"long_name">>, <<"short_name">>, <<"id">>]])
            end,
    case lists:filter(Match, Nodes) of
        [Node | _] -> {ok, Node};
        [] -> error
    end.

fold(null) -> null;
fold(Bin) -> string:casefold(Bin).

%% Nodes -> #{Id => Name}, for printing senders
names(Nodes) ->
    lists:foldl(fun(N, Acc) -> add_name(Acc, N) end, #{}, Nodes).

%% One more node (a new one, or a new name) in #{Id => Name}
add_name(Names, Node) ->
    Names#{maps:get(<<"id">>, Node) => display_name(Node)}.

display_name(Node) ->
    case maps:get(<<"long_name">>, Node, null) of
        null -> maps:get(<<"id">>, Node);
        Name -> Name
    end.

%% A message's sender, as a name if known
sender(Rx, Names) ->
    case maps:get(<<"sender_name">>, Rx, null) of
        null ->
            From = maps:get(<<"from">>, Rx),
            maps:get(From, Names, From);
        Name ->
            Name
    end.

%% MeshCore contact types; Meshtastic roles come as names
kind(Node) ->
    case maps:get(<<"role">>, Node, null) of
        1 -> <<"chat">>;
        2 -> <<"repeater">>;
        3 -> <<"room">>;
        4 -> <<"sensor">>;
        null -> <<"-">>;
        Role when is_binary(Role) -> string:lowercase(Role);
        Role -> iolist_to_binary(io_lib:format("~p", [Role]))
    end.

%%====================================================================
%% Sending
%%====================================================================

%% Tx: #{text := Text, to => Id, channel => N, protocol => meshcore, bridge => Id}
%% Without `to' the text goes to everyone on the channel.
send(#{conn := Conn, prefix := Prefix}, #{text := _} = Tx) ->
    Json = json:encode(maps:map(fun value/2, Tx)),
    {ok, _} = emqtt:publish(Conn, <<Prefix/binary, "/tx">>, iolist_to_binary(Json), 1),
    ok.

value(channel, N) -> N;
value(_Key, V) when is_atom(V) -> V;
value(_Key, V) -> unicode:characters_to_binary(V).

%%====================================================================
%% Messages
%%====================================================================

is_channel(Rx) ->
    maps:get(<<"to">>, Rx) =:= ?BROADCAST.

hops(Rx) ->
    #{<<"hop_start">> := Start, <<"hop_limit">> := Limit} = maps:get(<<"rxq">>, Rx),
    Start - Limit.

%% "(Ridge > 77?, heard by barn)": like serial_pingbot.py's path info,
%% from lora_mesh 0.3.2's rxq path (MeshCore) or relay (Meshtastic)
path_info(Rx) ->
    Bridges = lists:join(",", maps:get(<<"bridges">>, Rx, [])),
    unicode:characters_to_list(["(", path_text(Rx), ", heard by ", Bridges, ")"]).

%% "Ridge > 77?"       MeshCore: every repeater, first one first
%% "direct"            heard straight from the sender
%% "last relay Tower"  Meshtastic: only the last rebroadcaster is known
%% "2 hops"            no path known (lora_mesh 0.3.0, or a direct route)
path_text(Rx) ->
    RxQ = maps:get(<<"rxq">>, Rx),
    case {maps:get(<<"path">>, RxQ, null), maps:get(<<"relay">>, RxQ, null)} of
        {[], _} ->
            "direct";
        {Path, _} when is_list(Path) ->
            lists:join(" > ", [hop_name(H) || H <- Path]);
        {null, null} ->
            case hops(Rx) of
                0 -> "direct";
                N -> integer_to_list(N) ++ " hops"
            end;
        {null, Relay} ->
            ["last relay ", hop_name(Relay)]
    end.

%% a repeater or router by name, or its hash with "?" if not known
hop_name(#{<<"name">> := null, <<"hash">> := Hash}) -> [Hash, "?"];
hop_name(#{<<"name">> := Name}) -> Name.

%% A node's routes, per bridge: "barn: direct; field: Ridge > 77?"
%% ("-" when no bridge has a route: the radios flood to reach it)
route_text(Node) ->
    case maps:get(<<"routes">>, Node, #{}) of
        Routes when map_size(Routes) =:= 0 ->
            "-";
        Routes ->
            lists:join("; ", [[Bridge, ": ", route(Route)]
                              || {Bridge, Route} <- lists:sort(maps:to_list(Routes))])
    end.

%% one route: "Ridge > 77?" | "direct"
route([]) -> "direct";
route(Route) -> lists:join(" > ", [hop_name(H) || H <- Route]).

%% "12:01:05  Bob on #0: rain at the gate   (direct, heard by barn,field)  SNR 8.0"
describe(Rx, Names) ->
    Where = case is_channel(Rx) of
                true -> io_lib:format("on #~p", [maps:get(<<"channel">>, Rx)]);
                false -> "to me"
            end,
    Snr = maps:get(<<"rx_snr">>, maps:get(<<"rxq">>, Rx)),
    io_lib:format("~s  ~ts ~s: ~ts   ~ts  SNR ~.1f",
                  [clock(), sender(Rx, Names), Where, maps:get(<<"text">>, Rx),
                   path_info(Rx), float(Snr)]).

%%====================================================================
%% Internal
%%====================================================================

clock() ->
    {_, {H, M, S}} = calendar:local_time(),
    io_lib:format("~2..0B:~2..0B:~2..0B", [H, M, S]).

client_id() ->
    iolist_to_binary(["lmc-", integer_to_list(erlang:unique_integer([positive])),
                      "-", integer_to_list(rand:uniform(1000000))]).

credentials(#{username := User, password := Pass}) ->
    [{username, User},
     {password, Pass}];
credentials(_) ->
    [].
