;;; flat-key.scm — a flat's key, the door it opens, and the shift behind it.
;;;
;;; A flat is entered through its door, and the door opens to its key. So work
;;; inside a lent flat has two conditions the plan states apart: the worker may
;;; enter (the flat's grant, and the skill the work asks), and a key stands at
;;; the door when the shift begins, in a hand trusted to hold it (the key's
;;; grant). The door latches on the way out: the key is needed at the opening
;;; and at no other moment of the shift.
;;;
;;; ── the specs, and why each has its unit ────────────────────────────────────
;;;   spec-flat-key     "each"    the key: a means the opening uses, where the
;;;                               key stands. It reaches another place by being
;;;                               carried there (rp-flat-key-carry).
;;;   spec-flat-access  "each"    one opening of the door — a SERVICE, delivered
;;;                               at the flat in the band it is made, never
;;;                               inventoried: yesterday's open door admits
;;;                               nobody today.
;;;   spec-oven         "each"    the oven standing in the flat (contained-in
;;;                               the dwelling), used by the count and the hour.
;;;   spec-oven-shift   "each"    the delivered good: one shift worked at the
;;;                               oven. A service; what the shift bakes is the
;;;                               bake recipe's own claim (bread-commune-seed).
;;;   spec-key-blank    "each"    an uncut blank; spec-key-cutter the machine;
;;;   spec-key-swarf    "each"    the filings one cut leaves — the named loss.
;;;
;;; ── the four processes ──────────────────────────────────────────────────────
;;; `rp-flat-unlock` — the door opened. One run = one opening.
;;;   use   spec-flat-key   1 each × 0.1 h   the key, in the opener's hand
;;;   work  skill-errand    0.1 h            the opener, at the door
;;;   cite  spec-dwelling   1 each           the flat stands at the cell
;;;   deliver-service spec-flat-access 1     (primary)
;;; The opener is whoever the work lands on, and the work `use`s the key: the
;;; steward gate reads the key grant's rule for it, so the door is opened by a
;;; person the owner trusts to hold her key.
;;;
;;; `rp-flat-oven-shift` — a shift at the oven, behind the opened door.
;;;   consume spec-flat-access 1 each        the opening this shift entered by
;;;   use     spec-oven        1 each × 2 h
;;;   work    skill-bake       2 h
;;;   deliver-service spec-oven-shift 1      (primary)
;;; The skill line is what narrows the flat's enter rule further: whoever may
;;; enter may use what stands inside, and the shift lands on someone who can
;;; also bake.
;;;
;;; `rp-flat-key-carry` — the key carried from where it rests to where it is
;;; wanted: a travel MODE whose mover is the key (transport.scm `mode-recipe`).
;;;   pickup  spec-flat-key    1 each            at the origin
;;;   work    carried          0.21 h per km     the key's own journey: it is carried, on foot
;;;   work    skill-errand     0.21 h per km     the carrier
;;;   dropoff spec-flat-key    1 each            at the destination
;;; A mode that names a means is how that means travels (engine.scm, A MODE MAY
;;; NAME ITS MOVER): the key is one whole thing in one place a band, and the
;;; opening is planned where it stands. The carrier's work is this mode's need,
;;; offered through the steward gate like the opening.
;;;
;;; `rp-flat-key-copy` — a second key cut from the first.
;;;   use     spec-flat-key    1 each × 0.25 h   the pattern, in its holder's hand
;;;   use     spec-key-cutter  1 each × 0.25 h
;;;   consume spec-key-blank   1 each
;;;   work    skill-locksmith  0.25 h
;;;   produce spec-flat-key    1 each            (primary)
;;;   produce spec-key-swarf   1 each            the loss, named
;;; A process that produces the spec it uses is a COPY of a lent means. The cut
;;; `use`s the key, so the steward gate admits the key's holders for it today;
;;; the owner's narrower word (her alone, or whoever she delegates) is an open
;;; rule (tests/planner/test-berlin-flat-key.scm states where it stands).
;;;
;;; ── conservation ────────────────────────────────────────────────────────────
;;; The opening and the shift are states; the key, the oven and the cutter are
;;; durables a run uses without moving a gram. The blank's brass becomes the
;;; key's and the swarf's; all three are counted in "each" and unmeasured here
;;; (empty *contains* rows in catalogues/substances.scm, stated beside the dwelling's).
;;;
;;; ── the durations ───────────────────────────────────────────────────────────
;;; 0.1 h to open a door, 2 h a shift, 0.25 h a cut at a key-cutting machine —
;;; round figures of ordinary experience, edited here. Each fits any band the
;;; sub-day dial cuts, so no run spans bands.
;;;
;;; ── scope declarations a caller wants ───────────────────────────────────────
;;; Nothing here is storable. A lent key travels when its grant says it may
;;; (`socialize-private-resource #:movable?`): the commune's view then holds
;;; the key itself, and a key lent in place is drawn where it lies
;;; (economy/socialization.scm `project-socialized-custody`).

(define-module (playnet knowledge recipes flat-key)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module (playnet knowledge dsl world)
  #:use-module ((playnet knowledge recipes transport) #:select (mode-recipe))
  #:use-module (goblins)
  #:export (flat-key-world seed-flat-key-recipes!))

(define key-carry                        ; (recipe-process flows)
  (mode-recipe "carry the flat key" #:good "spec-flat-key" #:skill "carried"
               #:pace 0.21 #:manner "pedestrian"
               #:work '("skill-errand" . 0.21)
               #:id "rp-flat-key-carry" #:pspec "pspec-carry-flat-key"))

(define flat-key-world
  (world
   #:specs (list (spec* "spec-flat-key" "Flat key" %count-unit)
                 (spec* "spec-flat-access" "An opening of the flat's door" %count-unit)
                 (spec* "spec-oven" "Oven" %count-unit)
                 (spec* "spec-oven-shift" "A shift at the oven" %count-unit)
                 (spec* "spec-key-blank" "Key blank" %count-unit)
                 (spec* "spec-key-cutter" "Key-cutting machine" %count-unit)
                 (spec* "spec-key-swarf" "Key swarf" %count-unit)
                 (spec* "skill-bake" "Bake labour" %effort-unit)
                 (spec* "skill-errand" "Errand labour" %effort-unit)
                 (spec* "skill-locksmith" "Locksmith labour" %effort-unit))
   #:procs (list (car key-carry)
                 (rp* "rp-flat-unlock" "Open the flat's door" 0.1
                      #:tags '("tag:housing" "whole-count"))
                 (rp* "rp-flat-oven-shift" "A shift at the flat's oven" 2.0
                      #:tags '("tag:housing" "whole-count"))
                 (rp* "rp-flat-key-copy" "Cut a copy of the flat key" 0.25
                      #:tags '("tag:housing" "whole-count")))
   #:flows (append
            (cadr key-carry)
            (list
            ;; the opening
            (use* "rf-unlock-key" "spec-flat-key" "rp-flat-unlock" 0.1 #:qty 1)
            (wk* "rf-unlock-work" "skill-errand" 0.1 "rp-flat-unlock")
            (make-recipe-flow #:id "rf-unlock-flat" #:action 'cite #:resource-conforms-to "spec-dwelling"
                              #:resource-quantity (make-measure 1 %count-unit)
                              #:recipe-input-of "rp-flat-unlock")
            (make-recipe-flow #:id "rf-unlock-out" #:action 'deliver-service #:resource-conforms-to "spec-flat-access"
                              #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-flat-unlock" #:is-primary #t)
            ;; the shift behind it
            (consume* "rf-shift-access" "spec-flat-access" 1 "rp-flat-oven-shift" %count-unit)
            (use* "rf-shift-oven" "spec-oven" "rp-flat-oven-shift" 2.0 #:qty 1)
            (wk* "rf-shift-work" "skill-bake" 2.0 "rp-flat-oven-shift")
            (make-recipe-flow #:id "rf-shift-out" #:action 'deliver-service #:resource-conforms-to "spec-oven-shift"
                              #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-flat-oven-shift" #:is-primary #t)
            ;; the copy
            (use* "rf-copy-key" "spec-flat-key" "rp-flat-key-copy" 0.25 #:qty 1)
            (use* "rf-copy-cutter" "spec-key-cutter" "rp-flat-key-copy" 0.25 #:qty 1)
            (consume* "rf-copy-blank" "spec-key-blank" 1 "rp-flat-key-copy" %count-unit)
            (wk* "rf-copy-work" "skill-locksmith" 0.25 "rp-flat-key-copy")
            (out* "rf-copy-out" "spec-flat-key" 1 "rp-flat-key-copy" %count-unit)
            (out* "rf-copy-swarf" "spec-key-swarf" 1 "rp-flat-key-copy" %count-unit #:primary #f)))
   #:recipes (list (make-recipe #:id "recipe-flat-key-carry" #:name "A flat key carried"
                                #:primary-output "spec-flat-key" #:recipe-processes (list "rp-flat-key-carry"))
                   (make-recipe #:id "recipe-flat-access" #:name "An opened flat"
                                #:primary-output "spec-flat-access" #:recipe-processes (list "rp-flat-unlock"))
                   (make-recipe #:id "recipe-flat-oven-shift" #:name "A shift at a flat's oven"
                                #:primary-output "spec-oven-shift" #:recipe-processes (list "rp-flat-oven-shift"))
                   (make-recipe #:id "recipe-flat-key-copy" #:name "A copied flat key"
                                #:primary-output "spec-flat-key" #:recipe-processes (list "rp-flat-key-copy")))))

(define (seed-flat-key-recipes! rs)
  "Seed the flat-key knowledge into RS: the key, the opening it makes, the oven
   shift behind the door and the copy. RS is a ^recipe-store; call within a vat."
  (seed-world-recipes! rs flat-key-world)
  'flat-key-seeded)
