#!r6rs
;;; (m7 scheduler) — M7's spike, 2026-10-02: the smallest two-level
;;; scheduler (design §5.2; decision 0003 item 2), to price a handler run on
;;; a coroutine before M7.1 decides how a handler comes to run on one.  Not
;;; M7.1's library: one scheduler per process, and only the phase checked.
;;;
;;; A coroutine is a thunk run on a one-shot continuation (`call/1cc`) the
;;; scheduler enters.  It parks by capturing its own and jumping to the
;;; scheduler's, and ends by jumping to the scheduler's current one, never by
;;; returning into a resume already used (design §5.3, R3).  `drain-ready!`
;;; resumes each coroutine ready as it begins, oldest first; `turn!` is the
;;; drain, then one poll, in 'once when nothing is ready and 'nowait when
;;; something is, with the phase 'in-uv-run around it.
;;;
;;; Made plain (`(plain! #t)`), a drain calls each thunk in place, on the
;;; scheduler's own stack, with no continuation: the spike's control, the
;;; handler deferred to the drain with no coroutine.  Made to drain all
;;; (`(drain-all! #t)`), a drain runs on until nothing is ready, those made
;;; ready while it ran included, rather than stopping at those ready as it
;;; began (design §4's sketch): a producer that answers at once is then
;;; asked again in the same drain, as the libuv shell asks it in place.
(library (m7 scheduler)
  (export spawn! park! wake! drain-ready! ready? turn! phase phase-set! current-coroutine plain!
          drain-all!)
  (import (rnrs) (only (chezscheme) call/1cc))

  (define-record-type coroutine (fields (mutable k) (mutable value) thunk))

  (define front '())               ; the ready queue: front in order, back reversed
  (define back '())
  (define waiting 0)               ; how many are ready
  (define sched-k #f)              ; the scheduler's continuation, taken at each resume
  (define current #f)              ; the coroutine running, or #f
  (define the-phase 'scheduling)
  (define plain? #f)               ; whether a drain calls each thunk in place
  (define all? #f)                 ; whether a drain runs until nothing is ready

  ;; plain! : Boolean -> Void — whether later drains call each thunk in place.
  (define (plain! on?) (set! plain? on?))

  ;; drain-all! : Boolean -> Void — whether later drains run until nothing is ready.
  (define (drain-all! on?) (set! all? on?))

  ;; phase : -> Symbol ; phase-set! : Symbol -> Void
  (define (phase) the-phase)
  (define (phase-set! p) (set! the-phase p))

  ;; current-coroutine : -> (U Coroutine #f)
  (define (current-coroutine) current)

  ;; ready? : -> Boolean — whether a coroutine waits to run.
  (define (ready?) (fx>? waiting 0))

  (define (push! c)
    (set! back (cons c back))
    (set! waiting (fx+ waiting 1)))

  (define (pop!)
    (when (null? front)
      (set! front (reverse back))
      (set! back '()))
    (let ((c (car front)))
      (set! front (cdr front))
      (set! waiting (fx- waiting 1))
      c))

  ;; spawn! : (-> Any) -> Void — `thunk` on a coroutine of its own, run from
  ;; the next drain.
  (define (spawn! thunk) (push! (make-coroutine #f #f thunk)))

  ;; wake! : Coroutine Any -> Void — a parked coroutine made ready, `v` what
  ;; its park! answers.
  (define (wake! c v)
    (coroutine-value-set! c v)
    (push! c))

  ;; drain-ready! : -> Void — resume each coroutine ready as it begins, and
  ;; made to drain all, then each made ready since, until none is.
  (define (drain-ready!)
    (let loop ((n waiting))
      (cond ((fx>? n 0) (resume! (pop!)) (loop (fx- n 1)))
            ((and all? (fx>? waiting 0)) (loop waiting)))))

  ;; resume! : Coroutine -> Void — run it to its next park or its end.
  (define (resume! c)
    (unless (eq? the-phase 'scheduling)
      (assertion-violation 'resume! "a resume outside the scheduler" the-phase))
    (if plain? ((coroutine-thunk c)) (enter! c)))

  (define (enter! c)
    (set! current c)
    (call/1cc
     (lambda (k)
       (set! sched-k k)
       (let ((k0 (coroutine-k c)))
         (if k0
             (begin (coroutine-k-set! c #f) (k0 (coroutine-value c)))
             (begin ((coroutine-thunk c)) (sched-k 'finished))))))
    (set! current #f))

  ;; park! : -> Any — park the running coroutine until wake! is given it,
  ;; answering what wake! was.
  (define (park!)
    (unless (eq? the-phase 'scheduling)
      (assertion-violation 'park! "a park outside the scheduler" the-phase))
    (let ((c current))
      (unless c (assertion-violation 'park! "no coroutine runs"))
      (call/1cc (lambda (k) (coroutine-k-set! c k) (sched-k 'parked)))))

  ;; turn! : (Symbol -> Any) -> Any
  ;; The drain, then `poll!` in 'once when nothing is ready and 'nowait when
  ;; something is, the phase 'in-uv-run around it: what it answers.
  (define (turn! poll!)
    (drain-ready!)
    (let ((mode (if (ready?) 'nowait 'once)))
      (dynamic-wind
       (lambda () (set! the-phase 'in-uv-run))
       (lambda () (poll! mode))
       (lambda () (set! the-phase 'scheduling))))))
