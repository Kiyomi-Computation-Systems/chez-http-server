#!r6rs
;;; (outcome-lane) — the strict llhttp corpus through the fake shell's message
;;; loop: design §8.1's property 2.  M2.4.
;;;
;;; Every strict fixture is fed to one fake connection as `bytes-arrived`
;;; deliveries at every scheduled chunk size, and what the connection did must
;;; be what it did with the whole input in one delivery:
;;;
;;;   - the handlers called, with the requests they were given;
;;;   - the responses written, by status;
;;;   - the close and its reason, and the state the connection ended in.
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
(library (outcome-lane)
  (export outcome-at outcome-mismatch render-request attempt)
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

  ;; render-request : Request -> Datum — the request as its bytes.
  (define (render-request r)
    (list (request-method r) (utf8->string (span->bytevector (request-target r)))
          (request-http-major r) (request-http-minor r)
          (map (lambda (h) (cons (utf8->string (span->bytevector (car h)))
                                 (utf8->string (span->bytevector (cdr h)))))
               (request-headers r))))

  ;; decisive : (Listof Action) -> (Listof Datum)
  ;; The actions that make the outcome, rendered: the others (feeds, reads,
  ;; deadlines) follow the deliveries and differ by chunk size by design.
  (define (decisive actions)
    (fold-right (lambda (a acc)
                  (case (car a)
                    ((call-handler hand-off) (cons (list (car a) (render-request (cadr a))) acc))
                    ((write) (cons (list 'write (written-status a)) acc))
                    ((close) (cons a acc))
                    (else acc)))
                '() actions))

  ;; outcome-at : Bytevector Nat -> Datum
  ;; What one connection did reading `bv` in `size`-byte deliveries: the
  ;; decisive actions in order, the phase and close-after it ended with, and
  ;; the actions run anywhere but the outermost drain.
  (define (outcome-at bv size)
    (let ((sh (make-fake-connection corpus-limits (lambda (request) ok))))
      (fake-shell-feed-input! sh bv size)
      (let ((s (fake-shell-conn-state sh)))
        (list (decisive (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s)
              (fake-shell-violations sh)))))

  ;; outcome-mismatch : Fixture Symbol -> (U #f String)
  ;; #f when the outcome at every scheduled chunk size is the whole input's,
  ;; with every action run from the outermost drain; else what differed first.
  (define (outcome-mismatch f selection)
    (let* ((bv (corpus-decode-input (fixture-input-text f)))
           (len (bytevector-length bv))
           (no-scan (eq? #t (fixture-meta-ref f 'noScan #f)))
           (whole (attempt (lambda () (outcome-at bv (max 1 len))))))
      (cond
       ((string? whole) (string-append "the whole input " whole))
       ((pair? (cadddr whole)) (string-append "the whole input ran actions inside a feed or a nested drain"))
       (else
        (let loop ((sizes (corpus-scan-sizes len no-scan selection)))
          (if (null? sizes)
              #f
              (let ((o (attempt (lambda () (outcome-at bv (max 1 (car sizes)))))))
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
