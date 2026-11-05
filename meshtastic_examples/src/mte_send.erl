%%
%% Broadcast one packet of a kind, like the send-*.py examples:
%%
%%   mte send --what position          send-position.py (--lat 45 --lon -120 --alt 100)
%%   mte send --what nodeinfo          send-nodeinfo.py (our own User)
%%   mte send --what device            send-device-metrics.py (battery 69, 4.1 V, ...)
%%   mte send --what environment       send-environment-metrics.py (temperature, humidity)
%%   mte send --what telemetry         send-telemetry.py (our device metrics, as the
%%                                     library's sendTelemetry fills them in)
%%   mte send --what waypoint          send-waypoint.py (a waypoint for 2 minutes)
%%
%% -c N sends on channel N, -d NODE to one node instead of everyone.
%%
-module(mte_send).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    To = case maps:is_key(dest, Opts) of
             true -> mtc:dest(C, Opts);
             false -> 16#FFFFFFFF
         end,
    Send = #{to => To, channel => maps:get(channel, Opts, 0)},
    What = maps:get(what, Opts, "position"),
    Id = send(What, C, Opts, Send),
    io:format("Sent ~s to ~ts (packet id ~p)~n", [What, mtc:name(C, To), Id]),
    mtc:close(C).

send("position", C, Opts, Send) ->
    mtc:send_position(C, maps:merge(Send, #{lat => maps:get(lat, Opts, 45),
                                            lon => maps:get(lon, Opts, -120),
                                            alt => maps:get(alt, Opts, 100)}));
send("nodeinfo", C, _Opts, Send) ->
    {ok, Me} = mtc:node(C, mtc:my_num(C)),
    mtc:send_data(C, 'NODEINFO_APP', {user, maps:get(user, Me)}, Send);
send("device", C, _Opts, Send) ->
    Telemetry = #{time => erlang:system_time(second),
                  device_metrics => #{battery_level => 69,
                                      voltage => 4.1,
                                      channel_utilization => 42.0,
                                      air_util_tx => 1.0}},
    mtc:send_data(C, 'TELEMETRY_APP', {telemetry, Telemetry}, Send);
send("environment", C, _Opts, Send) ->
    Telemetry = #{time => erlang:system_time(second),
                  environment_metrics => #{temperature => 25.2,
                                           relative_humidity => 69.0}},
    mtc:send_data(C, 'TELEMETRY_APP', {telemetry, Telemetry}, Send);
send("telemetry", C, _Opts, Send) ->
    mtc:send_telemetry(C, device_metrics, Send);
send("waypoint", C, _Opts, Send) ->
    Waypoint = #{id => rand:uniform(16#FFFFFFFE),
                 latitude_i => 454877655,
                 longitude_i => -1215699769,
                 expire => erlang:system_time(second) + 120,
                 locked_to => mtc:my_num(C),
                 name => <<"Point 1">>,
                 description => <<"Waypoint 1 with emoji 🔥"/utf8>>,
                 icon => 16#1F525},                          % the 🔥 emoji
    mtc:send_data(C, 'WAYPOINT_APP', {waypoint, Waypoint}, Send).
