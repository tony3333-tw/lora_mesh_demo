%%
%% Set the admin keys of the radio, like save-admin-keys.py: the public
%% keys of the nodes allowed to administer this radio over the mesh (up
%% to 3). Existing keys are cleared first.
%%
%%   mte admin-keys --keys KEY1,KEY2       base64 public keys
%%   mte admin-keys --clear                remove all admin keys
%%
%% There is no default list: a key gives its owner control of the radio.
%% Get a node's public key with mte nodedb.
%%
-module(mte_admin_keys).

-export([run/1]).

run(Opts) ->
    Keys = [base64:decode(K) || K <- maps:get(keys, Opts, [])],
    case {Keys, maps:get(clear, Opts, false)} of
        {[], false} ->
            error({missing_option, "--keys KEY1,KEY2 (or --clear)"});
        _ ->
            C = mtc:connect(Opts),
            Security = mtc:config(C, security),
            case maps:get(admin_key, Security, []) of
                [] ->
                    ok;
                _Existing ->
                    io:format("Clearing existing admin keys...~n"),
                    write(C, Security#{admin_key => []}),
                    timer:sleep(1000)
            end,
            case Keys of
                [] ->
                    ok;
                _ ->
                    [io:format("Adding admin key: ~s~n", [base64:encode(K)]) || K <- Keys],
                    write(C, Security#{admin_key => Keys}),
                    io:format("Admin keys updated successfully!~n")
            end,
            mtc:close(C)
    end.

%% node.writeConfig("security")
write(C, Security) ->
    Id = mtc:admin(C, #{set_config => #{security => Security}}),
    ok = mtc:ack(C, Id, 10000).
