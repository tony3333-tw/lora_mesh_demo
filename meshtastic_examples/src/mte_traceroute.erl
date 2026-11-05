%%
%% Trace the route to a node, like send-traceroute-simple.py and
%% print-traceroute.py: every router on the way adds itself (and the SNR
%% it heard the request at), and the answer comes back the same way.
%%
%%   mte traceroute -d "Hill top"
%%   mte traceroute -d '!60c0ffee' --hop-limit 5
%%
%% The output is the Python library's (onResponseTraceRoute):
%%
%%   Route traced towards destination:
%%   Pi Gateway --> Tower (9.5dB) --> Hill top (-3.5dB)
%%   Route traced back to us:
%%   Hill top --> Tower (-3.0dB) --> Pi Gateway (10.25dB)
%%
%% Radios limit traceroutes (about one per 30 s): a second one too soon
%% gets no answer.
%%
-module(mte_traceroute).

-export([run/1]).

-define(UNKNOWN_SNR, -128).

run(Opts) ->
    C = mtc:connect(Opts),
    Dest = mtc:dest(C, Opts),
    HopLimit = maps:get(hop_limit, Opts, 3),
    io:format("Sending traceroute request to ~ts (hop limit ~p), this can take a while...~n",
              [mtc:name(C, Dest), HopLimit]),
    Id = mtc:send_traceroute(C, Dest, HopLimit),
    case mtc:reply(C, Id, 'TRACEROUTE_APP', 30000 * (HopLimit + 1)) of
        {ok, P} -> print_route(C, P);
        {error, Reason} -> io:format("Traceroute failed: ~s~n", [Reason]);
        timeout -> io:format("Timed out waiting for traceroute~n");
        closed -> io:format("the radio closed the connection~n")
    end,
    mtc:close(C).

%% P comes from the destination (from) to us (to)
print_route(C, #{from := From, to := To} = P) ->
    Route = mtc:get(P, [decoded, traceroute], #{}),
    Towards = maps:get(route, Route, []),
    SnrTowards = maps:get(snr_towards, Route, []),
    io:format("Route traced towards destination:~n"),
    io:format("~ts~n", [route_line(C, [To | Towards] ++ [From], SnrTowards)]),
    Back = maps:get(route_back, Route, []),
    SnrBack = maps:get(snr_back, Route, []),
    %% only valid with hop_start and one SNR per hop plus the last one
    case maps:is_key(hop_start, P) andalso length(SnrBack) =:= length(Back) + 1 of
        true ->
            io:format("Route traced back to us:~n"),
            io:format("~ts~n", [route_line(C, [From | Back] ++ [To], SnrBack)]);
        false ->
            ok
    end.

%% [First | Hops]: each hop with the SNR it was heard at (dB * 4)
route_line(C, [First | Hops], Snrs) ->
    Valid = length(Snrs) =:= length(Hops),
    Steps = [[" --> ", mtc:name(C, Node), " (", snr(Valid, Snrs, I), "dB)"]
             || {I, Node} <- lists:enumerate(Hops)],
    [mtc:name(C, First) | Steps].

snr(true, Snrs, I) ->
    case lists:nth(I, Snrs) of
        ?UNKNOWN_SNR -> "?";
        Snr -> float_to_list(Snr / 4, [short])
    end;
snr(false, _Snrs, _I) ->
    "?".
