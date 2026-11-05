%%
%% List the nodes lora_mesh knows, like print-nodedb.py.
%%
%%   mte nodedb
%%   mte nodedb --json
%%   mte nodedb --all          MeshCore nodes too
%%
%% print-nodedb.py lists one radio's node database. lora_mesh's list is
%% the nodes every bridge has heard, with which bridges heard each one.
%% It has no SNR, hops or channel use per node yet (lora_mesh 0.4).
%%
-module(mte_nodedb).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Nodes = mtc:nodes(C, Opts),
    case maps:get(json, Opts, false) of
        true -> io:format("~ts~n", [json:format(Nodes)]);
        false -> lists:foreach(fun print_node/1, Nodes)
    end,
    mtc:disconnect(C).

print_node(Node) ->
    field("Node Num", Node, <<"num">>),
    field("Node ID", Node, <<"id">>),
    field("Long Name", Node, <<"long_name">>),
    field("Short Name", Node, <<"short_name">>),
    field("Hardware Model", Node, <<"hw_model">>),
    field("Role", Node, <<"role">>),
    Pos = case maps:get(<<"position">>, Node, null) of
              null -> #{};
              P -> P
          end,
    field("Latitude", Pos, <<"latitude">>),
    field("Longitude", Pos, <<"longitude">>),
    field("Altitude", Pos, <<"altitude">>),
    field("Time", Pos, <<"time">>),
    field("Battery Level", Node, <<"battery_level">>),
    field("Voltage", Node, <<"voltage">>),
    field("Last Heard", Node, <<"last_heard">>),
    HeardBy = maps:get(<<"heard_by">>, Node, #{}),
    [io:format("Heard By: ~ts (SNR ~ts)~n",
               [Bridge, show(maps:get(<<"rx_snr">>, maps:get(<<"rxq">>, Heard)))])
     || {Bridge, Heard} <- lists:sort(maps:to_list(HeardBy))],
    io:format("~n~n").

%% print a line only when the field has a value, as print-nodedb.py does
field(Label, Map, Key) ->
    case maps:get(Key, Map, null) of
        null -> ok;
        V -> io:format("~s: ~ts~n", [Label, show(V)])
    end.

show(V) when is_binary(V) -> V;
show(V) when is_float(V) -> float_to_binary(V, [short]);
show(V) -> io_lib:format("~p", [V]).
