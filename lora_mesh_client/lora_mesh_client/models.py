"""Data classes for what lora_mesh publishes on MQTT.

Each one mirrors a record in lora_mesh's include/lora_mesh.hrl:

    Reception  <-  #mesh_rxq{}
    Message    <-  #mesh_rx{}
    Position   <-  #mesh_position{}
    Heard      <-  #mesh_heard{}
    Node       <-  #mesh_node{}
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional

BROADCAST = "!ffffffff"
MAX_TEXT_BYTES = 233  # DATA_PAYLOAD_LEN in Meshtastic's mesh.proto
MESHCORE_MAX_TEXT_BYTES = 160  # MAX_TEXT_LEN in MeshCore's BaseChatMesh.h

# MeshCore nodes are known by the first 6 bytes of their public key.
# lora_mesh numbers them with bit 48 set, so they never clash with
# 32-bit Meshtastic node numbers.
MESHCORE_TAG = 1 << 48


def is_meshcore(num: int) -> bool:
    return MESHCORE_TAG <= num < 2 * MESHCORE_TAG


def node_id(num: int) -> str:
    """Node number -> '!a1b2c3d4' (Meshtastic) or '@a1a2a3a4a5a6' (MeshCore)."""
    if is_meshcore(num):
        return f"@{num - MESHCORE_TAG:012x}"
    return f"!{num:08x}"


def node_num(value: int | str) -> int:
    """'!a1b2c3d4', '@a1a2a3a4a5a6' or a number -> the number lora_mesh uses."""
    if isinstance(value, int):
        return value
    text = value.strip()
    if text.startswith("!"):
        return int(text[1:], 16)
    if text.startswith("@"):
        if len(text) != 13:
            raise ValueError(f"a MeshCore id is '@' and 12 hex digits, not {text!r}")
        return MESHCORE_TAG + int(text[1:], 16)
    return int(text)


def _time(seconds: Optional[int]) -> Optional[datetime]:
    if not seconds:
        return None
    return datetime.fromtimestamp(seconds, tz=timezone.utc)


@dataclass(frozen=True)
class Reception:
    """Radio data of one reception (lora_mesh #mesh_rxq{})."""

    rx_snr: float = 0.0
    rx_rssi: int = 0
    hop_start: int = 0
    hop_limit: int = 0
    via_mqtt: bool = False

    @property
    def hops(self) -> int:
        """How many times the packet was relayed before it was heard."""
        return max(self.hop_start - self.hop_limit, 0)

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> "Reception":
        data = data or {}
        return cls(
            rx_snr=float(data.get("rx_snr") or 0.0),
            rx_rssi=int(data.get("rx_rssi") or 0),
            hop_start=int(data.get("hop_start") or 0),
            hop_limit=int(data.get("hop_limit") or 0),
            via_mqtt=bool(data.get("via_mqtt")),
        )


@dataclass(frozen=True)
class Message:
    """One text message from the mesh (lora_mesh #mesh_rx{}), published on <prefix>/rx/<from>."""

    id: int
    from_id: str
    to_id: str
    channel: int
    text: str
    rx: Reception
    bridges: tuple[str, ...] = ()
    protocol: str = "meshtastic"       # or "meshcore"
    sender_name: Optional[str] = None  # MeshCore channel messages carry the sender's name

    @property
    def is_broadcast(self) -> bool:
        return self.to_id == BROADCAST

    @property
    def is_known_sender(self) -> bool:
        """False for a MeshCore channel message from a name lora_mesh has no key for."""
        return self.from_id != "?"

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Message":
        return cls(
            id=int(data.get("id") or 0),
            from_id=data["from"],
            to_id=data.get("to") or BROADCAST,
            channel=int(data.get("channel") or 0),
            text=data.get("text") or "",
            rx=Reception.from_json(data.get("rxq")),
            bridges=tuple(data.get("bridges") or ()),
            protocol=data.get("protocol") or "meshtastic",
            sender_name=data.get("sender_name"),
        )


@dataclass(frozen=True)
class Position:
    """Last known position (lora_mesh #mesh_position{})."""

    latitude: float
    longitude: float
    altitude: Optional[int] = None
    time: Optional[datetime] = None

    @classmethod
    def from_json(cls, data: dict[str, Any] | None) -> Optional["Position"]:
        if not data or data.get("latitude") is None or data.get("longitude") is None:
            return None
        return cls(
            latitude=float(data["latitude"]),
            longitude=float(data["longitude"]),
            altitude=data.get("altitude"),
            time=_time(data.get("time")),
        )


@dataclass(frozen=True)
class Heard:
    """One bridge hearing one node (lora_mesh #mesh_heard{})."""

    bridge: str
    rx: Reception
    at: Optional[datetime]


@dataclass(frozen=True)
class Node:
    """What lora_mesh knows about one node (#mesh_node{}), retained on <prefix>/node/<id>."""

    num: int
    id: str
    protocol: str = "meshtastic"       # or "meshcore"
    long_name: Optional[str] = None
    short_name: Optional[str] = None
    hw_model: Optional[str] = None
    role: Optional[str] = None
    position: Optional[Position] = None
    battery_level: Optional[int] = None  # percent; 101 means on external power
    voltage: Optional[float] = None
    last_heard: Optional[datetime] = None
    heard_by: dict[str, Heard] = field(default_factory=dict)

    @property
    def name(self) -> str:
        return self.long_name or self.short_name or self.id

    @property
    def best_bridge(self) -> Optional[str]:
        """The bridge that hears this node with the best SNR, if any."""
        if not self.heard_by:
            return None
        return max(self.heard_by.values(), key=lambda h: h.rx.rx_snr).bridge

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Node":
        heard = {
            bridge: Heard(bridge=bridge,
                          rx=Reception.from_json(h.get("rxq")),
                          at=_time(h.get("at")))
            for bridge, h in (data.get("heard_by") or {}).items()
        }
        hw = data.get("hw_model")
        role = data.get("role")
        return cls(
            num=int(data["num"]),
            id=data.get("id") or node_id(int(data["num"])),
            protocol=data.get("protocol") or "meshtastic",
            long_name=data.get("long_name"),
            short_name=data.get("short_name"),
            hw_model=None if hw is None else str(hw),
            role=None if role is None else str(role),
            position=Position.from_json(data.get("position")),
            battery_level=data.get("battery_level"),
            voltage=data.get("voltage"),
            last_heard=_time(data.get("last_heard")),
            heard_by=heard,
        )
