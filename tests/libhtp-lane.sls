#!r6rs
;;; (libhtp-lane) — our expectations for libhtp's pipelining and multi-packet
;;; streams, and the run they are held to (design §8.2).  The M2 exit.
;;;
;;; A stream's client chunks (`>>>`) are its packets.  Each is delivered to one
;;; fake connection as one `bytes-arrived`, while the connection reads, with
;;; every later turn in between.  After the last, the client's `eof` arrives if
;;; the connection still reads, as when a capture ends.  The `<<<` chunks are a
;;; recorded origin's replies, not an oracle (decision 0007), so none is
;;; delivered, and every handler reads the body, if the request has one, and
;;; answers 200 ((outcome-lane)'s `reads`; decision 0013).  The lane runs under the trace
;;; lane's `corpus-limits`, with no Host required, like the llhttp lanes: six
;;; of the twelve send HTTP/1.1 without one (the owner's word, 2026-09-25).
;;;
;;; What the connection did is the outcome lane's record, plus the body:
;;;   - each handler call, with the request it was given;
;;;   - the body bytes delivered, joined between two other actions;
;;;   - the responses written, by status, and the close and its reason;
;;;   - the phase and close-after the connection ended with, and the actions
;;;     run anywhere but the outermost drain, which must be none.
;;;
;;; The expectations are ours (design §8.2), written from RFC 9112 and the
;;; decisions before the lane first ran, each with its reason beside it.
(library (libhtp-lane)
  (export libhtp-expected-files libhtp-expectation
          libhtp-outcome libhtp-mismatch)
  (import (rnrs)
          (libhtp-corpus) (fake-shell)
          (http-server connection) (http-server response)
          (only (outcome-lane) render-request attempt reads)
          (only (trace-lane) corpus-limits))

  ;; --- the expectations ------------------------------------------------------
  ;;
  ;; Each is (actions phase close-after violations).  A connection the client
  ;; keeps alive closes at its eof, with no close-after; an HTTP/1.0 one
  ;; closes after its response, as `not-keep-alive` (RFC 9112 §9.3: 1.1
  ;; persists unless it says close, 1.0 only if it says keep-alive; decision
  ;; 0006 item 1), in stages: it lingers, and the eof ends it (decision
  ;; 0011).

  ;; Two GETs on one connection, served in order (RFC 9112 §9.3.2; decision
  ;; 0004: serially).
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
  ;; reader is handed the body (decision 0013).  The trailer is not part of
  ;; the request, which is built at on-headers-complete (design §4.2;
  ;; trailers are M6.4's).
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
     ;; the body, answers when the message ends, and closes.
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
             closed not-keep-alive ()))))

  ;; libhtp-expected-files : (Listof String) — the streams with an
  ;; expectation, in file-name order.
  (define libhtp-expected-files
    (list-sort string<? (map car libhtp-expectations)))

  ;; libhtp-expectation : String -> (U Outcome #f)
  (define (libhtp-expectation name)
    (let ((e (assoc name libhtp-expectations)))
      (and e (cdr e))))

  ;; --- the run ---------------------------------------------------------------

  ;; What every handler answers.
  (define ok (make-response 200 #f '() #f))

  ;; packets : String -> (Listof Bytevector)
  ;; The stream's client chunks, in order.  The loader skips an empty chunk,
  ;; so none is empty.
  (define (packets name)
    (map cdr (filter (lambda (c) (eq? (car c) 'client))
                     (libhtp-parse-stream
                      (call-with-port
                          (open-file-input-port (string-append "test/vendor/libhtp/files/" name))
                        get-bytevector-all)))))

  ;; libhtp-outcome : String -> Outcome
  ;; What one fake connection did with the stream `name`'s client packets, one
  ;; delivery each, then the client's eof if it still reads.
  (define (libhtp-outcome name)
    (let ((sh (make-fake-connection corpus-limits reads)))
      (for-each (lambda (bv) (fake-shell-feed-input! sh bv (bytevector-length bv)))
                (packets name))
      (fake-shell-settle! sh)
      (when (fake-shell-reading? sh)
        (fake-shell-deliver! sh '(eof))
        (fake-shell-settle! sh))
      (let ((s (fake-shell-conn-state sh)))
        (list (decisive (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s)
              (fake-shell-violations sh)))))

  ;; decisive : (Listof Action) -> (Listof Datum)
  ;; The outcome lane's decisive actions, rendered, with the bodies: each run
  ;; of body deliveries, with no other decisive action between, joined into
  ;; one `(body text)`.  Feeds, reads and deadlines follow the deliveries and
  ;; are left out.
  (define (decisive actions)
    (fold-right
     (lambda (a acc)
       (case (car a)
         ((call-handler hand-off) (cons (list (car a) (render-request (cadr a))) acc))
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
