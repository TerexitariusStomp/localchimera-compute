;;; catalogues/skill-interaction.scm — cross-training: what one skill's slack does for another.
;;;
;;; A recipe's `work` flow names one exact skill; the planner matches a
;;; process to a worker who holds it (`Lab|skill|cell`, engine.scm's per-
;;; skill labour pool) and nothing else counts. That is right when skills
;;; genuinely don't transfer. It is a simplification when they partly do: a
;;; baker who has learned enough of a kitchen to cover a cook's shift, at
;;; reduced effectiveness, is a real labour-market fact this closure has no
;;; row for. A skill pool that reports only its own roster's hours, when a
;;; trained neighbour is sitting idle, is reporting the wrong number to
;;; whatever recipe is waiting on it.
;;;
;;; Illustrative DRAFT coefficients, exactly as every other governed table in
;;; this codebase is until a stewardship scope ratifies its own — real
;;; substitutability is a fact about a *specific* pair of trainings this note
;;; cannot know in general, so the direction and rough size here (a baker
;;; covers a cook's shift at moderate but incomplete effectiveness; the
;;; reverse rate differs) stand for whatever a scope's own cross-training
;;; register would say.
;;;
;;; The mechanism is the identical cascade nutrient bioavailability reads
;;; (`propagate.scm`): a skill's EFFECTIVE supply is its own net (produce −
;;; consume — already what `good-coeffs`/`span-coeffs` return for
;;; `Lab|skill|cell`, so a skill already at capacity on its own work has no
;;; slack left to lend) plus a substituting skill's own net, propagated. The
;;; GOVERNANCE DECISION this note makes, stated so it can be revisited: a
;;; floor or a process's labour demand met partly by a substitute's spillover
;;; counts as fully met, on the SAME terms as nutrient bioavailability — no
;;; separate discounted conjunction, one EFFECTIVE number the barrier reads.
;;; A stewardship scope that wants substituted hours to count for less than
;;; this treats them should say so in the coefficient, not by inventing a
;;; second constraint.

(define-module (playnet knowledge catalogues skill-interaction)
  #:use-module ((playnet vf formulas propagate)
                #:select (interactions->coupling expand-couple effective-values))
  #:re-export (interactions->coupling)
  #:export (*skill-interactions*
            expand-skill-couple
            effective-skill-supply))

;; (k j coefficient source) — j's EFFECTIVE supply feeds k's by coefficient:
;; p_k = net_k + Σ_j coefficient_kj · p_j. k and j are the FULL "Lab|skill"
;; good prefix (without the trailing "|cell"), matching lab-good's own
;; convention, so expand-couple's plain "|suffix" join reproduces
;; "Lab|skill-cook|kitchen@0" exactly. DRAFT, illustrative, asymmetric on
;; purpose — a baker covering a cook covers more of the gap than a cook
;; covering a baker, and neither claims a specific kitchen's real rate.
(define *skill-interactions*
  (list
   (list "Lab|skill-cook" "Lab|skill-bake" 0.4
         "A trained baker's idle hours cover a cook's shift at moderate
          effectiveness — plating and heat management transfer, portioning
          and knife work less so. Illustrative: 0.4 of a baker's own slack
          hours count toward a cook shortfall. Ratify a real rate at the
          scope that runs both kitchens.")
   (list "Lab|skill-bake" "Lab|skill-cook" 0.25
         "The reverse transfers less: a cook's idle hours cover baking's
          more exacting timing and measurement worse than a baker covers
          a cook's shift. Illustrative and asymmetric on purpose — the
          two coefficients are not required to match, and here don't.")))

;; expand-skill-couple: *skill-interactions* is expand-couple under this
;; domain's own name (catalogues/nutrient-interaction.scm's expand-nutrient-couple is
;; the same alias for its own table) — SUFFIXES are this solve's own cells
;; ("kitchen@0"), since a skill pool, like a nutrient, is per-cell as well as
;; per-kind (a baker idle at one kitchen does not cover a cook short-staffed
;; at another).
(define expand-skill-couple expand-couple)

;; SUPPLY: ((skill . net-hours) …), one cell's own skills' RAW net
;; (produce − consume, e.g. straight off a solve's own good-coeffs summed at
;; a warm start, or hand-supplied for a standalone check) → the same shape,
;; each net replaced by its EFFECTIVE one — effective-values (propagate.scm)
;; under this domain's own name. A skill named in SUPPLY but absent from
;; INTERACTIONS (nothing reads or feeds it) passes through unchanged — the
;; pure-math demonstration of the identical mechanism a real solve's
;; #:couplings keyword wires in (registered under 'skill), with no plan, no
;; columns, just the fixed point itself.
(define* (effective-skill-supply supply #:key (interactions *skill-interactions*))
  (effective-values supply #:interactions interactions))
