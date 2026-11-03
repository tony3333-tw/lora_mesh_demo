# lora-mesh-client

Python for your Meshtastic and MeshCore meshes: read messages, see every node, send texts.
It talks to a **lora_mesh** server over MQTT, so you need no Erlang and no protobuf.

```
 Meshtastic nodes ┐
 MeshCore radios  ┴► lora_mesh (Erlang) ─► MQTT broker ─► your Python script
                     bridges, router,       mesh/rx/+       lora_mesh_client
                     node registry          mesh/node/+
                                    ◄────── mesh/tx ◄──────
```

## Install

```sh
pip install paho-mqtt
pip install .            # from this folder
```

Python 3.9 or newer. You need a lora_mesh server running and its MQTT broker's address.

## Try it from the command line

```sh
python -m lora_mesh_client listen                       # print messages as they arrive
python -m lora_mesh_client nodes                        # list every node
python -m lora_mesh_client send "hello mesh"            # to everyone
python -m lora_mesh_client send "hi" --to !a1b2c3d4     # to one node
python -m lora_mesh_client send "hi" --bridge hill      # through one lora_mesh bridge
python -m lora_mesh_client send "hi" --to @a1a2a3a4a5a6 # to one MeshCore node
python -m lora_mesh_client send "hi" --protocol meshcore  # to everyone on the MeshCore channel 0
```

Add `--host`, `--port`, `--prefix`, `--username`, `--password` if your broker isn't on `localhost:1883`.

```
$ python -m lora_mesh_client listen
23:41:38  Hill top -> all: 哈囉 from mesh   [snr 8.5 dB, hops 1, via hill, home]

$ python -m lora_mesh_client nodes
id         name                 hardware         battery last heard        best bridge
!0a0b0c0d  Hill top             HELTEC_V3                10-28 19:44:42    hill
```

## Your first script

```python
from lora_mesh_client import MeshClient

mesh = MeshClient("localhost")

@mesh.on_message
def show(msg):
    print(msg.from_id, msg.text, msg.rx.rx_snr)
    if msg.text == "ping":
        mesh.send("pong", to=msg.from_id)

mesh.run()     # Ctrl+C to stop
```

Or as a loop, without decorators:

```python
with MeshClient("localhost") as mesh:
    for msg in mesh.messages():
        print(msg.text)
```

## Examples

| File | What it does |
|---|---|
| `examples/demo_bot.py` | For team demos: prints every message and new node, answers "ping" on a channel or directly (`--name Mary`) |
| `examples/echo_bot.py` | Replies "pong" to "ping", through the bridge that heard the sender best |
| `examples/csv_logger.py` | Writes every message and node update to `messages.csv` / `nodes.csv`, for data collection |
| `examples/battery_watch.py` | Warns once when a node's battery drops below a threshold |

## API

| | |
|---|---|
| `MeshClient(host, port=1883, prefix="mesh", username=None, password=None)` | A connection |
| `@mesh.on_message` | Call your function with a `Message` for every text |
| `@mesh.on_node` | Call your function with a `Node` whenever a node's record changes |
| `mesh.run()` | Connect and run until Ctrl+C |
| `mesh.start()` / `mesh.stop()`, or `with mesh:` | Run in the background |
| `mesh.messages(timeout=None)` | Iterate over incoming messages |
| `mesh.nodes` | `{"!a1b2c3d4": Node, "@a1a2a3a4a5a6": Node, ...}`: every node known so far |
| `mesh.node("!a1b2c3d4")` | One node, or `None` |
| `mesh.send(text, to=None, channel=0, bridge=None, protocol=None)` | Send a text; raises `ValueError` if too long (233 bytes Meshtastic, 160 MeshCore) |

### Data

Each class matches a record in lora_mesh's `include/lora_mesh.hrl`:

| Python | lora_mesh record | Fields |
|---|---|---|
| `Message` | `#mesh_rx{}` | `id, from_id, to_id, channel, text, rx, bridges, protocol, sender_name, is_broadcast, is_known_sender` |
| `Reception` | `#mesh_rxq{}` | `rx_snr, rx_rssi, hop_start, hop_limit, via_mqtt, hops` |
| `Node` | `#mesh_node{}` | `num, id, protocol, name, long_name, short_name, hw_model, role, position, battery_level, voltage, last_heard, heard_by, best_bridge` |
| `Position` | `#mesh_position{}` | `latitude, longitude, altitude, time` |
| `Heard` | `#mesh_heard{}` | `bridge, rx, at` |

Times are `datetime` in UTC. `battery_level` 101 means the node is on external power.

### Good to know

- **233 bytes per message** on Meshtastic, **160** on MeshCore, counted in UTF-8: 160 bytes is about 53 Chinese characters. On a MeshCore channel the radio's name and `": "` count too. `send()` checks the 233/160 limit; lora_mesh checks the name part.
- **Two kinds of id.** `!a1b2c3d4` is a Meshtastic node, `@a1a2a3a4a5a6` a MeshCore node (the start of its public key). `node_num()` and `node_id()` convert both; `protocol` on a `Message` or `Node` says which mesh.
- **MeshCore channel messages name the sender, they don't prove it.** lora_mesh matches the name to a known contact; if it can't, `from_id` is `"?"` and `sender_name` holds the name.
- **Node records are retained.** When your script connects, the broker hands it every node at once, so `mesh.nodes` fills within a second.
- **Messages are not retained.** Your script only sees messages that arrive while it's connected. Use `csv_logger.py`, or lora_mesh's own storage, to keep history.
- **Handlers run in a background thread.** One handler raising an error is logged and doesn't stop the others.

## Tests

```sh
pip install pytest
python -m pytest tests
```

The unit tests use JSON captured from real lora_mesh runs (0.2 for Meshtastic, 0.3 with a fake MeshCore
companion). The client was also tested end to end against
lora_mesh with two bridges and Mosquitto: receiving the deduplicated message and node record, then replying
through the best bridge.

## Licence

MIT. This client contains no Meshtastic code: it only exchanges JSON with lora_mesh over MQTT, so it can
use a permissive licence even though lora_mesh itself (built on Meshtastic's GPL-3.0 protobufs) is GPL.
Use it freely in your own projects.
