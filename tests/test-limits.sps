#!r6rs
;;; (http-server limits): decision 0005's defaults and the environment
;;; overrides.  Oracle: decision 0005 (the nginx-style bounded defaults) and
;;; the documented override convention (seconds for timeouts), and its
;;; amendment of 2026-09-25: the Host requirement is on unless
;;; CHEZ_HTTP_REQUIRE_HOST is exactly "false"; decision 0011's linger
;;; limit, 30 s, nginx's lingering_time; and 0005's connection cap and listen
;;; backlog, 10 000 and 511, which arrive in M4.3 (milestone plan §3).  The
;;; backlog reaches libuv's uv_listen as a C int, whose largest value is
;;; 2147483647 on every platform the project targets (chez-libuv's native.sls
;;; types it int).  `limits-with` replaces fields by the names below, which
;;; this suite writes out itself, in make-limits' order.  Where the server
;;; listens is decision 0012's: CHEZ_HTTP_HOST and CHEZ_HTTP_PORT, by default
;;; 127.0.0.1 and 8080; a TCP port is 0 to 65535, 0 asking the kernel for one
;;; (RFC 9293 §3.1's 16-bit port; libuv's bind takes port 0 so).  0005's
;;; write timeout, 60 s per write completion, and its tick, 250 ms, arrive in
;;; M5.1 (milestone plan §3).  The tick's variable, CHEZ_HTTP_TICK_MS, is read
;;; in milliseconds, since 250 ms has no whole-second spelling (plan §3).  A
;;; tick is 1 to 1,000 ms, decided on the owner's word on 2026-09-27: the
;;; wheel's buckets are a tick wide, and a tick over a second would make a
;;; timeout, given in whole seconds, late by more than its own unit.  Each
;;; kind of deadline the core arms lasts its own timeout (design §4.3;
;;; decision 0011's linger).  0005's write water marks, 262 144 and 65 536
;;; bytes outstanding, arrive in M6.3 (its amendment of 2026-09-25; plan §14):
;;; sizes, given in bytes, a low water above the high water refused.
(import (rnrs) (srfi :64) (testing) (http-server limits))

;; env : (Pair String String) ... -> (String -> (U String #f))
;; An environment holding just these variables.
(define (env . pairs)
  (lambda (name) (let ((p (assoc name pairs))) (and p (cdr p)))))

;; address : (String -> (U String #f)) -> (U (List String Nat) 'faulted)
(define (address lookup)
  (guard (e (#t 'faulted))
    (let-values (((host port) (address-from-environment lookup)))
      (list host port))))

;; Every field, by name and accessor, in make-limits' order.
(define named-fields
  (list (cons 'read-header-timeout-ms limits-read-header-timeout-ms)
        (cons 'idle-timeout-ms limits-idle-timeout-ms)
        (cons 'body-inactivity-timeout-ms limits-body-inactivity-timeout-ms)
        (cons 'linger-timeout-ms limits-linger-timeout-ms)
        (cons 'write-timeout-ms limits-write-timeout-ms)
        (cons 'tick-ms limits-tick-ms)
        (cons 'max-header-bytes limits-max-header-bytes)
        (cons 'max-header-count limits-max-header-count)
        (cons 'max-header-field-bytes limits-max-header-field-bytes)
        (cons 'max-header-value-bytes limits-max-header-value-bytes)
        (cons 'max-target-bytes limits-max-target-bytes)
        (cons 'max-body-bytes limits-max-body-bytes)
        (cons 'pipeline-cap limits-pipeline-cap)
        (cons 'read-buffer-size limits-read-buffer-size)
        (cons 'max-connections limits-max-connections)
        (cons 'backlog limits-backlog)
        (cons 'require-host? limits-require-host?)
        (cons 'write-high-water limits-write-high-water)
        (cons 'write-low-water limits-write-low-water)))

(define all-fields (map cdr named-fields))

;; alone? : (Pair Symbol Accessor) -> Boolean — limits-with, given this field
;; alone, changes it and leaves every other field as default-limits has it.
(define (alone? named)
  (let ((L (limits-with default-limits (list (cons (car named) 'changed)))))
    (for-all (lambda (other)
               (if (eq? other named)
                   (eq? ((cdr other) L) 'changed)
                   (equal? ((cdr other) L) ((cdr other) default-limits))))
             named-fields)))

(run-suite "limits"
  (lambda ()
    ;; --- defaults (decision 0005) ---
    (test-eqv "read-header default 60 s"  60000 (limits-read-header-timeout-ms default-limits))
    (test-eqv "idle default 75 s"         75000 (limits-idle-timeout-ms default-limits))
    (test-eqv "body-inactivity 60 s"      60000 (limits-body-inactivity-timeout-ms default-limits))
    (test-eqv "linger 30 s (decision 0011)" 30000 (limits-linger-timeout-ms default-limits))
    (test-eqv "write timeout 60 s per completion" 60000 (limits-write-timeout-ms default-limits))
    (test-eqv "tick 250 ms"               250   (limits-tick-ms default-limits))
    (test-eqv "max header bytes 16 KiB"   16384 (limits-max-header-bytes default-limits))
    (test-eqv "max header count 100"      100   (limits-max-header-count default-limits))
    (test-eqv "max header field 8 KiB"    8192  (limits-max-header-field-bytes default-limits))
    (test-eqv "max header value 8 KiB"    8192  (limits-max-header-value-bytes default-limits))
    (test-eqv "max target bytes 8 KiB"    8192  (limits-max-target-bytes default-limits))
    (test-eq  "bodies stream unbounded"   'unbounded
              (or (limits-max-body-bytes default-limits) 'unbounded))
    (test-eqv "pipeline cap 1"            1     (limits-pipeline-cap default-limits))
    (test-eqv "read buffer 16 KiB"        16384 (limits-read-buffer-size default-limits))
    (test-eqv "max connections 10 000"    10000 (limits-max-connections default-limits))
    (test-eqv "listen backlog 511"        511   (limits-backlog default-limits))
    (test-eq  "an HTTP/1.1 Host is required" #t   (limits-require-host? default-limits))
    (test-eqv "write high water 256 KiB outstanding" 262144 (limits-write-high-water default-limits))
    (test-eqv "write low water 64 KiB outstanding" 65536 (limits-write-low-water default-limits))

    ;; --- default-limits is exactly the empty environment (one code path) ---
    ;; Every field, so a default that moves in one place and not the other is
    ;; caught whichever field it is (plan §3: each new limit extends this guard).
    (let ((empty (limits-from-environment (lambda (name) #f))))
      (test-equal "empty env == default-limits, field by field"
                  (map (lambda (field) (field default-limits)) all-fields)
                  (map (lambda (field) (field empty)) all-fields)))

    ;; --- one variable per field, in field order, all CHEZ_HTTP_ ---
    (test-equal "the environment variables, one per field"
                '("CHEZ_HTTP_READ_HEADER_TIMEOUT" "CHEZ_HTTP_IDLE_TIMEOUT"
                  "CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT" "CHEZ_HTTP_LINGER_TIMEOUT"
                  "CHEZ_HTTP_WRITE_TIMEOUT" "CHEZ_HTTP_TICK_MS"
                  "CHEZ_HTTP_MAX_HEADER_BYTES"
                  "CHEZ_HTTP_MAX_HEADER_COUNT" "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES"
                  "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES" "CHEZ_HTTP_MAX_TARGET_BYTES"
                  "CHEZ_HTTP_MAX_BODY_BYTES" "CHEZ_HTTP_PIPELINE_CAP"
                  "CHEZ_HTTP_READ_BUFFER_SIZE" "CHEZ_HTTP_MAX_CONNECTIONS"
                  "CHEZ_HTTP_BACKLOG" "CHEZ_HTTP_REQUIRE_HOST"
                  "CHEZ_HTTP_WRITE_HIGH_WATER" "CHEZ_HTTP_WRITE_LOW_WATER")
                limits-environment-variables)

    ;; --- overrides: timeouts are seconds -> ms; sizes/counts as given ---
    (let ((L (limits-from-environment
               (lambda (name)
                 (cond ((string=? name "CHEZ_HTTP_IDLE_TIMEOUT") "30")
                       ((string=? name "CHEZ_HTTP_LINGER_TIMEOUT") "5")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_BYTES") "4096")
                       ((string=? name "CHEZ_HTTP_MAX_BODY_BYTES") "1048576")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES") "256")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES") "512")
                       ((string=? name "CHEZ_HTTP_MAX_CONNECTIONS") "2048")
                       ((string=? name "CHEZ_HTTP_BACKLOG") "128")
                       (else #f))))))
      (test-eqv "idle 30 s -> 30000 ms" 30000   (limits-idle-timeout-ms L))
      (test-eqv "linger 5 s -> 5000 ms" 5000    (limits-linger-timeout-ms L))
      (test-eqv "header bytes overridden" 4096   (limits-max-header-bytes L))
      (test-eqv "body cap overridden"     1048576 (limits-max-body-bytes L))
      (test-eqv "header field overridden" 256    (limits-max-header-field-bytes L))
      (test-eqv "header value overridden" 512    (limits-max-header-value-bytes L))
      (test-eqv "max connections overridden" 2048 (limits-max-connections L))
      (test-eqv "backlog overridden"      128    (limits-backlog L))
      ;; an untouched field keeps its default
      (test-eqv "untouched read-header keeps default" 60000
                (limits-read-header-timeout-ms L)))

    ;; --- the write timeout in seconds, the tick in milliseconds (M5.1) ---
    ;; Made inside the check, so a reader that refuses them fails the check.
    (test-equal "write 90 s -> 90000 ms; the tick is given in ms: 100 -> 100 ms"
                '(90000 100)
                (let ((L (limits-from-environment
                          (env '("CHEZ_HTTP_WRITE_TIMEOUT" . "90") '("CHEZ_HTTP_TICK_MS" . "100")))))
                  (list (limits-write-timeout-ms L) (limits-tick-ms L))))

    ;; --- the write water marks, in bytes (M6.3) ---
    ;; Made inside the checks, so a reader that refuses them fails the check.
    (let ((waters (lambda pairs
                    (guard (e (#t 'faulted))
                      (let ((L (limits-from-environment (apply env pairs))))
                        (list (limits-write-high-water L) (limits-write-low-water L)))))))
      (test-equal "the write water marks are given in bytes, each alone or both"
                  '((131072 65536) (262144 4096) (131072 32768))
                  (list (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "131072"))
                        (waters '("CHEZ_HTTP_WRITE_LOW_WATER" . "4096"))
                        (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "131072")
                                '("CHEZ_HTTP_WRITE_LOW_WATER" . "32768"))))
      ;; A low water above the high water would let the producer go on
      ;; before it had waited, so it is refused, as a malformed value is,
      ;; whichever of the two was set.  Equal marks, and none, are water marks.
      (test-equal "a low water at or below the high water is accepted, 0 among them"
                  '((65536 65536) (0 0) (1 0))
                  (list (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "65536"))
                        (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "0") '("CHEZ_HTTP_WRITE_LOW_WATER" . "0"))
                        (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "1") '("CHEZ_HTTP_WRITE_LOW_WATER" . "0"))))
      (test-equal "a low water above the high water, a negative mark, or not a number is refused"
                  '(faulted faulted faulted faulted faulted)
                  (list (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "65535"))
                        (waters '("CHEZ_HTTP_WRITE_LOW_WATER" . "262145"))
                        (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "10") '("CHEZ_HTTP_WRITE_LOW_WATER" . "11"))
                        (waters '("CHEZ_HTTP_WRITE_LOW_WATER" . "-1"))
                        (waters '("CHEZ_HTTP_WRITE_HIGH_WATER" . "lots")))))

    ;; --- the literal "unbounded" clears the body cap ---
    (let ((L (limits-from-environment
               (lambda (name)
                 (if (string=? name "CHEZ_HTTP_MAX_BODY_BYTES") "unbounded" #f)))))
      (test-eq "unbounded clears the body cap" 'cleared
               (or (limits-max-body-bytes L) 'cleared)))

    ;; --- the Host requirement: "true" or "false", nothing else ---
    (let ((host (lambda (value)
                  (limits-require-host?
                   (limits-from-environment
                    (lambda (name) (and (string=? name "CHEZ_HTTP_REQUIRE_HOST") value)))))))
      (test-equal "false turns the Host requirement off, true keeps it"
                  '(#f #t) (list (host "false") (host "true"))))
    (test-equal "any other Host requirement value is refused"
                '(faulted faulted faulted)
                (map (lambda (value)
                       (guard (e (#t 'faulted))
                         (limits-from-environment
                          (lambda (name) (and (string=? name "CHEZ_HTTP_REQUIRE_HOST") value)))
                         'no-fault))
                     '("0" "no" "False")))

    ;; --- the pipeline cap: 1 and nothing else.  The server answers one
    ;; request at a time by design (decision 0004's amendment of
    ;; 2026-09-25), so a larger cap would be ignored; it is refused instead.
    (let ((cap (lambda (value)
                 (guard (e (#t 'faulted))
                   (limits-pipeline-cap
                    (limits-from-environment
                     (lambda (name) (and (string=? name "CHEZ_HTTP_PIPELINE_CAP") value))))))))
      (test-equal "a pipeline cap of 1 is accepted; 2 and 8 are refused"
                  '(1 faulted faulted) (map cap '("1" "2" "8"))))

    ;; --- a malformed value faults rather than silently defaulting ---
    (test-eq "a negative pipeline cap is refused" 'faulted
             (guard (e (#t 'faulted))
               (limits-from-environment
                 (lambda (name) (if (string=? name "CHEZ_HTTP_PIPELINE_CAP") "-3" #f)))
               'no-fault))
    (let ((backlog (lambda (value)
                     (guard (e (#t 'faulted))
                       (limits-backlog
                        (limits-from-environment
                         (lambda (name) (and (string=? name "CHEZ_HTTP_BACKLOG") value))))))))
      (test-equal "a backlog is at most a C int's largest: 2147483647 is accepted, one more refused"
                  '(2147483647 faulted) (map backlog '("2147483647" "2147483648"))))
    (test-equal "no connections, or no backlog, is refused" '(faulted faulted)
                (map (lambda (variable)
                       (guard (e (#t 'faulted))
                         (limits-from-environment
                          (lambda (name) (and (string=? name variable) "0")))
                         'no-fault))
                     '("CHEZ_HTTP_MAX_CONNECTIONS" "CHEZ_HTTP_BACKLOG")))
    (test-equal "a tick of 1 to 1,000 ms is accepted; 0, below 0, over 1,000, or not a number is refused"
                '(1 1000 faulted faulted faulted faulted)
                (map (lambda (value)
                       (guard (e (#t 'faulted))
                         (limits-tick-ms
                          (limits-from-environment (env (cons "CHEZ_HTTP_TICK_MS" value))))))
                     '("1" "1000" "0" "-1" "1001" "fast")))
    (test-eq "a non-numeric size is refused" 'faulted
             (guard (e (#t 'faulted))
               (limits-from-environment
                 (lambda (name) (if (string=? name "CHEZ_HTTP_MAX_HEADER_BYTES") "big" #f)))
               'no-fault))

    ;; --- where the server listens (decision 0012) ---
    (test-equal "the server listens on 127.0.0.1:8080 by default, or when both are empty"
                '(("127.0.0.1" 8080) ("127.0.0.1" 8080))
                (list (address (env))
                      (address (env '("CHEZ_HTTP_HOST" . "") '("CHEZ_HTTP_PORT" . "")))))
    (test-equal "CHEZ_HTTP_HOST and CHEZ_HTTP_PORT move it, each alone; port 0 asks the kernel"
                '(("0.0.0.0" 8080) ("127.0.0.1" 0) ("::1" 65535))
                (list (address (env '("CHEZ_HTTP_HOST" . "0.0.0.0")))
                      (address (env '("CHEZ_HTTP_PORT" . "0")))
                      (address (env '("CHEZ_HTTP_HOST" . "::1") '("CHEZ_HTTP_PORT" . "65535")))))
    (test-equal "a port that is not a whole number from 0 to 65535 is refused"
                '(faulted faulted faulted faulted)
                (map (lambda (value) (address (env (cons "CHEZ_HTTP_PORT" value))))
                     '("-1" "65536" "http" "80.5")))

    ;; --- how long each kind of deadline lasts (M5.1) ---
    (test-equal "each deadline kind lasts its own timeout"
                '(1000 2000 3000 4000 5000)
                (let ((L (limits-with default-limits
                                      '((idle-timeout-ms . 1000) (read-header-timeout-ms . 2000)
                                        (body-inactivity-timeout-ms . 3000) (write-timeout-ms . 4000)
                                        (linger-timeout-ms . 5000)))))
                  (map (lambda (kind) (limits-deadline-ms L kind)) '(idle header body write linger))))
    (test-eq "a kind the core does not arm has no duration" 'refused
             (guard (e ((assertion-violation? e) 'refused))
               (limits-deadline-ms default-limits 'drain)
               'accepted))

    ;; --- limits-with: fields replaced by name, the rest kept ---
    (test-equal "limits-with replaces each field alone, by name"
                '(read-header-timeout-ms idle-timeout-ms body-inactivity-timeout-ms
                  linger-timeout-ms write-timeout-ms tick-ms
                  max-header-bytes max-header-count max-header-field-bytes
                  max-header-value-bytes max-target-bytes max-body-bytes pipeline-cap
                  read-buffer-size max-connections backlog require-host?
                  write-high-water write-low-water)
                (map car (filter alone? named-fields)))
    (test-equal "and several at once"
                '(1 128 #f)
                (let ((L (limits-with default-limits
                                      '((require-host? . #f) (max-connections . 1) (backlog . 128)))))
                  (list (limits-max-connections L) (limits-backlog L) (limits-require-host? L))))
    (test-eq "a name that is not a field is refused" 'refused
             (guard (e ((assertion-violation? e) 'refused))
               (limits-with default-limits '((max-conections . 1)))
               'accepted))))
