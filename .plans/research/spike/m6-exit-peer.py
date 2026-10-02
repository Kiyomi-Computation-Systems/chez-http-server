#!/usr/bin/env python3
"""M6 exit, 2026-10-02: a slow peer, for m6-exit-sixteen.sps.

    m6-exit-peer.py PORT PIECE PAUSE-MS

Opens one keep-alive connection to 127.0.0.1:PORT, sends a GET /ping, reads
its answer, and prints "ready".  Then, for each command read from standard
input, one line each, it makes one exchange and prints one line:

    up, up-whole       POST the 16 MiB pattern to /up or /up-whole, PIECE
                       bytes at a time with PAUSE-MS between, and read the
                       answer: "<cmd> <status> <answer> <seconds> rss ..."
    down, down-whole   GET /down or /down-whole and read the 16 MiB, PIECE
                       bytes at a time with PAUSE-MS before each read,
                       checking every byte against the pattern:
                       "<cmd> <status> <framing> <bytes> <wrong> <seconds> rss ..."

Its standard input closing ends it.  The pattern is the server's: byte n is
(m mod 251), where m = (n mod 65521) squared.  While an exchange runs, a
thread reads the server's resident memory every 50 ms, from outside: the
server is this process's parent (`ps -o rss=` on Darwin, VmRSS in /proc on
Linux), and each line ends "rss <before> <most> <after>", in KiB.  The peer
is a process of its own, so what it holds is not in the server's heap.  The
kernel's socket buffers are left as it makes them (the M5 exit: Darwin grows
a receive buffer made small after the connect).
"""
import os
import socket
import subprocess
import sys
import threading
import time

port, piece, pause = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]) / 1000.0
SIZE = 16 * 1024 * 1024
PERIOD = 65521
TABLE = bytes((i * i) % 251 for i in range(PERIOD))
PATTERN = TABLE * (SIZE // PERIOD + 2)
server = os.getppid()


def rss_kib():
    if sys.platform == "darwin":
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(server)], capture_output=True, text=True)
        return int(out.stdout.strip() or 0)
    with open("/proc/%d/status" % server) as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


class Sampler(threading.Thread):
    """The most resident memory read while an exchange runs."""

    def __init__(self):
        super().__init__(daemon=True)
        self.most, self.done = 0, threading.Event()

    def run(self):
        while not self.done.is_set():
            self.most = max(self.most, rss_kib())
            self.done.wait(0.05)


class Reader:
    """Reads the connection PIECE bytes at a time, PAUSE before each read."""

    def __init__(self, s):
        self.s, self.buf = s, b""

    def fill(self, slow):
        if slow:
            time.sleep(pause)
        chunk = self.s.recv(piece)
        if not chunk:
            raise EOFError("the server closed the connection")
        self.buf += chunk

    def line(self, slow=False):
        while b"\r\n" not in self.buf:
            self.fill(slow)
        line, _, self.buf = self.buf.partition(b"\r\n")
        return line

    def take(self, n, slow=False):
        while len(self.buf) < n:
            self.fill(slow)
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def some(self, most, slow):
        if not self.buf:
            self.fill(slow)
        out, self.buf = self.buf[:most], self.buf[most:]
        return out


s = socket.create_connection(("127.0.0.1", port))
r = Reader(s)


def head():
    status = int(r.line().split(b" ")[1])
    fields = {}
    while True:
        line = r.line()
        if not line:
            return status, fields
        name, _, value = line.partition(b":")
        fields[name.strip().lower()] = value.strip()


def exchange(fn):
    before, sampler = rss_kib(), Sampler()
    sampler.start()
    start = time.monotonic()
    words = fn()
    seconds = time.monotonic() - start
    sampler.done.set()
    sampler.join()
    return words + ["%.3f" % seconds, "rss", str(before), str(sampler.most), str(rss_kib())]


def up(path):
    s.sendall(b"POST %s HTTP/1.1\r\nHost: h\r\nContent-Length: %d\r\n\r\n" % (path, SIZE))
    for off in range(0, SIZE, piece):
        s.sendall(PATTERN[off:min(off + piece, SIZE)])
        time.sleep(pause)
    status, fields = head()
    answer = r.take(int(fields[b"content-length"]))
    return [str(status), answer.decode().replace(" ", "/")]


def down(path):
    s.sendall(b"GET %s HTTP/1.1\r\nHost: h\r\n\r\n" % path)
    status, fields = head()
    got, wrong = 0, 0

    def check(data):
        nonlocal got, wrong
        if data != PATTERN[got:got + len(data)]:
            wrong += 1
        got += len(data)

    if fields.get(b"transfer-encoding") == b"chunked":
        framing = "chunked"
        while True:
            n = int(r.line(True).split(b";")[0], 16)
            if n == 0:
                r.line(True)
                break
            left = n
            while left:
                data = r.some(left, True)
                check(data)
                left -= len(data)
            r.take(2, True)
    else:
        framing = "length"
        left = int(fields[b"content-length"])
        while left:
            data = r.some(left, True)
            check(data)
            left -= len(data)
    return [str(status), framing, str(got), str(wrong)]


s.sendall(b"GET /ping HTTP/1.1\r\nHost: h\r\n\r\n")
status, fields = head()
r.take(int(fields[b"content-length"]))
print("ready", flush=True)
for line in iter(sys.stdin.readline, ""):
    cmd = line.strip()
    if cmd in ("up", "up-whole"):
        words = exchange(lambda: up(b"/" + cmd.encode()))
    elif cmd in ("down", "down-whole"):
        words = exchange(lambda: down(b"/" + cmd.encode()))
    else:
        words = ["unknown"]
    print(" ".join([cmd] + words), flush=True)
s.close()
