%%
%% Watch the connections, like tcp_watchdog.py. tcp_watchdog.py keeps one
%% TCP link to one radio alive; through lora_mesh it is the radios'
%% links and lora_mesh itself that can go (lora_mesh 0.4:
%% mesh/bridge/<id>/status, mesh/status). lora_mesh reconnects its
%% bridges by itself; this says what is up and what is down.
%%
%%   mte watchdog                  a summary every 10 s, changes at once
%%   mte watchdog --every 60
%%
%% If the broker goes away, it connects again every 3 s, as
%% tcp_watchdog.py does with the radio. Text messages print meanwhile.
%%
-module(mte_watchdog).

-export([run/1]).

-define(RETRY_MS, 3000).

run(Opts) ->
    %% the broker connection is linked to us: survive it going down
    process_flag(trap_exit, true),
    Every = maps:get(every, Opts, 10) * 1000,
    loop(connect(Opts), Opts, Every, mtc:deadline(Every), #{}).

connect(Opts) ->
    try mtc:connect(Opts) of
        C ->
            ok = mtc:subscribe(C, status),
            ok = mtc:subscribe(C, bridges),
            ok = mtc:subscribe(C, rx),
            io:format("Interface initialized.~n"),
            C
    catch
        error:{mqtt_connect, Reason} ->
            io:format("Failed to initialize interface: ~p~n", [Reason]),
            undefined
    end.

%% no broker: try again after a while
loop(undefined, Opts, Every, _Check, _Seen) ->
    io:format("Retrying connection to the interface...~n"),
    timer:sleep(?RETRY_MS),
    C = connect(Opts),
    loop(C, Opts, Every, mtc:deadline(Every), #{});
loop(C, Opts, Every, Check, Seen) ->
    receive
        {publish, Msg} ->
            Seen2 = event(mtc:decode(C, Msg), Seen),
            loop(C, Opts, Every, Check, Seen2);
        {'EXIT', _Conn, Reason} ->
            io:format("Error with the interface (~p), reconnecting~n", [Reason]),
            loop(undefined, Opts, Every, Check, Seen);
        {disconnected, _Code, _Props} ->
            loop(C, Opts, Every, Check, Seen)
    after mtc:left(Check) ->
        io:format("Checking interface connection...~n"),
        summary(Seen),
        loop(C, Opts, Every, mtc:deadline(Every), Seen)
    end.

%% Seen: <<"lora_mesh">> => true | false, Bridge => true | false
event({status, #{<<"online">> := Online}}, Seen) ->
    changed(<<"lora_mesh">>, Online, Seen, "lora_mesh is ~s~n", [up(Online)]);
event({bridge_status, Bridge, #{<<"connected">> := Connected} = S}, Seen) ->
    Why = case S of
              #{<<"reason">> := R} when not Connected -> [" (", R, ")"];
              _ -> ""
          end,
    case maps:get(<<"lora_mesh">>, Seen, undefined) of
        false ->
            %% lora_mesh is down: this is its last status, out of date
            Seen#{Bridge => Connected};
        _ ->
            changed(Bridge, Connected, Seen, "bridge ~ts (~ts) is ~s~ts~n",
                    [Bridge, maps:get(<<"address">>, S, <<"?">>), up_down(Connected), Why])
    end;
event({rx, Rx}, Seen) ->
    io:format("~ts: ~ts~n", [maps:get(<<"from">>, Rx), maps:get(<<"text">>, Rx)]),
    Seen;
event(_Other, Seen) ->
    Seen.

changed(Key, Value, Seen, Format, Args) ->
    case maps:find(Key, Seen) of
        {ok, Value} -> ok;
        _ -> io:format(Format, Args)
    end,
    Seen#{Key => Value}.

%% While lora_mesh is down, its bridges' last status (retained on the
%% broker) is out of date: they show as unknown.
summary(Seen) ->
    Up = maps:get(<<"lora_mesh">>, Seen, undefined),
    case Up of
        true -> io:format("lora_mesh is up.~n");
        false -> io:format("lora_mesh is DOWN.~n");
        undefined -> io:format("lora_mesh has not said (lora_mesh 0.4 needed).~n")
    end,
    Bridges = lists:sort([{K, V} || {K, V} <- maps:to_list(Seen), K =/= <<"lora_mesh">>]),
    [io:format("  ~ts: ~s~n", [B, case Up of
                                       false -> "unknown (lora_mesh is down)";
                                       _ -> up_down(V)
                                   end])
     || {B, V} <- Bridges],
    ok.

up(true) -> "up";
up(false) -> "DOWN".

up_down(true) -> "connected";
up_down(false) -> "DISCONNECTED".
