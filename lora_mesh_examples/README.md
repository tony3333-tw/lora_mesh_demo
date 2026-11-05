# lora_mesh_examples

The examples of [meshcore_py](https://github.com/meshcore-dev/meshcore_py/tree/main/examples),
rewritten in **Erlang** (`src/ex_*.erl`) and **LFE** (`src/lx_*.lfe`) for lora_mesh 0.3.2
(they also work with 0.3.0, without the repeater names).

meshcore_py talks to one radio over USB, TCP or BLE. These programs talk to **lora_mesh** over
MQTT instead, so they work with every bridge lora_mesh has (MeshCore and Meshtastic) and need
no change to lora_mesh:

```
radio(s) ── lora_mesh 0.3.2 ── MQTT broker ── lme (these examples)
                                        └── lora_mesh_client (Python)
```

| `lme` example | Erlang | LFE | meshcore_py examples it follows |
|---|---|---|---|
| `contacts` | `ex_contacts.erl` | `lx_contacts.lfe` | serial_contacts.py, tcp_mchome_contacts.py |
| `infos` | `ex_infos.erl` | `lx_infos.lfe` | serial_infos.py, tcp_mchome_infos.py, ble_t1000_infos.py (partly: see below) |
| `msg` | `ex_msg.erl` | `lx_msg.lfe` | serial_msg.py, tcp_mchome_msg.py, ble_t1000_msg.py |
| `readmsgs` | `ex_readmsgs.erl` | `lx_readmsgs.lfe` | tcp_mchome_readmsgs.py, chan_recv_with_path.py |
| `chat` | `ex_chat.erl` | `lx_chat.lfe` | serial_chat.py, tcp_chat.py, ble_chat.py, ble_t1000_chan_msg.py (`to #0`) |
| `pingbot` | `ex_pingbot.erl` | `lx_pingbot.lfe` | serial_pingbot.py |
| `monitor` | `ex_monitor.erl` | `lx_monitor.lfe` | pubsub_example.py, serial_battery_monitor.py (partly) |

Shared code: `lmc.erl` (a small MQTT client for lora_mesh, used by both languages) and
`lme.erl` (the command line). Licence: MIT.

## Build and run

Needs Erlang/OTP 27+ and rebar3, like lora_mesh. The first build fetches emqtt, LFE and the
rebar3_lfe plugin.

```sh
cd lora_mesh_examples
rebar3 escriptize                 # -> _build/default/bin/lme, one file
cp _build/default/bin/lme ~/bin/  # optional

lme                               # list of examples
lme contacts                      # Erlang version
lme contacts --lfe                # LFE version
```

lora_mesh must be running and connected to the same broker. To have MeshCore nodes to look
at without radios, run the mixed demo: `DEMO=mixed ./lora_demo.sh` from the repository root.
(The default Meshtastic-only demo has no MeshCore nodes: use `lme contacts --all` there.)

Try these against the mixed demo:

```sh
lme contacts                      # Alice, Bob, Pump, Ridge, the two gateways (and Dave later),
                                  # with each gateway's route to them: "field: Ridge"
lme readmsgs                      # ... (Ridge > 77?, heard by barn)
lme contacts --all --json         # Meshtastic nodes too, as JSON
lme infos
lme msg -d Alice -m "hello"       # Alice answers "got it: hello"
lme readmsgs --count 5
lme chat -d Alice                 # type lines; "to Bob", "to #0", "contacts", "quit"
lme pingbot                       # answers Bob's "ping?": @[Bob] Pong 🏓(Ridge, heard by field)
lme monitor                       # nodes appearing, being heard, routes changing
```

Add `--lfe` to any of them to run the LFE version. Other options:
`--host H --port N --prefix P --username U --password W`, `-c N` (channel),
`--protocol meshcore|meshtastic` (which mesh a channel message goes to), `--wait S` (msg),
`--count N` (readmsgs). Ctrl-C ends the long-running ones.

From the Erlang shell instead of the escript:

```
rebar3 shell
1> lme:main(["contacts", "--lfe"]).
2> ex_msg:run(#{host => "localhost", dest => "Alice", message => "hi"}).
3> lx_msg:run(#{dest => "Alice", message => "hi"}).
```

(`chat` reads the keyboard, so run it with the escript rather than inside `rebar3 shell`.)

## What is different from meshcore_py

lora_mesh 0.3 already does the radio work that meshcore_py's examples do by hand, so some steps
disappear and some information is not available over MQTT:

- **Contacts and messages** come from lora_mesh, which fetched them from every bridge and merged
  copies heard by more than one. No `ensure_contacts()` or `get_msg()` loop.
- **No delivery ACK.** lora_mesh 0.3 only logs the radio's ACK; it does not publish it.
  `msg` waits for an *answer* from the contact instead (the demo's nodes answer "got it: ...").
- **Path:** like serial_pingbot.py, the path names the repeaters: lora_mesh 0.3.2 reads every
  bridge's RX log and publishes `path` (MeshCore) and `relay` (Meshtastic: only the last relay is
  known), with names where it knows them: `Ridge > 77?`. See `../lora_mesh/PATHS.md`.
  With lora_mesh 0.3.0 the examples show the hop count instead.
- **infos:** the radio's own SELF_INFO is logged by lora_mesh, not published. `infos` shows the
  node count and the bridges seen instead.
- **battery:** lora_mesh 0.3 cannot ask a bridge for its own battery. `monitor` shows the battery
  that Meshtastic nodes report about themselves (MeshCore contacts carry none).

Not ported, because they need radio commands lora_mesh 0.3 does not have (a later version
could add them to the MeshCore bridge and MQTT):

| meshcore_py example | needs |
|---|---|
| serial_trace.py | trace a path through repeaters, with SNR per hop (an active test; 0.3.2 records paths passively) |
| serial_repeater_status.py, tcp_login_status.py, serial_repeater_telemetry.py | log in to a repeater, ask for status / telemetry |
| serial_channel_manager.py | read and set channel names and keys |
| ble_t1000_custom_vars.py, ble_t1000_set_cv.py | device custom variables |
| ble_stats.py | radio statistics |
| rf_packet_monitor.py | raw RX log |
| ble_t1000_msg_retries.py | send with retries (needs the ACK) |
| mepo_mc_gps.py | the radio's own position |
| ble_sign_example.py, ble_private_key_export.py, ble_pin_pairing_example.py | signing, key export, BLE pairing: these belong on the radio, not on MQTT |
| connection_events_example.py | lora_mesh reconnects its bridges itself; `lmc` does not reconnect to the broker |

serial_rss_bot.py and serial_meshcore_ollama.py are bots like `pingbot`: the same loop, with an
HTTP request (`httpc`) where the pong is built.

## The two languages side by side

```erlang
%% ex_msg.erl
case lmc:find(Nodes, Dest) of
    error ->
        io:format("Contact '~ts' not found.~n", [Dest]);
    {ok, Node} ->
        ok = lmc:send(Client, #{to => maps:get(<<"id">>, Node), text => Text})
end
```

```lisp
;; lx_msg.lfe
(case (lmc:find nodes dest)
  ('error
   (io:format "Contact '~ts' not found.~n" (list dest)))
  ((tuple 'ok node)
   (lmc:send client (map 'to (maps:get #"id" node) 'text text))))
```

LFE note: `lfec` reads source files as Latin-1, so non-ASCII text in an LFE string literal is
sent wrongly. `lx_pingbot.lfe` writes the emoji as the code point `#x1f3d3` for this reason.
