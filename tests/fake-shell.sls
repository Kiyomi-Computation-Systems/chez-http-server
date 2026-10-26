#!r6rs
;;; (fake-shell) — the fake shell, by the name the suites import it by.
;;;
;;; The harness is (http-server private fake-shell), in
;;; src/http-server/private/fake-shell.sls, where the package installs
;;; it.  This library re-exports what the suites import, by the name
;;; they import it by.
(library (fake-shell)
  (export make-fake-shell fake-shell?
          fake-shell-state fake-shell-now
          fake-shell-actions fake-shell-events fake-shell-violations
          fake-shell-advance! fake-shell-deliver! fake-shell-tick! fake-shell-fire! fake-shell-run!
          make-fake-connection fake-shell-conn-state fake-shell-reading? drops-body
          fake-shell-deliver-later! fake-shell-settle! fake-shell-feed-input!
          fake-shell-writes fake-shell-date-writes! written-status write-wire
          fake-shell-fire-waits! fake-shell-answer-lookup! fake-shell-drain! fake-shell-armed
          event->door-read door-read->event
          fake-shell-shut? fake-shell-hold! fake-shell-schedule! fake-shell-taker-failures
          fake-shell-done-failures)
  (import (http-server private fake-shell)))
