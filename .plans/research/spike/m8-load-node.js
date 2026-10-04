// M8.4, 2026-10-04: the peer m8-load.sh runs beside `serve`.  Node's http
// module, on libuv's loop and one JavaScript thread, answering every request
// 200 with "served", as tests/serve-child.sps does, on 127.0.0.1 at the
// kernel's choice of port, which it prints as `serve` logs it.
const http = require('http');
const server = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type': 'text/plain', 'Content-Length': '6'});
  res.end('served');
});
server.listen(0, '127.0.0.1', () => {
  console.log(`listening 127.0.0.1 ${server.address().port}`);
});
