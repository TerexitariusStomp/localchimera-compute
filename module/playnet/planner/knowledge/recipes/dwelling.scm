;;; dwelling.scm — shelter as a located-dated good: the bed, used by night.
;;;
;;; Housing enters the plan the way every durable means does: it is `use`d, not
;;; consumed — drawn upon, left whole, handed back. The denomination rule from
;;; the means-pool (allocate capacity-hours, never machines) lands here as:
;;; nobody is allocated *a flat*; they are allocated *bed-nights at a place*.
;;; That keeps the solve convex and makes partial sharing (one room of three)
;;; fall out of a quantity, not a mechanism.
;;;
;;; ── the three specs, and why each has its unit ──────────────────────────────
;;;   spec-dwelling  "each"          the building/flat. A CONTAINER (its beds,
;;;                                  oven, tools are contained-in it) and
;;;                                  keep-in-place: a dwelling never relocates
;;;                                  through a plan — the socialization grant's
;;;                                  use-in-place default made structural.
;;;   spec-bed     "each"          one sleepable place — the capacity carrier
;;;                                  a grant socializes (Svc‖spec-bed). Count-
;;;                                  denominated, so its `use` draw is a count
;;;                                  and the use-unit lint holds draw and
;;;                                  capacity denominated the same way.
;;;   spec-shelter   "person-nights" the delivered good. A SERVICE — produced
;;;                                  and delivered, never inventoried: a night's
;;;                                  shelter cannot be stockpiled, and last
;;;                                  week's roof is not this week's (the same
;;;                                  fail-closed non-storability as a cleaned
;;;                                  floor in household.scm).
;;;
;;; ── the one process ─────────────────────────────────────────────────────────
;;; `rp-shelter-night` — a person sheltered for a night. One run = one person,
;;; one night: long stays are STANDING needs (a month is 30 runs), never
;;; run-spanning journeys, so occupancy stays per-band and partition-invariant.
;;;
;;;   use   spec-bed    1 each × 8 hours   the bed is occupied for the night
;;;   cite  spec-dwelling 1 each             the bed's container must exist at
;;;                                          the cell — non-rival (three beds
;;;                                          cite one flat), draws nothing
;;;   deliver-service spec-shelter 1 person-night   (primary)
;;;
;;; There is deliberately NO `work` flow: living-in is not labour. The labour of
;;; housing is its REPRODUCTION, and that chain already exists — household.scm
;;; (the weekly housework that keeps a dwelling livable) and
;;; the repair recipe (the repair side) draw on the same dwelling. One
;;; field: the sleeper, the cleaner, and the flat.
;;;
;;; ── conservation ────────────────────────────────────────────────────────────
;;; A `use` moves no matter and a `cite` draws nothing; shelter is a STATE, not
;;; matter, so spec-shelter/spec-bed/spec-dwelling carry empty *contains* rows
;;; (catalogues/substances.scm) — stated rather than left silent. The process is internal-
;;; clean: nothing enters, nothing leaves, nothing to balance. The material
;;; account of inhabitation (the soil a week of living deposits) is household
;;; .scm's `rp-hh-living` boundary process, not this file's claim.
;;;
;;; ── the duration ────────────────────────────────────────────────────────────
;;; 8 hours: the night the bed is actually held. It is the untimed-`use`
;;; guard's anchor (partition-invariant occupancy), and short enough that a
;;; night fits any band the sub-day dial cuts — the process never spans runs.
;;;
;;; ── scope declarations a caller wants ───────────────────────────────────────
;;; Nothing here is storable (a service and two durables); the durables are held
;;; resources — a citizen's `declare-means` of spec-bed qty N is the ownership
;;; a socialization grant projects Svc capacity from (service.scm declare-means,
;;; governance/socialization.scm commune-socialized-caps). spec-dwelling is
;;; keep-in-place; spec-bed is not declared movable — fail-closed, a bed
;;; moves only if a scope says so.
;;;
;;; ── the second producer: rent ───────────────────────────────────────────────
;;; A need is declared against spec-shelter, never against money and never
;;; against "rent" — rent is not the need, it is the OTHER way to reach it.
;;; `rp-shelter-night` delivers a person-night from capacity the commons
;;; already holds (a socialized bed); `rp-rent-shelter` below delivers the
;;; identical spec-shelter person-night by paying an external landlord — no
;;; bed, no dwelling, no commons capacity touched at all. Two independent
;;; recipe-processes producing the SAME primary output is the ordinary VF
;;; shape for substitutable supply (algorithms/rollup.scm's
;;; crystallized-snlt-for-spec takes the infimum over every producer), so nothing
;;; special has to wire the choice: the solve draws on whichever combination
;;; of the two is available and cheapest, and a purse-bounded shortfall in
;;; the rent leg (never-raw money, never-raw always) is what "priced out of
;;; housing" looks like on a plan that also has beds to lend.

;;; ─── specs ───────────────────────────────────────────────────────────────────
(define-module (playnet planner knowledge recipes dwelling)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:export (*dwelling-specs* seed-dwelling-specs seed-dwelling-recipe
            %rent-eur-per-night seed-rent-recipe))

(define *dwelling-specs*
  '(("spec-bed"    "Bed (one sleepable place)" "each")
    ("spec-shelter"  "A night's shelter"           "person-nights")))

(define (seed-dwelling-specs recipe-store)
  "Register the dwelling family: the flat (a keep-in-place container), the
   bed (the capacity carrier a grant socializes), and shelter (the delivered
   service)."
  ($ recipe-store 'add-resource-spec
     (make-resource-specification
      #:id "spec-dwelling" #:name "Dwelling (flat or house)" #:image "🏠" #:default-unit-of-resource "each"
      #:keep-in-place #t))
  (for-each
   (lambda (row)
     ($ recipe-store 'add-resource-spec
        (make-resource-specification
         #:id (car row) #:name (cadr row) #:image "🏠" #:default-unit-of-resource (caddr row))))
   *dwelling-specs*))

(define (seed-dwelling-recipe recipe-store)
  "Seed the one-step shelter recipe: a bed used for a night, in a dwelling
   that must stand at the cell, delivering one person-night of shelter."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-shelter" #:name "Inhabitation"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-shelter-night" #:name "A night's shelter"
                          #:process-conforms-to "pspec-shelter" #:process-classified-as '("tag:housing")
                          #:has-duration (make-duration 8 "hours")))

  ;; use: the bed, engaged 1 × 8 h — count AND duration, per the two-ovens rule
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-shelter-bed" #:action 'use #:resource-conforms-to "spec-bed"
                       #:resource-quantity (make-measure 1 "each") #:effort-quantity (make-measure 8 "hours")
                       #:recipe-input-of "rp-shelter-night"))
  ;; cite: the bed's container stands at the cell; non-rival, draws nothing
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-shelter-dwelling" #:action 'cite #:resource-conforms-to "spec-dwelling"
                       #:resource-quantity (make-measure 1 "each")
                       #:recipe-input-of "rp-shelter-night"))
  ;; deliver-service: the night of shelter — produced and delivered, never held
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-shelter-out" #:action 'deliver-service #:resource-conforms-to "spec-shelter"
                       #:resource-quantity (make-measure 1 "person-nights") #:recipe-output-of "rp-shelter-night" #:is-primary #t))  ; primary

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-shelter" #:name "Shelter (a night's housing)"
                  #:primary-output "spec-shelter" #:recipe-processes (list "rp-shelter-night"))))

;; €25/night ≈ €750/month room in a shared flat — a market rate, political
;; like every recipe cost, edited here rather than derived. Doubles as the
;; whole reason a socialized bed outprices it at zero direct labour: money
;; itself carries the crystallized labour of ITS OWN acquisition (spec-eur's
;; recipe, monero/specs.scm's twin for spec-xmr), so a night bought with
;; money is never actually cheaper than a night lent for free — it can only
;; be the one available when no bed is.
(define %rent-eur-per-night 25.0)

(define* (seed-rent-recipe recipe-store #:key (eur-per-night %rent-eur-per-night))
  "Seed the market alternative: EUR paid to an external landlord, delivering
   the identical spec-shelter person-night `rp-shelter-night` delivers from a
   socialized bed. No bed, no dwelling, no commons capacity — money is
   the only input, exactly the acquisition shape household.scm's `buy-<what>`
   recipes use for every other purchased good. Requires spec-eur to already
   be registered (household.scm's `seed-household-specs`, or a caller's own)."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-rent" #:name "Renting"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-rent-shelter" #:name "A night's rent"
                          #:process-conforms-to "pspec-rent" #:process-classified-as '("tag:housing" "tag:market")
                          #:has-duration (make-duration 0.05 "hours")))  ; the tenant's own time, paying it

  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-rent-eur" #:action 'consume #:resource-conforms-to "spec-eur"
                       #:resource-quantity (make-measure eur-per-night "EUR")
                       #:recipe-input-of "rp-rent-shelter"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-rent-out" #:action 'deliver-service #:resource-conforms-to "spec-shelter"
                       #:resource-quantity (make-measure 1 "person-nights") #:recipe-output-of "rp-rent-shelter" #:is-primary #t))  ; primary

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-rent-shelter" #:name "Rent (a night's housing, bought)"
                  #:primary-output "spec-shelter" #:recipe-processes (list "rp-rent-shelter"))))
