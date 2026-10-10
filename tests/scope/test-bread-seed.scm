;;; test-bread-seed.scm — the bread town is ONE economy behind two doors.
;;;
;;; bread-world ((playnet knowledge recipes bread-commune-seed)) is read
;;; through two doors: (playnet test scope) mock-world, stores that answer with
;;; its tables, and seed-world! into a scope-root's REAL stores — the gateway's
;;; demo commune path (server/gateway.scm, PLAYNET_SEED_DEMO) and what
;;; spawn-bread-scope does. This proves the two doors open onto the same plan:
;;; same demand, same work per process, same met, through a real recipe-store's
;;; own process-chain sort and a real observer's stock. A drift between the
;;; mocked reads and the seeded stores shows here first.
;;;
;;; Run: guile --no-auto-compile -q -L module -L tests tests/scope/test-bread-seed.scm

(use-modules (playnet test harness)
             (playnet test scope)
             (playnet knowledge recipes bread-commune-seed) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet knowledge dsl world)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define demand '(("bread#town@0" . 10.0)))

(define (solve-both w)
  "(place mock-result live-result chain stock) for one configuration of the town."
  (with-vat (spawn-vat #:name "bread-seed")
    (let* ((mock (mock-world w))
           (root (spawn-scope-root "bread-seed"))
           (place (seed-bread-commune! root #:world w)))
      (list place
            (plan-scope->alist mock #:demand demand)
            (plan-scope->alist root #:demand demand)
            ($ ($ root 'recipe-store) 'get-process-chain "bread-recipe")
            ($ ($ root 'observer) 'all-resources)))))

;; the two doors agree to the solver's own certificate: each solve stops at a
;; stationarity near 1e-4, so two paths through the same LP land within that of
;; each other, and the door is proven the same by agreeing to it
(define (~= a b) (< (abs (- a b)) (* 1e-4 (max 1.0 (abs a)))))
(define (met-of r) (or (assq-ref r 'met) 0))
(define (same-work? m l)
  (every (lambda (p) (let ((a (bread-hours m p)) (b (bread-hours l p)))
                       (< (abs (- a b)) (* 1e-4 (max 1.0 (abs a))))))
         '("grow" "mill" "bake")))

(display "\n── the live configuration: farmer, ada, bob on a clock ──\n")
(let* ((out (solve-both bread-world))
       (place (list-ref out 0)) (m (list-ref out 1)) (l (list-ref out 2))
       (chain (list-ref out 3)) (stock (list-ref out 4)))
  (check "seed-bread-commune! returns the town the demand names" (equal? place "town"))
  (check "the real recipe-store sorts the seeded recipe into grow → mill → bake"
         (equal? (map recipe-process-id chain) '("grow" "mill" "bake")))
  (check "the real observer holds every seeded resource"
         (= (length stock) (length (world-resources bread-world))))
  (check "the mocked door meets the demand" (> (met-of m) 0))
  (check "the seeded door meets the same demand to the same degree" (~= (met-of m) (met-of l)))
  (check "…and emits the same work per process (grow, mill, bake)" (same-work? m l))
  (check "the work is real: every process ran" (> (bread-hours l "bake") 0)))

(display "\n── the plain configuration: one worker per skill, no clock ──\n")
(let* ((out (solve-both bread-plain-world))
       (m (list-ref out 1)) (l (list-ref out 2)))
  (check "both doors meet the demand alike" (~= (met-of m) (met-of l)))
  (check "…and agree on the work per process" (same-work? m l)))

(test-summary!)
