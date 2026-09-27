#!r6rs
;;; (http-server limits) — bounded, nginx-style connection limits (decision 0005).
;;;
;;; PURE functional core: imports only (rnrs).  Reading the process
;;; environment is I/O and belongs to the shell, so this library never
;;; calls getenv.  Instead `limits-from-environment` takes an injected
;;; lookup procedure (String -> (U String #f)); the shell passes the real
;;; getenv and the tests pass a fake environment, so defaults and every
;;; override are exercised with no I/O.
;;;
;;; Defaults (decision 0005): header-read 60 s, idle 75 s, body-inactivity
;;; 60 s, linger 30 s (decision 0011: how long a connection that closes
;;; after a response reads and drops what arrives, waiting for the client to
;;; close), header bytes 16 KiB (-> 431), header count 100, header field and
;;; header value 8 KiB each (-> 431; M2, milestone plan §3), target 8 KiB
;;; (-> 414), bodies stream unbounded (#f), pipeline cap 1, read buffer
;;; 16 KiB (standing risk 2), 10 000 connections at once (a connection over
;;; them is refused as it arrives), and a listen backlog of 511, the kernel's
;;; queue of connections not yet accepted (M4.3, milestone plan §3).  The
;;; backlog reaches libuv's uv_listen as a C int, so it is at most 2147483647,
;;; the largest a C int holds on every platform the project targets.  The pipeline cap accepts only 1: the server
;;; answers one request at a time by design (decision 0004's amendment of
;;; 2026-09-25), so any other value is refused rather than ignored.  Durations are stored in milliseconds;
;;; sizes and buffers in bytes.  Timeout overrides are given in whole
;;; seconds; size and count overrides in their stored unit.
;;;
;;; One switch rides with them (decision 0005's amendment of 2026-09-25):
;;; an HTTP/1.1 request with no Host is refused with 400 (RFC 9112 §3.2)
;;; unless CHEZ_HTTP_REQUIRE_HOST is exactly "false".  And where the server
;;; listens is read the same way (decision 0012): CHEZ_HTTP_HOST and
;;; CHEZ_HTTP_PORT, by default 127.0.0.1 and 8080, loopback, so a server is
;;; exposed only when asked.
(library (http-server limits)
  (export
    make-limits limits?
    limits-with
    default-limits
    limits-from-environment
    limits-environment-variables
    limits-read-header-timeout-ms
    limits-idle-timeout-ms
    limits-body-inactivity-timeout-ms
    limits-linger-timeout-ms
    limits-max-header-bytes
    limits-max-header-count
    limits-max-header-field-bytes
    limits-max-header-value-bytes
    limits-max-target-bytes
    limits-max-body-bytes
    limits-pipeline-cap
    limits-read-buffer-size
    limits-max-connections
    limits-backlog
    limits-require-host?
    address-from-environment)
  (import (rnrs))

  ;; make-limits :
  ;;   Nat Nat Nat Nat Nat Nat Nat Nat Nat (U Nat #f) Nat Nat Nat Nat Boolean -> Limits
  ;; The fifteen fields, in declaration order:
  ;;   read-header-timeout-ms idle-timeout-ms body-inactivity-timeout-ms
  ;;   linger-timeout-ms max-header-bytes max-header-count
  ;;   max-header-field-bytes max-header-value-bytes max-target-bytes
  ;;   max-body-bytes pipeline-cap read-buffer-size max-connections backlog
  ;;   require-host?
  ;; (make-limits, limits? and the accessors are generated below.)
  (define-record-type limits
    (fields
      (immutable read-header-timeout-ms     limits-read-header-timeout-ms)
      (immutable idle-timeout-ms            limits-idle-timeout-ms)
      (immutable body-inactivity-timeout-ms limits-body-inactivity-timeout-ms)
      (immutable linger-timeout-ms          limits-linger-timeout-ms)
      (immutable max-header-bytes           limits-max-header-bytes)
      (immutable max-header-count           limits-max-header-count)
      (immutable max-header-field-bytes     limits-max-header-field-bytes)
      (immutable max-header-value-bytes     limits-max-header-value-bytes)
      (immutable max-target-bytes           limits-max-target-bytes)
      (immutable max-body-bytes             limits-max-body-bytes)
      (immutable pipeline-cap               limits-pipeline-cap)
      (immutable read-buffer-size           limits-read-buffer-size)
      (immutable max-connections            limits-max-connections)
      (immutable backlog                    limits-backlog)
      (immutable require-host?              limits-require-host?)))

  ;; limits-with : Limits (Listof (Pair Symbol Any)) -> Limits
  ;; `base` with the fields named in `overrides` replaced, each as (name .
  ;; value), the name make-limits gives the field (read-header-timeout-ms ...
  ;; require-host?).  The order comes from the record type itself, so a new
  ;; field needs no caller changed.  A name that is not a field is an
  ;; assertion violation; values are not checked, as make-limits' are not.
  (define (limits-with base overrides)
    (let* ((rtd (record-type-descriptor limits))
           (names (vector->list (record-type-field-names rtd))))
      (for-each (lambda (o)
                  (unless (and (pair? o) (memq (car o) names))
                    (assertion-violation 'limits-with "not a limits field" o)))
                overrides)
      (apply make-limits
             (let fields ((names names) (k 0))
               (if (null? names)
                   '()
                   (cons (let ((o (assq (car names) overrides)))
                           (if o (cdr o) ((record-accessor rtd k) base)))
                         (fields (cdr names) (+ k 1))))))))

  ;; default-limits : Limits — decision 0005's nginx-style defaults, and
  ;; decision 0011's linger.
  (define default-limits
    (make-limits 60000 75000 60000 30000 16384 100 8192 8192 8192 #f 1 16384 10000 511 #t))

  ;; limits-environment-variables : (Listof String)
  ;; The environment variables consulted by `limits-from-environment`,
  ;; in field order.
  (define limits-environment-variables
    '("CHEZ_HTTP_READ_HEADER_TIMEOUT"
      "CHEZ_HTTP_IDLE_TIMEOUT"
      "CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT"
      "CHEZ_HTTP_LINGER_TIMEOUT"
      "CHEZ_HTTP_MAX_HEADER_BYTES"
      "CHEZ_HTTP_MAX_HEADER_COUNT"
      "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES"
      "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES"
      "CHEZ_HTTP_MAX_TARGET_BYTES"
      "CHEZ_HTTP_MAX_BODY_BYTES"
      "CHEZ_HTTP_PIPELINE_CAP"
      "CHEZ_HTTP_READ_BUFFER_SIZE"
      "CHEZ_HTTP_MAX_CONNECTIONS"
      "CHEZ_HTTP_BACKLOG"
      "CHEZ_HTTP_REQUIRE_HOST"))

  ;; blank? : (U String #f) -> Boolean — an absent or empty value.
  (define (blank? s)
    (or (not s) (string=? s "")))

  ;; parse-exact : Symbol String String Nat (U Nat #f) -> Nat
  ;; Parse an exact integer >= min and, unless max is #f, <= max, or fault
  ;; with who/name.
  (define (parse-exact who name s min max)
    (let ((n (string->number s 10)))
      (unless (and n (integer? n) (exact? n) (>= n min) (or (not max) (<= n max)))
        (assertion-violation who
          "expected an exact integer within the field's bounds" name s min max))
      n))

  ;; c-int-max : Nat — the largest C int, what uv_listen takes a backlog as.
  (define c-int-max 2147483647)

  ;; env-integer : Lookup String Nat Nat [Nat] -> Nat
  (define env-integer
    (case-lambda
      ((lookup name default min) (env-integer lookup name default min #f))
      ((lookup name default min max)
       (let ((s (lookup name)))
         (if (blank? s) default (parse-exact 'limits-from-environment name s min max))))))

  ;; env-seconds->ms : Lookup String Nat -> Nat
  ;; Overrides are whole seconds; the stored value is milliseconds.
  (define (env-seconds->ms lookup name default-ms)
    (let ((s (lookup name)))
      (if (blank? s) default-ms (* 1000 (parse-exact 'limits-from-environment name s 0 #f)))))

  ;; env-max-body : Lookup String (U Nat #f) -> (U Nat #f)
  ;; The literal "unbounded" clears the cap; otherwise a byte count.
  (define (env-max-body lookup name default)
    (let ((s (lookup name)))
      (cond ((blank? s) default)
            ((string=? s "unbounded") #f)
            (else (parse-exact 'limits-from-environment name s 0 #f)))))

  ;; env-pipeline-cap : Lookup String -> Nat
  ;; 1, the only cap the server serves; a value that parses but is not 1
  ;; faults with who/name, as a malformed one does, rather than being
  ;; accepted and ignored.
  (define (env-pipeline-cap lookup name)
    (let ((n (env-integer lookup name 1 1)))
      (unless (= n 1)
        (assertion-violation 'limits-from-environment
          "the pipeline cap must be 1: requests are answered one at a time" name n))
      n))

  ;; env-boolean : Lookup String Boolean -> Boolean
  ;; Exactly "true" or "false"; anything else faults with who/name, as a
  ;; malformed size does, rather than guessing.
  (define (env-boolean lookup name default)
    (let ((s (lookup name)))
      (cond ((blank? s) default)
            ((string=? s "true") #t)
            ((string=? s "false") #f)
            (else (assertion-violation 'limits-from-environment
                                       "expected true or false" name s)))))

  ;; limits-from-environment : (String -> (U String #f)) -> Limits
  ;; default-limits with any variable present in `lookup` applied over it.
  ;; Pure: all I/O lives in the injected lookup.
  (define (limits-from-environment lookup)
    (make-limits
      (env-seconds->ms lookup "CHEZ_HTTP_READ_HEADER_TIMEOUT"     60000)
      (env-seconds->ms lookup "CHEZ_HTTP_IDLE_TIMEOUT"            75000)
      (env-seconds->ms lookup "CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT" 60000)
      (env-seconds->ms lookup "CHEZ_HTTP_LINGER_TIMEOUT"          30000)
      (env-integer     lookup "CHEZ_HTTP_MAX_HEADER_BYTES"        16384 1)
      (env-integer     lookup "CHEZ_HTTP_MAX_HEADER_COUNT"        100   1)
      (env-integer     lookup "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES"  8192  1)
      (env-integer     lookup "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES"  8192  1)
      (env-integer     lookup "CHEZ_HTTP_MAX_TARGET_BYTES"        8192  1)
      (env-max-body    lookup "CHEZ_HTTP_MAX_BODY_BYTES"          #f)
      (env-pipeline-cap lookup "CHEZ_HTTP_PIPELINE_CAP")
      (env-integer     lookup "CHEZ_HTTP_READ_BUFFER_SIZE"        16384 1)
      (env-integer     lookup "CHEZ_HTTP_MAX_CONNECTIONS"         10000 1)
      (env-integer     lookup "CHEZ_HTTP_BACKLOG"                 511   1 c-int-max)
      (env-boolean     lookup "CHEZ_HTTP_REQUIRE_HOST"            #t)))

  ;; address-from-environment : (String -> (U String #f)) -> (values String Nat)
  ;; Where the server listens (decision 0012): CHEZ_HTTP_HOST, and
  ;; CHEZ_HTTP_PORT, a TCP port, 0 to 65535, where 0 asks the kernel for one;
  ;; 127.0.0.1 and 8080 when they are absent or empty.  A malformed port
  ;; faults with who/name, as a malformed limit does.  The host is not
  ;; judged here: the listener's bind judges it, as the IPv4 or IPv6 literal
  ;; it must be.
  (define (address-from-environment lookup)
    (let ((host (lookup "CHEZ_HTTP_HOST")))
      (values (if (blank? host) "127.0.0.1" host)
              (env-integer lookup "CHEZ_HTTP_PORT" 8080 0 65535)))))
