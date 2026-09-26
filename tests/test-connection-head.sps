#!r6rs
;;; (http-server connection): the request head.  M2.2.
;;;
;;; on-message-begin through on-headers-complete, with chez-httparse driving
;;; the core through the adapter's bindings, the way a shell will.  Every row
;;; runs in the fake shell's message loop (M2.4): each chunk arrives as
;;; `bytes-arrived` while the connection reads, the parser is fed only when
;;; the core asks, the handler answers every request, each write completes,
;;; and the connection runs until it closes or the input ends.  So a refused
;;; message's response is written and the connection is closed.
;;;
;;; The rows:
;;;   - the request (method, target, version, headers in wire order) is what
;;;     the request's bytes say, at every chunk size;
;;;   - keep-alive is `should-keep-alive?` over the flags the adapter reads
;;;     inside on-headers-complete: decision 0006 item 1's four rows, alone
;;;     and pipelined;
;;;   - each of the four header limits passes a request at the limit and
;;;     refuses one past it with 431, through the parser's own failure;
;;;   - so does the target's limit, with 414 (M2.3);
;;;   - a target that is not the form its method calls for, or whose bytes
;;;     uriparse refuses, or that names no host where RFC 9110 needs one, is
;;;     refused with 400 (M2.3, and the host 2026-09-25; the forms are
;;;     test-target.sps's to table);
;;;   - except the narrow case decision 0009 redirects: a GET or HEAD whose
;;;     target's only faults are bracket params and pipes is answered 301,
;;;     `Location` the target encoded, when that target is within the limit;
;;;   - RFC 9112 §3.2's Host rules (2026-09-25): two Host lines, an invalid
;;;     Host value, and no Host on HTTP/1.1 are refused with 400, the last
;;;     unless decision 0005's switch is off.  The Host is judged before the
;;;     target, so a request the RFC says MUST get 400 is never redirected.
;;;     The rows about other rules send minimal requests with no Host, under
;;;     `minimal`, the defaults with the switch off; the Host rows run under
;;;     the defaults;
;;;   - a parser error with no refusal is a 400, except a Transfer-Encoding
;;;     whose last coding is not chunked, a 501 (M2.5).
;;;
;;; Oracles: the bytes of each request; decision 0006 item 1's keep-alive
;;; rows; design §6.5's 431, 414, 400 and 501; RFC 9112 §3.2's target forms
;;; and §6.1's 501; the limits each row sets.
(import (rnrs) (srfi :64) (testing)
        (http-server connection)
        (http-server request) (http-server response) (http-server span)
        (http-server limits) (fake-shell))

(define (b s) (string->utf8 s))

;; with-limits : (Listof (Pair Symbol Any)) -> Limits
;; default-limits with the Host requirement off and the named limits
;; replaced: header and target sizes, or 'require-host.
(define (with-limits overrides)
  (let ((get (lambda (key default) (cond ((assq key overrides) => cdr) (else default))))
        (L default-limits))
    (make-limits (limits-read-header-timeout-ms L) (limits-idle-timeout-ms L)
                 (limits-body-inactivity-timeout-ms L)
                 (get 'bytes (limits-max-header-bytes L))
                 (get 'count (limits-max-header-count L))
                 (get 'field (limits-max-header-field-bytes L))
                 (get 'value (limits-max-header-value-bytes L))
                 (get 'target (limits-max-target-bytes L))
                 (limits-max-body-bytes L)
                 (limits-pipeline-cap L) (limits-read-buffer-size L)
                 (get 'require-host #f))))

;; minimal : Limits — the defaults, with no Host required, for the rows that
;; send minimal requests to test another rule.
(define minimal (with-limits '()))

;; render-request : Request -> Datum — the request as its bytes.
(define (render-request r)
  (list (request-method r) (utf8->string (span->bytevector (request-target r)))
        (request-http-major r) (request-http-minor r)
        (map (lambda (h) (cons (utf8->string (span->bytevector (car h)))
                               (utf8->string (span->bytevector (cdr h)))))
             (request-headers r))))

;; render-action : Action -> Datum
;; A write as its status and its header block, the segment after the Date
;; slot, as text (M3.2).
(define (render-action a)
  (if (eq? (car a) 'write)
      (list 'write (written-status a) (utf8->string (caddr (cadr a))))
      a))

(define resp (make-response 200 #f '() (b "ok")))

;; Outcome: what one connection did with its input.
;;   requests  the requests handed to call-handler, rendered, in order
;;   error     #f, or the parser's error code (the event carries the code and
;;             its node) and the responses the core originated, a status of
;;             its own rather than the handler's
;;   phase     the state the connection ended in
;;   reason    its close-after reason
;; drive : Bytevector Nat Limits -> Outcome
;; One connection reading `input` in `size`-byte deliveries.
(define (drive input size limits)
  (let ((sh (make-fake-connection limits (lambda (request) resp))))
    (fake-shell-feed-input! sh input size)
    (let ((s (fake-shell-conn-state sh))
          (actions (fake-shell-actions sh))
          (error (find (lambda (ev) (and (eq? (car ev) 'parser-result) (eq? (cadr ev) 'error)))
                       (fake-shell-events sh))))
      (list (map (lambda (a) (render-request (cadr a)))
                 (filter (lambda (a) (eq? (car a) 'call-handler)) actions))
            (and error
                 (list (car (list-ref error 4))
                       (map render-action
                            (filter (lambda (a) (and (eq? (car a) 'write) (not (= (written-status a) 200))))
                                    actions))))
            (conn-phase s) (conn-close-after s)))))

;; every-size : Bytevector Limits -> (Listof Outcome)
;; The distinct outcomes over every delivery size from 1 to the whole input.
(define (every-size input limits)
  (let loop ((size 1) (seen '()))
    (if (> size (bytevector-length input))
        (reverse seen)
        (let ((o (drive input size limits)))
          (loop (+ size 1) (if (member o seen) seen (cons o seen)))))))

;; An originated status as render-action shows it: no body, so
;; `Content-Length: 0`, and `Connection: close` (decision 0010 item 6;
;; design §6.5: every one closes).
(define originated-block "Content-Length: 0\r\nConnection: close\r\n\r\n")
(define (status-write n) (list 'write n originated-block))

;; The outcomes the rows expect.
;;   req      a rendered request: method, target, version, headers
;;   ok       every request handled; the connection ends in `phase`
;;   refused  the parser failed with the core's reason as its code, and the
;;            core answered `status`, then closed; a refusal is a 431
(define (req method target major minor . headers)
  (list method target major minor headers))
(define (ok requests phase reason) (list requests #f phase reason))
(define (refused reason status)
  (list '() (list reason (list (status-write status))) 'closed reason))
(define (refusal reason) (refused reason 431))
;;   redirected  the parser failed with target-redirect as its code, and the
;;               core answered 301 with a Location header, then closed
(define (redirected location)
  (list '()
        (list 'target-redirect
              (list (list 'write 301 (string-append "Location: " location "\r\n" originated-block))))
        'closed 'target-redirect))

;; verdict : (-> Any) -> (U 'accepted 'refused)
(define (verdict thunk)
  (guard (e ((assertion-violation? e) 'refused))
    (thunk)
    'accepted))

(run-suite "connection-head"
  (lambda ()
    ;; --- the request is what its bytes say, at every chunk size --------------
    ;; every-size lists the distinct outcomes over all delivery sizes, so one
    ;; expected outcome is chunk invariance as well as the value.
    (test-equal "a GET with an empty header value, every delivery size"
                (list (ok (list (req 'GET "/a/b?c=1" 1 1 '("Host" . "example.com")
                                     '("X-Empty" . "") '("Accept" . "*/*")))
                          'idle #f))
                (every-size (b "GET /a/b?c=1 HTTP/1.1\r\nHost: example.com\r\nX-Empty:\r\nAccept: */*\r\n\r\n")
                            minimal))
    (test-equal "a POST with a body, every delivery size"
                (list (ok (list (req 'POST "/u" 1 1 '("Content-Length" . "5"))) 'idle #f))
                (every-size (b "POST /u HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello") minimal))
    (test-equal "method numbers become llhttp's names, DELETE (0) and M-SEARCH included"
                '(DELETE M-SEARCH OPTIONS)
                (map (lambda (text) (car (car (car (drive (b text) 1000 minimal)))))
                     '("DELETE /x HTTP/1.1\r\n\r\n" "M-SEARCH /x HTTP/1.1\r\n\r\n"
                       "OPTIONS * HTTP/1.1\r\n\r\n")))

    ;; --- keep-alive: decision 0006 item 1 -----------------------------------
    (test-equal "keep-alive, one request each: 1.1, 1.1 close, 1.0, 1.0 keep-alive"
                '((idle #f) (closed not-keep-alive) (closed not-keep-alive) (idle #f))
                (map (lambda (text)
                       (let ((o (drive (b text) 1000 minimal)))
                         (list (caddr o) (cadddr o))))
                     '("GET / HTTP/1.1\r\n\r\n"
                       "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
                       "GET / HTTP/1.0\r\n\r\n"
                       "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")))
    ;; Pipelined: the second message asks to close, so the third is never
    ;; handled, and each message's head holds only its own headers.
    (test-equal "pipelined 1.1, every delivery size: keep, then close, then nothing"
                (list (ok (list (req 'GET "/1" 1 1) (req 'GET "/2" 1 1 '("Connection" . "close")))
                          'closed 'not-keep-alive))
                (every-size (b "GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\nConnection: close\r\n\r\nGET /3 HTTP/1.1\r\n\r\n")
                            minimal))
    (test-equal "pipelined 1.0, every delivery size: keep-alive, then the default close"
                (list (ok (list (req 'GET "/1" 1 0 '("Connection" . "keep-alive")) (req 'GET "/2" 1 0))
                          'closed 'not-keep-alive))
                (every-size (b "GET /1 HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /2 HTTP/1.0\r\n\r\nGET /3 HTTP/1.0\r\n\r\n")
                            minimal))

    ;; --- the four header limits: at the limit, and one past it ------------------
    ;; A refusal is the parser's own failure with the core's reason as its code,
    ;; answered 431 and closing after, at every delivery size.
    (test-equal "a header name at max-header-field-bytes passes"
                (list (ok (list (req 'GET "/" 1 1 '("X-Ab" . "1"))) 'idle #f))
                (every-size (b "GET / HTTP/1.1\r\nX-Ab: 1\r\n\r\n") (with-limits '((field . 4)))))
    (test-equal "a header name one byte past it is refused"
                (list (refusal 'header-field-too-large))
                (every-size (b "GET / HTTP/1.1\r\nX-Abc: 1\r\n\r\n") (with-limits '((field . 4)))))
    (test-equal "a header value at max-header-value-bytes passes"
                (list (ok (list (req 'GET "/" 1 1 '("X" . "abc"))) 'idle #f))
                (every-size (b "GET / HTTP/1.1\r\nX: abc\r\n\r\n") (with-limits '((value . 3)))))
    (test-equal "a header value one byte past it is refused"
                (list (refusal 'header-value-too-large))
                (every-size (b "GET / HTTP/1.1\r\nX: abcd\r\n\r\n") (with-limits '((value . 3)))))
    (test-equal "max-header-count headers pass"
                (list (ok (list (req 'GET "/" 1 1 '("A" . "1") '("B" . "2"))) 'idle #f))
                (every-size (b "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n") (with-limits '((count . 2)))))
    (test-equal "one header more is refused"
                (list (refusal 'too-many-headers))
                (every-size (b "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n") (with-limits '((count . 2)))))
    (test-equal "names and values totalling max-header-bytes pass"
                (list (ok (list (req 'GET "/" 1 1 '("Ab" . "123") '("C" . "4567"))) 'idle #f))
                (every-size (b "GET / HTTP/1.1\r\nAb: 123\r\nC: 4567\r\n\r\n") (with-limits '((bytes . 10)))))
    (test-equal "one byte more across the section is refused"
                (list (refusal 'headers-too-large))
                (every-size (b "GET / HTTP/1.1\r\nAb: 123\r\nC: 45678\r\n\r\n") (with-limits '((bytes . 10)))))

    ;; --- the target's limit: at the limit, and one past it (M2.3) ---------------
    ;; Counted over the target's bytes as they arrive, so a target split across
    ;; deliveries (every size below its length) is counted whole.
    (test-equal "a target at max-target-bytes passes"
                (list (ok (list (req 'GET "/abc" 1 1)) 'idle #f))
                (every-size (b "GET /abc HTTP/1.1\r\n\r\n") (with-limits '((target . 4)))))
    (test-equal "a target one byte past it is refused with 414"
                (list (refused 'target-too-large 414))
                (every-size (b "GET /abcd HTTP/1.1\r\n\r\n") (with-limits '((target . 4)))))

    ;; --- the target's form and bytes (M2.3) -----------------------------------
    ;; Judged at on-headers-complete, where the method is known; a refusal is
    ;; the parser's own failure, answered 400 and closing after.
    (test-equal "a target of each form passes: OPTIONS *, a path that begins //, absolute-form"
                (list (list (ok (list (req 'OPTIONS "*" 1 1)) 'idle #f))
                      (list (ok (list (req 'GET "//a@b:c/d" 1 1)) 'idle #f))
                      (list (ok (list (req 'GET "http://example.com/p?q=1" 1 1)) 'idle #f)))
                (map (lambda (text) (every-size (b text) minimal))
                     '("OPTIONS * HTTP/1.1\r\n\r\n" "GET //a@b:c/d HTTP/1.1\r\n\r\n"
                       "GET http://example.com/p?q=1 HTTP/1.1\r\n\r\n")))
    (test-equal "an origin-form byte outside RFC 3986's set is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "GET /a\"b HTTP/1.1\r\n\r\n") minimal))
    (test-equal "* is refused with 400 unless the method is OPTIONS"
                (list (refused 'invalid-target 400))
                (every-size (b "GET * HTTP/1.1\r\n\r\n") minimal))
    (test-equal "an absolute-form target with a fragment is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "GET http://h/p#f HTTP/1.1\r\n\r\n") minimal))
    (test-equal "an absolute-form target with userinfo is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "GET http://u@h/p HTTP/1.1\r\n\r\n") minimal))
    (test-equal "a CONNECT target without a port is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "CONNECT example.com HTTP/1.1\r\n\r\n") minimal))
    (test-equal "an http target with no host is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "GET http:///x HTTP/1.1\r\n\r\n") minimal))
    (test-equal "a CONNECT target with an empty host is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "CONNECT :443 HTTP/1.1\r\n\r\n") minimal))

    ;; --- the Host header (RFC 9112 §3.2; 2026-09-25) --------------------------------
    ;; Judged at on-headers-complete, before the target; a refusal is the
    ;; parser's own failure, answered 400 and closing after.
    (test-equal "a request with one valid Host is served"
                (list (ok (list (req 'GET "/" 1 1 '("Host" . "example.com:8080"))) 'idle #f))
                (every-size (b "GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n") default-limits))
    (test-equal "an HTTP/1.1 request with no Host is refused with 400"
                (list (refused 'invalid-host 400))
                (every-size (b "GET / HTTP/1.1\r\n\r\n") default-limits))
    (test-equal "with the requirement off, it is served"
                (list (ok (list (req 'GET "/" 1 1)) 'idle #f))
                (every-size (b "GET / HTTP/1.1\r\n\r\n") minimal))
    (test-equal "an HTTP/1.0 request with no Host is served"
                (list (ok (list (req 'GET "/" 1 0)) 'closed 'not-keep-alive))
                (every-size (b "GET / HTTP/1.0\r\n\r\n") default-limits))
    (test-equal "two Host lines are refused with 400"
                (list (refused 'invalid-host 400))
                (every-size (b "GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n") default-limits))
    (test-equal "a Host value uriparse refuses is refused with 400"
                (list (refused 'invalid-host 400))
                (every-size (b "GET / HTTP/1.1\r\nHost: a b\r\n\r\n") default-limits))
    (test-equal "a Host with userinfo is refused with 400"
                (list (refused 'invalid-host 400))
                (every-size (b "GET / HTTP/1.1\r\nHost: u@h\r\n\r\n") default-limits))
    ;; The 400 is RFC 9112 §3.2's MUST; the 301 is only §3.2's alternative to a
    ;; 400 for a bad target.  So a target decision 0009 would redirect still
    ;; gets 400 when its Host is wrong.
    (test-equal "a redirectable target with no Host is refused with 400, not redirected"
                (list (refused 'invalid-host 400))
                (every-size (b "GET /s?ids[]=1 HTTP/1.1\r\n\r\n") default-limits))

    ;; --- the narrow redirect (decision 0009) ------------------------------------
    ;; Bracket params and pipes, the bytes browsers send unencoded, get a 301 to
    ;; the target encoded; the connection closes after it, as after every
    ;; status the core originates (design §6.5).
    (test-equal "a GET with bracket params and a pipe is redirected: 301, Location encoded"
                (list (redirected "/s?ids%5B%5D=1%7C2"))
                (every-size (b "GET /s?ids[]=1|2 HTTP/1.1\r\n\r\n") minimal))
    (test-equal "a POST with a pipe is refused with 400, not redirected"
                (list (refused 'invalid-target 400))
                (every-size (b "POST /a|b HTTP/1.1\r\n\r\n") minimal))
    ;; Location: //evil.example/... would send the client to another host.
    (test-equal "a path that begins // is refused with 400, never redirected off-host"
                (list (refused 'invalid-target 400))
                (every-size (b "GET //evil.example/a|b HTTP/1.1\r\n\r\n") minimal))
    ;; The Location is always a target this server accepts, its limit included:
    ;; "/a?b=|" is 6 bytes and "/a?b=%7C" 8.
    (test-equal "a redirect to a target at max-target-bytes is made"
                (list (redirected "/a?b=%7C"))
                (every-size (b "GET /a?b=| HTTP/1.1\r\n\r\n") (with-limits '((target . 8)))))
    (test-equal "one to a target past it is refused with 400"
                (list (refused 'invalid-target 400))
                (every-size (b "GET /a?b=| HTTP/1.1\r\n\r\n") (with-limits '((target . 7)))))

    ;; --- a parser error the core did not ask for (design §6.3) ------------------
    (test-equal "an invalid header token: 400, then close"
                (list (list '() (list 'invalid-header-token (list (status-write 400)))
                            'closed 'parser-error))
                (every-size (b "GET / HTTP/1.1\r\nBad Name: x\r\n\r\n") minimal))
    ;; invalid-transfer-encoding splits by the node the parser refused at
    ;; (M2.5): a Transfer-Encoding whose last coding is not chunked is a 501
    ;; (RFC 9112 §6.1), and every other one a 400.
    (test-equal "Transfer-Encoding: pigeons: 501, then close"
                (list (list '() (list 'invalid-transfer-encoding (list (status-write 501)))
                            'closed 'parser-error))
                (every-size (b "PUT /url HTTP/1.1\r\nTransfer-Encoding: pigeons\r\n\r\n") minimal))
    (test-equal "Transfer-Encoding: chunked, deflate: 400, then close"
                (list (list '() (list 'invalid-transfer-encoding (list (status-write 400)))
                            'closed 'parser-error))
                (every-size (b "POST / HTTP/1.1\r\nTransfer-Encoding: chunked, deflate\r\n\r\n") minimal))

    ;; --- bytes-arrived feeds the parser in every reading state -----------------
    (let ((bv (b "abcd")))
      (test-equal "bytes-arrived asks for feed-parser in idle, head and body, not handling"
                  (list (list (list 'feed-parser bv 0 4)) (list (list 'feed-parser bv 0 4))
                        (list (list 'feed-parser bv 0 4)) '())
                  (map (lambda (phase)
                         (call-with-values
                          (lambda () (conn-step (make-conn-state phase #f #f 0 0 #f #f minimal)
                                                (list 'bytes-arrived bv 0 4)))
                          (lambda (s actions) actions)))
                       '(idle head body handling))))

    ;; --- the state holds its limits ------------------------------------------------
    (test-eq "a state without a limits record is refused" 'refused
             (verdict (lambda () (make-conn-state 'idle #f #f 0 0 #f #f #f))))))
