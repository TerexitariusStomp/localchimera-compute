;;; server/seed-meeting-scope.scm — populate the demo "meeting commune"
;;;
;;; Direct port of the setup block from
;;; planner/tests/test-meeting-roles.scm:78-167, plus an explicit Plan
;;; record so the calendar's plan dropdown has something to show, plus
;;; the dependent-demand invocation that produces work intents with
;;; suggested-provider metadata for the skill-matched agents.
;;;
;;; Loaded via primitive-load from server/gateway.scm AFTER planner-loader.
;;; Depends on planner top-level definitions (record constructors,
;;; dependent-demand, empty-netter-state, etc.).

(use-modules (goblins)
             (srfi srfi-1)
             (srfi srfi-11))

;;; Mirror the test fixture's helpers — the test passes today, so its
;;; arities are known to match the schemas. Do not inline the
;;; make-economic-resource / make-recipe-flow / make-agent-relationship
;;; calls; reuse these helpers.

(define (work-flow id spec-id)
  "RecipeFlow with action='work, 1h effort, into rp-meeting."
  (make-recipe-flow id 'work spec-id #f
                    #f (make-measure 1 "hours") "rp-meeting" #f #f #f #f #f #f #f))

(define (seed-skill! obs id agent-id spec-id)
  "Resource conforming to SPEC-ID, accountable to AGENT-ID. Counts as a
   'skill' for the matcher because agents-with-skill walks resources by
   spec and groups by primary-accountable."
  ($ obs 'seed-resource
     (make-economic-resource id (string-append agent-id " " spec-id) #f #f #f
       spec-id #f
       (make-measure 1 "each") (make-measure 1 "each")
       #f #f agent-id #f #f #f #f #f #f #f #f)))

(define (add-member! as id agent-id scope-id)
  "AGENT-ID plays role-member toward SCOPE-ID, scoped by SCOPE-ID itself."
  ($ as 'add-relationship
     (make-agent-relationship id agent-id scope-id "role-member" scope-id #f)))

;;; ── Main seed ────────────────────────────────────────────────────────

(define (seed-meeting-scope! scope-root)
  "Run inside (with-vat planner-vat …). Builds the meeting commune scope:
   recipe + agents + skills + 'plan-meeting' Plan, then runs
   dependent-demand to populate intents with suggested-provider metadata."
  (let ((rs  ($ scope-root 'recipe-store))
        (ps  ($ scope-root 'plan-store))
        (obs ($ scope-root 'observer))
        (as  ($ scope-root 'agent-store))
        (als ($ scope-root 'alert-store)))

    ;; ── Resource specs (skills + meeting output) ──
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:facilitation" "Facilitation"
                                    #f #f #f "hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:note-taking" "Note Taking"
                                    #f #f #f "hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:participation" "Participation"
                                    #f #f #f "hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:meeting-minutes" "Meeting Minutes"
                                    #f #f #f "each" #f #f #f #f #f))

    ;; ── Process spec + recipe-process (1 hour duration) ──
    ($ rs 'add-process-spec
       (make-process-specification "pspec-meeting" "Weekly Meeting"
                                   #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-meeting" "Run Meeting" #f #f "pspec-meeting" #f
                            (make-duration 1 "hours") #f #f))

    ;; ── Work flows (4 inputs: 1 facilitator, 1 note-taker, 2 participants) ──
    ($ rs 'add-recipe-flow (work-flow "rf-facilitate"    "spec:facilitation"))
    ($ rs 'add-recipe-flow (work-flow "rf-notes"         "spec:note-taking"))
    ($ rs 'add-recipe-flow (work-flow "rf-participate-1" "spec:participation"))
    ($ rs 'add-recipe-flow (work-flow "rf-participate-2" "spec:participation"))

    ;; ── Output flow ──
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-minutes-out" 'produce "spec:meeting-minutes" #f
                         (make-measure 1 "each") #f #f "rp-meeting"
                         #f #f #f #f #f #f))

    ;; ── Recipe ──
    ($ rs 'add-recipe
       (make-recipe "recipe-meeting" "Weekly Planning Meeting" #f #f
                    "spec:meeting-minutes" (list "rp-meeting") #f))

    ;; ── Skills: resources conforming to spec, accountable = agent ──
    (seed-skill! obs "skill-alice-fac"  "agent-alice" "spec:facilitation")
    (seed-skill! obs "skill-alice-part" "agent-alice" "spec:participation")
    (seed-skill! obs "skill-bob-notes"  "agent-bob"   "spec:note-taking")
    (seed-skill! obs "skill-bob-part"   "agent-bob"   "spec:participation")
    (seed-skill! obs "skill-carol-part" "agent-carol" "spec:participation")
    ;; Dave has facilitation skill but is NOT in scope — used to demo scope filtering
    (seed-skill! obs "skill-dave-fac"   "agent-dave"  "spec:facilitation")

    ;; ── Agents (incl. the scope itself as an organization agent so the
    ;;     receiver="org:meeting" passes the agent existence checks) ──
    ($ as 'add-agent (make-agent "agent-alice" 'person "Alice" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-bob"   'person "Bob"   #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-carol" 'person "Carol" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-dave"  'person "Dave"  #f #f #f #f #f))
    ($ as 'add-agent (make-agent "org:meeting" 'organization "Meeting Commune"
                                 #f #f #f #f #f))

    ;; ── Membership: role + relationships ──
    ($ as 'add-role
       (make-agent-relationship-role "role-member" "member" "has member" #f #f))
    (add-member! as "rel-alice" "agent-alice" "org:meeting")
    (add-member! as "rel-bob"   "agent-bob"   "org:meeting")
    (add-member! as "rel-carol" "agent-carol" "org:meeting")

    ;; ── Named plan for the calendar's plan dropdown (8-field <plan>) ──
    ($ ps 'add-plan
       (make-plan "plan-meeting" "Weekly Planning Meeting"
                  #f #f #f #f #f #f))

    ;; ── Run dependent-demand → store intents + suggested-provider metadata ──
    (let* ((preg ($ scope-root 'process-registry))
           (ns   (empty-netter-state))
           (due  (+ (current-time) 86400)))  ; one day from now
      (let-values (((ns2 result)
                    (dependent-demand "plan-meeting" "spec:meeting-minutes" 1 due
                                      rs ps obs ns
                                      #:agents `((receiver . "org:meeting"))
                                      #:agent-store as
                                      #:scope-agent-id "org:meeting"
                                      #:alert-store als)))
        (let ((procs   (or (assq-ref result 'processes) '()))
              (intents (or (assq-ref result 'intents) '()))
              (assigns (or (assq-ref result 'work-assignments) '())))
          ;; Register the dynamically-created processes so the projection
          ;; layer can look them up by id (for process-name display).
          (for-each (lambda (p) ($ preg 'register p)) procs)
          ;; Persist intents in the plan-store
          (for-each (lambda (it) ($ ps 'add-intent it)) intents)
          ;; Stamp suggested-provider metadata so the calendar's
          ;; "Awaiting your acceptance" section knows who to surface.
          (for-each (lambda (wa)
                      (let ((iid (assq-ref wa 'intent-id))
                            (sp  (assq-ref wa 'suggested-provider)))
                        (when (and iid sp)
                          ($ ps 'set-meta iid `((suggested-provider . ,sp))))))
                    assigns))))))
