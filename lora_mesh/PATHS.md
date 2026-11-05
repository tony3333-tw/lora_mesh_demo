# Paths: repeaters, routers and routes (lora_mesh 0.3.2)

From 0.3.2, lora_mesh says which repeaters (MeshCore) and routers (Meshtastic) a message passed,
not only how many hops it took. Nothing needs configuring: the radios already send this; earlier
versions ignored it.

## What is recorded

| Where | Field | Mesh | Meaning |
|---|---|---|---|
| every message, `mesh/rx/<id>` → `rxq` | `path` | MeshCore | every repeater the message passed, first one first. `[]` = heard straight from the sender. `null` = not known |
| every message, `mesh/rx/<id>` → `rxq` | `relay` | Meshtastic | the last node that rebroadcast it. `null` = not relayed, or not known |
| every node, `mesh/node/<id>` → `heard_by.<bridge>.rxq` | `path`, `relay` | both | the same, for the last packet each bridge heard from that node |
| every node, `mesh/node/<id>` | `routes` | MeshCore | per bridge: the route that bridge's radio uses to reach the node, first hop first. `[]` = in radio range. No entry = no route yet (the radio floods) |

A hop is `{"hash": "d1", "name": "Ridge"}`. The radios identify a repeater only by a short hash.
lora_mesh fills in `name` when exactly one known node matches, and leaves it `null` otherwise.

```json
"rxq": {"rx_snr": 2.0, "hop_start": 2, "hop_limit": 0,
        "path": [{"hash": "d1", "name": "Ridge"}, {"hash": "77", "name": null}],
        "relay": null}

"routes": {"field": [{"hash": "d1", "name": "Ridge"}, {"hash": "77", "name": null}],
           "barn": []}
```

The Python client (0.2.2) has `msg.rx.path`, `msg.rx.relay`, `msg.rx.path_text` (`"Ridge > 77?"`)
and `node.routes`. The Erlang/LFE examples print the same text (`lmc:path_text/1`, `lmc:route_text/1`).

## Where it comes from

**MeshCore.** Each repeater that floods a packet on adds a hash of itself to the packet: the
first 1–4 bytes of its public key (`Mesh.cpp`). The companion radio pushes every packet it hears
to lora_mesh (`PUSH_CODE_LOG_RX_DATA`, 0x88, raw packet with its path). It also pushes copies it
later drops as duplicates. When the bridge then fetches a message, it picks the RX log entry
that belongs to it:

- **Direct message:** a `TXT_MSG` packet whose sender hash and destination hash match the
  message's sender and this radio.
- **Channel message:** a `GRP_TXT` packet.

In both cases the entry must also have exactly the message's `path_len` byte, and the earliest
unused match wins. The copy a radio delivers is the first one it heard; copies relayed further
have longer paths, so they don't match.

A contact's route is its stored `out_path`, part of every contact listing (`GET_CONTACTS`). It is
the route the radio uses to send to that contact. It is learned from replies (`PATH_UPDATED`), so
it can differ per bridge.

**Meshtastic.** A packet carries only `relay_node`, the last byte of the node number of the last
node that rebroadcast it (firmware 2.6 and later). The rest of the path is not recorded by the
radio. A full route needs a traceroute, which lora_mesh does not send yet.

## Limits

- **Short hashes collide.** With 1-byte hashes, two repeaters can share `d1`. lora_mesh prefers
  the node that relays (MeshCore repeater or room server, Meshtastic router roles). If that still
  leaves more than one, `name` stays `null` and clients show `d1?`. MeshCore nodes can be set
  to send larger path hashes (`path_hash_mode`), which makes this rare; lora_mesh reads any
  hash size (1–4 bytes).
- **Direct-routed messages have no path on arrival.** Every repeater on a MeshCore direct route
  removes itself, so `path` is `null`. The node's `routes` shows the way back instead.
- **Channel messages** are matched by kind and path length only. lora_mesh does not read channel
  keys, so it cannot use the channel hash. Two channel messages heard within the same second over
  equally long but different paths could swap paths. The text, sender and hop count are never
  affected.
- **Names come from known nodes.** A repeater lora_mesh has never seen (no advert, not in any
  radio's contacts) stays a hash. Names are filled in again when a message or node is published,
  so a repeater learned later gets its name on the next update.

## Try it without radios

The mixed demo has paths: `DEMO=mixed ./lora_demo.sh`. Some examples you will see:

- Field gw reaches Alice through the repeater Ridge (`d1`).
- Pump's reports pass Ridge and an unknown repeater `77`.
- Barn gw hears Bob directly.
- The Meshtastic router Tower relays Hill top's broadcasts.

```
Pump to me: pump on, flow 12 L/min   (Ridge > 77?, heard by barn)
Hill top on #0: temperature 24.4 C   (last relay Tower, heard by home)
```

`lme contacts --all` shows the routes column. The Meshtastic-only demo (`./lora_demo.sh`) has no
relays: its fake boards hear every node directly.
