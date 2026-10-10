;;; test-skill-compose.scm — effective-skills conformance closure (Stage 5b)
;;;
;;; Pure function: held ∪ transitive closure of satisfied-by clauses met at
;;; ≥ N validated hours. No ACDCs ⇒ no blake3.
;;;
;;; Read from (playnet vf formulas skill-law) — the LIVE closure, the one
;;; conformance-agent-skills hands the solver. A second copy of this function
;;; lives on under (playnet deprecated planner), and this suite used to import
;;; that one: byte-identical today, and a green here said nothing whatever about
;;; the code a plan actually runs. test-skill-matching.scm proves the live
;;; closure reaches a solve; this one states what it means.
;;;
;;; Run: guile -L module tests/planner/test-skill-compose.scm

(use-modules (playnet test harness))
(use-modules ((playnet vf formulas skill-law) #:select (effective-skills)))
(use-modules (srfi srfi-1))

;; electrosurgeon = (electrician ≥200h ∧ surgeon ≥150h); master = (electrosurgeon ≥50h)
(define catalogue
  '(("electrosurgeon" . ((("electrician" . 200) ("surgeon" . 150))))
    ("master"         . ((("electrosurgeon" . 50))))))

(define (hours-table alist) (lambda (s) (or (assoc-ref alist s) 0)))  ; assoc-ref: string keys (equal?)

(display "\n── Composite qualification (one person, both skills) ──\n")
(let ((eff (effective-skills '("electrician" "surgeon") catalogue
                             (hours-table '(("electrician" . 250) ("surgeon" . 160))))))
  (check-pred "holds electrician directly" (member "electrician" eff))
  (check-pred "holds surgeon directly"     (member "surgeon" eff))
  (check-pred "qualifies for electrosurgeon via substitute" (member "electrosurgeon" eff)))

(display "\n── Below the hours threshold ⇒ no substitute ──\n")
(let ((eff (effective-skills '("electrician" "surgeon") catalogue
                             (hours-table '(("electrician" . 250) ("surgeon" . 100))))))  ; surgeon < 150
  (check-pred "surgeon under threshold blocks electrosurgeon"
              (not (member "electrosurgeon" eff))))

(display "\n── Missing a component ⇒ no substitute ──\n")
(let ((eff (effective-skills '("electrician") catalogue
                             (hours-table '(("electrician" . 500))))))
  (check-pred "electrician alone is not electrosurgeon"
              (not (member "electrosurgeon" eff))))

(display "\n── Transitivity needs REAL hours in the derived skill ──\n")
;; Worker qualifies for electrosurgeon via substitute (0 practiced electrosurgeon
;; hours). master needs electrosurgeon ≥50h — derived-but-unpractised ⇒ NOT master.
(let ((eff (effective-skills '("electrician" "surgeon") catalogue
                             (hours-table '(("electrician" . 250) ("surgeon" . 160))))))
  (check-pred "has electrosurgeon (substitute)" (member "electrosurgeon" eff))
  (check-pred "but NOT master (no practised electrosurgeon hours)"
              (not (member "master" eff))))

(display "\n── Transitivity when the derived skill IS practised ──\n")
(let ((eff (effective-skills '("electrician" "surgeon") catalogue
                             (hours-table '(("electrician" . 250) ("surgeon" . 160)
                                            ("electrosurgeon" . 80))))))   ; ≥50 now
  (check-pred "now reaches master transitively" (member "master" eff)))

(display "\n── No catalogue ⇒ held set unchanged ──\n")
(let ((eff (effective-skills '("baker") '() (hours-table '()))))
  (check "just the held skill" (length eff) 1)
  (check-pred "baker present" (member "baker" eff)))

(display "\n")
(test-summary!)
