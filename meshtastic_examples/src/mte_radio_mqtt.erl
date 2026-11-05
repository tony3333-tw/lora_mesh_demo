%%
%% Publish what the radio receives to an MQTT broker as JSON, like
%% MQTT/serial-mqtt.py: for radios without WiFi or a network of their
%% own, e.g. a board on a Raspberry Pi running Mosquitto.
%%
%%   mte radio-mqtt                                    broker localhost
%%   mte radio-mqtt --broker 192.168.1.10 --root msh/sMQTT/2/json/LongFast/
%%
%% Topic: <root>!deadbeef, root msh/sMQTT/2/json/LongFast/ (as in Python).
%% Unlike serial-mqtt.py the broker is localhost unless --broker is
%% given. (lora_mesh does this job too, with its own JSON: mesh/rx/...)
%%
-module(mte_radio_mqtt).

-export([run/1]).

-define(VIRTUAL_NODE, "!deadbeef").

run(Opts) ->
    C = mtc:connect(Opts),
    Conn = mtq:connect(Opts#{broker => maps:get(broker, Opts, "localhost")}),
    Topic = mtq:root(Opts, "msh/sMQTT/2/json/LongFast/") ++ ?VIRTUAL_NODE,
    io:format("Publishing to ~s~n", [Topic]),
    loop(C, Conn, Topic).

loop(C, Conn, Topic) ->
    case mtc:next(C, infinity) of
        {packet, #{decoded := Data} = P} ->
            Json = json:format(message(P, Data)),
            io:format("~ts~n~n", [Json]),
            mtq:publish(Conn, Topic, iolist_to_binary(Json)),
            loop(C, Conn, Topic);
        {packet, _Encrypted} ->
            loop(C, Conn, Topic);
        closed ->
            io:format("the radio closed the connection~n")
    end.

%% The JSON message of serial-mqtt.py
message(P, Data) ->
    {Type, Payload} = payload(maps:get(portnum, Data, 'UNKNOWN_APP'), Data),
    Message = #{channel => maps:get(channel, P, 0),
                from => maps:get(from, P, 0),
                id => maps:get(id, P, 0),
                rssi => maps:get(rx_rssi, P, undefined),
                sender => <<?VIRTUAL_NODE>>,
                snr => maps:get(rx_snr, P, undefined),
                timestamp => maps:get(rx_time, P, undefined),
                to => maps:get(to, P, undefined),
                type => Type,
                payload => without_undefined(Payload)},
    without_undefined(Message).

payload('NODEINFO_APP', #{user := U}) ->
    {nodeinfo, #{hardware => maps:get(hw_model, U, 'UNSET'),
                 id => maps:get(id, U, undefined),
                 longname => maps:get(long_name, U, undefined),
                 shortname => maps:get(short_name, U, undefined)}};
payload('POSITION_APP', #{position := Pos}) ->
    {position, #{'PDOP' => maps:get('PDOP', Pos, undefined),
                 altitude => maps:get(altitude, Pos, undefined),
                 groundSpeed => maps:get(ground_speed, Pos, undefined),
                 latitude_i => maps:get(latitude_i, Pos, undefined),
                 longitude_i => maps:get(longitude_i, Pos, undefined),
                 precision_bits => maps:get(precision_bits, Pos, undefined),
                 satsInView => maps:get(sats_in_view, Pos, undefined),
                 time => maps:get(time, Pos, undefined)}};
payload('TEXT_MESSAGE_APP', #{text := Text}) ->
    {textMessage, #{text => Text}};
payload('TELEMETRY_APP', #{telemetry := T}) ->
    D = maps:get(device_metrics, T, #{}),
    W = maps:get(power_metrics, T, #{}),
    E = maps:get(environment_metrics, T, #{}),
    {telemetry,
     maps:from_list(
       [{K, maps:get(F, D)} || {K, F} <- [{air_util_tx, air_util_tx},
                                          {battery_level, battery_level},
                                          {channel_utilization, channel_utilization},
                                          {uptime_seconds, uptime_seconds},
                                          {voltage, voltage}],
                               maps:is_key(F, D)]
       ++ [{K, maps:get(F, W)} || {K, F} <- [{current_ch1, ch1_current},
                                            {current_ch2, ch2_current},
                                            {current_ch3, ch3_current},
                                            {voltage_ch1, ch1_voltage},
                                            {voltage_ch2, ch2_voltage},
                                            {voltage_ch3, ch3_voltage}],
                                 maps:is_key(F, W)]
       ++ [{K, maps:get(K, E)} || K <- [barometric_pressure, current, gas_resistance, iaq,
                                        lux, temperature, voltage, white_lux,
                                        wind_direction, wind_speed],
                                  maps:is_key(K, E)])};
payload(_Other, _Data) ->
    {todo, #{}}.

without_undefined(Map) ->
    maps:filter(fun(_K, V) -> V =/= undefined andalso V =/= <<>> end, Map).
