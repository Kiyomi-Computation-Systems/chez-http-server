#!r6rs
;;; (strictness-lane) — the server's verdicts on three origin servers' strict
;;; request tests: Kestrel's parsing tables, httpd's http_strict.t and
;;; lighttpd's request.t.  M8.3 (plan §14: 0007 item 3 put them in M2; no
;;; slice held them, and they join this lane).
;;;
;;; Unlike guardian's (a proxy's classes), these sources are origin servers,
;;; so each case's verdict is theirs to compare with: the request was refused
;;; (a status of 400 or more, its handler never reached), or served (its
;;; handler reached), or left unanswered (the head never ended).  Exact
;;; statuses are not compared: servers choose differently there, as 505 or
;;; 400 for a version (decision 0006's amendment of 2026-10-04).  A case where
;;; this server parts from its source is listed in `departures` with the
;;; reason, and the list is gated BOTH WAYS: a case not listed must agree, and
;;; a listed one must still part, so a change in either direction fails until
;;; reviewed (design §8.6's ratchet rule).
;;;
;;; Each case is delivered as its source sends it, but a bare request line is
;;; completed into a head (decided on the owner's word, by form, 2026-10-04):
;;; Kestrel and httpd send a line alone and answer as soon as they read it,
;;; where this server answers once a head ends, so a request that ends in
;;; CRLF and holds no empty line gets one more CRLF and its line is judged.
;;; The vendored bytes are untouched.  Then the client's eof.
;;;
;;; The sources' own wrapping, ported as our rows (Kestrel's tests at
;;; dc8b384: BadHttpRequestTests.cs, HttpParserTests.cs), and their scope:
;;;   - Kestrel: each table once, with its consuming test's wrapping and
;;;     verdict; three tables append others, ported below, each with a check
;;;     that its tail still reads as ported;
;;;   - httpd: every row of the strict host's column but the response-header
;;;     rows ("R", run through httpd's CGI) and the one gated on a module;
;;;   - lighttpd: the blocks of its sections "Basic Request-Handling" and
;;;     "keep-alive", picked by the file's own headings (the owner's word, by
;;;     form, 2026-10-04): the rest test lighttpd's modules.
(library (strictness-lane)
  (export strictness-cases strictness-case-id strictness-case-request strictness-case-expected
          kestrel-composition-faults
          strictness-outcome strictness-verdict strictness-mismatch
          departures complete-head lighttpd-scope)
  (import (rnrs)
          (kestrel-corpus) (httpd-corpus) (lighttpd-corpus)
          (only (corpus-scan) invariance-fault)
          (only (outcome-lane) outcome-at attempt reads))

  ;; A case: its id, its request's bytes as delivered, and the verdicts its
  ;; source expects, one a response, each 'refused, 'served, 'unanswered or
  ;; 'dropped (httpd's undef: the connection closed with no answer).
  (define-record-type strictness-case (fields id request expected))

  ;; --- Kestrel -----------------------------------------------------------------

  ;; The three tails Kestrel's tables end with, as ported below.
  (define kestrel-tails
    '(("RequestLineInvalidData" . ".Concat(MethodWithNonTokenCharData.Select(method => $\"{method} / HTTP/1.0\\r\\n\"))")
      ("MethodWithNonTokenCharData" . ".Concat(MethodWithNullCharData)")
      ("TargetWithNullCharData" . ".Concat(QueryStringWithNullCharData)")
      ("MethodWithNullCharData" . "") ("QueryStringWithNullCharData" . "")
      ("TargetWithEncodedNullCharData" . "") ("UnrecognizedHttpVersionData" . "")
      ("RequestHeaderInvalidData" . "") ("RequestHeaderInvalidDataLineFeedTerminator" . "")
      ("RequestLineInvalidDataLineFeedTerminator" . "") ("RequestLineIncompleteData" . "")))

  ;; kestrel-composition-faults : -> (Listof String)
  ;; Each table whose tail no longer reads as ported, by name: none.
  (define (kestrel-composition-faults)
    (map car (filter (lambda (p) (not (string=? (kestrel-table-tail (car p)) (cdr p)))) kestrel-tails)))

  (define (non-token-methods)          ; MethodWithNonTokenCharData, appended
    (append (kestrel-table "MethodWithNonTokenCharData") (kestrel-table "MethodWithNullCharData")))

  ;; kestrel-cases : -> (Listof StrictnessCase)
  (define (kestrel-cases)
    (define (table name rows verdict)
      (let loop ((rows rows) (i 1) (acc '()))
        (if (null? rows)
            (reverse acc)
            (loop (cdr rows) (+ i 1)
                  (cons (make-strictness-case (string-append "kestrel/" name "#" (number->string i))
                                              (complete-head (ascii (car rows)))
                                              (list verdict))
                        acc)))))
    (define (wrap before rows after) (map (lambda (r) (string-append before r after)) rows))
    (append
     ;; BadHttpRequestTests.InvalidRequestLineData: each line as sent, 400;
     ;; RequestLineInvalidData appends each non-token method's HTTP/1.0 line.
     (table "RequestLineInvalidData"
            (append (kestrel-table "RequestLineInvalidData") (wrap "" (non-token-methods) " / HTTP/1.0\r\n"))
            'refused)
     (table "TargetWithEncodedNullCharData"
            (wrap "GET " (kestrel-table "TargetWithEncodedNullCharData") " HTTP/1.1\r\n") 'refused)
     (table "TargetWithNullCharData"
            (wrap "GET " (append (kestrel-table "TargetWithNullCharData") (kestrel-table "QueryStringWithNullCharData"))
                  " HTTP/1.1\r\n")
            'refused)
     ;; ...TestInvalidRequestLinesWithUnrecognizedVersion: 505.
     (table "UnrecognizedHttpVersionData"
            (wrap "GET / " (kestrel-table "UnrecognizedHttpVersionData") "\r\n") 'refused)
     ;; ...TestInvalidHeaders, and its line-feed table: 400.
     (table "RequestHeaderInvalidData"
            (wrap "GET / HTTP/1.1\r\n" (kestrel-table "RequestHeaderInvalidData") "") 'refused)
     (table "RequestHeaderInvalidDataLineFeedTerminator"
            (wrap "GET / HTTP/1.1\r\n" (kestrel-table "RequestHeaderInvalidDataLineFeedTerminator") "") 'refused)
     ;; HttpParserTests: a line ended by LF alone is refused (strict, the
     ;; default); an incomplete line leaves the parser waiting; a non-token
     ;; method, in an HTTP/1.1 line, is refused.
     (table "RequestLineInvalidDataLineFeedTerminator"
            (kestrel-table "RequestLineInvalidDataLineFeedTerminator") 'refused)
     (table "RequestLineIncompleteData" (kestrel-table "RequestLineIncompleteData") 'unanswered)
     (table "MethodWithNonTokenCharData" (wrap "" (non-token-methods) " / HTTP/1.1\r\n") 'refused)))

  ;; --- httpd -------------------------------------------------------------------

  ;; httpd-cases : -> (Listof StrictnessCase)
  ;; The strict host's column: 0 any error, 1 any success, 90 an HTTP/0.9
  ;; body (an answer), undef no answer at all, else the status.  A row gated
  ;; on httpd's version holds for any server and is taken; one gated on a
  ;; module of httpd's (`have_module`) is httpd's alone and is not.
  (define (httpd-cases)
    (map (lambda (r)
           (make-strictness-case
            (string-append "httpd/row-" (number->string (httpd-row-index r)))
            (complete-head (httpd-row-request r))
            (list (let ((s (httpd-row-strict r)))
                    (cond ((eq? s 'undef) 'dropped)
                          ((memv s '(1 90)) 'served)
                          ((= s 0) 'refused)
                          ((< 100 s 400) 'served)
                          (else 'refused))))))
         (filter (lambda (r) (not (or (httpd-row-response-test? r) (module-gated? r))))
                 (httpd-rows))))

  ;; module-gated? : HttpdRow -> Boolean — gated on a module of httpd's.
  (define (module-gated? r)
    (let ((c (httpd-row-condition r)))
      (and c (>= (string-length c) 11) (string=? (substring c 0 11) "have_module"))))

  ;; --- lighttpd ----------------------------------------------------------------

  ;; lighttpd-scope : (Listof String) — the sections in the lane.
  (define lighttpd-scope '("Basic Request-Handling" "keep-alive"))

  ;; The statuses a server sends a request it refuses for its syntax, size or
  ;; version (RFC 9110 §15.5, §15.6).  Every other is the server's answer to
  ;; a request it accepted: an application's 404 or 401, or a 500 or 502 when
  ;; what it handed the request to failed; this server's handler accepts it
  ;; too, so these are served.
  (define refusals '(400 411 413 414 417 431 501 505))

  ;; lighttpd-cases : -> (Listof StrictnessCase)
  (define (lighttpd-cases)
    (map (lambda (b)
           (make-strictness-case
            (string-append "lighttpd/request.t:" (number->string (lighttpd-block-line b)))
            (complete-head (lighttpd-block-request b))
            (map (lambda (s) (if (memv s refusals) 'refused 'served)) (lighttpd-block-statuses b))))
         (lighttpd-blocks lighttpd-scope)))

  ;; strictness-cases : -> (Listof StrictnessCase) — the three, in turn.
  (define (strictness-cases) (append (kestrel-cases) (httpd-cases) (lighttpd-cases)))

  ;; --- delivery and verdict ----------------------------------------------------

  ;; complete-head : Bytevector -> Bytevector
  ;; A bare request line, one line ended by CRLF, with one CRLF more; any
  ;; other request as it is: a head, a partial line, or a header section
  ;; ended by CRLF, whose fault, if any, comes before its end.
  (define (complete-head bv)
    (let ((n (bytevector-length bv)))
      (if (and (>= n 2) (= (bytevector-u8-ref bv (- n 2)) 13) (= (bytevector-u8-ref bv (- n 1)) 10)
               (not (holds-crlf-before? bv (- n 2))))
          (let ((out (make-bytevector (+ n 2))))
            (bytevector-copy! bv 0 out 0 n)
            (bytevector-u8-set! out n 13)
            (bytevector-u8-set! out (+ n 1) 10)
            out)
          bv)))

  ;; holds-crlf-before? : Bytevector Nat -> Boolean — a CRLF begins before `end`.
  (define (holds-crlf-before? bv end)
    (let loop ((i 0))
      (and (< (+ i 1) (bytevector-length bv)) (< i end)
           (or (and (= (bytevector-u8-ref bv i) 13) (= (bytevector-u8-ref bv (+ i 1)) 10))
               (loop (+ i 1))))))

  ;; strictness-outcome : StrictnessCase Nat -> Datum — (outcome-lane)'s
  ;; outcome at one delivery size, the handler reading any body.
  (define (strictness-outcome c size)
    (outcome-at (strictness-case-request c) size reads))

  ;; strictness-verdict : Datum -> (Listof Symbol)
  ;; One verdict a response written, an interim 1xx aside: 'refused for a
  ;; status of 400 or more (the handler, which answers 200, writes none);
  ;; 'served otherwise.  With none written, '(served) if a handler was
  ;; reached (its body never came), else '(unanswered).
  (define (strictness-verdict o)
    (let* ((acts (car o))
           (statuses (filter (lambda (s) (>= s 200))
                             (map cadr (filter (lambda (a) (eq? (car a) 'write)) acts)))))
      (cond
       ((pair? statuses) (map (lambda (s) (if (>= s 400) 'refused 'served)) statuses))
       ((exists (lambda (a) (eq? (car a) 'call-handler)) acts) '(served))
       (else '(unanswered)))))

  ;; strictness-mismatch : StrictnessCase Symbol [Departures] -> (U #f String)
  ;; #f when the case agrees with its source, or parts as `departures` says
  ;; (the lane's own unless given), and is chunk-invariant at `selection`'s
  ;; sizes; else the first fault.
  (define strictness-mismatch
    (case-lambda
      ((c selection) (strictness-mismatch c selection departures))
      ((c selection departures) (mismatch c selection departures))))

  (define (mismatch c selection departures)
    (let* ((bv (strictness-case-request c))
           (whole (attempt (lambda () (strictness-outcome c (max 1 (bytevector-length bv)))))))
      (if (string? whole)
          (string-append "the whole input " whole)
          (let* ((verdict (strictness-verdict whole))
                 (agrees (equal? verdict (strictness-case-expected c)))
                 (listed (assoc (strictness-case-id c) departures)))
            (cond
             ((and (not agrees) (not listed)) "parts from its source, and is not a listed departure")
             ((and agrees listed) "agrees with its source, but is listed as a departure")
             ((and listed (not (equal? verdict (cadr listed)))) "departs, but not with the verdict listed")
             (else
              (invariance-fault (lambda (size) (strictness-outcome c size))
                                (bytevector-length bv) whole selection)))))))

  ;; --- the departures ----------------------------------------------------------
  ;;
  ;; departures : (Listof (List String (Listof Symbol) Symbol)) — each case
  ;; where this server parts from its source: its id, the verdict this server
  ;; gives it, which the lane holds it to, and why.  Ours, each from RFC 9112
  ;; or a decision:
  ;;   pct-encoding-undecoded  a percent-encoded octet, `%00` among them, is
  ;;                           a valid target (RFC 3986 §2.1); the server hands
  ;;                           it over undecoded (docs/request-targets.org),
  ;;                           where the source refuses a decoded NUL: RFC 3986
  ;;                           §7.3 puts that check on the code that decodes
  ;;                           (kept on the owner's word, 2026-10-04);
  ;;   version-not-1.x         HTTP/2.0 or HTTP/0.9, answered 505 (decision
  ;;                           0006's amendment), where httpd serves it;
  ;;   minor-version-served    HTTP/1.2, served as HTTP/1.1 (RFC 9110 §6.2's
  ;;                           SHOULD; decision 0006's amendment of
  ;;                           2026-10-04, later), where Kestrel answers 505;
  ;;   answers-not-drops       a line ended by CR alone: the parser's 400,
  ;;                           where httpd closes with no answer;
  ;;   reg-name-host           an absolute-form host that is an RFC 3986
  ;;                           reg-name, `0x7f.1` or `127.01.0.1`: served,
  ;;                           where httpd's strict host refuses a host it
  ;;                           would read as an IPv4 address;
  ;;   head-never-ends         a head ended by CR alone never ends; the eof
  ;;                           closes it unanswered (RFC 9112 §8), where httpd
  ;;                           answers 400;
  ;;   no-default-body-limit   a Content-Length of 2 GiB is read, with no body
  ;;                           limit unless CHEZ_HTTP_MAX_BODY_BYTES sets one,
  ;;                           where lighttpd's test config refuses it, 413;
  ;;   trailer-policy          a trailer field the Trailer header did not
  ;;                           name is still the request's to send (RFC 9110
  ;;                           §6.6.2: Trailer is advisory), where lighttpd
  ;;                           refuses it;
  ;;   chunk-extension-space   a space after a chunk extension's `;`
  ;;                           (`a; comment`): the parser's 400 (design §6.5;
  ;;                           kept on the owner's word, 2026-10-04), where
  ;;                           lighttpd reads RFC 9110 §5.6.3's BWS;
  ;;   empty-lines-allowed     two empty lines before a request line are
  ;;                           ignored (RFC 9112 §2.2; the padding PR, by
  ;;                           form), where lighttpd refuses the second request.
  (define departures
    '(("kestrel/TargetWithEncodedNullCharData#1" (served) pct-encoding-undecoded)
      ("kestrel/TargetWithEncodedNullCharData#2" (served) pct-encoding-undecoded)
      ("kestrel/TargetWithEncodedNullCharData#3" (served) pct-encoding-undecoded)
      ("kestrel/TargetWithEncodedNullCharData#4" (served) pct-encoding-undecoded)
      ("kestrel/TargetWithEncodedNullCharData#5" (served) pct-encoding-undecoded)
      ("kestrel/TargetWithEncodedNullCharData#6" (served) pct-encoding-undecoded)
      ("kestrel/TargetWithEncodedNullCharData#7" (served) pct-encoding-undecoded)
      ("kestrel/UnrecognizedHttpVersionData#3" (served) minor-version-served)
      ("httpd/row-14" (refused) version-not-1.x)
      ("httpd/row-40" (refused) answers-not-drops)
      ("httpd/row-41" (refused) version-not-1.x)
      ("httpd/row-44" (served) reg-name-host)
      ("httpd/row-45" (served) reg-name-host)
      ("httpd/row-47" (served) reg-name-host)
      ("httpd/row-48" (served) reg-name-host)
      ("httpd/row-50" (unanswered) head-never-ends)
      ("lighttpd/request.t:44" (served) pct-encoding-undecoded)
      ("lighttpd/request.t:51" (served) no-default-body-limit)
      ("lighttpd/request.t:263" (served) trailer-policy)
      ("lighttpd/request.t:317" (refused) chunk-extension-space)
      ("lighttpd/request.t:333" (refused) chunk-extension-space)
      ("lighttpd/request.t:865" (served served) empty-lines-allowed)))

  ;; ascii : String -> Bytevector — Kestrel's rows are ASCII, each a byte.
  (define (ascii s)
    (u8-list->bytevector
     (map (lambda (c) (let ((v (char->integer c)))
                        (if (< v 128) v (assertion-violation 'strictness-lane "a Kestrel row past ASCII" s))))
          (string->list s)))))
