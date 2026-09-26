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
;;; 16 KiB (standing risk 2).  The pipeline cap accepts only 1: the server
;;; answers one request at a time by design (decision 0004's amendment of
;;; 2026-09-25), so any other value is refused rather than ignored.  Durations are stored in milliseconds;
;;; sizes and buffers in bytes.  Timeout overrides are given in whole
;;; seconds; size and count overrides in their stored unit.
;;;
;;; One switch rides with them (decision 0005's amendment of 2026-09-25):
;;; an HTTP/1.1 request with no Host is refused with 400 (RFC 9112 §3.2)
;;; unless CHEZ_HTTP_REQUIRE_HOST is exactly "false".
(library (http-server limits)
  (export
    make-limits limits?
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
    limits-require-host?)
  (import (rnrs))

  ;; make-limits :
  ;;   Nat Nat Nat Nat Nat Nat Nat Nat Nat (U Nat #f) Nat Nat Boolean -> Limits
  ;; The thirteen fields, in declaration order:
  ;;   read-header-timeout-ms idle-timeout-ms body-inactivity-timeout-ms
  ;;   linger-timeout-ms max-header-bytes max-header-count
  ;;   max-header-field-bytes max-header-value-bytes max-target-bytes
  ;;   max-body-bytes pipeline-cap read-buffer-size require-host?
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
      (immutable require-host?              limits-require-host?)))

  ;; default-limits : Limits — decision 0005's nginx-style defaults, and
  ;; decision 0011's linger.
  (define default-limits
    (make-limits 60000 75000 60000 30000 16384 100 8192 8192 8192 #f 1 16384 #t))

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
      "CHEZ_HTTP_REQUIRE_HOST"))

  ;; blank? : (U String #f) -> Boolean — an absent or empty value.
  (define (blank? s)
    (or (not s) (string=? s "")))

  ;; parse-exact : Symbol String String Nat -> Nat
  ;; Parse a non-negative exact integer >= min, or fault with who/name.
  (define (parse-exact who name s min)
    (let ((n (string->number s 10)))
      (unless (and n (integer? n) (exact? n) (>= n min))
        (assertion-violation who
          "expected an exact integer >= the field minimum" name s min))
      n))

  ;; env-integer : Lookup String Nat Nat -> Nat
  (define (env-integer lookup name default min)
    (let ((s (lookup name)))
      (if (blank? s) default (parse-exact 'limits-from-environment name s min))))

  ;; env-seconds->ms : Lookup String Nat -> Nat
  ;; Overrides are whole seconds; the stored value is milliseconds.
  (define (env-seconds->ms lookup name default-ms)
    (let ((s (lookup name)))
      (if (blank? s) default-ms (* 1000 (parse-exact 'limits-from-environment name s 0)))))

  ;; env-max-body : Lookup String (U Nat #f) -> (U Nat #f)
  ;; The literal "unbounded" clears the cap; otherwise a byte count.
  (define (env-max-body lookup name default)
    (let ((s (lookup name)))
      (cond ((blank? s) default)
            ((string=? s "unbounded") #f)
            (else (parse-exact 'limits-from-environment name s 0)))))

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
      (env-boolean     lookup "CHEZ_HTTP_REQUIRE_HOST"            #t))))
