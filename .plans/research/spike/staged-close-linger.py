"""Which closes lose the response, and how long does a staged close last?

Loopback, this machine.  Two cases, each closed at once or in stages (RFC 9112
§9.6: shut the write side, read and drop until the client closes, then close):

  refused    the client sends a head of `size` bytes; the server reads the
             first 4 KiB, writes a 431 and closes (M3.4's measurement again);
  late       the client sends a request, waits `delay`, sends a second, then
             reads; the server reads the first, answers it at once with
             `Connection: close` (a handler's close, or HTTP/1.0's) and closes,
             so the second arrives after the close;
  unread     the same, but the server takes 20 ms to answer, as a handler
             does while the core has stopped reading (decision 0004), so the
             second is in its buffer, unread, when it closes.

Each run's outcome is what the client read, or which call failed and how.  For
a staged close, the linger is timed from the server's shutdown to the client's
close, which the server reads as the stream's end.
"""
import socket, threading, sys, time, collections, statistics

REFUSAL = (b"HTTP/1.1 431 Request Header Fields Too Large\r\n"
           b"Date: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
ANSWER = (b"HTTP/1.1 200 OK\r\n"
          b"Date: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
REQUEST = b"GET /%d HTTP/1.1\r\nHost: x\r\n\r\n"

def serve(lst, case, mode, ready, lingers):
    ready.set()
    c, _ = lst.accept()
    if case == "refused":
        c.recv(4096)
        c.sendall(REFUSAL)
    else:
        got = b""
        while b"\r\n\r\n" not in got:
            got += c.recv(16384)
        if case == "unread":
            time.sleep(0.020)
        c.sendall(ANSWER)
    if mode == "staged":
        t0 = time.perf_counter()
        c.shutdown(socket.SHUT_WR)
        c.settimeout(5)
        try:
            while c.recv(65536):
                pass
            lingers.append(time.perf_counter() - t0)
        except OSError:
            lingers.append(None)
    c.close()

def client(addr, case, arg):
    cl = socket.create_connection(addr)
    try:
        if case == "refused":
            cl.sendall(b"GET / HTTP/1.1\r\nX: " + b"v" * (arg - 20) + b"\r\n")
        else:
            cl.sendall(REQUEST % 1)
            time.sleep(arg)
            cl.sendall(REQUEST % 2)
    except OSError as e:
        cl.close()
        return "send failed: " + (e.strerror or type(e).__name__)
    try:
        got = b""
        while True:
            d = cl.recv(65536)
            if not d:
                break
            got += d
        want = REFUSAL if case == "refused" else ANSWER
        out = "read the response" if got.startswith(want) else "read something else"
    except OSError as e:
        want = REFUSAL if case == "refused" else ANSWER
        out = ("read the response, then " if got.startswith(want) else "read failed: ") + (e.strerror or type(e).__name__)
    cl.close()
    return out

def run(case, mode, arg, lingers):
    lst = socket.socket(); lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("127.0.0.1", 0)); lst.listen(1)
    ready = threading.Event()
    t = threading.Thread(target=serve, args=(lst, case, mode, ready, lingers)); t.start(); ready.wait()
    out = client(lst.getsockname(), case, arg)
    t.join(); lst.close()
    return out

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 100
for case, args in (("refused", (8 * 1024, 64 * 1024)), ("late", (0.001, 0.010)), ("unread", (0.001, 0.010))):
    for arg in args:
        for mode in ("immediate", "staged"):
            lingers = []
            tally = collections.Counter(run(case, mode, arg, lingers) for _ in range(runs))
            label = f"{arg} B" if case == "refused" else f"{arg * 1000:g} ms apart"
            line = f"{case:9} {label:>13}, {mode:9}: " + "; ".join(f"{k} {v}" for k, v in sorted(tally.items()))
            timed = [x for x in lingers if x is not None]
            if mode == "staged":
                line += (f"  | linger median {statistics.median(timed) * 1000:.2f} ms,"
                         f" max {max(timed) * 1000:.2f} ms, cut short {len(lingers) - len(timed)}")
            print(line, flush=True)
