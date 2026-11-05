%%
%% Stay connected to a radio, like tcp_watchdog.py: every --every
%% seconds (10) ask the radio for its firmware version; when that fails,
%% connect again (after 3 s, and again until it works). Text packets are
%% printed meanwhile.
%%
%%   mte watchdog --host 192.168.1.42
%%
-module(mte_watchdog).

-export([run/1]).

-define(RETRY_MS, 3000).

run(Opts) ->
    Every = maps:get(every, Opts, 10) * 1000,
    loop(connect(Opts), Opts, Every, mtc:deadline(Every)).

connect(Opts) ->
    try mtc:connect(Opts) of
        C ->
            io:format("Interface initialized.~n"),
            C
    catch
        error:{radio_connect, Reason} ->
            io:format("Failed to initialize interface: ~p~n", [Reason]),
            undefined
    end.

%% no connection: try again after a while
loop(undefined, Opts, Every, _Check) ->
    io:format("Retrying connection to the interface...~n"),
    timer:sleep(?RETRY_MS),
    C = connect(Opts),
    loop(C, Opts, Every, mtc:deadline(Every));
loop(C, Opts, Every, Check) ->
    case mtc:next(C, mtc:left(Check)) of
        {packet, #{decoded := #{portnum := 'TEXT_MESSAGE_APP'}} = P} ->
            io:format("~p~n", [P]),
            loop(C, Opts, Every, Check);
        {packet, _Other} ->
            loop(C, Opts, Every, Check);
        closed ->
            io:format("Error with the interface: closed, reconnecting~n"),
            loop(undefined, Opts, Every, Check);
        timeout ->
            io:format("Checking interface connection...~n"),
            case firmware(C) of
                {ok, Version} ->
                    io:format("Firmware Version: ~ts~nInterface is connected.~n", [Version]),
                    loop(C, Opts, Every, mtc:deadline(Every));
                {error, Reason} ->
                    io:format("Error with the interface (~p), reconnecting~n", [Reason]),
                    mtc:close(C),
                    loop(undefined, Opts, Every, Check)
            end
    end.

%% node.getMetadata(): an admin request to our own radio
firmware(C) ->
    try mtc:admin(C, #{get_device_metadata_request => true}) of
        Id ->
            case mtc:reply(C, Id, 'ADMIN_APP', 5000) of
                {ok, P} ->
                    {ok, mtc:get(P, [decoded, admin, get_device_metadata_response, firmware_version],
                                 <<"?">>)};
                Other ->
                    {error, Other}
            end
    catch
        error:Reason -> {error, Reason}
    end.
