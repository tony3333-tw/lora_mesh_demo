%%
%% Keeps this Erlang node connected to the other lora_mesh machines.
%%
%% Setting (etc/lora_mesh.config or sys.config):
%%   {connect, ['lora_mesh@rpi4-a']}.
%%
%% Every ?RETRY_MS it connects to each listed node that is not connected
%% yet; it logs when a node comes up or goes down. Once connected, pg
%% shares its groups, so bridges on one machine find the router on the
%% other (role bridge), and sends from MQTT reach bridges on any machine.
%%
%% Needs a distributed node (-sname/-name in vm.args) and the same cookie
%% on every machine. With no `connect' setting it does nothing.
%%
-module(lora_mesh_cluster).
-behaviour(gen_server).

-export([start_link/1]).
-export([status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RETRY_MS, 5000).

-record(state, {
    nodes   :: [node()]}).

%%====================================================================
%% API
%%====================================================================

start_link(Nodes) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Nodes, []).

%% [{Node, up | down}] for the configured nodes
status() ->
    gen_server:call(?MODULE, status).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Nodes) ->
    case node() of
        nonode@nohost when Nodes =/= [] ->
            logger:warning("lora_mesh_cluster: this node is not distributed "
                           "(no -sname/-name), cannot connect to ~p", [Nodes]);
        _ ->
            ok
    end,
    ok = net_kernel:monitor_nodes(true),
    self() ! connect,
    {ok, #state{nodes = [N || N <- Nodes, N =/= node()]}}.

handle_call(status, _From, #state{nodes = Nodes} = State) ->
    Up = nodes(),
    {reply, [{N, case lists:member(N, Up) of true -> up; false -> down end} || N <- Nodes],
     State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect, #state{nodes = Nodes} = State) ->
    case node() of
        nonode@nohost ->
            ok;
        _ ->
            Up = nodes(),
            [net_kernel:connect_node(N) || N <- Nodes, not lists:member(N, Up)]
    end,
    erlang:send_after(?RETRY_MS, self(), connect),
    {noreply, State};

handle_info({nodeup, Node}, State) ->
    logger:notice("lora_mesh_cluster: ~p connected", [Node]),
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    logger:warning("lora_mesh_cluster: ~p disconnected", [Node]),
    {noreply, State};

handle_info(_Other, State) ->
    {noreply, State}.
