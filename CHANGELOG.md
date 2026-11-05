# Changelog

What changed in each tagged version of this repository. The newest is first.

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
