;;; test-strategy.scm — Tests for strategy synthesis relations
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-strategy.scm

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))

;;; ── Test facts ───────────────────────────────────────────────────────────────

(define test-facts
  '((inventory "inv-bread" "spec-bread" 10 "loc-a" #f)
    (inventory "inv-water" "spec-water" 5 "loc-a" #f)
    (inventory "inv-empty" "spec-flour" 0 "loc-a" #f)
    (recipe "r-bread" "bake-bread" "spec-bread")
    (recipe "r-flour" "mill-flour" "spec-flour")
    (chain "r-bread" ("rp-bake"))
    (chain "r-flour" ("rp-mill"))
    (process "rp-bake" "baking" 3600000 1)
    (process "rp-mill" "milling" 1800000 1)
    (flow "rp-bake" input "spec-flour" 2 "kg" consume #f "f1")
    (flow "rp-bake" output "spec-bread" 1 "loaf" produce #f "f2")
    (flow "rp-mill" input "spec-wheat" 3 "kg" consume #f "f3")
    (flow "rp-mill" output "spec-flour" 2 "kg" produce #f "f4")))

(define ns #f)  ;; no netter state for pure relational tests
;;; ══════════════════════════════════════════════════════════════════════════════
;;; demand-class-o tests
;;; ══════════════════════════════════════════════════════════════════════════════

(display "\n── demand-class-o ──\n")

;; Forward: bread has inventory → class 0
(let ((results (run-plan 1 ns (c) (demand-class-o test-facts "spec-bread" c))))
  (check "bread with inventory → class 0" (and (pair? results) (car results)) 0))

;; Forward: flour has zero inventory but has recipe → class 2
(let ((results (run-plan 1 ns (c) (demand-class-o test-facts "spec-flour" c))))
  (check "flour with recipe → class 2" (and (pair? results) (car results)) 2))

;; Forward: wheat has neither → class 3
(let ((results (run-plan 1 ns (c) (demand-class-o test-facts "spec-wheat" c))))
  (check "wheat external → class 3" (and (pair? results) (car results)) 3))

;; Inverse: what specs are class 0? (have positive inventory)
(let ((results (run-plan 10 ns (s) (demand-class-o test-facts s 0))))
  (check-pred "class 0 includes bread" (member "spec-bread" results))
  (check-pred "class 0 includes water" (member "spec-water" results))
  (check-pred "class 0 excludes flour" (not (member "spec-flour" results))))
;;; ══════════════════════════════════════════════════════════════════════════════
;;; strategy-o tests (pure conde table — fully bidirectional)
;;; ══════════════════════════════════════════════════════════════════════════════

(display "\n── strategy-o ──\n")

;; Forward: strategy → ordering
(let ((results (run-plan 1 ns (o) (strategy-o 'earliest-due o))))
  (check "earliest-due → by-due-date" (car results) 'by-due-date))

(let ((results (run-plan 1 ns (o) (strategy-o 'local-first o))))
  (check "local-first → by-local-first" (car results) 'by-local-first))

;; Inverse: ordering → strategy
(let ((results (run-plan 1 ns (s) (strategy-o s 'by-due-date))))
  (check "by-due-date → earliest-due" (car results) 'earliest-due))

;; Enumerate all strategies
(let ((results (run-plan 10 ns (s) (fresh (o) (strategy-o s o)))))
  (check-pred "3 strategies" (= (length results) 3))
  (check-pred "includes earliest-due" (member 'earliest-due results))
  (check-pred "includes local-first" (member 'local-first results))
  (check-pred "includes unordered" (member 'unordered results)))
;;; ══════════════════════════════════════════════════════════════════════════════
;;; situation-o tests
;;; ══════════════════════════════════════════════════════════════════════════════

(display "\n── situation-o ──\n")

(let ((results (run-plan 1 ns (sit) (situation-o test-facts sit))))
  (check-pred "situation found" (pair? results))
  (let ((sit (car results)))
    (check "inventory coverage = 2" (assq-ref sit 'inventory-coverage) 2)
    (check "recipe coverage = 2" (assq-ref sit 'recipe-coverage) 2)
    (check-pred "bread in inventoried" (member "spec-bread" (assq-ref sit 'inventoried-specs)))
    (check-pred "bread in recipe specs" (member "spec-bread" (assq-ref sit 'recipe-specs)))))
;;; ══════════════════════════════════════════════════════════════════════════════
;;; plan-quality-o tests
;;; ══════════════════════════════════════════════════════════════════════════════

(display "\n── plan-quality-o ──\n")

;; All satisfied
(let* ((plan '(("spec-bread" (satisfied "spec-bread" 10 (("inv-bread" 10)) "loc-a"))))
       (results (run-plan 1 ns (q) (plan-quality-o plan q))))
  (check "all-satisfied plan" (car results) 'all-satisfied))

;; Partial
(let* ((plan '(("spec-bread" (satisfied "spec-bread" 10 (("inv-bread" 10)) "loc-a"))
               ("spec-iron" (unmet "spec-iron" 5 #f))))
       (results (run-plan 1 ns (q) (plan-quality-o plan q))))
  (check "partial plan" (car results) 'partial))

;; Many unmet
(let* ((plan '(("spec-iron" (unmet "spec-iron" 5 #f))
               ("spec-copper" (unmet "spec-copper" 3 #f))))
       (results (run-plan 1 ns (q) (plan-quality-o plan q))))
  (check "many-unmet plan" (car results) 'many-unmet))
;;; ══════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ══════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "Strategy tests: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))
(test-summary!)
