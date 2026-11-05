%%
%% Print the radio's modem preset (LONG_FAST, ...), like
%% get-config-modem-preset.py.
%%
%%   mte preset
%%
-module(mte_preset).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Lora = mtc:config(C, lora),
    io:format("~s~n", [maps:get(modem_preset, Lora)]),
    mtc:close(C).
