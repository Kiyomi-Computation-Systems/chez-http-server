#!r6rs
;;; (libhtp-lane) — our expectations for libhtp's streams, and the run they
;;; are held to: its pipelining and multi-packet streams, its two Expect
;;; streams, and the robustness lane's streams, libhtp's invalid streams and
;;; its HTTP/0.9 streams, by name.  35-early-response.t is run a second time,
;;; its handler answering at the head, as its recorded origin did (below).
;;;
;;; A stream's client chunks (`>>>`) are its packets.  Each is delivered to one
;;; fake connection as one `bytes-arrived`, while the connection reads, with
;;; every later turn in between.  After the last, the client's `eof` arrives if
;;; the connection still reads, as when a capture ends.  The `<<<` chunks are a
;;; recorded origin's replies, not an oracle, so none is delivered, and every
;;; handler reads the body, if the request has one, and answers 200
;;; ((outcome-lane)'s `reads`), but 99-expect-100.t's (below).  The lane runs
;;; under the trace lane's `corpus-limits`, with no Host required, like the
;;; llhttp lanes: six of the twelve pipelining and multi-packet streams send
;;; HTTP/1.1 without one.  The two Expect streams end their lines in a bare
;;; LF, which the strict parser refuses, so they are delivered with CRLF
;;; (`libhtp-packets`).
;;;
;;; What the connection did is the outcome lane's record, plus the body:
;;;   - each handler call, with the request it was given;
;;;   - the body bytes delivered, joined between two other actions;
;;;   - the responses written, by status, and the close and its reason;
;;;   - the phase and close-after the connection ended with, and the actions
;;;     run anywhere but the outermost drain, which must be none.
;;;
;;; The expectations are ours, written from RFC 9112 and the server's
;;; documented behaviour, each with its reason beside it.
(library (libhtp-lane)
  (export libhtp-expected-files libhtp-expectation libhtp-packets crlf-files
          libhtp-outcome libhtp-mismatch
          early-response-expectation early-response-outcomes
          robustness-expected-files robustness-file?)
  (import (rnrs)
          (libhtp-corpus) (fake-shell)
          (http-server connection) (http-server response) (http-server request)
          (http-server span)
          (only (outcome-lane) render-request attempt reads)
          (only (trace-lane) corpus-limits))

  ;; --- the expectations ------------------------------------------------------
  ;;
  ;; Each is (actions phase close-after violations).  A connection the client
  ;; keeps alive closes at its eof, with no close-after; an HTTP/1.0 one
  ;; closes after its response, as `not-keep-alive` (RFC 9112 §9.3: 1.1
  ;; persists unless it says close, 1.0 only if it says keep-alive), in
  ;; stages: it lingers, and the eof ends it.

  ;; Two GETs on one connection, served in order, one at a time (RFC 9112
  ;; §9.3.2).
  (define two-gets
    '(((call-handler (GET "/first" 1 1 ())) (write 200)
       (call-handler (GET "/second" 1 1 ())) (write 200)
       (close eof))
      closed #f ()))

  ;; Four GETs whose Host values are all valid (RFC 9110 §7.2: uri-host [":"
  ;; port]; RFC 3986 §3.2.2: a reg-name may end in a dot, and is
  ;; case-insensitive).
  (define four-hosts
    '(((call-handler (GET "/" 1 1 (("Host" . "www.example.com")))) (write 200)
       (call-handler (GET "/" 1 1 (("Host" . "www.example.com.")))) (write 200)
       (call-handler (GET "/" 1 1 (("Host" . "WwW.ExamPle.cOm")))) (write 200)
       (call-handler (GET "/" 1 1 (("Host" . "www.example.com:80")))) (write 200)
       (close eof))
      closed #f ()))

  ;; A chunked POST: chunks of 11 and 1 bytes, then a trailer, `Cookie: 2`,
  ;; split across packets.  The handler is asked once the head is in, and its
  ;; reader is handed the body.  The trailer is not part of the request, which
  ;; is built at on-headers-complete; a trailer is counted against the header
  ;; limits and not kept.
  (define chunked-post
    '(((call-handler (POST "/" 1 1 (("Transfer-Encoding" . "chunked")
                                    ("Content-Type" . "application/x-www-form-urlencoded")
                                    ("User-Agent" . "Mozilla") ("Cookie" . "1"))))
       (body "p=0123456789")
       (write 200)
       (close eof))
      closed #f ()))

  ;; libhtp-expectations : (Listof (Pair String Outcome)), by file name.
  (define libhtp-expectations
    (list
     ;; the chunked POST, its trailer across the two packets
     (cons "04-post-urlencoded-chunked.t" chunked-post)
     ;; curl 7.18's upload, expecting 100-continue, its head alone in the
     ;; first packet (RFC 9110 §10.1.1).  The handler is asked at the head
     ;; and answers with a reader, so the 100 goes out before any of the
     ;; body arrives; then the body, in three packets, its Content-Length of
     ;; 216 bytes, and the response.
     (cons "05-expect.t"
           `(((call-handler
               (POST "/" 1 1
                     (("User-Agent" . "curl/7.18.2 (i486-pc-linux-gnu) libcurl/7.18.2 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.8 libssh2/0.18")
                      ("Accept" . "*/*") ("Content-Length" . "216") ("Expect" . "100-continue")
                      ("Content-Type" . "multipart/form-data; boundary=----------------------------07869933ca1b"))))
              (write 100)
              (body ,(string-append
                      "------------------------------07869933ca1b\r\n"
                      "Content-Disposition: form-data; name=\"file\"; filename=\"404.php\"\r\n"
                      "Content-Type: application/octet-stream\r\n"
                      "\r\n"
                      "<? echo \"404\"; ?>\r\n"
                      "------------------------------07869933ca1b--\r\n"))
              (write 200)
              (close eof))
             closed #f ()))
     ;; the two GETs in one packet: pipelined
     (cons "07-pipelined-connection.t" two-gets)
     ;; the two GETs in two packets, each after the first's response
     (cons "08-not-pipelined-connection.t" two-gets)
     ;; an HTTP/1.0 head in three packets
     (cons "09-multi-packet-request-head.t"
           '(((call-handler (GET "/" 1 0 (("Host" . "www.example.com")))) (write 200)
              (close not-keep-alive))
             closed not-keep-alive ()))
     ;; the four GETs, each in its own packet
     (cons "10-host-in-headers.t" four-hosts)
     ;; Five absolute-form requests, three of them with a Host that names
     ;; another server or port.  "When an origin server receives a request
     ;; with an absolute-form of request-target, the origin server MUST ignore
     ;; the received Host header field" (RFC 9112 §3.2.2), so all five are
     ;; served.  Each POST's handler is asked once its head is in, and its
     ;; reader is handed the 8-byte body.
     (cons "20-ambiguous-host.t"
           '(((call-handler (GET "http://example.com/1" 1 1 (("Host" . "example.com"))))
              (write 200)
              (call-handler (GET "http://example.com/2" 1 1 (("Host" . "foo.com"))))
              (write 200)
              (call-handler (POST "http://www.example.com:8001/3" 1 1
                                  (("Host" . "www.example.com:8001") ("Content-Length" . "8"))))
              (body "12345678")
              (write 200)
              (call-handler (POST "http://www.example.com:8002/4" 1 1
                                  (("Host" . "www.example.com:8003") ("Content-Length" . "8"))))
              (body "12345678")
              (write 200)
              (call-handler (POST "http://www.example.com:80/5" 1 1
                                  (("Host" . "www.example.com") ("Content-Length" . "8"))))
              (body "12345678")
              (write 200)
              (close eof))
             closed #f ()))
     ;; the chunked POST again: libhtp's trailer test sends 04's bytes
     (cons "27-request-trailer-raw.t" chunked-post)
     ;; An HTTP/1.0 POST whose 12-byte body is the second packet.  The origin
     ;; recorded here answered 400 before the body; ours, its handler reading
     ;; the body, answers when the message ends, and closes.  Answered at the
     ;; head, as the origin did, it is run again (early-response-outcomes).
     (cons "35-early-response.t"
           '(((call-handler (POST "/" 1 0 (("Content-Length" . "12")
                                           ("Content-Type" . "application/x-www-form-urlencoded")
                                           ("User-Agent" . "Mozilla"))))
              (body "p=0123456789")
              (write 200)
              (close not-keep-alive))
             closed not-keep-alive ()))
     ;; the four GETs again: libhtp's crash test sends 10's bytes
     (cons "39-auto-destroy-crash.t" four-hosts)
     ;; The two GETs in two packets, the second after an empty line: "a
     ;; server that is expecting to receive and parse a request-line SHOULD
     ;; ignore at least one empty line (CRLF) received prior to the
     ;; request-line" (RFC 9112 §2.2).
     (cons "61-empty-line-between-requests.t" two-gets)
     ;; the chunked POST, its first chunk's data split as well
     (cons "66-post-chunked-split-chunk.t" chunked-post)
     ;; an HTTP/1.0 request line split inside its target
     (cons "67-long-request-line.t"
           '(((call-handler (GET "/0123456789/0123456789/" 1 0 (("User-Agent" . "Mozilla"))))
              (write 200)
              (close not-keep-alive))
             closed not-keep-alive ()))
     ;; A PUT to /forbidden expecting 100-continue, which its handler
     ;; refuses at the head, as the recorded origin did: answered with a
     ;; response, not a reader, so no 100 goes out, the body is not read, and
     ;; the connection closes after the response, dropping the POST behind
     ;; it, which the recorded origin served.
     (cons "99-expect-100.t"
           '(((call-handler (PUT "/forbidden" 1 1 (("Content-Length" . "14") ("Expect" . "100-continue"))))
              (write 401)
              (close unread-body))
             closed unread-body ()))))

  ;; --- the robustness lane's streams -----------------------------------------
  ;;
  ;; libhtp's invalid streams and its HTTP/0.9 streams, by name.  Each is one
  ;; connection's client packets, then its eof.  A request the server refuses
  ;; is answered with no handler asked, and the connection lingers until the
  ;; eof.  Written from RFC 9112 and the server's documented behaviour, each
  ;; with its reason.

  ;; A refusal at the head: the status, and the reason the connection closes
  ;; for.
  (define (refused status reason)
    `(((write ,status) (close ,reason)) closed ,reason ()))

  ;; An HTTP/1.0 GET served, then closed (RFC 9112 §9.3).
  (define (served-1.0 target headers)
    `(((call-handler (GET ,target 1 0 ,headers)) (write 200) (close not-keep-alive))
      closed not-keep-alive ()))

  ;; A chunked POST with libhtp's head, its handler asked at the head.
  (define chunked-post-asked
    '(call-handler (POST "/" 1 1 (("Transfer-Encoding" . "chunked")
                                  ("Content-Type" . "application/x-www-form-urlencoded")
                                  ("User-Agent" . "Mozilla") ("Cookie" . "1")))))

  ;; robustness-expectations : (Listof (Pair String Outcome)), by file name.
  (define robustness-expectations
    (list
     ;; HTTP/0.9: a request line with no version.  The parser reads the lines
     ;; after it as its fields, and only one CRLF came, so the head is not
     ;; complete when the eof comes: nothing is answered.
     (cons "21-http09.t" '(((close eof)) closed #f ()))
     ;; The second line, read as a field, has no colon (RFC 9112 §5.1): 400.
     (cons "23-http09-multiple.t" (refused 400 'parser-error))
     ;; HTTP/0.9, named or with no version, is refused with 505 (RFC 9110
     ;; §15.6.6).
     (cons "24-http09-explicit.t" (refused 505 'version-not-supported))
     (cons "92-http_0_9-method_only.t" (refused 505 'version-not-supported))
     ;; A Host with a space is no uri-host (RFC 9112 §3.2: any request with an
     ;; invalid Host is a 400), judged before the target.
     (cons "32-invalid-hostname.t" (refused 400 'invalid-host))
     ;; A port must be digits (RFC 3986 §3.2.3).
     (cons "33-invalid-hostname.t" (refused 400 'invalid-target))
     ;; An empty port is a port (RFC 3986 §3.2.3: port = *DIGIT), so the Host
     ;; is valid, and the request is served.
     (cons "34-invalid-hostname.t"
           (served-1.0 "/?p=%20" '(("Host" . "www.example.com:") ("User-Agent" . "Mozilla"))))
     ;; A Content-Length that is not digits (RFC 9112 §6.3 rule 5).
     (cons "36-invalid-request-1-invalid-c-l.t" (refused 400 'parser-error))
     ;; Transfer-Encoding beside Content-Length: the server may refuse it (RFC
     ;; 9112 §6.1), and the strict parser does.
     (cons "37-invalid-request-2-t-e-and-c-l.t" (refused 400 'parser-error))
     ;; A Transfer-Encoding whose last coding is not chunked (§6.3 rule 4).
     (cons "38-invalid-request-3-invalid-t-e.t" (refused 400 'parser-error))
     ;; An HTTP-version must be "HTTP/" DIGIT "." DIGIT (§2.3).
     (cons "43-invalid-protocol.t" (refused 400 'parser-error))
     ;; What an Authorization says is the handler's; its value is a valid
     ;; field value.
     (cons "44-auth-basic-invalid.t"
           (served-1.0 "/" '(("Host" . "www.example.com")
                             ("Authorization" . "Basic notBase64:EncodedStuff"))))
     ;; A field value folded onto lines that begin with a space (obs-fold):
     ;; a server must refuse it or unfold it (§5.2), and the strict parser
     ;; refuses it.
     (cons "46-auth-digest-invalid-username.t" (refused 400 'parser-error))
     ;; libhtp's response tests: their requests are plain GETs.
     (cons "48-invalid-response-headers-1.t" (served-1.0 "/?p=%20" '(("User-Agent" . "Mozilla"))))
     (cons "49-invalid-response-headers-2.t" (served-1.0 "/?p=%20" '(("User-Agent" . "Mozilla"))))
     ;; An IP-literal with no "]" (RFC 3986 §3.2.2).
     (cons "51-get-ipv6-invalid.t" (refused 400 'invalid-target))
     ;; A target that is no form a request may take (§3.2): it does not begin
     ;; with "/", and its "scheme" has no "://".  The parser refuses it at the
     ;; "/".
     (cons "52-invalid-path.t" (refused 400 'parser-error))
     ;; Percent-encoded octets are a path's to carry (RFC 3986 §2.1); whether
     ;; they decode to UTF-8 is the handler's, as the server hands the path
     ;; over undecoded.
     (cons "58-path-utf8-invalid.t"
           (served-1.0 "/Risti%C4%87%80.txt" '(("Host" . "www.example.com") ("User-Agent" . "Mozilla"))))
     ;; A chunk of 0x80000000 bytes is a chunk size (§7.1), and no body
     ;; limit is set by default (CHEZ_HTTP_MAX_BODY_BYTES), so what follows
     ;; is the chunk's data, read to the eof, which comes first: the body is
     ;; never complete, and nothing is answered.
     (cons "63-post-chunked-invalid-1.t"
           `((,chunked-post-asked
              (body "p=012345678\r\n1\r\n9\r\n0\r\nCookie: 2\r\n\r\n")
              (close eof))
             closed #f ()))
     ;; A chunk size must be hex digits (§7.1): "-1", then an empty line.
     ;; The handler is asked at the head, and the 400 comes with the size.
     (cons "64-post-chunked-invalid-2.t"
           `((,chunked-post-asked (write 400) (close parser-error)) closed parser-error ()))
     (cons "65-post-chunked-invalid-3.t"
           `((,chunked-post-asked (write 400) (close parser-error)) closed parser-error ()))
     ;; A field line with no colon (§5.1), before one with a NUL.
     (cons "68-invalid-request-header.t" (refused 400 'parser-error))
     ;; libhtp's response tests again: plain GETs.
     (cons "70-response-invalid-chunk-length.t" (served-1.0 "/" '()))
     (cons "75-response-invalid-cl.t" (served-1.0 "/" '()))
     ;; A CONNECT to an IP-literal with no "]" (RFC 3986 §3.2.2).
     (cons "79-connect-invalid-hostport.t" (refused 400 'invalid-target))
     ;; A Host that is an IP-literal with no "]".
     (cons "80-hostname-invalid-1.t" (refused 400 'invalid-host))
     ;; A target whose host is an IP-literal with no "]".
     (cons "81-hostname-invalid-2.t" (refused 400 'invalid-target))
     ;; A quote with no close is a valid field value (RFC 9110 §5.5); what it
     ;; says is the handler's.  HTTP/1.1, so the connection persists, and the
     ;; eof closes it.
     (cons "83-auth-digest-invalid-username-2.t"
           '(((call-handler (GET "/" 1 1 (("Host" . "www.example.com")
                                          ("Authorization" . "Digest username=\"ivanr"))))
              (write 200)
              (close eof))
             closed #f ()))))

  ;; robustness-file? : String -> Boolean
  ;; One of libhtp's invalid streams or HTTP/0.9 streams, by name.
  (define (robustness-file? name)
    (exists (lambda (word) (contains? name word)) '("invalid" "http09" "http_0_9")))

  ;; contains? : String String -> Boolean
  (define (contains? s word)
    (let ((n (string-length s)) (m (string-length word)))
      (let loop ((i 0))
        (and (<= (+ i m) n)
             (or (string=? (substring s i (+ i m)) word) (loop (+ i 1)))))))

  ;; libhtp-expected-files : (Listof String) — the streams with an
  ;; expectation, in file-name order.
  (define libhtp-expected-files
    (list-sort string<? (map car (append libhtp-expectations robustness-expectations))))

  ;; robustness-expected-files : (Listof String) — the robustness lane's,
  ;; in file-name order.
  (define robustness-expected-files
    (list-sort string<? (map car robustness-expectations)))

  ;; libhtp-expectation : String -> (U Outcome #f)
  (define (libhtp-expectation name)
    (let ((e (or (assoc name libhtp-expectations) (assoc name robustness-expectations))))
      (and e (cdr e))))

  ;; --- the run ---------------------------------------------------------------

  ;; What every handler answers.
  (define ok (make-response 200 #f '() #f))

  ;; crlf-files : (Listof String)
  ;; The streams delivered with each bare LF made CRLF, the line end HTTP
  ;; requires (RFC 9112 §2.2), which the strict parser holds a request to:
  ;; libhtp's two Expect streams, whose lines end in a bare LF.  05's is curl
  ;; 7.18's upload, whose body comes to its Content-Length, 216 bytes, only
  ;; with CRLF: its capture was CRLF, and the file was converted after.  99's
  ;; was written by hand.  The vendored bytes are never edited, and every
  ;; other stream is delivered as libhtp's chunker cuts it.
  (define crlf-files '("05-expect.t" "99-expect-100.t"))

  ;; libhtp-packets : String -> (Listof Bytevector)
  ;; The stream's client chunks, in order, as the lane delivers them: made
  ;; CRLF for a stream in crlf-files, and as the loader cuts them otherwise.
  ;; The loader skips an empty chunk, so none is empty.
  (define (libhtp-packets name)
    (let ((chunks (map cdr (filter (lambda (c) (eq? (car c) 'client))
                                   (libhtp-parse-stream
                                    (call-with-port
                                        (open-file-input-port (string-append "test/vendor/libhtp/files/" name))
                                      get-bytevector-all))))))
      (if (member name crlf-files) (map crlf chunks) chunks)))

  ;; crlf : Bytevector -> Bytevector — each LF not after a CR made CRLF.
  (define (crlf bv)
    (let-values (((port take) (open-bytevector-output-port)))
      (let loop ((i 0))
        (when (< i (bytevector-length bv))
          (let ((c (bytevector-u8-ref bv i)))
            (when (and (= c 10) (not (and (> i 0) (= (bytevector-u8-ref bv (- i 1)) 13))))
              (put-u8 port 13))
            (put-u8 port c)
            (loop (+ i 1)))))
      (take)))

  ;; handler-for : String -> (Request -> (U Response BodyReader))
  ;; What the stream `name`'s handler answers: `reads` for every stream but
  ;; 99-expect-100.t, whose recorded origin refused its PUT to /forbidden at
  ;; the head, and whose handler does too, so the stream shows the other half
  ;; of the Expect rule: no 100 for a request the handler answers at once.
  (define (handler-for name)
    (if (string=? name "99-expect-100.t") refuses-forbidden reads))

  ;; refuses-forbidden : Request -> (U Response BodyReader)
  ;; 401 at once, reading nothing, for a request for /forbidden; `reads`
  ;; otherwise.
  (define (refuses-forbidden request)
    (if (equal? (span->bytevector (request-target request)) forbidden)
        (make-response 401 #f '() #f)
        (reads request)))

  (define forbidden (string->utf8 "/forbidden"))

  ;; libhtp-outcome : String -> Outcome
  ;; What one fake connection did with the stream `name`'s client packets, one
  ;; delivery each, then the client's eof if it still reads.
  (define (libhtp-outcome name)
    (run-stream (handler-for name) (libhtp-packets name) #t))

  ;; run-stream : (Request -> (U Response BodyReader)) (Listof Bytevector) Boolean -> Outcome
  ;; What one fake connection whose handler is `handler` did with `packets`,
  ;; one delivery each, then, if `eof?`, the client's eof if it still reads.
  (define (run-stream handler packets eof?)
    (let ((sh (make-fake-connection corpus-limits handler)))
      (for-each (lambda (bv) (fake-shell-feed-input! sh bv (bytevector-length bv)))
                packets)
      (fake-shell-settle! sh)
      (when (and eof? (fake-shell-reading? sh))
        (fake-shell-deliver! sh '(eof))
        (fake-shell-settle! sh))
      (let ((s (fake-shell-conn-state sh)))
        (list (decisive (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s)
              (fake-shell-violations sh)))))

  ;; --- 35-early-response.t, answered at the head ----------------------------
  ;;
  ;; The lane's handler reads 35's body (the suites' one HTTP/1.0 body read),
  ;; which is the expectation above.  Its recorded origin answered the POST
  ;; 400 before the body, as a handler can with a response instead of a
  ;; reader, so the lane runs it so too.  The head's packet alone brings the
  ;; 400, and with it the staged close HTTP/1.0 gets: the connection lingers,
  ;; reading and dropping what the client still sends, the body among it, so
  ;; no reader is handed it, and the client's close ends it.

  ;; early-response-expectation : (List Outcome Outcome)
  ;; After the head's packet alone, and after the whole stream and its eof.
  (define early-response-expectation
    (let ((asked '(call-handler (POST "/" 1 0 (("Content-Length" . "12")
                                               ("Content-Type" . "application/x-www-form-urlencoded")
                                               ("User-Agent" . "Mozilla"))))))
      (list (list (list asked '(write 400)) 'lingering 'not-keep-alive '())
            (list (list asked '(write 400) '(close not-keep-alive)) 'closed 'not-keep-alive '()))))

  ;; early-response-outcomes : -> (List Outcome Outcome)
  ;; 35's head's packet alone, then the whole stream and its eof, each on a
  ;; fresh connection whose handler answers 400 at once, reading nothing.
  (define (early-response-outcomes)
    (let ((packets (libhtp-packets "35-early-response.t"))
          (at-once (lambda (request) (make-response 400 #f '() #f))))
      (list (run-stream at-once (list (car packets)) #f)
            (run-stream at-once packets #t))))

  ;; decisive : (Listof Action) -> (Listof Datum)
  ;; The outcome lane's decisive actions, rendered, with the bodies: each run
  ;; of body deliveries, with no other decisive action between, joined into
  ;; one `(body text)`.  Feeds, reads and deadlines follow the deliveries and
  ;; are left out.
  (define (decisive actions)
    (fold-right
     (lambda (a acc)
       (case (car a)
         ((call-handler) (cons (list 'call-handler (render-request (cadr a))) acc))
         ;; A hand-off by the bytes it hands over, though no libhtp stream's
         ;; handler takes an upgrade, so none reaches it.
         ((hand-off)
          (cons (list 'hand-off (let ((r (caddr a))) (and r (utf8->string (piece (car r) (cadr r) (caddr r))))))
                acc))
         ((deliver-body)
          (let ((text (utf8->string (piece (cadr a) (caddr a) (cadddr a)))))
            (if (and (pair? acc) (eq? (caar acc) 'body))
                (cons (list 'body (string-append text (cadar acc))) (cdr acc))
                (cons (list 'body text) acc))))
         ((write) (cons (list 'write (written-status a)) acc))
         ((close) (cons a acc))
         (else acc)))
     '() actions))

  ;; piece : Bytevector Nat Nat -> Bytevector — bv[from, to), copied.
  (define (piece bv from to)
    (let ((out (make-bytevector (- to from))))
      (bytevector-copy! bv from out 0 (- to from))
      out))

  ;; libhtp-mismatch : String [(String -> Outcome)] -> (U #f String)
  ;; #f when the stream `name` has an expectation and meets it; else why not.
  ;; `run` gives the outcome, `libhtp-outcome` unless a test says otherwise.
  ;; A run that raises is a mismatch saying what it raised, never a raise:
  ;; the ratchet calls this outside any check.
  (define libhtp-mismatch
    (case-lambda
      ((name) (libhtp-mismatch name libhtp-outcome))
      ((name run)
       (let ((expected (libhtp-expectation name)))
         (if (not expected)
             "no expectation"
             (let ((actual (attempt (lambda () (run name)))))
               (cond ((string? actual) actual)
                     ((equal? actual expected) #f)
                     (else "the outcome is not the expectation")))))))))
