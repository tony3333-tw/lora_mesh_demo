%%
%% Chat from the terminal, like serial_chat.py, tcp_chat.py and
%% ble_chat.py: incoming messages are printed, a typed line is sent.
%%
%%   lme chat -d Alice
%%
%% Commands (as in serial_chat.py, plus channels):
%%   hello there      send to the current destination
%%   send hello       the same
%%   to Bob           direct messages now go to Bob
%%   to #0            messages now go to everyone on channel 0
%%   contacts         list the nodes
%%   q / quit         end
%%
-module(ex_chat).

-export([run/1]).

-record(chat, {
    client,
    names,
    nodes,
    dest,          % {node, Id, Name} | {channel, N}
    protocol}).

run(Opts) ->
    Client = lmc:connect(Opts),
    Nodes = lmc:nodes(Client, 1000),
    ok = lmc:subscribe(Client, rx),
    Chat = #chat{client = Client,
                 names = lmc:names(Nodes),
                 nodes = Nodes,
                 protocol = maps:get(protocol, Opts, meshcore)},
    case destination(maps:get(dest, Opts, "Alice"), Chat) of
        {ok, Dest} ->
            Self = self(),
            spawn_link(fun() -> read_lines(Self) end),
            io:format("Talking to ~ts. Commands: to NAME, to #N, contacts, quit~n",
                      [dest_name(Dest)]),
            loop(Chat#chat{dest = Dest});
        error ->
            io:format("Contact '~ts' not found in contacts.~n", [maps:get(dest, Opts, "Alice")])
    end,
    lmc:disconnect(Client).

%% stdin is read by its own process, so messages print while we wait
read_lines(Parent) ->
    case io:get_line("") of
        eof ->
            Parent ! {line, eof};
        {error, _} ->
            Parent ! {line, eof};
        Line ->
            Parent ! {line, string:trim(Line, trailing, "\r\n")},
            read_lines(Parent)
    end.

loop(#chat{client = Client, names = Names} = Chat) ->
    receive
        {line, eof} ->
            ok;
        {line, Line} ->
            case command(Line, Chat) of
                quit -> ok;
                Chat2 -> loop(Chat2)
            end;
        {publish, Msg} ->
            case lmc:decode(Client, Msg) of
                {rx, Rx} ->
                    io:format("~ts: ~ts~n", [lmc:sender(Rx, Names), maps:get(<<"text">>, Rx)]),
                    loop(Chat);
                {node, Node} ->
                    loop(Chat#chat{names = lmc:add_name(Names, Node)});
                ignore ->
                    loop(Chat)
            end
    end.

command(Line, _Chat) when Line =:= "q"; Line =:= "quit" ->
    quit;
command("", Chat) ->
    Chat;
command("contacts", #chat{nodes = Nodes} = Chat) ->
    [io:format("  ~-15ts ~ts~n", [maps:get(<<"id">>, N), maps:get(<<"long_name">>, N)])
     || N <- Nodes, maps:get(<<"long_name">>, N) =/= null],
    Chat;
command("to " ++ Who, Chat) ->
    case destination(Who, Chat) of
        {ok, Dest} ->
            io:format("now talking to ~ts~n", [dest_name(Dest)]),
            Chat#chat{dest = Dest};
        error ->
            io:format("Contact '~ts' not found in contacts.~n", [Who]),
            Chat
    end;
command("send " ++ Text, Chat) ->
    say(Text, Chat);
command(Text, Chat) ->
    say(Text, Chat).

say(Text, #chat{client = Client, dest = Dest, protocol = Protocol} = Chat) ->
    Tx = case Dest of
             {node, Id, _Name} -> #{to => Id, text => Text};
             {channel, N} -> #{channel => N, protocol => Protocol, text => Text}
         end,
    ok = lmc:send(Client, Tx),
    io:format(" Sent~n"),
    Chat.

destination("#" ++ N, _Chat) ->
    try {ok, {channel, list_to_integer(N)}}
    catch error:badarg -> error
    end;
destination(Who, #chat{nodes = Nodes}) ->
    case lmc:find(Nodes, Who) of
        {ok, Node} ->
            {ok, {node, maps:get(<<"id">>, Node), maps:get(<<"long_name">>, Node)}};
        error ->
            error
    end.

dest_name({node, _Id, Name}) -> Name;
dest_name({channel, N}) -> io_lib:format("channel ~p", [N]).
