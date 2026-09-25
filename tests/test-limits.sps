#!r6rs
;;; (http-server limits): decision 0005's defaults and the environment
;;; overrides.  Oracle: decision 0005 (the nginx-style bounded defaults) and
;;; the documented override convention (seconds for timeouts), and its
;;; amendment of 2026-09-25: the Host requirement is on unless
;;; CHEZ_HTTP_REQUIRE_HOST is exactly "false".
(import (rnrs) (srfi :64) (testing) (http-server limits))

;; Every accessor, in field order.
(define all-fields
  (list limits-read-header-timeout-ms limits-idle-timeout-ms
        limits-body-inactivity-timeout-ms limits-max-header-bytes
        limits-max-header-count limits-max-header-field-bytes
        limits-max-header-value-bytes limits-max-target-bytes
        limits-max-body-bytes limits-pipeline-cap limits-read-buffer-size
        limits-require-host?))

(run-suite "limits"
  (lambda ()
    ;; --- defaults (decision 0005) ---
    (test-eqv "read-header default 60 s"  60000 (limits-read-header-timeout-ms default-limits))
    (test-eqv "idle default 75 s"         75000 (limits-idle-timeout-ms default-limits))
    (test-eqv "body-inactivity 60 s"      60000 (limits-body-inactivity-timeout-ms default-limits))
    (test-eqv "max header bytes 16 KiB"   16384 (limits-max-header-bytes default-limits))
    (test-eqv "max header count 100"      100   (limits-max-header-count default-limits))
    (test-eqv "max header field 8 KiB"    8192  (limits-max-header-field-bytes default-limits))
    (test-eqv "max header value 8 KiB"    8192  (limits-max-header-value-bytes default-limits))
    (test-eqv "max target bytes 8 KiB"    8192  (limits-max-target-bytes default-limits))
    (test-eq  "bodies stream unbounded"   'unbounded
              (or (limits-max-body-bytes default-limits) 'unbounded))
    (test-eqv "pipeline cap 1"            1     (limits-pipeline-cap default-limits))
    (test-eqv "read buffer 16 KiB"        16384 (limits-read-buffer-size default-limits))
    (test-eq  "an HTTP/1.1 Host is required" #t   (limits-require-host? default-limits))

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
                  "CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT" "CHEZ_HTTP_MAX_HEADER_BYTES"
                  "CHEZ_HTTP_MAX_HEADER_COUNT" "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES"
                  "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES" "CHEZ_HTTP_MAX_TARGET_BYTES"
                  "CHEZ_HTTP_MAX_BODY_BYTES" "CHEZ_HTTP_PIPELINE_CAP"
                  "CHEZ_HTTP_READ_BUFFER_SIZE" "CHEZ_HTTP_REQUIRE_HOST")
                limits-environment-variables)

    ;; --- overrides: timeouts are seconds -> ms; sizes/counts as given ---
    (let ((L (limits-from-environment
               (lambda (name)
                 (cond ((string=? name "CHEZ_HTTP_IDLE_TIMEOUT") "30")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_BYTES") "4096")
                       ((string=? name "CHEZ_HTTP_MAX_BODY_BYTES") "1048576")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_FIELD_BYTES") "256")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_VALUE_BYTES") "512")
                       (else #f))))))
      (test-eqv "idle 30 s -> 30000 ms" 30000   (limits-idle-timeout-ms L))
      (test-eqv "header bytes overridden" 4096   (limits-max-header-bytes L))
      (test-eqv "body cap overridden"     1048576 (limits-max-body-bytes L))
      (test-eqv "header field overridden" 256    (limits-max-header-field-bytes L))
      (test-eqv "header value overridden" 512    (limits-max-header-value-bytes L))
      ;; an untouched field keeps its default
      (test-eqv "untouched read-header keeps default" 60000
                (limits-read-header-timeout-ms L)))

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
    (test-eq "a non-numeric size is refused" 'faulted
             (guard (e (#t 'faulted))
               (limits-from-environment
                 (lambda (name) (if (string=? name "CHEZ_HTTP_MAX_HEADER_BYTES") "big" #f)))
               'no-fault))))
