# Reference read: Haskell Warp (yesodweb/wai) — connection semantics for chez-http-server

Repo: https://github.com/yesodweb/wai
Commit pinned for all `master`-tree citations below: **`9581c256dc343ab8793094fa008626db24f69633`** (fetched 2026-09-19; `master` HEAD as of `git ls-remote`/`GET /repos/yesodweb/wai/commits/master` at fetch time, committer date 2026-09-18T10:12:25Z).
`warp.cabal` `version:` field at that commit: **3.4.16**.
Older-design citations (classic timeout manager) are pinned to tag **`warp-3.2.28`**, commit **`d487668804d7a71606d137df3c6d3d1cc359660b`**.

All files were fetched verbatim with `curl` from `raw.githubusercontent.com/yesodweb/wai/<sha>/<path>` (HTTP 200 confirmed on each) into
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/warp-src/`, then read in full with line numbers. Every claim below cites a `file:line` from that fetch, given as a GitHub permalink (`.../blob/<sha>/<path>#L<n>`) so the synthesis agent can open the exact line. I did **not** rely on memory for any code-level claim; where I state something Warp does *not* do, I searched the fetched tree (`grep -rn`) and report the search, not an assumption.

Package layout note: in the current monorepo the HTTP/1 timeout manager and the buffered-recv code the task calls "Timeout.hs" and "Recv.hs" have been extracted out of `warp/` into their own top-level packages, **`time-manager`** (`System/TimeManager.hs`) and **`recv`** (`Network/Socket/BufferPool/Recv.hs`). I read both, plus the pre-extraction `warp-3.2.28` version of `System/TimeManager.hs` (the "one thread, tickle-able handle" design the task description specifically points at), because the two designs materially differ and only the old one matches the phrase in the task.

Files read in full (line counts from the actual fetch):

| File | Lines | Purpose |
|---|---|---|
| [`warp/Network/Wai/Handler/Warp/Run.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs) | 561 | accept loop, fork-per-connection, graceful shutdown, socket→Connection |
| [`warp/Network/Wai/Handler/Warp/HTTP1.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs) | 307 | the per-connection request loop (keep-alive/pipelining core) |
| [`warp/Network/Wai/Handler/Warp/Request.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs) | 350 | header-line reassembly, `Expect: 100-continue`, body-source selection, timeout wiring |
| [`warp/Network/Wai/Handler/Warp/RequestHeader.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs) | 139 | request-line / header-line byte parsing |
| [`warp/Network/Wai/Handler/Warp/Header.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Header.hs) | 123 | indexed-header fast path, duplicate-header resolution |
| [`warp/Network/Wai/Handler/Warp/Conduit.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Conduit.hs) | 177 | `ISource`/`CSource`: Content-Length and chunked body readers |
| [`warp/Network/Wai/Handler/Warp/Response.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs) | 600 | keep-alive decision, framing, HEAD/204/304, streaming/chunked output |
| [`warp/Network/Wai/Handler/Warp/ResponseHeader.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/ResponseHeader.hs) | 98 | zero-copy status-line/header serialization into the write buffer |
| [`warp/Network/Wai/Handler/Warp/Settings.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs) | 468 | every limit/timeout default, default error→response mapping |
| [`warp/Network/Wai/Handler/Warp/Types.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Types.hs) | 232 | `Connection`, `Source`, `InvalidRequest`, `Transport` |
| [`warp/Network/Wai/Handler/Warp/IO.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/IO.hs) | 81 | builder→socket draining loop, buffer growth |
| [`warp/Network/Wai/Handler/Warp/Buffer.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Buffer.hs) | 60 | write-buffer allocation |
| [`warp/Network/Wai/Handler/Warp/Counter.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Counter.hs) | 59 | open-connection counter used by graceful shutdown |
| [`warp/Network/Wai/Handler/Warp/ShuttingDown.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/ShuttingDown.hs) | 31 | shutdown flag (`TVar Bool`) |
| [`warp/Network/Wai/Handler/Warp/File.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/File.hs) | 212 (partial) | conditional GET → 304/412/416 |
| [`warp/Network/Wai/Handler/Warp/Imports.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Imports.hs) | — (grepped) | `isAsyncException` |
| [`recv/Network/Socket/BufferPool.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/recv/Network/Socket/BufferPool.hs) | 48 | buffer-pool design note |
| [`recv/Network/Socket/BufferPool/Recv.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/recv/Network/Socket/BufferPool/Recv.hs) | 126 | `receive`, `receiveNoWait`, `recvN` |
| [`time-manager/System/TimeManager.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/TimeManager.hs) | 230 | **current** timeout manager (delegates to GHC's per-capability timer) |
| [`time-manager/System/TimeManager/Internal.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/TimeManager/Internal.hs) | 56 | `Handle`/`Manager` representation |
| [`time-manager/System/ThreadManager.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/ThreadManager.hs) | 278 | kill-thread-on-timeout wrapper used by graceful shutdown |
| [`time-manager/System/TimeManager.hs` @ warp-3.2.28`](https://github.com/yesodweb/wai/blob/d487668804d7a71606d137df3c6d3d1cc359660b/time-manager/System/TimeManager.hs) | 152 | **classic** design: single `Control.Reaper` thread + tickle-able `Handle` |
| [`wai/Network/Wai/Internal.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai/Internal.hs) | 185 | `Request`, `Response`, `StreamingBody`, `ResponseRaw` shapes |
| [`wai/Network/Wai.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai.hs) | 606 (partial) | `Application`, `Middleware`, `responseRaw` docs |
| [`warp/test/RequestSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RequestSpec.hs) | 170 | header-chunking edge cases, `OverLargeHeader` |
| [`warp/test/ConnectionSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ConnectionSpec.hs) | 82 | keep-alive-rule truth table as tests |
| [`warp/test/RunSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs) | 528 | pipelining, chunked bodies, raw/upgrade, timeouts |
| [`warp/test/GracefulShutdownSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/GracefulShutdownSpec.hs) | 140 | shutdown-race and in-flight-request tests |
| [`warp/test/ExceptionSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ExceptionSpec.hs) | 69 | handler-exception → 500 |
| [`warp/test/ServerStateSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ServerStateSpec.hs) | 58 | `ServerState`/counter idempotency |

I also fetched `warp/Network/Wai/Handler/Warp/HTTP2.hs` and `warp/Network/Wai/Handler/Warp/HTTP2/*.hs` only to `grep` them (not deep-read; HTTP/2 is out of scope for a first chez-http-server) to settle the "501/431 dead code" question below.

Commands used (representative):
```
curl -sI https://raw.githubusercontent.com/yesodweb/wai/master/warp/Network/Wai/Handler/Warp/Run.hs   # -> HTTP/2 200
curl -s  https://api.github.com/repos/yesodweb/wai/git/trees/master?recursive=1 -o tree.json
curl -s  https://api.github.com/repos/yesodweb/wai/commits/master   # sha 9581c25…, date 2026-09-18T10:12:25Z
curl -s  https://raw.githubusercontent.com/yesodweb/wai/master/warp/Network/Wai/Handler/Warp/Run.hs -o warp/Network/Wai/Handler/Warp/Run.hs
grep -rn "PayloadTooLarge\|RequestHeaderFieldsTooLarge\|OverLargeHeader" warp/Network/Wai/Handler/Warp/*.hs
```

---

## 1. Keep-alive decision rule

Core function: `checkReqConnectionHeader` — [`Response.hs:511-520`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L511-L520):

```haskell
checkReqConnectionHeader :: Bool -> IndexedRequestHeader -> Bool
checkReqConnectionHeader isHttp11 reqidxhdr =
    case reqidxConnection reqidxhdr of
        Nothing -> isHttp11                              -- no header: HTTP/1.1 default persist, HTTP/1.0 default close
        Just val ->
            let connValue = CI.foldCase val
             in if isHttp11
                    then connValue /= "close"             -- HTTP/1.1: only "close" turns it off
                    else connValue == "keep-alive"         -- HTTP/1.0: only "keep-alive" turns it on
```

This value (`reqSaysPersist`, [`Response.hs:169`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L169)) is then combined with the *response's own* `Connection` header:

```haskell
-- Response.hs:172-198
s = responseStatus response
hs0 = sanitizeHeaders $ responseHeaders response
rspidxhdr = indexResponseHeader hs0
hasLength = hasContentLength rspidxhdr
responseWantsToClose =
    case hasConnection rspidxhdr of
        Nothing -> False
        Just v -> CI.foldCase v == "close"
isPersist = reqSaysPersist && not responseWantsToClose
...
needsChunked = isHttp11 && not hasLength
...
-- Should be False if (http10 && not hasLength), regardless of what
-- the 'Connection' header says. (as long as the response should have a body)
isKeepAlive =
    isPersist && (isHttp11 || hasLength || isHead || not (hasBody s))
```
[`Response.hs:180-198`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L180-L198)

So the full rule, per response kind (`!ret`, [`Response.hs:200-209`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L200-L209)):
- `ResponseBuilder`/`ResponseStream`: persist iff `isKeepAlive`. Because `needsChunked = isHttp11 && not hasLength`, an HTTP/1.1 response with no explicit `Content-Length` is **auto-chunked**, so `hasLength` doesn't matter for HTTP/1.1 keep-alive — the connection stays open regardless. Only for **HTTP/1.0** does the absence of `Content-Length` force close (no `Transfer-Encoding: chunked` in 1.0, so the only way to delimit the body is EOF ⇒ close). This is exactly the "close-delimited response forces close" rule the task asked about, and it is HTTP/1.0-only in Warp because 1.1 always has chunked as a fallback.
- `ResponseFile`: persist iff `isPersist` alone — Content-Length/Content-Range get added later by `addContentHeadersForFilePart`, so by the time this decision is made the file response is assumed to always carry a length ([`Response.hs:200-204`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L200-L204)).
- `ResponseRaw` (upgrade/websocket escape hatch): **always** `False` — an upgraded connection is never reusable as HTTP/1.1 keep-alive ([`Response.hs:206-209`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L208-L209)).

Finally, whatever `shouldPersist` is decided to be, Warp writes the actual `Connection` response header itself (`addConnection`, [`Response.hs:131-138`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L131-L138)):
```haskell
let shouldPersist = not isShuttingDown && ret
    addConnection hs =
        if shouldPersist || responseWantsToClose
            then hs
            else (Header.hConnection, "close") : hs
```
i.e. **Warp inserts `Connection: close` itself whenever it decides not to persist**, even if the app never mentioned `Connection` at all, and even if the request was `HTTP/1.0 Connection: Keep-Alive` — the client always gets an explicit signal, it is never left to infer close-from-EOF silently. `isShuttingDown` is also folded directly into the persistence decision — mid-shutdown, every response gets `Connection: close` regardless of what the request/response headers said (§11).

Test evidence for this exact truth table: [`ConnectionSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ConnectionSpec.hs) — HTTP/1.0 + `Connection: Keep-Alive` + no `Content-Length` ⇒ still closes with `Connection: close` sent ([`ConnectionSpec.hs:16-25`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ConnectionSpec.hs#L16-L25)); HTTP/1.1 HEAD never gets a spurious `Connection: close` ([`ConnectionSpec.hs:33-42`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ConnectionSpec.hs#L33-L42)); explicit `Connection: close` on 200/204/500 all close ([`ConnectionSpec.hs:43-58`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ConnectionSpec.hs#L43-L58)).

---

## 2. Pipelining policy and response ordering

Warp's HTTP/1 handler is a **strictly sequential, blocking, single-thread-per-connection loop** — [`HTTP1.hs:138-170`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L138-L170):
```haskell
loop firstRequest = do
    (req, mremainingRef, idxhdr, nextBodyFlush) <-
        recvRequest firstRequest settings conn ii th addr src transport
    keepAlive <- processRequest settings ii conn app th istatus src req
                    mremainingRef idxhdr nextBodyFlush `catch` ...
    case keepAlive of
        ReuseConnection -> loop SubsequentRequest
        CloseConnection -> return ()
```
There is no concurrency inside a single HTTP/1 connection: `processRequest` fully runs the WAI `Application` and fully sends the response (`sendResponse`, synchronous) before `loop` reads the next request. This makes response ordering trivially correct (FIFO by construction — there is nothing to reorder) at the cost of no request-level concurrency on one TCP connection; concurrency instead comes from one OS/green thread **per connection** (`fork`, [`Run.hs:405-419`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L405-L419)).

Pipelining itself needs no special-case code beyond this loop plus one connection-scoped `Source` (a 1-slot leftover buffer over the raw `recv`, [`Types.hs:163-191`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Types.hs#L163-L191)) that is created once in `http1` and threaded through every iteration of `loop` ([`HTTP1.hs:41-46`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L41-L46)). Bytes of request N+1 that arrive in the same `recv()` as the tail of request N simply sit in that `Source`'s `leftoverSource` `IORef` until `loop` calls `headerLines` again. `parser-feed!`'s `consumed` byte count plays the same role for us.

**The correctness-critical rule is: before reusing the connection, Warp must fully drain request N's body**, even if the application handler never read it — otherwise those bytes would be misparsed as the start of request N+1's headers. This is `processRequest`'s job after the response is sent ([`HTTP1.hs:226-251`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L226-L251)):
```haskell
if keepAlive
    then case settingsMaximumBodyFlush settings of
            Nothing -> do
                flushEntireBody nextBodyFlush          -- read-and-discard until empty, no bound
                T.resume th
                return ReuseConnection
            Just maxToRead -> do                        -- default: Just 8192
                let tryKeepAlive = do
                        isComplete <- flushBody nextBodyFlush maxToRead
                        if isComplete then do T.resume th; return ReuseConnection
                                       else return CloseConnection
                case mremainingRef of
                    Just ref -> do
                        remaining <- readIORef ref
                        if remaining <= maxToRead then tryKeepAlive else return CloseConnection
                    Nothing -> tryKeepAlive             -- chunked body: no known remaining length, always tries to flush
```
So: known-length bodies skip the flush attempt entirely (and go straight to `CloseConnection`) if the *declared remaining* Content-Length exceeds `settingsMaximumBodyFlush` (default `8192` bytes, [`Settings.hs:327`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L327)); chunked bodies always attempt the flush (bounded by the same 8192-byte budget via `flushBody`'s counting loop, [`HTTP1.hs:290-307`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L290-L307)) since their true length isn't known upfront. Either way, the point is: **an app that ignores the request body does not by itself force connection close** — Warp silently drains up to 8 KiB for it — but a large unread body does force close rather than pay an unbounded drain cost.

`recvRequest`'s treatment of "no bytes available" differs by `FirstRequest` vs `SubsequentRequest` — [`Request.hs:124-140`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L124-L140):
```haskell
headerLines maxTotalHeaderLength firstRequest src = do
    bs <- readSource src
    if S.null bs
        then case firstRequest of
              FirstRequest -> throwIO ConnectionClosedByPeer
              SubsequentRequest -> throwIO NoKeepAliveRequest
        else push maxTotalHeaderLength src (THStatus 0 0 id id) bs
```
and `NoKeepAliveRequest`/`BadFirstLine` are the two exceptions `http1server`'s handler swallows **completely silently** (no response, no rethrow, no log) — [`HTTP1.hs:117-136`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L119-L124), with a comment pointing at https://github.com/yesodweb/wai/issues/618 for the rationale (client just closed a keep-alive connection instead of sending another request — a completely ordinary event, not an error worth logging). This distinguishes cleanly from the first byte(s) of a *new* connection never arriving at all (treated as `ConnectionClosedByPeer`, itself excluded from `sendErrorResponse` too — [`HTTP1.hs:277-279`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L277-L279)) vs a malformed but non-empty request line on a reused connection (`BadFirstLine`, silently closed rather than answered with 400 — see §9 for why this matters for us).

Test evidence: [`RunSpec.hs:231-261`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L231-L261) sends 5 concatenated `GET`s (and Content-Length/chunked-body variants) as a *single* `msWrite`, i.e. genuinely pipelined on the wire, and checks all 5 responses come back correctly and in order; [`RunSpec.hs:262-267`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L262-L267) "no hanging" sends the request **one byte at a time** to prove the header/body parser doesn't block waiting for a full read.

---

## 3. Request-body streaming and backpressure

The `Request.requestBody :: IO ByteString` handed to the `Application` is a **pull** interface: nothing is read off the socket ahead of the application calling it. This is the core backpressure mechanism, and it needs no explicit flow-control protocol because Warp is one-blocking-thread-per-connection: if the app doesn't call `requestBody`, `connRecv` (ultimately a blocking `Network.Socket.recvBuf`/`recvBuf`, via `receive` — [`Recv.hs:23-24`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/recv/Network/Socket/BufferPool/Recv.hs#L23-L24)) is simply never invoked, so the OS's own TCP receive-window mechanics apply — the kernel buffer fills and the peer's writes eventually block. There's no analogue of `uv-read-stop!` needed because there was never a `uv-read-start!`-style always-on callback: **reads are demand-driven, not callback-driven**, which is the opposite default from libuv/our `on-data` callback model — worth internalizing early (§16).

Two body sources, chosen once per request by `bodyAndSource` — [`Request.hs:160-186`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L160-L186):
```haskell
bodyAndSource src idxhdr
    | chunked = do
        csrc <- mkCSource src
        return (readCSource csrc, Nothing, ChunkedBody)
    | otherwise = do
        let len = toLength $ reqidxContentLength idxhdr    -- Nothing -> 0
            bodyLen = KnownLength $ fromIntegral len
        isrc@(ISource _ remaining) <- mkISource src len
        return (readISource isrc, Just remaining, bodyLen)
  where
    chunked = isChunked $ reqidxTransferEncoding idxhdr
```
`chunked` wins outright whenever `Transfer-Encoding` says so — Content-Length is never consulted once TE is chunked (framing-precedence detail, see §9).

- **`ISource`** (Content-Length body), `readISource` — [`Conduit.hs:16-63`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Conduit.hs#L16-L63): tracks a mutable remaining-byte count in an `IORef`; each call reads one underlying chunk, clamps it to the remaining count (`min count (S.length bs)`), pushes any excess back onto the connection's `Source` via `leftoverSource` (so it becomes the head of the *next* request's byte stream — this is the pipelining boundary), and **throws `ConnectionClosedByPeer` if the socket EOFs before the declared length is satisfied**.
- **`CSource`** (chunked body), `readCSource` — [`Conduit.hs:67-176`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Conduit.hs#L67-L176): a small state machine (`NeedLen | NeedLenNewline | HaveLen Word | DoneChunking`) that parses one `<hex-len>\r\n` chunk header at a time, yields exactly that many body bytes per call (splitting/buffering across `recv` boundaries as needed), and drops the trailing CRLF after each chunk and the final `0\r\n` terminator's CRLF. No trailer-header support is implemented (`dropCRLF`/`dropLF` just consume up to the first LF after the zero-chunk, discarding whatever's there).

Both are then wrapped once more by `timeoutBody` — [`Request.hs:190-236`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L190-L236) — which on the **first** chunk pull (a) sends the buffered `100-continue` if one is owed (§7) and (b) calls `Timeout.resume` to re-arm the idle timer for body reading (it was paused right after headers were parsed, see §12), and on **every** pull, once the body reports empty/exhausted, calls `Timeout.pause` again. So the idle timeout genuinely tracks "is data actively flowing", not wall-clock-since-request-start: a slow but steady drip of body bytes keeps resetting the timer (subject to the Slowloris floor, §6), while a body the app never asks for again (past the first byte) is not silently timed out mid-handler — the timer is paused while the app is just computing, and only re-armed around actual I/O.

`getRequestBodyChunk`, the modern non-deprecated alias the task asked about, is literally `requestBody` — [`wai/Network/Wai/Internal.hs:106-111`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai/Internal.hs#L106-L111):
```haskell
getRequestBodyChunk :: Request -> IO B.ByteString
getRequestBodyChunk = requestBody
```
— confirming this is purely a rename for a misleading name (the field looks like "the whole body" but is "one chunk"), not a different mechanism.

Test evidence for chunked-body correctness, including deliberately fragmented wire input: [`RunSpec.hs:314-396`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L314-L396) (`"works"`, `"lots of chunks"` — 50×5-byte chunks, `"in chunks"` — every single byte of the wire input written in its own `msWrite`/`send()` call). Idle-timeout-during-body-streaming is explicitly tested at [`RunSpec.hs:397-430`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L397-L430): `setTimeout 1`, body written in two halves 100ms apart (well under the 1s timeout, so it must **not** fire) then the handler `threadDelay`s 500ms after fully consuming the body, asserting the delay itself is *not* interrupted (proving pause/resume, not just tickle, is in effect during app computation).

---

## 4. Response-body streaming and backpressure

Three response constructors reach `sendRsp` (a `Rsp` sum after HEAD/204/304-stripping is applied in `sendResponse`, [`Response.hs:186-194`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L186-L194)):

- **`RspBuilder`** (`responseBuilder`) — [`Response.hs:291-327`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L291-L327): the whole `Builder` is realized through `unsafeToBufIOWithOffset`/`toBufIOWith` ([`IO.hs:31-80`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/IO.hs#L38-L80)), which drives GHC's `Builder`'s own `runBuilder` state machine into the connection's 16 KiB write buffer (`createWriteBuffer 16384`, [`Run.hs:77`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L77)), flushing to the socket (`bufferIO … io`, a **blocking** `connSendAll`) every time the buffer fills, and — notably — growing the buffer (freeing the old one, `mallocBytes`ing a bigger one, [`IO.hs:52-75`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/IO.hs#L60-L75)) if a single `Builder` chunk (e.g. a big strict `ByteString` embedded via `byteString`) doesn't fit, capped by `settingsMaxBuilderResponseBufferSize` (default `1049000000` bytes — see the doc-mismatch note in §6) beyond which it's a hard `error` (crashes the connection thread, caught generically as a 500 by the outer handler in `processRequest`, not a graceful 413-style response).
- **`RspStream`** (`responseStream`) — [`Response.hs:331-362`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L331-L362): the app is handed a `send :: Builder -> IO ()` and a `flush :: IO ()` action (`StreamingBody = (Builder -> IO ()) -> IO () -> IO ()`, [`wai/Network/Wai/Internal.hs:156`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai/Internal.hs#L156)) and drives its own control flow (`streamingBody sendChunk (sendChunk flush)`). Each `send` call goes through `newByteStringBuilderRecv`'s incremental "popper" (`reuseBufferStrategy` over the *same* connection write buffer — no per-call allocation) and each resulting fragment is written with `sendFragment`, which **also brackets the timeout handle around the actual socket write**: `T.resume th; send bs; T.pause th` ([`Response.hs:497-501`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L497-L501)) — i.e. the idle timer is only "hot" while a `sendAll` syscall is actually blocked in the kernel, not while the app is between `write` calls computing the next chunk. Because `connSendAll` is a **blocking** `Network.Socket.ByteString.sendAll`, TCP backpressure (a full send buffer / slow reader) directly blocks the app's producer thread — no queue, no explicit "drain" signal needed, same one-thread-per-connection trick as the read side.
- **`RspFile`** (`responseFile`) — [`Response.hs:385-464`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L385-L464): headers go through the normal buffer, body goes through `connSendFile` (`sendfile(2)` where available, chunked fallback in `SendFile.hs`, not deep-read here since libuv doesn't expose `sendfile` and it's out of scope for a first cut) — again a blocking call, same backpressure story.
- **`RspRaw`** (`responseRaw`, the upgrade escape hatch) — [`Response.hs:371-379`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L371-L379): Warp writes **nothing** of its own (no status line, no headers) — `withApp recv send; return (Nothing, Nothing)` — the app's callback gets raw `recv`/`send` actions over the live connection and is 100% responsible for producing valid bytes (e.g. a `101 Switching Protocols` line) itself. `recv`/`send` here still route through `T.tickle th` on activity ([`Response.hs:375-379`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L375-L379)) so the idle timeout keeps applying even after upgrade.

Byte-accounting for `settingsLogger` is done by literally summing the lengths of every fragment actually handed to `connSendAll`/`popper` ([`Response.hs:339-367`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L339-L367)), not derived from a header — this is a nice invariant-check idea for our own access-log/metrics story (log what actually went on the wire, not what was declared).

Test evidence: `"streaming echo #249"` ([`RunSpec.hs:466-…`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L466)) round-trips request-body chunks straight into response-body writes, exercising both streaming directions concurrently in one handler; `"raw body" "works"` ([`RunSpec.hs:431-447`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L431-L447)) exercises `responseRaw` end to end, writing to the socket in two separate bursts and asserting each is echoed back doubled before the second burst is even sent — proving the raw path is genuinely interactive/streaming, not buffered.

---

## 5. Expect: 100-continue

Handling is entirely inside `recvRequest`/`timeoutBody`, **not** eagerly on header parse — the `100 Continue` line is only sent lazily, the first time the app actually pulls a body byte:
```haskell
-- Request.hs:83-89
let idxhdr = indexRequestHeader hdr
    expect = reqidxExpect idxhdr
    handle100Continue = handleExpect conn httpversion expect
(rbody, remainingRef, bodyLength) <- bodyAndSource src idxhdr
rbody' <- timeoutBody remainingRef th rbody handle100Continue
```
```haskell
-- Request.hs:144-156
handleExpect :: Connection -> H.HttpVersion -> Maybe HeaderValue -> IO ()
handleExpect conn ver (Just "100-continue") = do
    connSendAll conn continue
    Conc.yield
  where
    continue
        | ver == H.http11 = "HTTP/1.1 100 Continue\r\n\r\n"
        | otherwise = "HTTP/1.0 100 Continue\r\n\r\n"
handleExpect _ _ _ = return ()
```
and `timeoutBody` gates the call to exactly the **first** invocation of the returned action via an `isFirstRef :: IORef Bool` ([`Request.hs:197-225`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L197-L225)). Consequences worth copying:
- The match is a **literal, case-sensitive** `"100-continue"` bytestring equality against the raw header value (no trimming/case-folding shown — worth double-checking against RFC 9110 §10.1.1 case-insensitivity when we implement this; this looks like a possible minor Warp looseness, not something to copy uncritically).
- If the app **never reads the body at all**, no `100 Continue` is ever sent — this is correct per RFC 9110 (only send it if you intend to read the body) but means an app that always drains-and-ignores the body (as our keep-alive flush path does, §2!) will still trigger the 100-continue, since `flushEntireBody`/`flushBody` call the *same* wrapped body-reading action.
- There is a **second, header-less body accessor** built in parallel purely for the post-response drain path — `rbodyFlush <- timeoutBody remainingRef th rbody (return ())` ([`Request.hs:89`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L89)) — with `handle100Continue = return ()`, i.e. Warp deliberately builds *two* wrappers over the same underlying body reader, one used by the app (can trigger 100-continue) and one used internally for keep-alive draining (never does, since by then any 100-continue window is long past and the client already knows the outcome).
- No handling at all for `Expect` values other than exactly `"100-continue"` (e.g. no `417 Expectation Failed` for unknown expectations) — Warp simply ignores anything else.

---

## 6. Every named limit/timeout, with its default (all from [`Settings.hs:308-341`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L308-L341) unless noted)

| Setting | Default | Unit | Meaning / enforcement site |
|---|---|---|---|
| `settingsTimeout` | **30** | seconds | Idle-connection timeout; converted to microseconds and fed to the timeout manager at [`Run.hs:299-306`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L299-L306). Governs header read, body read (when active), and response send — never wall-clock-from-connect. |
| `settingsSlowlorisSize` | **2048** | bytes | A `recv()` result smaller than this does **not** tickle the timeout handle ([`HTTP1.hs:48-53`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L48-L53)) — anti-Slowloris: a client trickling 1 byte at a time never resets the 30s clock. |
| `settingsMaxTotalHeaderLength` | **50 × 1024 = 51200** | bytes | Total header-block byte budget (request line + all header lines, CRLFs included via running `chunkLen`), enforced incrementally in `push` — [`Request.hs:263,268`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L263). Throws `OverLargeHeader`. |
| `settingsMaximumBodyFlush` | **`Just 8192`** | bytes | Cap on how much of an app-unread request body Warp will drain to make the connection reusable (§2). `Nothing` = unbounded drain. |
| `settingsGracefulShutdownTimeout` | **`Nothing`** (unbounded) | seconds | Cap on how long `gracefulShutdown` waits for `Counter` to reach 0 before giving up — [`Run.hs:532-546`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L532-L546). |
| `settingsGracefulCloseTimeout1` | **0** (immediate `close()`, no lingering wait) | milliseconds | HTTP/1.x lingering-close FIN wait, via `gracefulClose` (§10). |
| `settingsGracefulCloseTimeout2` | **2000** | milliseconds | Same, for HTTP/2. |
| `settingsMaxBuilderResponseBufferSize` | **1049000000** (doc comment says "1 MiB" — **numeric/comment mismatch confirmed by direct read**, see below) | bytes | Hard cap on how big the write buffer may grow for a single `Builder`/streamed-chunk write before Warp gives up with a Haskell `error` (uncaught crash of the connection thread → generic 500 path, not a clean 413). |
| `settingsFdCacheDuration` | **0** (disabled) | seconds | File-descriptor cache TTL for `responseFile`. |
| `settingsFileInfoCacheDuration` | **0** (disabled) | seconds | `stat()` result cache TTL. |
| `settingsHTTP2Enabled` | **True** | — | ALPN/h2c upgrade eligibility. |
| `settingsPort` | 3000 | — | not connection-semantics, listed for completeness. |
| Write buffer initial size | **16384** | bytes | `createWriteBuffer 16384`, [`Run.hs:77`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L77) — hardcoded, not a `Settings` field. |
| Recv buffer pool | **min 2048 / max 16384** | bytes | `newBufferPool 2048 16384`, [`Run.hs:76`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L76) — hardcoded. |
| Proxy-protocol / accept-loop `eMFILE` backoff | — | — | Not a fixed timer: on file-descriptor exhaustion the accept loop calls `waitForDecreased counter` and blocks (STM `retry`) until some connection closes, rather than sleeping a fixed interval — [`Run.hs:389-401`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L389-L401), [`Counter.hs:32-40`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Counter.hs#L32-L40). |

**On the `settingsMaxBuilderResponseBufferSize` doc/value mismatch**: the haddock at [`Settings.hs:181-194`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L181-L194) says *"Default: 1049_000_000 = 1 MiB."* but `1_049_000_000` bytes is ≈1.05 GB, not 1 MiB (1 MiB = 1,048,576 bytes; `1_049_000` would be ≈1 MB). I checked the literal at [`Settings.hs:338`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L338) directly (`, settingsMaxBuilderResponseBufferSize = 1049000000`) — the code value is unambiguous, the *comment* is stale/wrong by 1000×. Flagging because it's exactly the kind of thing that's easy to cargo-cult from a doc comment instead of the actual constant. **Lesson: when we port a limit, copy the literal, not the prose next to it, and double-check both against upstream test/behavior if possible.**

**There is no request-line/header read-timeout distinct from the general idle timeout** — headers, body, and response are all covered by the same single `T.Handle` per connection, paused only around app-computation, not around I/O phases separately (§12). There is also no separate "keep-alive idle timeout" distinct from the request-processing idle timeout — it's the same handle, same 30s, reused across `loop` iterations (the `th` in `http1server` is created once per connection in `fork`/`serve`, [`Run.hs:451`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L451), and threaded through every `recvRequest`/`processRequest` call).

---

## 7. Upgrade / CONNECT

Grepped the whole fetched tree for `CONNECT`/`Upgrade`/`upgrade`; the **only** hits are a `settingsHTTP2Enabled` doc comment ("ALPN/upgrades", meaning h2c, not generic HTTP Upgrade) and `responseRaw`'s haddock. **Warp's HTTP/1 layer has no built-in `Upgrade:` header parsing, no `101 Switching Protocols` generation, and no `CONNECT` method special-casing at all.** The entire mechanism is delegated to the application via `responseRaw` (§4): the app decides from the request headers whether to upgrade, and if so returns a `Response` built with `responseRaw rawApp backupResponse` where `rawApp :: IO ByteString -> (ByteString -> IO ()) -> IO ()` gets raw, already-established-connection `recv`/`send` actions and is expected to write its own status line/headers (e.g. `101`) and then speak whatever protocol it wants (e.g. WebSocket frames) over the same socket — [`wai/Network/Wai.hs:199-213`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai.hs#L199-L213):
> "Create a response for a raw application. This is useful for 'upgrade' situations such as WebSockets... This function requires a backup response to be provided, for the case where the handler in question does not support such upgrading (e.g., CGI apps)."

The `backupResponse` argument exists purely so the same `Application` is portable to WAI backends (e.g. CGI) that *don't* support raw takeover — those backends just use the ordinary `Response` and ignore the raw callback. Warp itself always honors the raw path when the response reaches `sendRsp`'s `RspRaw` arm (§4) — for HTTP/1 only; nothing in the fetched HTTP/2 files references `ResponseRaw`/`RspRaw` (grepped, no hits), so `responseRaw` is HTTP/1.x-specific in Warp, as expected (HTTP/2 has its own native stream/RST semantics, no need for a raw escape hatch, and no CONNECT-tunnel support was found there either).

CONNECT specifically: no distinct handling was found anywhere in the request-line parser (`parseRequestLine`, [`RequestHeader.hs:57-121`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L57-L121)) — a `CONNECT` request line parses like any other method/path/version triple, and it's entirely up to the application to recognize `requestMethod == "CONNECT"` and respond with `responseRaw` if it wants tunnel semantics.

**Lesson for us**: don't build Upgrade/CONNECT protocol logic into the connection layer at all — expose the moral equivalent of `responseRaw` (a way for the handler to say "here are the raw send/recv procedures, I'm taking over") as the *only* upgrade primitive, and keep our own core completely ignorant of what upgrade protocols exist. This also cleanly sidesteps needing keep-alive/framing logic to understand upgrades: `ResponseRaw` unconditionally forces `shouldPersist = False` in Warp's model, i.e. **the connection is presumed to be handed off, not returned to the request/response loop** — worth deciding explicitly whether that's also our model, or whether we want a way to "downgrade" back to HTTP after a raw interlude (Warp doesn't support that; once `RspRaw` runs, `serveConnection`'s `http1`/`http1server` loop is not re-entered — the `withApp recv send` call is the last thing `sendRsp` does before `sendResponse` returns).

---

## 8. Framing precedence (Content-Length vs Transfer-Encoding; duplicates; HEAD; 1xx/204/304)

**Request side — TE beats CL outright, no smuggling defense**: `bodyAndSource`'s `chunked` guard ([`Request.hs:160-186`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L160-L186), quoted in §3) checks `Transfer-Encoding` **first**; if it case-folds to exactly `"chunked"` ([`Request.hs:184-186`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L184-L186): `isChunked (Just bs) = CI.foldCase bs == "chunked"`), Content-Length is **never even read** for body-length purposes — no rejection of a request carrying *both* headers, no comparison, no error. If `Transfer-Encoding` is present but not exactly `"chunked"` (e.g. `"gzip"`, `"gzip, chunked"` with something after, or a bogus value), `isChunked` returns `False` and Warp silently falls back to Content-Length framing (defaulting to `0` if that's also absent — [`Request.hs:180-182`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L180-L182): `toLength Nothing = 0`).

**Duplicate headers — last occurrence silently wins for every header Warp itself inspects.** `indexRequestHeader` is a left fold that unconditionally overwrites on each match ([`Header.hs:39-59`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Header.hs#L39-L59)):
```haskell
indexRequestHeader = L.foldl' insert defaultIndexRequestHeader
  where
    insert ix (key, val) = case BS.length bs of
        14 | bs == "content-length" -> ix{reqidxContentLength = Just val}
        17 | bs == "transfer-encoding" -> ix{reqidxTransferEncoding = Just val}
        ...
```
So two `Content-Length` headers (a classic request-smuggling vector) are **not rejected** — Warp just uses the *last* one for its own body-framing decision, while `requestHeaders` (the full list handed to the app) still contains **both**, in original order — [`Request.hs:100-119`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L108) (`requestHeaders = hdr`, unfiltered). This is a real gap relative to llhttp/RFC 9112 §6.3, which mandates rejecting messages with multiple conflicting `Content-Length` values or both `Content-Length` and `Transfer-Encoding`. **This is exactly the kind of strictness our chez-httparse (llhttp-conformant) parser already buys us over Warp's own parser** — worth calling out explicitly as a place we should be *stricter* than the reference implementation, not copy its looseness.

**Response side**: `needsChunked = isHttp11 && not hasLength` ([`Response.hs:185`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L185)) — i.e. Warp adds `Transfer-Encoding: chunked` itself, on HTTP/1.1 only, whenever the app didn't set `Content-Length`; it never adds `Content-Length` on the app's behalf for `ResponseBuilder`/`ResponseStream` (only `ResponseFile` computes and inserts one, via `addContentHeadersForFilePart` — not deep-read here, see `File.hs`). `addTransferEncoding` even handles the (unusual) case where the app itself already set some other `Transfer-Encoding` (e.g. via a compression middleware) by **appending** `, chunked` rather than clobbering it ([`Response.hs:541-545`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L541-L545)).

**HEAD**: handled by constructing `RspNoBody` for `ResponseBuilder`/`ResponseStream`/`ResponseFile` up front ([`Response.hs:186-194`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L189-L193), [`Response.hs:453-457`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L453-L457)) — the status line and **whatever headers the app supplied are sent verbatim**, only the body is suppressed. Crucially, `RspNoBody`'s `sendRsp` does **not** synthesize a `Content-Length: 0`:
```haskell
-- Response.hs:283-287
sendRsp conn _ _ ver s hs _ _ _ RspNoBody = do
    -- Not adding Content-Length.
    -- User agents treats it as Content-Length: 0.
    composeHeader ver s hs >>= connSendAll conn
    return (Just s, Just 0)
```
i.e. **a HEAD response for a GET that would have returned `Content-Length: N` correctly still carries that same `N`** (the app's headers pass through untouched), letting the client learn the resource's size from HEAD as RFC 9110 §9.3.2 requires — Warp relies on the app having set a correct Content-Length for what the *GET* response would be, it doesn't compute anything itself for the builder/stream case (only `ResponseFile`'s HEAD path has a `FIXME` noting it could look up file size but currently doesn't — [`Response.hs:453-457`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L454-L457)).

**1xx/204/304**: a single predicate decides body-presence for *all* of these at once — [`Response.hs:527-533`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L527-L533):
```haskell
-- | Only checks for status codes, NOT for methods.
hasBody :: H.Status -> Bool
hasBody s = sc /= 204 && sc /= 304 && sc >= 200
  where sc = H.statusCode s
```
so `sc >= 200` excludes every 1xx status too (100–199 all body-less), plus the two explicit exclusions 204 and 304 (not 205, not 1xx-other-than-100 individually listed — the `>= 200` bound handles the whole 1xx class in one comparison). The doc comment is explicit that this is **status-only**, deliberately independent of method, because HEAD is handled as an orthogonal, separate check earlier in `sendResponse` (`isHead = method == H.methodHead`, [`Response.hs:166`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L166)) — the two concerns are intentionally kept separable in the code, which is a clean design choice worth copying (one predicate for "does *this status* ever have a body", one separate flag for "was this a HEAD request", combined at the call site rather than one combined mega-predicate).

---

## 9. Parse/policy/handler-error → HTTP-response mapping, and whether the connection closes

Default mapping, `defaultOnExceptionResponse` — [`Settings.hs:393-415`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L393-L415):
```haskell
defaultOnExceptionResponse e
    | isAsyncException e = throw e
    | Just PayloadTooLarge <- fromException e = responseLBS status413 ... "Payload too large"
    | Just RequestHeaderFieldsTooLarge <- fromException e = responseLBS status431 ... "Request header fields too large"
    | Just (_ :: InvalidRequest) <- fromException e = responseLBS badRequest400 ... "Bad Request"
    | otherwise = responseLBS internalServerError500 ... "Something went wrong"
```
Cross-referenced against where each `InvalidRequest` constructor is actually **thrown** in the fetched HTTP/1 tree (`grep -rn`, and I additionally fetched and grepped `HTTP2.hs`/`HTTP2/*.hs` to rule out an HTTP/2-only throw site):

| Constructor | Thrown at | Status actually produced |
|---|---|---|
| `NotEnoughLines` | [`RequestHeader.hs:36`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L36) — empty header-line list | 400 (falls to catch-all `InvalidRequest`) |
| `BadFirstLine` | [`RequestHeader.hs:66,72,78,97`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L97) — malformed request line | **Never reaches `sendErrorResponse` at all** — `http1server`'s own `handler` special-cases it to a silent `return ()` before the generic branch ([`HTTP1.hs:124`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L124)). **No 400 is ever sent on the wire for a bad request line — the connection is just closed.** |
| `NonHttp` | [`RequestHeader.hs:101`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L101) — request line names a non-HTTP protocol | 400 |
| `IncompleteHeaders` | [`Request.hs:277`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L277) — EOF mid-header-block | 400 (but see `ConnectionClosedByPeer` note below — often the *other* exception fires first) |
| `ConnectionClosedByPeer` | [`Request.hs:134`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L134) (no bytes at all on a first-ever request) and [`Conduit.hs:37`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Conduit.hs#L37) (EOF before declared Content-Length satisfied) | **Explicitly excluded from `sendErrorResponse`** — `shouldSendErrorResponse` returns `False` for it ([`HTTP1.hs:277-278`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L277-L278)) since the peer is already gone; **no response sent, connection closed.** |
| `OverLargeHeader` | [`Request.hs:263,268`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L263) — header block exceeds `settingsMaxTotalHeaderLength` | **400**, not 431 — see finding below. |
| `BadProxyHeader` | [`HTTP1.hs:98`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L98) — malformed PROXY-protocol preamble | 400 |
| `PayloadTooLarge` | **never thrown anywhere in the fetched tree** (`warp/`, `recv/`, `time-manager/`, `wai/`, and grepped `HTTP2*` — zero hits besides the `Settings.hs` mapping and `Types.hs` definition/`Show`) | dead code path in-tree; only reachable if a library *user* throws it themselves (the constructor is re-exported via `InvalidRequest(..)` from `Network.Wai.Handler.Warp` — [`Warp.hs:129`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp.hs#L129)) |
| `RequestHeaderFieldsTooLarge` | **same — never thrown in-tree**, same re-export | dead code path in-tree |

**Two findings worth flagging explicitly, both directly read from source rather than assumed:**
1. **Warp's own oversized-header enforcement maps to 400, not 431**, despite `settingsMaxTotalHeaderLength`'s doc comment at [`Settings.hs:171-174`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L171-L174) and the changelog note at [`Settings.hs:390-392`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L390-L392) ("Sending 431 for too large payload... Sending 413... @since 3.2.27") suggesting otherwise. The RFC-correct status for this situation is 431 (RFC 6585) — this looks like upstream drift (the 413/431 machinery was added for a purpose the actual header-length check doesn't use) rather than an intentional 400. **We should send 431 for oversized headers ourselves** rather than copy this inconsistency, while still copying Warp's overall strategy of exception-typed → status-typed mapping.
2. **Several 4xx/5xx cases that "feel like errors" are actually silent connection drops with zero response bytes**: `BadFirstLine`, `NoKeepAliveRequest`, `ConnectionClosedByPeer`. This is deliberate and RFC-sound (you can't meaningfully answer a peer that already hung up, or reliably parse a status line onto a stream whose framing you can't trust), but it means **"malformed request → 400" is not a universal rule in Warp** — it depends on *when* in the connection's life the malformation is discovered. First-request-ever + garbage bytes ⇒ closed, no bytes. Nth-request-on-keep-alive + empty read ⇒ closed, no bytes (indistinguishable from a normal keep-alive close from the wire). Nth-request-on-keep-alive + garbage first line ⇒ **also** closed, no bytes (this one surprised me — I'd have expected a 400 here since there clearly *was* a next request attempted; instead `BadFirstLine` is treated the same as "client just closed the connection"). Only genuinely mid-message malformations (bad headers, `NonHttp`, oversized headers, bad PROXY preamble) get an actual 400 on the wire.

**No 408 (Request Timeout) is ever produced.** I traced this precisely: `TimeoutThread` (the exception the timeout manager throws into a stalled connection thread, [`TimeManager.hs:187-194`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/TimeManager.hs#L187-L194)) declares itself an **asynchronous** exception (`toException = asyncExceptionToException`), and `http1server`'s handler explicitly rethrows (without answering) anything `isAsyncException` returns `True` for — [`HTTP1.hs:125`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L125), backed by [`Imports.hs:30-34`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Imports.hs#L30-L34) (`SomeAsyncException` pattern match). **An idle-timed-out connection is just closed** (immediately, per the default `settingsGracefulCloseTimeout1 = 0`, §10) — no 408 status line is composed anywhere in this codebase (grepped `status408`/`requestTimeout408` — zero hits in the fetched tree).

**No 501 (Not Implemented)** either — grepped `notImplemented501`/`501` — zero hits. Warp does not restrict HTTP methods at all; any method string parses fine at the request-line level (`parseRequestLine` just slices whatever's between the two spaces, [`RequestHeader.hs:87`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L87)), and it is entirely the `Application`'s job to 405/501 an unsupported method if it cares to.

**No 505 (HTTP Version Not Supported)** either, and this one is the most surprising: `httpVersion` ([`RequestHeader.hs:109-116`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L109-L116)) **silently coerces any unrecognized version to `HTTP/1.0`**:
```haskell
httpVersion httpptr = do
    major <- peek (httpptr `plusPtr` 5) :: IO Word8
    minor <- peek (httpptr `plusPtr` 7) :: IO Word8
    let version
            | major == _1 = if minor == _1 then H.http11 else H.http10
            | major == _2 && minor == _0 = H.http20
            | otherwise = H.http10
    return version
```
so `HTTP/9.9`, `HTTP/0.9`, `HTTP/1.7` all parse successfully and are treated as `HTTP/1.0` (i.e. no chunked-encoding-on-response, default-close persistence) rather than being rejected with 505 or even distinguished from a "real" 1.0 request. `checkHTTP` ([`RequestHeader.hs:102-108`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/RequestHeader.hs#L102-L108)) does validate the literal bytes `"HTTP/"` and the `.` separator position (so `HTTP_1.1` or garbage there throws `NonHttp`), but never validates the version *digits* are `0`–`9` at all — a non-digit byte there just fails the `== _1`/`== _2` equality checks and falls through to the `H.http10` default, no error raised. **Lesson: we should validate and reject unsupported major versions explicitly** (this is squarely inside llhttp/chez-httparse's territory anyway — llhttp fixtures presumably already cover bogus version bytes; make sure our connection layer doesn't quietly downgrade a version chez-httparse successfully parsed but which our policy wants to refuse).

`ExceptionInsideResponseBody` ([`Types.hs:66-76`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Types.hs#L66-L76)) is the "too late to change the status" case: once `sendResponse`'s inner callback has started writing bytes (status line + headers already on the wire), a later exception from the streaming body **cannot** turn into a fresh error response — `processRequest` unwraps and rethrows it specifically to bypass `sendErrorResponse`, [`HTTP1.hs:206-207`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L206-L207) — the connection is simply torn down; there's no way to un-send a 200 and its headers. **We need the equivalent state flag** (Warp's is `istatus :: IORef Bool`, flipped to `False` the instant headers are sent, [`HTTP1.hs:200`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L200), consulted by `sendErrorResponse` at [`HTTP1.hs:262-264`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L262-L264) to refuse sending a second, conflicting response).

**Every one of these synchronous-error 400/413/431/500 paths closes the connection afterward regardless of keep-alive negotiation** — `sendErrorResponse`'s own call to `sendResponse` returns a `Bool` persistence value like any other response ([`HTTP1.hs:253-280`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L253-L280)) so in principle it *could* keep-alive, but `http1server`'s `handler` always calls `throwIO e` right after sending it ([`HTTP1.hs:135-136`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L135-L136)), which unwinds out of `loop` entirely — **so in practice every error response is connection-closing in Warp**, independent of what `Connection` header it happened to compose. Application-level handler exceptions go through a slightly different path (`processRequest`'s own `Left e` branch, [`HTTP1.hs:206-212`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L206-L212)) that *does* respect `sendErrorResponse`'s returned persistence flag (`writeIORef keepAliveRef keepAlive` without a following `throwIO`) — so a plain application exception (500) *can* keep the connection alive for the next pipelined request, but a protocol-level parse error cannot. This asymmetry (parse errors always close; handler exceptions may not) is a deliberate, sensible split and worth replicating: a parse error means we no longer trust our position in the byte stream (can't safely find the next request), a handler exception after a well-formed request does not have that problem.

Test evidence: [`ExceptionSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ExceptionSpec.hs) (handler `fail`s mid-request ⇒ 500, [`ExceptionSpec.hs:65-68`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ExceptionSpec.hs#L65-L68); note the `statusError`/`headersError`/`headerError`/`bodyError` cases at [`ExceptionSpec.hs:51-64`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ExceptionSpec.hs#L51-L64) are commented out with "We can consider forcing evaluation in Warp" — i.e. Warp does **not** currently force-evaluate lazy `undefined` thunks buried in a `Response`'s status/headers/body eagerly enough to catch them as a clean 500, a known/acknowledged gap in the upstream test suite itself, worth noting since we won't have Haskell's laziness pitfall but might have our own analogous "exception raised after we've committed to writing bytes" case); [`RequestSpec.hs:34-37`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RequestSpec.hs#L34-L37) and [`:107-114`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RequestSpec.hs#L107-L114) directly test the `OverLargeHeader` boundary (off-by-one on the exact byte budget); [`RunSpec.hs:269-275`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L269-L275) tests `IncompleteHeaders` at four different truncation points of the same input.

---

## 10. Close/shutdown protocol — lingering close, FIN, half-close, per-connection close, graceful drain

Two independent mechanisms, worth keeping conceptually separate in our own design:

**(a) Per-connection socket close (`connClose`)** — decided by transport type and `settingsGracefulCloseTimeout{1,2}`, [`Run.hs:87-99`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L87-L99):
```haskell
, connClose = do
    h2 <- readIORef isH2
    let tm = if h2 then settingsGracefulCloseTimeout2 set else settingsGracefulCloseTimeout1 set
    if tm <= 0
        then close s
        else gracefulClose s tm `E.catch` throughAsync (return ())
```
`gracefulClose` is from the `network` package (`Network.Socket`, re-exported at [`Run.hs:44-46`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L44-L46)); per its haddock (fetched from Hackage, `network-3.2.9.0`, https://hackage-content.haskell.org/package/network-3.2.9.0/docs/Network-Socket.html): *"Closing a socket gracefully. This sends TCP FIN and check if TCP FIN is received from the peer. The second argument is time out to receive TCP FIN in millisecond. In both normal cases and error cases, socket is deallocated finally."* — i.e. it's exactly the classic lingering-close pattern: `shutdown(fd, SHUT_WR)` (half-close the write side, sending FIN) then read-and-discard until either the peer's own FIN arrives (full close, clean) or the timeout elapses (then just `close()` anyway). **Warp's own default for HTTP/1.x is `settingsGracefulCloseTimeout1 = 0`, i.e. `tm <= 0` ⇒ plain immediate `close(s)`, no lingering wait at all** — the lingering-close machinery exists and is fully wired up but is **opt-in** for HTTP/1 (it's the default only for HTTP/2, at 2000ms). The doc comment at [`Settings.hs:159-164`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Settings.hs#L159-L164) is explicit: *"0 means uses immediate close."* An immediate `close()` on a socket with unread peer data (or where the peer hasn't yet read all our data) risks an RST instead of a clean FIN, which is a known, accepted tradeoff Warp makes for HTTP/1 by default — presumably because with the write-blocking-connSendAll model (§4) the response is already fully flushed to the kernel by the time `connClose` runs, so there's little marginal benefit to also lingering for the peer's FIN, whereas HTTP/2's multiplexed streams make a clean GOAWAY/FIN sequence more valuable.

`connRecvBuf` is explicitly marked `-- obsoleted` and is a no-op stub (`\_ _ -> return True`) ([`Run.hs:101`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L101)) — no half-close-for-reading concept is exposed separately from `gracefulClose`'s own internal read-until-FIN loop. Warp does not expose a "half-close the read side only" primitive to applications at all; the only half-close *behavior* present is internal to `gracefulClose`'s lingering-close implementation.

Warp guarantees `connClose` fires exactly once (`E.bracket mkConn cleanUp (serve unmask)`, [`Run.hs:442`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L442), `cleanUp` at [`Run.hs:444-447`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L444-L447)) regardless of which exit path the connection thread takes (normal completion, any synchronous exception, any async/timeout kill) — this is the same "own every close initiation, exactly once" discipline our chez-libuv ADR-0007 already mandates, just enforced here via `bracket` instead of an explicit close-tracking flag; worth noting that `E.bracket`'s guarantee is specifically about *masked* exception delivery around the acquire/release boundary, which is the Haskell-native version of "mask async exceptions until the close handler is registered" — see the long comment block at [`Run.hs:308-320`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L308-L320) citing https://github.com/yesodweb/wai/issues/146 for the full exception-safety discussion.

**(b) Whole-server graceful shutdown** — `gracefulShutdown`, [`Run.hs:532-546`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L532-L546):
```haskell
gracefulShutdown set counter = do
    setShuttingDown                          -- writeShuttingDown serverShuttingDown True
    case settingsGracefulShutdownTimeout set of
        Nothing -> waitForZero counter
        Just seconds -> void (timeout (seconds * microsPerSecond) (waitForZero counter))
```
Triggered by closing the *listen* socket (via `settingsInstallShutdownHandler`, typically a signal handler set up by the embedding app), which makes `acceptNewConnection`'s `accept()` fail, ending the accept loop ([`Run.hs:338-342`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L338-L342)) — at that point `gracefulShutdown` runs, which (1) flips the shared `ShuttingDown` flag and (2) blocks (via STM `retry`, [`Counter.hs:24-27`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Counter.hs#L24-L27)) until the open-connection `Counter` reaches zero, or the optional timeout elapses. Note this waits for **connections**, not for in-flight **requests** specifically — a connection only decrements the counter when its whole `fork`ed thread exits ([`Run.hs:419`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L419): `runConnection unmask `E.finally` decrease counter`), so a keep-alive connection currently idle between requests still counts as "open" and blocks shutdown until it either times out (§6, 30s default) or the server forces it closed via the `Connection: close` + shutdown-flag interaction below.

The shutdown flag interacts with request handling at **two** separate points, both worth copying:
1. **New responses stop persisting**: `sendResponse` reads `currentShuttingDownState` fresh for every single response and folds it directly into `shouldPersist` (§1: `shouldPersist = not isShuttingDown && ret`) — so a request that arrives (or is mid-flight) exactly as shutdown begins still gets a **complete, correct response**, just with `Connection: close` forced on it, converting the client to a normal graceful drain instead of an abrupt RST. This is confirmed by [`GracefulShutdownSpec.hs:74-130`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/GracefulShutdownSpec.hs#L74-L130) (`"serves the request in flight, then closes keep-alive connections and exits"`): the test explicitly asserts the in-flight request's response carries `Connection: close` ([`GracefulShutdownSpec.hs:99`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/GracefulShutdownSpec.hs#L99)) and a *second* request attempted on a fresh connection after shutdown gets connection-refused ([`GracefulShutdownSpec.hs:102-103`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/GracefulShutdownSpec.hs#L102-L103)).
2. **New reads stop happening for genuinely idle connections**: `makeGracefulRecvSlow`'s STM race ([`Run.hs:157-178`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L157-L178)) between "socket became readable" and "shutdown flag is set AND `appsInProgress == 0`" — if shutdown wins the race *and* there's no in-flight app on that connection, `connRecv` returns `""` (EOF) synthetically, which propagates as an ordinary `NoKeepAliveRequest`/EOF through `headerLines`, cleanly ending that connection's `loop` without ever touching the (possibly-just-closed) socket again. The `appsInProgress :: TVar Int` guard ([`Run.hs:488-493`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L488-L493), bumped around every `app req rsp` call) exists specifically so that a connection with a request **currently being handled** doesn't get this synthetic-EOF treatment mid-processing — only genuinely-idle keep-alive connections get force-closed by shutdown; busy ones are left alone until they finish naturally (then (1) above kicks in for their response, and their next read hits this same check and gets force-EOF'd). There's also a documented fast path (`receiveNoWait`, no IO-manager registration) tried first when *not* shutting down, presumably a latency optimization for the overwhelmingly common case — worth understanding but not central to our design.

`ServerState`/`Counter`/`ShuttingDown` are designed to be constructed once and shared: `makeServerState` is explicitly idempotent (safe to call more than once on the same `Settings` value and get the same state back rather than a fresh one) — tested directly at [`ServerStateSpec.hs:28-56`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ServerStateSpec.hs#L28-L56).

**Race the test suite specifically pins down**: a connection `accept()`-ed a moment *before* the listen socket closes, but whose serving thread hasn't been scheduled yet, must still be waited-for by graceful shutdown — [`GracefulShutdownSpec.hs:23-72`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/GracefulShutdownSpec.hs#L23-L72), with an extensive comment explaining exactly why the counter is incremented in the accept loop itself (`increase counter` in `fork`, *before* forking, [`Run.hs:414-418`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L414-L418)) rather than inside the forked thread — **this is the single most reusable lesson in the whole shutdown story for us**: *count the resource at the moment of acquisition, not at the moment its consumer starts running*, because the gap between "accepted" and "thread scheduled" is exactly where a naive implementation loses connections during shutdown.

---

## 11. Timeout-manager design (timer economy)

The task specifically points at "one thread, a tickle-able per-connection handle" — I found **two different implementations** of this idea in the wai repo's history, and they matter differently to us because our own timer primitive (`make-uv-timer`) is per-handle/per-timer, exactly like the *old* design's problem statement.

### 11a. Classic design (pre-rewrite, still tagged as `warp-3.2.28`; a `Control.Reaper`-based single thread)

Full source at [`time-manager/System/TimeManager.hs` @ `warp-3.2.28`](https://github.com/yesodweb/wai/blob/d487668804d7a71606d137df3c6d3d1cc359660b/time-manager/System/TimeManager.hs). Structure:
```haskell
type Manager = Reaper [Handle] Handle
data Handle = Handle !(IORef TimeoutAction) !(IORef State)
data State = Active | Inactive | Paused | Canceled

initialize timeout = mkReaper defaultReaperSettings
    { reaperAction = mkListAction prune, reaperDelay = timeout }
  where
    prune m@(Handle actionRef stateRef) = do
        state <- I.atomicModifyIORef' stateRef (\x -> (inactivate x, x))
        case state of
            Inactive -> do { onTimeout <- I.readIORef actionRef; onTimeout `E.catch` ignoreAll; return Nothing }
            Canceled -> return Nothing
            _        -> return $ Just m
    inactivate Active = Inactive
    inactivate x = x

register mgr onTimeout = do
    actionRef <- I.newIORef onTimeout; stateRef <- I.newIORef Active
    let h = Handle actionRef stateRef
    reaperAdd mgr h
    return h

tickle (Handle _ stateRef) = I.writeIORef stateRef Active     -- O(1), no heap/list touch at all
pause  (Handle _ stateRef) = I.writeIORef stateRef Paused
resume = tickle
cancel (Handle actionRef stateRef) = do
    I.writeIORef actionRef (return ())
    I.writeIORef stateRef Canceled
```
([`old/TimeManager-3.2.28.hs:34-141`](https://github.com/yesodweb/wai/blob/d487668804d7a71606d137df3c6d3d1cc359660b/time-manager/System/TimeManager.hs#L34-L141), full quote since it's short and the whole shape is the point.)

This is exactly the "timer economy" pattern that matters for us: **one OS/scheduler timer total, for the whole server**, firing on a fixed `reaperDelay` cadence (Warp sets `reaperDelay = timeout` — i.e. it sweeps once per `settingsTimeout` interval, 30s by default, not more granularly); every connection's `Handle` is just two `IORef`s in a list the sweep walks linearly. Tickling/resuming a connection is a single `writeIORef` — **no interaction with any timer/heap data structure at all**, unlike a design where each tickle reschedules a per-connection timer (an O(log n) heap operation, or in our libuv case, an FFI call to `uv_timer_start` per tickle). The sweep (`prune`) walks the whole live-handle list once per tick: `Active → Inactive` (still alive, but must prove liveness again by the *next* tick or die — i.e. any handle needs to be tickled at least once per `reaperDelay` window, giving an actual timeout window of *between* `reaperDelay` and `2 × reaperDelay`, not a precise per-connection deadline); `Inactive` (found already inactive from the *previous* sweep, meaning a full cycle passed with zero tickles) → fire `onTimeout` and drop from the list; `Paused`/`Canceled` handled specially (paused handles are left alone indefinitely — no timeout fires while paused, matching Warp's "pause while the app computes" use, §3/§4; canceled ones are dropped with no action). Because `pause`/`resume`/`tickle`/`cancel` are all pure `IORef` writes, **none of them need to run on the reaper thread or take any lock** — the reaper thread is the only place the list itself is mutated (`reaperAdd`/removal-via-`prune`'s return value), and it always was — Warp is explicit that `Handle` methods are safe to call from arbitrary connection threads concurrently with the sweep because they only ever touch that one `Handle`'s own two `IORef`s.

**Directly transferable design for us**: a single `uv-timer` (one FFI timer handle for the *entire server*, not one per connection — sidestepping chez-libuv's "timers are handles, one `make-uv-timer` per timer" cost entirely) firing once every `timeout` seconds, sweeping a plain mutable list/hashtable of lightweight per-connection cells `{state, on-timeout-thunk}` with three-and-a-half states (active/inactive/paused/canceled), where "tickle" is just a mutation of that cell's state field — zero FFI calls, zero interaction with libuv's timer heap, from the hot path (every `on-data` delivery). This buys us the exact backpressure-friendly, allocation-free, lock-free-in-effect tickle Warp gets, using primitives we already have (a single uv-timer + a hashtable we already need for the handle registry per chez-libuv's own docs). The tradeoff to carry over explicitly: **resolution is `timeout` seconds, not real-time-precise** — a connection idle for `timeout + ε` may live up to `2 × timeout` before being reaped, because "one full sweep interval with zero tickles" is the actual firing condition, not "exactly `timeout` seconds since the last tickle." If we want tighter precision we'd need a shorter, separate sweep interval than the timeout value itself (Warp doesn't do this — it conflates the two).

### 11b. Current design (this repo's `master`, i.e. `time-manager` since some 0.3.0 release): delegates to GHC's own per-capability timer manager

[`time-manager/System/TimeManager.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/TimeManager.hs) no longer implements its own reaper thread at all — `register` calls straight into `GHC.Event.registerTimeout`/`getSystemTimerManager` (the RTS's built-in I/O-manager timer wheel, one per capability/OS-thread already used for all of GHC's other non-blocking I/O), and `tickle`/`resume` call `GHC.Event.updateTimeout` — [`TimeManager.hs:124-181`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/TimeManager.hs#L124-L181). This is **not portable to us at all** (it's a GHC-RTS-specific capability, exactly analogous to "just use libuv's own timer heap directly, one `uv_timer_t` per connection" — the thing our task brief already told us costs one libuv timer handle per connection). I'm flagging this explicitly so we don't accidentally cite `master`'s design as "what Warp does" for the timer-economy question — **the design the task is actually asking about (and the one relevant to our timer-economy constraint) is §11a, the pre-rewrite one**, which is still fully readable at the `warp-3.2.28` tag and is a well-known, often-cited piece of Warp folklore (a single reaper thread + tickle-able handles was one of Warp's original, deliberate performance decisions circa the Snoyman/Yamamoto-era design writeups).

`System.ThreadManager` ([`time-manager/System/ThreadManager.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/ThreadManager.hs)) is a separate, newer layer on top of whichever `TimeManager` backend is in use: it tracks *which OS thread* is running each managed connection (a `TVar (Map Word64 ManagedThread)`, weak-referenced `ThreadId`s so a dead thread's stack can still be GC'd even if the map entry briefly lingers, [`ThreadManager.hs:64-76`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/ThreadManager.hs#L64-L76)) and adds `stopAfter`/`stopAfterWithResult` for **bulk**, coordinated kill-everything-and-rethrow semantics with an explicit `IORef Bool` per-thread lock (`lockAndKill`, [`ThreadManager.hs:225-232`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/time-manager/System/ThreadManager.hs#L225-L232)) to prevent a race between "the timeout manager independently decided to kill this thread" and "the whole-server shutdown path is also killing it" from double-delivering an async exception. Interesting as a general pattern (a lock-to-arbitrate-who-gets-to-throw-the-kill-exception between two independent supervisory mechanisms) but Warp's *own* HTTP/1 connection loop (`Run.hs`) does **not** currently use `ThreadManager` — it uses the lower-level `T.withHandleKillThread`/`T.Handle` API directly ([`Run.hs:451`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L451)); `ThreadManager` looks to be a newer/HTTP2-oriented or forward-looking abstraction I did not chase further since it wasn't in the task's file list and isn't (yet) load-bearing for the HTTP/1 path I was asked to focus on.

---

## 12. How the timeout handle is threaded through one request/response cycle (ties §3/§4/§11 together)

One `T.Handle` (`th`) is created per accepted connection (`T.withHandleKillThread`, [`Run.hs:451`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L451)) and threaded, unchanged, through every iteration of the connection's `loop`. Its pause/resume state over one request:

1. Connection accepted → handle registered, **active** (armed for `settingsTimeout`).
2. `recvRequest` reads headers → every `recv()` ≥ `settingsSlowlorisSize` bytes tickles it ([`HTTP1.hs:48-53`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L48-L53) — small reads don't).
3. `processRequest` calls **`T.pause th`** immediately before invoking the `Application` ([`HTTP1.hs:189`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L189)) — the handler can compute for arbitrarily long with **no timeout risk**, by design.
4. If/when the handler pulls a request-body chunk, `timeoutBody` calls **`T.resume th`** on the first pull ([`Request.hs:220`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L220)) and **`T.pause th`** again the moment the body reports exhausted ([`Request.hs:234`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L234)) — so *only the actual body-read I/O* is timeout-guarded, not the handler's subsequent processing of that body.
5. The instant the handler calls `respond` (its continuation), `processRequest` calls **`T.resume th`** again ([`HTTP1.hs:196`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L196)) before `sendResponse` runs — guarding the response-write phase.
6. Every individual socket write during response streaming re-tickles it via `sendFragment`'s `T.resume th; send bs; T.pause th` bracket ([`Response.hs:497-501`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L497-L501)) — so it's only "hot" while a `sendAll` is actually blocked in the kernel.
7. `sendResponse` itself unconditionally calls **`T.tickle th`** right before returning ([`Response.hs:156`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Response.hs#L156)) — belt-and-braces reset for the next `loop` iteration regardless of the pause/resume bracketing above.
8. On keep-alive, the post-response body-drain also explicitly `T.resume`s before draining and leaves it active for the next `loop` iteration's header read (§2's `tryKeepAlive`, [`HTTP1.hs:233,241`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/HTTP1.hs#L233)).
9. On connection teardown (`fork`'s `E.bracket`, [`Run.hs:451`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Run.hs#L451): `T.withHandleKillThread ... $ \th -> ...`), the handle is unregistered exactly once regardless of exit path.

**This pause/resume-around-I/O-only discipline (never around user-code-that-isn't-doing-I/O) is the single biggest transferable idea from the whole timeout story**, independent of which concrete timer-economy implementation (§11a vs §11b vs libuv) backs it: the *protocol* is "one shared per-connection liveness flag, toggled active only around actual socket I/O and body-consumption calls, paused everywhere else" — this composes cleanly with our own architecture regardless of whether the underlying primitive is a GHC timer, a Warp-style reaper sweep, or a single shared `uv-timer` sweep as sketched in §11a.

---

## 13. The application-handler API shape

`Application` — [`wai/Network/Wai.hs:309-310`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai.hs#L309-L310):
```haskell
type Application =
    Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
```
i.e. **continuation-passing, not "return a Response"**: the app receives a `Request` and a `respond` callback, and must eventually call `respond someResponse` exactly once, propagating whatever `respond` itself returns (`ResponseReceived`, an opaque sentinel with no fields — [`wai/Network/Wai/Internal.hs:176-184`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai/Internal.hs#L176-L184), whose haddock is explicit this exists only so the type signature can avoid `RankNTypes`) as its own final result. This shape is what lets `responseStream`/`responseRaw` work at all — the server hands the app a **producer** function (`Builder -> IO ()`) rather than the app returning a value the server then has to consume/stream on its own, so the app's own control flow (loops, `bracket`s for scarce resources acquired mid-handler, etc.) directly *is* the streaming loop, with no intermediate buffering layer or generator/coroutine machinery needed. `Middleware = Application -> Application` ([`wai/Network/Wai.hs:479`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai.hs#L479)) composes trivially by nesting this shape.

`Request` is a flat record ([`wai/Network/Wai/Internal.hs:24-104`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai/Internal.hs#L24-L104)) mixing pre-parsed convenience fields (`pathInfo :: [Text]` already percent-decoded/segmented, `queryString`, four specific pre-extracted headers `requestHeaderHost/Range/Referer/UserAgent` for the ones Warp's own code needs to consult on every request anyway, §1/§8/file-serving) with three escape hatches: `requestBody :: IO ByteString` (pull, §3), `vault :: Vault` (an extensible, type-safe heterogeneous map for handler-specific extension data — Warp itself stashes `pauseTimeoutKey`/`getFileInfoKey`/(TLS) client-cert accessors there, [`Request.hs:93-99`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/Network/Wai/Handler/Warp/Request.hs#L93-L99) — i.e. it's Warp's own mechanism for handing a *server-internal* capability, like "pause my own idle timer," out to application code without widening the core `Request` record), and `requestSendEarlyHints :: H.ResponseHeaders -> IO ()` (a proactive-push-style side channel, no-op by default, populated by HTTP/2). `Response` is a 4-constructor sum ([`wai/Network/Wai/Internal.hs:144-148`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/wai/Network/Wai/Internal.hs#L144-L148)) — `ResponseFile`/`ResponseBuilder`/`ResponseStream`/`ResponseRaw` — each just a status+headers+payload-description tuple; there is deliberately **no fifth "raw bytes" constructor for a fully-manual response** beyond `ResponseRaw`'s upgrade-only escape hatch — every normal response goes through Warp's own framing/keep-alive logic (§1/§8), which is exactly the boundary we should draw too: give our application layer producer-style streaming primitives for headers/body, but keep status-line composition, `Connection`/`Transfer-Encoding` header insertion, and the close decision itself inside our core, never delegable per-response.

---

## 14. What Warp's own test suite covers that we should copy the *shape* of

(File paths again, all under `warp/test/`, all fetched and read; test names quoted from `it "…"`/`describe "…"` strings, which are themselves the spec.)

- **[`ConnectionSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ConnectionSpec.hs)** — a direct truth-table test of the keep-alive rule (§1) as five concrete `it` cases (HTTP/1.0 w/ Keep-Alive + no length ⇒ close; HTTP/1.0 plain GET ⇒ close; HTTP/1.1 HEAD ⇒ *no* spurious `Connection: close`; HTTP/1.1 + explicit `Connection: close` on 200/204/500 ⇒ close) — **copy this exact shape**: it's a small, fast, whole-connection-level (writes raw bytes to a real socket via `withMySocket`/`msWrite`/`msRead`, not a unit test of an isolated function) test that directly encodes the normative rule and is trivially extensible with one more `testClose` call per new case. Given our own likely close/persist decision table will be at least as large (HTTP/1.0 vs 1.1 × request Connection token × response Connection token × response has-length × HEAD × method), this is exactly the test structure to imitate.
- **[`RunSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs)**, `describe "pipelining"` ([`:231-261`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L231-L261)) — the **same** scenarios run twice, once as N separate writes ("non-pipelining") and once as all N requests concatenated into a single `send()` ("pipelining"), reusing one `runTest` helper — a good pattern to copy directly: any request-handling test we write should be parameterizable over "delivered as separate TCP segments" vs "delivered as one segment," since that's exactly the seam chez-httparse's `parser-feed!` chunk-boundary handling and our own connection-buffer leftover logic both need proven robust against.
- **`describe "no hanging"`** ([`:262-267`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L262-L267)) — sends a request **one byte at a time** and asserts it's still handled correctly; this is the cheapest possible test of "the parser doesn't assume a header or body chunk arrives whole," directly relevant to chez-httparse's own "passes all 274 llhttp fixtures at every chunk size" claim — we should have an equivalent connection-layer-level (not just parser-level) one-byte-at-a-time test, since header parsing across `recv()` boundaries plus leftover-buffer bookkeeping is exactly the kind of thing that's correct at the parser layer but can still be wrong at the connection-buffer-management layer above it.
- **`describe "connection termination"`** ([`:269-275`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L269-L275)) — truncates the **same** input at four different points (`"...content-length: 10\r\n\r"`, `"...\r\n"`, `"...\r"`, `"...content-lengt"`) and asserts all four produce `IncompleteHeaders`. Good pattern: parametrize a single "premature EOF" test over multiple truncation offsets of one canonical input, rather than one arbitrarily-chosen offset.
- **`describe "special input"`** ([`:277-312`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L277-L312)) — three deliberately-tricky header-folding cases (legacy RFC 822/2616 multiline continuation via leading whitespace, no-space-after-colon, and a case Warp *deliberately does not* treat as multiline because the continuation byte arrives in a separate TCP write from the initial line) captured as exact expected `requestHeaders` lists. Directly useful as a spec for whatever we decide chez-httparse/our header-assembly layer should do with obsolete line-folding (RFC 9112 says reject it; worth checking whether we want Warp's permissive behavior here or to be stricter, per our general "be at least as strict as llhttp" stance from §8).
- **`describe "chunked bodies"`** ([`:314-396`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RunSpec.hs#L314-L396)) — normal case, "lots of chunks" (100 tiny chunks across 2 pipelined requests), byte-at-a-time delivery, and the idle-timeout-during-body-streaming case (§3) all as one `describe` block sharing a `consumeBody`/`countVar` harness — good shape for our own chunked-body streaming tests once chez-httparse is wired into a connection loop.
- **[`GracefulShutdownSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/GracefulShutdownSpec.hs)** — the two scenarios in §10(the accept-race test and the in-flight-request-gets-a-clean-response-then-refuses-new-connections test) are, in my judgement, the two *highest-value* connection-semantics tests in the entire suite to port early, because they're exactly the kind of race that's easy to get right by accident under a toy test and wrong under real concurrency; both are written as genuine multi-thread/multi-client integration tests against a real bound socket, not mocked.
- **[`ExceptionSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ExceptionSpec.hs)** — small but notable for what's *commented out* (§9): a reminder to explicitly decide, and test, what happens when a handler throws while status/headers/body are already logically "in flight" in our own (non-lazy, so this specific Haskell pitfall doesn't apply, but the general shape does) design.
- **[`ServerStateSpec.hs`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/ServerStateSpec.hs)** — tests that shared server-wide state construction (`makeServerState`) is idempotent; small but a good discipline check if we build an equivalent "construct once, thread through everywhere" server-state record.

Explicitly **not** deep-read (out of this task's scope, flagging so nobody assumes I checked them): `RequestSpec.hs`'s `parseByteRanges` block ([`:61-68`](https://github.com/yesodweb/wai/blob/9581c256dc343ab8793094fa008626db24f69633/warp/test/RequestSpec.hs#L61-L68), Range-header parsing, tangential to core connection semantics), `SendFileSpec.hs`/`FdCacheSpec.hs`/`FileSpec.hs` (static-file serving), `WithApplicationSpec.hs`, `BufferSpec.hs`/`ConduitSpec.hs`/`PackIntSpec.hs`/`ReadIntSpec.hs` (low-level codec unit tests, not connection-semantics), and the entire HTTP/2 test surface.

---

## 15. Things I looked for and explicitly did NOT find (so we don't assume Warp has them)

All confirmed by `grep -rn` over the fetched tree, not by absence-of-memory:
- No `uv_idle`/`uv_prepare`/`uv_check`-equivalent construct anywhere — not relevant to Haskell's runtime model, but worth noting we found nothing analogous to "defer this work to the next event-loop tick" in Warp's connection code; everything is either a blocking call on the connection's own thread or an STM-mediated wait.
- No built-in request-size/body-size **hard cap** distinct from the keep-alive-reuse drain budget (`settingsMaximumBodyFlush`, §2/§6) — an app that actually reads an arbitrarily large Content-Length or chunked body via `requestBody` will happily keep receiving it forever; Warp enforces no independent max-body-size setting. (There's `PayloadTooLarge`/413 machinery in `Settings.hs`, but as established in §9 it's never triggered by anything in-tree — it exists purely for a library consumer to throw themselves, e.g. from within their own `Application`.) **This means body-size limiting is entirely a policy decision Warp leaves to the app**, not something the connection layer enforces by default — a real design choice, not an oversight (it composes with %any% app-level policy), but one we should make *consciously* rather than silently copy-by-omission.
- No `Trailer:` / chunked-trailer support (§3, `CSource`'s `dropCRLF`/`dropLF` just discard whatever's between the final `0\r\n` and the terminating `\r\n`, no trailer headers are parsed into `requestHeaders` or exposed to the app at all).
- No `Expect:` values other than exactly `"100-continue"` are handled (§5) — no `417`.
- No distinct 408 (§9) — timeouts are silent closes, never a response.
- No distinct 501/505 (§9) — method and HTTP-version validation are essentially absent at the connection layer; both are either the application's job or (for version) silently coerced rather than rejected.
- No CONNECT-tunnel or Upgrade-header-aware logic in the connection layer at all (§7) — 100% delegated to the app via `responseRaw`.
