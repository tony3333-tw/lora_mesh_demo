%%
%% Collects packets from every bridge and deduplicates them.
%%
%% Plays the role of lorawan-server's lorawan_gw_router: several bridges
%% (like several gateways) may hear the same packet. The first copy opens
%% a window of dedup_ms; copies arriving inside it are collected; when it
%% closes, the best copy (highest SNR) goes to lora_mesh_handler together
%% with the list of bridges that heard it.
%%
%% A Meshtastic packet is identified by {From, Id}: the sender picks a
%% random 32-bit id for each packet. Copies arriving after the window
%% closed (kept in `seen' for ?SEEN_MS) only update "heard by" and are not
%% published again.
%%
%% The router joins the pg group ?PG_ROUTER so bridges on other Erlang
%% nodes can find it.
%%
-module(lora_mesh_router).
-behaviour(gen_server).

-export([start_link/1]).
-export([uplink/2]).
-export([node_info/2]).
-export([message/4]).
-export([stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("lora_mesh.hrl").
-include("meshtastic/mesh.hrl").

-define(DEDUP_MS, 200).
-define(SEEN_MS, 60000).
-define(PRUNE_MS, 30000).

-type key() :: term().     % Meshtastic {From, Id}; MeshCore {meshcore, ...}
-type copy() :: {atom(), #mesh_packet{}}                  % {Bridge, Packet}
              | {atom(), {rx, non_neg_integer() | undefined, #mesh_rx{}}}.

-record(state, {
    dedup_ms        :: non_neg_integer(),
    subscriber      :: pid() | atom(),
    pending = #{}   :: #{key() => [copy()]},     % window open
    seen = #{}      :: #{key() => integer()},    % window closed, until (ms)
    stats = #{published => 0,
              duplicates => 0,
              late => 0}  :: map()}).

%%====================================================================
%% API, called by bridges (possibly on other nodes)
%%====================================================================

%% Opts: #{dedup_ms => 200, subscriber => Pid | Name}
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-spec uplink(atom(), #mesh_packet{}) -> ok | {error, no_router}.
uplink(Bridge, #mesh_packet{} = Packet) ->
    to_router({uplink, Bridge, Packet}).

-spec node_info(atom(), #node_info{}) -> ok | {error, no_router}.
node_info(Bridge, #node_info{} = Info) ->
    to_router({node_info, Bridge, Info}).

%% An already-decoded message (MeshCore), deduplicated by Key across
%% bridges like a Meshtastic packet. FromNum is the sender's registry
%% number, or undefined when the sender is not known.
-spec message(atom(), term(), non_neg_integer() | undefined, #mesh_rx{}) ->
          ok | {error, no_router}.
message(Bridge, Key, FromNum, #mesh_rx{} = Rx) ->
    to_router({message, Bridge, Key, FromNum, Rx}).

%% Counters: published, duplicates (inside the window), late (after it).
stats() ->
    gen_server:call(?MODULE, stats).

to_router(Msg) ->
    %% prefer a router on this node, else any in the cluster
    case pg:get_local_members(?PG_SCOPE, ?PG_ROUTER) of
        [Pid | _] ->
            Pid ! Msg,
            ok;
        [] ->
            case pg:get_members(?PG_SCOPE, ?PG_ROUTER) of
                [Pid | _] ->
                    Pid ! Msg,
                    ok;
                [] ->
                    {error, no_router}
            end
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    ok = pg:join(?PG_SCOPE, ?PG_ROUTER, self()),
    erlang:send_after(?PRUNE_MS, self(), prune),
    {ok, #state{dedup_ms = maps:get(dedup_ms, Opts, ?DEDUP_MS),
                subscriber = maps:get(subscriber, Opts, lora_mesh_connector_mqtt)}}.

handle_call(stats, _From, #state{stats = Stats} = State) ->
    {reply, Stats, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

% a packet without id cannot be deduplicated: pass it straight on
handle_info({uplink, Bridge, #mesh_packet{id = 0} = Packet}, State) ->
    {noreply, publish([{Bridge, Packet}], State)};

handle_info({uplink, Bridge, #mesh_packet{from = From, id = Id} = Packet}, State) ->
    {noreply, collect({From, Id}, {Bridge, Packet}, State)};

handle_info({message, Bridge, Key, FromNum, #mesh_rx{} = Rx}, State) ->
    {noreply, collect(Key, {Bridge, {rx, FromNum, Rx}}, State)};

handle_info({flush, Key}, #state{pending = Pending, seen = Seen} = State) ->
    case maps:take(Key, Pending) of
        {Copies, Pending2} ->
            Until = erlang:monotonic_time(millisecond) + ?SEEN_MS,
            State2 = State#state{pending = Pending2,
                                 seen = Seen#{Key => Until}},
            {noreply, publish(Copies, State2)};
        error ->
            {noreply, State}
    end;

handle_info({node_info, Bridge, #node_info{} = Info}, State) ->
    lora_mesh_handler:node_info(Bridge, Info),
    {noreply, State};

handle_info(prune, #state{seen = Seen} = State) ->
    Now = erlang:monotonic_time(millisecond),
    erlang:send_after(?PRUNE_MS, self(), prune),
    {noreply, State#state{seen = maps:filter(fun(_K, Until) -> Until > Now end,
                                             Seen)}};

handle_info(Unknown, State) ->
    logger:warning("lora_mesh_router: unknown message ~p", [Unknown]),
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

%% First copy opens a window; copies inside it are collected; copies
%% after it only update "heard by".
collect(Key, Copy, #state{pending = Pending, seen = Seen, stats = Stats} = State) ->
    case Pending of
        #{Key := Copies} ->
            State#state{pending = Pending#{Key := [Copy | Copies]},
                        stats = bump(duplicates, Stats)};
        #{} ->
            case Seen of
                #{Key := _} ->
                    heard([Copy]),
                    State#state{stats = bump(late, Stats)};
                #{} ->
                    erlang:send_after(State#state.dedup_ms, self(), {flush, Key}),
                    State#state{pending = Pending#{Key => [Copy]}}
            end
    end.

%% Best copy first: highest SNR, then fewest hops taken.
publish(Copies, #state{subscriber = Sub, stats = Stats} = State) ->
    Sorted = lists:sort(fun better/2, Copies),
    case Sorted of
        [{_, #mesh_packet{} = Best} | _] ->
            Heard = [{Bridge, lora_mesh_handler:rxq(P)} || {Bridge, P} <- Sorted],
            lora_mesh_handler:uplink(Best, Heard, Sub);
        [{_, {rx, _FromNum, Best}} | _] ->
            Bridges = [Bridge || {Bridge, _} <- Sorted],
            heard(Sorted),
            catch Sub ! {uplink, Best#mesh_rx{bridges = Bridges}}
    end,
    State#state{stats = bump(published, Stats)}.

heard([{_, #mesh_packet{} = P} | _] = Copies) ->
    lora_mesh_handler:heard(P, [{Bridge, lora_mesh_handler:rxq(C)} || {Bridge, C} <- Copies]);
heard([{_, {rx, undefined, _}} | _]) ->
    ok;
heard([{_, {rx, FromNum, _}} | _] = Copies) ->
    lora_mesh_handler:heard_num(FromNum,
                                [{Bridge, RxQ} || {Bridge, {rx, _, #mesh_rx{rxq = RxQ}}} <- Copies]).

better({_, #mesh_packet{rx_snr = S1} = P1}, {_, #mesh_packet{rx_snr = S2} = P2}) ->
    case S1 == S2 of
        true -> hops(P1) =< hops(P2);
        false -> S1 > S2
    end;
better({_, {rx, _, #mesh_rx{rxq = Q1}}}, {_, {rx, _, #mesh_rx{rxq = Q2}}}) ->
    #mesh_rxq{rx_snr = S1} = Q1,
    #mesh_rxq{rx_snr = S2} = Q2,
    case S1 == S2 of
        true -> rxq_hops(Q1) =< rxq_hops(Q2);
        false -> S1 > S2
    end.

hops(#mesh_packet{hop_start = Start, hop_limit = Limit}) ->
    Start - Limit.

rxq_hops(#mesh_rxq{hop_start = Start, hop_limit = Limit}) ->
    Start - Limit.

bump(Counter, Stats) ->
    maps:update_with(Counter, fun(N) -> N + 1 end, 1, Stats).
