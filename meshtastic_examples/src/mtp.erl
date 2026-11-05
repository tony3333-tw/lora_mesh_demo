%%
%% mtp: Meshtastic protobufs as maps, for the examples that work on
%% protobuf bytes without a radio (decode, protos).
%%
%% mt_pb is generated from proto/ by gpb at build time (maps mode,
%% oneofs flat): #{decoded => ...} rather than {decoded, ...}.
%%
%%   Map = mtp:decode(Bytes, telemetry),
%%   mtp:compact(Map, telemetry)          % without the default fields
%%
-module(mtp).

-export([encode/2]).
-export([decode/2]).
-export([compact/2]).

%% mt_pb:encode_msg / decode_msg
encode(Map, MsgName) ->
    mt_pb:encode_msg(Map, MsgName).

decode(Bin, MsgName) ->
    mt_pb:decode_msg(Bin, MsgName).

%% Leave out the fields that have their default value (0, false, <<>>,
%% [], the first enum value), recursively, as protobuf's MessageToDict
%% does for Python.
compact(Map, MsgName) ->
    lists:foldl(fun compact_field/2, Map, mt_pb:find_msg_def(MsgName)).

compact_field(#{fields := Alternatives}, Acc) ->
    %% a oneof: at most one alternative is present
    lists:foldl(
      fun(#{name := N, type := T}, A) ->
              case A of
                  #{N := V} -> A#{N := compact_value(T, V)};
                  _ -> A
              end
      end,
      Acc,
      Alternatives);
compact_field(#{name := N, type := T, occurrence := Occurrence}, Acc) ->
    case Acc of
        #{N := V} ->
            case Occurrence of
                defaulty ->
                    case is_default(T, V) of
                        true -> maps:remove(N, Acc);
                        false -> Acc#{N := compact_value(T, V)}
                    end;
                repeated when V =:= [] ->
                    maps:remove(N, Acc);
                repeated ->
                    Acc#{N := [compact_value(T, X) || X <- V]};
                _ ->
                    Acc#{N := compact_value(T, V)}
            end;
        _ ->
            Acc
    end.

compact_value({msg, MsgName}, V) when is_map(V) -> compact(V, MsgName);
compact_value(_Type, V) -> V.

is_default({enum, E}, V) -> V =:= mt_pb:enum_symbol_by_value(E, 0);
is_default({msg, _}, _V) -> false;
is_default(bool, V) -> V =:= false;
is_default(string, V) -> V =:= <<>>;
is_default(bytes, V) -> V =:= <<>>;
is_default(_Number, V) -> V == 0.
