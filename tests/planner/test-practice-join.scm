;;; test-practice-join.scm — a person's practice is theirs wherever they worked.
;;;
;;; A work event is recorded in the scope where the work was done, so Ada's
;;; baking lies in two observers. Competence, the hours a conformance threshold
;;; asks for and the profile all read her practice; each read joins the rows of
;;; every observer by event id (planner/observation/practice.scm). An event recorded at both
;;; is one event; a second scope adds its own events and no more.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-practice-join.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes federation-demo) (playnet planner scope root) (srfi srfi-1)
             (playnet planner doors service)
             ((playnet planner scope live) #:select (practice-view-of))
             ((playnet planner observation practice) #:select (practice-view-hours practice-view-dated practice-rows-join))
             ((playnet test scope) #:select (record-work!))
             (playnet planner knowledge recipes federation-demo)
             (goblins) (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat))

(display "\n── the join, on rows ──\n")
(check "an event in two lists stands once"
       (practice-rows-join '(((e1 "baking" 1 4.0) (e2 "baking" 2 6.0)) ((e1 "baking" 1 4.0) (e3 "milling" 3 2.0))))
       '((e1 "baking" 1 4.0) (e2 "baking" 2 6.0) (e3 "milling" 3 2.0)))

(display "\n── Ada's baking lies at two scopes ──\n")
(with-vat vat
  (let* ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
         (svc (spawn ^planner-service (hashmap)))
         (oa ($ a 'observer)) (ob ($ b 'observer)))
    (seed-fed-commune! a "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
    (seed-fed-commune! b "fed" "commune-table" "Table" "venue-table" 42.75 23.40 0.0)
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    (record-work! oa "ada" 10 "ev-a1" "in-a1" #:skill "baking" #:when "2026-03-01T08:00:00Z")
    (record-work! ob "ada" 6 "ev-b1" "in-b1" #:skill "baking" #:when "2026-03-02T08:00:00Z")
    ;; the same event told to both observers (a replica, a copy)
    (record-work! oa "ada" 4 "ev-shared" "in-s-a" #:skill "baking" #:when "2026-03-03T08:00:00Z")
    (record-work! ob "ada" 4 "ev-shared" "in-s-b" #:skill "baking" #:when "2026-03-03T08:00:00Z")

    (define (baking view) (assoc-ref (practice-view-hours view "ada") "baking"))
    (check "read at the Granary alone, 14 hours: its own and the shared event"
           (baking (practice-view-of oa '())) 14)
    (check "read at the Table alone, 10"
           (baking (practice-view-of ob '())) 10)
    (check "read across both: 10 + 6 + 4, the shared event once"
           (baking (practice-view-of oa (list ob))) 20)
    (check "whichever scope asks, the same figure"
           (baking (practice-view-of ob (list oa))) 20)
    (check "the observer's own hours ledger is the sum of its rows"
           (list (assoc-ref ($ oa 'skill-hours-of "ada") "baking")
                 (apply + (map cadddr ($ oa 'work-practice "ada"))))
           '(14 14))
    (check "dated, the practice is three distinct days"
           (length (practice-view-dated (practice-view-of oa (list ob)) "ada" "baking")) 3)

    (display "\n── the profile reads the whole record ──\n")
    (let* ((r ($ svc 'skill-standing "Granary" "ada"))
           (row (and (eq? (car r) 'ok)
                     (find (lambda (x) (equal? (assq-ref x 'skill) "baking")) (assq-ref (cdr r) 'standing)))))
      (check "her baking stands at 20 hours through the Granary" (and row (assq-ref row 'hours)) 20)
      (check "and her competence under the ledger's law is the same figure" (and row (assq-ref row 'competence)) 20.0))
    (let* ((r ($ svc 'skill-standing "Table" "ada"))
           (row (and (eq? (car r) 'ok)
                     (find (lambda (x) (equal? (assq-ref x 'skill) "baking")) (assq-ref (cdr r) 'standing)))))
      (check "asked through the Table the figure is the same" (and row (assq-ref row 'hours)) 20))))

(test-summary!)
