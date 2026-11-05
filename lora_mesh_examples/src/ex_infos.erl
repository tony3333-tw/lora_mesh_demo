%%
%% Infos: what lora_mesh is connected to, like serial_infos.py.
%%
%% serial_infos.py prints the radio's own SELF_INFO. lora_mesh 0.3 logs
%% each bridge's own node at start ("my node is @...") but does not
%% publish it; what MQTT does show is every node, and which bridges have
%% heard them.
%%
%%   lme infos
%%
-module(ex_infos).

-export([run/1]).

run(Opts) ->
    Client = lmc:connect(Opts),
    Nodes = lmc:nodes(Client, 1000),
    Count = fun(P) -> length([N || N <- Nodes, maps:get(<<"protocol">>, N) =:= P]) end,
    Bridges = lists:usort(lists:append([maps:keys(maps:get(<<"heard_by">>, N, #{}))
                                        || N <- Nodes])),
    io:format("broker:   ~s:~p, topics ~ts/...~n",
              [maps:get(host, Opts, "localhost"), maps:get(port, Opts, 1883),
               maps:get(prefix, Client)]),
    io:format("nodes:    ~p (~p MeshCore, ~p Meshtastic)~n",
              [length(Nodes), Count(<<"meshcore">>), Count(<<"meshtastic">>)]),
    io:format("bridges that have heard something: ~ts~n",
              [case Bridges of
                   [] -> <<"none yet">>;
                   _ -> lists:join(", ", Bridges)
               end]),
    lmc:disconnect(Client).
