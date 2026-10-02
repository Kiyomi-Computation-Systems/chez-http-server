#!r6rs
;;; (http-server heap): the times a loop's waits wake at, in a binary heap.
;;; M7.2's third step.
;;;
;;; Oracles: decision 0015 item 3 — a sleep or a deadline wakes the first
;;; time the loop's timer fires at or after its time, never before — and a
;;; plain list of the entries put in, kept in the order they were put in,
;;; which says what an advance owes with no heap at all: the entries at or
;;; before `now`, by time, and equal times in that order (`list-sort` is
;;; stable).  The heap is an index over that list, so it must take out what
;;; the list takes out, through any mix of inserts, removals and advances; a
;;; script of them, from a fixed seed, is played against both.  The clock is
;;; the test's own: every instant is a number it gives, and no test sleeps
;;; (global-constraints).
;;;
;;; The checks:
;;;   - an advance takes out exactly the entries at or before `now`, the
;;;     earliest first, equal times in the order they were put in;
;;;   - 5,000 steps of inserts, removals and advances, from a fixed seed,
;;;     take out what the list model takes out, the count and the earliest
;;;     the same at every step;
;;;   - a removal takes out that entry alone, and removing it again, or one
;;;     an advance took out, does nothing;
;;;   - a removal from the middle moves the last entry up past a later
;;;     parent, so an advance still finds it;
;;;   - an empty heap has no earliest time and a count of 0;
;;;   - a time or a `now` that is not a whole number of milliseconds is an
;;;     assertion violation, and so is an entry of another heap removed;
;;;   - a heap holds nothing of an entry it has taken out, by an advance or
;;;     a removal, and holds one still in.
(import (rnrs) (srfi :64) (testing) (http-server heap)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object?))

;; model-due : (Listof (Pair Key Nat)) Nat -> (Listof Key)
;; What the plain list owes an advance to `now`: the keys at or before it,
;; by time, equal times in the list's order.
(define (model-due entries now)
  (map car (list-sort (lambda (a b) (< (cdr a) (cdr b)))
                      (filter (lambda (e) (<= (cdr e) now)) entries))))

;; outcome : (-> Any) -> Any — `(returned v)`, or `assertion` for an
;; assertion violation, or `other` for any other raise.
(define (outcome thunk)
  (guard (e ((assertion-violation? e) 'assertion) (#t 'other))
    (list 'returned (thunk))))

;; next-random : Nat -> Nat — the next of a linear congruential sequence,
;; the script's fixed seed its first.
(define (next-random x) (mod (+ (* x 1103515245) 12345) 2147483648))

;; play : Nat -> (U 'agreed (Listof Any))
;; `steps` steps from a fixed seed, each an insert at a time a little ahead
;; of the clock, a removal of an entry put in, or an advance of the clock,
;; played against the heap and against the list model: 'agreed when every
;; advance took out the same keys and every step left the same count and
;; earliest time; else the first step that did not.
(define (play steps)
  (let ((h (make-heap)))
    (let loop ((i 0) (x 20260 ) (now 0) (model '()) (entries '()) (key 0))
      (if (= i steps)
          'agreed
          (let* ((x (next-random x)) (r (mod (div x 65536) 100)))
            (cond
             ((< r 50)                      ; an insert, 0 to 49 ms ahead
              (let* ((t (+ now (mod (div x 7) 50)))
                     (e (heap-insert! h t key)))
                (check i h (append model (list (cons key t))) (cons (cons key e) entries)
                       x now (+ key 1) loop)))
             ((and (< r 75) (pair? entries)) ; a removal, of an entry put in
              (let* ((pick (list-ref entries (mod (div x 3) (length entries))))
                     (k (car pick)))
                (heap-remove! h (cdr pick))
                (check i h (filter (lambda (m) (not (eqv? (car m) k))) model) entries
                       x now key loop)))
             (else                           ; an advance, 0 to 29 ms on
              (let* ((now (+ now (mod (div x 11) 30)))
                     (got (heap-advance! h now))
                     (owed (model-due model now)))
                (if (equal? got owed)
                    (check i h (filter (lambda (m) (> (cdr m) now)) model) entries
                           x now key loop)
                    (list 'step i 'advance now 'took got 'owed owed))))))))))

;; check : ... -> Any — the count and the earliest against the model, then
;; the next step.
(define (check i h model entries x now key loop)
  (let ((earliest (if (null? model) #f (apply min (map cdr model)))))
    (if (and (= (heap-count h) (length model)) (eqv? (heap-earliest h) earliest))
        (loop (+ i 1) x now model entries key)
        (list 'step i 'count (heap-count h) (length model) 'earliest (heap-earliest h) earliest))))

(run-suite "heap"
  (lambda ()
    ;; for-each, not map, whose order Chez does not fix: the order the
    ;; entries are put in is what the ties are checked by.
    (let ((h (make-heap)))
      (for-each (lambda (k t) (heap-insert! h t k)) '(a b c d e f g) '(30 10 20 10 40 20 10))
      (test-equal "an advance takes out exactly the entries at or before now, the earliest first, equal times in the order they were put in"
        '((b d g) (c f a) () (e) 0)
        (list (heap-advance! h 10) (heap-advance! h 30) (heap-advance! h 39) (heap-advance! h 40)
              (heap-count h))))

    (test-eq "5,000 steps of inserts, removals and advances take out what the list model takes out"
             'agreed (play 5000))

    (let* ((h (make-heap))
           (a (heap-insert! h 10 'a)) (b (heap-insert! h 20 'b)) (c (heap-insert! h 30 'c)))
      (heap-remove! h b)
      (heap-remove! h b)
      (let ((first (heap-advance! h 10)))
        (heap-remove! h a)
        (test-equal "a removal takes out that entry alone; removing it again, or one an advance took, does nothing"
          '((a) 1 30 (c))
          (list first (heap-count h) (heap-earliest h) (heap-advance! h 100)))))

;; Built as [0 100 50 101 102 60 70]: taking out 101 puts 70, the last,
    ;; under 100, which it must move up past; then 300 and 301 bury it unless
    ;; it did.  An advance to 80 owes 0, 50, 60 and 70.
    (let ((h (make-heap)))
      (for-each (lambda (t) (heap-insert! h t t)) '(0 100 50))
      (let ((e101 (heap-insert! h 101 101)))
        (for-each (lambda (t) (heap-insert! h t t)) '(102 60 70))
        (heap-remove! h e101)
        (for-each (lambda (t) (heap-insert! h t t)) '(300 301))
        (test-equal "a removal from the middle moves the last entry up past a later parent, so an advance still finds it"
          '(0 50 60 70) (heap-advance! h 80))))

    (test-equal "an empty heap has no earliest time and a count of 0"
      '(#f 0 ()) (let ((h (make-heap))) (list (heap-earliest h) (heap-count h) (heap-advance! h 1000))))

    (test-equal "a time or a now that is not a whole number of milliseconds, or another heap's entry, is an assertion violation"
      '(assertion assertion assertion assertion assertion)
      (let ((h (make-heap)) (other (make-heap)))
        (list (outcome (lambda () (heap-insert! h -1 'k)))
              (outcome (lambda () (heap-insert! h 1.5 'k)))
              (outcome (lambda () (heap-insert! h 'soon 'k)))
              (outcome (lambda () (heap-advance! h -1)))
              (outcome (lambda ()
                         (for-each (lambda (t) (heap-insert! h t t)) '(1 2 3))
                         (heap-insert! other 5 'k)
                         (heap-remove! h (heap-insert! other 6 'j)))))))

    ;; A heap holds nothing of an entry it has taken out: a key let go after
    ;; an advance took it, the heap's only one, and one let go after it was
    ;; removed, the heap's last, are collected, beside one still in, seen
    ;; held.
    (let* ((h (make-heap))
           (advanced (let ((k (list 'advanced))) (heap-insert! h 1 k) (weak-cons k '()))))
      (heap-advance! h 1)
      (let* ((held (let ((k (list 'held))) (heap-insert! h 100 k) (weak-cons k '())))
             (removed (let ((k (list 'removed))) (heap-remove! h (heap-insert! h 200 k)) (weak-cons k '()))))
        (collect (collect-maximum-generation))
        (test-equal "a heap holds nothing of an entry it has taken out, by an advance or a removal, and holds one still in"
          '(#t #t #f 1)
          (list (bwp-object? (car advanced)) (bwp-object? (car removed)) (bwp-object? (car held))
                (heap-count h)))))))
