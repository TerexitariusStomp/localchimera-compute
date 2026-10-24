;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-resource-conformance-live.scm — substitutable MEANS through the live planner.
;;;
;;; The means-side twin of test-skill-e2e. There, a worker holding the component
;;; skills fills a composite slot via the effective-skills closure. Here, a durable
;;; whose spec SUBSTITUTES for another fills that other's demand — the SAME closure,
;;; the SAME satisfied-by catalogue, now carrying an instrument.
;;;
;;; A bake recipe only ever asks for an `oven` (it `use`s one). The commune holds no
;;; plain oven; it holds a convection-oven, whose per-period service arrives as a
;;; `Svc|convection-oven` eco-cap. Because the catalogue says `oven` is satisfied-by
;;; `convection-oven`, plan-scope splits that cap into a resource-supplier spanning
;;; the closure {convection-oven, oven} on one budget — so the convection-oven's
;;; hours BECOME the oven source, bounded by its capacity.
;;;
;;; The proof is that bounding. An UNCAPPED `Svc|oven` is a free structural raw (the
;;; planner's abundance default), so without the catalogue the convection-oven plays
;;; no part and oven demand is met free — INSENSITIVE to the convection-oven's
;;; capacity (cap 2 ⇒ met 1.0). WITH the catalogue the convection-oven becomes the
;;; oven's supplier, so met TRACKS its capacity (cap 2 ⇒ met 0.5, cap 4 ⇒ met ~1.0).
;;; Same capacity, half the fulfilment: substitution is what routed the bounded means
;;; to the demand.
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/scope/test-resource-conformance-live.scm

(use-modules ((localchimera utils units) #:select (%count-unit %effort-unit)))
(use-modules (localchimera test scope)) ; mock-scope-root
(use-modules (localchimera test harness)
             (localchimera vf schemas)
             (localchimera scope live)
             (goblins) (goblins vat) (srfi srfi-1))

;; the convection-oven the commune actually holds (custody at "town").
(define holdings (list (er "res:conv-oven" "convection-oven" "commune" #:qty 1 #:unit %count-unit)))

;; bake: `use` an OVEN (1 oven-hour) → 1 bread. No `work` flow ⇒ the oven is the only scarcity.
(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "b1" "bread" 1.0 "bake") (use* "b2" "oven" "bake" 1.0 #:qty 1.0)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes '() #:recipe-exchanges '())))

;; the catalogue: `oven` is satisfied-by holding a `convection-oven`.
(define oven-specs
  (list (make-resource-specification
         #:id "oven" #:name "Oven" #:resource-classified-as '() #:default-unit-of-effort %effort-unit
         #:satisfied-by '((("convection-oven" . 0))))))

(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
(define vat (spawn-vat #:name "resource-conformance-live"))

;; one live solve: SPECS is the resource-spec catalogue, CAP the convection-oven's
;; per-period service capacity (delivered as a Svc|convection-oven eco-cap). Demand
;; 4 bread. Returns the fraction of demand met.
(define (run specs cap)
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () holdings))
                               (skill-hours-of . ,(lambda (aid) '()))
                               (record-event   . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:specs specs #:procs procs #:flows flows))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (assq-ref
       (plan-scope->alist scope
         #:eco-caps `(("Svc|convection-oven#town@0" . ,cap))   ; the commune holds a convection-oven, not an oven
         #:demand '(("bread#town@0" . 4.0))
         #:backend 'native-c)
       'met))))

(define cat-2   (run oven-specs 2.0))   ; substitutes; convection-oven bounds oven ⇒ 2/4 met
(define cat-4   (run oven-specs 4.0))   ; substitutes; 4 oven-hours ⇒ 4/4 met
(define nocat-2 (run '() 2.0))          ; no catalogue ⇒ oven is a free raw, capacity plays no part ⇒ full

(display "\n── a convection-oven fills a plain `oven` demand, live (bake demand 4) ──\n")
(format #t "  with catalogue, cap 2 ⇒ met ~,2f   (bounded to ≈ 2/4)~%" cat-2)
(format #t "  with catalogue, cap 4 ⇒ met ~,2f   (≈ 4/4)~%" cat-4)
(format #t "  NO  catalogue, cap 2 ⇒ met ~,2f   (oven free — capacity ignored)~%" nocat-2)

(check "convection-oven substitutes for oven, BOUNDED by its capacity (cap 2 ⇒ ~1/2)"
       (and (> cat-2 0.45) (< cat-2 0.55)))
(check "more capacity ⇒ more of the substituted service (cap 4 ⇒ ~full)"
       (> cat-4 0.95))
;; WITHOUT THE CATALOGUE, NOTHING BAKES — and that is the fail-closed default
;; doing its job, not a regression. This used to expect met ≈ 1.0 on the reading
;; that an uncapped `Svc|oven` is a free structural raw the planner may conjure.
;; `spec-skips-balance?` removed exactly that freedom: an unstocked, unproduced,
;; unlisted spec dies rather than inventing itself, and its own comment names
;; this case as the footgun it closes. The commune holds a convection-oven and
;; no oven, so with no catalogue to say the one satisfies the other, there is no
;; oven — and a recipe that `use`s one cannot run at all.
;;
;; That makes the fixture's point HARDER than the version it replaces. The old
;; contrast was 1.0 vs 0.5 — substitution costs you the free lunch. The real
;; contrast is 0.0 vs 0.5: substitution is what makes the instrument the commune
;; ACTUALLY HOLDS count as the one the recipe asks for. Without it the held oven
;; is invisible and the bread is not baked.
(check "without the catalogue the held convection-oven is not an oven — nothing bakes"
       (< nocat-2 0.05))
(check "substitution is what routed the held means to demand (same cap 2: 0 → 1/2)"
       (> (- cat-2 nocat-2) 0.4))

(display "\n")
(test-summary!)
