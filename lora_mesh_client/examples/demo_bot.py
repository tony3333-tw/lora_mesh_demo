"""A demo bot for lora_mesh: shows every message and node, answers "ping".

Each teammate can run it on their own laptop with their own name:

    python examples/demo_bot.py --host 192.168.1.20 --name Mary

- Every text from the mesh is printed with sender, mesh, signal and the
  bridges that heard it.
- A node is announced when lora_mesh first reports it, and again when its
  name, battery or position changes (Meshtastic telemetry and position).
- "ping" or "ping?" gets "pong from <name>":
    a direct message is answered directly to the sender,
    a channel message is answered on the same channel, through the
    bridge that heard it best.
"""
import argparse
from datetime import datetime

from lora_mesh_client import MeshClient, Message, Node

parser = argparse.ArgumentParser(description="lora_mesh demo bot")
parser.add_argument("--host", default="localhost", help="MQTT broker (the lora_mesh machine)")
parser.add_argument("--port", type=int, default=1883)
parser.add_argument("--name", default="bot", help="your name, used in replies")
args = parser.parse_args()

mesh = MeshClient(args.host, args.port)
known: dict[str, tuple] = {}  # node id -> (name, battery, position) last printed


def now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def sender(msg: Message) -> str:
    if msg.is_known_sender:
        node = mesh.node(msg.from_id)
        if node:
            return node.name
    return msg.sender_name or msg.from_id


@mesh.on_message
def show_and_answer(msg: Message) -> None:
    where = "channel %d" % msg.channel if msg.is_broadcast else "direct"
    print(f"{now()}  {sender(msg)} ({msg.protocol}, {where}): {msg.text}"
          f"   [snr {msg.rx.rx_snr:.1f} dB, {msg.rx.path_text}, heard by {', '.join(msg.bridges) or '-'}]",
          flush=True)

    if msg.text.strip().lower().rstrip("?") != "ping":
        return
    reply = f"pong from {args.name}"
    best = msg.bridges[0] if msg.bridges else None
    if msg.is_broadcast:
        mesh.send(reply, channel=msg.channel, bridge=best)
        print(f"{now()}  -> {reply} (on channel {msg.channel} via {best})", flush=True)
    else:
        mesh.send(reply, to=msg.from_id, bridge=best)
        print(f"{now()}  -> {reply} (to {sender(msg)} via {best})", flush=True)


@mesh.on_node
def announce(node: Node) -> None:
    """Print a node when first seen, and again when its name, battery or position changes."""
    pos = (round(node.position.latitude, 5), round(node.position.longitude, 5)) if node.position else None
    now_seen = (node.name, node.battery_level, pos)
    before = known.get(node.id)
    known[node.id] = now_seen
    if before == now_seen:
        return
    details = [node.protocol, node.role or "-"]
    if node.battery_level is not None:
        details.append("battery %d%%" % node.battery_level if node.battery_level <= 100 else "on power")
    where = f" at {pos[0]:.5f}, {pos[1]:.5f}" if pos else ""
    label = "node" if before is None else "update"
    print(f"{now()}  {label} {node.id} {node.name} ({', '.join(details)}){where}", flush=True)


print(f"demo bot '{args.name}' on {args.host}:{args.port}, Ctrl+C to stop", flush=True)
mesh.run()
