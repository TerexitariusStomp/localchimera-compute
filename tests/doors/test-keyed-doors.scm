;;; test-keyed-doors.scm — every door declared `#:keyed` answers a repeat of one act with what it recorded.
;;;
;;; A keyed door (doors/protocol.scm, `#:keyed tap`) takes a token its caller minted for
;;; ONE act; the same token on the same subject is the same act. That promise is the
;;; door's, so it is stated here once for the whole registry rather than door by door:
;;;
;;;   COVERED   every keyed door has a fixture below, and every fixture names a keyed door,
;;;             so a door cannot be declared keyed and go untested, nor a fixture outlive it
;;;   REPEAT    a fixture presses its door twice with one token: both answer ok, the second
;;;             says `again`, and the books hold what the first recorded and nothing more
;;;   ANOTHER   a press with another token is another act
;;;
;;; A fixture is a procedure of no arguments returning three procedures: (press TOKEN) sends
;;; the door's request and answers its reply, (recorded) counts what the books hold of the act,
;;; and (same? FIRST SECOND) says the second reply is the first's, answered again. A door that
;;; only forwards (a session door the lobby hands to the planner) names its executor's fixture.
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/doors/test-keyed-doors.scm

(use-modules (playnet test harness) (playnet test books)
             (playnet vf schemas) (playnet doors protocol)
             ((playnet vf formulas flows) #:select (make-work-commitment))
             (playnet doors service)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-11))

(define %standing (@@ (playnet doors service) %standing))   ; the live service's reads; its cache exists once a service is spawned
(define (cache-solve! sid demand alist) ((@ (playnet doors planner solve-cache) cache-solve!) (%standing 'cache) sid demand alist))
(define (row id act spec qty place in)
  `((id . ,id) (action . ,act) (conforms-to . ,spec) (quantity . ,qty) (at-location . ,place)
    (input-of . ,in) (output-of . #f) (when . "2026-10-02") (note . #f)))

(define (scope+service)
  (let-values (((vat scope) (fresh-scope)))
    (values vat scope
            (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
            (with-vat vat ($ scope 'observer)))))

(define (flow-fixture)
  (let-values (((vat scope svc obs) (scope+service)))
    (let ((rid "mc|consume|water|P|A||2026-10-02"))
      (with-vat vat
        ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
        (cache-solve! "org:t" '() `((material . (,(row rid 'consume "water" 10.0 "A" "P"))))))
      (values (lambda (token) (with-vat vat ($ svc 'record-flow "org:t" "consume" "water" 3.0 3.0 "A" "2026-10-02" "P" #f rid token)))
              (lambda () (with-vat vat (length (or ($ obs 'fulfilled-by rid) '()))))
              (lambda (first second) (and (assq-ref (cdr second) 'again) #t))))))

(define (effort-fixture)
  (let-values (((vat scope svc obs) (scope+service)))
    (with-vat vat
      ($ ($ scope 'plan-store) 'add-commitment
         (make-work-commitment #:id "c-4h" #:provider "ana" #:skill "baking" #:hours 4.0)))
    (values (lambda (token) (with-vat vat ($ svc 'record-effort "org:t" "c-4h" "ana" 1.0 "hours" token)))
            (lambda () (with-vat vat (length (or ($ obs 'fulfilled-by "c-4h") '()))))
            (lambda (first second) (equal? first second)))))

(define fixtures
  `(((planner . record-flow)   . ,flow-fixture)
    ((planner . record-effort) . ,effort-fixture)
    ((session . record-effort) . (planner . record-effort))))     ; the lobby forwards it, token and all

(display "\n── COVERED: every keyed door has a fixture, and every fixture a keyed door ──\n")
(let ((keyed (map (lambda (d) (cons (door-object d) (door-name d))) (doors-keyed)))
      (fixed (map car fixtures)))
  (check "no keyed door goes untested" (lset-difference equal? keyed fixed) '())
  (check "no fixture outlives its door's marker" (lset-difference equal? fixed keyed) '()))

(for-each
 (lambda (fx)
   (display (format #f "\n── ~a ~a: a repeat is answered, another token is another act ──\n" (caar fx) (cdar fx)))
   (let* ((fixture (if (pair? (cdr fx)) (cdr (assoc (cdr fx) fixtures)) (cdr fx))))
     (let-values (((press recorded same?) (fixture)))
       (let* ((first (press "tok1")) (n (recorded)) (second (press "tok1")))
         (check "the press lands" (ok? first) #t)
         (check "the same token again is answered ok, as the same act" (list (ok? second) (same? first second)) '(#t #t))
         (check "…and the books hold what the first recorded and nothing more" (recorded) n)
         (check "another token is another act" (begin (press "tok2") (> (recorded) n)) #t)))))
 fixtures)

(display "\n── record-effort: a repeat of the press that FINISHED the block is the same act, not a refusal ──\n")
(let-values (((vat scope svc obs) (scope+service)))
  (with-vat vat
    ($ ($ scope 'plan-store) 'add-commitment
       (make-work-commitment #:id "c-1h" #:provider "ana" #:skill "baking" #:hours 1.0)))
  (let* ((press (lambda (hours token) (with-vat vat ($ svc 'record-effort "org:t" "c-1h" "ana" hours "hours" token))))
         (first (press 1.0 "done")))
    (check "the press that records the whole hour lands" (ok? first) #t)
    (check "…and a press with no token is now refused: the block is finished"
           (refused? (press 1.0 #f)) #t)
    (check "…but the same press arriving again is answered with its event"
           (equal? (press 1.0 "done") first) #t)))

(test-summary!)
