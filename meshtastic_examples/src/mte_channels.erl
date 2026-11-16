%%
%% Print the channels saved on each bridge's radio, like get-channels.py
%% (lora_mesh 0.4: mesh/bridge/<id>/info).
%%
%%   mte channels
%%   mte channels --bridge home
%%
%% lora_mesh hides private channel keys ("(hidden)") unless its config
%% has {show_secrets, true}; the one-byte default keys such as AQ== show.
%%
-module(mte_channels).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    case mtc:bridges(C, Opts) of
        [] -> io:format("No channels found (no Meshtastic bridge has reported its radio).~n");
        Bridges -> lists:foreach(fun print_bridge/1, Bridges)
    end,
    mtc:disconnect(C).

print_bridge(#{<<"bridge">> := Bridge} = B) ->
    %% DISABLED is the default role, so lora_mesh leaves it out
    case [Ch || Ch <- maps:get(<<"channels">>, B, []), maps:is_key(<<"role">>, Ch)] of
        [] ->
            io:format("~ts: No channels found.~n", [Bridge]);
        Channels ->
            io:format("~ts: Channels:~n", [Bridge]),
            lists:foreach(fun print_channel/1, Channels)
    end.

print_channel(#{<<"index">> := Index, <<"role">> := Role} = Ch) ->
    Settings = maps:get(<<"settings">>, Ch, #{}),
    io:format("Index: ~p, Role: ~ts, PSK (Base64): ~ts, Name: ~ts~n",
              [Index, Role, psk(maps:get(<<"psk">>, Settings, <<>>)),
               maps:get(<<"name">>, Settings, <<>>)]).

%% "base64:AQ==" -> "AQ=="; "(hidden)" stays
psk(<<"base64:", B64/binary>>) -> B64;
psk(Other) -> Other.
