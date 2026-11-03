-module(lora_mesh_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-include("lora_mesh.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% role full   (default): pg scope, registry, router, MQTT connector, bridges
%% role bridge          : pg scope and bridges only; they find the router
%%                        on another Erlang node through pg
%%
%% Order matters: the router side starts before the bridges so the first
%% packets have somewhere to go.
init([]) ->
    Role = application:get_env(lora_mesh, role, full),
    Bridges = application:get_env(lora_mesh, bridges, []),
    SupFlags = #{strategy => one_for_one,
                 intensity => 5,
                 period => 30},
    Scope = #{id => pg_scope,
              start => {pg, start_link, [?PG_SCOPE]}},
    {ok, {SupFlags, [Scope | server(Role) ++ [bridge(B) || B <- Bridges]]}}.

server(bridge) ->
    [];
server(full) ->
    {ok, MqttOpts} = application:get_env(lora_mesh, mqtt),
    DedupMs = application:get_env(lora_mesh, dedup_ms, 200),
    [#{id => lora_mesh_registry,
       start => {lora_mesh_registry, start_link,
                 [#{notify => lora_mesh_connector_mqtt}]}},
     #{id => lora_mesh_router,
       start => {lora_mesh_router, start_link,
                 [#{dedup_ms => DedupMs,
                    subscriber => lora_mesh_connector_mqtt}]}},
     #{id => lora_mesh_connector_mqtt,
       start => {lora_mesh_connector_mqtt, start_link, [MqttOpts]}}].

%% #{id => home, host => ...}                         Meshtastic (default)
%% #{id => field, type => meshcore, transport => serial, device => ...}
%% #{id => shed, type => meshcore, transport => tcp, host => ...}
bridge(#{id := Id} = Opts) ->
    Module = case maps:get(type, Opts, meshtastic) of
                 meshtastic -> lora_mesh_node;
                 meshcore -> lora_mesh_meshcore
             end,
    #{id => {bridge, Id},
      start => {Module, start_link, [Opts]}}.
