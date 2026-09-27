#!/usr/bin/env python3
"""M4 exit, 2026-09-27: hold connections to a server, for m4-exit-budget.sps.

    m4-exit-hold.py PORT N R

Opens N connections to 127.0.0.1:PORT, and on each in turn sends R GETs, one
at a time, reading each whole response (by its Content-Length) before the
next.  Then prints "ready" and holds every connection open, idle, until its
standard input closes, and closes them.  It runs as a process of its own, so
what it holds is not in the server's heap.
"""
import socket
import sys

port, n, r = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
request = b"GET / HTTP/1.1\r\nHost: h\r\n\r\n"


def exchange(s):
    s.sendall(request)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("the server closed a connection")
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    length = next(int(line.split(b":", 1)[1]) for line in head.split(b"\r\n")
                  if line.lower().startswith(b"content-length:"))
    while len(body) < length:
        chunk = s.recv(4096)
        if not chunk:
            sys.exit("the server closed a connection")
        body += chunk


socks = [socket.create_connection(("127.0.0.1", port)) for _ in range(n)]
for _ in range(r):
    for s in socks:
        exchange(s)
print("ready", flush=True)
sys.stdin.read()
for s in socks:
    s.close()
