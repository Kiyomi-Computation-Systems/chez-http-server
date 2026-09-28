#!r6rs
;;; (http-server connection): the connection keeps no response bytes once
;;; the write is issued.  M3.3.
;;;
;;; chez-libuv copies a write's segments into request-owned foreign memory at
;;; the call (design §7.3; vendor/chez-libuv/src/libuv/stream.sls:88-128), so
;;; once the write is issued nothing needs the response's bytes.  The core
;;; must not keep them until the write completes, as a queue holding its
;;; buffers for libuv would: a handler's body can be large, and the client
;;; decides how long its write takes to complete.
;;;
;;; No wire test can see the difference, since the bytes written are the
;;; same either way, so the check is on liveness.  A connection as the shell
;;; holds one (the core's state in the adapter's context, and its parser)
;;; serves a request.  The write it asks for is performed as uv-write*!
;;; performs it: the bytes are copied out, by the fake shell's write-wire,
;;; and the action is dropped.  Then,
;;; with the write still outstanding, a full collection must release the
;;; response, its body, the write's segment list and its header block.  A
;;; weak pair sees it: its car is broken once nothing else holds the object.
;;;
;;; M3.5: a connection that closes after its response lingers, for up to
;;; 30 s, reading only to drop what arrives (decision 0011).  So it keeps
;;; nothing of the input it read: not the delivery, whose rest a pause keeps
;;; for the next message, and not the request, whose spans point into it.
;;; The same instrument checks that while it lingers.
;;;
;;; M6.1: a body read whole is copied into one bytevector, which the core
;;; hands to the reader the handler answered with (decision 0013).  Once the
;;; reader's response is written, the connection keeps neither the reader
;;; nor that body: a handler's body can be up to its cap, 1 MiB.
;;;
;;; Oracles: design §7.3; decision 0011; and the instrument's calibration
;;; below: an object still held is seen held, and a dropped one released.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object?)
        (http-server connection) (http-server private adapter)
        (http-server response) (http-server limits) (http-server body)
        (only (fake-shell) write-wire)
        (byte-machine runtime))

(define (b s) (string->utf8 s))

(define request (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))

;; weakly : Symbol Any -> (Pair Symbol WeakPair) — a named weak pointer.
(define (weakly name x) (cons name (weak-cons x '())))

;; after-collection : (Listof (Pair Symbol WeakPair)) -> (Listof (Pair Symbol Symbol))
;; Collect every generation, then say of each object whether anything still
;; holds it.
(define (after-collection weak)
  (collect (collect-maximum-generation))
  (map (lambda (w) (cons (car w) (if (bwp-object? (cadr w)) 'released 'held))) weak))

;; open-connection : -> (values ConnContext Parser)
;; A keep-alive connection in idle, as the shell holds one.  The actions its
;; parser callbacks queue are dropped: this driver steps the handler's cycle
;; itself.
(define (open-connection)
  (let ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                (lambda (actions) (values)))))
    (values ctx (make-conn-parser ctx))))

;; issue! : ConnContext Parser (-> Response)
;;   -> (values (U Nat #f) (U (Listof (Pair Symbol WeakPair)) Symbol))
;; Serve one request as far as its write: the request fed, and paused at its
;; end; the handler's answer, which `answer` makes here and nothing else
;; holds, stepped; and the write performed.  Returns the write's byte count,
;; and a weak pointer to each thing the connection must not keep: the
;; handler's response and its body, and the write's segment list and header
;; block.  (A registered status's line is the serializer's own, made once,
;; and the Date slot is a symbol, so neither is the response's.)  A core
;; that did not pause or asked for no write returns #f and 'not-paused or
;; 'no-write instead, so the checks fail rather than the suite ending.
(define (issue! ctx p answer)
  (let* ((len (bytevector-length request))
         (r (begin (conn-context-step! ctx (list 'bytes-arrived request 0 len))
                   (parser-feed! p request 0 len))))
    (conn-context-step! ctx (list 'parser-result (parser-result-status r)
                                  (parser-result-consumed r) (parser-result-next r) #f #f))
    (if (not (eq? (parser-result-status r) 'paused))
        (values #f 'not-paused)
        (let* ((response (answer))
               (w (assq 'write (conn-context-step! ctx (list 'handler-responded response)))))
          (if (not w)
              (values #f 'no-write)
              (let ((segments (cadr w)))
                (write-wire segments (caddr w) 0)
                (values (caddr w)
                        (list (weakly 'response response)
                              (weakly 'body (response-body response))
                              (weakly 'segments segments)
                              (weakly 'header-block (header-block segments))))))))))

;; header-block : (Listof Segment) -> (U Bytevector #f)
;; A write's header block: its first bytevector after the status line, past
;; the Date slot when it has one.
(define (header-block segments) (find bytevector? (cdr segments)))

;; close-after-pipelined! : ConnContext Parser
;;   -> (U (Listof (Pair Symbol WeakPair)) Symbol)
;; Serve a request that asks to close, with another pipelined behind it in
;; the same delivery, until its write completes, so the connection lingers.
;; The delivery is made here and nothing else holds it: the core keeps its
;; rest as the pause's pending input, and the request's spans point into it.
;; Returns a weak pointer to each, or 'no-write if the core asked for none.
(define (close-after-pipelined! ctx p)
  (let* ((delivery (b (string-append "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
                                     "GET /2 HTTP/1.1\r\nHost: x\r\n\r\n")))
         (len (bytevector-length delivery))
         (r (begin (conn-context-step! ctx (list 'bytes-arrived delivery 0 len))
                   (parser-feed! p delivery 0 len))))
    (conn-context-step! ctx (list 'parser-result (parser-result-status r)
                                  (parser-result-consumed r) (parser-result-next r) #f #f))
    (let* ((request (conn-request (conn-context-state ctx)))
           (w (assq 'write (conn-context-step! ctx (list 'handler-responded
                                                         (make-response 200 #f '() #f))))))
      (if (not w)
          'no-write
          (begin
            (conn-context-step! ctx (list 'write-completed (caddr w)))
            (list (weakly 'delivery delivery) (weakly 'request request)))))))

;; lingering : -> (List (U (Listof (Pair Symbol Symbol)) Symbol) Symbol)
;; What a full collection releases while that connection lingers, and the
;; phase it was collected in.  The parser is resumed after it, as in served,
;; so the whole connection lives through the collection.
(define (lingering)
  (let-values (((ctx p) (open-connection)))
    (let ((weak (close-after-pipelined! ctx p)))
      (let ((seen (if (symbol? weak) weak (after-collection weak))))
        (parser-resume! p)
        (list seen (conn-phase (conn-context-state ctx)))))))

;; served : (-> Response) -> (List (U (Listof (Pair Symbol Symbol)) Symbol) Datum Symbol)
;; One request on a fresh connection: what a full collection releases while
;; its write is outstanding; the state it was collected in, the phase and
;; the writes outstanding; and the phase the write's completion leaves.
;; The parser is resumed after it, as the shell resumes it, so the whole
;; connection lives through the collection.  When the connection asked for
;; no write, what went wrong, the phase it stopped in, and #f; a completion
;; the core refuses leaves 'refused.  Either way the checks fail, rather
;; than the suite ending.
(define (served answer)
  (let-values (((ctx p) (open-connection)))
    (let-values (((nbytes weak) (issue! ctx p answer)))
      (if (not nbytes)
          (list weak (conn-phase (conn-context-state ctx)) #f)
          (let* ((seen (after-collection weak))
                 (during (list (conn-phase (conn-context-state ctx))
                               (conn-outstanding (conn-context-state ctx)))))
            (let ((after (guard (e ((assertion-violation? e) 'refused))
                           (conn-context-step! ctx (list 'write-completed nbytes))
                           (conn-phase (conn-context-state ctx)))))
              (parser-resume! p)
              (list seen during after)))))))

;; read-whole! : -> (List (U (Listof (Pair Symbol Symbol)) Symbol) Datum)
;; A POST with a 4,096-byte body on a fresh connection, read by a whole
;; reader made here, whose procedure answers with a response of its own:
;; what a full collection releases once the reader's response is written,
;; while its write is outstanding, and the phase and writes outstanding then.
;; A core that asks for no handler, hands over no body or asks for no write
;; answers what went wrong instead, so the checks fail rather than the suite
;; ending.
(define (read-whole!)
  (let-values (((ctx p) (open-connection)))
    (let* ((post (b (string-append "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4096\r\n\r\n"
                                   (make-string 4096 #\a))))
           (len (bytevector-length post))
           (r (begin (conn-context-step! ctx (list 'bytes-arrived post 0 len))
                     (parser-feed! p post 0 len)))
           (asked (conn-context-step! ctx (list 'parser-result (parser-result-status r)
                                                (parser-result-consumed r) (parser-result-next r) #f #f))))
      (if (not (assq 'call-handler asked))
          (list 'not-asked #f)
          (let* ((reader (read-whole-body (lambda (body) (make-response 200 #f '() #f))))
                 (handed (conn-context-step! ctx (list 'handler-responded reader)))
                 (piece (assq 'deliver-body handed)))
            (if (not piece)
                (list 'no-body #f)
                (let ((body (cadr piece)))
                  ((body-reader-on-piece reader) body (caddr piece) (cadddr piece))
                  (let ((w (assq 'write (conn-context-step!
                                         ctx (list 'handler-responded ((body-reader-on-end reader)))))))
                    (if (not w)
                        (list 'no-write #f)
                        (begin
                          (write-wire (cadr w) (caddr w) 0)
                          (let ((seen (after-collection (list (weakly 'reader reader) (weakly 'body body)))))
                            (parser-resume! p)
                            (list seen (list (conn-phase (conn-context-state ctx))
                                             (conn-outstanding (conn-context-state ctx)))))))))))))))

(define released
  '((response . released) (body . released) (segments . released) (header-block . released)))

(run-suite "connection-retention"
  (lambda ()
    ;; Calibration: an instrument that always said released would pass.  The
    ;; held bytevector is read after the collection, so it is live through it.
    (let* ((held (make-bytevector 4096 1))
           (seen (after-collection (list (weakly 'held held)
                                         (weakly 'dropped (make-bytevector 4096 2))))))
      (test-equal "the instrument sees a held object held, and a dropped one released"
                  '((held . held) (dropped . released)) seen)
      (test-eqv "the held object lived through the collection" 4096 (bytevector-length held)))

    (let ((r (served (lambda ()
                       (make-response 200 #f (list (cons (b "X-Kind") (b "retention")))
                                      (make-bytevector 4096 97))))))
      (test-equal "a handler's response: the connection holds none of it while its write is outstanding"
                  released (car r))
      (test-equal "a handler's response: collected in responding, its one write outstanding"
                  '(responding 1) (cadr r))
      (test-eq "a handler's response: the completion returns the connection to idle"
               'idle (caddr r)))

    ;; A response with a fault is answered 500 (decision 0010 item 2): the
    ;; handler's response and body are never written, and the 500's write is
    ;; the one outstanding.
    (let ((r (served (lambda ()
                       (make-response 200 #f (list (cons (b "Content-Length") (b "4096")))
                                      (make-bytevector 4096 97))))))
      (test-equal "a response with a fault, answered 500: the connection holds none of either"
                  released (car r))
      (test-equal "a response with a fault: collected in responding, the 500's write outstanding"
                  '(responding 1) (cadr r))
      (test-eq "a response with a fault: the completion starts the staged close"
               'lingering (caddr r)))

    ;; M6.1: a body read whole, once its reader's response is written.
    (let ((r (read-whole!)))
      (test-equal "a body read whole: once the reader's response is written, the connection holds neither the reader nor the body"
                  '((reader . released) (body . released)) (car r))
      (test-equal "a body read whole: collected in responding, the response's write outstanding"
                  '(responding 1) (cadr r)))

    ;; M3.5: a lingering connection reads only to drop what arrives, so it
    ;; keeps nothing of the input it read (decision 0011).
    (let ((r (lingering)))
      (test-equal "a lingering connection holds none of its input: the delivery and the request"
                  '((delivery . released) (request . released)) (car r))
      (test-eq "and it was collected lingering" 'lingering (cadr r)))))
