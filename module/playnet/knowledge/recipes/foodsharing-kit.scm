;;; foodsharing-kit.scm — the two halves of foodsharing's entry cost, modelled as
;;; what they actually are: a COMPETENCE that has to be taught, and MEANS that can
;;; be held in common.
;;;
;;; Design note: `docs/planning/food/foodsharing-requirements.md`. The requirements
;;; catalogue splits foodsharing's rulebook into credential / means / constraint /
;;; forbid / conduct. This file encodes the first two, which are the ones the
;;; planner can act on. Nothing here names a statute; the legal exterior of a
;;; pickup still comes from the fold over `docs/legal/contexts/de.sexp`.
;;;
;;; ── THE COMPETENCE ───────────────────────────────────────────────────────
;;; Becoming a Foodsaver is: pass the quiz, do at least THREE Einführungsabholungen
;;; supervised by a Botschafter*in or Vertrauensperson, have your identity checked,
;;; receive the Ausweis. The load-bearing part for a plan is the middle one — those
;;; three pickups consume an EXPERIENCED Foodsaver's hours.
;;;
;;; That is exactly the engine's skill-dynamics shape (planner.scm §skill spec):
;;; a training column consumes the MENTOR's hours of the same skill, the trainee's
;;; competence persists in the person, idle periods decay it, practice renews it.
;;; So the ceiling on how fast a district can grow is MENTOR CAPACITY — which the
;;; wiki cannot tell you and a plan can.
;;;
;;; The decay is not an invention either: foodsharing marks a dormant profile with
;;; a Schlafmütze, and an inactive Foodsaver's standing lapses in practice.
;;;
;;; ── THE MEANS ────────────────────────────────────────────────────────────
;;; Tongs, reusable gloves, a Kühltasche or Kühlbox with Kühlelemente, clean
;;; food-safe containers. Today each person buys and carries their own, and
;;; arriving without them is the most common reason someone is turned away.
;;;
;;; Each is an ordinary <resource-specification> a process `use`s. Held by the
;;; Kiezküche they are one pool the plan allocates per pickup, and the question
;;; changes from "did you bring yours?" to "how many pickups can we run today?" —
;;; which has an answer, and a way to raise it.
;;;
;;; ── PROVENANCE ───────────────────────────────────────────────────────────
;;; [DATA]  The requirement list and the ≥3 supervised pickups are the wiki's
;;;   (Hygieneregeln, Foodsaver, Einführungsabholung-Checkliste), read 2026-08-07.
;;; [DRAFT] Every NUMBER below — mentor hours per trained Foodsaver, decay and
;;;   regeneration rates, kit quantities per pickup — is a judgment figure. A
;;;   Berlin steward with a district's real roster replaces them without touching
;;;   the mechanism.

;;; ─── the competence ───────────────────────────────────────────────────────
(define-module (playnet knowledge recipes foodsharing-kit)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (%fs-skill %fs-skill-name *foodsaver-skill-args* foodsaver-skill-args
            foodsaver-skill declare-foodsaver-skill! enrol-foodsaver-trainee!
            *foodsharing-kit* kit-spec-id kit-spec-name kit-unit kit-per-pickup
            foodsharing-kit-uses %fs-cold-kit %fs-hand-kit foodsharing-cold-uses
            foodsharing-hand-uses seed-foodsharing-kit! seed-foodsharing-kit-specs!))

(define %fs-skill "skill-fs-foodsaver")
(define %fs-skill-name "Foodsaver (Ausweis)")

;;; The Einführungsabholung as the engine sees it. Three supervised pickups at
;;; roughly 1.5 h each is ~4.5 hours of an experienced Foodsaver's time per person
;;; brought in; the trainee spends the same hours plus the quiz.
;;;
;;;   teacher — mentor hours drawn per unit of competence taught [DRAFT]
;;;   trainee — the trainee's own hours, drawn from the same time budget they work from
;;;   lag     — periods between the training and holding the Ausweis (identity
;;;             check + issue), so a district cannot conjure Foodsavers same-day
;;;   endow   — nobody starts qualified
;;;   decay   — the Schlafmütze: standing lapses when unused
;;;   regen   — doing pickups keeps it current
(define *foodsaver-skill-args*
  '(#:decay 0.15 #:regen 0.6 #:yield 1.0 #:lag 1
    #:teacher 4.5 #:trainee 4.5 #:endow 0.0))

(define (foodsaver-skill-args) *foodsaver-skill-args*)

;;; The engine's skill globals live in (playnet solve engine), reached by
;;; whoever imports it — (playnet scope live) on the live path, a test's own
;;; module in a harness — never in this library module. So the declaration is
;;; handed to the caller to run in its own context, and the caller passes the
;;; setter it has:
;;;
;;;   (declare-foodsaver-skill! set-skill-spec!)              ; the lifecycle
;;;   (enrol-foodsaver-trainee! add-trainable! "hela" 0)      ; who may be taught
;;;
;;; Both are idempotent.
;;;
;;; THESE ARE PROCEDURES, and the reason is worth keeping. They were
;;; `define-syntax-rule`, which cannot do the job the paragraph above describes,
;;; twice over:
;;;
;;;   • syntax-rules is HYGIENIC, so `set-skill-spec!` inside the macro resolves
;;;     to the binding visible where the macro was DEFINED — this module, which
;;;     is exactly the resolution the caller-runs-it design exists to avoid.
;;;   • exported and used across a module boundary, the identifier arrives as
;;;     the transformer VALUE and is applied as a procedure:
;;;
;;;         Wrong type to apply: #<syntax-transformer declare-foodsaver-skill!>
;;;
;;; That failure is COMPILED-ONLY — interpreted, the macro expands in place and
;;; the test passes — which is why it read for a while as a stale `.go` rather
;;; than as the module-boundary bug it is. Clearing the cache made it pass and
;;; hid the cause. Taking the setter as an argument removes both problems: no
;;; hygiene question, because nothing is captured, and no transformer to export.
(define (foodsaver-skill) %fs-skill)

(define (declare-foodsaver-skill! set-skill-spec!)
  "Declare the Foodsaver competence's lifecycle using the CALLER's setter."
  (apply set-skill-spec! %fs-skill *foodsaver-skill-args*))

(define (enrol-foodsaver-trainee! add-trainable! worker from)
  "Let WORKER be taught the competence from period FROM — a Foodsaver is taught
   by a Foodsaver, so the skill is both the taught and the teaching one."
  (add-trainable! worker %fs-skill from %fs-skill))

;;; ─── the kit : the means, as specs a process `use`s ──────────────────────
;;; (spec-id  name  unit  per-pickup)  — `per-pickup` is what ONE Abholung draws.
;;; Hours for things a pickup occupies for its duration; `each` for things it
;;; takes and returns.
(define *foodsharing-kit*
  '(("spec-fs-kuehlbox"   "Kühlbox mit Kühlelementen"        "each" 1.0)
    ("spec-fs-handschuhe" "Mehrweghandschuhe"                "each" 1.0)
    ("spec-fs-zange"      "Zange (unverpackte Backwaren)"    "each" 1.0)
    ("spec-fs-behaelter"  "Lebensmittelechte Behälter"       "each" 4.0)))

(define (kit-spec-id row)  (list-ref row 0))
(define (kit-spec-name row)(list-ref row 1))
(define (kit-unit row)     (list-ref row 2))
(define (kit-per-pickup row) (list-ref row 3))

;;; the `uses` rows a food-chain stage wants (food-chain-seed.scm `food-stage`):
;;; (spec-id qty unit label).
(define* (foodsharing-kit-uses #:key (only #f) (scale 1.0))
  "The kit rows a pickup stage draws on. ONLY restricts to named spec ids (the
   handout stage wants gloves and tongs, not the whole cold kit)."
  (filter-map
   (lambda (row)
     (and (or (not only) (member (kit-spec-id row) only))
          (list (kit-spec-id row) (* scale (kit-per-pickup row))
                (kit-unit row) (kit-spec-name row))))
   *foodsharing-kit*))

;;; what a pickup needs cold; what a handout needs in hand
(define %fs-cold-kit '("spec-fs-kuehlbox" "spec-fs-behaelter"))
(define %fs-hand-kit '("spec-fs-handschuhe" "spec-fs-zange"))
(define (foodsharing-cold-uses) (foodsharing-kit-uses #:only %fs-cold-kit))
(define (foodsharing-hand-uses) (foodsharing-kit-uses #:only %fs-hand-kit))

;;; ─── the kit as resources the COMMUNE holds ──────────────────────────────
;;; primary-accountable is the commune: this kit is bought once and owned, so it
;;; is sovereign — unlike the fLotte bikes, nobody can recall it (berlin-flotte.scm).
;;; That difference is the whole argument for buying the kit collectively.
(define* (seed-foodsharing-kit! obs #:key (place "berlin") (holder "commune-berlin")
                                          (sets 4))
  "Seed SETS complete kits into the commune's holdings at PLACE. One `set` is what
   one simultaneous pickup needs, so SETS is how many pickups can run at once."
  (for-each
   (lambda (row)
     (let ((id (string-append (kit-spec-id row) "-pool"))
           (qty (* sets (kit-per-pickup row))))
       ($ obs 'record-resource
          (make-economic-resource
           #:id id #:name (kit-spec-name row) #:conforms-to (kit-spec-id row)
           #:classified-as '("infrastructure" "kit")
           #:accounting-quantity (make-measure qty (kit-unit row)) #:onhand-quantity (make-measure qty (kit-unit row))
           #:current-location place #:primary-accountable holder))))
   *foodsharing-kit*))

(define* (seed-foodsharing-kit-specs! rs)
  "Register the kit's resource specifications (the food chain registers any spec a
   stage names, so this is only needed when seeding the kit on its own)."
  (for-each
   (lambda (row)
     ($ rs 'add-resource-spec
        (make-resource-specification #:id (kit-spec-id row) #:name (kit-spec-name row)
                                     #:resource-classified-as '("kit") #:default-unit-of-resource (kit-unit row))))
   *foodsharing-kit*))
