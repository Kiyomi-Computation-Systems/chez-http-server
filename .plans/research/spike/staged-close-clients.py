"""What do real clients report when a refusal is followed by an immediate close?

Loopback, this machine.  The server reads once, up to 16 KiB (one read of the
shell's buffer), writes a refusal, and closes at once or in stages (shut the
write side, read and drop until the client closes).  Each client sends:

  head   a GET whose head is 64 KiB, over the 16 KiB limit (answered 431);
  body   a POST with a 4 MiB body (answered 413, as M6's cap will).

Each run's outcome is the status the client reports, or its error.
Usage: staged-close-clients.py RUNS CLIENT... (curl, python, node)
"""
import socket, threading, sys, time, collections, subprocess, http.client, os, tempfile

REPLY = {
    "head": b"HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    "body": b"HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
}
BIG = 64 * 1024
BODY = 4 * 1024 * 1024
BODY_FILE = os.path.join(tempfile.gettempdir(), "staged-close-body.bin")

def handle(c, case, mode):
    try:
        c.recv(16384)
        c.sendall(REPLY[case])
        if mode == "staged":
            c.shutdown(socket.SHUT_WR)
            c.settimeout(5)
            while c.recv(65536):
                pass
    except OSError:
        pass
    c.close()

def serve(lst, case, mode, stop):
    # Linux does not wake an accept blocked on a listener another thread
    # closes, so the loop polls a stop flag instead.
    lst.settimeout(0.05)
    while not stop.is_set():
        try:
            c, _ = lst.accept()
        except socket.timeout:
            continue
        c.settimeout(None)
        threading.Thread(target=handle, args=(c, case, mode), daemon=True).start()

def by_curl(port, case):
    args = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10"]
    if case == "head":
        args += ["-H", "X: " + "v" * BIG]
    else:
        args += ["--data-binary", "@" + BODY_FILE, "-H", "Content-Type: application/octet-stream"]
    p = subprocess.run(args + [f"http://127.0.0.1:{port}/"], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else f"exit {p.returncode} (http_code {p.stdout})"

def by_python(port, case):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        if case == "head":
            conn.request("GET", "/", headers={"X": "v" * BIG})
        else:
            conn.request("POST", "/", body=b"v" * BODY)
        return str(conn.getresponse().status)
    except OSError as e:
        return type(e).__name__
    finally:
        conn.close()

NODE = r"""
const [port, kind] = process.argv.slice(1);
const init = kind === 'head' ? {headers: {x: 'v'.repeat(65536)}}
                             : {method: 'POST', body: Buffer.alloc(4 * 1024 * 1024, 118)};
fetch(`http://127.0.0.1:${port}/`, init)
  .then(r => console.log(r.status))
  .catch(e => console.log('error ' + ((e.cause && (e.cause.code || e.cause.message)) || e.message)));
"""

def by_node(port, case):
    p = subprocess.run(["node", "-e", NODE, str(port), case], capture_output=True, text=True)
    return p.stdout.strip() or p.stderr.strip()[-80:]

CLIENTS = {"curl": by_curl, "python": by_python, "node": by_node}

if not os.path.exists(BODY_FILE):
    with open(BODY_FILE, "wb") as f:
        f.write(b"v" * BODY)
runs = int(sys.argv[1])
for name in sys.argv[2:]:
    for case in ("head", "body"):
        for mode in ("immediate", "staged"):
            lst = socket.socket(); lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            lst.bind(("127.0.0.1", 0)); lst.listen(64)
            port = lst.getsockname()[1]
            stop = threading.Event()
            server = threading.Thread(target=serve, args=(lst, case, mode, stop))
            server.start()
            tally = collections.Counter(CLIENTS[name](port, case) for _ in range(runs))
            stop.set(); server.join(); lst.close()
            print(f"{name:6} {case}, {mode:9}: " + "; ".join(f"{k} {v}" for k, v in sorted(tally.items())), flush=True)
