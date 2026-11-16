%%
%% Print each bridge's own radio as JSON, like print-myNodeInfo
%% (interface.getMyNodeInfo()): lora_mesh's record of that node, with the
%% radio's my_info (lora_mesh 0.4: mesh/bridge/<id>/info).
%%
%%   mte myinfo
%%   mte myinfo --bridge home
%%
-module(mte_myinfo).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    case mtc:bridges(C, Opts) of
        [] ->
            io:format("no Meshtastic bridge has reported its radio yet "
                      "(lora_mesh 0.4 needed)~n");
        Bridges ->
            Nodes = mtc:nodes(C, Opts),
            lists:foreach(fun(B) -> print_bridge(B, Nodes) end, Bridges)
    end,
    mtc:disconnect(C).

print_bridge(#{<<"bridge">> := Bridge, <<"my_id">> := MyId} = B, Nodes) ->
    Node = case mtc:find(Nodes, MyId) of
               {ok, N} -> N;
               error -> #{<<"id">> => MyId}
           end,
    io:format("~ts:~n~ts~n", [Bridge, mtc:json(Node#{<<"my_info">> => maps:get(<<"my_info">>, B, #{})})]).
