;;; test-fold-laws.scm — the algebra of the folds the federation sums.
;;;
;;; A parent recombines its children in hashmap order, so a combine must be
;;; associative and commutative; and which folds are also IDEMPOTENT decides
;;; whether the same fact arriving twice is harmless. The table in
;;; docs/planning/federation/federation-identity-and-folds.md §3 names each; this holds the
;;; three it asserts, over randomized inputs from a fixed seed:
;;;
;;;   • the labour roster's `pool-merge` is a join: commutative, associative and
;;;     IDEMPOTENT — the same person arriving twice changes nothing;
;;;   • the credit combine is commutative and associative, idempotent only on the
;;;     kinds that are one fact about one person (citizen, ccf, unmet) and NOT on
;;;     the sums (gross, claimed): a fact arriving twice there is added twice;
;;;   • the keyed sum (demand, means, voice, slack) is commutative and associative
;;;     and NOT idempotent — it is sound exactly when each fact has one home, which
;;;     is what the home buys (tests/planner/test-one-citizen.scm).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-fold-laws.scm

(use-modules (playnet test harness)
             (playnet vf schemas) (playnet vf beyond schedules) (srfi srfi-1)
             (playnet pools availability-pool)
             ((playnet algorithms elastic) #:select (credit-combine))
             ((playnet vf aggregation fold-node) #:select (keyed-sum-monoid monoid-combine))
             (srfi srfi-1))

;; a fixed-seed generator: the same inputs every run
(define next-state (make-rng 20261002))
(define (rnd n) (modulo (quotient (next-state) 65536) n))
(define (pick l) (list-ref l (rnd (length l))))

;; hours, windows and places come from small sets, so two arrivals of one person
;; often tie on hours and differ in what else they carry: the join must still
;; pick the same one whichever arrives first
(define windows
  (list #f
        (make-availability-window #f #f (list (make-day-schedule '(monday) (list (make-time-range "09:00" "12:00")))) #f)
        (make-availability-window #f #f (list (make-day-schedule '(tuesday) (list (make-time-range "09:00" "12:00")))) #f)))
(define (rand-entry)
  (make-entry (pick '("ada" "bo" "cy" "di")) (pick '("bake" "mill" "sew"))
              (pick windows) (pick '("town" "farm")) (exact->inexact (+ 1 (rnd 3)))))
(define (rand-pool)
  (let loop ((n (rnd 6)) (p (make-labour-pool)))
    (if (zero? n) p (loop (- n 1) (pool-add p (rand-entry))))))
;; a pool as a canonical list, so two pools compare by what they hold
(define (canon pool)
  (sort (map (lambda (e) (list (entry-agent e) (entry-skill e) (entry-hours e)
                               (entry-window e) (entry-cell e) (entry-place e) (entry-away e)))
             (pool-entries pool))
        (lambda (a b) (string<? (object->string a) (object->string b)))))
;; pools as the roster holds them: one entry per (agent, skill)
(define (roster-pool) (pool-merge (make-labour-pool) (rand-pool)))

(define (law-holds? n gen law) (every (lambda (_) (law (gen))) (iota n)))

(display "\n── pool-merge is a join ──\n")
(check "commutative" (law-holds? 200 (lambda () (list (roster-pool) (roster-pool)))
                                 (lambda (ab) (equal? (canon (pool-merge (car ab) (cadr ab)))
                                                      (canon (pool-merge (cadr ab) (car ab))))))
       #t)
(check "associative" (law-holds? 200 (lambda () (list (roster-pool) (roster-pool) (roster-pool)))
                                 (lambda (abc)
                                   (equal? (canon (pool-merge (pool-merge (car abc) (cadr abc)) (caddr abc)))
                                           (canon (pool-merge (car abc) (pool-merge (cadr abc) (caddr abc)))))))
       #t)
(check "idempotent: a person arriving twice is one person"
       (law-holds? 200 roster-pool (lambda (a) (equal? (canon (pool-merge a a)) (canon a)))) #t)

(display "\n── the credit combine ──\n")
(define (rand-cells)
  (delete-duplicates
   (let loop ((n (+ 1 (rnd 6))) (acc '()))
     (if (zero? n) acc
         (loop (- n 1)
               (cons (cons (cons (pick '(gross claimed ccf unmet citizen)) (pick '("ada" "bo" "cy")))
                           (exact->inexact (+ 1 (rnd 9))))
                     acc))))
   (lambda (a b) (equal? (car a) (car b)))))
(define (canon-cells cs) (sort cs (lambda (a b) (string<? (object->string a) (object->string b)))))
(check "commutative" (law-holds? 200 (lambda () (list (rand-cells) (rand-cells)))
                                 (lambda (ab) (equal? (canon-cells (credit-combine (car ab) (cadr ab)))
                                                      (canon-cells (credit-combine (cadr ab) (car ab))))))
       #t)
(check "associative" (law-holds? 200 (lambda () (list (rand-cells) (rand-cells) (rand-cells)))
                                 (lambda (abc)
                                   (equal? (canon-cells (credit-combine (credit-combine (car abc) (cadr abc)) (caddr abc)))
                                           (canon-cells (credit-combine (car abc) (credit-combine (cadr abc) (caddr abc)))))))
       #t)
(check "a person's capacity and citizenship are one fact: arriving twice changes nothing"
       (let ((a '((((citizen . "ada") . 1) ((ccf . "ada") . 0.5) ((unmet . "ada") . 0.5)))))
         (equal? (canon-cells (credit-combine (car a) (car a))) (canon-cells (car a))))
       #t)
(check "a person's ccf resolves to the lower reading, whichever arrives first"
       (list (cdr (assoc '(ccf . "ada") (credit-combine '(((ccf . "ada") . 0.5)) '(((ccf . "ada") . 0.8)))))
             (cdr (assoc '(ccf . "ada") (credit-combine '(((ccf . "ada") . 0.8)) '(((ccf . "ada") . 0.5))))))
       '(0.5 0.5))
(check "and their unmet to the larger"
       (list (cdr (assoc '(unmet . "ada") (credit-combine '(((unmet . "ada") . 0.2)) '(((unmet . "ada") . 0.7)))))
             (cdr (assoc '(unmet . "ada") (credit-combine '(((unmet . "ada") . 0.7)) '(((unmet . "ada") . 0.2))))))
       '(0.7 0.7))
(check "labour is not: gross arriving twice is added twice"
       (cdr (assoc '(gross . "ada") (credit-combine '(((gross . "ada") . 4.0)) '(((gross . "ada") . 4.0)))))
       8.0)

(display "\n── the keyed sum ──\n")
(define ksum (monoid-combine keyed-sum-monoid))
(define (rand-keyed)
  (delete-duplicates
   (let loop ((n (+ 1 (rnd 5))) (acc '()))
     (if (zero? n) acc (loop (- n 1) (cons (cons (pick '("bread" "milk" "oil" "salt")) (exact->inexact (+ 1 (rnd 9)))) acc))))
   (lambda (a b) (equal? (car a) (car b)))))
(define (canon-keyed cs) (sort cs (lambda (a b) (string<? (car a) (car b)))))
(check "commutative" (law-holds? 200 (lambda () (list (rand-keyed) (rand-keyed)))
                                 (lambda (ab) (equal? (canon-keyed (ksum (car ab) (cadr ab)))
                                                      (canon-keyed (ksum (cadr ab) (car ab))))))
       #t)
(check "associative" (law-holds? 200 (lambda () (list (rand-keyed) (rand-keyed) (rand-keyed)))
                                 (lambda (abc)
                                   (equal? (canon-keyed (ksum (ksum (car abc) (cadr abc)) (caddr abc)))
                                           (canon-keyed (ksum (car abc) (ksum (cadr abc) (caddr abc)))))))
       #t)
(check "not idempotent: a want arriving twice is two wants"
       (ksum '(("bread" . 3.0)) '(("bread" . 3.0))) '(("bread" . 6.0)))

(test-summary!)
