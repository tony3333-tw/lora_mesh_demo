%%% @doc Meshtastic "stream API" framing.
%%%
%%% The same framing is used on serial and on TCP port 4403:
%%%
%%%   +------+------+---------+---------+-------------------+
%%%   | 0x94 | 0xC3 | len MSB | len LSB | protobuf (len B)  |
%%%   +------+------+---------+---------+-------------------+
%%%
%%% Payload is a ToRadio (client -> node) or FromRadio (node -> client).
%%% Anything outside a frame (e.g. debug log text on serial) is skipped.
-module(lora_mesh_frame).

-export([encode/1]).
-export([decode/1]).

-define(START1, 16#94).
-define(START2, 16#C3).
-define(MAX_LEN, 512).

%%--------------------------------------------------------------------
%% Wrap one encoded protobuf message in a frame header.
%%--------------------------------------------------------------------
-spec encode(iodata()) -> iodata().
encode(Payload) ->
    Len = iolist_size(Payload),
    true = Len =< ?MAX_LEN,
    [<<?START1, ?START2, Len:16/big>>,
     Payload].

%%--------------------------------------------------------------------
%% Pull every complete frame out of a buffer.
%% Returns the payloads (oldest first) and the unconsumed rest.
%%--------------------------------------------------------------------
-spec decode(binary()) -> {[binary()], binary()}.
decode(Buffer) ->
    decode(Buffer, []).

decode(<<?START1, ?START2, Len:16/big, Rest/binary>>, Acc)
  when Len =< ?MAX_LEN ->
    case Rest of
        <<Payload:Len/binary, Tail/binary>> ->
            decode(Tail, [Payload | Acc]);
        _ ->
            %% Frame not complete yet: keep header and wait for more bytes.
            {lists:reverse(Acc), <<?START1, ?START2, Len:16/big, Rest/binary>>}
    end;
decode(<<?START1, Rest/binary>>, Acc)
  when byte_size(Rest) >= 3 ->
    %% Header bytes with an impossible length: not a real frame.
    %% Drop one byte and resync.
    decode(Rest, Acc);
decode(<<?START1>> = Partial, Acc) ->
    {lists:reverse(Acc), Partial};
decode(<<?START1, ?START2>> = Partial, Acc) ->
    {lists:reverse(Acc), Partial};
decode(<<?START1, ?START2, _>> = Partial, Acc) ->
    {lists:reverse(Acc), Partial};
decode(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
decode(<<_Junk, Rest/binary>>, Acc) ->
    decode(Rest, Acc).
