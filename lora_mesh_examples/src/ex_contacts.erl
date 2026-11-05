%%
%% Contacts: every node lora_mesh knows, like serial_contacts.py and
%% tcp_mchome_contacts.py (meshcore_py/examples).
%%
%% meshcore_py asks the radio (CMD_GET_CONTACTS). Here lora_mesh has
%% already done that for every bridge and keeps the answer on
%% mesh/node/<id>, retained: subscribing is enough.
%%
%%   lme contacts             MeshCore nodes, as a table
%%   lme contacts --all       Meshtastic nodes too
%%   lme contacts --json      as JSON, like the Python example
%%
%% routes (lora_mesh 0.3.2): how each bridge's radio reaches the contact,
%% e.g. "field: Ridge; barn: direct".
%%
-module(ex_contacts).

-export([run/1]).

run(Opts) ->
    Client = lmc:connect(Opts),
    Nodes = [N || N <- lmc:nodes(Client, 1000),
                  maps:get(all, Opts, false)
                      orelse maps:get(<<"protocol">>, N) =:= <<"meshcore">>],
    case maps:get(json, Opts, false) of
        true -> io:format("~ts~n", [json:format(Nodes)]);
        false -> table(Nodes)
    end,
    lmc:disconnect(Client).

table([]) ->
    io:format("no nodes yet (is lora_mesh running and connected to the broker?)~n");
table(Nodes) ->
    io:format("~-15s ~-9s ~-14s ~-20s ~-10s ~-12s ~s~n",
              ["id", "type", "name", "position", "heard", "heard by", "routes"]),
    lists:foreach(fun row/1, Nodes),
    io:format("~p nodes~n", [length(Nodes)]).

row(Node) ->
    io:format("~-15ts ~-9ts ~-14ts ~-20s ~-10s ~-12ts ~ts~n",
              [maps:get(<<"id">>, Node),
               lmc:kind(Node),
               name(Node),
               position(maps:get(<<"position">>, Node, null)),
               ago(maps:get(<<"last_heard">>, Node, null)),
               lists:join(",", lists:sort(maps:keys(maps:get(<<"heard_by">>, Node, #{})))),
               lmc:route_text(Node)]).

name(Node) ->
    case maps:get(<<"long_name">>, Node, null) of
        null -> <<"?">>;
        Name -> Name
    end.

position(null) ->
    "-";
position(#{<<"latitude">> := Lat, <<"longitude">> := Lon}) ->
    io_lib:format("~.4f,~.4f", [float(Lat), float(Lon)]).

ago(null) ->
    "-";
ago(Time) ->
    case erlang:system_time(second) - Time of
        S when S < 120 -> io_lib:format("~ps ago", [S]);
        S when S < 7200 -> io_lib:format("~pm ago", [S div 60]);
        S when S < 172800 -> io_lib:format("~ph ago", [S div 3600]);
        _ -> string:slice(calendar:system_time_to_rfc3339(Time), 0, 10)   % long ago: the date
    end.
