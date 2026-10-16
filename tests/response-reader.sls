#!r6rs
;;; (response-reader) — a response read back off the wire by chez-httparse's
;;; strict response parser: the serializer's independent oracle.
;;;
;;; The serializer writes bytes.  This reads them as a client would, with a
;;; parser that is not ours, so wire that only looks right to our own code is
;;; caught.  What it returns is what the parser saw: the status code, read at
;;; on-headers-complete; the reason phrase; each header field, in order; the
;;; body delivered; and how the read ended.  Bytes become characters one for
;;; one (Latin-1), so a value's obs-text survives the round trip.
(library (response-reader)
  (export read-response)
  (import (rnrs)
          (generated httparse-message) (httparse modes) (byte-machine runtime)
          (only (httparse test adapter) adapter-trace-names))

  ;; read-response : Bytevector Boolean Boolean
  ;;                 -> (List Nat String (Listof (Pair String String)) String Symbol)
  ;;   head? — the parser skips the body, as a client does for the answer to
  ;;           a HEAD, or to a CONNECT that succeeded
  ;;   eof?  — the connection ends after these bytes, as a client sees at EOF
  ;; The status, the reason phrase, the headers, the body and the end:
  ;; 'complete when the message completed at the last byte, 'bytes-after when
  ;; it completed with bytes after it (such as a body written where the client
  ;; reads none), else the status of the parser's last answer ('need-input
  ;; while a body is still owed, 'error, ...).  The parser pauses at the
  ;; message's end, so where it stopped is known.  An interim 1xx with bytes
  ;; after it is read past, as a client reads past it to the final response,
  ;; which is the one returned; one alone is returned itself.  With `eof?`, a
  ;; message the bytes left open is finished with parser-finish!, which
  ;; completes one delimited by the close and refuses any other.
  (define (read-response bv head? eof?)
    (let ((status 0) (reason '()) (field '()) (value '()) (headers '())
          (body '()) (complete #f))
      (define (take bytes from to acc)   ; the span's bytes, onto acc, reversed
        (let loop ((i from) (acc acc))
          (if (= i to) acc (loop (+ i 1) (cons (bytevector-u8-ref bytes i) acc)))))
      (define (text acc) (list->string (map integer->char (reverse acc))))
      (define (span-callback name)
        (case name
          ((on-status-data)
           (lambda (p ctx bytes from to) (set! reason (take bytes from to reason)) callback-continue))
          ((on-header-field-data)
           (lambda (p ctx bytes from to) (set! field (take bytes from to field)) callback-continue))
          ((on-header-value-data)
           (lambda (p ctx bytes from to) (set! value (take bytes from to value)) callback-continue))
          ((on-body-data)
           (lambda (p ctx bytes from to) (set! body (take bytes from to body)) callback-continue))
          (else (lambda (p ctx bytes from to) callback-continue))))
      (define (event-callback name)
        (case name
          ((on-header-value-complete)
           (lambda (p ctx)
             (set! headers (cons (cons (text field) (text value)) headers))
             (set! field '())
             (set! value '())
             callback-continue))
          ((on-headers-complete)
           (lambda (p ctx)
             (set! status (parser-field-ref p 'status-code))
             (if head? 'skip-body callback-continue)))
          ((on-message-complete)
           (lambda (p ctx) (set! complete #t) callback-pause))
          (else (lambda (p ctx) callback-continue))))
      (let* ((p (make-parser
                 httparse-message-machine
                 (map (lambda (row)
                        (list (car row)
                              (if (eq? (cadr row) 'span)
                                  (span-callback (car row))
                                  (event-callback (car row)))))
                      adapter-trace-names)
                 #f (list (cons 'type (httparse-message-type-value 'response)))))
             (len (bytevector-length bv))
             (end (let read-from ((from 0))
                    (let ((fed (parser-feed! p bv from len)))
                      (cond
                       ((and complete (interim? status) (< (parser-result-next fed) len))
                        (set! reason '()) (set! headers '()) (set! body '()) (set! complete #f)
                        (parser-resume! p)
                        (read-from (parser-result-next fed)))
                       (complete (if (< (parser-result-next fed) len) 'bytes-after 'complete))
                       ((and eof? (eq? (parser-result-status fed) 'need-input))
                        (let ((finished (parser-finish! p)))
                          (if complete 'complete (parser-result-status finished))))
                       (else (parser-result-status fed)))))))
        (list status (text reason) (reverse headers) (text body) end))))

  ;; interim? : Nat -> Boolean
  ;; A 1xx the final response follows (RFC 9110 §15.2): a client reads on.
  ;; A 101 is the last HTTP/1 message on the connection, so it is not one.
  (define (interim? status)
    (and (<= 100 status 199) (not (= status 101)))))
