"""Print a warning when a node's battery drops below a threshold (once per node).

    python examples/battery_watch.py --host localhost --below 20
"""
import argparse

from lora_mesh_client import MeshClient

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="localhost")
parser.add_argument("--below", type=int, default=20, help="percent")
args = parser.parse_args()

mesh = MeshClient(args.host)
warned = set()


@mesh.on_node
def check(node):
    level = node.battery_level
    if level is None or level > 100:      # unknown, or 101 = on external power
        return
    if level < args.below and node.id not in warned:
        warned.add(node.id)
        print(f"LOW BATTERY: {node.name} ({node.id}) at {level}%")
    elif level >= args.below:
        warned.discard(node.id)


print(f"watching batteries below {args.below}%, Ctrl+C to stop")
mesh.run()
