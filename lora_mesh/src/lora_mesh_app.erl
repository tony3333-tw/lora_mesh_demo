-module(lora_mesh_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([config_file/0]).

%% Before the supervisor starts, settings from an editable config file
%% override the defaults in lora_mesh.app / sys.config:
%%
%%   $LORA_MESH_CONFIG               if set
%%   <release root>/etc/lora_mesh.config   in a release
%%
%% The file holds Erlang terms, one per setting, e.g.
%%   {bridges, [#{id => home, host => "192.168.1.50"}]}.
%%   {mqtt, #{host => "localhost", port => 1883, prefix => <<"mesh">>}}.
start(_Type, _Args) ->
    case load_config(config_file()) of
        ok -> lora_mesh_sup:start_link();
        {error, _} = Error -> Error
    end.

stop(_State) ->
    ok.

config_file() ->
    case os:getenv("LORA_MESH_CONFIG") of
        false -> filename:join([code:root_dir(), "etc", "lora_mesh.config"]);
        "" -> filename:join([code:root_dir(), "etc", "lora_mesh.config"]);
        Path -> Path
    end.

load_config(File) ->
    case file:consult(File) of
        {ok, Terms} ->
            lists:foreach(
              fun({Key, Value}) when is_atom(Key) ->
                      application:set_env(lora_mesh, Key, Value);
                 (Other) ->
                      logger:warning("lora_mesh: ignoring ~p in ~s", [Other, File])
              end,
              Terms),
            logger:notice("lora_mesh: settings from ~s", [File]),
            ok;
        {error, enoent} ->
            %% no file: keep sys.config / built-in defaults
            ok;
        {error, Reason} ->
            %% a broken file must not start with surprising settings
            logger:error("lora_mesh: cannot read ~s: ~s",
                         [File, file:format_error(Reason)]),
            {error, {bad_config, File, Reason}}
    end.
