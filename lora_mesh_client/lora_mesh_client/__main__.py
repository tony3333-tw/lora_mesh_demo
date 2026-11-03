"""Command line:  python -m lora_mesh_client <listen | nodes | send> [options]

    python -m lora_mesh_client listen
    python -m lora_mesh_client nodes
    python -m lora_mesh_client send "hello mesh"
    python -m lora_mesh_client send "hi" --to !a1b2c3d4 --bridge hill
    python -m lora_mesh_client send "hi" --to @a1a2a3a4a5a6
    python -m lora_mesh_client send "hello all" --protocol meshcore
"""

from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime

from .client import MeshClient
from .models import Message, Node


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m lora_mesh_client",
                                     description="Talk to a lora_mesh server over MQTT.")
    parser.add_argument("--host", default="localhost", help="MQTT broker (default localhost)")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--prefix", default="mesh", help="topic prefix set in lora_mesh (default mesh)")
    parser.add_argument("--username")
    parser.add_argument("--password")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("listen", help="print messages as they arrive (Ctrl+C to stop)")

    nodes = sub.add_parser("nodes", help="list the nodes lora_mesh knows")
    nodes.add_argument("--wait", type=float, default=2.0,
                       help="seconds to collect retained node records (default 2)")

    send = sub.add_parser("send", help="send a text into the mesh")
    send.add_argument("text")
    send.add_argument("--to", help="!a1b2c3d4 (Meshtastic), @a1a2a3a4a5a6 (MeshCore) or a number "
                                   "(default: everyone)")
    send.add_argument("--channel", type=int, default=0)
    send.add_argument("--bridge", help="send through this lora_mesh bridge only")
    send.add_argument("--protocol", choices=["meshtastic", "meshcore"],
                      help="for a broadcast: which mesh (default: any bridge)")

    args = parser.parse_args(argv)
    mesh = MeshClient(args.host, args.port, args.prefix, args.username, args.password)

    try:
        if args.command == "listen":
            return listen(mesh)
        if args.command == "nodes":
            return list_nodes(mesh, args.wait)
        if args.command == "send":
            with mesh:
                mesh.send(args.text, to=args.to, channel=args.channel, bridge=args.bridge,
                          protocol=args.protocol)
            print("sent")
            return 0
    except (ValueError, TimeoutError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 2


def listen(mesh: MeshClient) -> int:
    @mesh.on_message
    def show(msg: Message) -> None:
        sender = mesh.node(msg.from_id) if msg.is_known_sender else None
        name = sender.name if sender else (msg.sender_name or msg.from_id)
        to = "all" if msg.is_broadcast else msg.to_id
        print(f"{datetime.now():%H:%M:%S}  {name} -> {to}: {msg.text}"
              f"   [snr {msg.rx.rx_snr:.1f} dB, hops {msg.rx.hops}, via {', '.join(msg.bridges) or '-'}]",
              flush=True)

    print(f"listening on {mesh.host}:{mesh.port} ({mesh.prefix}/rx/+), Ctrl+C to stop", flush=True)
    mesh.run()
    return 0


def list_nodes(mesh: MeshClient, wait: float) -> int:
    with mesh:
        time.sleep(wait)
        nodes = sorted(mesh.nodes.values(), key=lambda n: n.last_heard.timestamp() if n.last_heard else 0,
                       reverse=True)
    if not nodes:
        print("no nodes yet")
        return 0
    print(f"{'id':<14} {'name':<20} {'hardware':<16} {'battery':>7} {'last heard':<17} best bridge")
    for n in nodes:
        battery = "" if n.battery_level is None else f"{n.battery_level}%"
        heard = f"{n.last_heard.astimezone():%m-%d %H:%M:%S}" if n.last_heard else ""
        print(f"{n.id:<14} {n.name[:20]:<20} {(n.hw_model or '')[:16]:<16} {battery:>7} {heard:<17} {n.best_bridge or ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
