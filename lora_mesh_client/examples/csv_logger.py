"""Log every message and every node update to CSV files, for data collection.

    python examples/csv_logger.py --host localhost --dir data

messages.csv: time, from, to, channel, text, snr, rssi, hops, bridges
nodes.csv:    time, id, name, battery, voltage, latitude, longitude, altitude
"""
import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path

from lora_mesh_client import MeshClient

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="localhost")
parser.add_argument("--dir", default="data")
args = parser.parse_args()

out = Path(args.dir)
out.mkdir(exist_ok=True)


def writer(name, header):
    path = out / name
    new = not path.exists()
    f = path.open("a", newline="", encoding="utf-8")
    w = csv.writer(f)
    if new:
        w.writerow(header)
    return f, w


msg_file, messages = writer("messages.csv",
                            ["time", "from", "to", "channel", "text", "snr", "rssi", "hops", "bridges"])
node_file, nodes = writer("nodes.csv",
                          ["time", "id", "name", "battery", "voltage", "latitude", "longitude", "altitude"])

mesh = MeshClient(args.host)


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@mesh.on_message
def log_message(msg):
    messages.writerow([now(), msg.from_id, msg.to_id, msg.channel, msg.text,
                       msg.rx.rx_snr, msg.rx.rx_rssi, msg.rx.hops, " ".join(msg.bridges)])
    msg_file.flush()


@mesh.on_node
def log_node(node):
    pos = node.position
    nodes.writerow([now(), node.id, node.name, node.battery_level, node.voltage,
                    pos.latitude if pos else "", pos.longitude if pos else "", pos.altitude if pos else ""])
    node_file.flush()


print(f"logging to {out}/, Ctrl+C to stop")
mesh.run()
