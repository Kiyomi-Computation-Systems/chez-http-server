#!r6rs
;;; (http-server wheel): the deadlines a loop's connections arm, kept in
;;; tick-ms buckets.  M5.1.
;;;
;;; Oracles: decision 0005 and its amendment of 2026-09-27 — a deadline of D
;;; fires within [D, D + tick-ms], never before D, each deadline as now
;;; reaches it, and the tick timer stops when the wheel is empty — and a
;;; plain list of the armed deadlines, which says what an advance owes with no
;;; buckets at all.  The wheel is an index over that list, so it must fire
;;; what the list fires whatever its tick and however few slots it has.  The
;;; entries are the caller's (decided 2026-09-27), so one the caller keeps
;;; disarmed must hold nothing of the wheel: a weak pointer sees it, beside an
;;; entry the wheel still holds, seen held.  The clock is the test's own:
;;; every instant is a number of milliseconds it gives, and no test sleeps
;;; (global-constraints).
(import (rnrs) (srfi :64) (testing) (http-server wheel)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object?))

;; fired-at : Wheel (Listof (Pair Key Nat)) Nat Nat -> (Listof (Pair Key (Listof Nat)))
;; Arm an entry for each key at its deadline, then advance every tick-ms
;; from `start` through `end`: each key with the instants it fired at, in
;; the order given.
(define (fired-at wheel armed start end)
  (let ((times (make-eq-hashtable)))
    (for-each (lambda (a) (wheel-arm! wheel (make-wheel-entry (car a)) (cdr a))) armed)
    (let tick ((now start))
      (when (<= now end)
        (for-each (lambda (key)
                    (hashtable-update! times key (lambda (ts) (cons now ts)) '()))
                  (wheel-advance! wheel now))
        (tick (+ now (wheel-tick-ms wheel)))))
    (map (lambda (a) (cons (car a) (reverse (hashtable-ref times (car a) '()))))
         armed)))

;; observe : ((Any -> Void) -> Any) -> (Listof Any)
;; Run `script`, handing it `see`, and return what it saw, in order.
(define (observe script)
  (let ((seen '()))
    (script (lambda (x) (set! seen (cons x seen))))
    (reverse seen)))

;; range : Nat Nat -> (Listof Nat) — from `from` through `to`.
(define (range from to)
  (if (> from to) '() (cons from (range (+ from 1) to))))

;; take : (Listof Any) Nat -> (Listof Any) — the first n.
(define (take xs n)
  (if (= n 0) '() (cons (car xs) (take (cdr xs) (- n 1)))))

;; sweep : Nat -> (U 'within (Pair (List Nat) (Listof Nat)))
;; Every deadline from 1000 to 3000 ms armed at once, keys fresh lists
;; holding them, and a tick every 250 ms from `start`: 'within when each
;; fired once, at or after its deadline and less than a tick after it; else
;; the first that did not, with the instants it fired at.
(define (sweep start)
  (let* ((armed (map (lambda (d) (cons (list d) d)) (range 1000 3000)))
         (off (filter (lambda (key+times)
                        (let ((d (caar key+times)) (times (cdr key+times)))
                          (not (and (= (length times) 1)
                                    (<= d (car times))
                                    (< (car times) (+ d 250))))))
                      (fired-at (make-wheel 250) armed start 3500))))
    (if (null? off) 'within (car off))))

;; weakly : Symbol Any -> (Pair Symbol WeakPair) — a named weak pointer.
(define (weakly name x) (cons name (weak-cons x '())))

;; after-collection : (Listof (Pair Symbol WeakPair)) -> (Listof (Pair Symbol Symbol))
;; Collect every generation, then say of each object whether anything still
;; holds it.
(define (after-collection weak)
  (collect (collect-maximum-generation))
  (map (lambda (w) (cons (car w) (if (bwp-object? (cadr w)) 'released 'held))) weak))

;; what-entries-hold : -> (List (Listof (Pair Symbol Symbol)) Nat (U Nat #f) (U Nat #f))
;; Two entries the caller keeps, one disarmed and one fired, each with a
;; neighbour after it in its ring that is then fired or disarmed, and
;; dropped; and one entry dropped while armed, which the wheel holds.  What a
;; full collection releases, then the wheel's count and the two kept
;; entries' deadlines, read after it so all three are held through it.
(define (what-entries-hold)
  (let ((w (make-wheel 250))
        (disarmed (make-wheel-entry 'disarmed))
        (fired (make-wheel-entry 'fired)))
    (let ((weak (let ((after-disarmed (make-wheel-entry 'after-disarmed))
                      (after-fired (make-wheel-entry 'after-fired))
                      (armed (make-wheel-entry 'armed)))
                  (wheel-arm! w disarmed 1000)
                  (wheel-arm! w after-disarmed 1001)
                  (wheel-arm! w fired 2000)
                  (wheel-arm! w after-fired 2001)
                  (wheel-arm! w armed 9000)
                  (wheel-disarm! w disarmed)
                  (wheel-advance! w 2000)
                  (wheel-disarm! w after-fired)
                  (list (weakly 'after-disarmed after-disarmed)
                        (weakly 'after-fired after-fired)
                        (weakly 'armed armed)))))
      (list (after-collection weak)
            (wheel-count w)
            (wheel-entry-deadline disarmed)
            (wheel-entry-deadline fired)))))

;; --- the plain list the wheel indexes ------------------------------------------
;; Each armed key as (key deadline order), `order` counting the arms before
;; its own, so that equal deadlines keep the order they were armed in.

;; model-disarm : Model Key -> Model
(define (model-disarm m key)
  (filter (lambda (e) (not (eq? (car e) key))) m))

;; model-due : Model Nat -> (values (Listof Key) Model)
;; The keys due by `now`, earliest deadline first and equal ones in the
;; order they were armed, and the entries left.
(define (model-due m now)
  (let-values (((due left) (partition (lambda (e) (<= (cadr e) now)) m)))
    (values (map car
                 (list-sort (lambda (a b)
                              (or (< (cadr a) (cadr b))
                                  (and (= (cadr a) (cadr b)) (< (caddr a) (caddr b)))))
                            due))
            left)))

;; make-random : Nat -> (Nat -> Nat)
;; The same numbers below n on every run: a linear congruential generator,
;; its top 15 bits drawn as many times as n needs, so any n is reached.
(define (make-random seed)
  (let ((x seed))
    (define (bits15)
      (set! x (mod (+ (* x 1103515245) 12345) 2147483648))
      (div x 65536))
    (lambda (n)
      (let draw ((value 0) (reach 1))
        (if (>= reach n)
            (mod value n)
            (draw (+ (* value 32768) (bits15)) (* reach 32768)))))))

(define model-keys '(k0 k1 k2 k3 k4 k5 k6 k7 k8 k9 k10 k11))

;; agrees : Nat (U Nat #f) Nat Nat -> (U 'agrees (Listof Any))
;; `steps` operations, the same on a wheel (`slots` #f for its default) and
;; on the plain list: arming a key's entry (mostly within 600 ticks,
;; sometimes up to 5,000 ahead, sometimes already past), disarming one, and
;; advancing (mostly by up to 2 ticks, sometimes up to 2,000, sometimes back
;; by less than one).  After each, the two must agree on what fired and how
;; many are armed, and at the end on every key's deadline.  'agrees, or
;; where they first differ.
(define (agrees tick slots seed steps)
  (let ((w (if slots (make-wheel tick slots) (make-wheel tick)))
        (random (make-random seed))
        (entries (list->vector (map make-wheel-entry model-keys))))
    (let loop ((i 0) (now 100000) (m '()) (order 0))
      (cond
        ((not (= (wheel-count w) (length m)))
         (list 'step i 'count (length m) (wheel-count w)))
        ((= i steps)
         (let ((expected (map (lambda (k) (let ((e (assq k m))) (and e (cadr e)))) model-keys))
               (got (map wheel-entry-deadline (vector->list entries))))
           (if (equal? expected got) 'agrees (list 'deadlines expected got))))
        (else
         (let* ((entry (vector-ref entries (random (vector-length entries))))
                (key (wheel-entry-key entry))
                (r (random 100)))
           (cond
             ((< r 40)
              (let ((d (max 0 (cond ((< r 5) (- now (random (* 50 tick))))
                                    ((< r 10) (+ now (random (* 5000 tick))))
                                    (else (+ now (random (* 600 tick))))))))
                (wheel-arm! w entry d)
                (loop (+ i 1) now (cons (list key d order) (model-disarm m key)) (+ order 1))))
             ((< r 50)
              (wheel-disarm! w entry)
              (loop (+ i 1) now (model-disarm m key) order))
             (else
              (let ((now (max 0 (cond ((< r 52) (- now (random tick)))
                                      ((< r 57) (+ now (random (* 2000 tick))))
                                      (else (+ now (random (* 2 tick))))))))
                (let-values (((due left) (model-due m now)))
                  (let ((fired (wheel-advance! w now)))
                    (if (equal? fired due)
                        (loop (+ i 1) now left order)
                        (list 'step i 'now now 'due due 'fired fired)))))))))))))

;; refused-by : (Pair Symbol (-> Any)) -> (U 'refused 'accepted (List 'refused-by Any))
;; 'refused if the thunk raises an assertion violation naming the procedure
;; it was given to, as the wheel's own checks do: a refusal met further in,
;; by another procedure, is not one.
(define (refused-by who+thunk)
  (guard (e ((assertion-violation? e)
             (if (and (who-condition? e) (eq? (condition-who e) (car who+thunk)))
                 'refused
                 (list 'refused-by (and (who-condition? e) (condition-who e))))))
    ((cdr who+thunk))
    'accepted))

(run-suite "wheel"
  (lambda ()
    ;; --- when a deadline fires: at the first tick at or after it ---
    (test-equal "a deadline fires at the first tick at or after it, never before: ticks on bucket boundaries"
                '((long-past 1000) (just-past 1000) (due 1000) (a-ms-late 1250)
                  (bucket-end 1250) (boundary 1250) (past-boundary 1500)
                  (idle-limit 76000) (idle-limit+1ms 76250))
                (fired-at (make-wheel 250)
                          '((long-past . 0) (just-past . 999) (due . 1000) (a-ms-late . 1001)
                            (bucket-end . 1249) (boundary . 1250) (past-boundary . 1251)
                            (idle-limit . 76000) (idle-limit+1ms . 76001))
                          1000 77000))
    (test-equal "and with ticks between bucket boundaries"
                '((due 1100) (a-ms-late 1350) (bucket-start 1350) (a-tick-on 1600)
                  (bucket-middle 1600) (a-ms-early 1600) (on-a-tick 1600))
                (fired-at (make-wheel 250)
                          '((due . 1100) (a-ms-late . 1101) (bucket-start . 1250)
                            (a-tick-on . 1351) (bucket-middle . 1500) (a-ms-early . 1599)
                            (on-a-tick . 1600))
                          1100 2000))
    (test-equal "every deadline from 1000 to 3000 ms fires once, within [D, D + 250) of it, for ticks at three phases"
                '(within within within)
                (map sweep '(1000 1100 1249)))
    (test-equal "instants start at 0: a deadline at 0 fires at an advance to 0"
                '(zero)
                (let ((w (make-wheel 250)))
                  (wheel-arm! w (make-wheel-entry 'zero) 0)
                  (wheel-advance! w 0)))
    (test-equal "a deadline already past when armed fires at the next advance"
                '((late) ())
                (observe (lambda (see)
                           (let ((w (make-wheel 250)))
                             (wheel-advance! w 5000)
                             (wheel-arm! w (make-wheel-entry 'late) 500)
                             (see (wheel-advance! w 5100))
                             (see (wheel-advance! w 5350))))))

    ;; --- one deadline per entry: fired once, disarmed, moved ---
    (test-equal "a deadline fires once; armed again, the entry fires again"
                '((k) () (k) ())
                (observe (lambda (see)
                           (let ((w (make-wheel 250)) (k (make-wheel-entry 'k)))
                             (wheel-arm! w k 1000)
                             (see (wheel-advance! w 1000))
                             (see (wheel-advance! w 1250))
                             (wheel-arm! w k 2000)
                             (see (wheel-advance! w 2000))
                             (see (wheel-advance! w 2250))))))
    (test-equal "a disarmed deadline never fires, and disarming an entry not armed changes nothing"
                '((kept) ())
                (observe (lambda (see)
                           (let ((w (make-wheel 250)) (dropped (make-wheel-entry 'dropped)))
                             (wheel-arm! w (make-wheel-entry 'kept) 1000)
                             (wheel-arm! w dropped 1000)
                             (wheel-disarm! w dropped)
                             (wheel-disarm! w (make-wheel-entry 'never-armed))
                             (see (wheel-advance! w 1000))
                             (see (wheel-advance! w 100000))))))
    (test-equal "arming an entry again moves its one deadline, later or earlier"
                '((earlier) () (later))
                (observe (lambda (see)
                           (let ((w (make-wheel 250))
                                 (later (make-wheel-entry 'later))
                                 (earlier (make-wheel-entry 'earlier)))
                             (wheel-arm! w later 1000)
                             (wheel-arm! w earlier 5000)
                             (wheel-arm! w later 5000)
                             (wheel-arm! w earlier 1000)
                             (see (wheel-advance! w 1000))
                             (see (wheel-advance! w 4999))
                             (see (wheel-advance! w 5000))))))
    (test-equal "an entry's deadline reads as armed, and #f before it is armed and once it fires or is disarmed"
                '(#f 1000 2500 #f #f b)
                (observe (lambda (see)
                           (let ((w (make-wheel 250)) (a (make-wheel-entry 'a)) (b (make-wheel-entry 'b)))
                             (see (wheel-entry-deadline a))
                             (wheel-arm! w a 1000)
                             (wheel-arm! w b 2000)
                             (wheel-arm! w b 2500)
                             (see (wheel-entry-deadline a))
                             (see (wheel-entry-deadline b))
                             (wheel-advance! w 1000)
                             (wheel-disarm! w b)
                             (see (wheel-entry-deadline a))
                             (see (wheel-entry-deadline b))
                             (see (wheel-entry-key b))))))
    (test-equal "the count is how many entries are armed, 0 once the last fires: the shell's cue to stop its timer"
                '(0 3 2 2 1 0)
                (observe (lambda (see)
                           (let ((w (make-wheel 250))
                                 (a (make-wheel-entry 'a))
                                 (b (make-wheel-entry 'b))
                                 (c (make-wheel-entry 'c)))
                             (see (wheel-count w))
                             (wheel-arm! w a 1000)
                             (wheel-arm! w b 2000)
                             (wheel-arm! w c 2000)
                             (wheel-arm! w a 1000)
                             (see (wheel-count w))
                             (wheel-disarm! w c)
                             (see (wheel-count w))
                             (wheel-disarm! w c)
                             (see (wheel-count w))
                             (wheel-advance! w 1000)
                             (see (wheel-count w))
                             (wheel-advance! w 2000)
                             (see (wheel-count w))))))
    (test-equal "an entry the caller keeps, disarmed or fired, holds nothing of the wheel; one still armed is held"
                '(((after-disarmed . released) (after-fired . released) (armed . held)) 1 #f #f)
                (what-entries-hold))

    ;; --- the order an advance fires in ---
    (test-equal "within one bucket, the earlier deadline fires first, whichever was armed first"
                '(early late)
                (let ((w (make-wheel 250)))
                  (wheel-arm! w (make-wheel-entry 'late) 1200)
                  (wheel-arm! w (make-wheel-entry 'early) 1100)
                  (wheel-advance! w 1300)))
    (test-equal "equal deadlines fire in the order they were last armed"
                '((c a b) (c b a))
                (let ((w1 (make-wheel 250)) (w2 (make-wheel 250))
                      (e1 (map make-wheel-entry '(c a b)))
                      (e2 (map make-wheel-entry '(c a b))))
                  (for-each (lambda (e) (wheel-arm! w1 e 1000)) e1)
                  (for-each (lambda (e) (wheel-arm! w2 e 1000)) (append e2 (list (cadr e2))))
                  (list (wheel-advance! w1 1000) (wheel-advance! w2 1000))))

    ;; --- slots shared across revolutions, and long jumps ---
    (test-equal "a deadline a revolution ahead, in the same slot, waits for its own time"
                '((this-lap) () (next-lap))
                (observe (lambda (see)
                           (let ((w (make-wheel 250 4)))
                             (wheel-arm! w (make-wheel-entry 'this-lap) 1000)
                             (wheel-arm! w (make-wheel-entry 'next-lap) 2000)
                             (see (wheel-advance! w 1000))
                             (see (wheel-advance! w 1999))
                             (see (wheel-advance! w 2000))))))
    (let ((keys (map (lambda (k) (list k (+ 1017 (* 250 k)))) (range 0 39))))
      (test-equal "one advance past forty deadlines over five revolutions fires those due, earliest first, and keeps the rest"
                  (list (take keys 25) 15 (list-tail keys 25) 0)
                  (observe (lambda (see)
                             (let ((w (make-wheel 250 8)))
                               (for-each (lambda (key) (wheel-arm! w (make-wheel-entry key) (cadr key)))
                                         keys)
                               (see (wheel-advance! w (+ 1017 (* 250 24))))
                               (see (wheel-count w))
                               (see (wheel-advance! w 1000000))
                               (see (wheel-count w)))))))
    (test-equal "the wheel fires what a plain list of deadlines fires, over 4,000 operations, whatever its tick and slots"
                '(agrees agrees agrees agrees agrees agrees)
                (map (lambda (c) (apply agrees c))
                     '((250 #f 1 4000) (250 1 2 4000) (250 2 3 4000)
                       (7 3 4 4000) (1 8 5 4000) (1000 5 6 4000))))

    ;; --- what the wheel refuses ---
    (test-equal "a tick or slot count that is not a whole number above 0, an instant that is not a whole number of ms from 0, or what is not an entry, is refused by the procedure it is given to"
                '(refused refused refused refused refused refused refused refused refused refused refused)
                (let ((w (make-wheel 250)) (e (make-wheel-entry 'k)))
                  (map refused-by
                       (list (cons 'make-wheel (lambda () (make-wheel 0)))
                             (cons 'make-wheel (lambda () (make-wheel 5/2)))
                             (cons 'make-wheel (lambda () (make-wheel 250 0)))
                             (cons 'wheel-arm! (lambda () (wheel-arm! w e -1)))
                             (cons 'wheel-arm! (lambda () (wheel-arm! w e 1000.0)))
                             (cons 'wheel-arm! (lambda () (wheel-arm! w 'k 1000)))
                             (cons 'wheel-disarm! (lambda () (wheel-disarm! w 'k)))
                             (cons 'wheel-entry-deadline (lambda () (wheel-entry-deadline 'k)))
                             (cons 'wheel-advance! (lambda () (wheel-advance! w -1)))
                             (cons 'wheel-advance! (lambda () (wheel-advance! w 1000.0)))
                             (cons 'wheel-advance! (lambda () (wheel-advance! w 'soon)))))))
    (test-equal "a refused arm leaves the entry and the count as they were"
                '(1000 1)
                (let ((w (make-wheel 250)) (e (make-wheel-entry 'k)))
                  (wheel-arm! w e 1000)
                  (guard (x ((assertion-violation? x) #f))
                    (wheel-arm! w e 1000.0))
                  (list (wheel-entry-deadline e) (wheel-count w))))))
