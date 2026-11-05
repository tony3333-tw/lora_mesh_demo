%%
%% Show the radio's channel URL, or set its channels from one, like
%% set-URL.py (node.getURL / node.setURL). A URL holds the channels
%% (name, key, ...) and the LoRa settings, as the phone app's QR code.
%%
%%   mte set-url                       print the current URL
%%   mte set-url --url 'https://meshtastic.org/e/#CgcSAQE6AggNEgwIATgBQANIAVAeaAE'
%%
%% Setting changes the radio's channels and LoRa settings; the radio may
%% restart. Then the example connects again and prints the new URL.
%%
-module(mte_set_url).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    io:format("~s~n", [url(C)]),
    case maps:find(url, Opts) of
        {ok, Url} ->
            Result = set_url(C, Url),
            mtc:close(C),
            case Result of
                ok ->
                    timer:sleep(4000),
                    C2 = reconnect(Opts, 5),
                    io:format("~s~n", [url(C2)]),
                    mtc:close(C2);
                error ->
                    ok
            end;
        error ->
            mtc:close(C)
    end.

%% node.getURL(): the primary and secondary channels' settings and the
%% LoRa config, as a ChannelSet in URL-safe base64 without padding
url(C) ->
    Settings = [S || #{role := Role, settings := S} <- mtc:channels(C),
                     Role =:= 'PRIMARY' orelse Role =:= 'SECONDARY'],
    Set = #{settings => Settings, lora_config => mtc:config(C, lora)},
    B64 = base64:encode(mtc:encode(Set, channel_set), #{mode => urlsafe, padding => false}),
    ["https://meshtastic.org/e/#", B64].

%% node.setURL(url): channel 0 primary, the others secondary, then the
%% LoRa config. -> ok | error
set_url(C, Url) ->
    case string:split(Url, "/#") of
        [_, B64] ->
            Set = mtc:decode(base64:decode(B64, #{mode => urlsafe, padding => false}), channel_set),
            case maps:get(settings, Set, []) of
                [] ->
                    io:format("Warning: There were no settings.~n"),
                    error;
                Settings ->
                    [admin_ok(C, #{set_channel => #{index => I - 1,
                                                    role => role(I - 1),
                                                    settings => S}})
                     || {I, S} <- lists:enumerate(Settings)],
                    admin_ok(C, #{set_config => #{lora => maps:get(lora_config, Set, #{})}}),
                    io:format("Set ~p channel(s) and the LoRa config~n", [length(Settings)])
            end;
        _ ->
            io:format("Warning: Invalid URL '~ts'~n", [Url]),
            error
    end.

role(0) -> 'PRIMARY';
role(_) -> 'SECONDARY'.

admin_ok(C, Admin) ->
    Id = mtc:admin(C, Admin),
    ok = mtc:ack(C, Id, 10000).

%% the radio may be restarting
reconnect(Opts, Tries) ->
    try
        mtc:connect(Opts)
    catch
        error:{radio_connect, _} when Tries > 1 ->
            timer:sleep(3000),
            reconnect(Opts, Tries - 1)
    end.
