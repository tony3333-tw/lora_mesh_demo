# lora_mesh demo

Meshtastic and MeshCore LoRa radios to MQTT, in Erlang, with a Python client.
Runs a live demo with fake radios, so no hardware is needed to try it.

| Folder / file | What | Licence |
|---|---|---|
| `lora_mesh/` | Erlang server: radio bridges, router, node registry, MQTT connector (0.3.2) | GPL-3.0 (uses Meshtastic's protobufs) |
| `lora_mesh_client/` | Python client: read messages and nodes, send texts (0.2.2) | MIT |
| `lora_mesh_examples/` | meshcore_py's examples rewritten in Erlang and LFE, as MQTT clients of lora_mesh | MIT |
| `lora_demo.sh` | tmux demo: server, bot, manual send and MQTT in four panes | MIT |

The server and the client only talk over MQTT, so the client contains no GPL code:

| Topic | Direction | Carries |
|---|---|---|
| `mesh/rx/<node id>` | server → clients | a text message from the mesh |
| `mesh/node/<node id>` | server → clients (retained) | what is known about a node: name, battery, position, who heard it |
| `mesh/tx` | clients → server | a text to send into the mesh |

Node ids: `!0a0b0c0d` for Meshtastic, `@a1a2a3a4a5a6` for MeshCore.

Since 0.3.2 every message also says which repeaters (MeshCore) or which last router (Meshtastic)
it came through, and every MeshCore node how each bridge reaches it: see `lora_mesh/PATHS.md`.

## How the demo is laid out

```
+---------------------------+---------------------------+
| T1 lora_mesh (Erlang)     | T2 Python bot             |
|    fake boards + script   |    runs by itself         |
+---------------------------+---------------------------+
| T3 Python manual          | T4 mosquitto_sub          |
|    send pre-typed: Enter  |    everything on MQTT     |
+---------------------------+---------------------------+
```

- **T1** runs lora_mesh with two fake Meshtastic boards ("home" and "hill"). Every 8 s something
  happens on air: a temperature heard by both boards (published once), a battery report, a
  position, a direct message, a "ping?".
- **T2** is an automatic Python program: it prints every message and node, and answers "ping".
- **T3** is you: a send command is typed and waiting; press Enter, and the node's answer appears in T2.
- **T4** shows the raw MQTT traffic.

## Requirements

On Linux (tested on a Raspberry Pi 4 with Raspberry Pi OS, 64-bit):

- Erlang/OTP 27 or newer, and rebar3
- Python 3.9 or newer
- Mosquitto (`sudo apt install mosquitto mosquitto-clients`)
- tmux (`sudo apt install tmux`)

## Run it

```sh
git clone https://github.com/<you>/lora_mesh_demo.git
cd lora_mesh_demo

# Python client, once
cd lora_mesh_client
python3 -m venv .venv
. .venv/bin/activate
pip install paho-mqtt
pip install -e .
deactivate
cd ..

# the demo
./lora_demo.sh             # start (or re-attach)
./lora_demo.sh stop        # end it
```

The first start compiles the Erlang code, including the large generated Meshtastic protobuf
module: allow about 10 minutes on a Raspberry Pi 4, with no output while it compiles. Later
starts take seconds.

Other options: `DEMO=mixed ./lora_demo.sh` runs a mixed MeshCore + Meshtastic demo;
`NAME=John ./lora_demo.sh` makes the bot answer "pong from John".

## Tests

```sh
cd lora_mesh && rebar3 eunit                                   # Erlang
cd lora_mesh_client && . .venv/bin/activate && pip install pytest && python -m pytest -v tests
```

## More

- `CHANGELOG.md`: what changed in each tagged version
- `lora_mesh/README.md`: the server in detail (bridges, deduplication, configuration, releases)
- `lora_mesh/PATHS.md`: repeater paths, Meshtastic relays and routes (0.3.2)
- `lora_mesh_client/README.md`: the Python API and examples
- `lora_mesh_examples/README.md`: the Erlang and LFE examples (`lme contacts`, `lme chat --lfe`, ...)
