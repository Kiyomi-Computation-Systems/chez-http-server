#!r6rs
;;; (outcome-lane) — the llhttp request corpus through the fake shell's message
;;; loop: design §8.1's property 2.  M2.4.
;;;
;;; Every request fixture is fed to one fake connection as `bytes-arrived`
;;; deliveries at every scheduled chunk size, and what the connection did must
;;; be what it did with the whole input in one delivery:
;;;
;;;   - the handlers called, with the requests they were given;
;;;   - the responses written, by status;
;;;   - the close and its reason, and the state the connection ended in.
;;;
;;; The client closes once its input is sent: a connection still reading
;;; then gets its eof, as the libhtp lane's streams end.  One kept alive
;;; closes for `eof`; one that lingers after a response that closes it
;;; (decision 0011) closes for the response's reason.
;;;
;;; That is §8.1's call-handler sequence, keep-alive decision and close
;;; reason: the keep-alive decision shows as whether a close follows a
;;; response.  Every action must also have run from the outermost drain (the
;;; shell's run-to-completion check).  A run that raises is a mismatch, never
;;; an outcome.
;;;
;;; The corpus is parser truth, not server truth (§8.1), so no fixture says
;;; what the outcome should be.  The lane checks that the pause protocol makes
;;; it independent of how the bytes were split.  It runs under the trace
;;; lane's `corpus-limits`, with no Host required, for the same reason.
;;;
;;; The connection parses with the server's own parser, and the lane reads no
;;; log, so the flags a fixture's log was recorded under never enter it: since
;;; decision 0019 it runs all 167, the 32 the trace lane defers among them.
;;;
;;; Two handlers (M6.1, decision 0013): `reads`, which reads every body,
;;; dropping it, then answers 200, as every handler answered before M6; and
;;; `answers`, which answers 200 at once, reading no body, so a request whose
;;; head announces one is answered and the connection closes after it.  What
;;; the feed that completed a head met of the body before the handler
;;; answered, an error among it, waits for the answer, so both are
;;; independent of the split too.
(library (outcome-lane)
  (export outcome-at outcome-mismatch render-request attempt reads answers)
  (import (rnrs)
          (httparse test corpus-load)      ; fixture-input-text, fixture-meta-ref
          (httparse test corpus-decode)    ; corpus-decode-input
          (httparse test conformance)      ; corpus-scan-sizes
          (http-server connection) (http-server request) (http-server response)
          (http-server span)
          (fake-shell)
          (only (trace-lane) corpus-limits))

  ;; What every handler answers.
  (define ok (make-response 200 #f '() #f))

  ;; reads : Request -> BodyReader — the body read and dropped, then `ok`.
  ;; answers : Request -> Response — `ok`, at once.
  (define reads (drops-body (lambda (request) ok)))
  (define (answers request) ok)

  ;; render-request : Request -> Datum — the request as its bytes.
  (define (render-request r)
    (list (request-method r) (utf8->string (span->bytevector (request-target r)))
          (request-http-major r) (request-http-minor r)
          (map (lambda (h) (cons (utf8->string (span->bytevector (car h)))
                                 (utf8->string (span->bytevector (cdr h)))))
               (request-headers r))))

  ;; decisive : (Listof Action) -> (Listof Datum)
  ;; The actions that make the outcome, rendered: the others (feeds, reads,
  ;; deadlines) follow the deliveries and differ by chunk size by design.  A
  ;; hand-off is rendered by the bytes it hands over, as text, or #f (M8.2).
  (define (decisive actions)
    (fold-right (lambda (a acc)
                  (case (car a)
                    ((call-handler) (cons (list 'call-handler (render-request (cadr a))) acc))
                    ((hand-off) (cons (list 'hand-off (retained-text (caddr a))) acc))
                    ((write) (cons (list 'write (written-status a)) acc))
                    ((close) (cons a acc))
                    (else acc)))
                '() actions))

  ;; retained-text : (U #f (List Bytevector Nat Nat)) -> (U #f String)
  ;; The bytes a hand-off hands over, as UTF-8 text, or #f for none.
  (define (retained-text r)
    (and r (let ((o (make-bytevector (- (caddr r) (cadr r)))))
             (bytevector-copy! (car r) (cadr r) o 0 (bytevector-length o))
             (utf8->string o))))

  ;; outcome-at : Bytevector Nat [(Request -> Any)] -> Datum
  ;; What one connection did reading `bv` in `size`-byte deliveries, with
  ;; `handler` (`reads` unless given), then the client's eof if it still
  ;; reads: the decisive actions in order, the phase and close-after it ended
  ;; with, and the actions run anywhere but the outermost drain.
  (define (outcome-at bv size . handler)
    (let ((sh (make-fake-connection corpus-limits (if (null? handler) reads (car handler)))))
      (fake-shell-feed-input! sh bv size)
      (when (fake-shell-reading? sh)
        (fake-shell-deliver! sh '(eof))
        (fake-shell-settle! sh))
      (let ((s (fake-shell-conn-state sh)))
        (list (decisive (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s)
              (fake-shell-violations sh)))))

  ;; outcome-mismatch : Fixture Symbol [(Request -> Any)] -> (U #f String)
  ;; #f when the outcome at every scheduled chunk size is the whole input's,
  ;; with every action run from the outermost drain, with `handler` (`reads`
  ;; unless given); else what differed first.
  (define (outcome-mismatch f selection . handler)
    (let* ((bv (corpus-decode-input (fixture-input-text f)))
           (len (bytevector-length bv))
           (no-scan (eq? #t (fixture-meta-ref f 'noScan #f)))
           (h (if (null? handler) reads (car handler)))
           (whole (attempt (lambda () (outcome-at bv (max 1 len) h)))))
      (cond
       ((string? whole) (string-append "the whole input " whole))
       ((pair? (cadddr whole)) (string-append "the whole input ran actions inside a feed or a nested drain"))
       (else
        (let loop ((sizes (corpus-scan-sizes len no-scan selection)))
          (if (null? sizes)
              #f
              (let ((o (attempt (lambda () (outcome-at bv (max 1 (car sizes)) h)))))
                (cond
                 ((string? o) (string-append "size " (number->string (car sizes)) " " o))
                 ((equal? o whole) (loop (cdr sizes)))
                 (else (string-append "size " (number->string (car sizes)) " did "
                                      (show o) " where the whole input did " (show whole)))))))))))

  ;; attempt : (-> Datum) -> (U Datum String)
  ;; The run's outcome, or a string saying what the run raised.  The libhtp
  ;; lane runs its streams through it too, so the two lanes report a raise
  ;; alike.
  (define (attempt run)
    (call/cc
     (lambda (k)
       (with-exception-handler
        (lambda (e) (k (string-append "raised " (describe e))))
        run))))

  ;; describe : Any -> String — a raised object, briefly.
  (define (describe e)
    (cond
     ((and (condition? e) (message-condition? e))
      (string-append (if (who-condition? e) (show (condition-who e)) "") " "
                     (condition-message e)))
     ((and (condition? e) (pair? (simple-conditions e)))
      (show (record-type-name (record-rtd (car (simple-conditions e))))))
     (else (show e))))

  ;; show : Any -> String — written, and cut to 400 characters.
  (define (show x)
    (let ((s (call-with-string-output-port (lambda (p) (write x p)))))
      (if (> (string-length s) 400) (string-append (substring s 0 400) "...") s))))
