%%
%% Print every message as it arrives, like tcp_mchome_readmsgs.py,
%% chan_recv_with_path.py and the message part of pubsub_example.py.
%%
%% meshcore_py pulls messages from the radio (CMD_SYNC_NEXT_MESSAGE).
%% lora_mesh already pulls them from every bridge, merges copies heard
%% by several bridges, and publishes each once on mesh/rx/<from>.
%%
%%   lme readmsgs              until Ctrl-C
%%   lme readmsgs --count 5    stop after 5 messages
%%
-module(ex_readmsgs).

-export([run/1]).

run(Opts) ->
    Client = lmc:connect(Opts),
    Names = lmc:names(lmc:nodes(Client, 500)),
    ok = lmc:subscribe(Client, rx),
    io:format("Waiting for messages (Ctrl-C to stop)...~n"),
    loop(Client, Names, maps:get(count, Opts, infinity)),
    lmc:disconnect(Client).

loop(_Client, _Names, 0) ->
    ok;
loop(Client, Names, Count) ->
    case lmc:next(Client, infinity) of
        {rx, Rx} ->
            io:format("~ts~n", [lmc:describe(Rx, Names)]),
            loop(Client, Names, decrement(Count));
        {node, Node} ->
            %% keep names current: a new node may speak next
            loop(Client, lmc:add_name(Names, Node), Count)
    end.

decrement(infinity) -> infinity;
decrement(N) -> N - 1.
