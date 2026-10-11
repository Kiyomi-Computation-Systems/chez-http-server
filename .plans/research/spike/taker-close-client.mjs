// The lost close (chez-websocket's decision 0008, item 6), a Node client: the
// shape of ws and of a browser, one thread that writes a message as the
// socket drains and reads as data comes.  Each run connects to
// 127.0.0.1:PORT, asks for a WebSocket upgrade, and once the 101 has come
// writes TOTAL bytes in CHUNK-byte writes.  It ends the socket when the
// server's end comes.  Per run: whether the close frame (88 02 03 f1) was
// read, how the stream ended (eof, or the error's code), the bytes handed
// to write, and the milliseconds from the first write to the socket's close.
//
//   node taker-close-client.mjs PORT RUNS TOTAL CHUNK
import net from 'node:net';

const marker = Buffer.from([0x88, 0x02, 0x03, 0xf1]);
const handshake =
  'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
  'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n';

function run(port, total, chunk) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1');
    let head = Buffer.alloc(0), upgraded = false, tail = Buffer.alloc(0);
    let saw = false, ended = null, sent = 0, t0 = performance.now();
    const zeros = Buffer.alloc(chunk);
    function pump() {
      while (sent < total && !s.destroyed) {
        const n = Math.min(chunk, total - sent);
        sent += n;
        if (!s.write(n === chunk ? zeros : zeros.subarray(0, n))) { s.once('drain', pump); return; }
      }
    }
    function scan(b) {
      const joined = Buffer.concat([tail, b]);
      if (joined.indexOf(marker) >= 0) saw = true;
      tail = joined.subarray(Math.max(0, joined.length - 3));
    }
    s.on('connect', () => s.write(handshake));
    s.on('data', (b) => {
      if (!upgraded) {
        head = Buffer.concat([head, b]);
        const i = head.indexOf('\r\n\r\n');
        if (i < 0) return;
        upgraded = true;
        scan(head.subarray(i + 4));
        t0 = performance.now();
        pump();
        return;
      }
      scan(b);
    });
    s.on('end', () => { ended ??= 'eof'; s.end(); });
    s.on('error', (e) => { ended ??= e.code; });
    s.on('close', () => resolve({ saw, ended, sent, ms: performance.now() - t0 }));
  });
}

const [port, runs, total, chunk] = process.argv.slice(2).map(Number);
const tally = { read: 0, ends: {} };
for (let i = 0; i < runs; i++) {
  const r = await run(port, total, chunk);
  console.log(`run ${i}: close-frame ${r.saw ? 'read' : 'lost'}, ended ${r.ended}, sent ${r.sent}, ${r.ms.toFixed(1)} ms`);
  tally.read += r.saw ? 1 : 0;
  tally.ends[r.ended] = (tally.ends[r.ended] ?? 0) + 1;
}
console.log(`tally: ${runs} runs, close frame read ${tally.read}, ended ${JSON.stringify(tally.ends)}`);
