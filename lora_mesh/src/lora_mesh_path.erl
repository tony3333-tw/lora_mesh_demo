%%
%% Which repeaters and routers a message went through, with names.
%%
%% Radios name the nodes on a path by a short hash, not a full id:
%%
%%   MeshCore    each repeater adds the first 1-4 bytes of its public key
%%               to a flooded packet (Mesh.cpp), so the path is complete:
%%               [d1, 77] = first the repeater whose key starts d1, then 77
%%   Meshtastic  a packet carries only relay_node: the last byte of the
%%               node number of the last node that rebroadcast it
%%
%% A hop here is #{hash => <<"d1">>, name => <<"Ridge">> | undefined}.
%% The name is filled in when exactly one known node matches the hash.
%% Repeaters (MeshCore) and routers (Meshtastic) are preferred: when two
%% nodes share the hash and only one of them relays, that one is meant.
%% No match, or an unresolved tie, leaves the name undefined (JSON null);
%% the hash is always kept.
%%
%% Names are looked up when the path is read (bridge) and again when it
%% is published (fill/2, in the MQTT connector): a repeater listed after
%% the contact whose route uses it still gets its name.
%%
-module(lora_mesh_path).

-export([meshcore/1]).
-export([meshtastic_relay/2]).
-export([fill/2]).

-include("lora_mesh.hrl").

-define(PREFIX_MASK, ((1 bsl 48) - 1)).

-type hop() :: #{hash := binary(), name := binary() | undefined}.
-export_type([hop/0]).

%% Raw path hashes (as lora_mesh_meshcore_codec:path_hashes/2 returns them)
%% -> hops. undefined stays undefined (path not known).
-spec meshcore([binary()] | undefined) -> [hop()] | undefined.
meshcore(undefined) ->
    undefined;
meshcore(Hashes) ->
    Nodes = [N || #mesh_node{protocol = meshcore} = N <- known_nodes()],
    [hop(H, [N || N <- Nodes, key_starts_with(N, H)], fun is_repeater/1)
     || H <- Hashes].

%% A Meshtastic packet's relay_node, if it was relayed at all: Hops is
%% hop_start - hop_limit. 0 and unset relay_node -> undefined.
-spec meshtastic_relay(non_neg_integer() | undefined, integer()) -> hop() | undefined.
meshtastic_relay(Relay, Hops) when is_integer(Relay), Relay > 0, Hops > 0 ->
    Byte = Relay band 16#FF,
    Nodes = [N || #mesh_node{protocol = meshtastic, num = Num} = N <- known_nodes(),
                  Num band 16#FF =:= Byte],
    hop(<<Byte>>, Nodes, fun is_router/1);
meshtastic_relay(_Relay, _Hops) ->
    undefined.

%% Fill in names still missing: Kind = meshcore (a path or route, a
%% list of hops) | meshtastic (a relay, one hop).
-spec fill(meshcore | meshtastic, [hop()] | hop() | undefined) -> [hop()] | hop() | undefined.
fill(_Kind, undefined) ->
    undefined;
fill(meshcore, Hops) when is_list(Hops) ->
    case lists:all(fun(#{name := Name}) -> Name =/= undefined end, Hops) of
        true -> Hops;
        false -> meshcore([binary:decode_hex(H) || #{hash := H} <- Hops])
    end;
fill(meshtastic, #{name := undefined, hash := H} = Hop) ->
    <<Byte>> = binary:decode_hex(H),
    case meshtastic_relay(Byte, 1) of
        undefined -> Hop;
        Filled -> Filled
    end;
fill(meshtastic, Hop) ->
    Hop.

%%====================================================================
%% Internal
%%====================================================================

hop(Hash, Candidates, Preferred) ->
    #{hash => binary:encode_hex(Hash, lowercase),
      name => pick(Candidates, Preferred)}.

pick([Only], _Preferred) ->
    name(Only);
pick(Candidates, Preferred) ->
    case lists:filter(Preferred, Candidates) of
        [Only] -> name(Only);
        _ -> undefined
    end.

name(#mesh_node{long_name = undefined, id = Id}) -> Id;
name(#mesh_node{long_name = Name}) -> Name.

key_starts_with(#mesh_node{num = Num}, Hash) ->
    Size = byte_size(Hash),
    case <<(Num band ?PREFIX_MASK):48>> of
        <<Hash:Size/binary, _/binary>> -> true;
        _ -> false
    end.

is_repeater(#mesh_node{role = Role}) ->
    lists:member(Role, [repeater, room]).

is_router(#mesh_node{role = Role}) ->
    lists:member(Role, ['ROUTER', 'ROUTER_LATE', 'REPEATER', 'ROUTER_CLIENT', 'CLIENT_BASE']).

%% The registry may live on another Erlang node (a bridge-only node):
%% then there are no names here, only hashes.
known_nodes() ->
    try
        lora_mesh_registry:all()
    catch
        error:badarg -> []
    end.
