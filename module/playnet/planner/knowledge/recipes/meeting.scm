;;; meeting.scm — Weekly Planning Meeting recipe, as a <world>.
;;;
;;; Originally inlined in module/playnet/planner/seed-meeting-scope.scm.
;;; Extracted so all reusable recipe seed data lives under
;;; knowledge/recipes/. The scope bootstrap (agents, skills, plan,
;;; dependent-demand) still lives in seed-meeting-scope.scm and
;;; calls seed-meeting-recipe.
;;;
;;;   meeting-world        the chain: three role skills and the minutes, one
;;;                        process of an hour, four hours of work into it
;;;   seed-meeting-recipe  the chain into a recipe-store
;;;
;;; A scope that meets appends meeting-world to its own (recipes/dev.scm:
;;; the development scope's week holds its meeting beside its issues).

;; A meeting is COUNTABLE. Four people give an hour each and a decision comes out;
;; two people giving half an hour is not half a meeting, it is no meeting.
;;
;; Stated here as data rather than declared by a call, because a recipe reaches
;; the planner as a MODULE and the discrete machinery lives in the engine, which
;; is primitive-loaded. A scope threads this into its own options — the shape
;; `regenerating-stock-storables` already uses to hand a #:storable list over.
(define-module (playnet planner knowledge recipes meeting)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner knowledge dsl shorthand)
  #:use-module (playnet planner knowledge dsl world)
  #:use-module ((playnet planner knowledge skills meeting-skills)
                #:select (%meeting-skills))
  #:use-module (goblins)
  #:export (meeting-whole-acts meeting-work-flow meeting-roles meeting-world
            seed-meeting-recipe))

(define meeting-whole-acts '("rp-meeting"))

(define (meeting-work-flow id spec-id)
  "RecipeFlow with action='work, 1h effort, into rp-meeting."
  (wk* id spec-id 1 "rp-meeting"))

;; the roles a meeting asks for, each a skill counted in hours
(define meeting-roles '("spec:facilitation" "spec:note-taking" "spec:participation"))

(define meeting-world
  ;; 4 work inputs (1 facilitator, 1 note-taker, 2 participants) → 1
  ;; meeting-minutes output, 1 hour. The three role skills are the
  ;; catalogue's own (knowledge/skills/meeting-skills.scm); only the
  ;; output — not a skill — stays declared here.
  (world
   #:specs (cons (spec* "spec:meeting-minutes" "Meeting Minutes" "each")
                 %meeting-skills)
   #:procs (list (rp* "rp-meeting" "Run Meeting" 1 #:conforms-to "pspec-meeting"))
   #:flows (list (meeting-work-flow "rf-facilitate"    "spec:facilitation")
                 (meeting-work-flow "rf-notes"         "spec:note-taking")
                 (meeting-work-flow "rf-participate-1" "spec:participation")
                 (meeting-work-flow "rf-participate-2" "spec:participation")
                 (out* "rf-minutes-out" "spec:meeting-minutes" 1 "rp-meeting" "each"))
   #:recipes (list (make-recipe #:id "recipe-meeting" #:name "Weekly Planning Meeting"
                                #:primary-output "spec:meeting-minutes" #:recipe-processes (list "rp-meeting")))))

(define (seed-meeting-recipe recipe-store)
  "Seed the Weekly Planning Meeting recipe: 4 work inputs (1 facilitator,
   1 note-taker, 2 participants) → 1 meeting-minutes output, 1 hour."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-meeting" #:name "Weekly Meeting"))
  (seed-world-recipes! recipe-store meeting-world))
