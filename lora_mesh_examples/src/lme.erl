%%
%% lme: run one example from the command line (rebar3 escriptize builds
%% _build/default/bin/lme), or from `rebar3 shell':
%%
%%   lme contacts                     the Erlang version
%%   lme contacts --lfe               the LFE version
%%   lme msg -d Alice -m "hello"
%%   lme chat -d Alice
%%   lme pingbot --channel 0
%%
%%   1> lme:main(["contacts", "--lfe"]).
%%
%% Options (all optional):
%%   --host H  --port N  --prefix P  --username U  --password W
%%   -d/--dest NAME  -m/--message TEXT  -c/--channel N
%%   --protocol meshcore|meshtastic  --wait S  --count N  --all  --json
%%
-module(lme).

-export([main/1]).

%% example -> {Erlang module, LFE module, the meshcore_py examples it follows}
-define(EXAMPLES,
        [{"contacts", ex_contacts, lx_contacts, "serial_contacts.py, tcp_mchome_contacts.py"},
         {"infos", ex_infos, lx_infos, "serial_infos.py, tcp_mchome_infos.py"},
         {"msg", ex_msg, lx_msg, "serial_msg.py, tcp_mchome_msg.py"},
         {"readmsgs", ex_readmsgs, lx_readmsgs, "tcp_mchome_readmsgs.py, chan_recv_with_path.py"},
         {"chat", ex_chat, lx_chat, "serial_chat.py, tcp_chat.py"},
         {"pingbot", ex_pingbot, lx_pingbot, "serial_pingbot.py"},
         {"monitor", ex_monitor, lx_monitor, "pubsub_example.py, serial_battery_monitor.py"}]).

main([Name | Args]) ->
    %% print names and emoji as they are, not as \x{...}
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    case lists:keyfind(Name, 1, ?EXAMPLES) of
        {Name, Erl, Lfe, _Like} ->
            try options(Args, #{}) of
                Opts ->
                    Module = case maps:get(lfe, Opts, false) of
                                 true -> Lfe;
                                 false -> Erl
                             end,
                    run(Module, Opts)
            catch
                throw:{bad_option, Opt} ->
                    io:format("unknown or incomplete option: ~ts~n", [Opt]),
                    usage()
            end;
        false ->
            usage()
    end;
main([]) ->
    usage().

run(Module, Opts) ->
    try
        Module:run(Opts)
    catch
        error:{mqtt_connect, Reason} ->
            io:format("cannot reach the MQTT broker at ~s:~p (~p)~n",
                      [maps:get(host, Opts, "localhost"), maps:get(port, Opts, 1883), Reason])
    end.

usage() ->
    io:format("usage: lme EXAMPLE [--lfe] [options]~n~n"),
    [io:format("  ~-9s like ~s~n", [Name, Like]) || {Name, _, _, Like} <- ?EXAMPLES],
    io:format("~noptions: --host H --port N --prefix P --username U --password W~n"
              "         -d NAME -m TEXT -c N --protocol meshcore|meshtastic~n"
              "         --wait S --count N --all --json~n").

options([], Opts) ->
    Opts;
options(["--lfe" | Rest], Opts) -> options(Rest, Opts#{lfe => true});
options(["--all" | Rest], Opts) -> options(Rest, Opts#{all => true});
options(["--json" | Rest], Opts) -> options(Rest, Opts#{json => true});
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
options(["--protocol", V | Rest], Opts) ->
    options(Rest, Opts#{protocol => list_to_atom(V)});
options(["--wait", V | Rest], Opts) -> options(Rest, Opts#{wait => int(V)});
options(["--count", V | Rest], Opts) -> options(Rest, Opts#{count => int(V)});
options([Other | _], _Opts) ->
    throw({bad_option, Other}).

int(V) ->
    try list_to_integer(V)
    catch error:badarg -> throw({bad_option, V})
    end.
