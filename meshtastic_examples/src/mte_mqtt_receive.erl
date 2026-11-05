%%
%% Print everything lora_mesh publishes, like MQTT/receive-mqtt-packets.py
%% prints everything on a Meshtastic MQTT topic. Plain emqtt and json,
%% without mtc: what any MQTT client sees of lora_mesh.
%%
%%   mte mqtt-receive                          mesh/rx/# and mesh/node/#
%%   mte mqtt-receive --topic 'mesh/rx/#'
%%   mte mqtt-receive --host 192.168.1.10 --prefix lab
%%
%% receive-mqtt-packets.py gets encrypted protobuf from a public broker
%% and decrypts it with the channel key. lora_mesh publishes JSON to
%% your own broker: the radios have already decrypted it.
%%
-module(mte_mqtt_receive).

-export([run/1]).
-export([connect/1]).
-export([print/2]).

run(Opts) ->
    Prefix = maps:get(prefix, Opts, "mesh"),
    Topics = maps:get(topics, Opts, [Prefix ++ "/rx/#", Prefix ++ "/node/#"]),
    Conn = connect(Opts),
    io:format("Connected to MQTT broker!~n"),
    [begin
         {ok, _, _} = emqtt:subscribe(Conn, unicode:characters_to_binary(Topic), 0),
         io:format("Subscribed to topic: ~ts~n", [Topic])
     end
     || Topic <- Topics],
    loop().

loop() ->
    receive
        {publish, #{topic := Topic, payload := Payload, retain := Retain}} ->
            print(Topic, Payload, Retain),
            loop();
        {disconnected, ReasonCode, _Props} ->
            io:format("disconnected from the broker (~p)~n", [ReasonCode])
    end.

%% the broker lora_mesh uses: --host (localhost) --port (1883)
%% --username --password. Raises error({mqtt_connect, Reason}).
connect(Opts) ->
    {ok, _} = application:ensure_all_started(emqtt),
    Login = case Opts of
                #{username := U, password := P} ->
                    [{username, unicode:characters_to_binary(U)},
                     {password, unicode:characters_to_binary(P)}];
                _ ->
                    []
            end,
    {ok, Conn} = emqtt:start_link([{host, maps:get(host, Opts, "localhost")},
                                   {port, maps:get(port, Opts, 1883)},
                                   {clean_start, true}
                                   | Login]),
    unlink(Conn),
    case emqtt:connect(Conn) of
        {ok, _} ->
            link(Conn),
            Conn;
        {error, Reason} ->
            catch emqtt:stop(Conn),
            error({mqtt_connect, Reason})
    end.

%% one message: the topic, then its JSON indented
print(Topic, Payload) ->
    print(Topic, Payload, false).

print(Topic, <<>>, _Retain) ->
    io:format("~ts (removed)~n~n", [Topic]);
print(Topic, Payload, Retain) ->
    Note = case Retain of
               true -> " (retained)";
               false -> ""
           end,
    Body = try json:format(json:decode(Payload))
           catch _:_ -> Payload
           end,
    io:format("~ts~s~n~ts~n~n", [Topic, Note, Body]).
