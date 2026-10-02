#!r6rs
;;; (libhtp-lane) — our expectations for libhtp's pipelining and multi-packet
;;; streams, and for its two Expect streams, and the run they are held to
;;; (design §8.2).  The M2 exit; the Expect streams since M6.4; and since the
;;; M6 exit, 35-early-response.t run a second time, its handler answering at
;;; the head, as its recorded origin did (below).
;;;
;;; A stream's client chunks (`>>>`) are its packets.  Each is delivered to one
;;; fake connection as one `bytes-arrived`, while the connection reads, with
;;; every later turn in between.  After the last, the client's `eof` arrives if
;;; the connection still reads, as when a capture ends.  The `<<<` chunks are a
;;; recorded origin's replies, not an oracle (decision 0007), so none is
;;; delivered, and every handler reads the body, if the request has one, and
;;; answers 200 ((outcome-lane)'s `reads`; decision 0013), but
;;; 99-expect-100.t's (below).  The lane runs under the trace
;;; lane's `corpus-limits`, with no Host required, like the llhttp lanes: six
;;; of the twelve send HTTP/1.1 without one (the owner's word, 2026-09-25).
;;; The two Expect streams end their lines in a bare LF, which the strict
;;; parser refuses, so they are delivered with CRLF (`libhtp-packets`).
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
  (export libhtp-expected-files libhtp-expectation libhtp-packets crlf-files
          libhtp-outcome libhtp-mismatch
          early-response-expectation early-response-outcomes)
  (import (rnrs)
          (libhtp-corpus) (fake-shell)
          (http-server connection) (http-server response) (http-server request)
          (http-server span)
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
     ;; curl 7.18's upload, expecting 100-continue, its head alone in the
     ;; first packet (RFC 9110 §10.1.1).  The handler is asked at the head
     ;; and answers with a reader, so the 100 goes out before any of the
     ;; body arrives (decision 0013; M6.4); then the body, in three packets,
     ;; its Content-Length of 216 bytes, and the response.
     (cons "05-expect.t"
           `(((call-handler
               (POST "/" 1 1
                     (("User-Agent" . "curl/7.18.2 (i486-pc-linux-gnu) libcurl/7.18.2 OpenSSL/0.9.8g zlib/1.2.3.3 libidn/1.8 libssh2/0.18")
                      ("Accept" . "*/*") ("Content-Length" . "216") ("Expect" . "100-continue")
                      ("Content-Type" . "multipart/form-data; boundary=----------------------------07869933ca1b"))))
              (write 100)
              (body ,(string-append
                      "------------------------------07869933ca1b\r\n"
                      "Content-Disposition: form-data; name=\"file\"; filename=\"404.php\"\r\n"
                      "Content-Type: application/octet-stream\r\n"
                      "\r\n"
                      "<? echo \"404\"; ?>\r\n"
                      "------------------------------07869933ca1b--\r\n"))
              (write 200)
              (close eof))
             closed #f ()))
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
     ;; the body, answers when the message ends, and closes.  Answered at the
     ;; head, as the origin did, it is run again (early-response-outcomes).
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
             closed not-keep-alive ()))
     ;; A PUT to /forbidden expecting 100-continue, which its handler
     ;; refuses at the head, as the recorded origin did: answered with a
     ;; response, not a reader, so no 100 goes out, the body is not read, and
     ;; the connection closes after the response (decision 0013 item 4),
     ;; dropping the POST behind it, which the recorded origin served.
     (cons "99-expect-100.t"
           '(((call-handler (PUT "/forbidden" 1 1 (("Content-Length" . "14") ("Expect" . "100-continue"))))
              (write 401)
              (close unread-body))
             closed unread-body ()))))

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

  ;; crlf-files : (Listof String)
  ;; The streams delivered with each bare LF made CRLF, the line end HTTP
  ;; requires (RFC 9112 §2.2), which the strict parser holds a request to:
  ;; libhtp's two Expect streams, whose lines end in a bare LF.  05's is curl
  ;; 7.18's upload, whose body comes to its Content-Length, 216 bytes, only
  ;; with CRLF: its capture was CRLF, and the file was converted after.  99's
  ;; was written by hand.  Decided on the owner's word, by form, 2026-09-29:
  ;; the vendored bytes are never edited, and every other stream is
  ;; delivered as libhtp's chunker cuts it.
  (define crlf-files '("05-expect.t" "99-expect-100.t"))

  ;; libhtp-packets : String -> (Listof Bytevector)
  ;; The stream's client chunks, in order, as the lane delivers them: made
  ;; CRLF for a stream in crlf-files, and as the loader cuts them otherwise.
  ;; The loader skips an empty chunk, so none is empty.
  (define (libhtp-packets name)
    (let ((chunks (map cdr (filter (lambda (c) (eq? (car c) 'client))
                                   (libhtp-parse-stream
                                    (call-with-port
                                        (open-file-input-port (string-append "test/vendor/libhtp/files/" name))
                                      get-bytevector-all))))))
      (if (member name crlf-files) (map crlf chunks) chunks)))

  ;; crlf : Bytevector -> Bytevector — each LF not after a CR made CRLF.
  (define (crlf bv)
    (let-values (((port take) (open-bytevector-output-port)))
      (let loop ((i 0))
        (when (< i (bytevector-length bv))
          (let ((c (bytevector-u8-ref bv i)))
            (when (and (= c 10) (not (and (> i 0) (= (bytevector-u8-ref bv (- i 1)) 13))))
              (put-u8 port 13))
            (put-u8 port c)
            (loop (+ i 1)))))
      (take)))

  ;; handler-for : String -> (Request -> (U Response BodyReader))
  ;; What the stream `name`'s handler answers: `reads` for every stream but
  ;; 99-expect-100.t, whose recorded origin refused its PUT to /forbidden at
  ;; the head, and whose handler does too, so the stream shows the other half
  ;; of the Expect rule: no 100 for a request the handler answers at once.
  (define (handler-for name)
    (if (string=? name "99-expect-100.t") refuses-forbidden reads))

  ;; refuses-forbidden : Request -> (U Response BodyReader)
  ;; 401 at once, reading nothing, for a request for /forbidden; `reads`
  ;; otherwise.
  (define (refuses-forbidden request)
    (if (equal? (span->bytevector (request-target request)) forbidden)
        (make-response 401 #f '() #f)
        (reads request)))

  (define forbidden (string->utf8 "/forbidden"))

  ;; libhtp-outcome : String -> Outcome
  ;; What one fake connection did with the stream `name`'s client packets, one
  ;; delivery each, then the client's eof if it still reads.
  (define (libhtp-outcome name)
    (run-stream (handler-for name) (libhtp-packets name) #t))

  ;; run-stream : (Request -> (U Response BodyReader)) (Listof Bytevector) Boolean -> Outcome
  ;; What one fake connection whose handler is `handler` did with `packets`,
  ;; one delivery each, then, if `eof?`, the client's eof if it still reads.
  (define (run-stream handler packets eof?)
    (let ((sh (make-fake-connection corpus-limits handler)))
      (for-each (lambda (bv) (fake-shell-feed-input! sh bv (bytevector-length bv)))
                packets)
      (fake-shell-settle! sh)
      (when (and eof? (fake-shell-reading? sh))
        (fake-shell-deliver! sh '(eof))
        (fake-shell-settle! sh))
      (let ((s (fake-shell-conn-state sh)))
        (list (decisive (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s)
              (fake-shell-violations sh)))))

  ;; --- 35-early-response.t, answered at the head ----------------------------
  ;;
  ;; The lane's handler reads 35's body, the suites' one HTTP/1.0 body read,
  ;; so its expectation stays.  Its recorded origin answered the POST 400
  ;; before the body, as a handler can since M6.1, with a response instead
  ;; of a reader (decision 0013 item 4), and the M6 exit runs it so too, on
  ;; the owner's word, by form (2026-10-02).  The head's packet alone brings
  ;; the 400, and with it the staged close HTTP/1.0 gets: the connection
  ;; lingers, reading and dropping what the client still sends, the body
  ;; among it, so no reader is handed it, and the client's close ends it
  ;; (decision 0011).

  ;; early-response-expectation : (List Outcome Outcome)
  ;; After the head's packet alone, and after the whole stream and its eof.
  (define early-response-expectation
    (let ((asked '(call-handler (POST "/" 1 0 (("Content-Length" . "12")
                                               ("Content-Type" . "application/x-www-form-urlencoded")
                                               ("User-Agent" . "Mozilla"))))))
      (list (list (list asked '(write 400)) 'lingering 'not-keep-alive '())
            (list (list asked '(write 400) '(close not-keep-alive)) 'closed 'not-keep-alive '()))))

  ;; early-response-outcomes : -> (List Outcome Outcome)
  ;; 35's head's packet alone, then the whole stream and its eof, each on a
  ;; fresh connection whose handler answers 400 at once, reading nothing.
  (define (early-response-outcomes)
    (let ((packets (libhtp-packets "35-early-response.t"))
          (at-once (lambda (request) (make-response 400 #f '() #f))))
      (list (run-stream at-once (list (car packets)) #f)
            (run-stream at-once packets #t))))

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
