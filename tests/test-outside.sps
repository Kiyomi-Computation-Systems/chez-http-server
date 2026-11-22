#!r6rs
;;; await-outside: a wait whose resume any thread may call.
;;;
;;; Three machines make the outside wait, each a table of rows written by
;;; hand, `(state event next effect)`:
;;;   - THE WAIT, one `await-outside`, every transition on the loop's thread;
;;;   - THE RESUME, one wait's `resume`, every transition under the inbox's
;;;     mutex, its event whether the inbox it posts to, the one open as its
;;;     `register` ran, is open or closed as it is called;
;;;   - THE INBOX, one a loop's waits at a time.
;;; Each table is checked sound: every row in its states and events; no
;;; two rows for one state and event (deterministic); every pair of a state
;;; and an event a row's, or named impossible, with why, and never both
;;; (complete); and every state reached from the first.  The check is held
;;; to a fixture that is unsound in each of those ways.
;;;
;;; Then each row is driven.  The wait's and the resume's are driven against
;;; (http-server testing)'s host, through the public (http-server) and
;;; (http-server testing): a handler answers `awaiting` and waits outside,
;;; and the test keeps its `resume` and calls it between the host's calls,
;;; as a worker thread would.  A wait's row is observed as the client sees
;;; it; a resume's as what each call answers and what the host's next call
;;; makes of it, then again for the state it leaves, which must do what the
;;; table says that state does.  The inbox's rows are driven against a
;;; loop's waits, (http-server private waits), whose opener records each
;;; open, wake and close the waits ask of it, and answers no wake while the
;;; loop takes no posts, since a host's wake is never refused, its opener
;;; always answers one, and it is not seen from outside.
;;;
;;; The scripts after the rows: a resume called and handed over; a
;;; `register` that raises; one that calls `resume` itself, after which the
;;; handler still parks, as `await`'s does not; a value posted after a
;;; deadline or a client's close ended the wait, dropped and not logged; a
;;; resume called twice; a stop of posts; two handlers resumed in reverse
;;; order; a value and a deadline in one advance, the value first; a value
;;; a handler posts, handed over in the same run; a dropped value let go,
;;; though its resume is kept; a `register` that itself waits, its value
;;; kept and answered as it returns; a taker's coroutine; and
;;; `await-outside` refused on no coroutine and in a plain handler.  The
;;; inbox's delivery hands values over in the order they were posted, and
;;; every value before any notice is logged.
;;;
;;; A waiting verb called from another thread, a worker's, is refused as R2,
;;; off the loop's thread, on that thread, before any register runs: while
;;; the loop's thread runs a handler's coroutine, which waits for the worker
;;; (`await-outside` and `await` with a register that raises, then
;;; `sleep-ms` and `await-outside` with one that returns, which would park
;;; on the worker), and between the host's calls; the coroutine answers as
;;; before.
;;;
;;; A `register` that itself waits leaves its outside wait registering while
;;; it is parked in the other: a value delivered meanwhile is kept, EARLY,
;;; and answered as `register` returns, the outside wait never parking.
;;;
;;; Oracles: docs/waiting.md (what `await-outside` and its `resume` do, what
;;; is logged, and that a value and a deadline in one turn go to the value);
;;; docs/testing.md (the host hands a posted value over at its next call,
;;; before it moves the clock; `test-host-posted` and `test-host-stop-posts!`);
;;; docs/upgrades.md (a taker that answers `awaiting` waits as a handler
;;; does); and (http-server private waits)' contract for the inbox: a mutex,
;;; a queue and an open flag, its wake the shell's, closed by the shell.
(import (rnrs) (srfi :64) (testing)
        (http-server) (http-server testing)
        (only (http-server private scheduler) make-scheduler scheduler-spawn! scheduler-drain!
              scheduler-invariant? scheduler-invariant-name)
        (only (http-server private waits) make-waits waits-outside! waits-outside-close!
              waits-posted waits-queued?)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object? fork-thread thread-join
              make-list))

(define (b s) (string->utf8 s))

(define (get path) (b (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; text : Nat String -> Response
(define (text status s) (make-response status #f '() (b s)))

;; show : Any -> String — a number or a symbol, as text.
(define (show v)
  (cond ((number? v) (number->string v))
        ((symbol? v) (symbol->string v))
        (else "?")))

;; seen : TestClient -> (Listof (List Nat String))
;; Each response the client read: its status and its body, as text.
(define (seen c)
  (map (lambda (r) (list (test-response-status r) (utf8->string (test-response-body r))))
       (test-client-responses c)))

;; refused : Symbol (-> Any) -> (U 'refused 'accepted Any)
;; Whether `thunk` is refused by `who`: an assertion violation it names.
(define (refused who thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (eq? (condition-who e) who)) 'refused)
            (#t (list 'raised (if (who-condition? e) (condition-who e) e))))
    (thunk)
    'accepted))

;; --- the tables ---------------------------------------------------------------
;; A row is (state event next effect).  Impossible pairs are named in groups,
;; (states events why): every pair of one of the states and one of the
;; events.

(define wait-states '(registering early parked resumed abandoned dead))
(define wait-events '(register-returns register-raises value-delivered deadline-passes client-closes))
(define wait-rows
  '((registering register-returns parked parks)
    (registering register-raises dead raise-leaves)
    (registering value-delivered early kept)
    (early register-returns resumed answers-at-once)
    (early register-raises dead raise-leaves)
    (parked value-delivered resumed answers-value)
    (parked deadline-passes abandoned raises-deadline-passed)
    (parked client-closes abandoned raises-client-closed)
    (abandoned value-delivered abandoned dropped)
    (dead value-delivered dead dropped)))
(define wait-impossible
  '(((registering early) (deadline-passes client-closes)
     "this wait has not begun while register runs: a deadline or a close then ends the wait register is parked in, if it waits, and that wait's raise reaches register, which returns or raises; one that came before makes this wait raise before register runs")
    ((parked resumed abandoned dead) (register-returns register-raises)
     "register runs once, and has run")
    ((early resumed) (value-delivered)
     "a resume posts once, so a wait's value is delivered once")
    ((resumed abandoned) (deadline-passes client-closes)
     "the wait is over: a deadline that passes, or a close, after it is the coroutine's next wait's")
    ((dead) (deadline-passes client-closes)
     "no wait began")))

(define resume-states '(fresh used refused))
(define resume-events '(open closed))
(define resume-rows
  '((fresh open used (#t queued))
    (fresh closed refused (#f nothing))
    (used open used (#f notice))
    (used closed used (#f nothing))
    (refused closed refused (#f nothing))))
(define resume-impossible
  '(((refused) (open)
     "a resume is refused only once the inbox it posts to has closed, and an inbox once closed stays closed: a later outside wait opens a fresh one, which a resume made before it never posts to")))

(define inbox-states '(absent open closed))
(define inbox-events '(outside-wait outside-wait-no-posts post delivery serves-no-more wake-meets-closed-handle))
(define inbox-rows
  '((absent outside-wait open opened)
    (absent outside-wait-no-posts closed refused)
    (absent serves-no-more absent nothing)
    (open outside-wait open shared)
    (open post open queued-and-woken)
    (open delivery open emptied)
    (open serves-no-more closed emptied-once-more)
    (open wake-meets-closed-handle closed taken-back)
    (closed post closed refused)
    (closed outside-wait open fresh-inbox)
    (closed outside-wait-no-posts closed refused)
    (closed serves-no-more closed nothing)))
(define inbox-impossible
  '(((absent) (post delivery wake-meets-closed-handle)
     "a resume is made by an outside wait, which opens an inbox: with none, nothing posts and no wake is made")
    ((open) (outside-wait-no-posts)
     "the loop takes no posts only once no shell on it serves, and the last to serve no more closed the inbox")
    ((closed) (delivery wake-meets-closed-handle)
     "a closed inbox's wake is closed, so it fires no more, and a post to it is refused under the mutex before any wake")))

;; --- checking a table -----------------------------------------------------------

;; pairs : (Listof Symbol) (Listof Symbol) -> (Listof (List Symbol Symbol))
(define (pairs states events)
  (apply append (map (lambda (s) (map (lambda (e) (list s e)) events)) states)))

;; impossible-pairs : (Listof (List (Listof Symbol) (Listof Symbol) String)) -> (Listof (List Symbol Symbol))
(define (impossible-pairs groups)
  (apply append (map (lambda (g) (pairs (car g) (cadr g))) groups)))

;; row-pair : Row -> (List Symbol Symbol)
(define (row-pair r) (list (car r) (cadr r)))

;; duplicates : (Listof Any) -> (Listof Any) — each element found twice or more, once.
(define (duplicates xs)
  (let loop ((xs xs) (seen '()) (dups '()))
    (cond ((null? xs) (reverse dups))
          ((member (car xs) seen)
           (loop (cdr xs) seen (if (member (car xs) dups) dups (cons (car xs) dups))))
          (else (loop (cdr xs) (cons (car xs) seen) dups)))))

;; reached : Symbol (Listof Row) -> (Listof Symbol) — the states the rows reach from `start`.
(define (reached start rows)
  (let loop ((seen (list start)))
    (let ((more (filter (lambda (s) (not (memq s seen)))
                        (map caddr (filter (lambda (r) (memq (car r) seen)) rows)))))
      (if (null? more) seen (loop (cons (car more) seen))))))

;; table-faults : (Listof Symbol) (Listof Symbol) (Listof Row) Groups -> (Listof Any)
;; Every way the table is unsound, '() for none: a row outside its states
;; and events, an impossible pair outside them, two rows for a pair, a pair
;; named impossible twice, a pair both a row's and impossible, a pair
;; neither, and a state the rows never reach from the first.
(define (table-faults states events rows impossible)
  (let ((covered (map row-pair rows))
        (excluded (impossible-pairs impossible))
        (all (pairs states events)))
    (append
     (map (lambda (r) (list 'outside-its-vocabulary r))
          (filter (lambda (r) (not (and (memq (car r) states) (memq (cadr r) events) (memq (caddr r) states))))
                  rows))
     (map (lambda (p) (list 'impossible-outside-its-vocabulary p))
          (filter (lambda (p) (not (member p all))) excluded))
     (map (lambda (p) (list 'two-rows p)) (duplicates covered))
     (map (lambda (p) (list 'impossible-twice p)) (duplicates excluded))
     (map (lambda (p) (list 'a-row-and-impossible p)) (filter (lambda (p) (member p excluded)) covered))
     (map (lambda (p) (list 'neither p))
          (filter (lambda (p) (not (or (member p covered) (member p excluded)))) all))
     (map (lambda (s) (list 'unreached s))
          (filter (lambda (s) (not (memq s (reached (car states) rows)))) states)))))

;; row-for : (Listof Row) Symbol Symbol -> (U Row #f)
(define (row-for rows state event)
  (find (lambda (r) (and (eq? (car r) state) (eq? (cadr r) event))) rows))

;; --- a host whose handler waits outside -------------------------------------------

;; A scene: a host, its clients, each resume its handler's code registered,
;; in order, what that code noted, and how often the dynamic-wind around
;; each wait was entered and left.
(define-record-type scene
  (fields (mutable host) (mutable clients) (mutable kept) (mutable notes)
          (mutable befores) (mutable afters)))

(define (note! sc x) (scene-notes-set! sc (append (scene-notes sc) (list x))))

;; outside-scene : Symbol (U Nat #f) -> Scene
;; A host whose handler, for each request, waits outside, inside a deadline
;; of `ms` if it is not #f, in a dynamic-wind that counts each entry and
;; leaving; and one client that has sent it a GET.  Its `register` keeps
;; its resume, then, by `how`: `keep` returns; `raise` raises
;; 'register-raised; `self` calls the resume with 'self, and notes what it
;; answered; `sleep` sleeps 10 ms, then returns; `sleep-raise` sleeps 10 ms,
;; then raises 'register-raised.  The handler answers 200 with the value, 504 "late" for
;; &deadline-passed, and 200 "raised" for its register's raise; it notes a
;; client's close, and lets it out.
(define (outside-scene how ms)
  (let ((sc (make-scene #f '() '() '() 0 0)))
    (define (wait)
      (dynamic-wind
       (lambda () (scene-befores-set! sc (+ 1 (scene-befores sc))))
       (lambda ()
         (await-outside
          (lambda (resume)
            (scene-kept-set! sc (append (scene-kept sc) (list resume)))
            (case how
              ((raise) (raise 'register-raised))
              ((self) (note! sc (list 'self (resume 'self))))
              ((sleep) (sleep-ms 10))
              ((sleep-raise) (sleep-ms 10) (raise 'register-raised))))))
       (lambda () (scene-afters-set! sc (+ 1 (scene-afters sc))))))
    (scene-host-set! sc
      (make-test-host
       (lambda (request)
         (awaiting
          (lambda ()
            (guard (e ((deadline-passed? e) (text 504 "late"))
                      ((eq? e 'register-raised) (text 200 "raised"))
                      ((client-closed? e) (note! sc 'client-closed) (raise e)))
              (text 200 (show (if ms (with-deadline ms wait) (wait))))))))))
    (scene-connect! sc)
    sc))

;; scene-connect! : Scene -> TestClient — one more client, which sends a GET.
(define (scene-connect! sc)
  (let ((c (test-host-connect! (scene-host sc))))
    (scene-clients-set! sc (append (scene-clients sc) (list c)))
    (test-client-send! c (get "/"))
    c))

(define (scene-client sc) (car (scene-clients sc)))
(define (scene-resume sc) (car (scene-kept sc)))

;; call-effect : TestHost (Any -> Boolean) Any -> (List Boolean Symbol)
;; What one call of `resume` with `v` answers, and what it posted, as the
;; host's next call shows it: `queued`, a value more to hand over and
;; nothing logged; `notice`, no value and one `late-resume await-outside`
;; logged; `nothing`, neither.  Anything else is answered as it was seen.
(define (call-effect host resume v)
  (let* ((posted (test-host-posted host))
         (logged (length (test-host-log host)))
         (answer (resume v))
         (queued (- (test-host-posted host) posted)))
    (test-host-advance! host 0)
    (let ((late (list-tail (test-host-log host) logged)))
      (list answer
            (cond ((and (= queued 1) (null? late)) 'queued)
                  ((and (= queued 0) (equal? late '((late-resume await-outside)))) 'notice)
                  ((and (= queued 0) (null? late)) 'nothing)
                  (else (list 'seen queued late)))))))

;; --- the wait's rows, driven ------------------------------------------------------
;; Each answers the row's (next effect) when the client sees what the row
;; says, and what it saw otherwise.

(define wait-drivers
  (list
   (list 'registering 'register-returns
         (lambda ()
           (let* ((sc (outside-scene 'keep #f)) (c (scene-client sc)))
             (let ((o (list (seen c) (test-client-waiting? c) (scene-befores sc) (scene-afters sc))))
               (if (equal? o '(() #t 1 1)) '(parked parks) o)))))
   (list 'registering 'register-raises
         (lambda ()
           (let* ((sc (outside-scene 'raise #f)) (c (scene-client sc)))
             (let ((o (list (seen c) (test-client-waiting? c) (test-host-log (scene-host sc)))))
               (if (equal? o '(((200 "raised")) #f ())) '(dead raise-leaves) o)))))
   ;; A register that sleeps 10 ms: the value delivered meanwhile is kept,
   ;; nothing answered until register returns.
   (list 'registering 'value-delivered
         (lambda ()
           (let* ((sc (outside-scene 'sleep #f)) (c (scene-client sc)) (h (scene-host sc))
                  (answer ((scene-resume sc) 7)))
             (test-host-advance! h 0)
             (let ((between (list answer (test-host-posted h) (seen c) (test-client-waiting? c) (test-host-log h))))
               (test-host-advance! h 10)
               (let ((o (list between (seen c))))
                 (if (equal? o '((#t 0 () #t ()) ((200 "7")))) '(early kept) o))))))
   ;; The dynamic-wind around the wait is left and entered again once, by
   ;; the sleep's park: the outside wait itself does not park.
   (list 'early 'register-returns
         (lambda ()
           (let* ((sc (outside-scene 'sleep #f)) (c (scene-client sc)) (h (scene-host sc)))
             ((scene-resume sc) 7)
             (test-host-advance! h 0)
             (test-host-advance! h 10)
             (let ((o (list (seen c) (test-client-waiting? c) (test-host-log h) (scene-befores sc) (scene-afters sc))))
               (if (equal? o '(((200 "7")) #f () 2 2)) '(resumed answers-at-once) o)))))
   (list 'early 'register-raises
         (lambda ()
           (let* ((sc (outside-scene 'sleep-raise #f)) (c (scene-client sc)) (h (scene-host sc))
                  (answer ((scene-resume sc) 7)))
             (test-host-advance! h 0)
             (let ((posted (test-host-posted h)))
               (test-host-advance! h 10)
               (let ((o (list answer posted (seen c) (test-client-waiting? c) (test-host-log h))))
                 (if (equal? o '(#t 0 ((200 "raised")) #f ())) '(dead raise-leaves) o))))))
   (list 'parked 'value-delivered
         (lambda ()
           (let* ((sc (outside-scene 'keep #f)) (c (scene-client sc)) (h (scene-host sc))
                  (answer ((scene-resume sc) 7)))
             (test-host-advance! h 0)
             (let ((o (list answer (seen c) (test-client-waiting? c) (test-host-log h) (test-host-posted h))))
               (if (equal? o '(#t ((200 "7")) #f () 0)) '(resumed answers-value) o)))))
   (list 'parked 'deadline-passes
         (lambda ()
           (let* ((sc (outside-scene 'keep 50)) (c (scene-client sc)) (h (scene-host sc)))
             (test-host-advance! h 50)
             (let ((o (list (seen c) (test-client-waiting? c) (test-host-log h))))
               (if (equal? o '(((504 "late")) #f ())) '(abandoned raises-deadline-passed) o)))))
   (list 'parked 'client-closes
         (lambda ()
           (let* ((sc (outside-scene 'keep #f)) (c (scene-client sc)) (h (scene-host sc)))
             (test-client-close! c)
             (let ((o (list (scene-notes sc) (seen c) (test-client-waiting? c) (test-host-log h)
                            (test-client-connection-closed? c))))
               (if (equal? o '((client-closed) () #f () #t)) '(abandoned raises-client-closed) o)))))
   (list 'abandoned 'value-delivered
         (lambda ()
           (let* ((sc (outside-scene 'keep 50)) (c (scene-client sc)) (h (scene-host sc)))
             (test-host-advance! h 50)
             (let* ((answer ((scene-resume sc) 7)) (posted (test-host-posted h)))
               (test-host-advance! h 0)
               (let ((o (list answer posted (test-host-posted h) (seen c) (test-host-log h))))
                 (if (equal? o '(#t 1 0 ((504 "late")) ())) '(abandoned dropped) o))))))
   (list 'dead 'value-delivered
         (lambda ()
           (let* ((sc (outside-scene 'raise #f)) (c (scene-client sc)) (h (scene-host sc)))
             (let* ((answer ((scene-resume sc) 7)) (posted (test-host-posted h)))
               (test-host-advance! h 0)
               (let ((o (list answer posted (test-host-posted h) (seen c) (test-host-log h))))
                 (if (equal? o '(#t 1 0 ((200 "raised")) ())) '(dead dropped) o))))))))

;; --- the resume's rows, driven ----------------------------------------------------
;; Each answers the effect of a call in the row's state, then of a second in
;; the state it left, under the same event.

(define (parked-scene) (outside-scene 'keep #f))

(define resume-drivers
  (list
   (list 'fresh 'open
         (lambda ()
           (let* ((sc (parked-scene)) (h (scene-host sc)) (r (scene-resume sc)))
             (let* ((first (call-effect h r 7)) (second (call-effect h r 8)))
               (list first second)))))
   (list 'fresh 'closed
         (lambda ()
           (let* ((sc (parked-scene)) (h (scene-host sc)) (r (scene-resume sc)))
             (test-host-stop-posts! h)
             (let* ((first (call-effect h r 7)) (second (call-effect h r 8)))
               (list first second)))))
   (list 'used 'open
         (lambda ()
           (let* ((sc (parked-scene)) (h (scene-host sc)) (r (scene-resume sc)))
             (r 7)
             (test-host-advance! h 0)
             (let* ((first (call-effect h r 8)) (second (call-effect h r 9)))
               (list first second)))))
   (list 'used 'closed
         (lambda ()
           (let* ((sc (parked-scene)) (h (scene-host sc)) (r (scene-resume sc)))
             (r 7)
             (test-host-stop-posts! h)
             (let* ((first (call-effect h r 8)) (second (call-effect h r 9)))
               (list first second)))))
   (list 'refused 'closed
         (lambda ()
           (let* ((sc (parked-scene)) (h (scene-host sc)) (r (scene-resume sc)))
             (test-host-stop-posts! h)
             (r 7)
             (let* ((first (call-effect h r 8)) (second (call-effect h r 9)))
               (list first second)))))))

;; --- the inbox's rows, driven against a loop's waits ---------------------------

;; A rig: a loop's scheduler, never polled, and its waits, whose opener
;; records each call the waits make of it, in order: `open`, or
;; `no-posts`, answering no wake, while the rig's loop takes no posts;
;; `wake`, its answer the rig's wake-answer; and `close-wake`; the
;; deliveries it was given, newest first; each outside wait's resume, by
;; name; what each wait answered, `(name value)`, in the order they
;; answered; and the log.
(define-record-type rig
  (fields scheduler (mutable waits) (mutable calls) (mutable deliveries) (mutable wake-answer)
          (mutable resumes) (mutable answers) (mutable log) (mutable takes-posts?)))

(define (rig-call! r what) (rig-calls-set! r (append (rig-calls r) (list what))))

;; new-rig : -> Rig
(define (new-rig)
  (let ((r (make-rig (make-scheduler (lambda (mode) (assertion-violation 'rig "the rig never polls" mode)))
                     #f '() '() #t '() '() '() #t)))
    (let ((w (make-waits (rig-scheduler r)
                         (lambda (what details) (rig-log-set! r (append (rig-log r) (list (cons what details))))))))
      (waits-outside! w (lambda (deliver!)
                          (if (rig-takes-posts? r)
                              (begin
                                (rig-call! r 'open)
                                (rig-deliveries-set! r (cons deliver! (rig-deliveries r)))
                                (lambda () (rig-call! r 'wake) (rig-wake-answer r)))
                              (begin (rig-call! r 'no-posts) #f))))
      (rig-waits-set! r w)
      r)))

;; rig-wait! : Rig Symbol -> Void — a coroutine `name` waits outside, its
;; resume kept by name; once it answers, `(name value)` is noted.
(define (rig-wait! r name)
  (scheduler-spawn! (rig-scheduler r)
    (lambda ()
      (let ((v (await-outside (lambda (resume) (rig-resumes-set! r (cons (cons name resume) (rig-resumes r)))))))
        (rig-answers-set! r (append (rig-answers r) (list (list name v))))))
    (lambda (kind v) (when (eq? kind 'raised) (rig-answers-set! r (append (rig-answers r) (list (list name 'raised)))))))
  (scheduler-drain! (rig-scheduler r)))

;; rig-post! : Rig Symbol Any -> Boolean — `name`'s resume, called with `v`.
(define (rig-post! r name v) ((cdr (assq name (rig-resumes r))) v))

;; rig-deliver! : Rig -> Void — the newest inbox's delivery, and what it wakes run.
(define (rig-deliver! r)
  ((car (rig-deliveries r)))
  (scheduler-drain! (rig-scheduler r)))

;; rig-close! : Rig -> Void — the waits close their inbox, its wake's close
;; recorded, and what that wakes runs.
(define (rig-close! r)
  (waits-outside-close! (rig-waits r) (lambda () (rig-call! r 'close-wake)))
  (scheduler-drain! (rig-scheduler r)))

(define inbox-drivers
  (list
   (list 'absent 'outside-wait
         (lambda ()
           (let* ((r (new-rig)) (before (rig-calls r)))
             (rig-wait! r 'a)
             (let* ((after (rig-calls r)) (posted (rig-post! r 'a 7)))
               (let ((o (list before after posted)))
                 (if (equal? o '(() (open) #t)) '(open opened) o))))))
;; While the loop takes no posts, the wait's resume is refused, its inbox
   ;; closed: once the loop takes posts again, the next wait opens a fresh
   ;; inbox, and that resume stays refused.
   (list 'absent 'outside-wait-no-posts
         (lambda ()
           (let ((r (new-rig)))
             (rig-takes-posts?-set! r #f)
             (rig-wait! r 'a)
             (let* ((pa (rig-post! r 'a 7))
                    (o (list pa (rig-calls r) (waits-posted (rig-waits r)) (waits-queued? (rig-waits r))
                             (rig-answers r))))
               (rig-takes-posts?-set! r #t)
               (rig-wait! r 'b)
               (let* ((pb (rig-post! r 'b 8)) (pa-again (rig-post! r 'a 9)))
                 (rig-deliver! r)
                 (let ((o (append o (list (rig-calls r) pb pa-again (rig-answers r)))))
                   (if (equal? o '(#f (no-posts) 0 #f () (no-posts open wake) #t #f ((b 8))))
                       '(closed refused)
                       o)))))))
   (list 'absent 'serves-no-more
         (lambda ()
           (let ((r (new-rig)))
             (rig-close! r)
             (let ((o (list (rig-calls r) (waits-posted (rig-waits r)) (waits-queued? (rig-waits r)))))
               (rig-wait! r 'a)
               (let ((o (append o (list (rig-calls r)))))
                 (if (equal? o '(() 0 #f (open))) '(absent nothing) o))))))
   (list 'open 'outside-wait
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-wait! r 'b)
             (let* ((calls (rig-calls r)) (pb (rig-post! r 'b 'two)) (pa (rig-post! r 'a 'one)))
               (rig-deliver! r)
               (let ((o (list calls pb pa (length (rig-deliveries r)) (rig-answers r))))
                 (if (equal? o '((open) #t #t 1 ((b two) (a one)))) '(open shared) o))))))
   (list 'open 'post
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-wait! r 'b)
             (let* ((pa (rig-post! r 'a 7))
                    (o (list pa (rig-calls r) (waits-posted (rig-waits r)) (waits-queued? (rig-waits r))
                             (rig-answers r)))
                    (pb (rig-post! r 'b 8)))
               (let ((o (append o (list pb))))
                 (if (equal? o '(#t (open wake) 1 #t () #t)) '(open queued-and-woken) o))))))
   (list 'open 'delivery
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-wait! r 'b)
             (rig-post! r 'a 7)
             (rig-deliver! r)
             (let ((o (list (rig-answers r) (waits-posted (rig-waits r)) (waits-queued? (rig-waits r)))))
               (rig-deliver! r)
               (let* ((o (append o (list (rig-answers r) (rig-log r))))
                      (pb (rig-post! r 'b 8)))
                 (let ((o (append o (list pb))))
                   (if (equal? o '(((a 7)) 0 #f ((a 7)) () #t)) '(open emptied) o)))))))
   (list 'open 'serves-no-more
         (lambda ()
           (let ((r (new-rig)) (at-close #f))
             (rig-wait! r 'a)
             (rig-wait! r 'b)
             (rig-post! r 'a 7)
             ;; As the wake closes: the flag is already cleared, so b's post is
             ;; refused; and a's value is not yet handed over.
             (waits-outside-close! (rig-waits r)
                                   (lambda ()
                                     (rig-call! r 'close-wake)
                                     (let* ((posted (waits-posted (rig-waits r))) (pb (rig-post! r 'b 8)))
                                       (set! at-close (list posted pb)))))
             (scheduler-drain! (rig-scheduler r))
             (let* ((o (list (rig-calls r) at-close (rig-answers r) (waits-posted (rig-waits r))))
                    (pb (rig-post! r 'b 9))
                    (o (append o (list pb (rig-calls r)))))
               (if (equal? o '((open wake close-wake) (1 #f) ((a 7)) 0 #f (open wake close-wake)))
                   '(closed emptied-once-more)
                   o)))))
   (list 'open 'wake-meets-closed-handle
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-wait! r 'b)
             (rig-wake-answer-set! r #f)
             (let* ((pa (rig-post! r 'a 7))
                    (o (list pa (waits-posted (rig-waits r)) (waits-queued? (rig-waits r)) (rig-calls r)))
                    (pb (rig-post! r 'b 8))
                    (pa-again (rig-post! r 'a 9))
                    (o (append o (list pb pa-again (rig-calls r) (waits-queued? (rig-waits r))))))
               (rig-close! r)
               (let ((o (append o (list (rig-calls r) (rig-answers r)))))
                 (if (equal? o '(#f 0 #f (open wake) #f #f (open wake) #f (open wake) ()))
                     '(closed taken-back)
                     o))))))
   (list 'closed 'post
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-close! r)
             (let* ((pa (rig-post! r 'a 7))
                    (o (list pa (rig-calls r) (waits-posted (rig-waits r)) (waits-queued? (rig-waits r)))))
               (if (equal? o '(#f (open close-wake) 0 #f)) '(closed refused) o)))))
   (list 'closed 'outside-wait
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-close! r)
             (rig-wait! r 'b)
             (let* ((calls (rig-calls r)) (pb (rig-post! r 'b 8)) (pa (rig-post! r 'a 7)))
               (rig-deliver! r)
               (let ((o (list calls pb pa (length (rig-deliveries r)) (rig-answers r))))
                 (if (equal? o '((open close-wake open) #t #f 2 ((b 8)))) '(open fresh-inbox) o))))))
   (list 'closed 'outside-wait-no-posts
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-close! r)
             (rig-takes-posts?-set! r #f)
             (rig-wait! r 'b)
             (let* ((pb (rig-post! r 'b 8))
                    (o (list pb (rig-calls r) (waits-posted (rig-waits r)) (waits-queued? (rig-waits r))
                             (rig-answers r))))
               (rig-takes-posts?-set! r #t)
               (rig-wait! r 'c)
               (let* ((pc (rig-post! r 'c 9)) (pb-again (rig-post! r 'b 10)))
                 (rig-deliver! r)
                 (let ((o (append o (list (rig-calls r) pc pb-again (rig-answers r)))))
                   (if (equal? o '(#f (open close-wake no-posts) 0 #f ()
                                   (open close-wake no-posts open wake) #t #f ((c 9))))
                       '(closed refused)
                       o)))))))
   (list 'closed 'serves-no-more
         (lambda ()
           (let ((r (new-rig)))
             (rig-wait! r 'a)
             (rig-close! r)
             (rig-close! r)
             (let* ((calls (rig-calls r)) (pa (rig-post! r 'a 7)) (o (list calls pa)))
               (if (equal? o '((open close-wake) #f)) '(closed nothing) o)))))))

;; drivers-pairs : (Listof (List Symbol Symbol Procedure)) -> (Listof (List Symbol Symbol))
(define (drivers-pairs drivers) (map (lambda (d) (list (car d) (cadr d))) drivers))

;; driver-for : Drivers Row -> (-> Any)
(define (driver-for drivers row)
  (let ((d (find (lambda (d) (and (eq? (car d) (car row)) (eq? (cadr d) (cadr row)))) drivers)))
    (if d (caddr d) (lambda () (list 'no-driver (row-pair row))))))

;; label : String Row -> String
(define (label table row)
  (string-append table ": " (symbol->string (car row)) ", " (symbol->string (cadr row))
                 " -> " (symbol->string (caddr row))))

;; --- a waiting verb off the loop's thread -------------------------------------

;; What a wait off the loop's thread is refused with.
(define off-thread '(refused r2 "a wait off the loop's thread"))

;; elsewhere : (-> Any) -> Any
;; What `thunk` comes to on a thread of its own, which this one waits for:
;; `(refused name message)` for a scheduler's refusal, `(raised x)` for any
;; other raise, a condition as `condition`, or `(returned v)`.
(define (elsewhere thunk)
  (let* ((v 'never-ran)
         (t (fork-thread
             (lambda ()
               (set! v (guard (e ((scheduler-invariant? e)
                                  (list 'refused (scheduler-invariant-name e) (condition-message e)))
                                 (#t (list 'raised (if (condition? e) 'condition e))))
                         (list 'returned (thunk))))))))
    (thread-join t)
    v))

;; raising-verbs : (Symbol -> Void) -> (Listof (-> Any))
;; Calls of await-outside and of await, each register noting that it ran,
;; through `ran!`, then raising.
(define (raising-verbs ran!)
  (list (lambda () (await-outside (lambda (r) (ran! 'await-outside) (raise 'register-ran))))
        (lambda () (await (lambda (r) (ran! 'await) (raise 'register-ran))))))

;; parking-verbs : (Symbol -> Void) -> (Listof (-> Any))
;; Calls of sleep-ms, and of await-outside with a register that notes it
;; ran and returns: each parks wherever it is not refused.
(define (parking-verbs ran!)
  (list (lambda () (sleep-ms 1))
        (lambda () (await-outside (lambda (r) (ran! 'await-outside))))))

;; mid-coroutine : ((Symbol -> Void) -> (Listof (-> Any))) -> (List Any ...)
;; A host whose handler's coroutine makes each of `verbs`' calls on a
;; thread of its own, waiting for each, then answers 200 "ok": what each
;; call came to, the registers that ran, what the client saw, and the log.
(define (mid-coroutine verbs)
  (let* ((ran '()) (outcomes 'never-called)
         (h (make-test-host
             (lambda (request)
               (awaiting
                (lambda ()
                  (set! outcomes (map elsewhere (verbs (lambda (who) (set! ran (cons who ran))))))
                  (text 200 "ok"))))))
         (c (test-host-connect! h)))
    (test-client-send! c (get "/"))
    (list outcomes ran (seen c) (test-host-log h))))

;; between-calls : -> (List Any ...)
;; A host whose handler waits outside, its resume kept; between the host's
;; calls, each verb's call, raising and parking, on a thread of its own;
;; then the kept resume, called with 7, and an advance of 0.  What each call
;; came to, the registers that ran, what the resume answered, what the
;; client saw, and the log.
(define (between-calls)
  (let* ((ran '()) (kept #f)
         (h (make-test-host
             (lambda (request)
               (awaiting (lambda () (text 200 (show (await-outside (lambda (r) (set! kept r))))))))))
         (c (test-host-connect! h)))
    (test-client-send! c (get "/"))
    (let* ((ran! (lambda (who) (set! ran (cons who ran))))
           (outcomes (map elsewhere (append (raising-verbs ran!) (parking-verbs ran!))))
           (answer (kept 7)))
      (test-host-advance! h 0)
      (list outcomes ran answer (seen c) (test-host-log h)))))

(run-suite "outside"
  (lambda ()
    ;; --- the tables are sound -------------------------------------------------------
    (test-equal "the check finds each way a table is unsound: a row outside its vocabulary, two rows for a pair, a pair both a row's and impossible, a pair neither, a state unreached"
      '((outside-its-vocabulary (a go z x))
        (impossible-outside-its-vocabulary (a stop))
        (two-rows (a go))
        (impossible-twice (b go))
        (a-row-and-impossible (b go))
        (neither (c go))
        (unreached c))
      (table-faults '(a b c) '(go)
                    '((a go b x) (a go z x) (b go a y))
                    '(((b) (go) "fixture") ((b) (go) "fixture") ((a) (stop) "fixture"))))
    (test-equal "the wait's table is sound: deterministic, complete over its six states and five events, every state reached"
      '() (table-faults wait-states wait-events wait-rows wait-impossible))
    (test-equal "the resume's table is sound: deterministic, complete over its three states and two events, every state reached"
      '() (table-faults resume-states resume-events resume-rows resume-impossible))
    (test-equal "the inbox's table is sound: deterministic, complete over its three states and six events, every state reached"
      '() (table-faults inbox-states inbox-events inbox-rows inbox-impossible))
    (test-equal "each table's rows are driven, each once, and nothing else is"
      (list (map row-pair wait-rows) (map row-pair resume-rows) (map row-pair inbox-rows))
      (list (drivers-pairs wait-drivers) (drivers-pairs resume-drivers) (drivers-pairs inbox-drivers)))

    ;; --- each row, driven -----------------------------------------------------------
    (for-each (lambda (row)
                (test-equal (label "the wait" row) (cddr row) ((driver-for wait-drivers row))))
              wait-rows)
    (for-each (lambda (row)
                (test-equal (label "the resume" row)
                  (list (cadddr row) (cadddr (row-for resume-rows (caddr row) (cadr row))))
                  ((driver-for resume-drivers row))))
              resume-rows)
    (for-each (lambda (row)
                (test-equal (label "the inbox" row) (cddr row) ((driver-for inbox-drivers row))))
              inbox-rows)

    ;; --- the scripts ---------------------------------------------------------------
    (let* ((sc (outside-scene 'keep #f)) (c (scene-client sc)) (h (scene-host sc)))
      (let* ((before (list (seen c) (test-client-waiting? c) (test-host-posted h)))
             (answer ((scene-resume sc) 7))
             (posted (test-host-posted h)))
        (test-host-advance! h 0)
        (test-equal "a resume the test calls answers #t and posts the value; the host's next call hands it over, and the response carries it"
          '((() #t 0) #t 1 ((200 "7")) #f 0 ())
          (list before answer posted (seen c) (test-client-waiting? c) (test-host-posted h) (test-host-log h)))))

    (let* ((sc (outside-scene 'raise #f)) (c (scene-client sc)))
      (test-equal "a register that raises: the raise reaches the handler, nothing waits, nothing is logged"
        '(((200 "raised")) #f () 0)
        (list (seen c) (test-client-waiting? c) (test-host-log (scene-host sc)) (test-host-posted (scene-host sc)))))

    ;; The park leaves the dynamic-wind around the wait and comes back in: a
    ;; wait that parks enters it twice and leaves it twice; one answered at
    ;; once, as `await`'s whose register resumes, once each.
    (let* ((sc (outside-scene 'self #f)) (c (scene-client sc)))
      (test-equal "a register that calls resume itself: it answers #t, the handler still parks, and the value is handed over in the same run"
        '(((self #t)) 2 2 ((200 "self")) #f ())
        (list (scene-notes sc) (scene-befores sc) (scene-afters sc) (seen c) (test-client-waiting? c)
              (test-host-log (scene-host sc)))))
    (let* ((counts (vector 0 0))
           (h (make-test-host
               (lambda (request)
                 (awaiting
                  (lambda ()
                    (text 200 (show (dynamic-wind
                                     (lambda () (vector-set! counts 0 (+ 1 (vector-ref counts 0))))
                                     (lambda () (await (lambda (resume) (resume 'self))))
                                     (lambda () (vector-set! counts 1 (+ 1 (vector-ref counts 1))))))))))))
           (c (test-host-connect! h)))
      (test-client-send! c (get "/"))
      (test-equal "and await, its register resuming itself, does not park: entered and left once"
        '(1 1 ((200 "self")))
        (list (vector-ref counts 0) (vector-ref counts 1) (seen c))))

    (let* ((sc (outside-scene 'keep 50)) (c (scene-client sc)) (h (scene-host sc)))
      (test-host-advance! h 50)
      (let* ((answer ((scene-resume sc) 7)) (posted (test-host-posted h)))
        (test-host-advance! h 0)
        (test-equal "a deadline of 50 ms passes, then the resume: &deadline-passed, the resume answers #t, the value is dropped, nothing is logged"
          '(((504 "late")) #t 1 0 ())
          (list (seen c) answer posted (test-host-posted h) (test-host-log h)))))

    (let* ((sc (outside-scene 'keep #f)) (c (scene-client sc)) (h (scene-host sc)))
      (test-client-close! c)
      (let* ((answer ((scene-resume sc) 7)) (posted (test-host-posted h)))
        (test-host-advance! h 0)
        (test-equal "the client closes, then the resume: &client-closed, the resume answers #t, the value is dropped, no handler-failed and no line logged"
          '((client-closed) #t 1 0 () () #t)
          (list (scene-notes sc) answer posted (test-host-posted h) (test-host-log h) (seen c)
                (test-client-connection-closed? c)))))

    ;; Dropped, a value is let go: the check holds it only weakly, and keeps
    ;; the resume it was posted with.
    (let ((dropped
           (lambda (ms end!)
             (let* ((sc (outside-scene 'keep ms)) (h (scene-host sc))
                    (value (weak-cons (make-bytevector 1000 7) #f)))
               (end! sc)
               (let ((answer ((scene-resume sc) (car value))))
                 (test-host-advance! h 0)
                 (collect (collect-maximum-generation))
                 (list answer (if (bwp-object? (car value)) 'let-go 'held)
                       (if (procedure? (scene-resume sc)) 'resume-kept 'resume-gone)))))))
      (test-equal "a value dropped is let go, though its resume is kept: posted to a wait a deadline ended, and to one a client's close ended"
        '((#t let-go resume-kept) (#t let-go resume-kept))
        (list (dropped 50 (lambda (sc) (test-host-advance! (scene-host sc) 50)))
              (dropped #f (lambda (sc) (test-client-close! (scene-client sc)))))))

    ;; A register that itself waits, its resume called while it does.
    (let* ((sc (outside-scene 'sleep #f)) (c (scene-client sc)) (h (scene-host sc)))
      (let ((answer ((scene-resume sc) 7)))
        (test-host-advance! h 10)
        (test-host-advance! h 1000)
        (test-equal "a register that sleeps 10 ms, its resume called meanwhile: the value is kept and answered as register returns, 200 7, nothing logged, the handler not waiting"
          '(#t ((200 "7")) () #f 0)
          (list answer (seen c) (test-host-log h) (test-client-waiting? c) (test-host-posted h)))))

    (let* ((sc (outside-scene 'keep #f)) (c (scene-client sc)) (h (scene-host sc)) (r (scene-resume sc)))
      (let* ((first (r 7)) (second (r 8)) (posted (test-host-posted h)))
        (test-host-advance! h 0)
        (test-equal "a resume called twice: #t, then #f; one value is posted, the notice not counted; the handler gets the first; one late-resume await-outside is logged"
          '(#t #f 1 ((200 "7")) ((late-resume await-outside)))
          (list first second posted (seen c) (test-host-log h)))))

    ;; A stop of posts: a value posted before it is handed over by it; every
    ;; resume of the inbox answers #f after it, and the handler it was for
    ;; still waits; the next outside wait opens a fresh inbox.
    (let* ((sc (outside-scene 'keep #f)) (h (scene-host sc))
           (c1 (scene-client sc)) (c2 (scene-connect! sc)) (c3 (scene-connect! sc)))
      (let ((r1 (car (scene-kept sc))) (r2 (cadr (scene-kept sc))) (r3 (caddr (scene-kept sc))))
        (let* ((before (r2 'before)) (posted-before (list before (test-host-posted h))))
          (test-host-stop-posts! h)
          (let* ((after-stop (list (seen c2) (test-host-posted h)))
                 (fresh (r1 7))
                 (used (r2 'again))
                 (posted (test-host-posted h)))
            (test-host-advance! h 0)
            (test-equal "a stop of posts hands over the value posted before it; then a fresh resume answers #f, its handler still waits, and a used one answers #f and logs nothing"
              '((#t 1) (((200 "before")) 0) #f #f 0 #t () ())
              (list posted-before after-stop fresh used posted (test-client-waiting? c1) (seen c1)
                    (test-host-log h)))
            (let* ((c4 (scene-connect! sc)) (r4 (cadddr (scene-kept sc))))
              (let* ((new (r4 'fresh)) (old (r3 'old)) (posted (test-host-posted h)) (late (r1 'late)))
                (test-host-advance! h 0)
                (test-equal "after it, the next outside wait opens a fresh inbox: its resume answers #t and is handed over, and the old inbox's resumes still answer #f, logging nothing"
                  '(#t #f #f 1 ((200 "fresh")) #t #t ())
                  (list new old late posted (seen c4) (test-client-waiting? c1) (test-client-waiting? c3)
                        (test-host-log h)))))))))

    (let* ((sc (outside-scene 'keep #f)) (h (scene-host sc))
           (c1 (scene-client sc)) (c2 (scene-connect! sc)))
      (let* ((r1 (car (scene-kept sc))) (r2 (cadr (scene-kept sc)))
             (second (r2 'two))
             (first (r1 'one))
             (answers (list second first))
             (posted (test-host-posted h)))
        (test-host-advance! h 0)
        (test-equal "two handlers wait; the second is resumed first: each gets its own value"
          '((#t #t) 2 ((200 "one")) ((200 "two")) ())
          (list answers posted (seen c1) (seen c2) (test-host-log h)))))

    ;; A value and a deadline: the first to reach the wait on the loop wins.
    ;; The handler notes the host's clock as the value reaches it.
    (let* ((kept #f) (at #f) (box #f)
           (h (make-test-host
               (lambda (request)
                 (awaiting
                  (lambda ()
                    (guard (e ((deadline-passed? e) (text 504 "late")))
                      (with-deadline 50
                        (lambda ()
                          (let ((v (await-outside (lambda (r) (set! kept r)))))
                            (set! at (test-host-now box))
                            (text 200 (show v)))))))))))
           (c (test-host-connect! h)))
      (set! box h)
      (test-client-send! c (get "/"))
      (let ((answer (kept 7)))
        (test-host-advance! h 50)
        (test-equal "a value posted before an advance that passes its 50 ms deadline is handed over first, at the host's clock before it moves: the response carries it, nothing is logged"
          '(#t 0 ((200 "7")) () 0 50)
          (list answer at (seen c) (test-host-log h) (test-host-posted h) (test-host-now h)))))
    (let* ((sc (outside-scene 'keep 50)) (c (scene-client sc)) (h (scene-host sc)))
      (test-host-advance! h 50)
      (let* ((answer ((scene-resume sc) 7)) (posted (test-host-posted h)))
        (test-host-advance! h 0)
        (test-equal "and a deadline that passes before the value is posted wins: 504, the resume answers #t, nothing is logged, and nothing is left posted after the next call"
          '(((504 "late")) #t 1 () 0)
          (list (seen c) answer posted (test-host-log h) (test-host-posted h)))))

    ;; Another handler's code, on the loop's thread, posts: the value is
    ;; handed over in the next round of the run that posted it.
    (let* ((kept #f)
           (h (make-test-host
               (lambda (request)
                 (if (string=? (request-path request) "/wait")
                     (awaiting (lambda () (text 200 (show (await-outside (lambda (r) (set! kept r)))))))
                     (text 200 (if (eq? (kept 'from-wake) #t) "posted" "refused"))))))
           (c1 (test-host-connect! h))
           (c2 (test-host-connect! h)))
      (test-client-send! c1 (get "/wait"))
      (test-client-send! c2 (get "/wake"))
      (test-equal "a handler that calls another's resume, on the loop's thread: it answers #t, and the value is handed over in the same run"
        '(((200 "from-wake")) ((200 "posted")) 0 ())
        (list (seen c1) (seen c2) (test-host-posted h) (test-host-log h))))

    ;; A taker's coroutine waits outside, as a handler's does.
    (let* ((kept #f)
           (h (make-test-host
               (lambda (request)
                 (switch-protocols
                  (list (cons (b "Upgrade") (b "echo")))
                  (lambda (t retained)
                    (awaiting
                     (lambda ()
                       (transport-write! t (b (show (await-outside (lambda (r) (set! kept r)))))))))))))
           (c (test-host-connect! h)))
      (test-client-send! c (b "GET /echo HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\n"))
      (let* ((n (bytevector-length (test-client-received c)))
             (answer (kept 7)))
        (test-host-advance! h 0)
        (let ((all (test-client-received c)))
          (test-equal "a taker's coroutine waits outside: its resume answers #t, and what it writes after the 101 carries the value"
            '((101) #t "7" ())
            (list (map test-response-status (test-client-responses c)) answer
                  (utf8->string (let ((o (make-bytevector (- (bytevector-length all) n))))
                                  (bytevector-copy! all n o 0 (bytevector-length o))
                                  o))
                  (test-host-log h))))))

    ;; --- refused -----------------------------------------------------------------
    (let* ((called '())
           (on-none (refused 'await-outside (lambda () (await-outside (lambda (r) (set! called (cons 'top called)))))))
           (failed #f)
           (h (make-test-host
               (lambda (request)
                 (await-outside (lambda (r) (set! called (cons 'plain called))))
                 (text 200 "not here"))))
           (c (test-host-connect! h)))
      (test-client-send! c (get "/"))
      (test-equal "await-outside on no coroutine is refused, naming it, before register runs; in a plain handler too, which fails: 500, logged handler-failed"
        '(refused () (500) (handler-failed))
        (list on-none called (map test-response-status (test-client-responses c)) (map car (test-host-log h)))))

    (let* ((box #f)
           (h (make-test-host
               (lambda (request)
                 (awaiting (lambda () (text 200 (show (refused 'test-host-stop-posts! (lambda () (test-host-stop-posts! box))))))))))
           (c (test-host-connect! h)))
      (set! box h)
      (test-client-send! c (get "/"))
      (test-equal "a stop of posts made from the host's own code is refused there, as every call that acts is"
        '((200 "refused"))
        (seen c)))

    ;; --- a waiting verb off the loop's thread -------------------------------------
    ;; The calls that would park on the worker come last: a park there
    ;; would jump into the loop's thread's drain from the worker.
    (test-equal "while the loop's thread runs a handler's coroutine, which waits for a worker: await-outside and await from the worker are each refused there as R2, off the loop's thread, no register runs, and the coroutine answers as before"
      (list (list off-thread off-thread) '() '((200 "ok")) '())
      (mid-coroutine raising-verbs))
    (test-equal "between the host's calls, a handler parked outside: await-outside, await and sleep-ms from a worker are each refused there as R2, off the loop's thread, no register runs, and the handler's own resume is handed over as before"
      (list (make-list 4 off-thread) '() #t '((200 "7")) '())
      (between-calls))
    (test-equal "while the loop's thread runs a handler's coroutine, which waits for a worker: sleep-ms, and await-outside with a register that returns, from the worker are each refused there as R2, off the loop's thread, no register runs, and the coroutine answers as before"
      (list (list off-thread off-thread) '() '((200 "ok")) '())
      (mid-coroutine parking-verbs))

    ;; --- the inbox's delivery --------------------------------------------------------
    (let ((r (new-rig)))
      (for-each (lambda (name) (rig-wait! r name)) '(a b c))
      (rig-post! r 'c 3)
      (rig-post! r 'a 1)
      (rig-post! r 'b 2)
      (rig-deliver! r)
      (test-equal "the delivery hands values over in the order they were posted"
        '((c 3) (a 1) (b 2))
        (rig-answers r)))

    ;; A log that raises: the notice of a's second call is queued before b's
    ;; value, which is handed over all the same.
    (let* ((r (new-rig))
           (s (rig-scheduler r))
           (w (make-waits s (lambda (what details) (raise (list 'log-raised what details))))))
      (waits-outside! w (lambda (deliver!) (rig-deliveries-set! r (cons deliver! (rig-deliveries r))) (lambda () #t)))
      (rig-waits-set! r w)
      (rig-wait! r 'a)
      (rig-wait! r 'b)
      (rig-post! r 'a 1)
      (rig-post! r 'a 'again)
      (rig-post! r 'b 2)
      (let ((raised (guard (e ((pair? e) e)) ((car (rig-deliveries r))) 'no-raise)))
        (scheduler-drain! s)
        (test-equal "the delivery hands over every value before it logs any notice: a log that raises loses no value"
          '((log-raised late-resume (await-outside)) ((a 1) (b 2)) #f)
          (list raised (rig-answers r) (waits-queued? w)))))))
