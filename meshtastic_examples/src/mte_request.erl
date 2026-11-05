%%
%% Ask a node for something and print its answer, like the request-*.py
%% examples:
%%
%%   mte request -d "Hill top"                       telemetry (device metrics),
%%                                                   request-telemetry-simple.py
%%   mte request -d "Hill top" --what environment    request-enviroment-metrics.py
%%   mte request -d "Hill top" --what position       request-position.py
%%   mte request -d "Hill top" --what nodeinfo       request-nodeinfo.py
%%
%% Also --what local_stats | power (other telemetry kinds). The answer
%% is printed the way the Python library prints it.
%%
-module(mte_request).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Dest = mtc:dest(C, Opts),
    Ask = #{to => Dest, want_response => true, channel => maps:get(channel, Opts, 0)},
    {Port, Id} =
        case maps:get(what, Opts, "telemetry") of
            "telemetry" -> {'TELEMETRY_APP', mtc:send_telemetry(C, device_metrics, Ask)};
            "environment" -> {'TELEMETRY_APP', mtc:send_telemetry(C, environment_metrics, Ask)};
            "local_stats" -> {'TELEMETRY_APP', mtc:send_telemetry(C, local_stats, Ask)};
            "power" -> {'TELEMETRY_APP', mtc:send_telemetry(C, power_metrics, Ask)};
            "position" -> {'POSITION_APP', mtc:send_position(C, Ask)};
            "nodeinfo" -> {'NODEINFO_APP', send_nodeinfo(C, Ask)}
        end,
    io:format("Asked ~ts, waiting for the answer...~n", [mtc:name(C, Dest)]),
    case mtc:reply(C, Id, Port, 60000) of
        {ok, P} -> answer(Port, P);
        {error, Reason} -> io:format("No answer: ~s~n", [Reason]);
        timeout -> io:format("No answer within 60 s~n");
        closed -> io:format("the radio closed the connection~n")
    end,
    mtc:close(C).

%% Our own User, with want_response: the node answers with its own
send_nodeinfo(C, Ask) ->
    {ok, Me} = mtc:node(C, mtc:my_num(C)),
    mtc:send_data(C, 'NODEINFO_APP', {user, maps:get(user, Me)}, Ask).

answer('TELEMETRY_APP', P) ->
    io:format("Telemetry received:~n"),
    case mtc:get(P, [decoded, telemetry], #{}) of
        #{device_metrics := M} ->
            pct("Battery level: ~.2f%~n", M, battery_level),
            pct("Voltage: ~.2f V~n", M, voltage),
            pct("Total channel utilization: ~.2f%~n", M, channel_utilization),
            pct("Transmit air utilization: ~.2f%~n", M, air_util_tx),
            case M of
                #{uptime_seconds := Up} -> io:format("Uptime: ~p s~n", [Up]);
                _ -> ok
            end;
        Telemetry ->
            [begin
                 io:format("~s:~n", [Kind]),
                 [io:format("  ~s: ~ts~n", [K, mtc:show(V)]) || {K, V} <- lists:sort(maps:to_list(Values))]
             end
             || {Kind, Values} <- maps:to_list(maps:remove(time, Telemetry))],
            ok
    end;
answer('POSITION_APP', P) ->
    Pos = mtc:get(P, [decoded, position], #{}),
    Where = case Pos of
                #{latitude := Lat, longitude := Lon} -> ["(", mtc:show(Lat), ", ", mtc:show(Lon), ")"];
                _ -> "(unknown)"
            end,
    Alt = case Pos of
              #{altitude := A} -> io_lib:format(" ~pm", [A]);
              _ -> ""
          end,
    Precision = case maps:get(precision_bits, Pos, 0) of
                    32 -> " full precision";
                    0 -> " position disabled";
                    Bits -> io_lib:format(" precision:~p", [Bits])
                end,
    io:format("Position received: ~s~s~s~n", [Where, Alt, Precision]);
answer('NODEINFO_APP', P) ->
    io:format("~ts~n", [mtc:json(P)]).

pct(Format, Map, Key) ->
    case Map of
        #{Key := V} -> io:format(Format, [float(V)]);
        _ -> ok
    end.
