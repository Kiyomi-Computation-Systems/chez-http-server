#!r6rs
;;; (http-server private serve) — the process's edge: a server started from
;;; the environment, its log, and its loop run.
;;;
;;; `serve` is what the facade gives an embedder: a server on a loop of its
;;; own, configured through the process's environment (the Twelve-Factor App's
;;; config), logging a line for each thing that happens on standard output
;;; (its logs), and run until it stops: once the process is sent SIGTERM or
;;; SIGINT, or its listener fails, the server drains, and `serve` returns when
;;; the drain ends.
;;;
;;; THE START (`start-server`) reads the settings through a lookup, as the
;;; limits are read ((http-server limits)): the limits, and where the server
;;; listens, CHEZ_HTTP_HOST and CHEZ_HTTP_PORT.  A malformed setting is
;;; refused before anything listens, as an &http-server-config-error composed
;;; with what refused it, whose irritants name the variable.  A host that is
;;; not an IPv4 or IPv6 literal is refused by the listener's bind, and is a
;;; config error too; the shell has closed the listener by then.  A server
;;; that listens logs `listening`, with its host and port, the kernel's choice
;;; for port 0.  `serve` watches the process's signals before that line, so a
;;; supervisor that signals the moment it reads it finds them watched.
;;;
;;; THE CONDITIONS:
;;;
;;;   &http-server-error < &error
;;;     └── &http-server-config-error   ; a malformed setting at startup
;;;
;;; No condition carries a handler's failure: a handler's raise is answered
;;; 500 and logged as `handler-failed`, and never reaches the embedder.
;;;
;;; THE LOG (`log-line`) writes each thing that happens as one line on
;;; standard output, flushed at once: what happened, then each detail after
;;; a space.  A condition reads as Chez's `display-condition` shows it, its
;;; line breaks made spaces; a record reads as its kind, `#<connection>`, so
;;; a line never spells out a connection's state; a string, a symbol, a
;;; number, a boolean or a character is displayed; anything else is written.
(library (http-server private serve)
  (export serve start-server run-until-stopped! log-line
          &http-server-error http-server-error?
          &http-server-config-error http-server-config-error?)
  (import (rnrs)
          (only (chezscheme) getenv display-condition)
          (libuv)
          (only (http-server limits) limits-from-environment address-from-environment)
          (only (http-server server) server-phase)
          (only (http-server private shell)
                make-shell shell-listen! shell-turn! shell-run-turns! shell-watch-signals! shell-call-deferred!
                shell-server wall-clock))

  ;; &http-server-error : the condition type of the server's own errors.
  ;; http-server-error? : Any -> Boolean
  (define-condition-type &http-server-error &error
    make-http-server-error http-server-error?)

  ;; &http-server-config-error : a malformed setting at startup.
  ;; http-server-config-error? : Any -> Boolean
  (define-condition-type &http-server-config-error &http-server-error
    make-http-server-config-error http-server-config-error?)

  ;; serve : (Request -> (U Answer Switch)) [(String -> (U String #f))] -> Void
  ;; Answer as (http-server awaiting) defines it, Switch as (http-server switch).
  ;; Serve `handler` where the environment says, logging on standard output,
  ;; until the server stops: it drains once the process is sent SIGTERM or
  ;; SIGINT, or its listener fails, and `serve` returns when the drain ends,
  ;; whatever waits are still armed: the loop's teardown closes their timers
  ;; and cancels the lookups not yet begun, but one already running holds it
  ;; until the lookup answers.  A taker's calls deferred to a turn are made
  ;; before it returns (run-until-stopped!).
  ;; `lookup` stands in for the process's environment, as `getenv` does by
  ;; default.  A malformed setting raises &http-server-config-error before
  ;; anything listens.  The signals are watched before `listening` is
  ;; logged; one sent before that meets what the process does with it, by
  ;; default ending it, before anything is served.
  (define serve
    (case-lambda
      ((handler) (serve handler getenv))
      ((handler lookup)
       (call-with-uv-loop
        (lambda (loop)
          (run-until-stopped! (start-server loop handler lookup log-line shell-watch-signals!)))))))

  ;; run-until-stopped! : Shell -> Void
  ;; Turn the shell's loop until its server stops, then make the taker's
  ;; calls still deferred to a turn (shell-call-deferred!): `serve`'s run, on
  ;; a loop its caller owns.  So the `done` of a taker's write refused as the
  ;; server stops is told before the run returns.
  (define (run-until-stopped! sh)
    (shell-run-turns! sh (lambda () (not (eq? (server-phase (shell-server sh)) 'stopped))))
    (shell-call-deferred! sh))

  ;; start-server : UvLoop (Request -> Response) (String -> (U String #f))
  ;;                (Symbol (Listof Any) -> Any) [(Shell -> Any)] -> Shell
  ;; A server on `loop`, serving `handler`, configured through `lookup` and
  ;; logging to `log`, listening where `lookup` says: the start `serve`
  ;; makes, on a loop the caller runs.  Once it listens, it calls `ready`
  ;; with the shell, if given, and then logs `listening` with the host and
  ;; the port it listens on: `serve` watches the process's signals there.
  (define start-server
    (case-lambda
      ((loop handler lookup log) (start-server loop handler lookup log (lambda (sh) #f)))
      ((loop handler lookup log ready)
       (let-values (((limits host port) (settings lookup)))
         (let* ((sh (make-shell loop handler limits wall-clock log))
                (bound (guard (e ((bad-address? e)
                                  (raise (condition
                                          (make-http-server-config-error)
                                          (make-message-condition
                                           "CHEZ_HTTP_HOST is not an IPv4 or IPv6 literal")
                                          (make-irritants-condition (list "CHEZ_HTTP_HOST" host))
                                          e))))
                         (shell-listen! sh host port))))
           (ready sh)
           (log 'listening (list host bound))
           sh)))))

  ;; settings : (String -> (U String #f)) -> (values Limits String Nat)
  ;; The limits and the address `lookup` gives.  What the pure parsers refuse,
  ;; an assertion violation naming the variable, is raised again as an
  ;; &http-server-config-error composed with it.
  (define (settings lookup)
    (guard (e ((assertion-violation? e)
               (raise (condition (make-http-server-config-error) e))))
      (let ((limits (limits-from-environment lookup)))
        (let-values (((host port) (address-from-environment lookup)))
          (values limits host port)))))

  ;; bad-address? : Any -> Boolean — chez-libuv's refusal of a host that is
  ;; not an IP literal, at the bind.
  (define (bad-address? e)
    (and (uv-invalid-argument? e) (eq? (uv-invalid-argument-reason e) 'bad-address)))

  ;; log-line : Symbol (Listof Any) -> Void
  ;; One line on standard output, flushed at once: `what`, then each detail
  ;; after a space, as the library's header says.
  (define (log-line what details)
    (let ((out (current-output-port)))
      (display what out)
      (for-each (lambda (d) (put-char out #\space) (put-detail out d)) details)
      (newline out)
      (flush-output-port out)))

  ;; put-detail : OutputPort Any -> Void
  (define (put-detail out d)
    (cond ((condition? d) (put-string out (one-line (condition-text d))))
          ((or (string? d) (symbol? d) (number? d) (boolean? d) (char? d)) (display d out))
          ((record? d)
           (put-string out "#<")
           (display (record-type-name (record-rtd d)) out)
           (put-string out ">"))
          (else (write d out))))

  ;; condition-text : Condition -> String — as `display-condition` shows it.
  (define (condition-text c)
    (call-with-string-output-port (lambda (p) (display-condition c p))))

  ;; one-line : String -> String — its line breaks made spaces.
  (define (one-line s)
    (list->string (map (lambda (c) (if (char=? c #\newline) #\space c)) (string->list s)))))
