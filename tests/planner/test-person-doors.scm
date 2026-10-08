;;; test-person-doors.scm — every planner door that takes a person is classified.
;;;
;;; A planner door whose second argument is a person (agent-id, aid, worker,
;;; inviter, claimant) either states that person's standing — it routes to
;;; their home — or acts at the scope the call names. `person-facts.scm` holds
;;; the three lists; this test refuses a door in none of them, a name in a list
;;; that is no door, and a name in two lists. A new person-door fails here until
;;; it is classified.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-person-doors.scm

(use-modules (playnet test harness)
             (playnet protocol)
             (playnet planner facts person-facts)
             (srfi srfi-1))

(define planner-doors (doors-of 'planner))
(define (args-of d) (let ((a (door-args d))) (if (list? a) a '())))
(define (names-person-second? d)           ; a person named anywhere among the arguments
  (any (lambda (x) (and (symbol? x) (person-door-argument? x))) (args-of d)))
(define classified (append person-write-doors person-read-doors scope-subject-doors))

(display "\n── every planner door that takes a person is classified ──\n")
(let ((loose (filter-map (lambda (d) (and (names-person-second? d)
                                          (not (memq (door-name d) classified))
                                          (door-name d)))
                         planner-doors)))
  (check "no person-door is left unclassified" loose '()))

(display "\n── the lists name real doors, once ──\n")
(let ((names (map door-name planner-doors)))
  (check "every classified name is a planner door"
         (remove (lambda (n) (memq n names)) classified) '())
  (check "no door is in two lists"
         (length classified) (length (delete-duplicates classified))))

(display "\n── the doors that write a person's standing take the person where the table says ──\n")
(define (person-at-position? d)
  (let ((a (args-of d)) (k (person-argument-position (door-name d))))
    (and (>= (length a) k) (symbol? (list-ref a (- k 1))) (person-door-argument? (list-ref a (- k 1))))))
(check "each routed door's person is the argument its position names"
       (remove (lambda (n)
                 (let ((d (find (lambda (d) (eq? (door-name d) n)) planner-doors)))
                   (and d (person-at-position? d))))
               (append person-write-doors person-read-doors))
       '())

(test-summary!)
