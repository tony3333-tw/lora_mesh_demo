#!/usr/bin/env python3
"""Make a fake USB serial port for tests.

Opens a pseudo-terminal, prints the path of its device side (like
/dev/pts/5, standing in for /dev/ttyUSB0), then relays bytes between it
and a TCP port (the fake companion). Stops when stdin closes, so the
Erlang test that started it with open_port/2 cleans it up.

    python3 meshcore_pty.py 5000
"""
import os
import pty
import select
import socket
import sys
import tty


def main():
    port = int(sys.argv[1])
    master, slave = pty.openpty()
    tty.setraw(slave)
    print(os.ttyname(slave), flush=True)

    sock = socket.create_connection(("127.0.0.1", port))
    stdin = sys.stdin.fileno()
    while True:
        ready, _, _ = select.select([master, sock, stdin], [], [])
        if stdin in ready and not os.read(stdin, 1024):
            break
        if master in ready:
            try:
                data = os.read(master, 4096)
            except OSError:          # nobody has the device open right now
                data = b""
            if data:
                sock.sendall(data)
        if sock in ready:
            data = sock.recv(4096)
            if not data:
                break
            os.write(master, data)


if __name__ == "__main__":
    main()
