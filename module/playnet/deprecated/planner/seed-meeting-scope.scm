;;; module/playnet/planner/seed-meeting-scope.scm — populate the demo "meeting commune"
;;;
;;; Direct port of the setup block from
;;; tests/planner/test-meeting-roles.scm:78-167, plus an explicit Plan
;;; record so the calendar's plan dropdown has something to show, plus
;;; the dependent-demand invocation that produces work intents with
;;; suggested-provider metadata for the skill-matched agents.

(define-module (playnet deprecated planner seed-meeting-scope)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (playnet planner)
  ;; dependent-demand/empty-netter-state have no new-planner port yet
  ;; (module/playnet/planner.scm's own header lists algorithms/netting.scm
  ;; and algorithms/dependent-demand.scm, but neither file actually exists
  ;; under module/playnet/planner/algorithms/ — the comment is stale).
  ;; Import ONLY those two bindings from the deprecated tree rather than
  ;; the whole (playnet deprecated planner) umbrella, so record types built
  ;; by (playnet planner) above stay the only ones in play everywhere else
  ;; in this file.
  #:use-module ((playnet deprecated planner)
                #:select (dependent-demand empty-netter-state))
  #:export (seed-meeting-scope!))

;;; Mirror the test fixture's helpers — the test passes today, so its
;;; arities are known to match the schemas. Do not inline the
;;; make-economic-resource / make-recipe-flow / make-agent-relationship
;;; calls; reuse these helpers.

(define (seed-skill! obs id agent-id spec-id)
  "Resource conforming to SPEC-ID, accountable to AGENT-ID. Counts as a
   'skill' for the matcher because agents-with-skill walks resources by
   spec and groups by primary-accountable."
  ($ obs 'seed-resource
     (make-economic-resource #:id id #:name (string-append agent-id " " spec-id)
       #:conforms-to spec-id
       #:accounting-quantity (make-measure 1 "each") #:onhand-quantity (make-measure 1 "each") #:primary-accountable agent-id)))

(define (add-member! as id agent-id scope-id)
  "AGENT-ID plays role-member toward SCOPE-ID, scoped by SCOPE-ID itself."
  ($ as 'add-relationship
     (make-agent-relationship #:id id #:subject agent-id #:object scope-id
                              #:relationship "role-member" #:in-scope-of scope-id)))

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

    ;; ── Recipe (specs + process + flows) ──
    (seed-meeting-recipe rs)

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
    ($ as 'add-agent (make-agent #:id "agent-alice" #:type 'person #:name "Alice"))
    ($ as 'add-agent (make-agent #:id "agent-bob"   #:type 'person #:name "Bob"))
    ($ as 'add-agent (make-agent #:id "agent-carol" #:type 'person #:name "Carol"))
    ($ as 'add-agent (make-agent #:id "agent-dave"  #:type 'person #:name "Dave"))
    ($ as 'add-agent (make-agent #:id "org:meeting" #:type 'organization #:name "Meeting Commune"))

    ;; ── Membership: role + relationships ──
    ($ as 'add-role
       (make-agent-relationship-role #:id "role-member" #:label "member"
                                     #:inverse-label "has member"))
    (add-member! as "rel-alice" "agent-alice" "org:meeting")
    (add-member! as "rel-bob"   "agent-bob"   "org:meeting")
    (add-member! as "rel-carol" "agent-carol" "org:meeting")

    ;; ── Named plan for the calendar's plan dropdown (8-field <plan>) ──
    ($ ps 'add-plan
       (make-plan #:id "plan-meeting" #:name "Weekly Planning Meeting"))

    ;; ── Run dependent-demand → store intents + suggested-provider metadata ──
    ;; dependent-demand/empty-netter-state are deprecated-only (no ported
    ;; equivalent — see the #:select comment above) and internally apply
    ;; deprecated-schema record accessors to whatever ResourceSpecification/
    ;; etc. records the new-planner stores above (rs/ps/obs) hand back —
    ;; those are a different, new-planner-typed universe now, so this call
    ;; is not guaranteed to succeed. Isolate it: the recipe/agents/skills/
    ;; plan seeded above (the part the calendar actually needs to render)
    ;; must not be lost just because the suggested-provider enrichment
    ;; can't cross that boundary.
    (catch #t
      (lambda ()
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
                        assigns)))))
      (lambda (key . args)
        (format (current-error-port)
                "seed-meeting-scope!: dependent-demand enrichment skipped (~a ~a)~%"
                key args)))))
