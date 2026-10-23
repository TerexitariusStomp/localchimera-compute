;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; vf/facts/barred-specs.scm — specs no individual may ever hold a claim of.
;;;
;;; Most of what a citizen may claim is bread, a ride, a repair — things
;;; rail.scm classifies off the recipes that touch them, with no exception.
;;; A short list of specs is different: not because of what a recipe does
;;; with them, but because of what they ARE — a currency, a precious metal,
;;; anything a jurisdiction's own law (not this federation's) says an
;;; individual may not simply be handed. This is that list, read before any
;;; recipe is asked, and the one override `rails-of`'s own rule deliberately
;;; does not make for a resource's tag (vf/facts/rail.scm: "a word on a record
;;; never enters") — because this is not a record's word. It is the
;;; federation's own standing policy, named once, same for every scope.
;;;
;;; A leaf: no further #:use-module, so a module that imports this one
;;; (rail.scm) keeps its own "imports nothing of the planner" property.

(define-module (playnet vf facts barred-specs)
  #:export (barred-individual? barred-individual-specs))

;; (spec-id category reason)
;;   category : a tag for what KIND of bar this is — 'financial-instrument
;;              today; 'controlled-substance, 'weapon, 'hazardous-material,
;;              'protected-species, 'cultural-property are the categories
;;              this list is shaped to take, the day a recipe ever models
;;              one of those; none does yet, so none has a row.
;;   reason   : one sentence, for whoever reads this table to understand why.
;;
;; Every row here is `medium-of-exchange #t` or `classified-as '("currency"
;; …)` somewhere in knowledge/recipes/ or monero/specs.scm — the id is the
;; production resource-spec id, not a narrative name a test fixture might
;; coincidentally share (a test's own "gold-1"/"gold" fixture, for instance,
;; is not this "spec-gold" and is untouched by this table).
(define *barred-individual-specs*
  '(("spec-xmr"              financial-instrument "Monero — a live, wallet-backed external asset; the direct money-transmission exposure docs/legal/operator.md row 3 names.")
    ("spec-eur"               financial-instrument "Euro — fiat currency.")
    ("spec-usd"               financial-instrument "US Dollar (also the tenant-maintenance strike fund's own spec) — fiat currency.")
    ("spec-gbp"               financial-instrument "Pound Sterling — fiat currency.")
    ("spec-jpy"               financial-instrument "Japanese Yen — fiat currency.")
    ("spec-chf"               financial-instrument "Swiss Franc — fiat currency.")
    ("spec-cad"               financial-instrument "Canadian Dollar — fiat currency.")
    ("spec-aud"               financial-instrument "Australian Dollar — fiat currency.")
    ("spec-cny"               financial-instrument "Renminbi — fiat currency.")
    ("spec-inr"               financial-instrument "Indian Rupee — fiat currency.")
    ("spec-gold"              financial-instrument "Gold, fine, by gram — FATF/AMLD's own named category (dealers in precious metals and stones); the same underlying risk as currency.")
    ("spec-silver"            financial-instrument "Silver, fine, by gram — the same category as gold.")
    ("spec-liquidity-premium" financial-instrument "A USD-denominated financial instrument (the rollover-pricing recipe) — medium-of-exchange flagged the same way as the currencies above.")))

(define (barred-individual? spec)
  "SPEC's (category . reason), or #f if nothing bars it."
  (let ((row (assoc spec *barred-individual-specs*)))
    (and row (cons (cadr row) (caddr row)))))

(define (barred-individual-specs) (map car *barred-individual-specs*))
