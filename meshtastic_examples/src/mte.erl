%%
%% mte: run one example from the command line (rebar3 escriptize builds
%% _build/default/bin/mte), or from `rebar3 shell':
%%
%%   mte nodedb                        the Erlang version
%%   mte nodedb --lfe                  the LFE version
%%   mte nodedb --host 192.168.1.10    lora_mesh's broker on another machine
%%
%%   1> mte:main(["nodedb", "--lfe"]).
%%
%% The examples talk to lora_mesh through its MQTT broker; lora_mesh
%% holds the connections to the radios.
%%
%% Options (all optional; each example says which it uses):
%%   broker:  --host H (localhost) --port N (1883) --prefix P (mesh)
%%            --username U --password W
%%   what:    -d/--dest NODE  -m/--message TEXT  -c/--channel N
%%            --seconds S  --wait S  --all
%%   output:  --json  --topic T1,T2
%%   decode:  --type MSG  --hex HEX  --base64 B64
%%
-module(mte).

-export([main/1]).

%% example -> {Erlang module, LFE module, the Python examples it follows}
-define(EXAMPLES,
        [{"messages", mte_messages, mtl_messages, "print-messages.py, get-all-messages.py"},
         {"autoresponder", mte_autoresponder, mtl_autoresponder, "autoresponder.py, send-secondary.py"},
         {"chat", mte_chat, mtl_chat, "send-and-receive.py"},
         {"dm", mte_dm, mtl_dm, "send-direct-message.py"},
         {"nodedb", mte_nodedb, mtl_nodedb, "print-nodedb.py"},
         {"decode", mte_decode, mtl_decode, "decode-protobuf.py"},
         {"protos", mte_protos, mtl_protos, "list-protos.py"},
         {"mqtt-receive", mte_mqtt_receive, mtl_mqtt_receive, "MQTT/receive-mqtt-packets.py"},
         {"mqtt-send", mte_mqtt_send, mtl_mqtt_send, "MQTT/send-mqtt-packets.py"},
         {"mqtt-client", mte_mqtt_client, mtl_mqtt_client, "MQTT/mqtt-client.py"}]).

main([Name | Args]) ->
    %% print names and emoji as they are, not as \x{...}
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    case lists:keyfind(Name, 1, ?EXAMPLES) of
        {Name, Erl, Lfe, _Like} ->
            with_options(Args, fun(Opts) ->
                                       Module = case maps:get(lfe, Opts, false) of
                                                    true -> Lfe;
                                                    false -> Erl
                                                end,
                                       run(Module, Opts)
                               end);
        false ->
            usage()
    end;
main([]) ->
    usage().

with_options(Args, Fun) ->
    try options(Args, #{}) of
        Opts -> Fun(Opts)
    catch
        throw:{bad_option, Opt} ->
            io:format("unknown or incomplete option: ~ts~n", [Opt]),
            usage()
    end.

run(Module, Opts) ->
    try
        Module:run(Opts)
    catch
        error:{mqtt_connect, Reason} ->
            io:format("cannot reach the MQTT broker at ~s:~p (~p)~n"
                      "(is it running, and is lora_mesh connected to it?)~n",
                      [maps:get(host, Opts, "localhost"), maps:get(port, Opts, 1883), Reason]);
        error:{unknown_node, Dest} ->
            io:format("lora_mesh knows no node '~ts' (use a name, !id or number; "
                      "mte nodedb lists them)~n", [Dest]);
        error:{missing_option, Option} ->
            io:format("this example needs ~s~n", [Option])
    end.

usage() ->
    io:format("usage: mte EXAMPLE [--lfe] [options]~n~n"
              "through lora_mesh (--host H --port N --prefix P, default localhost:1883 mesh):~n"),
    [io:format("  ~-14s ~s~n", [Name, Like]) || {Name, _, _, Like} <- ?EXAMPLES],
    io:format("~nsee README.md for each example's options, and for the examples~n"
              "that wait for lora_mesh 0.4~n").

options([], Opts) ->
    Opts;
options(["--lfe" | Rest], Opts) -> options(Rest, Opts#{lfe => true});
options(["--json" | Rest], Opts) -> options(Rest, Opts#{json => true});
options(["--all" | Rest], Opts) -> options(Rest, Opts#{all => true});
options(["--host", V | Rest], Opts) -> options(Rest, Opts#{host => V});
options(["--port", V | Rest], Opts) -> options(Rest, Opts#{port => int(V)});
options(["--prefix", V | Rest], Opts) -> options(Rest, Opts#{prefix => V});
options(["--username", V | Rest], Opts) -> options(Rest, Opts#{username => V});
options(["--password", V | Rest], Opts) -> options(Rest, Opts#{password => V});
options([D, V | Rest], Opts) when D =:= "-d"; D =:= "--dest" ->
    options(Rest, Opts#{dest => V});
options([M, V | Rest], Opts) when M =:= "-m"; M =:= "--message" ->
    options(Rest, Opts#{message => V});
options([C, V | Rest], Opts) when C =:= "-c"; C =:= "--channel" ->
    options(Rest, Opts#{channel => int(V)});
options(["--seconds", V | Rest], Opts) -> options(Rest, Opts#{seconds => int(V)});
options(["--wait", V | Rest], Opts) -> options(Rest, Opts#{wait => int(V)});
options(["--topic", V | Rest], Opts) -> options(Rest, Opts#{topics => string:lexemes(V, ",")});
options(["--type", V | Rest], Opts) -> options(Rest, Opts#{type => V});
options(["--hex", V | Rest], Opts) -> options(Rest, Opts#{hex => V});
options(["--base64", V | Rest], Opts) -> options(Rest, Opts#{base64 => V});
options([Other | _], _Opts) ->
    throw({bad_option, Other}).

int(V) ->
    try list_to_integer(V)
    catch error:badarg -> throw({bad_option, V})
    end.
