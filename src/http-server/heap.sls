#!r6rs
;;; (http-server heap) — the times a loop's waits wake at, kept in a binary
;;; heap (decision 0015 item 3; M7.2).
;;;
;;; PURE functional core: imports only (rnrs), and reads no clock.  Every
;;; instant is a whole number of milliseconds the caller gives, from a clock
;;; that never steps: in the libuv shell the loop's own (uv_now).  A loop's
;;; waits, in their private library, keep each sleep's time and each deadline
;;; here, and the loop's one timer for them is armed for the earliest.  Like
;;; the wheel, a heap is linear: its procedures update it in place.
;;;
;;; THE CONTRACT.  An advance to `now` takes out exactly the entries whose
;;; times are at or before `now`, and returns their keys: the earliest first,
;;; and equal times in the order they were put in.  So a timer armed for the
;;; earliest, the heap advanced to the loop's time each time it fires, wakes
;;; no wait before its time.  An entry is taken out once, by an advance or
;;; a removal: removing it again does nothing.  A heap holds nothing of an
;;; entry it has taken out.
;;;
;;; THE INDEX.  A binary min-heap in a vector, ordered by time and then by
;;; the order the entries were put in.  Each entry keeps its place in the
;;; vector, so one can be taken out from the middle in log time, as a
;;; deadline is once its thunk has returned.  The vector doubles when full,
;;; and is never shrunk.
(library (http-server heap)
  (export make-heap heap? heap-count heap-earliest
          heap-insert! heap-remove! heap-advance!
          heap-entry? heap-entry-key heap-entry-time)
  (import (rnrs))

  ;; heap-entry? : Any -> Boolean
  ;; heap-entry-key : HeapEntry -> Any — what an advance returns as it takes
  ;; the entry out.
  ;; heap-entry-time : HeapEntry -> Nat — the time it was put in at.
  (define-record-type (entry make-entry heap-entry?)
    (fields (immutable key heap-entry-key)
            (immutable time heap-entry-time)
            (immutable order entry-order)                   ; how many were put in before it
            (mutable place entry-place entry-place-set!))   ; its index, or #f once taken out
    (sealed #t))

  ;; heap? : Any -> Boolean
  ;; heap-count : Heap -> Nat — how many entries it holds.
  (define-record-type (heap %make-heap heap?)
    (fields (mutable slots heap-slots heap-slots-set!)
            (mutable count heap-count heap-count-set!)
            (mutable put heap-put heap-put-set!))   ; how many were ever put in
    (sealed #t))

  ;; make-heap : -> Heap — an empty heap.
  (define (make-heap) (%make-heap (make-vector 16 #f) 0 0))

  ;; whole! : Symbol Any -> Void — refuse what is not an exact integer of at
  ;; least 0.
  (define (whole! who x)
    (unless (and (integer? x) (exact? x) (>= x 0))
      (assertion-violation who "expected an exact integer of at least 0" x)))

  ;; before? : Entry Entry -> Boolean — earlier, or as early and put in first.
  (define (before? a b)
    (let ((ta (heap-entry-time a)) (tb (heap-entry-time b)))
      (or (< ta tb) (and (= ta tb) (< (entry-order a) (entry-order b))))))

  ;; place! : Heap Nat Entry -> Void — `e` at index i.
  (define (place! h i e)
    (vector-set! (heap-slots h) i e)
    (entry-place-set! e i))

  ;; up! : Heap Nat Entry -> Void — `e` placed, moving up from index i past
  ;; each parent it comes before.
  (define (up! h i e)
    (let loop ((i i))
      (if (= i 0)
          (place! h 0 e)
          (let* ((p (div (- i 1) 2)) (pe (vector-ref (heap-slots h) p)))
            (if (before? e pe)
                (begin (place! h i pe) (loop p))
                (place! h i e))))))

  ;; down! : Heap Nat Entry -> Void — `e` placed, moving down from index i
  ;; past each child that comes before it, the earlier child first.
  (define (down! h i e)
    (let ((v (heap-slots h)) (n (heap-count h)))
      (let loop ((i i))
        (let* ((l (+ (* 2 i) 1))
               (r (+ l 1))
               (c (cond ((>= l n) #f)
                        ((and (< r n) (before? (vector-ref v r) (vector-ref v l))) r)
                        (else l))))
          (if (and c (before? (vector-ref v c) e))
              (begin (place! h i (vector-ref v c)) (loop c))
              (place! h i e))))))

  ;; heap-insert! : Heap Nat Any -> HeapEntry
  ;; An entry for `key` at `time`, put in.
  (define (heap-insert! h time key)
    (whole! 'heap-insert! time)
    (let ((n (heap-count h))
          (e (make-entry key time (heap-put h) #f)))
      (heap-put-set! h (+ (heap-put h) 1))
      (when (= n (vector-length (heap-slots h)))
        (let ((v (make-vector (* 2 n) #f)) (old (heap-slots h)))
          (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (vector-ref old i)))
          (heap-slots-set! h v)))
      (heap-count-set! h (+ n 1))
      (up! h n e)
      e))

  ;; take-out! : Heap Nat -> Void
  ;; The entry at index i taken out, its slot filled by the last entry.
  (define (take-out! h i)
    (let* ((v (heap-slots h))
           (e (vector-ref v i))
           (n (- (heap-count h) 1))
           (last (vector-ref v n)))
      (vector-set! v n #f)
      (heap-count-set! h n)
      (entry-place-set! e #f)
      (unless (= i n)
        (if (and (> i 0) (before? last (vector-ref v (div (- i 1) 2))))
            (up! h i last)
            (down! h i last)))))

  ;; heap-remove! : Heap HeapEntry -> Void
  ;; `e`, an entry put in `h`, taken out if it is still in; nothing if not.
  (define (heap-remove! h e)
    (let ((i (entry-place e)))
      (when i
        (unless (and (< i (heap-count h)) (eq? (vector-ref (heap-slots h) i) e))
          (assertion-violation 'heap-remove! "not an entry of this heap" e))
        (take-out! h i))))

  ;; heap-earliest : Heap -> (U Nat #f) — the earliest time in it, or #f
  ;; when it is empty.
  (define (heap-earliest h)
    (and (> (heap-count h) 0)
         (heap-entry-time (vector-ref (heap-slots h) 0))))

  ;; heap-advance! : Heap Nat -> (Listof Any)
  ;; The keys of the entries at or before `now`, each taken out: the
  ;; earliest first, and equal times in the order they were put in.
  (define (heap-advance! h now)
    (whole! 'heap-advance! now)
    (let loop ((due '()))
      (if (and (> (heap-count h) 0)
               (<= (heap-entry-time (vector-ref (heap-slots h) 0)) now))
          (let ((e (vector-ref (heap-slots h) 0)))
            (take-out! h 0)
            (loop (cons (heap-entry-key e) due)))
          (reverse due)))))
