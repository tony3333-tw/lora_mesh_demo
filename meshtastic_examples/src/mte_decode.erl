%%
%% Decode protobuf bytes, like decode-protobuf.py (a Telemetry message).
%%
%%   mte decode                                the bytes from decode-protobuf.py
%%   mte decode --hex 0d9a2b4467...            your bytes, as hex
%%   mte decode --base64 DZorRGcaCg... --type telemetry
%%   mte decode --type position --hex ...      any message: mesh_packet, user, ...
%%
-module(mte_decode).

-export([run/1]).

%% b"\r\232+Dg\032\n\r\341z \301\025\000\200\241B" in decode-protobuf.py
-define(SAMPLE, <<"\r\232+Dg\032\n\r\341z \301\025\000\200\241B">>).

run(Opts) ->
    Bytes = case Opts of
                #{hex := Hex} -> binary:decode_hex(list_to_binary(Hex));
                #{base64 := B64} -> base64:decode(B64);
                _ -> ?SAMPLE
            end,
    Type = list_to_atom(maps:get(type, Opts, "telemetry")),
    Map = mtp:decode(Bytes, Type),
    io:format("~p~n", [mtp:compact(Map, Type)]).
