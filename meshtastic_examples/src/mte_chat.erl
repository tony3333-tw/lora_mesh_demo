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
    Send = case maps:is_key(dest, Opts) of
               true -> #{to => mtc:dest(C, Opts)};
               false -> #{channel => maps:get(channel, Opts, 0)}
           end,
    Self = self(),
    spawn_link(fun() -> read_lines(Self) end),
    loop(C, Send),
    mtc:close(C).

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

loop(C, Send) ->
    receive
        {line, eof} ->
            ok;
        {line, "quit"} ->
            ok;
        {line, ""} ->
            loop(C, Send);
        {line, Text} ->
            mtc:send_text(C, Text, Send),
            loop(C, Send);
        {mtc, C, packet, #{from := From, decoded := #{portnum := 'TEXT_MESSAGE_APP', text := Text}}} ->
            io:format("~ts: ~ts~n> ", [mtc:name(C, From), Text]),
            loop(C, Send);
        {mtc, C, packet, _Other} ->
            loop(C, Send);
        {mtc, C, closed, _} ->
            io:format("the radio closed the connection~n")
    end.
