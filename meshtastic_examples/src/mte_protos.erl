%%
%% Every setting the protobufs define, with its default value, like
%% list-protos.py: the user settings, 8 channel settings, the radio
%% config and the module config, as nested JSON-like text. (What a menu
%% of all settings could be built from.)
%%
%%   mte protos
%%
-module(mte_protos).

-export([run/1]).

-define(USER_SETTINGS, [long_name, short_name, is_licensed, is_unmessagable]).

run(_Opts) ->
    User = [F || {Name, _} = F <- menu(user), lists:member(Name, ?USER_SETTINGS)],
    Channel = menu(channel_settings),
    io:format("{~n"),
    pretty("\"User Config\"", {obj, User}, 2, true),
    pretty("\"Channel Config\"", {list, lists:duplicate(8, {obj, Channel})}, 2, true),
    pretty("\"Radio Config\"", {obj, menu(config)}, 2, true),
    pretty("\"Module Config\"", {obj, menu(module_config)}, 2, false),
    io:format("}~n").

%% A message's fields in order, as [{Name, Default}]; nested messages
%% (oneof alternatives too) as {obj, ...}
menu(MsgName) ->
    lists:append([field(F) || F <- mt_pb:find_msg_def(MsgName)]).

field(#{fields := Alternatives}) ->
    lists:append([field(F#{occurrence => optional}) || F <- Alternatives]);
field(#{name := Name, occurrence := repeated}) ->
    [{Name, {list, []}}];
field(#{name := Name, type := {msg, Sub}}) ->
    [{Name, {obj, menu(Sub)}}];
field(#{name := Name, type := {map, _, _}}) ->
    [{Name, {obj, []}}];
field(#{name := Name, type := {enum, Enum}}) ->
    [{Name, mt_pb:enum_symbol_by_value(Enum, 0)}];
field(#{name := Name, type := Type}) ->
    [{Name, default(Type)}].

default(bool) -> false;
default(string) -> <<>>;
default(bytes) -> <<>>;
default(float) -> 0.0;
default(double) -> 0.0;
default(_Integer) -> 0.

pretty(Title, {obj, Fields}, Indent, Comma) ->
    Pad = lists:duplicate(Indent, $\s),
    io:format("~s~s{~n", [Pad, prefix(Title)]),
    items([{io_lib:format("\"~s\"", [K]), V} || {K, V} <- Fields], Indent + 2),
    io:format("~s}~s~n", [Pad, comma(Comma)]);
pretty(Title, {list, Items}, Indent, Comma) ->
    Pad = lists:duplicate(Indent, $\s),
    io:format("~s~s[~n", [Pad, prefix(Title)]),
    items([{"", V} || V <- Items], Indent + 2),
    io:format("~s]~s~n", [Pad, comma(Comma)]);
pretty(Title, Value, Indent, Comma) ->
    Pad = lists:duplicate(Indent, $\s),
    io:format("~s~s~s~s~n", [Pad, prefix(Title), value(Value), comma(Comma)]).

%% "\"name\": " before a value, nothing for a list item
prefix("") -> "";
prefix(Title) -> [Title, ": "].

items(Items, Indent) ->
    Last = length(Items),
    [pretty(K, V, Indent, I =/= Last) || {I, {K, V}} <- lists:enumerate(Items)],
    ok.

value(true) -> "true";
value(false) -> "false";
value(<<>>) -> "\"\"";
value(V) when is_atom(V) -> io_lib:format("\"~s\"", [V]);
value(V) -> io_lib:format("~p", [V]).

comma(true) -> ",";
comma(false) -> "".
