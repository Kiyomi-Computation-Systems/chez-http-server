#!r6rs
;;; (http-server connection): what a request costs in allocation.  M2.2, M2.3,
;;; and the M3 exit.
;;;
;;; Decision 0002's second amendment: the 3 KiB gate is a regression ratchet
;;; counted as a total (parser, adapter and core), and shapes are the real
;;; guard.  One keep-alive connection runs whole requests the way a shell
;;; will: `bytes-arrived`, the feed through the adapter's bindings (the core
;;; pauses the parser at the message's end), the queued actions taken, then
;;; `parser-result`, `handler-responded`, `write-completed`, and the resume.
;;; The workload is the CPS spike's (research/spike/cps-core.sps §4): a
;;; keep-alive GET with three headers, fed whole.
;;;
;;; The checks:
;;;   - the total per request is within the 3,072 B ratchet;
;;;   - it does not grow with the length of a header value: the head is kept
;;;     as spans, never copied (the amendment's second shape);
;;;   - nor with the length of the target: an origin-form target's path and
;;;     query are judged in place, by uriparse's ranged `validate-component`
;;;     (v0.5.0, uriparse #21), never copied, so a long path and a long query
;;;     each cost what a short target does (every request here arrives in one
;;;     delivery: a target split across deliveries is joined once by the core,
;;;     as a header is);
;;;   - nor with the length of the Host value: it is judged in place, by
;;;     uriparse's ranged `validate-authority` (v0.6.0, uriparse #24);
;;;   - an absolute-form target costs one parse by a reused uriparse collector
;;;     more: the collector is the connection's, made once, never one per
;;;     request (M2.3, design §7.5);
;;;   - the cost stays constant from request to request: later requests on
;;;     the connection cost what earlier ones did (the third shape);
;;;   - nor does it grow with the length of the response's body: the body is
;;;     a segment of the write, never copied (design §7.3; the M3 exit);
;;;   - a field name costs the same however much of a parser keyword it
;;;     matches (byte-machine #139, fixed in v0.6.1);
;;;;   - and two requests a server meets are within the ratchet too: a JSON
;;;     POST, and ab -k's HTTP/1.0 keep-alive GET (the M3 exit).  The POST's
;;;     handler reads its body, whole and streamed: a response given instead
;;;     of a reader to a request whose head announces a body closes the
;;;     connection (decision 0013, M6.1).  curl's GET
;;;     is printed, not gated: its three fields are the CPS workload's shape,
;;;     which the ratchet already holds.  So is a browser's GET, with eleven
;;;     fields: each past the CPS workload's three costs 176 B, and reading
;;;     its Connection value 64 B more, so its total counts its fields.
;;; The first shape, per callback, is test-connection-entry.sps's.
;;;
;;; And a streamed response (M6.3; decision 0013 item 8): a GET answered with
;;; a producer whose pieces are written as they come.  Each piece costs the
;;; same however many came before it, and a 16 KiB piece costs what a
;;; 128-byte one does: a piece is a segment of its write, never copied, and a
;;; power of two's size line is made once.  A 100-byte piece costs more: its
;;; size line.  The cost of a piece is printed, not gated.
;;;
;;; And what a connection costs to open (M4.1): its parser shares the one
;;; binding list the adapter makes (design §7.5), so it costs what
;;; byte-machine's make-parser does with a list of twenty-five bindings made
;;; once, beforehand.
;;;
;;; Oracles: the 3,072 B ratchet and the shapes, from 0002's second amendment;
;;; Chez's cumulative allocation counter `sstats-bytes`, calibrated below and
;;; never the live heap; and what uriparse's own reused collector costs on
;;; the same target, and byte-machine's own make-parser on a list made once,
;;; each read by that counter.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) statistics sstats-bytes)
        (http-server connection) (http-server private adapter)
        (http-server response) (http-server limits) (http-server body)
        (uri collect)
        (only (generated httparse-message) httparse-message-machine)
        (only (httparse modes) httparse-message-type-value)
        (byte-machine runtime))

(define (b s) (string->utf8 s))

(define gate 3072)
(define warm 1000)
(define reps 10000)

(define resp (make-response 200 #f '() #f))

;; with-body : Nat -> Response — a 200 with an `n`-byte body.
(define (with-body n) (make-response 200 #f '() (make-bytevector n 97)))

;; connection : Bytevector Response -> (-> Void)
;; A keep-alive connection that serves `request` once per call, answering
;; `response`.
(define (connection request response)
  (let* ((queued '())
         (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (set! queued (cons actions queued)))))
         (p (make-conn-parser ctx))
         (len (bytevector-length request)))
    (lambda ()
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (assertion-violation 'connection "the core did not pause the parser"
                               (parser-result-status r)))
        (set! queued '())
        (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                      (parser-result-next r) #f #f))
        (let ((w (assq 'write (conn-context-step! ctx (list 'handler-responded response)))))
          (conn-context-step! ctx (list 'write-completed (caddr w))))
        (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
          (assertion-violation 'connection "the connection did not return to idle"
                               (conn-phase (conn-context-state ctx))))
        (parser-resume! p)))))

;; reading-connection : Bytevector (-> BodyReader) -> (-> Void)
;; A keep-alive connection that serves `request`, whose head announces a
;; body, once per call, as a shell does (decision 0013): the request fed
;; whole, the core pauses the parser at the message's end, and asks the
;; handler with the feed's result; the handler answers with a reader made by
;; `make-reader`; the pieces the core hands it are handed over; and its
;; response is written.  What the callbacks queue is kept as the gate's own
;; connection keeps it, a pair a batch.
(define (reading-connection request make-reader)
  (let* ((queued '())
         (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (set! queued (cons actions queued)))))
         (p (make-conn-parser ctx))
         (len (bytevector-length request)))
    (lambda ()
      (set! queued '())
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (assertion-violation 'reading-connection "the core did not pause the parser"
                               (parser-result-status r)))
        (unless (assq 'call-handler
                      (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                                    (parser-result-next r) #f #f)))
          (assertion-violation 'reading-connection "the core did not ask the handler"))
        (let ((reader (make-reader)))
          (for-each (lambda (a)
                      (when (eq? (car a) 'deliver-body)
                        ((body-reader-on-piece reader) (cadr a) (caddr a) (cadddr a))))
                    (conn-context-step! ctx (list 'handler-responded reader)))
          (let ((w (assq 'write (conn-context-step!
                                 ctx (list 'handler-responded ((body-reader-on-end reader)))))))
            (unless w
              (assertion-violation 'reading-connection "the reader's response was not written"))
            (conn-context-step! ctx (list 'write-completed (caddr w)))))
        (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
          (assertion-violation 'reading-connection "the connection did not return to idle"
                               (conn-phase (conn-context-state ctx))))
        (parser-resume! p)))))

;; whole-buffers : Nat Nat -> Nat
;; What the core allocates reading a body of `size` bytes whole, delivered
;; in `piece`-byte pieces, averaged over ten connections: a POST's head, the
;; handler asked and answered with a whole reader (no cap of its own), each
;; stepped before the count, then each piece entered as the adapter enters
;; it.  The pieces are the same bytes each time, so only the buffer the core
;; grows is counted.
(define (whole-buffers size piece)
  (let* ((head (b (string-append "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: "
                                 (number->string size) "\r\n\r\n")))
         (bytes (make-bytevector piece 97))
         (read-whole (lambda ()
                       (let* ((ctx (make-conn-context
                                    (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                    (lambda (actions) #f)))
                              (p (make-conn-parser ctx))
                              (len (bytevector-length head)))
                         (conn-context-step! ctx (list 'bytes-arrived head 0 len))
                         (parser-feed! p head 0 len)
                         (conn-context-step! ctx '(parser-result need-input 0 0 #f #f))
                         (conn-context-step! ctx (list 'handler-responded
                                                       (read-whole-body (lambda (body) resp) #f)))
                         (conn-context-state ctx))))
         (states (let loop ((i 0) (acc '())) (if (= i 10) acc (loop (+ i 1) (cons (read-whole) acc))))))
    (let ((before (sstats-bytes (statistics))))
      (for-each (lambda (s)
                  (let loop ((arrived 0))
                    (when (< arrived size)
                      (let ((n (min piece (- size arrived))))
                        (conn-parser-step s 'on-body-data bytes 0 n)
                        (loop (+ arrived n))))))
                states)
      (div (- (sstats-bytes (statistics)) before) 10))))

;; streaming-connection : Bytevector Nat Nat -> (-> Void)
;; A keep-alive connection that serves `request` once per call, answered
;; with a 200 streamed from a producer of `pieces` pieces, each the same
;; `size`-byte bytevector handed out again, as a shell performs it (M6.3):
;; each `notify-producer` answered at once with the producer's next answer,
;; as producer-event makes it, and the writes completed after, oldest first,
;; a turn at a time, a completion that asks for a piece performed too.  The
;; pieces stay under decision 0005's high water, so the producer waits only
;; at 64 writes outstanding, and goes on at 16 (M6.3's second review).
(define (streaming-connection request pieces size)
  (let* ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) #f)))
         (p (make-conn-parser ctx))
         (len (bytevector-length request))
         (piece (make-bytevector size 97)))
    (lambda ()
      (let ((left pieces) (writes '()))
        (define (producer)
          (if (= left 0) (eof-object) (begin (set! left (- left 1)) piece)))
        (define (take actions)
          (for-each (lambda (a)
                      (case (car a)
                        ((write) (set! writes (cons (caddr a) writes)))
                        ((notify-producer) (take (conn-context-step! ctx (producer-event (producer)))))
                        (else #f)))
                    actions))
        (conn-context-step! ctx (list 'bytes-arrived request 0 len))
        (let ((r (parser-feed! p request 0 len)))
          (unless (eq? (parser-result-status r) 'paused)
            (assertion-violation 'streaming-connection "the core did not pause the parser"
                                 (parser-result-status r)))
          (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                        (parser-result-next r) #f #f))
          (take (conn-context-step! ctx (list 'handler-responded (make-response 200 #f '() producer))))
          (let settle ()
            (let ((turn (reverse writes)))
              (set! writes '())
              (unless (null? turn)
                (for-each (lambda (n)
                            (let ((as (conn-context-step! ctx (list 'write-completed n))))
                              (when (exists (lambda (a) (eq? (car a) 'notify-producer)) as)
                                (take as))))
                          turn)
                (settle))))
          (unless (and (= left 0) (eq? (conn-phase (conn-context-state ctx)) 'idle))
            (assertion-violation 'streaming-connection "the stream was not written whole"
                                 left (conn-phase (conn-context-state ctx))))
          (parser-resume! p))))))

;; The readers the POSTs are answered with: the body read whole, as the
;; buffering helper reads it, and streamed and dropped.  Each is made for its
;; request, as a handler makes it.
(define (whole) (read-whole-body (lambda (body) resp)))
(define (drop bv from to) #f)
(define (answer) resp)
(define (streamed) (read-body drop answer))

;; What a thunk last returned, so an allocation it makes is never dead code.
(define hold #f)

;; bytes-per-call : (-> Any) Nat -> Nat
;; Bytes one call of `thunk` allocates, averaged over `n` calls.
(define (bytes-per-call thunk n)
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i n) (set! hold (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) n)))

;; per-request : Bytevector [Response] -> Nat
;; After a warm-up, over `reps` requests, each answered `resp` unless another
;; response is given.
(define per-request
  (case-lambda
    ((request) (per-request request resp))
    ((request response)
     (let ((serve (connection request response)))
       (bytes-per-call serve warm)
       (bytes-per-call serve reps)))))

;; warmed : (-> Any) -> Nat — the same, for any thunk.
(define (warmed thunk)
  (bytes-per-call thunk warm)
  (bytes-per-call thunk reps))

(define (repeat s n)
  (let loop ((i 0) (acc '())) (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

(define cps (b "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
;; The same request with a 500-byte User-Agent; with a 500-byte target, all
;; path; with a 500-byte target, nearly all query; with a 500-byte Host value;
;; and with its target in absolute-form.
(define cps-long-header
  (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: " (repeat "s" 500)
                    "\r\nAccept: */*\r\n\r\n")))
(define cps-long-target
  (b (string-append "GET /" (repeat "a" 499)
                    " HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n")))
(define cps-long-query
  (b (string-append "GET /a?" (repeat "q" 497)
                    " HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n")))
(define cps-long-host
  (b (string-append "GET /a HTTP/1.1\r\nHost: " (repeat "h" 500)
                    "\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n")))
(define cps-absolute
  (b "GET http://x/a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
;; The same request with one more 17-byte field name, which matches the first
;; byte of the parser's keyword Transfer-Encoding, or its first 16 (the matcher
;; that once copied its prefix per byte: byte-machine #139).
(define (cps-with-name name)
  (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n" name ": a\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n")))
(define cps-keyword-1 (cps-with-name "Txxxxxxxxxxxxxxxx"))
(define cps-keyword-16 (cps-with-name "Transfer-Encodinx"))

;; Requests a server meets, as their clients send them: curl 8.7.1's GET; a
;; JSON POST with a 13-byte body; ApacheBench 2.3's GET under -k, HTTP/1.0
;; kept alive; and a browser's GET, eleven fields, Connection among them.
(define curl-get
  (b "GET / HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n\r\n"))
(define json-post
  (b (string-append "POST /api HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n"
                    "Content-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}")))
(define ab-keep-alive
  (b "GET / HTTP/1.0\r\nConnection: Keep-Alive\r\nHost: localhost:8080\r\nUser-Agent: ApacheBench/2.3\r\nAccept: */*\r\n\r\n"))
(define browser-get
  (b (string-append "GET /index.html HTTP/1.1\r\nHost: localhost:8080\r\nConnection: keep-alive\r\n"
                    "sec-ch-ua: \"Chromium\";v=\"128\"\r\nsec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: \"macOS\"\r\n"
                    "Upgrade-Insecure-Requests: 1\r\nUser-Agent: Mozilla/5.0 (Macintosh)\r\n"
                    "Accept: text/html,application/xhtml+xml\r\nSec-Fetch-Site: none\r\n"
                    "Accept-Encoding: gzip, deflate, br\r\nAccept-Language: en-US,en;q=0.9\r\n\r\n")))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

;; measure : (-> Nat) -> (U Nat 'refused)
;; A reading, or 'refused if a request on the connection was not served, so
;; that failure is a check rather than the suite ending early.
(define (measure thunk)
  (guard (e ((assertion-violation? e)
             (diag (string-append "connection-allocation: a request was not served: "
                                  (if (message-condition? e) (condition-message e) "?")))
             'refused))
    (thunk)))

(run-suite "connection-allocation"
  (lambda ()
    ;; Calibration: an instrument that always read zero would pass the shapes.
    (let* ((before (sstats-bytes (statistics)))
           (junk (make-bytevector 100000 0))
           (after (sstats-bytes (statistics))))
      (test-eq "the counter sees a 100000-byte bytevector" 'seen
               (if (and (>= (- after before) 100000) (= (bytevector-length junk) 100000))
                   'seen
                   'missed)))
    (test-eqv "an empty loop allocates nothing per iteration"
              0 (bytes-per-call (lambda () #f) reps))

    (let ((short (measure (lambda () (per-request cps))))
          (long-header (measure (lambda () (per-request cps-long-header))))
          (long-target (measure (lambda () (per-request cps-long-target))))
          (long-query (measure (lambda () (per-request cps-long-query))))
          (long-host (measure (lambda () (per-request cps-long-host))))
          (absolute (measure (lambda () (per-request cps-absolute))))
          (body-100 (measure (lambda () (per-request cps (with-body 100)))))
          (body-999 (measure (lambda () (per-request cps (with-body 999))))))
      (test-eq "every request on the eight connections is served" 'served
               (if (for-all number? (list short long-header long-target long-query long-host absolute
                                          body-100 body-999))
                   'served 'refused))
      (when (for-all number? (list short long-header long-target long-query long-host absolute
                                   body-100 body-999))
        (diag (string-append "connection-allocation: the CPS workload "
                             (number->string short) " B/request (ratchet "
                             (number->string gate) " B); with a 500-byte header "
                             (number->string long-header) ", with a 500-byte target "
                             (number->string long-target) ", with a 500-byte query "
                             (number->string long-query) ", with a 500-byte Host "
                             (number->string long-host) ", in absolute-form "
                             (number->string absolute) "; answered with a 100-byte body "
                             (number->string body-100) ", with a 999-byte body "
                             (number->string body-999)))
        (test-eq "a keep-alive request costs something" 'allocates
                 (if (> short 0) 'allocates 'free))
        (test-eq "and no more than the 3,072 B ratchet" 'within
                 (if (<= short gate) 'within 'over))
        (test-eqv "a 500-byte header value costs what a short one does" short long-header)
        ;; "/a", "/aaa..." and "/a?qqq..." are 2, 500 and 500 bytes, each judged
        ;; where it arrived: the path, and the query after the "?".
        (test-eqv "a 500-byte target costs what a short one does" short long-target)
        (test-eqv "a 500-byte target with a query costs what a short one does" short long-query)
        ;; The Host value is judged where it arrived, as the target is.
        (test-eqv "a 500-byte Host value costs what a short one does" short long-host)
        ;; An absolute-form target costs one parse by a reused collector more:
        ;; uriparse's own, measured on the same target.
        (let* ((c (make-uri-collector 'uri))
               (t (b "http://x/a"))
               (parse (warmed (lambda ()
                                (uri-collector-reset! c)
                                (uri-collect-feed! c t 0 (bytevector-length t))
                                (uri-parse-result-validate (uri-collect-finish! c))))))
          (test-eqv "an absolute-form target costs one reused collector's parse more"
                    (+ short parse) absolute))
        ;; A response's body is a segment of the write, never copied (design
        ;; §7.3; the M3 exit).  Both lengths take three digits, so the header
        ;; block is the same size and only the body differs.
        (test-eqv "a 999-byte body costs what a 100-byte one does" body-100 body-999)))

    ;; A field name costs the same however much of a parser keyword it
    ;; matches.  byte-machine's matcher once copied the prefix it had matched
    ;; on every byte, so a name matching 16 bytes of Transfer-Encoding cost
    ;; 2,880 B more than one matching 1 (byte-machine #139, filed at the M3
    ;; exit, fixed in v0.6.1 and pinned through chez-httparse v0.4.3).
    (let ((one (measure (lambda () (per-request cps-keyword-1))))
          (sixteen (measure (lambda () (per-request cps-keyword-16)))))
      (test-eq "both near-miss requests are served" 'served
               (if (and (number? one) (number? sixteen)) 'served 'refused))
      (when (and (number? one) (number? sixteen))
        (test-eqv "a 17-byte name costs the same however much of a keyword it matches" one sixteen)))

    ;; Requests a server meets: a JSON POST and ab -k's GET, each within the
    ;; ratchet; curl's GET, the CPS workload's shape, and a browser's are
    ;; printed.  On the owner's word, at the M3 exit (2026-09-26).
    (let ((curl (measure (lambda () (per-request curl-get))))
          (json (measure (lambda () (warmed (reading-connection json-post whole)))))
          (json-streamed (measure (lambda () (warmed (reading-connection json-post streamed)))))
          (ab (measure (lambda () (per-request ab-keep-alive))))
          (browser (measure (lambda () (per-request browser-get)))))
      (test-eq "every request a server meets is served" 'served
               (if (for-all number? (list curl json json-streamed ab browser)) 'served 'refused))
      (when (for-all number? (list curl json json-streamed ab browser))
        (diag (string-append "connection-allocation: requests a server meets: curl's GET "
                             (number->string curl) " B/request, a JSON POST read whole "
                             (number->string json) " and streamed " (number->string json-streamed)
                             ", ab -k's GET " (number->string ab)
                             "; a browser's GET, eleven fields, " (number->string browser)))
        (test-eq "a JSON POST with Content-Type and Content-Length, its body read whole, is within the ratchet" 'within
                 (if (<= json gate) 'within 'over))
        (test-eq "the same POST, its body streamed, is within the ratchet" 'within
                 (if (<= json-streamed gate) 'within 'over))
        (test-eq "ab -k's HTTP/1.0 keep-alive GET is within the ratchet" 'within
                 (if (<= ab gate) 'within 'over))))

    ;; A body read whole is buffered as it arrives, the buffer growing to the
    ;; declared length once that is at most twice what has arrived and
    ;; doubling before: the buffers it grows through come to less than twice
    ;; the body (M6.1's review).  Grown by each piece alone, a 64 KiB body in
    ;; 1,000-byte pieces would be copied at each of its 66.
    (let ((grown (measure (lambda () (whole-buffers 65536 1000)))))
      (when (number? grown)
        (diag (string-append "connection-allocation: a 64 KiB body read whole, in 1,000-byte pieces, "
                             (number->string grown) " B")))
      (test-eq "a 64 KiB body read whole, in 1,000-byte pieces, allocates less than twice its length"
               'within
               (cond ((not (number? grown)) grown)
                     ((< grown (* 2 65536)) 'within)
                     (else (list 'over grown)))))

    ;; A streamed response (M6.3): curl's GET answered with a producer of 16,
    ;; 32 and 48 pieces of 100 bytes, and of 8 pieces of 128 bytes, of
    ;; 16 KiB and of 100 bytes.  The sixteen pieces from the 17th to the 32nd
    ;; cost what the first sixteen did, and the sixteen from the 33rd what
    ;; those did: the core keeps nothing that grows with the pieces written.
    ;; Forty-eight pieces and the head stay under the 64 writes a stream may
    ;; have outstanding, so none of these streams waits for a completion
    ;; (M6.3's second review), whose own cost would be read as the pieces'.
    ;; And a piece's bytes are a segment of its write, never
    ;; copied, so its length changes nothing but its size line, made once for
    ;; a power of two, `80` or `4000`, and for its piece otherwise, `64`.
    (let ((c16 (measure (lambda () (warmed (streaming-connection curl-get 16 100)))))
          (c32 (measure (lambda () (warmed (streaming-connection curl-get 32 100)))))
          (c48 (measure (lambda () (warmed (streaming-connection curl-get 48 100)))))
          (small (measure (lambda () (warmed (streaming-connection curl-get 8 128)))))
          (large (measure (lambda () (warmed (streaming-connection curl-get 8 16384)))))
          (other (measure (lambda () (warmed (streaming-connection curl-get 8 100))))))
      (test-eq "every streamed response is written whole" 'served
               (if (for-all number? (list c16 c32 c48 small large other)) 'served 'refused))
      (when (for-all number? (list c16 c32 c48 small large other))
        (diag (string-append "connection-allocation: curl's GET streamed, 16 pieces "
                             (number->string c16) " B, 32 " (number->string c32)
                             ", 48 " (number->string c48) "; a piece "
                             (number->string (div (- c32 c16) 16)) " B; 8 pieces of 16 KiB "
                             (number->string large) ", of 128 bytes " (number->string small)
                             ", of 100 bytes " (number->string other)))
        ;; Per piece, so the byte a collection adds to an average now and
        ;; then (9,729 B for the second 32 pieces, where the first 16 took
        ;; 4,864) is not read as a piece's.
        (test-eqv "a piece costs the same however many came before it"
                  (div (- c32 c16) 16) (div (- c48 c32) 16))
        (test-eq "and a streamed piece costs something" 'allocates
                 (if (> (- c32 c16) 0) 'allocates 'free))
        (test-eqv "a 16 KiB piece costs what a 128-byte one does" small large)
        (test-eq "a 100-byte piece costs more than a 128-byte one: its own size line" 'more
                 (if (> other small) 'more (list 'not-more other small)))))

    ;; The same connection, twice as long: the requests after the first
    ;; 11,000 cost what those did.
    (let* ((serve (connection cps resp))
           (first (measure (lambda () (bytes-per-call serve warm) (bytes-per-call serve reps))))
           (later (measure (lambda () (bytes-per-call serve reps)))))
      (test-eq "every request on the long connection is served" 'served
               (if (and (number? first) (number? later)) 'served 'refused))
      (when (and (number? first) (number? later))
        (test-eqv "request 20,000 costs what request 1,000 did" first later)))

    ;; A connection's parser shares the adapter's binding list, one for the
    ;; server (design §7.5; M4.1): it costs what make-parser does with a list
    ;; of the twenty-five bindings made once, here, before either is measured.
    (let* ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                   (lambda (actions) #f)))
           (made-once (map (lambda (name)
                             (list name (if (memq name conn-span-callbacks)
                                            (lambda (p c bv from to) callback-continue)
                                            (lambda (p c) callback-continue))))
                           conn-parser-callbacks))
           (inits (list (cons 'type (httparse-message-type-value 'request))))
           (shared (warmed (lambda () (make-parser httparse-message-machine made-once ctx inits))))
           (opened (warmed (lambda () (make-conn-parser ctx)))))
      (diag (string-append "connection-allocation: a connection's parser "
                           (number->string opened) " B; make-parser on a list made once "
                           (number->string shared) " B"))
      (test-eqv "a connection's parser costs what one on a binding list made once does"
                shared opened))))
