# lora_mesh 0.3

Meshtastic and MeshCore **bridges, router and node registry** in Erlang, written with records and laid out like
[gotthardp/lorawan-server](https://github.com/gotthardp/lorawan-server) so the two can be read side by side.

- **Stage 1, registry:** every node the mesh reports (name, hardware, position, battery, who heard it) in ETS,
  published to MQTT as retained JSON.
- **Stage 2, several bridges + router:** one connection per Meshtastic node, found through `pg`; a router
  deduplicates packets heard by more than one bridge and keeps the best copy.
- **0.3, MeshCore:** a second kind of bridge, `lora_mesh_meshcore`, for MeshCore companion radios over USB
  serial or Wi-Fi: text messages (direct and channel) and contacts, into the same router, registry and MQTT
  topics. See [MeshCore](#meshcore).

## The pipeline

```
 node A ─TCP 4403─► lora_mesh_node (bridge home) ─┐
 node B ─TCP 4403─► lora_mesh_node (bridge hill) ─┤  pg scope lora_mesh
                    (this or another Erlang node) │
                                                  ▼
                                         lora_mesh_router ── dedup {From, Id} in a 200 ms window,
                                                  │          best SNR first, then fewest hops
                                                  ▼
                                         lora_mesh_handler ── by port number:
                                           │        │          TEXT → uplink, NODEINFO/POSITION/TELEMETRY → registry
                                           │        ▼
                                           │   lora_mesh_registry (ETS) ──{node, #mesh_node{}}──┐
                                           ▼                                                     ▼
                                     {uplink, #mesh_rx{}} ──────────────────────► lora_mesh_connector_mqtt ──► broker
                                                                                   mesh/rx/<from>
                                                                                   mesh/node/<id> (retained)
                                                     lora_mesh_node:send/1,2 ◄──── mesh/tx
```

## Next to lorawan-server

```
lorawan-server  gateway ─► lorawan_gw_forwarder ─► lorawan_gw_router ─► lorawan_mac ─► lorawan_handler ─► connector
lora_mesh       node    ─► lora_mesh_node       ─► lora_mesh_router  ─►  (firmware)  ─► lora_mesh_handler ─► connector
```

| lorawan-server | lora_mesh | Job |
|---|---|---|
| `lorawan_gw_forwarder` (one per protocol, many gateways) | `lora_mesh_node` (one per bridge) | Radio-side socket, wire → records |
| `lorawan_gw_router` (`deduplication_delay`) | `lora_mesh_router` (`dedup_ms`) | Collect copies from all gateways/bridges, publish once |
| `lorawan_mac` | none | Decryption, integrity, counters: done by the node firmware |
| `lorawan_handler` | `lora_mesh_handler` | Decode the application payload |
| `lorawan_db` device/node tables (Mnesia) | `lora_mesh_registry` (ETS) | What we know about each end device |
| `lorawan_connector_mqtt` | `lora_mesh_connector_mqtt` | MQTT in and out |
| gateways found by MAC address | bridges found through `pg` | How the router side reaches the radio side |

| lorawan-server record | lora_mesh record | Holds |
|---|---|---|
| `#rxq{}` | `#mesh_rxq{rx_snr, rx_rssi, hop_start, hop_limit, via_mqtt}` | Radio data of one reception |
| `#frame{}` | `#mesh_rx{from, to, channel, id, rxq, bridges, text}` | One received message |
| `#txdata{}` | `#mesh_tx{to, channel, text}` | One message to send |
| `#node{}` / `#device{}` | `#mesh_node{num, id, long_name, short_name, hw_model, role, position, battery_level, voltage, last_heard, heard_by}` | One end device |
| per-gateway reception data | `#mesh_heard{bridge, rxq, at}` | One bridge hearing one node |

### Why ETS and not Mnesia

The registry rebuilds itself: when a bridge connects, its node sends its whole node database (`node_info`),
which seeds the table. History worth keeping (messages, positions, telemetry over time) belongs in a store
such as PostgreSQL, which is stage 4.

## How deduplication works

A Meshtastic packet is identified by `{From, Id}`: the sender picks a random 32-bit id for every packet.

1. The first copy opens a window of `dedup_ms` (200 ms by default).
2. Copies from other bridges inside the window are collected (`duplicates` counter).
3. When the window closes, the copies are sorted: highest `rx_snr` first, then fewest hops
   (`hop_start - hop_limit`). The best one is handled; the list of bridges goes into `#mesh_rx.bridges`
   and every bridge's reception goes into the sender's `heard_by`.
4. Copies arriving later (kept for 60 s) only update `heard_by` (`late` counter).
5. A packet with id 0 cannot be deduplicated and is passed straight on.

`lora_mesh_router:stats()` returns `#{published, duplicates, late}`.

## Configuration

```erlang
{lora_mesh,
 [{role, full},                                   % full | bridge
  {bridges, [#{id => home, host => "192.168.1.50"},
             #{id => hill, host => "100.64.0.12"}]},  % e.g. over Tailscale
  {dedup_ms, 200},
  {mqtt, #{host => "localhost", port => 1883, prefix => <<"mesh">>}}]}
```

- **`role full`** runs registry, router, MQTT connector and the listed bridges.
- **`role bridge`** runs only the bridges. Put it on a small machine next to a node (a Pi, a VPS), join it to
  the cluster (same cookie, `-sname`, Tailscale as in your pg cluster plan), and its bridges find the router
  through `pg`. Bridges send to a router on their own Erlang node if there is one, else to any in the cluster;
  `send/1` likewise prefers a local bridge. Multi-node use has not been tested yet; all tests run the
  bridges and router on one Erlang node.

## MQTT

| Topic | Direction | Payload |
|---|---|---|
| `mesh/rx/<from>` | out | text message, best copy, plus `bridges` |
| `mesh/node/<id>` | out, **retained** | the node's registry record, updated on every change |
| `mesh/tx` | in | `{"text": "...", "to": "!a1b2c3d4", "channel": 0, "bridge": "hill"}`; only `text` is required. `to` may be `"@a1a2a3a4a5a6"` (MeshCore); `"protocol": "meshcore"` or `"meshtastic"` picks the mesh for a broadcast |

```
mesh/rx/!0a0b0c0d {"id":99,"text":"哈囉 from mesh","bridges":["hill","home"],"channel":0,"to":"!ffffffff","from":"!0a0b0c0d","rxq":{"hop_limit":2,"via_mqtt":false,"rx_snr":8.5,"rx_rssi":-90,"hop_start":3}}

mesh/node/!0a0b0c0d {"id":"!0a0b0c0d","num":168496141,"long_name":"Hill top","short_name":"HILL","hw_model":"HELTEC_V3","role":"CLIENT","position":{"latitude":24.1477,"longitude":120.6736,"altitude":85,"time":0},"battery_level":null,"voltage":null,"last_heard":1793187882,"heard_by":{"home":{"at":1793187882,"rxq":{...,"rx_snr":5.0}},"hill":{"at":1793187882,"rxq":{...,"rx_snr":8.5}}}}
```

Without `"bridge"`, a direct message goes out through any bridge of the destination's mesh, a broadcast
through any bridge (or any of `"protocol"`), one on this Erlang node first. Choosing the *best* bridge
automatically, from `heard_by`, is stage 3.

MeshCore records have two more fields:

```
mesh/rx/@b1b2b3b4b5b6 {"id":1761700002,"protocol":"meshcore","text":"rain at the north gate","bridges":["field"],"channel":0,"rxq":{"rx_snr":-3.0,"rx_rssi":0,"hop_start":1,"hop_limit":0,"via_mqtt":false},"from":"@b1b2b3b4b5b6","to":"!ffffffff","sender_name":"Bob"}

mesh/node/@a1a2a3a4a5a6 {"id":"@a1a2a3a4a5a6","protocol":"meshcore","num":459194878961062,"long_name":"Alice","role":"chat","position":{"latitude":25.047,"longitude":121.517,...},"last_heard":1793240961,"heard_by":{"field":{...}},...}
```

## Erlang API

```erlang
lora_mesh_node:send(#mesh_tx{to = 16#a1b2c3d4, text = "hi"}).    % any bridge
lora_mesh_node:send(hill, #mesh_tx{text = "hello everyone"}).     % that bridge
lora_mesh_node:send(#mesh_tx{to = lora_mesh_meshcore:num_from_hex(<<"a1a2a3a4a5a6">>),
                             text = "hi"}).                       % a MeshCore node
lora_mesh_node:send_protocol(meshcore, #mesh_tx{text = "hi all"}).% MeshCore channel 0
lora_mesh_node:bridges().                                         % [hill, home]
lora_mesh_registry:lookup(16#0a0b0c0d).                           % {ok, #mesh_node{}}
lora_mesh_registry:all().
lora_mesh_router:stats().
```

## MeshCore

A MeshCore **companion radio** (the firmware the MeshCore phone app talks to) is the computer's way into a
MeshCore mesh. `lora_mesh_meshcore` speaks its serial protocol, taken from
`examples/companion_radio/MyMesh.cpp` (firmware v1.18, protocol 14), and hands the router the same
`#mesh_rx{}` records a Meshtastic bridge does. Everything after the bridge is shared.

```
 companion ─USB serial─► lora_mesh_meshcore (bridge field) ─┐
 companion ─TCP 5000──► lora_mesh_meshcore (bridge barn)  ─┤
 Meshtastic node ─4403─► lora_mesh_node    (bridge home)  ─┴─► lora_mesh_router ─► registry, MQTT
```

| Flash this firmware | Connect with |
|---|---|
| Companion **USB** (`companion_radio_usb`) | `transport => serial, device => "/dev/ttyUSB0"` (115200 baud) |
| Companion **Wi-Fi** (`companion_radio_wifi`) | `transport => tcp, host => "192.168.1.60"` (port 5000) |

The BLE companion firmware is for phones; lora_mesh does not speak Bluetooth. One radio has one app
connection: while lora_mesh is connected, the phone app cannot use that radio.

### What the bridge does

1. **Start:** `DEVICE_QUERY` (asks for protocol 3, so messages carry SNR), `APP_START` (the radio answers
   with its own key and name), `SET_DEVICE_TIME` from the computer clock (refused, harmlessly, if the radio
   is ahead), `GET_CONTACTS`, then a first message sync.
2. **Contacts** go into the registry: name, type (`chat`, `repeater`, `room`, `sensor`) as `role`,
   position, last advert. A new advert heard on air arrives at once (`PUSH_NEW_ADVERT`); a known node's advert
   makes the bridge fetch only the contacts changed since the last fetch (`GET_CONTACTS since`).
3. **Messages** wait in the radio until asked for: on `PUSH_MSG_WAITING` the bridge sends
   `SYNC_NEXT_MESSAGE` until the radio says `NO_MORE_MESSAGES`. Messages received while lora_mesh was away are
   collected on reconnect.
4. **Commands** go one at a time with a 5 s answer timeout, as the firmware expects. If the link drops, the
   bridge reconnects every 1 s, doubling to 30 s.

### Ids

| Mesh | Id | Registry number |
|---|---|---|
| Meshtastic | `!0a0b0c0d` (node number) | the 32-bit node number |
| MeshCore | `@a1a2a3a4a5a6` (first 6 bytes of the public key, as the firmware uses) | `1 bsl 48` + those 48 bits |

Bit 48 keeps the two kinds apart in one registry, one router and one MQTT topic tree. `#mesh_rx.protocol` and
`#mesh_node.protocol` say which mesh a record came from.

### Direct and channel messages

- **Direct:** the radio gives the sender's key prefix, so `from` is exact. `to` is the radio's own id.
- **Channel:** MeshCore carries `"<name>: <text>"` with no key. The bridge splits off the name into
  `sender_name` and looks it up among the contacts: if exactly one contact has that name, `from` is its id;
  otherwise `from` is `"?"`.
- **Radio data:** MeshCore reports SNR but no RSSI (`rx_rssi` is 0). Hops go into `hop_start` (with
  `hop_limit` 0), so `hop_start - hop_limit` means "hops taken" for both meshes; a message that came by a
  direct (source) route counts as 0.
- **Deduplication:** a MeshCore message has no packet id, so the router key is the sender (key prefix for
  direct, name for channel), the sender's timestamp and the text. Two bridges hearing the same channel message
  publish it once, best SNR first, as with Meshtastic. The channel slot number is not in the key, because two
  radios can keep the same channel in different slots.

### Sending

| `to` | Goes |
|---|---|
| a MeshCore number / `"@a1a2a3a4a5a6"` | direct message through a MeshCore bridge; the radio must have that node as a contact |
| broadcast with `"protocol": "meshcore"` | channel `channel` (slot number on the radio, 0 = Public) through a MeshCore bridge |
| broadcast with `"bridge": "field"` | that bridge's mesh |

Limits come from the firmware: 160 bytes for a direct message (`MAX_TEXT_LEN`), and for a channel
message the radio's name plus `": "` count against the same 160. Errors: `too_long`, `not_found` (unknown
contact or channel slot), `wrong_protocol` (a Meshtastic number given to a MeshCore bridge, or the other
way), `not_connected`, `timeout`.

### Config

```erlang
{bridges, [#{id => home, host => "192.168.1.50"},                        % Meshtastic, TCP 4403
           #{id => field, type => meshcore, transport => serial,
             device => "/dev/ttyUSB0"},                                  % MeshCore, USB
           #{id => barn, type => meshcore, transport => tcp,
             host => "192.168.1.60"}]}.                                  % MeshCore, Wi-Fi 5000
```

Serial needs `stty` and `cat` (standard on Linux) and permission to open the device: add the user that runs
lora_mesh to the `dialout` group (`sudo usermod -aG dialout lora_mesh`). Opening a USB port resets many boards,
so the bridge waits 2 s (`start_delay_ms`) before its first command. Use a stable name such as
`/dev/serial/by-id/usb-...` when several radios are plugged in.

### Not yet

Signed and CLI text types are received as text; room servers, repeater administration, telemetry and
binary data, adding contacts, and channel management are not handled. Use the phone app (on another radio)
for those.

## Demo without radios

Two demos, both started from `rebar3 as test shell --start-clean`:

| Demo | Fake radios | Start |
|---|---|---|
| Meshtastic only | two Heltec V4 boards with Wi-Fi, "home" and "hill" | `lora_mesh_demo_meshtastic:start().` |
| Mixed | two MeshCore companions and one Meshtastic node | `lora_mesh_demo:start().` |

The **Meshtastic demo** (`test/lora_mesh_demo_meshtastic.erl`) imitates two boards in one mesh of Hill top,
School, Farm (a sensor), Tracker and, later, Dave. It cycles through: a broadcast from Hill top heard by both
boards (published once, `bridges` lists both); battery telemetry from Farm and positions from Tracker (they
update `mesh/node/...`, not `mesh/rx`); a direct message from School to the home board; "ping?" for a bot;
and once a new node, Dave (NODEINFO). A node sent a direct message answers "got it: ...".
Stop it with `lora_mesh_demo_meshtastic:stop().`

The **mixed demo** (`test/lora_mesh_demo.erl`) runs lora_mesh against fake radios: two MeshCore companions ("field", "barn")
and one Meshtastic node ("home"), with named nodes (Alice, Bob, Pump, Ridge, Hill top, School). Every few
seconds a scripted message arrives; teammates watch and reply from their laptops over MQTT.

```sh
rebar3 as test shell --start-clean
1> lora_mesh_demo:start().                        % broker on localhost:1883
1> lora_mesh_demo:start(#{mqtt_host => "localhost", mqtt_port => 1883, every_ms => 8000}).
2> lora_mesh_demo:stop().
```

The script cycles through: a direct message from Alice; a channel message from Bob heard by both MeshCore
radios (published once, `bridges` lists both); a Meshtastic broadcast from Hill top; a 2-hop report from
Pump; "ping?" from Bob for a bot to answer; and once a new node, Dave. Anything sent to a node gets
"got it: ..." back from it, and every send is printed in the shell.

Teammates use the Python client (`examples/demo_bot.py --host <pi> --name <them>` answers "ping").
For their laptops to reach the broker, Mosquitto must listen on the network, for example
`/etc/mosquitto/conf.d/lan.conf` with `listener 1883 0.0.0.0` and `allow_anonymous true` (local network only).

## Running the release (no Erlang needed)

`lora_mesh-0.3.0.tar.gz` contains everything: the Erlang runtime, all libraries and a start script.

```sh
sudo mkdir -p /opt/lora_mesh
sudo tar xzf lora_mesh-0.3.0.tar.gz -C /opt/lora_mesh
sudo nano /opt/lora_mesh/etc/lora_mesh.config     # your nodes and broker
/opt/lora_mesh/bin/lora_mesh foreground            # run; Ctrl+C to stop
```

| Command | Does |
|---|---|
| `bin/lora_mesh foreground` | Run in this terminal, logs on screen |
| `bin/lora_mesh daemon` | Run in the background |
| `bin/lora_mesh ping` | `pong` if it is running |
| `bin/lora_mesh stop` | Stop it |
| `bin/lora_mesh remote_console` | Erlang shell inside the running system (`lora_mesh_router:stats().`) |

**Settings** live in `etc/lora_mesh.config` (Erlang terms, one per line). Set `LORA_MESH_CONFIG=/path/file`
to use another file. Restart after editing.

**As a service:** `etc/lora_mesh.service` is a systemd unit for `/opt/lora_mesh`:

```sh
sudo useradd -r -d /opt/lora_mesh -s /usr/sbin/nologin lora_mesh
sudo chown -R lora_mesh /opt/lora_mesh
sudo cp /opt/lora_mesh/etc/lora_mesh.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lora_mesh
journalctl -u lora_mesh -f
```

**Where a release runs.** The bundled runtime is compiled for the machine that built it:

| Built on | Runs on |
|---|---|
| Ubuntu 24.04, x86-64 (the delivered tarball) | x86-64 Linux with glibc 2.38+: Ubuntu 24.04+, Debian 13+ |
| Raspberry Pi OS Bookworm / Debian 12, aarch64 | Raspberry Pi 4/5 with Bookworm or newer |

Build on the **oldest** system you want to support; the result also runs on newer ones. It also needs
OpenSSL 3 (`libcrypto.so.3`), standard on all of the systems above.

### Building a release

On the target kind of machine (for example the Pi), with OTP 27+ and rebar3 installed and `proto/` filled
as in Setup:

```sh
rebar3 as prod tar
# -> _build/prod/rel/lora_mesh/lora_mesh-0.3.0.tar.gz
```

The release contains compiled code only. lora_mesh is GPL-3.0 (it is built on Meshtastic's GPL-3.0
definitions), so when you give the tarball to others, give them this source too, for example the
project zip alongside it.

## Setup (development)

Needs OTP 27+.

```sh
# list your nodes under bridges in config/sys.config
rebar3 shell
```

- `proto/` already holds the Meshtastic `.proto` files from
  [meshtastic/protobufs](https://github.com/meshtastic/protobufs) at commit 569a2b3 (GPL-3.0, licence in
  `proto/LICENSE.meshtastic-protobufs`), matching `include/meshtastic/*.hrl`. To move to newer ones, copy
  `nanopb.proto` and `meshtastic/` from a newer checkout over them and regenerate the `.hrl` files (below).

- `rebar.config.script` sets `BUILD_WITHOUT_QUIC=1`, so emqtt skips its QUIC NIF (quicer). emqtt is a git dependency for this reason: a Hex emqtt would pull quicer regardless. gun 2.1.0 and cowlib 2.13.0 are pinned because newer gun on Hex has a version rule rebar3 cannot read.
- The first build generates `src/meshtastic_pb.erl` for all 28 `.proto` files in record mode (about 7 MB,
  about 2 minutes to compile here). gpb warns about a `map()` type from `device_ui.proto`'s `Map` message;
  it is harmless.
- `include/meshtastic/*.hrl` match protobufs commit 569a2b3. After copying newer `.proto` files, regenerate them:

  ```sh
  erlc -o tools tools/split_hrl.erl
  erl -noshell -pa tools -pa _build/default/plugins/gpb/ebin -eval 'split_hrl:all(), halt().'
  ```

## Tests

```sh
rebar3 eunit
```

54 tests:

- `lora_mesh_router_tests`: three bridges hear one packet → one publish, best copy, all three in
  `heard_by`; a late copy; id 0; NODEINFO, POSITION and TELEMETRY filling the registry; seeding from `node_info`.
- `lora_mesh_bridges_tests`: two bridges over real TCP to two fake nodes hearing the same packet.
- `lora_mesh_node_tests`: one bridge: config request, forwarding to the router, `send/2` by id, the
  233-byte limit.
- `lora_mesh_connector_mqtt_tests`, `lora_mesh_frame_tests`.
- `lora_mesh_meshcore_tests`: the MeshCore codec on hand-made bytes (frames, resync, every command and
  response used), ids and `"@..."` parsing; then the bridge against `lora_mesh_fake_companion`:
  - over TCP: contacts into the registry, the startup command order, a direct message with SNR and hops,
    two queued channel messages (one from a known name, one not), DM and channel sends, every send error,
    a new advert, a changed advert (`GET_CONTACTS since`), the radio dropping and the bridge reconnecting and
    collecting what arrived meanwhile;
  - two MeshCore bridges hearing the same channel message in different slots: published once, best SNR;
  - over serial: a pseudo-terminal from `test/meshcore_pty.py` stands in for `/dev/ttyUSB0`.

`test/lora_mesh_fake_companion.erl` is a MeshCore companion written from the firmware source
(`MyMesh.cpp`), byte by byte and without the codec, so the codec is checked against a separate reading of
the firmware. It is not the firmware: try a real radio before relying on it in the field.

Also run end to end with Mosquitto, a fake Meshtastic node and a fake MeshCore companion side by side, and
the Python client sending to `@...` and `!...` ids; and the 0.3 release tarball, run with no Erlang on
`PATH`, over the serial pseudo-terminal. Earlier, with two fake Meshtastic nodes: one `mesh/rx` publish with both bridges, a retained
`mesh/node` record with name, hardware, position and `heard_by`, and `"bridge":"hill"` delivered through
that bridge only.

## Known limits

- The registry's MQTT updates are sent on every change, including each "heard" update. Fine for a small mesh;
  a busy one would want rate limiting.
- If the broker is not connected yet, uplinks are dropped with a warning; the registry still updates and is
  republished on the node's next change.
- `send/1` picks any bridge of the right mesh, not the best one (stage 3).
- MeshCore channel messages are matched to a sender by name only; two contacts with the same name give
  `from = "?"`.
