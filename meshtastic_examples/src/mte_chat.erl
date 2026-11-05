%%
%% Send what is typed, print what is received, like send-and-receive.py.
%%
%%   mte chat                     to everyone on channel 0
%%   mte chat -c 1                to everyone on channel 1
%%   mte chat -d "Hill top"       direct messages to one node
%%
%% An empty line does nothing; "quit" (or Ctrl-D) ends.
%%
-module(mte_chat).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Names = mtc:names(mtc:nodes(C, Opts)),
    Send = case maps:is_key(dest, Opts) of
               true -> #{to => mtc:dest(C, Opts)};
               false -> #{channel => maps:get(channel, Opts, 0)}
           end,
    ok = mtc:subscribe(C, rx),
    Self = self(),
    spawn_link(fun() -> read_lines(Self) end),
    loop(C, Names, Send),
    mtc:disconnect(C).

%% stdin is read by its own process, so messages print while we wait
read_lines(Parent) ->
    case io:get_line("> ") of
        eof ->
            Parent ! {line, eof};
        {error, _} ->
            Parent ! {line, eof};
        Line ->
            Parent ! {line, string:trim(Line, trailing, "\r\n")},
            read_lines(Parent)
    end.

loop(C, Names, Send) ->
    receive
        {line, eof} ->
            ok;
        {line, "quit"} ->
            ok;
        {line, ""} ->
            loop(C, Names, Send);
        {line, Text} ->
            ok = mtc:send_text(C, Text, Send),
            loop(C, Names, Send);
        {publish, Msg} ->
            case mtc:decode(C, Msg) of
                {rx, Rx} ->
                    io:format("~ts: ~ts~n> ", [mtc:sender(Rx, Names), maps:get(<<"text">>, Rx)]);
                _Other ->
                    ok
            end,
            loop(C, Names, Send)
    end.
