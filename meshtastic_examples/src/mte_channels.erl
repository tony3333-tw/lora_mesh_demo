%%
%% Print the channels saved on the radio, like get-channels.py.
%%
%%   mte channels
%%
-module(mte_channels).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    case [Ch || #{role := Role} = Ch <- mtc:channels(C), Role =/= 'DISABLED'] of
        [] ->
            io:format("No channels found.~n");
        Channels ->
            io:format("Channels:~n"),
            lists:foreach(fun print_channel/1, Channels)
    end,
    mtc:close(C).

print_channel(#{index := Index, role := Role, settings := Settings}) ->
    io:format("Index: ~p, Role: ~s, PSK (Base64): ~s, Name: ~ts~n",
              [Index, Role, base64:encode(maps:get(psk, Settings, <<>>)),
               maps:get(name, Settings, <<>>)]).
