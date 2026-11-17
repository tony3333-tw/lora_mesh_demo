# Changelog

What changed in each tagged version of this repository. The newest is first.

## 0.4.1 — 2026-11-17

### Fixed

- lora_mesh's tests could fail on slower machines (e.g. a Raspberry Pi), usually with 10
  failures starting at `lora_mesh_meshcore_tests:tcp_bridge/0`. Three tests read the node
  registry right after an uplink, but the registry is updated by a cast. They now wait for
  the node (`wait_node/2`) in `lora_mesh_meshcore_tests` and `lora_mesh_bridges_tests`.
  lora_mesh itself is unchanged (still 0.4.0).

### Notes

- The plan moves up one step: requests through lora_mesh (`traceroute`, `request`, `send`,
  `foxhunt`, the ACK for `dm`) are now 0.4.2, and admin (off by default) is 0.4.3.

### Tests

- lora_mesh: 71 eunit tests. Run 5 times in a row on a Raspberry Pi 4.

## 0.4.0 — 2026-11-05

### Added

- lora_mesh 0.4.0, four new MQTT topics:
  - `mesh/packet/<from>`: every packet the bridges hear, whatever its port, decoded (text,
    position, user, telemetry, routing, neighbor info, ...), with `bridges`. Meshtastic only.
  - `mesh/bridge/<id>/info` (retained): what each bridge's radio said when it connected. For
    Meshtastic its my info, metadata, channels, config and module config; for MeshCore its id,
    name, firmware and position.
  - `mesh/bridge/<id>/status` (retained): whether each bridge is connected, and why not.
  - `mesh/status` (retained): whether lora_mesh is up. The broker's last will sets it to
    `{"online": false}` if lora_mesh stops without saying goodbye.
- `show_secrets` in lora_mesh's config (`false` by default): channel keys, the Wi-Fi password,
  the radio's private key and other secrets are left out of `mesh/bridge/<id>/info`.
- `meshtastic_examples/` 0.3.0: six examples back, as clients of lora_mesh: `packets` (`--raw`,
  `--json`, `--log FILE`, `--counts`), `myinfo`, `local-stats`, `channels`, `preset` and
  `watchdog`, in Erlang and LFE. 16 examples in all.

### Notes

- The 10 examples of 0.3.4 still work with lora_mesh 0.3; the six new ones need 0.4.0.
- Coming next: 0.4.1 (requests through lora_mesh: `traceroute`, `request`, `send`, `foxhunt`,
  the ACK for `dm`) and 0.4.2 (admin, off by default).

### Tests

- lora_mesh: 71 eunit tests, 7 of them new (`cd lora_mesh && rebar3 eunit`).
- meshtastic_examples: 8 eunit tests. Every example was run against lora_mesh's Meshtastic
  demo in both languages, and `watchdog` through a lora_mesh crash and restart.

### Known issue

- `rebar3 eunit` in `lora_mesh` can fail on slower machines (e.g. a Raspberry Pi), usually
  with 10 failures starting at `lora_mesh_meshcore_tests:tcp_bridge/0`. It's a timing race in
  the tests, not in lora_mesh. Fixed in 0.4.1.



## 0.3.4 — 2026-11-05

### Changed

- `meshtastic_examples/` 0.2.0 uses **lora_mesh as its backend**: the examples are MQTT
  clients of lora_mesh, on your own broker, and nothing goes to mqtt.meshtastic.org. lora_mesh
  keeps the only connection to each radio, so the examples no longer take a radio away from
  it.
- 10 examples work with lora_mesh 0.3 as it is: `messages`, `autoresponder`, `chat`, `dm`,
  `nodedb`, `decode`, `protos`, `mqtt-receive`, `mqtt-send`, `mqtt-client`.
- `dm` waits for a reply from the node instead of the ACK, because lora_mesh 0.3 does not
  pass ACKs on.

### Removed

- The direct radio client, the fake radio, the Meshtastic MQTT encryption, and the 14
  examples that need topics lora_mesh does not have yet. They are in 0.3.3. The plan for
  bringing them back with lora_mesh 0.4 is in `meshtastic_examples/README.md`.

### Tests

- 7 eunit tests (`cd meshtastic_examples && rebar3 eunit`); every example was run against
  lora_mesh's Meshtastic demo in both languages.

## 0.3.3 — 2026-11-05

### Added

- `meshtastic_examples/` 0.1.0: the examples of
  [Meshtastic-Python-Examples](https://github.com/pdxlocations/Meshtastic-Python-Examples)
  in Erlang and LFE, run with `mte`: 24 examples covering the 42 Python scripts. They talk
  to one radio directly (TCP port 4403), or to a Meshtastic MQTT broker.
- `mte fake-radio`: a pretend radio with a four-node mesh, to try the examples without
  hardware.
- 9 eunit tests (`cd meshtastic_examples && rebar3 eunit`).

### Notes

- A radio serves one app connection at a time, so these examples knock lora_mesh off a radio
  it is using: use a radio lora_mesh is not using, or stop lora_mesh first.
- `admin-keys` ships no default keys, and `mqtt-send` sends "Hello from Erlang" as its test
  text.

## 0.3.2 — 2026-11-04

### Added

- lora_mesh 0.3.2: repeater paths (MeshCore) and the last relay (Meshtastic) in every
  message's `rxq`, and each bridge's route to a node in `mesh/node/<id>`. See
  `lora_mesh/PATHS.md`.
- lora_mesh_client 0.2.2: `msg.rx.path`, `msg.rx.relay`, `msg.rx.path_text`.

### Changed

- `lora_mesh_examples/` shows the paths: `pingbot` answers with the repeaters a message came
  through, `contacts` lists each gateway's route to a node, and `monitor` reports routes
  changing. The examples still work with lora_mesh 0.3.0, without the repeater names.

## 0.3.1 — 2026-11-03

### Added

- `lora_mesh_examples/`: the examples of
  [meshcore_py](https://github.com/meshcore-dev/meshcore_py/tree/main/examples) in Erlang
  and LFE, run with `lme`: `contacts`, `infos`, `msg`, `readmsgs`, `chat`, `pingbot` and
  `monitor`. They are MQTT clients of lora_mesh 0.3, so they work with every bridge it has
  (MeshCore and Meshtastic) and need no change to lora_mesh. MIT licence.

### Notes

- lora_mesh stays at 0.3 and lora_mesh_client at 0.2.1.

## 0.3.0

### Added

- lora_mesh 0.3: a MeshCore bridge for companion radios over USB serial or Wi-Fi, into the
  same router, registry and MQTT topics as Meshtastic.
- A release tarball that runs without Erlang installed.

## Earlier

- Stage 1: the node registry, published to MQTT as retained JSON.
- Stage 2: several Meshtastic bridges and a router that merges copies of the same packet.
