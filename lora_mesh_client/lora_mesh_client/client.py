"""MeshClient: talk to a lora_mesh server over MQTT.

lora_mesh publishes
    <prefix>/rx/<from>     one JSON text message per packet (deduplicated)
    <prefix>/node/<id>     one retained JSON record per node
and listens on
    <prefix>/tx            {"text": ..., "to": ..., "channel": ..., "bridge": ...}

This client only speaks that MQTT/JSON interface: no Erlang, no protobuf.
"""

from __future__ import annotations

import json
import logging
import queue
import threading
from typing import Callable, Iterator, Optional

import paho.mqtt.client as mqtt

from .models import (
    MAX_TEXT_BYTES,
    MESHCORE_MAX_TEXT_BYTES,
    Message,
    Node,
    is_meshcore,
    node_id,
    node_num,
)

log = logging.getLogger("lora_mesh_client")

MessageHandler = Callable[[Message], None]
NodeHandler = Callable[[Node], None]


class MeshClient:
    """A connection to a lora_mesh server's MQTT broker.

    Typical use:

        mesh = MeshClient("localhost")

        @mesh.on_message
        def show(msg):
            print(msg.from_id, msg.text)

        mesh.run()          # blocks; Ctrl+C to stop
    """

    def __init__(
        self,
        host: str = "localhost",
        port: int = 1883,
        prefix: str = "mesh",
        username: Optional[str] = None,
        password: Optional[str] = None,
        client_id: Optional[str] = None,
    ) -> None:
        self.host = host
        self.port = port
        self.prefix = prefix.rstrip("/")
        self._message_handlers: list[MessageHandler] = []
        self._node_handlers: list[NodeHandler] = []
        self._nodes: dict[str, Node] = {}
        self._lock = threading.Lock()
        self._connected = threading.Event()
        self._inbox: "queue.Queue[Message]" = queue.Queue(maxsize=1000)
        self._started = False
        self._loop_thread: Optional[int] = None  # paho's thread, where handlers run

        self._mqtt = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=client_id or "",
        )
        if username is not None:
            self._mqtt.username_pw_set(username, password)
        self._mqtt.on_connect = self._on_connect
        self._mqtt.on_disconnect = self._on_disconnect
        self._mqtt.on_message = self._on_message

    # ------------------------------------------------------------------
    # Handlers (use as decorators)
    # ------------------------------------------------------------------

    def on_message(self, handler: MessageHandler) -> MessageHandler:
        """Call handler(Message) for every text message from the mesh."""
        self._message_handlers.append(handler)
        return handler

    def on_node(self, handler: NodeHandler) -> NodeHandler:
        """Call handler(Node) whenever lora_mesh updates a node's record."""
        self._node_handlers.append(handler)
        return handler

    # ------------------------------------------------------------------
    # Connection
    # ------------------------------------------------------------------

    def start(self, timeout: float = 10.0) -> "MeshClient":
        """Connect and process messages in a background thread."""
        if not self._started:
            self._mqtt.connect(self.host, self.port)
            self._mqtt.loop_start()
            self._started = True
        if not self._connected.wait(timeout):
            raise TimeoutError(f"no MQTT connection to {self.host}:{self.port}")
        return self

    def stop(self) -> None:
        """Disconnect and stop the background thread."""
        if self._started:
            self._mqtt.disconnect()
            self._mqtt.loop_stop()
            self._started = False
            self._connected.clear()

    def run(self) -> None:
        """Connect and process messages until Ctrl+C."""
        self.start()
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    def __enter__(self) -> "MeshClient":
        return self.start()

    def __exit__(self, *exc: object) -> None:
        self.stop()

    # ------------------------------------------------------------------
    # Reading
    # ------------------------------------------------------------------

    @property
    def nodes(self) -> dict[str, Node]:
        """Every node lora_mesh has reported, keyed by '!a1b2c3d4' or '@a1a2a3a4a5a6'."""
        with self._lock:
            return dict(self._nodes)

    def node(self, who: int | str) -> Optional[Node]:
        """One node by number, '!a1b2c3d4' or '@a1a2a3a4a5a6', if known."""
        return self.nodes.get(node_id(node_num(who)))

    def messages(self, timeout: Optional[float] = None) -> Iterator[Message]:
        """Yield text messages as they arrive.

        for msg in mesh.messages():
            print(msg.text)

        With a timeout, stops after that many seconds without a message.
        """
        self.start()
        while True:
            try:
                yield self._inbox.get(timeout=timeout)
            except queue.Empty:
                return

    # ------------------------------------------------------------------
    # Sending
    # ------------------------------------------------------------------

    def send(
        self,
        text: str,
        to: int | str | None = None,
        channel: int = 0,
        bridge: Optional[str] = None,
        protocol: Optional[str] = None,
    ) -> None:
        """Send a text into the mesh through lora_mesh.

        to:       None for everyone, or a node number / '!a1b2c3d4' / '@a1a2a3a4a5a6'
        channel:  channel index on the node
        bridge:   send through this lora_mesh bridge only (e.g. "hill")
        protocol: for a broadcast, "meshtastic" or "meshcore" picks the mesh
                  (a direct message goes to the mesh its id belongs to)

        Raises ValueError for texts the node cannot carry: over 233 bytes in
        UTF-8 for Meshtastic, 160 for MeshCore (where a channel message also
        carries the radio's name).
        """
        if protocol not in (None, "meshtastic", "meshcore"):
            raise ValueError(f"protocol is 'meshtastic' or 'meshcore', not {protocol!r}")
        num = None if to is None else node_num(to)
        meshcore = protocol == "meshcore" or (num is not None and is_meshcore(num))
        limit = MESHCORE_MAX_TEXT_BYTES if meshcore else MAX_TEXT_BYTES
        size = len(text.encode("utf-8"))
        if size == 0:
            raise ValueError("text is empty")
        if size > limit:
            mesh = "MeshCore message" if meshcore else "Meshtastic packet"
            raise ValueError(
                f"text is {size} bytes in UTF-8; a {mesh} holds at most "
                f"{limit} (about {limit // 3} Chinese characters)"
            )
        command: dict[str, object] = {"text": text, "channel": channel}
        if num is not None:
            command["to"] = node_id(num)
        if bridge is not None:
            command["bridge"] = bridge
        elif protocol is not None:
            command["protocol"] = protocol
        self.start()
        info = self._mqtt.publish(f"{self.prefix}/tx", json.dumps(command, ensure_ascii=False), qos=1)
        if threading.get_ident() != self._loop_thread:
            # Wait for the broker's acknowledgement, except inside a handler:
            # handlers run in paho's own thread, which has to return before
            # it can send the message, so waiting there would only stall.
            info.wait_for_publish(timeout=10)

    # ------------------------------------------------------------------
    # paho callbacks (run in paho's thread)
    # ------------------------------------------------------------------

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        self._loop_thread = threading.get_ident()
        if reason_code.is_failure:
            log.warning("MQTT connect failed: %s", reason_code)
            return
        client.subscribe([(f"{self.prefix}/rx/+", 0),
                          (f"{self.prefix}/node/+", 0)])
        self._connected.set()

    def _on_disconnect(self, client, userdata, flags, reason_code, properties) -> None:
        self._connected.clear()
        if reason_code != 0:
            log.warning("MQTT disconnected: %s (paho reconnects automatically)", reason_code)

    def _on_message(self, client, userdata, msg: mqtt.MQTTMessage) -> None:
        kind = msg.topic[len(self.prefix) + 1:].split("/", 1)[0]
        try:
            data = json.loads(msg.payload)
        except ValueError:
            log.warning("not JSON on %s", msg.topic)
            return
        if kind == "rx":
            self._dispatch_message(Message.from_json(data))
        elif kind == "node":
            self._dispatch_node(Node.from_json(data))

    def _dispatch_message(self, message: Message) -> None:
        try:
            self._inbox.put_nowait(message)
        except queue.Full:  # nobody is iterating messages(): keep the newest
            self._inbox.get_nowait()
            self._inbox.put_nowait(message)
        for handler in self._message_handlers:
            self._safe(handler, message)

    def _dispatch_node(self, node: Node) -> None:
        with self._lock:
            self._nodes[node.id] = node
        for handler in self._node_handlers:
            self._safe(handler, node)

    @staticmethod
    def _safe(handler: Callable, arg: object) -> None:
        # one broken handler must not stop the client
        try:
            handler(arg)
        except Exception:
            log.exception("handler %s failed", getattr(handler, "__name__", handler))
