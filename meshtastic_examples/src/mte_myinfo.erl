%%
%% Print our own node's entry in the node database as JSON, like
%% print-myNodeInfo (interface.getMyNodeInfo()).
%%
%%   mte myinfo
%%
-module(mte_myinfo).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    case mtc:node(C, mtc:my_num(C)) of
        {ok, Node} -> io:format("~ts~n", [mtc:json(Node)]);
        error -> io:format("our node is not in the node database yet~n")
    end,
    mtc:close(C).
