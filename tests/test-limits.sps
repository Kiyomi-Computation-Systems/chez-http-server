#!r6rs
;;; (http-server limits): decision 0005's defaults and the environment
;;; overrides.  Oracle: decision 0005 (the nginx-style bounded defaults) and
;;; the documented override convention (seconds for timeouts).
(import (rnrs) (srfi :64) (testing) (http-server limits))

(run-suite "limits"
  (lambda ()
    ;; --- defaults (decision 0005) ---
    (test-eqv "read-header default 60 s"  60000 (limits-read-header-timeout-ms default-limits))
    (test-eqv "idle default 75 s"         75000 (limits-idle-timeout-ms default-limits))
    (test-eqv "body-inactivity 60 s"      60000 (limits-body-inactivity-timeout-ms default-limits))
    (test-eqv "max header bytes 16 KiB"   16384 (limits-max-header-bytes default-limits))
    (test-eqv "max header count 100"      100   (limits-max-header-count default-limits))
    (test-eqv "max target bytes 8 KiB"    8192  (limits-max-target-bytes default-limits))
    (test-eq  "bodies stream unbounded"   'unbounded
              (or (limits-max-body-bytes default-limits) 'unbounded))
    (test-eqv "pipeline cap 1"            1     (limits-pipeline-cap default-limits))
    (test-eqv "read buffer 16 KiB"        16384 (limits-read-buffer-size default-limits))

    ;; --- default-limits is exactly the empty environment (one code path) ---
    (let ((empty (limits-from-environment (lambda (name) #f))))
      (test-eqv "empty env == default idle"
                (limits-idle-timeout-ms default-limits) (limits-idle-timeout-ms empty))
      (test-eqv "empty env == default read-buffer"
                (limits-read-buffer-size default-limits) (limits-read-buffer-size empty)))

    ;; --- overrides: timeouts are seconds -> ms; sizes/counts as given ---
    (let ((L (limits-from-environment
               (lambda (name)
                 (cond ((string=? name "CHEZ_HTTP_IDLE_TIMEOUT") "30")
                       ((string=? name "CHEZ_HTTP_MAX_HEADER_BYTES") "4096")
                       ((string=? name "CHEZ_HTTP_PIPELINE_CAP") "8")
                       ((string=? name "CHEZ_HTTP_MAX_BODY_BYTES") "1048576")
                       (else #f))))))
      (test-eqv "idle 30 s -> 30000 ms" 30000   (limits-idle-timeout-ms L))
      (test-eqv "header bytes overridden" 4096   (limits-max-header-bytes L))
      (test-eqv "pipeline cap overridden" 8      (limits-pipeline-cap L))
      (test-eqv "body cap overridden"     1048576 (limits-max-body-bytes L))
      ;; an untouched field keeps its default
      (test-eqv "untouched read-header keeps default" 60000
                (limits-read-header-timeout-ms L)))

    ;; --- the literal "unbounded" clears the body cap ---
    (let ((L (limits-from-environment
               (lambda (name)
                 (if (string=? name "CHEZ_HTTP_MAX_BODY_BYTES") "unbounded" #f)))))
      (test-eq "unbounded clears the body cap" 'cleared
               (or (limits-max-body-bytes L) 'cleared)))

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
