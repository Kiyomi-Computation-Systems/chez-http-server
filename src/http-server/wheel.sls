#!r6rs
;;; (http-server wheel) — the deadlines a loop's connections arm, kept in
;;; tick-ms buckets: a hashed timing wheel (decision 0005 and its amendment
;;; of 2026-09-27; design §2).
;;;
;;; PURE functional core: imports only (rnrs), and reads no clock.  Every
;;; instant is a whole number of milliseconds the caller gives, from a clock
;;; that never steps: in the libuv shell the loop's own (uv_now), never the
;;; wall clock the Date line is made from.  The shell arms an entry at its now
;;; plus a limit, and advances the wheel to its now once a tick.  Like the
;;; connection core's state, a wheel is linear: its procedures update it in
;;; place.
;;;
;;; ENTRIES ARE THE CALLER'S (decided 2026-09-27).  A key, such as a
;;; connection, has one entry, made once and kept as long as the key can have
;;; a deadline, and armed in one wheel at a time.  Arming, moving and
;;; disarming only link and unlink it, so none allocates.  One entry per key
;;; is the caller's to keep: two entries are two deadlines.  An armed entry
;;; holds its key until it fires or is disarmed, so a key that is done with
;;; has its entry disarmed; a disarmed entry holds nothing of the wheel.
;;;
;;; THE CONTRACT.  An advance to `now` fires, and disarms, exactly the entries
;;; whose deadlines are at or before `now`, and returns their keys.  So a
;;; caller that advances every tick-ms fires a deadline of D within [D, D +
;;; tick-ms], never before D (0005).  The keys come back already disarmed: a
;;; caller that stops partway through them arms again the ones it did not
;;; act on.
;;;
;;; THE INDEX.  A deadline D lies in bucket (div D tick-ms), and bucket b in
;;; slot (mod b slots), so a slot holds one bucket of every revolution.  The
;;; cursor is the furthest bucket an advance has reached.  Every armed entry
;;; lies in the slot of a bucket at or after the cursor: its deadline's
;;; bucket, or the cursor's when that bucket had already passed as it was
;;; armed.  So an advance visits the slots of the buckets from the cursor's to
;;; now's (the cursor's alone when now is behind it), and every slot once when
;;; there are more buckets than slots, and meets every deadline at or before
;;; `now`.  It fires by each entry's own deadline, never by its bucket, so a
;;; deadline later in now's bucket, or a revolution ahead, stays armed.  Each
;;; slot is a doubly linked ring headed by a sentinel entry.
(library (http-server wheel)
  (export make-wheel wheel? wheel-tick-ms wheel-count
          make-wheel-entry wheel-entry? wheel-entry-key wheel-entry-deadline
          wheel-arm! wheel-disarm! wheel-advance!)
  (import (rnrs))

  ;; make-wheel-entry : Any -> WheelEntry — `key`'s entry, not armed.
  ;; wheel-entry? : Any -> Boolean
  ;; wheel-entry-key : WheelEntry -> Any — what an advance returns as it fires.
  ;; An armed entry is linked into its slot's ring.  A disarmed one has no
  ;; links, and keeps its last deadline unread.  A ring's sentinel is an entry
  ;; too, never armed or fired.
  (define-record-type (entry make-wheel-entry wheel-entry?)
    (fields (immutable key wheel-entry-key)
            (mutable deadline entry-deadline entry-deadline-set!)
            (mutable prev entry-prev entry-prev-set!)
            (mutable next entry-next entry-next-set!))
    (protocol (lambda (new) (lambda (key) (new key #f #f #f))))
    (sealed #t))

  ;; wheel? : Any -> Boolean
  ;; wheel-tick-ms : Wheel -> Positive-Integer — its buckets' width.
  ;; wheel-count : Wheel -> Nat — how many entries are armed.  At 0 the shell
  ;; stops its tick timer (0005).
  ;; (All three are generated here; make-wheel, below, builds one.)
  (define-record-type (wheel %make-wheel wheel?)
    (fields (immutable tick-ms wheel-tick-ms)
            (immutable slots wheel-slots)
            (mutable count wheel-count wheel-count-set!)
            (mutable cursor wheel-cursor wheel-cursor-set!))
    (sealed #t))

  ;; 512 slots: the longest default deadline, the idle one's 75 s, is 300
  ;; ticks of 250 ms, so no default deadline shares a slot with one a
  ;; revolution later.
  (define default-slots 512)

  ;; whole! : Symbol Any Nat -> Void
  ;; Refuse what is not an exact integer of at least `least`.
  (define (whole! who x least)
    (unless (and (integer? x) (exact? x) (>= x least))
      (assertion-violation who "expected an exact integer of at least" least x)))

  ;; entry! : Symbol Any -> Void — refuse what is not an entry.
  (define (entry! who e)
    (unless (wheel-entry? e)
      (assertion-violation who "expected a wheel entry" e)))

  ;; make-ring : -> Entry — an empty slot: a sentinel linked to itself.
  (define (make-ring)
    (let ((s (make-wheel-entry #f)))
      (entry-prev-set! s s)
      (entry-next-set! s s)
      s))

  ;; make-wheel : Positive-Integer [Positive-Integer] -> Wheel
  ;; An empty wheel whose buckets are tick-ms wide, with `slots` slots (512
  ;; unless given).  Its cursor starts at bucket 0.
  (define make-wheel
    (case-lambda
      ((tick-ms) (make-wheel tick-ms default-slots))
      ((tick-ms slots)
       (whole! 'make-wheel tick-ms 1)
       (whole! 'make-wheel slots 1)
       (let ((rings (make-vector slots)))
         (do ((i 0 (+ i 1))) ((= i slots))
           (vector-set! rings i (make-ring)))
         (%make-wheel tick-ms rings 0 0)))))

  ;; wheel-entry-deadline : WheelEntry -> (U Nat #f) — its deadline while it
  ;; is armed; #f while it is not.
  (define (wheel-entry-deadline e)
    (entry! 'wheel-entry-deadline e)
    (and (entry-next e) (entry-deadline e)))

  ;; link-last! : Wheel Entry Entry -> Void — arm `e` at the end of `ring`,
  ;; so a ring keeps the order its entries were armed in.
  (define (link-last! w ring e)
    (let ((last (entry-prev ring)))
      (entry-prev-set! e last)
      (entry-next-set! e ring)
      (entry-next-set! last e)
      (entry-prev-set! ring e))
    (wheel-count-set! w (+ (wheel-count w) 1)))

  ;; unlink! : Wheel Entry -> Void — disarm `e`, and clear its links, so an
  ;; entry its caller keeps holds nothing of the ring it left.
  (define (unlink! w e)
    (let ((prev (entry-prev e)) (next (entry-next e)))
      (entry-next-set! prev next)
      (entry-prev-set! next prev))
    (entry-prev-set! e #f)
    (entry-next-set! e #f)
    (wheel-count-set! w (- (wheel-count w) 1)))

  ;; ring-for : Wheel Nat -> Entry — the ring a deadline is kept in: its
  ;; bucket's slot's, or the cursor's when its bucket has passed.
  (define (ring-for w deadline)
    (let ((rings (wheel-slots w)))
      (vector-ref rings (mod (max (div deadline (wheel-tick-ms w)) (wheel-cursor w))
                             (vector-length rings)))))

  ;; wheel-arm! : Wheel WheelEntry Nat -> Void
  ;; Arm `e` at `deadline`, moving the deadline it had, if any.
  (define (wheel-arm! w e deadline)
    (entry! 'wheel-arm! e)
    (whole! 'wheel-arm! deadline 0)
    (when (entry-next e) (unlink! w e))
    (entry-deadline-set! e deadline)
    (link-last! w (ring-for w deadline) e))

  ;; wheel-disarm! : Wheel WheelEntry -> Void
  ;; Disarm `e`; an entry not armed is left as it is.
  (define (wheel-disarm! w e)
    (entry! 'wheel-disarm! e)
    (when (entry-next e) (unlink! w e)))

  ;; take-due! : Wheel Entry Nat (Listof Entry) -> (Listof Entry)
  ;; Disarm each entry of the ring whose deadline is at or before `now`,
  ;; consing it onto `due`.
  (define (take-due! w ring now due)
    (let walk ((e (entry-next ring)) (due due))
      (if (eq? e ring)
          due
          (let ((next (entry-next e)))
            (cond ((<= (entry-deadline e) now)
                   (unlink! w e)
                   (walk next (cons e due)))
                  (else (walk next due)))))))

  ;; earlier? : Entry Entry -> Boolean
  (define (earlier? a b)
    (< (entry-deadline a) (entry-deadline b)))

  ;; wheel-advance! : Wheel Nat -> (Listof Any)
  ;; The keys of the entries whose deadlines are at or before `now`, each
  ;; disarmed: the earliest deadline first, and equal ones in the order they
  ;; were last armed.  (Equal deadlines share a ring, which keeps its arming
  ;; order, and list-sort is stable.)  A `now` behind the cursor fires what is
  ;; due by it and leaves the cursor where it was.
  (define (wheel-advance! w now)
    (whole! 'wheel-advance! now 0)
    (let* ((rings (wheel-slots w))
           (n (vector-length rings))
           (cursor (wheel-cursor w))
           (last (max cursor (div now (wheel-tick-ms w)))))
      (let visit ((b cursor) (due '()))
        (if (and (<= b last) (< (- b cursor) n))
            (visit (+ b 1) (take-due! w (vector-ref rings (mod b n)) now due))
            (begin
              (wheel-cursor-set! w last)
              (map wheel-entry-key (list-sort earlier? (reverse due)))))))))
