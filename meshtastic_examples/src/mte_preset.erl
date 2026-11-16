%%
%% Print each bridge's radio modem preset (LONG_FAST, ...), like
%% get-config-modem-preset.py (lora_mesh 0.4: mesh/bridge/<id>/info).
%%
%%   mte preset
%%   mte preset --bridge home
%%
-module(mte_preset).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    case mtc:bridges(C, Opts) of
        [] ->
            io:format("no Meshtastic bridge has reported its radio yet (lora_mesh 0.4 needed)~n");
        Bridges ->
            [io:format("~ts: ~ts~n", [Bridge, preset(B)]) || #{<<"bridge">> := Bridge} = B <- Bridges]
    end,
    mtc:disconnect(C).

%% LONG_FAST is the first preset, a default, so lora_mesh leaves it out
preset(B) ->
    mtc:get(B, [<<"config">>, <<"lora">>, <<"modem_preset">>], <<"LONG_FAST">>).
