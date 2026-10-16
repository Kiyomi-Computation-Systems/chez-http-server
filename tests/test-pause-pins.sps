#!r6rs
;;; Pause pins: a pause inside a body, pinned as the parser's behaviour.
;;;
;;; A consumer that pauses the parser inside on-body-data must feed it again
;;; from `parser-result-next`, which points one past the piece just
;;; delivered, and after a pause on a body's last byte the message ends only
;;; with one more feed, which may be empty.  chez-httparse documents the
;;; first (docs/api.org, "Pausing, and where to resume").  The core hands a
;;; reader each read's pieces as the parser meets them, so it never pauses
;;; inside a body: these checks pin the two facts as the parser's, for any
;;; reader that would need the pause.  A dependency bump that moves either
;;; reddens this suite first.
;;;
;;; Each check pauses at every piece and feeds again as the rule says, then
;;; compares what the parser delivered with the input's own bytes.
;;;
;;; Oracles: the inputs' own bytes (a 10-byte body and the GET behind it; a
;;; chunked body of 3 and 2 bytes; a 5-byte body at a read's end), and
;;; chez-httparse's docs/api.org.
(import (rnrs) (srfi :64) (testing)
        (generated httparse-message) (httparse modes) (byte-machine runtime))

(define (b s) (string->utf8 s))

;; recorder : -> (values Parser (-> (Listof Datum)) (Datum -> Any))
;; A request parser that pauses at each piece of a body and at each
;; message's end; what it delivered so far, in order: each body piece as its
;; text, each message's target, and each message's end; and a way to note
;; something beside them.
(define (recorder)
  (let* ((seen '())
         (note! (lambda (x) (set! seen (cons x seen))))
         (text (lambda (bv from to)
                 (let ((o (make-bytevector (- to from))))
                   (bytevector-copy! bv from o 0 (- to from))
                   (utf8->string o))))
         (p (make-parser
             httparse-message-machine
             (map (lambda (name)
                    (list name
                          (case name
                            ((on-body-data)
                             (lambda (p c bv from to) (note! (list 'body (text bv from to))) callback-pause))
                            ((on-url-data)
                             (lambda (p c bv from to) (note! (list 'url (text bv from to))) callback-continue))
                            ((on-message-complete)
                             (lambda (p c) (note! '(end)) callback-pause))
                            ((on-method-data on-protocol-data on-version-data on-status-data
                              on-header-field-data on-header-value-data
                              on-chunk-extension-name-data on-chunk-extension-value-data)
                             (lambda (p c bv from to) callback-continue))
                            (else (lambda (p c) callback-continue)))))
                  '(on-reset on-message-begin on-method-data on-method-complete
                    on-url-data on-url-complete on-protocol-data on-protocol-complete
                    on-version-data on-version-complete on-status-data on-status-complete
                    on-header-field-data on-header-field-complete
                    on-header-value-data on-header-value-complete
                    on-headers-complete on-body-data on-chunk-header
                    on-chunk-extension-name-data on-chunk-extension-name-complete
                    on-chunk-extension-value-data on-chunk-extension-value-complete
                    on-chunk-complete on-message-complete))
             #f
             (list (cons 'type (httparse-message-type-value 'request))))))
    (values p (lambda () (reverse seen)) note!)))

;; again-from : ParserResult Nat -> Nat
;; Where the feed after a pause starts: `next`, as the rule says.  Starting it
;; where the read started instead (`start`) makes the parser take the head's
;; first bytes as body.
(define (again-from r start) (parser-result-next r))

;; feed-read : Parser Bytevector (Datum -> Any) -> Void
;; Feed one read whole, and after each pause inside it resume and feed the
;; rest again, from where `again-from` says, while any of it is left.  A
;; pause on the read's last byte leaves nothing to feed.  A read is fed at
;; most `feeds-cap` times, one more than it has bytes: past that the loop is
;; feeding the same bytes again, and it notes `(looped)` and stops, so a
;; wrong resume fails its check rather than never ending.
(define (feed-read p bv note!)
  (let ((feeds-cap (+ (bytevector-length bv) 1)))
    (let loop ((at 0) (feeds 1))
      (let ((r (parser-feed! p bv at (bytevector-length bv))))
        (when (eq? (parser-result-status r) 'paused)
          (parser-resume! p)
          (let ((from (again-from r at)))
            (cond ((>= from (bytevector-length bv)) (values))
                  ((>= feeds feeds-cap) (note! '(looped)))
                  (else (loop from (+ feeds 1))))))))))

(run-suite "pause-pins"
  (lambda ()
    ;; --- a pause inside a body feeds again from next ------------------------
    ;; The body is split across two reads, a GET behind it in the second: each
    ;; body byte is delivered once, in order, and the GET is read whole.
    (let-values (((p seen note!) (recorder)))
      (feed-read p (b "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n01234") note!)
      (feed-read p (b "56789GET /b HTTP/1.1\r\nHost: y\r\n\r\n") note!)
      (test-equal "paused at each piece and fed again from next: each body byte once, then the GET"
                  '((url "/a") (body "01234") (body "56789") (end) (url "/b") (end))
                  (seen)))
    (let-values (((p seen note!) (recorder)))
      (feed-read p (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                     "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\nGET /b HTTP/1.1\r\nHost: y\r\n\r\n"))
                 note!)
      (test-equal "chunked, in one read: each chunk's bytes once, then the GET"
                  '((url "/a") (body "abc") (body "de") (end) (url "/b") (end))
                  (seen)))

    ;; --- a pause on the body's last byte needs one more feed ------------------
    ;; The read ends on the body's last byte: paused there, the message has
    ;; not ended, and it ends with one empty feed at next.
    (let-values (((p seen note!) (recorder)))
      (let* ((bv (b "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
             (r (parser-feed! p bv 0 (bytevector-length bv))))
        (parser-resume! p)
        (let* ((before (seen))
               (left (- (bytevector-length bv) (parser-result-next r))))
          (parser-feed! p bv (parser-result-next r) (bytevector-length bv))
          (test-equal "paused on the body's last byte, the message ends only at one more feed, an empty one"
                      '(((url "/a") (body "hello")) 0
                        ((url "/a") (body "hello") (end)))
                      (list before left (seen))))))))
