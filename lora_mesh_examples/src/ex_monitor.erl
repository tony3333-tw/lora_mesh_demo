%%
%% Watch the mesh's nodes change, like pubsub_example.py (adverts),
%% connection_events_example.py and serial_battery_monitor.py:
%%
%%   new node @e1e2e3e4e5e6 Dave (chat)
%%   Hill top: battery 81% -> 79%
%%   Bob: heard by barn (SNR 8.0, direct)
%%   Pump: route from field now Ridge > 77?
%%
%% serial_battery_monitor.py asks the radio for its own battery every
%% 10 s; lora_mesh 0.3 has no such command. It does publish the battery
%% that Meshtastic nodes report about themselves (MeshCore contacts carry
%% none), and that is shown here.
%%
%%   lme monitor
%%
-module(ex_monitor).

-export([run/1]).

run(Opts) ->
    Client = lmc:connect(Opts),
    ok = lmc:subscribe(Client, nodes),
    io:format("Watching nodes (Ctrl-C to stop)...~n"),
    loop(Client, #{}).

%% Known: #{Id => last node map}
loop(#{conn := _} = Client, Known) ->
    receive
        {publish, #{retain := Retained} = Msg} ->
            case lmc:decode(Client, Msg) of
                {node, #{<<"id">> := Id} = Node} ->
                    case Known of
                        #{Id := Old} -> changes(Old, Node);
                        #{} when Retained -> known(Node);
                        #{} -> new(Node)
                    end,
                    loop(Client, Known#{Id => Node});
                _ ->
                    loop(Client, Known)
            end
    end.

known(Node) ->
    io:format("known   ~ts ~ts (~ts)~n", [id(Node), name(Node), lmc:kind(Node)]).

new(Node) ->
    io:format("new node ~ts ~ts (~ts)~n", [id(Node), name(Node), lmc:kind(Node)]).

changes(Old, New) ->
    Name = name(New),
    [io:format("~ts: name ~ts -> ~ts~n", [id(New), name(Old), Name])
     || name(Old) =/= Name],
    [io:format("~ts: battery ~ts -> ~ts~n", [Name, battery(Old), battery(New)])
     || battery(Old) =/= battery(New)],
    [io:format("~ts: position ~ts~n", [Name, position(New)])
     || maps:get(<<"position">>, Old) =/= maps:get(<<"position">>, New)],
    routes(Name, maps:get(<<"routes">>, Old, #{}), maps:get(<<"routes">>, New, #{})),
    OldHeard = maps:get(<<"heard_by">>, Old, #{}),
    maps:foreach(
      fun(Bridge, #{<<"at">> := At, <<"rxq">> := RxQ}) ->
              case maps:get(Bridge, OldHeard, #{}) of
                  #{<<"at">> := At} ->
                      ok;
                  _ ->
                      io:format("~ts: heard by ~ts (SNR ~.1f, ~ts)~n",
                                [Name, Bridge, float(maps:get(<<"rx_snr">>, RxQ)),
                                 lmc:path_text(#{<<"rxq">> => RxQ})])
              end
      end,
      maps:get(<<"heard_by">>, New, #{})).

%% a bridge's radio learned (or lost) its route to the node
routes(Name, Old, New) ->
    maps:foreach(
      fun(Bridge, Route) ->
              case maps:get(Bridge, Old, none) of
                  Route ->
                      ok;
                  _ ->
                      io:format("~ts: route from ~ts now ~ts~n",
                                [Name, Bridge, lmc:route(Route)])
              end
      end,
      New),
    [io:format("~ts: route from ~ts forgotten (it floods)~n", [Name, Bridge])
     || Bridge <- maps:keys(Old), not is_map_key(Bridge, New)],
    ok.

id(Node) -> maps:get(<<"id">>, Node).

name(Node) ->
    case maps:get(<<"long_name">>, Node, null) of
        null -> id(Node);
        Name -> Name
    end.

battery(Node) ->
    case maps:get(<<"battery_level">>, Node, null) of
        null -> <<"?">>;
        101 -> <<"powered">>;
        Level -> iolist_to_binary(io_lib:format("~p%", [Level]))
    end.

position(Node) ->
    case maps:get(<<"position">>, Node, null) of
        null -> <<"none">>;
        #{<<"latitude">> := Lat, <<"longitude">> := Lon} ->
            iolist_to_binary(io_lib:format("~.5f,~.5f", [float(Lat), float(Lon)]))
    end.
