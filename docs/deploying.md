# Deploying

The server speaks plain HTTP/1.1 and is built to sit behind a reverse proxy
that handles TLS and HTTP/2. This page covers the proxy, the process
around it, and the settings worth changing.

## Behind a proxy

Run the server on `127.0.0.1` and let the proxy face the internet:

```text
client ──https, HTTP/2──▶ proxy ──http, HTTP/1.1──▶ chez-http-server (127.0.0.1:8080)
```

[Caddy](https://caddyserver.com) gets a certificate and proxies in two
lines:

```text
example.com {
	reverse_proxy 127.0.0.1:8080
}
```

With nginx, ask for HTTP/1.1 to the upstream so connections are kept alive,
and pass upgrades on if you take them:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;     # for WebSockets
    proxy_set_header Connection $connection_upgrade;
}
```

(`$connection_upgrade` is the usual `map $http_upgrade $connection_upgrade`
block: `upgrade` when the client asked for one, `""` otherwise.)

Things to know:

- **Speak HTTP/1.1 to the server, not h2c.** The server answers HTTP/2's
  opening line with `505`.
- **The client's address is in a header.** Behind a proxy,
  `request-remote-address` is the proxy's. Read `X-Forwarded-For` (Caddy and
  the nginx block above set it) only when `request-remote-address` is your
  proxy's, and take its last address, the one your proxy added: anyone who
  can reach the server can send that header, and a client can write the
  addresses before the last.
- **The server checks `Host`.** Pass the client's `Host` on (Caddy does by
  default), or the server may refuse what it cannot read as a host.
- **A proxy reload can close upgraded connections.** Caddy's does, so
  WebSocket clients should reconnect.
- **A client that leaves is noticed.** When a client drops its connection to
  the proxy, the proxy closes its connection to the server, and a handler
  that waits is told ([Waiting](waiting.md)).

## The process

The server is a single process with one event loop. Run it under whatever
supervises your services:

- **Listen where the supervisor says.** In a container, set
  `CHEZ_HTTP_HOST=0.0.0.0`. On platforms that hand you a port, pass it on:
  `CHEZ_HTTP_PORT=$PORT`.
- **Stop it with `SIGTERM`.** It drains: it stops accepting, finishes the
  requests in flight, and exits once they are done or
  `CHEZ_HTTP_DRAIN_TIMEOUT` (10 s) has passed ([Connections](connections.md)).
  Give it longer than that before a `SIGKILL`: `docker stop` waits 10 s by
  default, so either pass `-t 15` or set `CHEZ_HTTP_DRAIN_TIMEOUT=8`.
  Kubernetes waits 30 s by default.
- **Raise the open-file limit** above `CHEZ_HTTP_MAX_CONNECTIONS` (10,000):
  each connection is a file descriptor. Under systemd, set `LimitNOFILE=`.
- **Read the logs from standard output.** The server writes one line for
  each thing that happens (`listening`, `handler-failed`, `draining`,
  `stopped`, ...), and nothing to files.
- **Add a health route yourself.** The server has no built-in one; a
  `/health` branch in your handler that answers `200` is enough for a load
  balancer or a container health check.

A systemd unit, as a sketch:

```ini
[Service]
WorkingDirectory=/srv/app
# the five library folders, as Installing lists them
Environment=CHEZSCHEMELIBDIRS=/srv/app/chez-http-server/src:/srv/app/chez-http-server/vendor/chez-libuv/src:...
Environment=CHEZ_HTTP_PORT=8080
ExecStart=/usr/bin/chez --program /srv/app/server.sps
Restart=on-failure
LimitNOFILE=16384
TimeoutStopSec=15
```

## Settings worth a look

The defaults are safe for most sites. Change them when you know why:

| Setting | When |
|:--|:--|
| `CHEZ_HTTP_MAX_BODY_BYTES` | you take uploads: cap them at what you accept |
| `CHEZ_HTTP_IDLE_TIMEOUT` | the proxy keeps idle connections longer than 75 s: make this longer than the proxy's |
| `CHEZ_HTTP_MAX_CONNECTIONS` | you expect more than 10,000 at once, or have less memory (about 17 KiB each) |
| `CHEZ_HTTP_DRAIN_TIMEOUT` | your requests or upgrades need longer to finish when you deploy |

Every setting is in [Configuration](configuration.md).
