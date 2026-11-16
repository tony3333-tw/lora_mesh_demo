%%
%% Print every packet lora_mesh's bridges hear, five ways, like the
%% print-packets*.py examples (lora_mesh 0.4: mesh/packet/<from>):
%%
%%   mte packets                  parsed by port, like print-packets.py
%%   mte packets --raw            the packet map as it is, like print-packets-basic.py
%%   mte packets --json           as JSON, like print-packets-json.py
%%   mte packets --log FILE       as JSON, also kept in FILE (a JSON array),
%%                                like print-packets-json-log.py
%%   mte packets --counts         packets per port and per sender, every
%%                                10 s, as text bar charts, instead of
%%                                print-packets-json-log-and-plot.py's
%%                                matplotlib window (add --log FILE to keep them)
%%
%% lora_mesh merges the copies its bridges hear: one packet, with
%% "bridges" saying which bridges heard it.
%%
-module(mte_packets).

-export([run/1]).

-define(COUNT_EVERY_MS, 10000).

run(Opts) ->
    C = mtc:connect(Opts),
    %% our own radios' packets (local stats) are not logged, as in Python
    Mine = [maps:get(<<"my_id">>, B) || B <- mtc:bridges(C, #{all => true})],
    ok = mtc:subscribe(C, packets),
    Mode = case Opts of
               #{counts := true} -> counts;
               #{raw := true} -> raw;
               #{json := true} -> json;
               #{log := _} -> json;
               _ -> parsed
           end,
    Log = maps:get(log, Opts, undefined),
    loop(C, Mode, Log, Mine, {#{}, #{}}, mtc:deadline(?COUNT_EVERY_MS)).

loop(C, Mode, Log, Mine, Counts, Next) ->
    Timeout = case Mode of
                  counts -> mtc:left(Next);
                  _ -> infinity
              end,
    case mtc:next(C, Timeout) of
        {packet, P} ->
            case Log =/= undefined andalso not lists:member(maps:get(<<"from_id">>, P), Mine) of
                true -> append(Log, P);
                false -> ok
            end,
            show(Mode, P),
            loop(C, Mode, Log, Mine, count(P, Counts), Next);
        timeout ->
            chart(Counts),
            loop(C, Mode, Log, Mine, Counts, mtc:deadline(?COUNT_EVERY_MS));
        _Other ->
            loop(C, Mode, Log, Mine, Counts, Next)
    end.

show(parsed, P) -> print_packet(P);
show(raw, P) -> io:format("~p~n~n", [P]);
show(json, P) -> io:format("~ts~n~n", [mtc:json(P)]);
show(counts, _P) -> ok.

%%--------------------------------------------------------------------
%% --log: a JSON array in a file, one more packet each time
%%--------------------------------------------------------------------

append(File, P) ->
    Old = case file:read_file(File) of
              {ok, Bin} ->
                  try json:decode(Bin) of
                      List when is_list(List) -> List;
                      _ -> []
                  catch
                      _:_ -> []
                  end;
              {error, _} ->
                  []
          end,
    ok = file:write_file(File, json:format(Old ++ [P])).

%%--------------------------------------------------------------------
%% --counts
%%--------------------------------------------------------------------

count(P, {Ports, Senders}) ->
    Port = mtc:get(P, [<<"decoded">>, <<"portnum">>], <<"Unknown">>),
    From = maps:get(<<"from_id">>, P, <<"?">>),
    {maps:update_with(Port, fun(N) -> N + 1 end, 1, Ports),
     maps:update_with(From, fun(N) -> N + 1 end, 1, Senders)}.

chart({Ports, Senders}) ->
    io:format("~nPortnums Frequency~n"),
    bars(Ports),
    io:format("From Numbers Frequency~n"),
    bars(Senders).

bars(Counts) ->
    Sorted = lists:reverse(lists:keysort(2, maps:to_list(Counts))),
    [io:format("  ~-20ts ~s ~p~n", [Key, lists:duplicate(N, $#), N]) || {Key, N} <- Sorted],
    ok.

%%--------------------------------------------------------------------
%% print-packets.py
%%--------------------------------------------------------------------

print_packet(P) ->
    io:format("Received packet:~n"),
    io:format("  From: ~p / ~ts~n", [maps:get(<<"from">>, P, 0), maps:get(<<"from_id">>, P)]),
    io:format("  To: ~p / ~ts~n", [maps:get(<<"to">>, P, 0), maps:get(<<"to_id">>, P)]),
    field("  Channel", P, <<"channel">>),
    field("  SNR", P, <<"rx_snr">>),
    field("  RSSI", P, <<"rx_rssi">>),
    field("  Hop Limit", P, <<"hop_limit">>),
    field("  Hop Start", P, <<"hop_start">>),
    field("  Priority", P, <<"priority">>),
    field("  via MQTT", P, <<"via_mqtt">>),
    io:format("  Heard by: ~ts~n", [lists:join(", ", maps:get(<<"bridges">>, P, []))]),
    case P of
        #{<<"decoded">> := Data} ->
            Port = maps:get(<<"portnum">>, Data, <<"UNKNOWN_APP">>),
            io:format("  Port Number: ~ts~n", [Port]),
            print_data(Port, Data);
        _ ->
            io:format("  No 'decoded' key found in the packet. Our node doesn't have the encryption key!~n")
    end,
    io:format("~n").

print_data(<<"NODEINFO_APP">>, #{<<"user">> := User}) ->
    io:format("  Node Information:~n"),
    io:format("    ID: ~ts~n", [maps:get(<<"id">>, User, <<"N/A">>)]),
    io:format("    Long Name: ~ts~n", [maps:get(<<"long_name">>, User, <<"N/A">>)]),
    io:format("    Short Name: ~ts~n", [maps:get(<<"short_name">>, User, <<"N/A">>)]),
    io:format("    MAC Address: ~ts~n", [maps:get(<<"macaddr">>, User, <<"N/A">>)]),
    io:format("    Hardware Model: ~ts~n", [maps:get(<<"hw_model">>, User, <<"UNSET">>)]),
    field("    Role", User, <<"role">>);
print_data(<<"POSITION_APP">>, #{<<"position">> := Pos}) ->
    io:format("  Position:~n"),
    io:format("    Latitude: ~ts~n", [mtc:show(maps:get(<<"latitude">>, Pos, <<"N/A">>))]),
    io:format("    Longitude: ~ts~n", [mtc:show(maps:get(<<"longitude">>, Pos, <<"N/A">>))]),
    io:format("    Altitude: ~ts~n", [mtc:show(maps:get(<<"altitude">>, Pos, <<"N/A">>))]),
    field("    PDOP", Pos, <<"PDOP">>),
    field("    Ground Track", Pos, <<"ground_track">>),
    field("    Satellites in View", Pos, <<"sats_in_view">>);
print_data(<<"TEXT_MESSAGE_APP">>, #{<<"text">> := Text}) ->
    io:format("  Text Message:~n"),
    io:format("    Text: ~ts~n", [Text]);
print_data(<<"TELEMETRY_APP">>, #{<<"telemetry">> := T}) ->
    io:format("  Telemetry:~n"),
    io:format("    Time: ~ts~n", [mtc:show(maps:get(<<"time">>, T, <<"N/A">>))]),
    metrics("    Device Metrics:", T, <<"device_metrics">>,
            [{"Battery Level", <<"battery_level">>}, {"Voltage", <<"voltage">>},
             {"Channel Utilization", <<"channel_utilization">>},
             {"Air Utilization Tx", <<"air_util_tx">>}, {"Uptime Seconds", <<"uptime_seconds">>}]),
    metrics("    Power Metrics:", T, <<"power_metrics">>,
            [{"CH1 Voltage", <<"ch1_voltage">>}, {"CH1 Current", <<"ch1_current">>},
             {"CH2 Voltage", <<"ch2_voltage">>}, {"CH2 Current", <<"ch2_current">>}]),
    metrics("    Environment Metrics:", T, <<"environment_metrics">>,
            [{"Temperature", <<"temperature">>}, {"Relative Humidity", <<"relative_humidity">>},
             {"Barometric Pressure", <<"barometric_pressure">>}]),
    metrics("    Local Stats:", T, <<"local_stats">>,
            [{"Packets Tx", <<"num_packets_tx">>}, {"Packets Rx", <<"num_packets_rx">>},
             {"Online Nodes", <<"num_online_nodes">>},
             {"Channel Utilization", <<"channel_utilization">>}]);
print_data(<<"NEIGHBORINFO_APP">>, #{<<"neighborinfo">> := Info}) ->
    io:format("  Neighbor Information:~n"),
    io:format("    Node ID: ~p~n", [maps:get(<<"node_id">>, Info, 0)]),
    io:format("    Last Sent By ID: ~p~n", [maps:get(<<"last_sent_by_id">>, Info, 0)]),
    io:format("    Node Broadcast Interval (secs): ~p~n",
              [maps:get(<<"node_broadcast_interval_secs">>, Info, 0)]),
    io:format("    Neighbors:~n"),
    [io:format("      Neighbor ID: ~p~n        SNR: ~ts~n",
               [maps:get(<<"node_id">>, N, 0), mtc:show(maps:get(<<"snr">>, N, 0.0))])
     || N <- maps:get(<<"neighbors">>, Info, [])],
    ok;
print_data(<<"RANGE_TEST_APP">>, #{<<"text">> := Text}) ->
    io:format("  Range Test Information:~n"),
    io:format("    Payload: ~ts~n", [Text]);
print_data(<<"STORE_FORWARD_APP">>, #{<<"store_forward">> := SF}) ->
    io:format("  Store Forward Information:~n"),
    field("    Statistics", SF, <<"stats">>),
    field("    History", SF, <<"history">>),
    field("    Heartbeat", SF, <<"heartbeat">>);
print_data(<<"PAXCOUNTER_APP">>, #{<<"paxcounter">> := Pax}) ->
    io:format("  Paxcounter Information:~n"),
    io:format("    Wifi: ~p~n", [maps:get(<<"wifi">>, Pax, 0)]),
    io:format("    BLE: ~p~n", [maps:get(<<"ble">>, Pax, 0)]),
    io:format("    Uptime: ~p~n", [maps:get(<<"uptime">>, Pax, 0)]);
print_data(Port, _Data) ->
    io:format("  Decoded packet does not contain data we are looking for: ~ts~n", [Port]).

metrics(Title, Telemetry, Key, Fields) ->
    case Telemetry of
        #{Key := M} ->
            io:format("~s~n", [Title]),
            [io:format("      ~s: ~ts~n", [Label, mtc:show(maps:get(F, M, <<"N/A">>))])
             || {Label, F} <- Fields],
            ok;
        _ ->
            ok
    end.

field(Label, Map, Key) ->
    case Map of
        #{Key := V} -> io:format("~s: ~ts~n", [Label, mtc:show(V)]);
        _ -> ok
    end.
