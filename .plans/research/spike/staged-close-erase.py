"""Does a reset erase a response the client has received but not yet read?

Loopback, this machine.  The server reads the first 4 KiB of a request, writes
a 431 and closes at once, with the rest of the request unread, so its TCP stack
sends a reset.  The client sends `size` bytes, then waits `wait` before its
first read, so the reset has arrived by then, and reads until the stream ends.
The outcome: the 431 read before an error or the end, or no byte at all.
"""
import socket, threading, sys, time, collections

REFUSAL = (b"HTTP/1.1 431 Request Header Fields Too Large\r\n"
           b"Date: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

def serve(lst, ready):
    ready.set()
    c, _ = lst.accept()
    c.recv(4096)
    c.sendall(REFUSAL)
    c.close()

def run(size, wait):
    lst = socket.socket(); lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("127.0.0.1", 0)); lst.listen(1)
    ready = threading.Event()
    t = threading.Thread(target=serve, args=(lst, ready)); t.start(); ready.wait()
    cl = socket.create_connection(lst.getsockname())
    try:
        cl.sendall(b"GET / HTTP/1.1\r\nX: " + b"v" * (size - 20) + b"\r\n")
    except OSError as e:
        out = "send failed: " + (e.strerror or type(e).__name__)
    else:
        time.sleep(wait)
        got, end = b"", "the end"
        try:
            while True:
                d = cl.recv(65536)
                if not d:
                    break
                got += d
        except OSError as e:
            end = e.strerror or type(e).__name__
        out = ("read the 431, then " if got.startswith(REFUSAL) else f"read {len(got)} B, then ") + end
    cl.close(); t.join(); lst.close()
    return out

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 100
for size in (8 * 1024, 64 * 1024, 4 * 1024 * 1024):
    for wait in (0, 0.050):
        tally = collections.Counter(run(size, wait) for _ in range(runs))
        print(f"{size:>8} B sent, first read after {wait * 1000:g} ms: "
              + "; ".join(f"{k} {v}" for k, v in sorted(tally.items())), flush=True)
