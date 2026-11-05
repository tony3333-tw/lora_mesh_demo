# meshtastic_examples

The examples of [Meshtastic-Python-Examples](https://github.com/pdxlocations/Meshtastic-Python-Examples)
(pdxlocations, commit 3c56832), rewritten in **Erlang** (`src/mte_*.erl`) and **LFE**
(`src/mtl_*.lfe`), with **lora_mesh as the backend**.

The Python examples talk to one radio through the `meshtastic` library, or to a public
Meshtastic MQTT broker. These talk to **lora_mesh** instead, through your own MQTT broker:

```
radio(s) ── lora_mesh ── your MQTT broker ── mte (these examples)
                                       ├── lme (lora_mesh_examples)
                                       └── lora_mesh_client (Python)
```

lora_mesh keeps the only connection to each radio, so the examples never take a radio away from
it, and they reach every bridge lora_mesh has (on this machine or another). Nothing goes to a
public broker.

This version has the examples that work with lora_mesh 0.3 as it is: text messages and the node
list. The others need new topics in lora_mesh; they are listed under
[Waiting for lora_mesh 0.4](#waiting-for-lora_mesh-04).

## Build and run

Needs Erlang/OTP 27+ and rebar3, like lora_mesh. The first build fetches emqtt, LFE and the gpb
and LFE rebar3 plugins, and generates the Meshtastic protobuf module `src/mt_pb.erl` from
`proto/` (for `decode` and `protos`). As with lora_mesh, that compile takes several minutes on a
Raspberry Pi.

```sh
cd meshtastic_examples
rebar3 escriptize                 # -> _build/default/bin/mte, one file
cp _build/default/bin/mte ~/bin/  # optional

mte                               # list of examples
mte nodedb                        # Erlang version
mte nodedb --lfe                  # LFE version
```

lora_mesh must be running and connected to the same broker. Without radios, run lora_mesh's
Meshtastic demo (`./lora_demo.sh` from the repository root, or
`lora_mesh_demo_meshtastic:start().` in `rebar3 as test shell`): its mesh has Hill top, School,
Farm, Tracker and later Dave, and a node that gets a direct message answers "got it: ...".

```sh
mte nodedb                        # Dave, Farm, Hill gw, Hill top, Home gw, School, Tracker
mte messages --seconds 30
mte dm -d School -m "hello"       # School: got it: hello
mte chat -d "Hill top"            # type lines; "quit" ends
mte autoresponder -c 1
mte mqtt-receive                  # everything lora_mesh publishes
```

## The examples

Every example takes `--host H` (localhost) and `--port N` (1883) for the broker, `--prefix P`
(mesh, as lora_mesh's `prefix`), and `--username U --password W` if the broker wants them. `-d
NODE` is a name ("Hill top", "hill"), an id (`!0a0b0c0d`) or a number (`168496141`). Add `--lfe`
to any example to run the LFE version.

| `mte` example | Python examples | Options |
|---|---|---|
| `messages` | print-messages.py, get-all-messages.py | `--seconds S` stops after S s |
| `autoresponder` | autoresponder.py, send-secondary.py | `-m TEXT`, `-c N` (channel 1 = send-secondary) |
| `chat` | send-and-receive.py | `-d NODE` or `-c N` |
| `dm` | send-direct-message.py | `-d NODE -m TEXT`, `--wait S` (10) |
| `nodedb` | print-nodedb.py | `--json`, `--all` (MeshCore nodes too) |
| `decode` | decode-protobuf.py | `--hex HEX` or `--base64 B64`, `--type MSG` |
| `protos` | list-protos.py | |
| `mqtt-receive` | MQTT/receive-mqtt-packets.py | `--topic T1,T2` (`mesh/rx/#,mesh/node/#`) |
| `mqtt-send` | MQTT/send-mqtt-packets.py | `-m TEXT`, `-c N`, `-d '!id'` |
| `mqtt-client` | MQTT/mqtt-client.py | as mqtt-send, then prints what comes back |

`decode` and `protos` work on protobuf bytes alone and need neither lora_mesh nor a broker.

The three `mqtt-*` examples use plain emqtt and the `json` module, without `mtc`: they show
lora_mesh's topics as any MQTT client sees them.

```
mesh/rx/<from>      out        a text message (JSON)
mesh/node/<id>      out, kept  what lora_mesh knows about a node (JSON, retained)
mesh/tx             in         {"text": "...", "to": "!0a0b0c0d", "channel": 0}
```

From the Erlang shell instead of the escript:

```
rebar3 shell
1> mte:main(["nodedb", "--lfe"]).
2> C = mtc:connect(#{host => "localhost"}).
3> mtc:send_text(C, "hello", #{to => <<"!0c0c0c0c">>}).
```

(`chat` reads the keyboard, so run it with the escript rather than inside `rebar3 shell`.)

## What is different from the Python examples

- **Messages are JSON maps from lora_mesh** with binary keys: `maps:get(<<"text">>, Rx)`,
  `<<"from">>` as `"!0a0b0c0d"`. lora_mesh merges the copies its bridges hear and adds
  `bridges`.
- **Broadcasts go to the Meshtastic mesh** (`"protocol": "meshtastic"`), not to MeshCore radios
  lora_mesh may also have. Direct messages go wherever the node is.
- **dm** cannot wait for the ACK: lora_mesh 0.3 does not report it. It prints what the node sends
  back for `--wait` seconds.
- **nodedb** lists every node any bridge has heard, with which bridges heard it and their SNR.
  It has no per-node SNR, hops, channel use or MAC address.
- **autoresponder** does not answer its own reply text, so two of them don't answer each other
  for ever.
- **mqtt-send** sends texts as the bridge's own radio, so there is no made-up "Bottastic" node, no
  node info and no position.
- **mqtt-receive** gets JSON that the radios have already decrypted, from your broker; the Python
  example gets encrypted protobuf from the public broker and decrypts it.

## Waiting for lora_mesh 0.4

The other Python examples need things lora_mesh 0.3 does not publish or accept. This is the
plan for lora_mesh 0.4 and the examples it would bring:

| lora_mesh 0.4 adds | Examples it enables | Python examples |
|---|---|---|
| `mesh/packet/<from>`: every packet a bridge hears (all ports, decoded), not only texts | `packets` (`--raw`, `--json`, `--log FILE`, `--counts`) | print-packets.py, print-packets-basic.py, print-packets-json.py, print-packets-json-log.py, print-packets-json-log-and-plot.py |
| `mesh/bridge/<id>/info` (retained): each bridge's radio as it connects: my info, channels, config, metadata, local stats | `myinfo`, `local-stats`, `channels`, `preset` | print-myNodeInfo, get-local-stats.py, get-channels.py, get-config-modem-preset.py |
| `mesh/bridge/<id>/status` (retained, with a last will): connected or not | `watchdog` (watches lora_mesh's bridges instead of one TCP link) | tcp_watchdog.py |
| `mesh/req` → `mesh/resp/<ref>`: send a request through a bridge and get the answer back | `traceroute`, `request` (telemetry, environment, position, node info), `send` (position, node info, telemetry, waypoint), `foxhunt`; and the ACK for `dm` | send-traceroute-simple.py, print-traceroute.py, request-*.py, send-*.py, foxhunt.py, test-rssi-snr.py |
| Admin through `mesh/req`, **off unless lora_mesh's config turns it on** | `save-channel`, `admin-keys`, `set-url` | save-channel.py, save-admin-keys.py, set-URL.py |

Not planned: MQTT/serial-mqtt.py (a radio's packets to an MQTT broker) is what lora_mesh itself
does.

Admin stays off by default because anyone who can publish to the broker could otherwise change
the radios' channels and keys. A Meshtastic-only version of these examples that talks to a radio
directly (TCP 4403) was written first and is kept out of this tree; parts of it (the request and
admin code, a fake radio that answers them) can move into lora_mesh 0.4.

## The code

| Module | What |
|---|---|
| `mtc` | a small client for lora_mesh: connect, node list, find a node, send a text, wait for messages. What `meshtastic.tcp_interface` does for the Python examples, through lora_mesh |
| `mtp` | Meshtastic protobufs as maps (decode, compact), for `decode` |
| `mte` | the command line |
| `mt_pb` | generated from `proto/` by gpb at build time |

Messages arrive in the process that called `mtc:connect/1`; `mtc:next/2` waits for the next one.

```erlang
%% mte_messages.erl
case mtc:next(C, mtc:left(Deadline)) of
    {rx, #{<<"text">> := Text}} ->
        io:format("~ts~n", [Text]),
        ...
```

```lisp
;; mtl_messages.lfe
(case (mtc:next c (mtc:left deadline))
  ((tuple 'rx (map #"text" text))
   (io:format "~ts~n" (list text))
   ...
```

## Tests

```sh
rebar3 eunit      # mtc's node lookup, topics and mesh/tx JSON, both languages' tx, mtp
```

The examples themselves were run against lora_mesh's Meshtastic demo, in both languages.

## Licence

GPL-3.0, like the Python examples it follows and the Meshtastic protobufs in `proto/`
(see `proto/LICENSE.meshtastic-protobufs`).
