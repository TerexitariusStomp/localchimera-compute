;;; grow-composition-test.scm — a product's COMPOSITION EMERGES FROM ITS RECIPE.
;;;
;;; The metabolic-rift question in proper ValueFlows: a carrot's nutrients aren't
;;; a number in a table, they are what the grow PROCESS drew from the soil. This
;;; suite proves the composition the matter face reads is DERIVED off the grow
;;; recipe's own consume/produce flows — not the *contains* fallback — and that
;;; it conserves. The recipe is rigged so its derived nitrogen fraction (0.040)
;;; DIFFERS from the fallback (0.026), so there is no ambiguity about which spoke.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/doors/grow-composition-test.scm
;;; (via the blake3 dev-test shell — see [[reference_blake3_test_profile]])

(use-modules (playnet test harness)
             (playnet knowledge recipes grow) (playnet scope root) (srfi srfi-1)
             (playnet doors service) (playnet doors plan-wire)
             (playnet knowledge catalogues substances)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define (~= a b) (and a b (< (abs (- a b)) 1e-4)))
(define co2-cfrac (/ (atomic-weight "C") (molar-mass "co2")))   ; 12.011/44.009, derived

;;; ── Part A: derive-contains is conservation made constructive (pure) ─────────
;; The grow recipe's own flows (kg of substance), exactly as grow.scm seeds them.
(define grow-consumed `(("soil-n" . 5.0) ("soil-p" . 1.0) ("soil-k" . 2.0)
                        ("co2" . 44.0) ("grow-water" . ,(water-for "carrot" 100.0))))
(define grow-produced '(("carrot" . 100) ("crop-runoff" . 20)))
(define carrot-comp (derive-contains grow-consumed grow-produced "carrot"))

(display "\n── a product's composition is DERIVED from its recipe's flows ──\n")
(check-pred "derivation yields a carrot row" (and carrot-comp (equal? (car carrot-comp) "carrot")))
(define (cfrac e) (or (assoc-ref (cdr carrot-comp) e) 0))
;; N: (soil-n 5.0 − runoff 20×0.050=1.0) / 100 = 0.040  — and NOT the table's 0.026
(check-pred "nitrogen DERIVED: (5.0 − 1.0)/100 = 0.040" (~= (cfrac "N") 0.040))
(check-pred "the recipe overrides the *contains* fallback (0.040 ≠ 0.026)"
            (not (~= (cfrac "N") 0.026)))
;; P: (1.0 − 20×0.022=0.44)/100 ; K: (2.0 − 20×0.030=0.60)/100 ; C: 44×cfrac/100
(check-pred "phosphorus DERIVED: (1.0 − 0.44)/100 = 0.0056" (~= (cfrac "P") 0.0056))
(check-pred "potassium DERIVED: (2.0 − 0.60)/100 = 0.0140"  (~= (cfrac "K") 0.0140))
(check-pred "carbon DERIVED from CO₂ formula: 44×(12.011/44.009)/100"
            (~= (cfrac "C") (/ (* 44.0 co2-cfrac) 100)))

;; conservation: what the soil gave = what the crop embodies + what runoff bleeds.
(define (drawn e)    (* (or (assoc-ref grow-consumed (string-append "soil-" (string-downcase e))) 0) 1.0))
(define (embodied e) (* (cfrac e) 100))
(define (bled e)     (* 20 (or (assoc-ref (assoc-ref *contains* "crop-runoff") e) 0)))
(check-pred "N conserved: drawn = embodied + bled (5.0 = 4.0 + 1.0)"
            (~= (drawn "N") (+ (embodied "N") (bled "N"))))
(check-pred "P conserved: drawn = embodied + bled (1.0 = 0.56 + 0.44)"
            (~= (drawn "P") (+ (embodied "P") (bled "P"))))
(check-pred "K conserved: drawn = embodied + bled (2.0 = 1.40 + 0.60)"
            (~= (drawn "K") (+ (embodied "K") (bled "K"))))

;; derivation refuses when the primary isn't produced
(check-pred "no primary output → no derivation"
            (not (derive-contains grow-consumed grow-produced "turnip")))

;;; ── Part B: end-to-end through the real matter wire ──────────────────────────
;; Seed the grow recipe into a REAL scope-root, then push a solve through the
;; production matter-results->wire. The wire scans the store, derives carrot's
;; composition from rp-grow's flows, and lifts the carrot link with it.
(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Grow Composition")) store))
(with-vat vat (let ((rs ($ scope 'recipe-store))) (seed-grow-specs rs) (seed-grow-recipe rs)))

;; the solve the grow recipe would yield: draw soil-N, grow carrot, bleed runoff.
(define grow-solve
  `((material .
     (((action . consume) (conforms-to . "soil-n")     (quantity . 5.0) (output-of . #f)       (input-of . "rp-grow"))
      ((action . produce) (conforms-to . "carrot")      (quantity . 100) (output-of . "rp-grow") (input-of . #f))
      ((action . produce) (conforms-to . "crop-runoff") (quantity . 20)  (output-of . "rp-grow") (input-of . #f))))))
(define wire (with-vat vat (matter-results->wire scope grow-solve)))

(define links (assq-ref wire 'links))
(define (link from to) (find (lambda (l) (and (equal? (assq-ref l 'from) from)
                                             (equal? (assq-ref l 'to) to))) links))
(define (lN l) (and l (or (assq-ref (assq-ref l 'flows) 'N) 0)))

(display "\n── the matter wire reads the RECIPE-DERIVED composition end-to-end ──\n")
(check-pred "wire produced" (and wire #t))
;; carrot link carries the DERIVED 0.040 → 100 kg ⇒ 4.0 kg N (table would give 2.6)
(check-pred "produce link grow→carrot uses recipe-derived N (100×0.040 = 4.0)"
            (~= (lN (link "rp-grow" "res:carrot")) 4.0))
;; what the table says of a carrot is the release's own row (catalogues/substances.scm), read
;; here and never typed, so the figure a recipe supersedes is the figure that stands
(define table-n (* 100 (or (assoc-ref (elemental "carrot") "N") 0)))
(check-pred "and NOT the fallback (the table's own carrot, a hundred kilograms of it)"
            (not (~= (lN (link "rp-grow" "res:carrot")) table-n)))
;; the soil draw is the rift: 5.0 kg N pulled from the soil stock
(define nodes (assq-ref wire 'nodes))
(define (node id) (find (lambda (n) (equal? (assq-ref n 'id) id)) nodes))
(check-pred "soil-n is an environment resource (its drift is the rift)"
            (assq-ref (node "res:soil-n") 'env))
(check-pred "soil N drawn into grow = 5.0" (~= (lN (link "res:soil-n" "rp-grow")) 5.0))

;;; ── Part C: with NO recipe, the same solve falls back to *contains* ──────────
;; A fresh scope has no grow recipe → recipe-derived-contains is empty → the
;; carrot link uses the fallback table (0.026). This is the demotion made visible:
;; the table is consulted only in the absence of a deriving recipe.
(define store2 (make-memory-store))
(define-values (vat2 scope2)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "No Recipe")) store2))
(define wire2 (with-vat vat2 (matter-results->wire scope2 grow-solve)))
(define links2 (assq-ref wire2 'links))
(define (link2 from to) (find (lambda (l) (and (equal? (assq-ref l 'from) from)
                                              (equal? (assq-ref l 'to) to))) links2))
(define (lN2 l) (and l (or (assq-ref (assq-ref l 'flows) 'N) 0)))
(display "\n── absent a recipe, *contains* is the fallback ──\n")
(check-pred "no-recipe scope falls back to the table's N for a hundred kilograms of carrot"
            (and (> table-n 0) (~= (lN2 (link2 "rp-grow" "res:carrot")) table-n)))

(test-summary!)
