"""Reply to "ping" with "pong", straight back to the sender.

    python examples/echo_bot.py --host localhost
"""
import argparse

from lora_mesh_client import MeshClient

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="localhost")
args = parser.parse_args()

mesh = MeshClient(args.host)


@mesh.on_message
def reply(msg):
    if msg.text.strip().lower() == "ping":
        # answer through the bridge that heard the sender best
        mesh.send(f"pong ({msg.rx.rx_snr:.1f} dB)", to=msg.from_id, bridge=msg.bridges[0] if msg.bridges else None)
        print(f"pong -> {msg.from_id}")


print("echo bot running, Ctrl+C to stop")
mesh.run()
