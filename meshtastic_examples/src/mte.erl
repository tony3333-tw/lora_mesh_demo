%%
%% mte: run one example from the command line (rebar3 escriptize builds
%% _build/default/bin/mte), or from `rebar3 shell':
%%
%%   mte nodedb                        the Erlang version
%%   mte nodedb --lfe                  the LFE version
%%   mte nodedb --host 192.168.1.42    a radio on WiFi (TCP port 4403)
%%   mte fake-radio                    a fake radio to try them on
%%
%%   1> mte:main(["nodedb", "--lfe"]).
%%
%% Options (all optional; each example says which it uses):
%%   radio:   --host H (localhost) --port N (4403)
%%   what:    -d/--dest NODE  -m/--message TEXT  -c/--channel N  --what KIND
%%            --hop-limit N  --seconds S  --wait S  --every S  --pause S
%%   output:  --raw  --json  --log FILE  --counts
%%   send:    --lat D  --lon D  --alt M
%%   config:  --index N  --name NAME  --psk BASE64  --keys K1,K2  --url URL
%%   decode:  --type MSG  --hex HEX  --base64 B64
%%   MQTT:    --broker H  --mqtt-port N  --username U  --password W
%%            --root TOPIC  --channel-name NAME  --key BASE64  --topic T1,T2
%%
-module(mte).

-export([main/1]).

%% example -> {Erlang module, LFE module, the Python examples it follows}
-define(EXAMPLES,
        [{"messages", mte_messages, mtl_messages, "print-messages.py, get-all-messages.py"},
         {"autoresponder", mte_autoresponder, mtl_autoresponder, "autoresponder.py, send-secondary.py"},
         {"chat", mte_chat, mtl_chat, "send-and-receive.py"},
         {"dm", mte_dm, mtl_dm, "send-direct-message.py"},
         {"packets", mte_packets, mtl_packets,
          "print-packets.py, print-packets-basic.py, print-packets-json.py,\n"
          "                    print-packets-json-log.py, print-packets-json-log-and-plot.py"},
         {"local-stats", mte_local_stats, mtl_local_stats, "get-local-stats.py"},
         {"myinfo", mte_myinfo, mtl_myinfo, "print-myNodeInfo"},
         {"nodedb", mte_nodedb, mtl_nodedb, "print-nodedb.py"},
         {"channels", mte_channels, mtl_channels, "get-channels.py"},
         {"preset", mte_preset, mtl_preset, "get-config-modem-preset.py"},
         {"traceroute", mte_traceroute, mtl_traceroute, "send-traceroute-simple.py, print-traceroute.py"},
         {"request", mte_request, mtl_request,
          "request-telemetry-simple.py, request-enviroment-metrics.py,\n"
          "                    request-position.py, request-nodeinfo.py"},
         {"send", mte_send, mtl_send,
          "send-position.py, send-nodeinfo.py, send-telemetry.py, send-waypoint.py,\n"
          "                    send-device-metrics.py, send-environment-metrics.py"},
         {"foxhunt", mte_foxhunt, mtl_foxhunt, "foxhunt.py, test-rssi-snr.py"},
         {"watchdog", mte_watchdog, mtl_watchdog, "tcp_watchdog.py"},
         {"save-channel", mte_save_channel, mtl_save_channel, "save-channel.py"},
         {"admin-keys", mte_admin_keys, mtl_admin_keys, "save-admin-keys.py"},
         {"set-url", mte_set_url, mtl_set_url, "set-URL.py"},
         {"decode", mte_decode, mtl_decode, "decode-protobuf.py"},
         {"protos", mte_protos, mtl_protos, "list-protos.py"},
         {"mqtt-receive", mte_mqtt_receive, mtl_mqtt_receive, "MQTT/receive-mqtt-packets.py"},
         {"mqtt-send", mte_mqtt_send, mtl_mqtt_send, "MQTT/send-mqtt-packets.py"},
         {"mqtt-client", mte_mqtt_client, mtl_mqtt_client, "MQTT/mqtt-client.py"},
         {"radio-mqtt", mte_radio_mqtt, mtl_radio_mqtt, "MQTT/serial-mqtt.py"}]).

main(["fake-radio" | Args]) ->
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    with_options(Args, fun(Opts) ->
                               mtfake:run(Opts#{interval => maps:get(every, Opts, 5) * 1000})
                       end);
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
        error:{radio_connect, Reason} ->
            io:format("cannot reach the radio at ~s:~p (~p)~n"
                      "(is it on the network? or start one: mte fake-radio)~n",
                      [maps:get(host, Opts, "localhost"), maps:get(port, Opts, 4403), Reason]);
        error:{radio_closed, _} ->
            io:format("the radio closed the connection~n");
        error:{mqtt_connect, Reason} ->
            io:format("cannot reach the MQTT broker at ~s:~p (~p)~n",
                      [maps:get(broker, Opts, "the default broker"), maps:get(mqtt_port, Opts, 1883), Reason]);
        error:{unknown_node, Dest} ->
            io:format("no node '~ts' in the radio's node list (use a name, !id or number)~n", [Dest]);
        error:{missing_option, Option} ->
            io:format("this example needs ~s~n", [Option])
    end.

usage() ->
    io:format("usage: mte EXAMPLE [--lfe] [options]~n~n"
              "radio examples (--host H --port N, default localhost:4403):~n"),
    [io:format("  ~-14s ~s~n", [Name, Like])
     || {Name, _, _, Like} <- ?EXAMPLES, not lists:prefix("MQTT", Like)],
    io:format("~nMQTT examples (--broker H --mqtt-port N --username U --password W):~n"),
    [io:format("  ~-14s ~s~n", [Name, Like])
     || {Name, _, _, Like} <- ?EXAMPLES, lists:prefix("MQTT", Like)],
    io:format("~n  fake-radio     a fake radio to try the examples on (--port N --every S)~n"
              "~nsee README.md for each example's options~n").

options([], Opts) ->
    Opts;
options(["--lfe" | Rest], Opts) -> options(Rest, Opts#{lfe => true});
options(["--raw" | Rest], Opts) -> options(Rest, Opts#{raw => true});
options(["--json" | Rest], Opts) -> options(Rest, Opts#{json => true});
options(["--counts" | Rest], Opts) -> options(Rest, Opts#{counts => true});
options(["--clear" | Rest], Opts) -> options(Rest, Opts#{clear => true});
options(["--quiet" | Rest], Opts) -> options(Rest, Opts#{quiet => true});
options(["--host", V | Rest], Opts) -> options(Rest, Opts#{host => V});
options(["--port", V | Rest], Opts) -> options(Rest, Opts#{port => int(V)});
options([D, V | Rest], Opts) when D =:= "-d"; D =:= "--dest" ->
    options(Rest, Opts#{dest => V});
options([M, V | Rest], Opts) when M =:= "-m"; M =:= "--message" ->
    options(Rest, Opts#{message => V});
options([C, V | Rest], Opts) when C =:= "-c"; C =:= "--channel" ->
    options(Rest, Opts#{channel => int(V)});
options(["--what", V | Rest], Opts) -> options(Rest, Opts#{what => V});
options(["--hop-limit", V | Rest], Opts) -> options(Rest, Opts#{hop_limit => int(V)});
options(["--seconds", V | Rest], Opts) -> options(Rest, Opts#{seconds => int(V)});
options(["--wait", V | Rest], Opts) -> options(Rest, Opts#{wait => int(V)});
options(["--every", V | Rest], Opts) -> options(Rest, Opts#{every => int(V)});
options(["--pause", V | Rest], Opts) -> options(Rest, Opts#{pause => int(V)});
options(["--log", V | Rest], Opts) -> options(Rest, Opts#{log => V});
options(["--lat", V | Rest], Opts) -> options(Rest, Opts#{lat => num(V)});
options(["--lon", V | Rest], Opts) -> options(Rest, Opts#{lon => num(V)});
options(["--alt", V | Rest], Opts) -> options(Rest, Opts#{alt => num(V)});
options(["--index", V | Rest], Opts) -> options(Rest, Opts#{index => int(V)});
options(["--name", V | Rest], Opts) -> options(Rest, Opts#{name => V});
options(["--psk", V | Rest], Opts) -> options(Rest, Opts#{psk => V});
options(["--keys", V | Rest], Opts) -> options(Rest, Opts#{keys => string:lexemes(V, ",")});
options(["--url", V | Rest], Opts) -> options(Rest, Opts#{url => V});
options(["--type", V | Rest], Opts) -> options(Rest, Opts#{type => V});
options(["--hex", V | Rest], Opts) -> options(Rest, Opts#{hex => V});
options(["--base64", V | Rest], Opts) -> options(Rest, Opts#{base64 => V});
options(["--broker", V | Rest], Opts) -> options(Rest, Opts#{broker => V});
options(["--mqtt-port", V | Rest], Opts) -> options(Rest, Opts#{mqtt_port => int(V)});
options(["--username", V | Rest], Opts) -> options(Rest, Opts#{username => V});
options(["--password", V | Rest], Opts) -> options(Rest, Opts#{password => V});
options(["--root", V | Rest], Opts) -> options(Rest, Opts#{root => V});
options(["--channel-name", V | Rest], Opts) -> options(Rest, Opts#{channel_name => V});
options(["--key", V | Rest], Opts) -> options(Rest, Opts#{key => V});
options(["--topic", V | Rest], Opts) -> options(Rest, Opts#{topics => string:lexemes(V, ",")});
options([Other | _], _Opts) ->
    throw({bad_option, Other}).

int(V) ->
    try list_to_integer(V)
    catch error:badarg -> throw({bad_option, V})
    end.

num(V) ->
    try list_to_float(V)
    catch error:badarg -> int(V)
    end.
