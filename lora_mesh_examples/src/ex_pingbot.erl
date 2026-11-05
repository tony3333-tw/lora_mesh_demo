%%
%% Answer "ping" on a channel, like serial_pingbot.py:
%%
%%   Bob on #0: ping?
%%   me  on #0: @[Bob] Pong 🏓(Ridge, heard by field)
%%
%% serial_pingbot.py reads the repeaters on the path from the radio's
%% RX log. lora_mesh 0.3.2 does that for every bridge and publishes the
%% path with the repeaters' names (lmc:path_info/1); a Meshtastic ping
%% shows its last relay.
%%
%%   lme pingbot                 channel 0
%%   lme pingbot --channel 1
%%
-module(ex_pingbot).

-export([run/1]).

run(Opts) ->
    Channel = maps:get(channel, Opts, 0),
    Client = lmc:connect(Opts),
    Names = lmc:names(lmc:nodes(Client, 500)),
    ok = lmc:subscribe(Client, rx),
    io:format("Listening for 'ping' on channel ~p (Ctrl-C to stop)...~n", [Channel]),
    loop(Client, Channel, Names).

loop(Client, Channel, Names) ->
    case lmc:next(Client, infinity) of
        {rx, Rx} ->
            handle(Client, Channel, Names, Rx),
            loop(Client, Channel, Names);
        {node, Node} ->
            loop(Client, Channel, lmc:add_name(Names, Node))
    end.

handle(Client, Channel, Names, Rx) ->
    Text = maps:get(<<"text">>, Rx),
    Sender = lmc:sender(Rx, Names),
    io:format("~ts~n", [lmc:describe(Rx, Names)]),
    case lmc:is_channel(Rx)
        andalso maps:get(<<"channel">>, Rx) =:= Channel
        andalso is_ping(Text) of
        true ->
            Reply = unicode:characters_to_binary(
                      ["@[", Sender, "] Pong \x{1F3D3}", lmc:path_info(Rx)]),
            io:format("Detected Ping. Replying on channel ~p with: ~ts~n", [Channel, Reply]),
            %% answer on the mesh the ping came from
            ok = lmc:send(Client, #{channel => Channel,
                                    protocol => maps:get(<<"protocol">>, Rx),
                                    text => Reply});
        false ->
            ok
    end.

%% "ping", "Ping?", "PING!" ...; not our own "@[Bob] Pong" echoed back
is_ping(Text) ->
    Lower = string:lowercase(Text),
    string:find(Lower, "ping") =/= nomatch
        andalso string:prefix(Text, "@[") =:= nomatch.
