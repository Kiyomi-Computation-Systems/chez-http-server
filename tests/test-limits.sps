#!r6rs
;;; (http-server limits): the defaults and the environment overrides.
;;; Oracle: nginx-style bounded defaults and the documented override
;;; convention: timeouts in whole seconds, sizes and counts in their stored
;;; unit, the tick in milliseconds (250 ms has no whole-second spelling).
;;; The Host requirement is on unless CHEZ_HTTP_REQUIRE_HOST is exactly
;;; "false".  The linger limit is 30 s, nginx's lingering_time.  The
;;; connection cap is 10 000 and the listen backlog 511; the backlog reaches
;;; libuv's uv_listen as a C int, whose largest value is 2147483647 on every
;;; platform the project targets (chez-libuv's native.sls types it int).  The
;;; write timeout is 60 s per write completion.  A tick is 1 to 1,000 ms: the
;;; timer wheel's buckets are a tick wide, and a tick over a second would
;;; make a timeout, given in whole seconds, late by more than its own unit.
;;; Each kind of deadline the core arms lasts its own timeout.  The write
;;; water marks, 262 144 and 65 536 bytes outstanding, are sizes in bytes; a
;;; low water above the high water is refused.  The drain timeout is 10 s
;;; after a shutdown is asked for, in whole seconds like the other timeouts.
;;; There is no pipeline cap: CHEZ_HTTP_PIPELINE_CAP is not read, since the
;;; server answers one request at a time.  Where the server listens is
;;; CHEZ_HTTP_HOST and CHEZ_HTTP_PORT, by default 127.0.0.1 and 8080; a TCP
;;; port is 0 to 65535, 0 asking the kernel for one (RFC 9293 §3.1's 16-bit
;;; port; libuv's bind takes port 0 so).  Every number, the port's too, is
;;; written in ASCII digits alone, leading zeros allowed: anything else is
;;; refused, naming its variable.  `limits-with` replaces fields by the names
;;; below, which this suite writes out itself, in make-limits' order.
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
        (cons 'read-buffer-size limits-read-buffer-size)
        (cons 'max-connections limits-max-connections)
        (cons 'backlog limits-backlog)
        (cons 'require-host? limits-require-host?)
        (cons 'write-high-water limits-write-high-water)
        (cons 'write-low-water limits-write-low-water)
        (cons 'drain-timeout-ms limits-drain-timeout-ms)))

(define all-fields (map cdr named-fields))

;; refusal : (-> Any) -> Any
;; The thunk's answer, or, if it raised an assertion violation with
;; irritants, (refused first-irritant): a refused setting names its variable
;; first.
(define (refusal thunk)
  (guard (e ((and (assertion-violation? e) (irritants-condition? e)
                  (pair? (condition-irritants e)))
             (list 'refused (car (condition-irritants e)))))
    (thunk)))

;; set-alone : (Pair String Accessor) String -> Any
;; The field its variable sets, from an environment holding just that
;; variable at `value`, or the refusal.
(define (set-alone variable value)
  (refusal (lambda () ((cdr variable) (limits-from-environment (env (cons (car variable) value)))))))

;; port-alone : String -> Any
;; The port from an environment holding just CHEZ_HTTP_PORT at `value`, or
;; the refusal.
(define (port-alone value)
  (refusal (lambda ()
             (let-values (((host port) (address-from-environment (env (cons "CHEZ_HTTP_PORT" value)))))
               port))))

;; The timeouts, given in whole seconds, each with its field.
(define timeout-variables
  (list (cons "CHEZ_HTTP_READ_HEADER_TIMEOUT" limits-read-header-timeout-ms)
        (cons "CHEZ_HTTP_IDLE_TIMEOUT" limits-idle-timeout-ms)
        (cons "CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT" limits-body-inactivity-timeout-ms)
        (cons "CHEZ_HTTP_LINGER_TIMEOUT" limits-linger-timeout-ms)
        (cons "CHEZ_HTTP_WRITE_TIMEOUT" limits-write-timeout-ms)
        (cons "CHEZ_HTTP_DRAIN_TIMEOUT" limits-drain-timeout-ms)))

;; The tick, the sizes and the counts, given in their stored unit, each with
;; its field.
(define count-variables
  (list (cons "CHEZ_HTTP_TICK_MS" limits-tick-ms)
        (cons "CHEZ_HTTP_MAX_HEADER_BYTES" limits-max-header-bytes)
        (cons "CHEZ_HTTP_MAX_HEADER_COUNT" limits-max-header-count)
        (cons "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES" limits-max-header-field-bytes)
        (cons "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES" limits-max-header-value-bytes)
        (cons "CHEZ_HTTP_MAX_TARGET_BYTES" limits-max-target-bytes)
        (cons "CHEZ_HTTP_READ_BUFFER_SIZE" limits-read-buffer-size)
        (cons "CHEZ_HTTP_MAX_CONNECTIONS" limits-max-connections)
        (cons "CHEZ_HTTP_BACKLOG" limits-backlog)
        (cons "CHEZ_HTTP_WRITE_HIGH_WATER" limits-write-high-water)
        (cons "CHEZ_HTTP_WRITE_LOW_WATER" limits-write-low-water)))

(define body-variable (cons "CHEZ_HTTP_MAX_BODY_BYTES" limits-max-body-bytes))

;; Values that are not a whole number in ASCII digits alone: a sign, on zero
;; too; a radix prefix; an exponent, with an exactness prefix and without; a
;; fraction; a decimal point; a space before and after; a word; an exactness
;; prefix; a complex number with no imaginary part, in both its forms; and
;; ARABIC-INDIC DIGIT THREE (U+0663), which char-numeric? takes for a digit.
;; Chez 10.4.1's string->number reads "+5", "-0", "#x10", "#e1e3", "10/2",
;; "#e5", "5+0i" and "5@0" as exact integers.
(define malformed
  (list "-1" "+5" "-0" "#x10" "1e3" "#e1e3" "10/2" "1.5" " 5" "5 " "five" "#e5"
        "5+0i" "5@0" (string (integer->char #x0663))))

;; refused-for : (Listof (Pair String Accessor)) -> (Listof (Listof Any))
;; Each variable's refusal of each malformed value, as a refusal names it.
(define (refused-for variables)
  (map (lambda (variable) (map (lambda (value) (list 'refused (car variable))) malformed))
       variables))

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
    ;; --- defaults ---
    (test-eqv "read-header default 60 s"  60000 (limits-read-header-timeout-ms default-limits))
    (test-eqv "idle default 75 s"         75000 (limits-idle-timeout-ms default-limits))
    (test-eqv "body-inactivity 60 s"      60000 (limits-body-inactivity-timeout-ms default-limits))
    (test-eqv "linger 30 s" 30000 (limits-linger-timeout-ms default-limits))
    (test-eqv "write timeout 60 s per completion" 60000 (limits-write-timeout-ms default-limits))
    (test-eqv "tick 250 ms"               250   (limits-tick-ms default-limits))
    (test-eqv "max header bytes 16 KiB"   16384 (limits-max-header-bytes default-limits))
    (test-eqv "max header count 100"      100   (limits-max-header-count default-limits))
    (test-eqv "max header field 8 KiB"    8192  (limits-max-header-field-bytes default-limits))
    (test-eqv "max header value 8 KiB"    8192  (limits-max-header-value-bytes default-limits))
    (test-eqv "max target bytes 8 KiB"    8192  (limits-max-target-bytes default-limits))
    (test-eq  "bodies stream unbounded"   'unbounded
              (or (limits-max-body-bytes default-limits) 'unbounded))
    (test-eqv "read buffer 16 KiB"        16384 (limits-read-buffer-size default-limits))
    (test-eqv "max connections 10 000"    10000 (limits-max-connections default-limits))
    (test-eqv "listen backlog 511"        511   (limits-backlog default-limits))
    (test-eq  "an HTTP/1.1 Host is required" #t   (limits-require-host? default-limits))
    (test-eqv "write high water 256 KiB outstanding" 262144 (limits-write-high-water default-limits))
    (test-eqv "write low water 64 KiB outstanding" 65536 (limits-write-low-water default-limits))
    (test-eqv "drain 10 s after a shutdown is asked for" 10000 (limits-drain-timeout-ms default-limits))

    ;; --- default-limits is exactly the empty environment (one code path) ---
    ;; Every field, so a default that moves in one place and not the other is
    ;; caught whichever field it is; each new limit extends this guard.
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
                  "CHEZ_HTTP_MAX_BODY_BYTES"
                  "CHEZ_HTTP_READ_BUFFER_SIZE" "CHEZ_HTTP_MAX_CONNECTIONS"
                  "CHEZ_HTTP_BACKLOG" "CHEZ_HTTP_REQUIRE_HOST"
                  "CHEZ_HTTP_WRITE_HIGH_WATER" "CHEZ_HTTP_WRITE_LOW_WATER"
                  "CHEZ_HTTP_DRAIN_TIMEOUT")
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

    ;; --- the write timeout in seconds, the tick in milliseconds ---
    ;; Made inside the check, so a reader that refuses them fails the check.
    (test-equal "write 90 s -> 90000 ms; the tick is given in ms: 100 -> 100 ms"
                '(90000 100)
                (let ((L (limits-from-environment
                          (env '("CHEZ_HTTP_WRITE_TIMEOUT" . "90") '("CHEZ_HTTP_TICK_MS" . "100")))))
                  (list (limits-write-timeout-ms L) (limits-tick-ms L))))

    ;; --- the drain timeout in whole seconds ---
    ;; Made inside the check, so a reader that refuses them fails the check.
    ;; A drain of 0 s is accepted: its deadline is the shutdown's own instant.
    (test-equal "drain 3 s -> 3000 ms, and 0 s -> 0 ms; below 0, or not a number, is refused"
                '(3000 0 faulted faulted)
                (map (lambda (value)
                       (guard (e (#t 'faulted))
                         (limits-drain-timeout-ms
                          (limits-from-environment (env (cons "CHEZ_HTTP_DRAIN_TIMEOUT" value))))))
                     '("3" "0" "-1" "soon")))

    ;; --- the write water marks, in bytes ---
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

    ;; --- no pipeline cap: CHEZ_HTTP_PIPELINE_CAP is not read, whatever it
    ;; holds, a malformed value among them.
    (let ((defaults (map (lambda (field) (field default-limits)) all-fields)))
      (test-equal "CHEZ_HTTP_PIPELINE_CAP is not read: whatever it holds, the limits are default-limits, field by field"
                  (list defaults defaults defaults defaults)
                  (map (lambda (value)
                         (guard (e (#t 'faulted))
                           (let ((L (limits-from-environment
                                     (env (cons "CHEZ_HTTP_PIPELINE_CAP" value)))))
                             (map (lambda (field) (field L)) all-fields))))
                       '("1" "2" "-3" "many"))))

    ;; --- a malformed value faults rather than silently defaulting ---
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

    ;; --- a numeric value is ASCII digits alone ---
    ;; Each variable alone, so a refusal can only be its own.
    (test-equal "a timeout not in ASCII digits alone is refused, naming its variable, for each of the six"
                (refused-for timeout-variables)
                (map (lambda (variable) (map (lambda (value) (set-alone variable value)) malformed))
                     timeout-variables))
    (test-equal "the tick, a size or a count not in ASCII digits alone is refused, naming its variable, for each of the eleven"
                (refused-for count-variables)
                (map (lambda (variable) (map (lambda (value) (set-alone variable value)) malformed))
                     count-variables))
    (test-equal "a body cap not in ASCII digits alone, nor unbounded, is refused, naming CHEZ_HTTP_MAX_BODY_BYTES"
                (refused-for (list body-variable))
                (list (map (lambda (value) (set-alone body-variable value)) malformed)))
    (test-equal "these checks cover every variable read but the Host switch"
                (list-sort string<? (remove "CHEZ_HTTP_REQUIRE_HOST" limits-environment-variables))
                (list-sort string<? (map car (append timeout-variables count-variables (list body-variable)))))
    (test-equal "leading zeros are digits too: 007 s is 7000 ms, a tick of 0100 is 100 ms, a body cap of 00 is 0 bytes"
                '(7000 100 0)
                (list (set-alone (car timeout-variables) "007")
                      (set-alone (car count-variables) "0100")
                      (set-alone body-variable "00")))

    ;; --- where the server listens ---
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
    (test-equal "a port not in ASCII digits alone is refused, naming CHEZ_HTTP_PORT: #x1F90 is not 8080"
                (cons '(refused "CHEZ_HTTP_PORT")
                      (map (lambda (value) '(refused "CHEZ_HTTP_PORT")) malformed))
                (cons (port-alone "#x1F90") (map port-alone malformed)))
    (test-eqv "a port's leading zeros are digits too: 08080 is 8080" 8080 (port-alone "08080"))

    ;; --- how long each kind of deadline lasts ---
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
                  max-header-value-bytes max-target-bytes max-body-bytes
                  read-buffer-size max-connections backlog require-host?
                  write-high-water write-low-water drain-timeout-ms)
                (map car (filter alone? named-fields)))
    (test-equal "and several at once"
                '(1 128 #f)
                (let ((L (limits-with default-limits
                                      '((require-host? . #f) (max-connections . 1) (backlog . 128)))))
                  (list (limits-max-connections L) (limits-backlog L) (limits-require-host? L))))
    (test-eq "a name that is not a field is refused" 'refused
             (guard (e ((assertion-violation? e) 'refused))
               (limits-with default-limits '((max-conections . 1)))
               'accepted))
    (test-eq "pipeline-cap is a field no more: limits-with refuses it" 'refused
             (guard (e ((assertion-violation? e) 'refused))
               (limits-with default-limits '((pipeline-cap . 1)))
               'accepted))))
