;;; catalogues/nutrient-interaction.scm — bioavailability: what one nutrient does to another.
;;;
;;; The closure that reduces a food to its nutrient content (catalogues/substances.scm's
;;; `nutrient-content`) treats every row as independent: a kilo of grain
;;; delivers its energy, its protein, its iron, each a separate number, none
;;; touching another. That is correct for the FLOOR side — form-and-
;;; substance.typ's vector is a conjunction, and it stays one; nothing here
;;; changes what a floor may add up against another. It is a simplification on
;;; the CLOSURE side: what a meal actually delivers is not always what was
;;; eaten. Calcium measurably suppresses how much of a meal's non-heme iron
;;; the body absorbs; vitamin C measurably raises it; iron and zinc compete for
;;; the same absorption pathway. A closure that reports raw intake as if it
;;; were bioavailable intake is reporting the wrong number to the floor.
;;;
;;; This is a linear proxy for what is really a saturating, meal-composition-
;;; dependent effect — the same honesty every DRAFT table in this codebase
;;; carries (catalogues/substances.scm's *food-nutrition*, conformance-catalogue.scm):
;;; a real, well-established DIRECTION (calcium inhibits, vitamin C assists,
;;; iron and zinc compete), a deliberately modest illustrative MAGNITUDE, and
;;; a note that a stewardship scope may register a sharper coupling — never a
;;; claim to clinical precision. Ratify the coefficients at the UC level like
;;; every other governed number here.
;;;
;;; The mechanism is the SAME cascade the eco fragility reads (planner
;;; propagate.scm): p = draw + C·p, the Neumann fixed point over a coupling
;;; agent → agent → coefficient, mutual and possibly cyclic (iron competes
;;; with zinc; nothing says zinc could not, in a sharper table, compete back).
;;; A tree climb or an ADMM round would both be the wrong tool here, for the
;;; reasons docs/planning/solve/propagator.md gives; this is the right one, reused.

(define-module (playnet planner knowledge catalogues nutrient-interaction)
  #:use-module ((playnet planner formulas propagate)
                #:select (interactions->coupling expand-couple effective-values))
  #:re-export (interactions->coupling)
  #:export (*nutrient-interactions*
            expand-nutrient-couple
            effective-nutrients))

;; expand-nutrient-couple/effective-nutrients are expand-couple/
;; effective-values under this domain's own name — catalogues/skill-interaction.scm's
;; expand-skill-couple/effective-skill-supply are the same two aliases for
;; its own table. The combinator (and its pure-math reading) is shared
;; (propagate.scm); the name at each call site stays domain-readable.
(define expand-nutrient-couple expand-couple)

;; (k j coefficient source) — j's amount feeds k's EFFECTIVE amount by
;; COEFFICIENT: p_k = raw_k + Σ_j coefficient_kj · p_j. Negative = j
;; suppresses k; positive = j assists k. DRAFT, illustrative magnitudes —
;; ratify at UC. Every row here is a real, textbook-established DIRECTION;
;; none claims a precise clinical size.
(define *nutrient-interactions*
  (list
   (list "iron" "calcium" -0.002
         "Calcium competes with non-heme iron for the same intestinal
          transporter — well established (Hallberg et al.); the true effect
          is a saturating ~30-50% absorption cut at a single meal's calcium
          dose, not linear. -0.002 keeps the illustrative size modest:
          ~1000 mg calcium ⇒ ~2 mg less effective iron, against an
          ~15-18 mg RDA.")
   (list "iron" "vit C" 0.05
         "Ascorbic acid reduces ferric to ferrous iron, raising non-heme
          absorption — well established (Hallberg & Hulthen). ~90 mg vitamin
          C ⇒ ~4.5 mg more effective iron, an illustrative boost kept smaller
          than the real single-meal effect (which can approach doubling).")
   (list "zinc" "iron" -0.05
         "Iron and zinc compete for shared divalent-metal transport,
          especially at supplemental doses (Solomons & Jacob) — a modest
          illustrative drag here, ~18 mg iron ⇒ ~0.9 mg less effective zinc
          against an ~8-11 mg RDA.")))

;; RAW: ((nutrient . amount) …), one person's raw intake (e.g. straight off
;; nutrient-content, summed over a day's meals) → the same shape, each amount
;; replaced by its EFFECTIVE one — effective-values (propagate.scm) under
;; this domain's own name. A nutrient named in RAW but absent from
;; INTERACTIONS (no row reads or feeds it) passes through unchanged — the
;; pure-math demonstration of the identical mechanism a real solve's
;; #:couplings keyword wires in (registered under 'nutrient), with no plan,
;; no columns, just the fixed point itself.
(define* (effective-nutrients raw #:key (interactions *nutrient-interactions*))
  (effective-values raw #:interactions interactions))
