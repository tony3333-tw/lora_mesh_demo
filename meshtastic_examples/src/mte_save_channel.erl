%%
%% Change one channel on the radio, like save-channel.py.
%%
%%   mte save-channel                      channel 1 = "NBC", default key,
%%                                         uplink and downlink on, position precision 13
%%   mte save-channel --index 2 --name farm --psk "base64 key"
%%
%% Channel 0 becomes the primary channel, others secondary. A new key
%% for a private channel: 16 or 32 random bytes in base64, e.g.
%% openssl rand -base64 16. This changes the radio's settings.
%%
-module(mte_save_channel).

-export([run/1]).

run(Opts) ->
    C = mtc:connect(Opts),
    Index = maps:get(index, Opts, 1),
    #{settings := Old} = lists:nth(Index + 1, mtc:channels(C)),
    Settings = Old#{psk => mtq:psk(maps:get(psk, Opts, "AQ==")),
                    name => unicode:characters_to_binary(maps:get(name, Opts, "NBC")),
                    uplink_enabled => true,
                    downlink_enabled => true,
                    module_settings => #{position_precision => 13}},
    Role = case Index of
               0 -> 'PRIMARY';
               _ -> 'SECONDARY'
           end,
    Channel = #{index => Index, role => Role, settings => Settings},
    Id = mtc:admin(C, #{set_channel => Channel}),
    case mtc:ack(C, Id, 10000) of
        ok -> io:format("Channel ~p saved:~n~p~n", [Index, Channel]);
        Other -> io:format("The radio did not confirm: ~p~n", [Other])
    end,
    mtc:close(C).
