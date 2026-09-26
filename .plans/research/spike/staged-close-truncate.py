"""Does an immediate close cut short a large response while a request sits unread?

Loopback, this machine.  The client sends a request and, 1 ms later, a second
(pipelining), then waits 50 ms before reading, as a client busy elsewhere does.
The server reads the first, takes 20 ms to answer, as a handler does while the
core has stopped reading (decision 0004), so the second arrives unread, and
writes a 4 MiB response with `Connection: close`.  When the write returns, the
bytes are in the kernel, not yet with the client, as with libuv's write
completion.  Then it closes at once, or in stages.  The outcome: the whole
response read, or how much of it before the error, the end, or 3 s of nothing.
"""
import socket, threading, sys, time, collections

BODY = 4 * 1024 * 1024
HEAD = b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % BODY
WHOLE = len(HEAD) + BODY
REQUEST = b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n"

def serve(lst, mode, ready):
    ready.set()
    c, _ = lst.accept()
    got = b""
    while b"\r\n\r\n" not in got:
        got += c.recv(16384)
    time.sleep(0.020)
    c.sendall(HEAD + b"v" * BODY)
    if mode == "staged":
        c.shutdown(socket.SHUT_WR)
        c.settimeout(5)
        try:
            while c.recv(65536):
                pass
        except OSError:
            pass
    c.close()

def run(mode):
    lst = socket.socket(); lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("127.0.0.1", 0)); lst.listen(1)
    ready = threading.Event()
    t = threading.Thread(target=serve, args=(lst, mode, ready)); t.start(); ready.wait()
    cl = socket.create_connection(lst.getsockname())
    cl.sendall(REQUEST % 1); time.sleep(0.001); cl.sendall(REQUEST % 2)
    time.sleep(0.050)
    cl.settimeout(3)
    n, end = 0, "the end"
    try:
        while True:
            d = cl.recv(1 << 20)
            if not d:
                break
            n += len(d)
    except socket.timeout:
        end = "nothing for 3 s"
    except OSError as e:
        end = e.strerror or type(e).__name__
    cl.close(); t.join(); lst.close()
    return "read it all" if n == WHOLE else f"read {n * 100 // WHOLE}% of it, then {end}"

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 50
for mode in ("immediate", "staged"):
    tally = collections.Counter(run(mode) for _ in range(runs))
    print(f"4 MiB response, {mode:9}: " + "; ".join(f"{k} {v}" for k, v in sorted(tally.items())), flush=True)
