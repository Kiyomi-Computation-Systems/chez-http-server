#!r6rs
;;; M6.1, 2026-09-28: how a handler reads a body, and writes one of unknown
;;; length — what each way costs, measured before the decision (plan §14).
;;;
;;; PART 1, brief risk 3 at the pin (chez-httparse v0.4.3): the two facts the
;;; pinned tests will assert, and the plan's mutation.
;;;   (1a) a pause inside on-body-data re-feeds from `parser-result-next`, and
;;;        each body byte is delivered once;
;;;   (1b) after a pause on a body's last byte, the message is not complete
;;;        until one more feed, here an empty one;
;;;   (1c) the mutation: the feed after the pause starts where the delivery
;;;        started.
;;;
;;; PART 2, reading.  Each way is modelled as a cycle over the real parser:
;;; the pauses it asks for are the parser's own, and the lists the core and
;;; shell would make for them (a `parser-result` event, the pending input, a
;;; `feed-parser`, a `deliver-body`, a credit) are made as the core makes
;;; them (M2.4's cycle).  What is measured is what a way adds to today's
;;; cycle, where the handler runs at the message's end and the body is
;;; dropped:
;;;   (A) streams: for a request with a body the handler runs once the feed
;;;       that completed the head returns, and answers with a reader; each
;;;       piece the parser meets is queued, as the core queues `deliver-body`
;;;       today, and handed to the reader once its feed returns; at the end
;;;       the reader gives the response;
;;;   (Am) (A) with the design sketch's one-slot mailbox: each piece pauses
;;;       the parser, is handed to the reader, and the reader's return, the
;;;       credit, resumes it and feeds the rest of the delivery, even when
;;;       empty (brief risk 3);
;;;   (A+) the buffering helper: (A), its reader copying the pieces into one
;;;       bytevector, of the declared length, or a copy per piece joined at
;;;       the end when the body is chunked;
;;;   (B) the server buffers every body, as the helper does, and the handler
;;;       runs at the end with it;
;;;   (C) (A) with the design sketch's `(handler request respond)`: a
;;;       `respond` procedure made for each request.
;;; And the JSON POST through the real parser, adapter and core, today, as
;;; tests/test-connection-allocation.sps runs it: the baseline every way adds
;;; to, and the 3,072 B gate it is held to.
;;; Workloads: the gate's JSON POST (a 13-byte body, fed whole), and a 1 MiB
;;; body in 64 deliveries of 16 KiB, framed by Content-Length and chunked
;;; (16 KiB chunks).  Per request, after 100 warm-up runs, averaged over 1,000
;;; (the MiB) or 10,000 (the POST).  And what a connection holds live once a
;;; MiB body's last piece is taken, before its response: the live heap after
;;; a collection of every generation, less the same with no request in flight.
;;;
;;; PART 3, writing a body of unknown length, per 16 KiB piece, the protocol's
;;; own cost (the chunk framing around a piece is the same for all three):
;;;   (i)   a thunk the server calls for each piece: a bytevector, or the end
;;;         of file object at the end, as `get-bytevector-some` answers;
;;;   (ii)  a binary input port the server reads into one buffer of its own;
;;;   (iii) the design sketch's `(lambda (emit done) ...)`, called for pieces.
;;; Each producer holds one 16 KiB bytevector and hands it out again: the
;;; write copies at the call (design §7.3), so nothing needs a fresh one.
;;;
;;; Run on the project's library path (the ledger's M3 entry gives it).
(import (rnrs)
        (only (chezscheme) statistics sstats-bytes collect collect-maximum-generation bytes-allocated)
        (byte-machine runtime) (generated httparse-message) (httparse modes)
        (only (httparse decisions) F-CHUNKED)
        (only (http-server connection) make-conn-state)
        (only (http-server private adapter) make-conn-context conn-context-step! make-conn-parser)
        (only (http-server response) make-response)
        (only (http-server limits) default-limits))

(define (b s) (string->utf8 s))
(define (show . xs) (for-each display xs) (newline))
;; keep! : Any -> Void — keep a value where Chez cannot compile the store
;; away: a variable that is only ever assigned is dropped, and with it the
;; allocation of a value stored in it (M3.3's calibration).
(define keeper (vector #f))
(define (keep! x) (vector-set! keeper 0 x))

;; bytes-per-run : (-> Any) Nat Nat -> Nat — after `warm` runs, averaged over `n`.
(define (bytes-per-run thunk warm n)
  (let loop ((i 0)) (when (< i warm) (keep! (thunk)) (loop (+ i 1))))
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i n) (keep! (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) n)))

;;; --- the parser, and a connection modelled on the core's cycle --------------

;; A connection: the parser, and what the cycle keeps.  `pause-head?` and
;; `pause-body?` say where the parser pauses; the message's end always does.
(define-record-type conn
  (fields (mutable parser)
          (mutable way)          ; today, A, Am, A+, B, C
          (mutable queue)        ; what the callbacks asked for, newest first
          (mutable pending)      ; (bv next end), as the core keeps it
          (mutable length)       ; the declared Content-Length, or #f
          (mutable reader)       ; (A)'s answer: (on-piece . on-end)
          (mutable buffer)       ; (B)'s and (A+)'s copy
          (mutable filled)
          (mutable chunks)       ; a chunked body's copies, newest first
          (mutable response)
          (mutable hold-end?)    ; stop at the message's end, for `held`
          (mutable respond)))    ; (C)'s procedure, made for each request

(define (queue! c x) (conn-queue-set! c (cons x (conn-queue c))))

(define (streams? c) (memq (conn-way c) '(A Am A+ C)))

;; The body delivered, as the core delivers it: a `deliver-body` action for
;; each piece, today dropped; (B) copies it.
(define (body-piece! c bv from to)
  (let ((action (list 'deliver-body bv from to)))
    (case (conn-way c)
      ((B) (keep! action) (copy-in! c bv from to) callback-continue)
      ((Am) (queue! c action) callback-pause)
      ((A A+ C) (queue! c action) callback-continue)
      (else (keep! action) callback-continue))))

;; copy-in! : Conn Bytevector Nat Nat -> Void — the server's buffer, or the
;; helper's: the declared length allocated once, or, chunked, a copy per piece.
(define (copy-in! c bv from to)
  (if (conn-length c)
      (begin
        (unless (conn-buffer c) (conn-buffer-set! c (make-bytevector (conn-length c))))
        (bytevector-copy! bv from (conn-buffer c) (conn-filled c) (- to from))
        (conn-filled-set! c (+ (conn-filled c) (- to from))))
      (let ((piece (make-bytevector (- to from))))
        (bytevector-copy! bv from piece 0 (- to from))
        (conn-chunks-set! c (cons piece (conn-chunks c))))))

;; joined : Conn -> Bytevector — the body a buffering way hands over.
(define (joined c)
  (or (conn-buffer c)
      (let* ((pieces (reverse (conn-chunks c)))
             (out (make-bytevector (fold-left (lambda (n p) (+ n (bytevector-length p))) 0 pieces))))
        (fold-left (lambda (at p) (bytevector-copy! p 0 out at (bytevector-length p)) (+ at (bytevector-length p)))
                   0 pieces)
        out)))

(define (continue-event p c) callback-continue)
(define (continue-span p c bv from to) callback-continue)

(define bindings
  (map (lambda (name)
         (list name
               (case name
                 ((on-headers-complete)
                  (lambda (p c)
                    (let ((flags (parser-field-ref p 'flags)) (cl (parser-field-ref p 'content-length)))
                      (conn-length-set! c (and (zero? (bitwise-and flags F-CHUNKED)) cl))
                      (when (and (streams? c) (or (positive? cl) (not (zero? (bitwise-and flags F-CHUNKED)))))
                        (queue! c (list 'call-handler 'request)))
                      callback-continue)))
                 ((on-body-data) (lambda (p c bv from to) (body-piece! c bv from to)))
                 ((on-message-complete) (lambda (p c) (queue! c '(message-end)) callback-pause))
                 ((on-method-data on-url-data on-protocol-data on-version-data on-status-data
                   on-header-field-data on-header-value-data
                   on-chunk-extension-name-data on-chunk-extension-value-data)
                  continue-span)
                 (else continue-event))))
       '(on-reset on-message-begin on-method-data on-method-complete
         on-url-data on-url-complete on-protocol-data on-protocol-complete
         on-version-data on-version-complete on-status-data on-status-complete
         on-header-field-data on-header-field-complete
         on-header-value-data on-header-value-complete
         on-headers-complete on-body-data on-chunk-header
         on-chunk-extension-name-data on-chunk-extension-name-complete
         on-chunk-extension-value-data on-chunk-extension-value-complete
         on-chunk-complete on-message-complete)))

(define request-type (list (cons 'type (httparse-message-type-value 'request))))

;; connection : Symbol -> Conn — its parser's context is the connection.
(define (connection way)
  (let ((c (make-conn #f way '() #f #f #f #f 0 '() #f #f #f)))
    (conn-parser-set! c (make-parser httparse-message-machine bindings c request-type))
    c))

;; The handler: it reads nothing but the body, and answers a constant.
(define response 'response)

;; (A)'s reader, as a handler writes it: a count of the bytes, and the answer.
(define (streaming-reader)
  (let ((n 0))
    (cons (lambda (bv from to) (set! n (+ n (- to from))))
          (lambda () (keep! n) response))))

;; (A+)'s: the helper, whose reader copies into the connection's buffer here.
(define (buffering-reader c)
  (cons (lambda (bv from to) (copy-in! c bv from to))
        (lambda () (keep! (joined c)) response)))

;; feed! : Conn Bytevector Nat Nat -> Void
;; One feed, as the shell performs it: the result dispatched as the core's
;; `parser-result` event, the pending input kept from `next`, and the queued
;; actions run in order.  A pause at the head or at a piece resumes once
;; the handler has answered or the reader has taken the piece: the credit.
(define (feed! c bv start end)
  (let* ((r (parser-feed! (conn-parser c) bv start end))
         (event (list 'parser-result (parser-result-status r) (parser-result-consumed r)
                      (parser-result-next r) #f #f)))
    (keep! event)
    (when (eq? (parser-result-status r) 'paused)
      (conn-pending-set! c (list bv (parser-result-next r) end)))
    (let ((actions (reverse (conn-queue c))))
      (conn-queue-set! c '())
      (for-each (lambda (a) (perform! c a)) actions))))

(define (perform! c a)
  (case (car a)
    ((call-handler)
     (let ((answer (case (conn-way c)
                     ((A Am C) (streaming-reader))
                     ((A+) (buffering-reader c)))))
       (when (eq? (conn-way c) 'C)
         (conn-respond-set! c (lambda (resp) (conn-response-set! c resp))))
       (conn-reader-set! c answer)
       (keep! (list 'handler-responded answer))))
    ((deliver-body)
     ((car (conn-reader c)) (cadr a) (caddr a) (cadddr a))
     (when (eq? (conn-way c) 'Am)
       (keep! (list 'body-credit 1))
       (resume! c)))
    ((message-end)
     (if (conn-hold-end? c) (queue! c a) (end! c)))))

;; end! : Conn -> Void — the reader's answer, or the handler's, and back to idle.
(define (end! c)
  (case (conn-way c)
    ((A Am A+) (conn-response-set! c ((cdr (conn-reader c)))))
    ((C) ((conn-respond c) ((cdr (conn-reader c)))) (conn-respond-set! c #f))
    ((B) (keep! (joined c)) (conn-response-set! c response))
    (else (conn-response-set! c response)))
  ;; the response written, the connection back to idle, as today
  (conn-pending-set! c #f) (conn-reader-set! c #f)
  (conn-buffer-set! c #f) (conn-filled-set! c 0) (conn-chunks-set! c '())
  (parser-resume! (conn-parser c)))

;; resume! : Conn -> Void — resume, and feed the pending input, empty or not.
(define (resume! c)
  (let ((pending (conn-pending c)))
    (conn-pending-set! c #f)
    (parser-resume! (conn-parser c))
    (keep! (cons 'feed-parser pending))
    (feed! c (car pending) (cadr pending) (caddr pending))))

;; run : Conn (Listof Bytevector) -> (-> Void) — a request in deliveries.
(define (run c deliveries)
  (lambda ()
    (for-each (lambda (bv) (keep! (list 'bytes-arrived bv 0 (bytevector-length bv)))
                (feed! c bv 0 (bytevector-length bv)))
              deliveries)
    (unless (eq? (conn-response c) response)
      (assertion-violation 'run "no response" (conn-way c)))
    (conn-response-set! c #f)))

;;; --- the workloads -----------------------------------------------------------

(define json-post
  (list (b (string-append "POST /api HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n"
                          "Content-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}"))))

(define KiB 1024)
(define MiB (* 1024 1024))

;; mib-length : (Listof Bytevector) — a MiB body framed by Content-Length, in
;; deliveries of 16 KiB, the head in the first.
(define (split bv size)
  (let loop ((at 0) (acc '()))
    (if (>= at (bytevector-length bv))
        (reverse acc)
        (let* ((n (min size (- (bytevector-length bv) at))) (out (make-bytevector n)))
          (bytevector-copy! bv at out 0 n)
          (loop (+ at n) (cons out acc))))))

(define (concat . bvs)
  (let ((out (make-bytevector (fold-left (lambda (n x) (+ n (bytevector-length x))) 0 bvs))))
    (fold-left (lambda (at x) (bytevector-copy! x 0 out at (bytevector-length x)) (+ at (bytevector-length x)))
               0 bvs)
    out))

(define mib-length
  (split (concat (b (string-append "PUT /up HTTP/1.1\r\nHost: x\r\nContent-Length: "
                                   (number->string MiB) "\r\n\r\n"))
                 (make-bytevector MiB 97))
         (* 16 KiB)))

(define mib-chunked
  (split (apply concat
                (b "PUT /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
                (append
                 (let loop ((i 0) (acc '()))
                   (if (= i 64)
                       acc
                       (loop (+ i 1) (cons* (b "4000\r\n") (make-bytevector (* 16 KiB) 97) (b "\r\n") acc))))
                 (list (b "0\r\n\r\n"))))
         (* 16 KiB)))

;;; --- PART 1 ------------------------------------------------------------------

(define seen '())
(define (note! . xs) (set! seen (cons xs seen)))
(define (text bv from to) (utf8->string (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) o)))

(define recording
  (map (lambda (row)
         (let ((name (car row)))
           (list name
                 (case name
                   ((on-body-data) (lambda (p c bv from to) (note! 'body (text bv from to)) callback-pause))
                   ((on-message-complete) (lambda (p c) (note! 'message-complete) callback-pause))
                   ((on-message-begin) (lambda (p c) (note! 'message-begin) callback-continue))
                   ((on-url-data) (lambda (p c bv from to) (note! 'url (text bv from to)) callback-continue))
                   ((on-headers-complete) (lambda (p c) callback-continue))
                   (else (cadr row))))))
       bindings))

(define (recorder) (make-parser httparse-message-machine recording #f request-type))

(define (result r) (list (parser-result-status r) 'consumed (parser-result-consumed r) 'next (parser-result-next r)))

;; feed-all : Parser Bytevector Nat -> (Listof Result)
;; Feed one delivery from `start`, pausing and resuming as the core would,
;; re-feeding from `next` after each pause, until the delivery is taken.
(define (feed-all p bv start)
  (let loop ((at start) (out '()))
    (let ((r (parser-feed! p bv at (bytevector-length bv))))
      (if (and (eq? (parser-result-status r) 'paused) (< (parser-result-next r) (bytevector-length bv)))
          (begin (parser-resume! p) (loop (parser-result-next r) (cons (result r) out)))
          (reverse (cons (result r) out))))))

(show "=== PART 1: brief risk 3 at the pin")
(let* ((p (recorder))
       (d1 (b "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n01234"))
       (d2 (b "56789GET /b HTTP/1.1\r\nHost: y\r\n\r\n")))
  (show "(1a) Content-Length 10, in two deliveries, a GET behind it; every piece pauses")
  (show "  delivery 1: " (feed-all p d1 0))
  (parser-resume! p)
  (show "  delivery 2: " (feed-all p d2 0))
  (show "  delivered: " (reverse seen)))
(set! seen '())
(let* ((p (recorder))
       (d (b "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\nGET /b HTTP/1.1\r\nHost: y\r\n\r\n")))
  (show "(1a) chunked, two chunks and a GET, in one delivery")
  (show "  " (feed-all p d 0))
  (show "  delivered: " (reverse seen)))
(set! seen '())
(let* ((p (recorder))
       (d (b "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")))
  (show "(1b) the delivery ends on the body's last byte")
  (let ((r (parser-feed! p d 0 (bytevector-length d))))
    (show "  the feed: " (result r) "  delivered: " (reverse seen))
    (parser-resume! p)
    (show "  resumed, nothing fed: message complete? " (and (memq 'message-complete (map car seen)) #t))
    (let ((r2 (parser-feed! p d (parser-result-next r) (bytevector-length d))))
      (show "  one empty feed at next: " (result r2) "  delivered: " (reverse seen)))))
(set! seen '())
(let* ((p (recorder))
       (d1 (b "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n01234"))
       (d2 (b "56789GET /b HTTP/1.1\r\nHost: y\r\n\r\n")))
  (show "(1c) the mutation: after the pause, feed from where the delivery started")
  (let ((r (parser-feed! p d1 0 (bytevector-length d1))))
    (show "  delivery 1: " (result r))
    (parser-resume! p)
    (let ((r2 (parser-feed! p d1 0 (bytevector-length d1))))
      (show "  delivery 1 again from 0: " (result r2))))
  (show "  delivered: " (reverse seen)))

;;; --- PART 2 ------------------------------------------------------------------

;; core-connection : Bytevector -> (-> Void)
;; tests/test-connection-allocation.sps's keep-alive connection: the real
;; parser, adapter and core, serving `request` once per call.
(define (core-connection request)
  (let* ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (keep! actions))))
         (p (make-conn-parser ctx))
         (len (bytevector-length request))
         (ok (make-response 200 #f '() #f)))
    (lambda ()
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                      (parser-result-next r) #f #f))
        (let ((w (assq 'write (conn-context-step! ctx (list 'handler-responded ok)))))
          (conn-context-step! ctx (list 'write-completed (caddr w))))
        (parser-resume! p)))))

(show "")
(show "=== PART 2: reading")
(show "the JSON POST through the real parser, adapter and core, today: "
      (bytes-per-run (core-connection (car json-post)) 1000 10000) " B, against the 3,072 B gate")
(show "bytes a way adds per request to the model's cycle today (the body dropped):")
(define (measure deliveries warm n)
  (let ((today (bytes-per-run (run (connection 'today) deliveries) warm n)))
    (cons today
          (map (lambda (way) (cons way (- (bytes-per-run (run (connection way) deliveries) warm n) today)))
               '(A Am A+ B C)))))
(for-each
 (lambda (row)
   (let ((m (measure (cadr row) (caddr row) (cadddr row))))
     (show (car row) " today's cycle " (car m) " B;  adds: "
           (map (lambda (x) (list (car x) (cdr x))) (cdr m)))))
 (list (list "the JSON POST, 13-byte body, fed whole       " json-post 100 10000)
       (list "a MiB, Content-Length, 64 deliveries of 16 KiB" mib-length 100 1000)
       (list "a MiB, chunked 16 KiB, 64 deliveries          " mib-chunked 100 1000)))

;; collect-all : -> Void — every generation, so the live heap is what is live.
(define (collect-all) (collect (collect-maximum-generation)))

;; held : Symbol (Listof Bytevector) -> Nat
;; What a connection holds once a body's last piece is taken, before the
;; response: the request run with its message's end held back, then the
;; live heap after a collection of every generation, less the same once the
;; connection is dropped.  The connection is reached only through `cell`, so
;; dropping it there drops it; the deliveries are the workload's, live
;; throughout, and not counted.
(define cell (vector #f))
(define (held way deliveries)
  (vector-set! cell 0 (connection way))
  ((run (vector-ref cell 0) deliveries))       ; one request through first
  (conn-hold-end?-set! (vector-ref cell 0) #t)
  (for-each (lambda (bv) (feed! (vector-ref cell 0) bv 0 (bytevector-length bv))) deliveries)
  (keep! #f)
  (collect-all)
  (let ((with (bytes-allocated)))
    (vector-set! cell 0 #f)
    (collect-all)
    (- with (bytes-allocated))))

(held 'today mib-length)                      ; warm: the first full collection frees what came before
(show "")
(show "what a connection holds once a MiB body's last piece is taken, before its response")
(show "(the connection, its parser and what the way keeps; the deliveries not counted):")
(for-each
 (lambda (way)
   (let* ((by-length (held way mib-length))
          (by-chunks (held way mib-chunked)))
     (show "  " way "  Content-Length " by-length " B,  chunked " by-chunks " B")))
 '(today A Am A+ B C))

;;; --- PART 3 ------------------------------------------------------------------

(show "")
(show "=== PART 3: writing a body of unknown length, bytes per 16 KiB piece, protocol only")
(define piece (make-bytevector (* 16 KiB) 98))
(define pieces-per-response 64)

;; (i) the thunk
(define (thunk-response)
  (let ((left pieces-per-response))
    (lambda () (if (zero? left) (eof-object) (begin (set! left (- left 1)) piece)))))
(define (drain-thunk producer)
  (let loop ((n 0))
    (let ((x (producer)))
      (if (eof-object? x) n (begin (keep! (list 'handler-body-chunk x 0 (bytevector-length x))) (loop (+ n 1)))))))

;; (ii) the port, read into the server's own buffer
(define server-buffer (make-bytevector (* 16 KiB)))
(define (port-response)
  (let ((left (* pieces-per-response 16 KiB)))
    (make-custom-binary-input-port "body"
      (lambda (bv start count)
        (let ((n (min count left)))
          (bytevector-copy! piece 0 bv start (min n (bytevector-length piece)))
          (set! left (- left n))
          n))
      #f #f #f)))
(define (drain-port port)
  (let loop ((n 0))
    (let ((k (get-bytevector-n! port server-buffer 0 (bytevector-length server-buffer))))
      (if (eof-object? k) n
          (begin (keep! (list 'handler-body-chunk server-buffer 0 k)) (loop (+ n 1)))))))

;; (iii) emit and done, the producer called until it says done
(define (emit-response)
  (let ((left pieces-per-response))
    (lambda (emit done) (if (zero? left) (done) (begin (set! left (- left 1)) (emit piece))))))
(define (drain-emit producer)
  (let ((finished #f) (n 0))
    (let loop ()
      (producer (lambda (bv) (set! n (+ n 1)) (keep! (list 'handler-body-chunk bv 0 (bytevector-length bv))))
                (lambda () (set! finished #t)))
      (if finished n (loop)))))

(define (per-piece make drain)
  (let ((total (bytes-per-run (lambda () (drain (make))) 100 1000)))
    (list total (div total pieces-per-response))))
(show "  (i)   thunk, bytevector or eof:    per response, per piece " (per-piece thunk-response drain-thunk))
(show "  (ii)  binary input port, read in:  per response, per piece " (per-piece port-response drain-port))
(show "  (iii) emit and done:               per response, per piece " (per-piece emit-response drain-emit))
