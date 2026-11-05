%%
%% List the nodes in the radio's node database, like print-nodedb.py.
%%
%%   mte nodedb
%%   mte nodedb --json
%%
-module(mte_nodedb).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Nodes = mtc:nodes(C),
    case maps:get(json, Opts, false) of
        true -> io:format("~ts~n", [mtc:json(Nodes)]);
        false -> lists:foreach(fun print_node/1, Nodes)
    end,
    mtc:close(C).

print_node(Node) ->
    User = maps:get(user, Node, #{}),
    io:format("Node Num: ~p~n", [maps:get(num, Node)]),
    io:format("Node ID: ~ts~n", [maps:get(id, User, <<"?">>)]),
    io:format("Long Name: ~ts~n", [maps:get(long_name, User, <<"">>)]),
    io:format("Short Name: ~ts~n", [maps:get(short_name, User, <<"">>)]),
    io:format("Hardware Model: ~s~n", [maps:get(hw_model, User, 'UNSET')]),
    field("Role", User, role),
    case User of
        #{macaddr := Mac} -> io:format("MAC Address: ~s~n", [mac(Mac)]);
        _ -> ok
    end,
    case User of
        #{public_key := Key} -> io:format("Public Key: ~s~n", [base64:encode(Key)]);
        _ -> ok
    end,
    field("SNR", Node, snr),
    field("Last Heard", Node, last_heard),
    field("Hops Away", Node, hops_away),
    Pos = maps:get(position, Node, #{}),
    field("Latitude", Pos, latitude),
    field("Longitude", Pos, longitude),
    field("Altitude", Pos, altitude),
    field("Time", Pos, time),
    Metrics = maps:get(device_metrics, Node, #{}),
    field("Battery Level", Metrics, battery_level),
    field("Voltage", Metrics, voltage),
    field("Channel Utilization", Metrics, channel_utilization),
    field("Air Util Tx", Metrics, air_util_tx),
    field("Uptime Seconds", Metrics, uptime_seconds),
    io:format("~n~n").

%% print a line only when the field is there, as print-nodedb.py does
field(Label, Map, Key) ->
    case Map of
        #{Key := V} -> io:format("~s: ~ts~n", [Label, mtc:show(V)]);
        _ -> ok
    end.

mac(Mac) ->
    lists:join(":", [io_lib:format("~2.16.0b", [B]) || <<B>> <= Mac]).
