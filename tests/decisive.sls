#!r6rs
;;; (decisive) — what a connection did, as the suites that drive one through
;;; the fake shell at every delivery size compare it: the handlers asked, the
;;; pieces handed over, each reader's end, and the writes by status.  Shared
;;; by test-connection-body.sps, test-connection-expect.sps and
;;; test-connection-padding.sps.
(library (decisive)
  (export decisive text render-request)
  (import (rnrs) (http-server request) (http-server span)
          (only (fake-shell) written-status))

  ;; text : Bytevector Nat Nat -> String — bv[from, to) as UTF-8 text.
  (define (text bv from to)
    (let ((o (make-bytevector (- to from))))
      (bytevector-copy! bv from o 0 (- to from))
      (utf8->string o)))

  ;; render-request : Request -> Datum — the method and target.
  (define (render-request r)
    (list (request-method r) (utf8->string (span->bytevector (request-target r)))))

  ;; decisive : (Listof Action) -> (Listof Datum)
  ;; The handlers asked, the pieces handed over joined into one text between
  ;; two other actions, each reader's end, and the writes by status.
  (define (decisive actions)
    (let loop ((as actions) (acc '()))
      (if (null? as)
          (reverse acc)
          (let ((a (car as)))
            (case (car a)
              ((call-handler)
               (loop (cdr as) (cons (list 'call-handler (render-request (cadr a))) acc)))
              ((deliver-body)
               (let ((piece (text (cadr a) (caddr a) (cadddr a))))
                 (if (and (pair? acc) (eq? (car (car acc)) 'body))
                     (loop (cdr as) (cons (list 'body (string-append (cadr (car acc)) piece)) (cdr acc)))
                     (loop (cdr as) (cons (list 'body piece) acc)))))
              ((deliver-body-end) (loop (cdr as) (cons '(end) acc)))
              ((write) (loop (cdr as) (cons (list 'write (written-status a)) acc)))
              (else (loop (cdr as) acc))))))))
