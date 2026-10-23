;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/test/meeting-scope.scm — the demo "meeting commune", seeded into a scope root.
;;;
;;; A harness fixture: the meeting recipe (knowledge/recipes/meeting), three
;;; members with their skills as resources accountable to them, one outsider
;;; with a skill, the scope as an organisation agent, the member role, and a
;;; named plan for the calendar's plan dropdown, and the plan's work intents: one
;;; per work flow of the meeting, each suggested to a member by the live skill
;;; matcher (algorithms/skill-matcher), with an unmatched-role alert for a flow no
;;; member can fill. tests/ai/test-planner-service.scm stands on it.

(define-module (playnet test meeting-scope)
  #:use-module ((goblins) #:select ($))
  #:use-module (playnet vf schemas)
  #:use-module ((playnet knowledge recipes meeting) #:select (seed-meeting-recipe meeting-world))
  #:use-module ((playnet knowledge dsl world) #:select (world-flows))
  #:use-module ((playnet vf formulas flows) #:select (make-work-intent))
  #:use-module ((playnet algorithms skill-matcher) #:select (match-work-flows))
  #:use-module ((srfi srfi-1) #:select (filter))
  #:export (seed-meeting-scope!))

(define (seed-skill! obs id agent-id spec-id)
  "A resource conforming to SPEC-ID, accountable to AGENT-ID: a skill for the
   matcher, which walks resources by spec and groups by primary-accountable."
  ($ obs 'seed-resource
     (make-economic-resource #:id id #:name (string-append agent-id " " spec-id)
       #:conforms-to spec-id
       #:accounting-quantity (make-measure 1 "each") #:onhand-quantity (make-measure 1 "each") #:primary-accountable agent-id)))

(define (add-member! as id agent-id scope-id)
  "AGENT-ID plays role-member toward SCOPE-ID, scoped by SCOPE-ID itself."
  ($ as 'add-relationship
     (make-agent-relationship #:id id #:subject agent-id #:object scope-id
                              #:relationship "role-member" #:in-scope-of scope-id)))

(define (seed-meeting-scope! scope-root)
  "Run inside the scope's vat. Builds the meeting commune: recipe, agents,
   skills, membership and the 'plan-meeting' Plan."
  (let ((rs  ($ scope-root 'recipe-store))
        (ps  ($ scope-root 'plan-store))
        (obs ($ scope-root 'observer))
        (as  ($ scope-root 'agent-store))
        (als ($ scope-root 'alert-store)))
    (seed-meeting-recipe rs)
    (seed-skill! obs "skill-alice-fac"  "agent-alice" "spec:facilitation")
    (seed-skill! obs "skill-alice-part" "agent-alice" "spec:participation")
    (seed-skill! obs "skill-bob-notes"  "agent-bob"   "spec:note-taking")
    (seed-skill! obs "skill-bob-part"   "agent-bob"   "spec:participation")
    (seed-skill! obs "skill-carol-part" "agent-carol" "spec:participation")
    ;; Dave has facilitation skill but is NOT in scope: the scope filter's case
    (seed-skill! obs "skill-dave-fac"   "agent-dave"  "spec:facilitation")
    ;; the scope itself as an organisation agent, so receiver = "org:meeting" is an agent
    ($ as 'add-agent (make-agent #:id "agent-alice" #:type 'person #:name "Alice"))
    ($ as 'add-agent (make-agent #:id "agent-bob"   #:type 'person #:name "Bob"))
    ($ as 'add-agent (make-agent #:id "agent-carol" #:type 'person #:name "Carol"))
    ($ as 'add-agent (make-agent #:id "agent-dave"  #:type 'person #:name "Dave"))
    ($ as 'add-agent (make-agent #:id "org:meeting" #:type 'organization #:name "Meeting Commune"))
    ($ as 'add-role
       (make-agent-relationship-role #:id "role-member" #:label "member"
                                     #:inverse-label "has member"))
    (add-member! as "rel-alice" "agent-alice" "org:meeting")
    (add-member! as "rel-bob"   "agent-bob"   "org:meeting")
    (add-member! as "rel-carol" "agent-carol" "org:meeting")
    ($ ps 'add-plan
       (make-plan #:id "plan-meeting" #:name "Weekly Planning Meeting"))
    ;; the plan's work: one intent per work flow, suggested to a member by skill
    (let* ((work (filter (lambda (f) (eq? 'work (recipe-flow-action f))) (world-flows meeting-world)))
           (matches (match-work-flows work obs as #:scope-id "org:meeting")))
      (for-each
       (lambda (f)
         (let ((iid (string-append "intent-" (recipe-flow-id f)))
               (who (assoc-ref matches (recipe-flow-id f))))
           ($ ps 'add-intent
              (make-work-intent #:id iid #:skill (recipe-flow-resource-conforms-to f) #:hours 1
                                #:input-of "rp-meeting" #:planned-within "plan-meeting"
                                #:due "2026-03-02"))   ; the day it is due, no clock stated
           (if who
               ($ ps 'set-meta iid `((suggested-provider . ,who)))
               ($ als 'push-alert `((kind . unmatched-role) (intent-id . ,iid)
                                    (spec-id . ,(recipe-flow-resource-conforms-to f)))))))
       work))))
