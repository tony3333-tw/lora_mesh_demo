"""Parsing and sending, against JSON captured from a real lora_mesh 0.2 run."""

import json

import pytest

from lora_mesh_client import MAX_TEXT_BYTES, MeshClient, Message, Node, is_meshcore, node_id, node_num

# exactly what lora_mesh published on mesh/rx/!0a0b0c0d and mesh/node/!0a0b0c0d
RX = '{"id":99,"text":"哈囉 from mesh","bridges":["hill","home"],"channel":0,"to":"!ffffffff","from":"!0a0b0c0d","rxq":{"hop_limit":2,"via_mqtt":false,"rx_snr":8.5,"rx_rssi":-90,"hop_start":3}}'
NODE = '{"id":"!0a0b0c0d","position":{"time":0,"altitude":85,"latitude":24.1477,"longitude":120.6736},"short_name":"HILL","long_name":"Hill top","role":"CLIENT","hw_model":"HELTEC_V3","num":168496141,"last_heard":1793187882,"battery_level":null,"voltage":null,"heard_by":{"home":{"at":1793187882,"rxq":{"hop_limit":2,"via_mqtt":false,"rx_snr":5.0,"rx_rssi":-90,"hop_start":3}},"hill":{"at":1793187882,"rxq":{"hop_limit":2,"via_mqtt":false,"rx_snr":8.5,"rx_rssi":-90,"hop_start":3}}}}'

# what lora_mesh 0.3 published for a MeshCore companion (fake, built from the firmware source)
CORE_DM = '{"id":1761700001,"protocol":"meshcore","text":"溫度 23.5","bridges":["field"],"channel":0,"rxq":{"rx_snr":6.25,"rx_rssi":0,"hop_start":2,"hop_limit":0,"via_mqtt":false},"from":"@a1a2a3a4a5a6","to":"@5e1f00000001","sender_name":null}'
CORE_CHANNEL = '{"id":1761700002,"protocol":"meshcore","text":"rain at the north gate","bridges":["field"],"channel":0,"rxq":{"rx_snr":-3.0,"rx_rssi":0,"hop_start":1,"hop_limit":0,"via_mqtt":false},"from":"@b1b2b3b4b5b6","to":"!ffffffff","sender_name":"Bob"}'
CORE_NODE = '{"id":"@a1a2a3a4a5a6","position":{"time":null,"latitude":25.047,"longitude":121.517,"altitude":null},"protocol":"meshcore","role":"chat","heard_by":{"field":{"at":1793240961,"rxq":{"rx_snr":6.25,"rx_rssi":0,"hop_start":2,"hop_limit":0,"via_mqtt":false}}},"num":459194878961062,"long_name":"Alice","short_name":null,"hw_model":null,"battery_level":null,"voltage":null,"last_heard":1793240961}'


def test_message():
    m = Message.from_json(json.loads(RX))
    assert m.from_id == "!0a0b0c0d"
    assert m.text == "哈囉 from mesh"
    assert m.is_broadcast
    assert m.bridges == ("hill", "home")
    assert m.rx.rx_snr == 8.5
    assert m.rx.hops == 1


def test_node():
    n = Node.from_json(json.loads(NODE))
    assert n.num == 0x0A0B0C0D
    assert n.name == "Hill top"
    assert n.hw_model == "HELTEC_V3"
    assert n.position.latitude == pytest.approx(24.1477)
    assert n.position.time is None          # 0 = no time from the node
    assert n.battery_level is None
    assert n.best_bridge == "hill"
    assert n.last_heard.year >= 2026


def test_node_ids():
    assert node_id(0x0A0B0C0D) == "!0a0b0c0d"
    assert node_num("!0a0b0c0d") == 0x0A0B0C0D
    assert node_num(42) == 42


def test_meshcore_ids():
    num = node_num("@a1a2a3a4a5a6")
    assert num == (1 << 48) + 0xA1A2A3A4A5A6
    assert is_meshcore(num)
    assert not is_meshcore(0xFFFFFFFF)
    assert node_id(num) == "@a1a2a3a4a5a6"
    with pytest.raises(ValueError):
        node_num("@a1a2")


def test_meshcore_messages():
    dm = Message.from_json(json.loads(CORE_DM))
    assert dm.protocol == "meshcore"
    assert dm.from_id == "@a1a2a3a4a5a6"
    assert not dm.is_broadcast
    assert dm.rx.hops == 2
    ch = Message.from_json(json.loads(CORE_CHANNEL))
    assert ch.is_broadcast
    assert ch.sender_name == "Bob"
    assert ch.is_known_sender
    unknown = Message.from_json({**json.loads(CORE_CHANNEL), "from": "?"})
    assert not unknown.is_known_sender
    assert Message.from_json(json.loads(RX)).protocol == "meshtastic"


def test_meshcore_node():
    n = Node.from_json(json.loads(CORE_NODE))
    assert n.protocol == "meshcore"
    assert n.id == "@a1a2a3a4a5a6"
    assert n.role == "chat"
    assert n.best_bridge == "field"


class FakePublish:
    """Stands in for paho so send() can be checked without a broker."""

    def __init__(self):
        self.sent = []

    def publish(self, topic, payload, qos):
        self.sent.append((topic, json.loads(payload)))

        class Info:
            def wait_for_publish(self, timeout=None):
                pass

        return Info()


@pytest.fixture
def mesh(monkeypatch):
    client = MeshClient("localhost", prefix="mesh")
    fake = FakePublish()
    monkeypatch.setattr(client, "_mqtt", fake)
    monkeypatch.setattr(client, "start", lambda timeout=10.0: client)
    return client, fake


def test_send_broadcast(mesh):
    client, fake = mesh
    client.send("hello")
    assert fake.sent == [("mesh/tx", {"text": "hello", "channel": 0})]


def test_send_direct_via_bridge(mesh):
    client, fake = mesh
    client.send("hi", to=0xA1B2C3D4, channel=1, bridge="hill")
    assert fake.sent == [("mesh/tx", {"text": "hi", "channel": 1, "to": "!a1b2c3d4", "bridge": "hill"})]


def test_send_limits(mesh):
    client, fake = mesh
    client.send("x" * MAX_TEXT_BYTES)                  # 233 bytes: fits
    with pytest.raises(ValueError, match="234 bytes"):
        client.send("哈" * 78)                          # 78 x 3 = 234 bytes
    with pytest.raises(ValueError):
        client.send("")
    assert len(fake.sent) == 1


def test_send_meshcore(mesh):
    client, fake = mesh
    client.send("hi", to="@a1a2a3a4a5a6")
    client.send("大家好", protocol="meshcore")
    assert fake.sent == [("mesh/tx", {"text": "hi", "channel": 0, "to": "@a1a2a3a4a5a6"}),
                         ("mesh/tx", {"text": "大家好", "channel": 0, "protocol": "meshcore"})]
    with pytest.raises(ValueError, match="MeshCore"):
        client.send("x" * 161, to="@a1a2a3a4a5a6")      # 160 bytes at most
    with pytest.raises(ValueError):
        client.send("hi", protocol="lorawan")
    client.send("x" * 161)                              # Meshtastic: fits
    assert len(fake.sent) == 3


def test_broken_handler_does_not_stop_others(mesh):
    client, _ = mesh
    seen = []

    @client.on_message
    def broken(msg):
        raise RuntimeError("bug in a user's handler")

    @client.on_message
    def works(msg):
        seen.append(msg.text)

    client._dispatch_message(Message.from_json(json.loads(RX)))
    assert seen == ["哈囉 from mesh"]
