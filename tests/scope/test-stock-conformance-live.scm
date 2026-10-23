;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-stock-conformance-live.scm — a substitutable STOCK through the live planner.
;;;
;;; The consumable-stock twin of test-resource-conformance-live. There a durable's
;;; SERVICE (Svc|) substituted; here a stock's OWN ONHAND does — the same closure,
;;; the same satisfied-by catalogue, but a good that is drawn DOWN rather than a
;;; per-period service. A knead recipe only ever asks for `flour` (it `consume`s it).
;;; The commune holds no flour; it holds wheat-flour. Because the catalogue says
;;; `flour` is satisfied-by `wheat-flour`, plan-scope pulls the wheat-flour record
;;; out of the ingest-stock path and makes it a durable? = #f supplier over the
;;; closure {wheat-flour, flour} on one budget = its onhand — so the wheat-flour
;;; answers the flour demand, bounded by how much is on hand.
;;;
;;; A bare consumable is NOT a free structural pool (only Lab|/Svc| are), so the
;;; control is a clean binary: WITHOUT the catalogue the recipe's `flour` has no
;;; source at all and nothing is kneaded. WITH it, output tracks the wheat-flour
;;; on hand (2 kg ⇒ half the demand, 4 kg ⇒ all of it).
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/scope/test-stock-conformance-live.scm

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (goblins) (goblins vat) (srfi srfi-1))

;; the wheat-flour the commune actually holds (onhand ONHAND kg, at "town").
(define (wf onhand) (make-economic-resource #:id "res:wf" #:conforms-to "wheat-flour" #:classified-as '()
   #:accounting-quantity (make-measure onhand "kg") #:onhand-quantity (make-measure onhand "kg") #:current-location "town" #:primary-accountable "commune"))

;; knead: `consume` 1 FLOUR → 1 dough. No `work` flow ⇒ the flour is the only scarcity.
(define procs (list (rp* "knead" "Knead")))
(define flows (list (out* "k1" "dough" 1.0 "knead") (consume* "k2" "flour" 1.0 "knead")))
(define recipes (list (make-recipe #:id "knead-recipe" #:name "Knead" #:primary-output "dough"
                                   #:recipe-processes '() #:recipe-exchanges '())))

;; the catalogue: `flour` is satisfied-by holding `wheat-flour`.
(define flour-specs
  (list (make-resource-specification
         #:id "flour" #:name "Flour" #:resource-classified-as '() #:default-unit-of-effort "kg"
         #:satisfied-by '((("wheat-flour" . 0))))))

(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
(define vat (spawn-vat #:name "stock-conformance-live"))

;; one live solve: SPECS is the resource-spec catalogue, ONHAND the wheat-flour the
;; commune holds. Demand 4 dough. Returns the fraction of demand met.
(define (run specs onhand)
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () (list (wf onhand))))
                               (skill-hours-of . ,(lambda (aid) '()))
                               (record-event   . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:specs specs #:procs procs #:flows flows))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (assq-ref
       (plan-scope->alist scope
         #:demand '(("dough#town@0" . 4.0))
         #:backend 'native-c)
       'met))))

(define cat-2   (run flour-specs 2.0))   ; substitutes; 2 kg wheat-flour ⇒ 2/4 kneaded
(define cat-4   (run flour-specs 4.0))   ; substitutes; 4 kg ⇒ 4/4
(define nocat-4 (run '() 4.0))           ; no catalogue ⇒ wheat-flour is not flour ⇒ nothing kneaded

(display "\n── wheat-flour fills a plain `flour` demand, live (knead demand 4) ──\n")
(format #t "  with catalogue, 2 kg ⇒ met ~,2f   (≈ 2/4)~%" cat-2)
(format #t "  with catalogue, 4 kg ⇒ met ~,2f   (≈ 4/4)~%" cat-4)
(format #t "  NO  catalogue, 4 kg ⇒ met ~,2f   (≈ 0 — wheat-flour ≠ flour)~%" nocat-4)

(check "wheat-flour substitutes for flour, BOUNDED by its onhand (2 kg ⇒ ~1/2)"
       (and (> cat-2 0.45) (< cat-2 0.55)))
(check "more stock ⇒ more of the substituted good (4 kg ⇒ ~full)"
       (> cat-4 0.95))
(check "without the satisfied-by catalogue wheat-flour cannot fill `flour` (bare good, no free raw)"
       (< nocat-4 0.05))
(check "substitution is what filled it (catalogue lifts met from ~0 to full)"
       (> cat-4 (+ nocat-4 0.9)))

(display "\n")
(test-summary!)
