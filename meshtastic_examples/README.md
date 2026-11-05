# meshtastic_examples

The examples of [Meshtastic-Python-Examples](https://github.com/pdxlocations/Meshtastic-Python-Examples)
(pdxlocations, commit 3c56832), rewritten in **Erlang** (`src/mte_*.erl`) and **LFE**
(`src/mtl_*.lfe`).

The Python examples talk to one radio through the `meshtastic` library, or to a Meshtastic MQTT
broker. These do the same, without Python:

```
radio ── TCP 4403 ── mte (these examples)        like TCPInterface(hostname=...)
radios ── MQTT broker ── mte mqtt-*              like the MQTT/ examples (paho)
```

lora_mesh is not needed. The radio examples use the radio's client API (TCP port 4403), the
same one lora_mesh's Meshtastic bridges use. `lora_mesh_examples/`, by contrast, are MQTT clients
of lora_mesh.

**One client per radio.** A radio serves one client API connection at a time: when an example
connects, the radio closes its previous connection (lora_mesh's bridge to it, or the phone app
over WiFi). The previous client then reconnects and closes ours in turn. Run these examples on a
radio lora_mesh is not using, or stop lora_mesh first.

**TCP only.** The radio has to be on the network: WiFi (Heltec V3/V4, T-Beam, ...) or Ethernet,
switched on in the app's network settings. USB serial and Bluetooth, which the
Python examples can also use, are not supported here.

## Build and run

Needs Erlang/OTP 27+ and rebar3, like lora_mesh. The first build fetches emqtt, LFE and the gpb
and LFE rebar3 plugins, and generates the large Meshtastic protobuf module `src/mt_pb.erl` from
`proto/`. As with lora_mesh, that compile takes several minutes on a Raspberry Pi.

```sh
cd meshtastic_examples
rebar3 escriptize                 # -> _build/default/bin/mte, one file
cp _build/default/bin/mte ~/bin/  # optional

mte                               # list of examples
mte nodedb --host 192.168.1.42    # Erlang version, a radio on WiFi
mte nodedb --host 192.168.1.42 --lfe
```

### Without a radio: the fake radio

`mte fake-radio` is a pretend radio on port 4403, so every radio example can be tried without
hardware. Its mesh has four nodes:

| node | id | |
|---|---|---|
| Pi Gateway | `!1a2b3c4d` | the radio itself |
| Tower | `!0d0d0dee` | ROUTER, heard directly |
| Barn sensor | `!2a2a2a2a` | SENSOR, heard directly |
| Hill top | `!60c0ffee` | heard through Tower (1 hop) |

```sh
mte fake-radio                    # terminal 1: listens on localhost:4403, logs what it gets
mte nodedb                        # terminal 2
mte packets --lfe
mte request -d "Hill top" --what position
mte traceroute -d hill
```

The fake mesh sends a packet every few seconds: texts, positions, telemetry, node info, neighbor
info, a paxcounter, a range test, a store-and-forward heartbeat, and the radio's own statistics.
It ACKs direct messages, answers telemetry, position, node info and traceroute requests, replies
"got it: ..." to a direct text, and applies admin messages (channels, config) until it is
stopped. Requests to a node it doesn't know fail with `MAX_RETRANSMIT`. Like a real radio, it
serves one client at a time. Options: `--port N`, `--every S` (seconds between packets, 5).

## The examples

Radio examples take `--host H` (localhost) and `--port N` (4403). `-d NODE` is a name ("Hill top",
"hill"), an id (`!60c0ffee`) or a number (`1623194643`). Add `--lfe` to any example to run the
LFE version.

| `mte` example | Python examples | Options |
|---|---|---|
| `messages` | print-messages.py, get-all-messages.py | `--seconds S` stops after S s |
| `autoresponder` | autoresponder.py, send-secondary.py | `-m TEXT`, `-c N` (channel 1 = send-secondary) |
| `chat` | send-and-receive.py | `-d NODE` or `-c N` |
| `dm` | send-direct-message.py | `-d NODE -m TEXT`, `--wait S` |
| `packets` | print-packets.py, print-packets-basic.py, print-packets-json.py, print-packets-json-log.py, print-packets-json-log-and-plot.py | none, `--raw`, `--json`, `--log FILE`, `--counts` |
| `local-stats` | get-local-stats.py | |
| `myinfo` | print-myNodeInfo | |
| `nodedb` | print-nodedb.py | `--json` |
| `channels` | get-channels.py | |
| `preset` | get-config-modem-preset.py | |
| `traceroute` | send-traceroute-simple.py, print-traceroute.py | `-d NODE`, `--hop-limit N` |
| `request` | request-telemetry-simple.py, request-enviroment-metrics.py, request-position.py, request-nodeinfo.py | `-d NODE --what telemetry\|environment\|position\|nodeinfo\|local_stats\|power` |
| `send` | send-position.py, send-nodeinfo.py, send-device-metrics.py, send-environment-metrics.py, send-telemetry.py, send-waypoint.py | `--what position\|nodeinfo\|device\|environment\|telemetry\|waypoint`, `--lat --lon --alt`, `-c N`, `-d NODE` |
| `foxhunt` | foxhunt.py, test-rssi-snr.py | `-d NODE`, `--pause S`, `--wait S` |
| `watchdog` | tcp_watchdog.py | `--every S` |
| `save-channel` | save-channel.py | `--index N --name NAME --psk BASE64` |
| `admin-keys` | save-admin-keys.py | `--keys K1,K2` or `--clear` |
| `set-url` | set-URL.py | `--url URL` (without: print the URL) |
| `decode` | decode-protobuf.py | `--hex HEX` or `--base64 B64`, `--type MSG` |
| `protos` | list-protos.py | |

MQTT examples take `--broker H` (mqtt.meshtastic.org), `--mqtt-port N` (1883), `--username U`
and `--password W` (the public broker's meshdev / large4cats), `--root TOPIC`,
`--channel-name NAME` (LongFast) and `--key BASE64` (AQ==, the default key).

| `mte` example | Python example | |
|---|---|---|
| `mqtt-receive` | MQTT/receive-mqtt-packets.py | prints every packet, decrypted; `--topic T1,T2` |
| `mqtt-send` | MQTT/send-mqtt-packets.py | publishes node info, position, text as "Bottastic"; `-m TEXT`, `--pause S` |
| `mqtt-client` | MQTT/mqtt-client.py | both: publishes, then prints the channel |
| `radio-mqtt` | MQTT/serial-mqtt.py | radio → JSON on `msh/sMQTT/2/json/LongFast/!deadbeef`; broker localhost |

Topics: the Python examples use `msh/US/2/e/` to receive and `msh/US/Bots/2/e/` to send. In
Taiwan, radios publish under `msh/TW/2/e/` (`--root msh/TW/2/e/`). Keep test packets on the Bots
topic, and on the public broker remember that radios download them and put them on the air.

Try the MQTT examples locally with Mosquitto, no radio needed:

```sh
mte mqtt-receive --broker localhost --root msh/US/Bots/2/e/     # terminal 1
mte mqtt-send --broker localhost -m "hello"                     # terminal 2
```

From the Erlang shell instead of the escript:

```
rebar3 shell
1> mte:main(["nodedb", "--lfe"]).
2> C = mtc:connect(#{host => "192.168.1.42"}).
3> mtc:send_text(C, "hello", #{}).
```

## Configuration examples change the radio

`save-channel`, `admin-keys` and `set-url` write to the radio, as their Python originals do.
`set-url` also sets the LoRa region and preset of the URL, and the radio may restart.
`admin-keys` has no default keys: save-admin-keys.py ships three keys that would give their
owners admin rights over your radio.

## What is different from the Python examples

- **Packets are maps** with snake_case atom keys: `rx_snr`, not `rxSnr`. Unset fields are left
  out, as in Python's dicts: `maps:get(rx_snr, P, 0.0)` or `mtc:get(P, [decoded, telemetry], #{})`.
  Positions have `latitude`/`longitude` in degrees next to `latitude_i`/`longitude_i`.
- **Answers are waited for**, not slept after: `dm` waits for the ACK (or NAK), and `request` and
  `traceroute` wait for the answer and print it the way the Python library does.
- **Names**: `-d` takes a node's name as well as its number; output shows names where the
  Python examples show numbers (traceroute).
- **autoresponder** does not answer its own reply text, so two of them don't answer each other
  for ever.
- **foxhunt** waits `--pause` seconds (2) before asking again; the Python examples ask again at once.
- **packets --counts** prints text bar charts every 10 s instead of opening a matplotlib window.
- **send --what environment** sends 25.2 °C; send-environment-metrics.py sends 352.222.
- **mqtt-send** sends "Hello from Erlang" (or `-m`), and its position does not ask for answers.
- **radio-mqtt** publishes to localhost unless `--broker` is given, and fills in `snr` (from
  `rx_snr`).
- **print-traceroute.py**'s own one-line format is not kept: `traceroute` prints the library's
  format, which has the SNR of each hop.

## The code

| Module | What |
|---|---|
| `mtc` | the radio client: connect, node list, channels, config, send, wait for answers. What `meshtastic.tcp_interface` does for Python |
| `mtq` | Meshtastic on MQTT: keys, channel hash, AES-CTR, ServiceEnvelope. What the MQTT examples do with paho and cryptography |
| `mtfake` | the fake radio |
| `mte` | the command line |
| `mt_pb` | generated from `proto/` by gpb at build time: Meshtastic's protobufs as maps |

Received packets arrive as messages, `{mtc, C, packet, P}`; `mtc:next/2` waits for the next one.

```erlang
%% mte_messages.erl
case mtc:next(C, infinity) of
    {packet, #{decoded := #{portnum := 'TEXT_MESSAGE_APP', text := Text}}} ->
        io:format("~ts~n", [Text]);
    ...
```

```lisp
;; mtl_messages.lfe
(case (mtc:next c 'infinity)
  ((tuple 'packet (map 'decoded (map 'portnum 'TEXT_MESSAGE_APP 'text text)))
   (io:format "~ts~n" (list text)))
  ...
```

LFE note: `lfec` reads source files as Latin-1, so `mtl_send.lfe` writes the waypoint's emoji as
the code point `#x1F525`.

## Tests

```sh
rebar3 eunit      # keys, channel hash, AES-CTR (checked against openssl), envelopes, the fake radio
```

## Licence

GPL-3.0, like the Python examples it follows and the Meshtastic protobufs in `proto/`
(see `proto/LICENSE.meshtastic-protobufs`).
