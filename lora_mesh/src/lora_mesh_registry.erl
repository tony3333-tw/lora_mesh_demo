%%
%% What we know about every node in the mesh: one #mesh_node{} per node
%% number, in an ETS table.
%%
%% Plays the role of lorawan-server's device/node tables in lorawan_db,
%% kept in ETS rather than Mnesia: it is rebuilt from the mesh after a
%% restart (each bridge's node sends its node database on connect).
%%
%% Reads go straight to ETS; writes are serialised through this process.
%% Every change is sent to the notify process as {node, #mesh_node{}}.
%%
-module(lora_mesh_registry).
-behaviour(gen_server).

-export([start_link/1]).
-export([update/2]).
-export([lookup/1]).
-export([all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("lora_mesh.hrl").

-define(TABLE, lora_mesh_nodes).

-record(state, {
    notify   :: pid() | atom() | undefined}).

%%====================================================================
%% API
%%====================================================================

%% Opts: #{notify => Pid | Name | undefined}
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% Apply Fun to the node's record (a fresh one if the node is new).
-spec update(non_neg_integer(), fun((#mesh_node{}) -> #mesh_node{})) -> ok.
update(Num, Fun) ->
    gen_server:cast(?MODULE, {update, Num, Fun}).

-spec lookup(non_neg_integer()) -> {ok, #mesh_node{}} | not_found.
lookup(Num) ->
    case ets:lookup(?TABLE, Num) of
        [Node] -> {ok, Node};
        [] -> not_found
    end.

-spec all() -> [#mesh_node{}].
all() ->
    ets:tab2list(?TABLE).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    ?TABLE = ets:new(?TABLE, [named_table,
                              protected,
                              set,
                              {keypos, #mesh_node.num},
                              {read_concurrency, true}]),
    {ok, #state{notify = maps:get(notify, Opts, lora_mesh_connector_mqtt)}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknownmsg}, State}.

handle_cast({update, Num, Fun}, #state{notify = Notify} = State) ->
    Old = case ets:lookup(?TABLE, Num) of
              [Node] -> Node;
              [] -> new_node(Num)
          end,
    try Fun(Old) of
        Old ->
            ok;
        #mesh_node{num = Num} = New ->
            true = ets:insert(?TABLE, New),
            notify(Notify, New)
    catch
        Class:Reason ->
            logger:warning("lora_mesh_registry: update of ~s failed ~p:~p",
                           [Old#mesh_node.id, Class, Reason])
    end,
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Unknown, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

%% A fresh record; MeshCore numbers have bit 48 set (lora_mesh_meshcore).
new_node(Num) ->
    case lora_mesh_meshcore:is_node_num(Num) of
        true ->
            #mesh_node{num = Num,
                       id = lora_mesh_meshcore:node_id(Num),
                       protocol = meshcore};
        false ->
            #mesh_node{num = Num,
                       id = lora_mesh_node:node_id(Num)}
    end.

notify(undefined, _Node) ->
    ok;
notify(Notify, Node) ->
    %% a name that is not registered (yet) must not crash the registry
    catch Notify ! {node, Node},
    ok.
