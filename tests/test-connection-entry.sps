#!r6rs
;;; (http-server connection): the parser entry points.  M2.2, first step.
;;;
;;; Decision 0002's third amendment has parser callbacks enter the core
;;; directly, with their own arguments, so no event is allocated to carry
;;; them.  This suite holds the amendment's rules as checks:
;;;
;;;   - the callback names are a closed set, chez-httparse's twenty-five, and
;;;     a name outside it or given the wrong shape is an assertion violation
;;;     (item 5);
;;;   - every callback is answered: the first action is its reply-parser, in
;;;     every state (item 2);
;;;   - both ways in agree: a callback as a tagged list through conn-step and
;;;     the same callback through the entry point leave the same state and ask
;;;     for the same actions (item 3);
;;;   - a callback whose data the core does not keep allocates nothing, and
;;;     one whose data it keeps allocates the same whatever the span's length
;;;     (item 4; the second amendment's shape checks).
;;;
;;; Oracles: chez-httparse's own table of its callbacks and their kinds
;;; (`adapter-trace-names`, from its test harness), and its parser, which
;;; refuses a binding list with a hole or an extra name; the callbacks that
;;; parser fires on three inputs; the amendment's "allocates nothing"; Chez's
;;; cumulative allocation counter, calibrated below.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) statistics sstats-bytes)
        (http-server connection) (http-server response) (http-server request)
        (http-server span) (http-server limits) (http-server body)
        (only (httparse decisions) F-CONTENT-LENGTH)
        (httparse test adapter)          ; adapter-trace-names
        (generated httparse-message) (httparse modes) (byte-machine runtime))

(define (b s) (string->utf8 s))

;; --- the oracle ------------------------------------------------------------

;; chez-httparse's rows are (callback-name kind trace-name); a span row's kind
;; is 'span, and on-headers-complete's is 'state-line.
(define oracle-names (map car adapter-trace-names))
(define (oracle-kind name) (cadr (assq name adapter-trace-names)))
(define oracle-spans (filter (lambda (n) (eq? (oracle-kind n) 'span)) oracle-names))

(define request-inits (list (cons 'type (httparse-message-type-value 'request))))

;; silent-bindings : -> Bindings — one binding per name the core declares,
;; with the arity the oracle gives its kind.
(define (silent-bindings)
  (map (lambda (name)
         (list name (if (eq? (oracle-kind name) 'span)
                        (lambda (p ctx bv from to) callback-continue)
                        (lambda (p ctx) callback-continue))))
       conn-parser-callbacks))

;; --- states and the two ways in ----------------------------------------------

;; The deadline each reading state has armed when a callback arrives in it.
(define (armed phase)
  (case phase ((idle) 'idle) ((head) 'header) ((body) 'body) (else #f)))

(define (fresh phase) (make-conn-state phase (armed phase) #f 0 0 #f #f default-limits))

;; A reader that drops what it is handed and answers `resp` (defined below).
(define reader (read-body (lambda (bv from to) #t) (lambda () (make-response 200 #f '() #f))))

;; reading-state : -> ConnState
;; A POST whose head announced a body of 1,000 bytes, its handler asked and
;; answered with a streaming reader, reached by steps: in body, reading.
(define (reading-state)
  (let ((s (fresh 'head)) (target (string->utf8 "/")))
    (conn-parser-step s 'on-url-data target 0 1)
    (conn-parser-step s 'on-url-complete)
    (let ((host (string->utf8 "Host: x")))
      (conn-parser-step s 'on-header-field-data host 0 4)
      (conn-parser-step s 'on-header-field-complete)
      (conn-parser-step s 'on-header-value-data host 6 7)
      (conn-parser-step s 'on-header-value-complete))
    (conn-headers-complete-step s 3 1 1 F-CONTENT-LENGTH 1000 0)
    (conn-step s '(parser-result need-input 0 0 #f #f))
    (conn-step s (list 'handler-responded reader))
    (unless (eq? (conn-body-reader s) reader)
      (assertion-violation 'reading-state "the steps did not reach a reader reading" (conn-phase s)))
    s))

;; A span for the span callbacks, and on-headers-complete's six fields for a
;; keep-alive GET: llhttp's method 1, HTTP/1.1, no flags, no content-length,
;; and a parser `upgrade` of 0.
(define span-bv (make-bytevector 1000 (char->integer #\x)))
(define head-fields '(1 1 1 0 0 0))

;; payload : Symbol Nat -> (Listof Any)
;; The parser-event payload for `name`, with a span `len` bytes long.
(define (payload name len)
  (cond ((eq? name 'on-headers-complete) (cons name head-fields))
        ((eq? (oracle-kind name) 'span) (list name span-bv 0 len))
        (else (list name))))

;; direct : ConnState (Listof Any) -> (values ConnState (Listof Action))
;; The adapter's way in: the payload's own fields as arguments.
(define (direct s p)
  (let ((name (car p)))
    (cond ((eq? name 'on-headers-complete) (apply conn-headers-complete-step s (cdr p)))
          ((null? (cdr p)) (conn-parser-step s name))
          (else (apply conn-parser-step s name (cdr p))))))

;; tagged : ConnState (Listof Any) -> (values ConnState (Listof Action))
;; The table's way in: one tagged list through conn-step.
(define (tagged s p) (conn-step s (cons 'parser-event p)))

;; render-request : (U Request #f) -> Datum
;; A request as its bytes: each way in builds its own record, and records
;; compare by identity.
(define (render-request r)
  (and r (list 'request (request-method r) (span->bytevector (request-target r))
               (request-http-major r) (request-http-minor r)
               (map (lambda (h) (cons (span->bytevector (car h)) (span->bytevector (cdr h))))
                    (request-headers r)))))

(define (render-action a)
  (if (and (eq? (car a) 'call-handler) (request? (cadr a)))
      (list 'call-handler (render-request (cadr a)))
      a))

;; snapshot : ConnState (Listof Action) -> Datum — everything a step decides.
(define (snapshot s actions)
  (list (conn-phase s) (conn-deadline s) (conn-close-after s) (conn-outstanding s)
        (conn-pending s) (render-request (conn-request s)) (map render-action actions)))

(define (step way s p) (call-with-values (lambda () (way s p)) snapshot))

;; verdict : (-> Any) -> (U 'accepted 'refused)
(define (verdict thunk)
  (guard (e ((assertion-violation? e) 'refused))
    (call-with-values thunk (lambda results 'accepted))))

;; --- the callbacks a real parse fires --------------------------------------

;; record-callbacks : Bytevector -> (Listof Payload)
;; What chez-httparse fires parsing `input` whole, each as the payload the
;; adapter passes: (name), (name bv from to), or on-headers-complete with the
;; six fields read inside it.
(define (record-callbacks input)
  (let* ((acc '())
         (push! (lambda (x) (set! acc (cons x acc))))
         (bindings
          (map (lambda (row)
                 (let ((name (car row)))
                   (list name
                         (case (cadr row)
                           ((span) (lambda (p ctx bv from to)
                                     (push! (list name bv from to)) callback-continue))
                           ((state-line)
                            (lambda (p ctx)
                              (push! (cons name (map (lambda (f) (parser-field-ref p f))
                                                     '(method http-major http-minor
                                                       flags content-length upgrade))))
                              callback-continue))
                           (else (lambda (p ctx) (push! (list name)) callback-continue))))))
               adapter-trace-names))
         (p (make-parser httparse-message-machine bindings #f request-inits))
         (r (parser-feed! p input 0 (bytevector-length input))))
    (unless (eq? (parser-result-status r) 'need-input)
      (assertion-violation 'record-callbacks "the input did not parse" (parser-result-status r)))
    (reverse acc)))

(define (bytevector-append x y)
  (let ((z (make-bytevector (+ (bytevector-length x) (bytevector-length y)))))
    (bytevector-copy! x 0 z 0 (bytevector-length x))
    (bytevector-copy! y 0 z (bytevector-length x) (bytevector-length y))
    z))

(define get-a (b "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
(define inputs
  (list (cons "two pipelined keep-alive GETs" (bytevector-append get-a get-a))
        (cons "a POST with a Content-Length body"
              (b "POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
        (cons "a chunked POST with a chunk extension"
              (b "POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5;e=v\r\nhello\r\n0\r\n\r\n"))))

(define resp (make-response 200 #f '() (b "ok")))

;; reply? : Action -> Boolean
;; A reply-parser with one of its three outcomes: continue, pause, or a
;; refusal naming its reason.  A fresh head has no target, which the core
;; refuses at on-headers-complete (M2.3), so that reply is a `fail`.
(define (reply? a)
  (or (and (member a '((reply-parser continue) (reply-parser pause))) #t)
      (and (pair? a) (eq? (car a) 'reply-parser) (pair? (cdr a))
           (let ((outcome (cadr a)))
             (and (pair? outcome) (eq? (car outcome) 'fail)
                  (pair? (cdr outcome)) (symbol? (cadr outcome)))))))

;; replay : (ConnState Payload -> (values ...)) (Listof Payload) -> (Listof Datum)
;; Drive one connection through the recorded callbacks, entering them `way`,
;; with the shell's part wherever the core paused the parser: the feed's
;; result; the handler, if it was asked, answering with a reader; and, once
;; the reader is handed its end, the reader's response and its write's
;; completion, so the next message starts from idle.  A request whose head
;; announces a body is asked with the feed's result (decision 0013), and a
;; response given in place of a reader would close the connection, so every
;; request is answered with one.  The shell's own events go through
;; conn-step either way.
(define (replay way callbacks)
  (let loop ((s (fresh 'idle)) (cs callbacks) (acc '()))
    (if (null? cs)
        (reverse acc)
        (call-with-values
         (lambda () (way s (car cs)))
         (lambda (s actions)
           (let ((acc (cons (snapshot s actions) acc)))
             (if (equal? (car actions) '(reply-parser pause))
                 (let*-values (((s a0) (conn-step s '(parser-result paused 0 0 #f #f)))
                               ((s a1) (if (or (assq 'call-handler actions) (assq 'call-handler a0))
                                           (conn-step s (list 'handler-responded reader))
                                           (values s '()))))
                   (let ((acc (cons (snapshot s a1) (cons (snapshot s a0) acc))))
                     (if (or (assq 'deliver-body-end actions) (assq 'deliver-body-end a1))
                         (let*-values (((s a2) (conn-step s (list 'handler-responded resp)))
                                       ((s a3) (conn-step s (list 'write-completed
                                                                  (caddr (assq 'write a2))))))
                           (loop s (cdr cs) (cons (snapshot s a3) (cons (snapshot s a2) acc))))
                         (loop s (cdr cs) acc))))
                 (loop s (cdr cs) acc))))))))

;; --- allocation --------------------------------------------------------------

(define reps 10000)

;; entry : Symbol Nat -> (ConnState -> (values ConnState (Listof Action)))
;; One callback entered exactly as the adapter enters it, with its arguments
;; written out.  `direct` spreads a payload with `apply`, which allocates for
;; on-headers-complete's seven arguments; the adapter never does.
(define (entry name len)
  (cond ((eq? name 'on-headers-complete)
         (lambda (s) (conn-headers-complete-step s 1 1 1 0 0 0)))
        ((eq? (oracle-kind name) 'span)
         (lambda (s) (conn-parser-step s name span-bv 0 len)))
        (else (lambda (s) (conn-parser-step s name)))))

;; enter-all! : (Vectorof ConnState) (ConnState -> (values ...)) -> Void
;; Enter one callback on each state.
(define (enter-all! states enter)
  (let ((n (vector-length states)))
    (let loop ((i 0))
      (when (< i n)
        (let-values (((s actions) (enter (vector-ref states i))))
          (loop (+ i 1)))))))

;; fresh-states : Symbol Nat -> (Vectorof ConnState)
;; `n` states in `phase`, or reading a body, reached by steps, for 'reading.
(define (fresh-states phase n)
  (let ((v (make-vector n)))
    (let loop ((i 0))
      (when (< i n)
        (vector-set! v i (if (eq? phase 'reading) (reading-state) (fresh phase)))
        (loop (+ i 1))))
    v))

;; bytes-per-call : Symbol Symbol Nat -> Nat
;; Bytes one call of the entry point allocates, for `name` arriving in `phase`,
;; averaged over `reps` calls.  The states and the entry are built before the
;; counted region, so only the calls are inside it; a warm-up runs first.
(define (bytes-per-call phase name len)
  (let ((enter (entry name len))
        (warm (fresh-states phase 100))
        (states (fresh-states phase reps)))
    (enter-all! warm enter)
    (let ((before (sstats-bytes (statistics))))
      (enter-all! states enter)
      (div (- (sstats-bytes (statistics)) before) reps))))

;; Where each callback arrives while a request is parsed: one row per callback,
;; in the oracle's order.  The two status callbacks never fire for a request
;; parser; they are entered in head, where the request line is.
(define arrivals
  '((idle on-reset) (idle on-message-begin)
    (head on-method-data) (head on-method-complete)
    (head on-url-data) (head on-url-complete)
    (head on-protocol-data) (head on-protocol-complete)
    (head on-version-data) (head on-version-complete)
    (head on-status-data) (head on-status-complete)
    (head on-header-field-data) (head on-header-field-complete)
    (head on-header-value-data) (head on-header-value-complete)
    (head on-headers-complete) (body on-body-data) (body on-chunk-header)
    (body on-chunk-extension-name-data) (body on-chunk-extension-name-complete)
    (body on-chunk-extension-value-data) (body on-chunk-extension-value-complete)
    (body on-chunk-complete) (body on-message-complete)))

;; The callbacks whose data the core keeps, and so may allocate: the target
;; and each header name and value are kept as spans, a completed value joins
;; its name as a header, the head's completion builds the request, a body span
;; goes on to the reader the handler answered with (decision 0013), and the
;; message's completion carries the request.
(define kept
  '(on-url-data on-header-field-data on-header-value-data on-header-value-complete
    on-headers-complete on-body-data on-message-complete))

;; The span callbacks among them, and the state each arrives in: a body span
;; while a reader reads the body.
(define kept-spans
  '((head on-url-data) (head on-header-field-data) (head on-header-value-data)
    (reading on-body-data)))

(run-suite "connection-entry"
  (lambda ()
    ;; --- the closed set ----------------------------------------------------
    (test-equal "the twenty-five callbacks, in chez-httparse's order"
                oracle-names conn-parser-callbacks)
    (test-equal "the ten span callbacks, as chez-httparse's table has them"
                oracle-spans conn-span-callbacks)
    (test-eq "chez-httparse's parser takes exactly these names as its bindings" 'made
             (guard (e (#t 'refused))
               (make-parser httparse-message-machine (silent-bindings) #f request-inits)
               'made))

    (test-eq "an unknown callback is an assertion violation" 'refused
             (verdict (lambda () (conn-parser-step (fresh 'head) 'on-no-such-thing))))
    (test-eq "an unknown callback with a span is an assertion violation" 'refused
             (verdict (lambda () (conn-parser-step (fresh 'head) 'on-no-such-data span-bv 0 1))))
    (test-equal "a span callback without its span is refused, all ten" '()
                (filter (lambda (n)
                          (eq? 'accepted (verdict (lambda () (conn-parser-step (fresh 'head) n)))))
                        oracle-spans))
    (test-equal "an event callback given a span is refused, all fifteen" '()
                (filter (lambda (n)
                          (and (not (eq? (oracle-kind n) 'span))
                               (eq? 'accepted
                                    (verdict (lambda () (conn-parser-step (fresh 'head) n span-bv 0 1))))))
                        oracle-names))
    (test-eq "on-headers-complete does not enter as an event callback" 'refused
             (verdict (lambda () (conn-parser-step (fresh 'head) 'on-headers-complete))))
    (test-eq "an unknown callback as a tagged list is an assertion violation" 'refused
             (verdict (lambda () (conn-step (fresh 'head) '(parser-event on-no-such-thing)))))
    (test-eq "on-headers-complete as a tagged list needs its six fields" 'refused
             (verdict (lambda () (conn-step (fresh 'head) '(parser-event on-headers-complete)))))
    ;; The sixth is the parser's `upgrade` (chez-httparse v0.4.1, #47): a payload
    ;; without it is the shape before the core read it, and is refused.
    (test-eq "on-headers-complete without the parser's upgrade field is refused" 'refused
             (verdict (lambda () (conn-step (fresh 'head) '(parser-event on-headers-complete 1 1 1 0 0)))))

    ;; --- every callback is answered, in every state --------------------------
    (test-equal "the first action is the reply, for every callback in every state" '()
                (fold-right
                 (lambda (phase acc)
                   (fold-right
                    (lambda (name acc)
                      (let ((actions (call-with-values
                                      (lambda () (direct (fresh phase) (payload name 4)))
                                      (lambda (s actions) actions))))
                        (if (and (pair? actions) (reply? (car actions)))
                            acc
                            (cons (list phase name) acc))))
                    acc conn-parser-callbacks))
                 '() conn-states))

    ;; --- both ways in agree ----------------------------------------------------
    (test-equal "one step, both ways: every callback in every state" '()
                (fold-right
                 (lambda (phase acc)
                   (fold-right
                    (lambda (name acc)
                      (let ((p (payload name 4)))
                        (if (equal? (step tagged (fresh phase) p) (step direct (fresh phase) p))
                            acc
                            (cons (list phase name) acc))))
                    acc conn-parser-callbacks))
                 '() conn-states))
    (for-each
     (lambda (input)
       (let* ((callbacks (record-callbacks (cdr input)))
              ;; A refusal mid-replay fails this check rather than the suite.
              (runs (guard (e ((assertion-violation? e) #f))
                      (cons (replay tagged callbacks) (replay direct callbacks)))))
         (test-eq (string-append "both replays run to the end: " (car input))
                  'ran (if runs 'ran 'refused))
         (when runs
           (let ((by-list (car runs)))
             (test-equal (string-append "a whole parse, both ways: " (car input))
                         by-list (cdr runs))
             ;; Not vacuous: every message reached the handler, and the
             ;; connection is idle again after its cycle.
             (test-eqv (string-append "every message reached call-handler: " (car input))
                       (length (filter (lambda (p) (eq? (car p) 'on-message-complete)) callbacks))
                       (length (filter (lambda (snap) (assq 'call-handler (list-ref snap 6)))
                                       by-list)))
             (test-eq (string-append "the connection ends idle: " (car input))
                      'idle (car (list-ref by-list (- (length by-list) 1))))))))
     inputs)

    ;; --- allocation ----------------------------------------------------------
    ;; Calibration: an instrument that always read zero would pass everything
    ;; below.  The counter sees an allocation, and a loop that allocates
    ;; nothing reads zero per iteration.
    (let* ((before (sstats-bytes (statistics)))
           (junk (make-bytevector 100000 0))
           (after (sstats-bytes (statistics))))
      (test-eq "the counter sees a 100000-byte bytevector" 'seen
               (if (and (>= (- after before) 100000) (= (bytevector-length junk) 100000))
                   'seen
                   'missed)))
    (let ((before (sstats-bytes (statistics))))
      (let loop ((i 0)) (when (< i reps) (loop (+ i 1))))
      (test-eqv "an empty loop allocates nothing per iteration"
                0 (div (- (sstats-bytes (statistics)) before) reps)))

    (test-equal "one arrival row per callback, in the oracle's order"
                oracle-names (map cadr arrivals))
    (test-equal "a callback whose data the core does not keep allocates nothing" '()
                (filter (lambda (row)
                          (and (not (memq (cadr row) kept))
                               (> (bytes-per-call (car row) (cadr row) 4) 0)))
                        arrivals))
    ;; A span the core keeps costs something, and the same whatever its
    ;; length: it is kept as bounds, never copied.
    (test-equal "a kept span costs something, the same for 1 byte as for 1,000" '()
                (filter (lambda (row)
                          (let ((short (bytes-per-call (car row) (cadr row) 1))
                                (long (bytes-per-call (car row) (cadr row) 1000)))
                            (not (and (> short 0) (= short long)))))
                        kept-spans))))
