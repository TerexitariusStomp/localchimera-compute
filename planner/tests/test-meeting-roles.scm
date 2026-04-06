;;; test-meeting-roles.scm — Role/skill-matching for work flows
;;;
;;; Tests that the planner matches work flows to agents by skill,
;;; respects scope membership, avoids double-booking, emits alerts
;;; for unmatched roles, and preserves backward compatibility.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-meeting-roles.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))


;;; ── Harness ───────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))

;; Shorthand: (work-flow id spec-id) → RecipeFlow with work action, 1h effort
(define (work-flow id spec-id)
  (make-recipe-flow id 'work spec-id #f
                    #f (make-measure 1 "hours") "rp-meeting" #f #f #f #f #f #f #f))

;; Shorthand: (skill-resource id agent-id spec-id) → seed resource
(define (seed-skill! obs id agent-id spec-id)
  ($ obs 'seed-resource
     (make-economic-resource id (string-append agent-id " " spec-id) #f #f #f
       spec-id #f
       (make-measure 1 "each") (make-measure 1 "each")
       #f #f agent-id #f #f #f #f #f #f #f #f)))

;; Shorthand: membership relationship
(define (add-member! as id agent-id)
  ($ as 'add-relationship
     (make-agent-relationship id agent-id "org:meeting" "role-member" "org:meeting" #f)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: Meeting recipe with role-based work flows
;;;
;;; Recipe "weekly-planning" with one process containing:
;;;   work flow: conforms-to "spec:facilitation", effort 1h
;;;   work flow: conforms-to "spec:note-taking",  effort 1h
;;;   work flow: conforms-to "spec:participation", effort 1h (x2)
;;;   produce flow: conforms-to "spec:meeting-minutes", qty 1
;;;
;;; Agents:
;;;   Alice — facilitation + participation skills
;;;   Bob   — note-taking + participation skills
;;;   Carol — participation skill only
;;;   Dave  — facilitation skill, but NOT in org scope
;;;
;;; Org: "org:meeting" with Alice, Bob, Carol as members
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Meeting recipe with roles ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Meeting Test Commune"))
    store))

;; We also need an agent-store (separate from scope, which has its own)
(define agent-store-ref #f)

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; ── Resource specs (skills + output) ──
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:facilitation" "Facilitation" #f #f #f "hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:note-taking" "Note Taking" #f #f #f "hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:participation" "Participation" #f #f #f "hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:meeting-minutes" "Meeting Minutes" #f #f #f "each" #f #f #f #f #f))

    ;; ── Meeting process ──
    ($ rs 'add-process-spec
       (make-process-specification "pspec-meeting" "Weekly Meeting" #f #f #f #f #f #f #f))

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-meeting" "Run Meeting" #f #f "pspec-meeting" #f
                            (make-duration 1 "hours") #f #f))

    ;; ── Work flows (inputs) ──
    ($ rs 'add-recipe-flow (work-flow "rf-facilitate"    "spec:facilitation"))
    ($ rs 'add-recipe-flow (work-flow "rf-notes"         "spec:note-taking"))
    ($ rs 'add-recipe-flow (work-flow "rf-participate-1" "spec:participation"))
    ($ rs 'add-recipe-flow (work-flow "rf-participate-2" "spec:participation"))

    ;; ── Output flow ──
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-minutes-out" 'produce "spec:meeting-minutes" #f
                         (make-measure 1 "each") #f #f "rp-meeting" #f #f #f #f #f #f))

    ;; ── Recipe ──
    ($ rs 'add-recipe
       (make-recipe "recipe-meeting" "Weekly Planning Meeting" #f #f "spec:meeting-minutes"
                    (list "rp-meeting") #f))

    ;; ── Skills (resource conforming to spec, accountable = agent) ──
    ;; Alice: facilitation + participation
    (seed-skill! obs "skill-alice-fac"  "agent-alice" "spec:facilitation")
    (seed-skill! obs "skill-alice-part" "agent-alice" "spec:participation")
    ;; Bob: note-taking + participation
    (seed-skill! obs "skill-bob-notes"  "agent-bob"   "spec:note-taking")
    (seed-skill! obs "skill-bob-part"   "agent-bob"   "spec:participation")
    ;; Carol: participation only
    (seed-skill! obs "skill-carol-part" "agent-carol"  "spec:participation")
    ;; Dave: facilitation (but outside scope)
    (seed-skill! obs "skill-dave-fac"   "agent-dave"   "spec:facilitation")

    ;; ── Agent store with org membership ──
    (set! agent-store-ref (spawn ^agent-store (hashmap) (hashmap) (hashmap)))

    ;; Add agents
    ($ agent-store-ref 'add-agent
       (make-agent "agent-alice" 'person "Alice" #f #f #f #f #f))
    ($ agent-store-ref 'add-agent
       (make-agent "agent-bob" 'person "Bob" #f #f #f #f #f))
    ($ agent-store-ref 'add-agent
       (make-agent "agent-carol" 'person "Carol" #f #f #f #f #f))
    ($ agent-store-ref 'add-agent
       (make-agent "agent-dave" 'person "Dave" #f #f #f #f #f))

    ;; Add membership role
    ($ agent-store-ref 'add-role
       (make-agent-relationship-role "role-member" "member" "has member" #f #f))

    ;; Alice, Bob, Carol are members of org:meeting (Dave is NOT)
    (add-member! agent-store-ref "rel-alice" "agent-alice")
    (add-member! agent-store-ref "rel-bob"   "agent-bob")
    (add-member! agent-store-ref "rel-carol" "agent-carol")

    (check-pred "setup: recipe created"
                (pair? ($ rs 'get-process-chain "recipe-meeting")))
    (check-pred "setup: agents-with-skill facilitation includes alice"
                (member "agent-alice" ($ obs 'agents-with-skill "spec:facilitation")))
    (check-pred "setup: agents-with-skill facilitation includes dave"
                (member "agent-dave" ($ obs 'agents-with-skill "spec:facilitation")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Skill matching — agents assigned by skill
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Skill matching ──\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (work-flows
           (list (work-flow "rf-facilitate" "spec:facilitation")
                 (work-flow "rf-notes" "spec:note-taking")
                 (work-flow "rf-participate-1" "spec:participation")))
         (result (match-work-flows work-flows obs agent-store-ref
                   #:scope-id "org:meeting")))

    ;; Facilitation: Alice (only in-scope agent with facilitation)
    (check "facilitation → Alice"
           (assoc-ref result "rf-facilitate") "agent-alice")
    ;; Note-taking: Bob (only agent with note-taking)
    (check "note-taking → Bob"
           (assoc-ref result "rf-notes") "agent-bob")
    ;; Participation: Carol (Alice busy with facilitation, Bob with notes)
    (check "participation → Carol"
           (assoc-ref result "rf-participate-1") "agent-carol")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. No double-booking
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. No double-booking ──\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (work-flows
           (list (work-flow "rf-facilitate" "spec:facilitation")
                 (work-flow "rf-notes" "spec:note-taking")))
         (result (match-work-flows work-flows obs agent-store-ref
                   #:scope-id "org:meeting"))
         (fac-agent (assoc-ref result "rf-facilitate"))
         (notes-agent (assoc-ref result "rf-notes")))
    ;; Both should be assigned, and different
    (check-pred "both assigned" (and fac-agent notes-agent))
    (check-pred "no double-booking" (not (equal? fac-agent notes-agent)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Unmatched role → Intent + alert
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Unmatched role → #f ──\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         ;; 4 work flows but only 3 in-scope agents
         (work-flows
           (list (work-flow "rf-facilitate" "spec:facilitation")
                 (work-flow "rf-notes" "spec:note-taking")
                 (work-flow "rf-participate-1" "spec:participation")
                 (work-flow "rf-participate-2" "spec:participation")))
         (result (match-work-flows work-flows obs agent-store-ref
                   #:scope-id "org:meeting")))

    ;; Three agents matched, one slot unmatched
    (let ((matched (filter cdr result))
          (unmatched (filter (lambda (p) (not (cdr p))) result)))
      (check "3 matched" (length matched) 3)
      (check "1 unmatched" (length unmatched) 1)
      ;; The unmatched one should be a participation slot
      (check-pred "unmatched is participation"
                  (member (caar unmatched) '("rf-participate-1" "rf-participate-2"))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Scope filtering — Dave excluded
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Scope filtering ──\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         ;; Only facilitation — Dave has skill but not in scope
         (work-flows
           (list (work-flow "rf-facilitate" "spec:facilitation")))
         ;; With scope: Alice should be selected (Dave excluded)
         (result-scoped (match-work-flows work-flows obs agent-store-ref
                          #:scope-id "org:meeting"))
         ;; Without scope: either Alice or Dave could be selected
         (result-unscoped (match-work-flows work-flows obs #f)))

    (check "scoped: facilitation → Alice (Dave excluded)"
           (assoc-ref result-scoped "rf-facilitate") "agent-alice")
    ;; Unscoped should pick someone (Alice or Dave)
    (check-pred "unscoped: facilitation assigned"
                (assoc-ref result-unscoped "rf-facilitate"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Backward compatibility — omit agent-store
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Backward compatibility ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (rs ($ scope 'recipe-store))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (due (+ (current-time) 86400))
         (agents `((provider . "agent-alice") (receiver . "org:meeting"))))
    ;; Call dependent-demand WITHOUT agent-store — should work as before
    (let-values (((ns2 result) (dependent-demand "plan-compat" "spec:meeting-minutes" 1 due
                                  rs ps obs ns #:agents agents)))
      (check-pred "backward compat: has processes"
                  (pair? (assq-ref result 'processes)))
      ;; All commitments/intents should use the global agents
      (let ((comms (or (assq-ref result 'commitments) '()))
            (ints  (or (assq-ref result 'intents) '())))
        (check-pred "backward compat: produces output records"
                    (> (+ (length comms) (length ints)) 0))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. miniKanren relations
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. miniKanren skill/role relations ──\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (resources ($ obs 'all-resources))
         (rels (hashmap-values ($ agent-store-ref 'all-relationships))))

    ;; skill-o: Alice has facilitation
    (let ((result (query-agents-with-skill resources "spec:facilitation")))
      (check-pred "skill-o: Alice has facilitation"
                  (member "agent-alice" result))
      (check-pred "skill-o: Dave has facilitation"
                  (member "agent-dave" result))
      (check-pred "skill-o: Bob does NOT have facilitation"
                  (not (member "agent-bob" result))))

    ;; relationship-o: Alice is member of org:meeting
    (let ((result (run* (who)
                    (relationship-o rels who "org:meeting" "role-member"))))
      (check-pred "relationship-o: Alice in org"
                  (member "agent-alice" result))
      (check-pred "relationship-o: Dave NOT in org"
                  (not (member "agent-dave" result))))

    ;; qualified-worker-o: combine skill + membership
    (let ((result (query-qualified-workers resources rels "spec:facilitation" "org:meeting")))
      (check-pred "qualified-worker-o: Alice qualified for facilitation in org"
                  (member "agent-alice" result))
      (check-pred "qualified-worker-o: Dave NOT qualified (not in org)"
                  (not (member "agent-dave" result))))

    ;; Bidirectional: what skills does Alice have in org:meeting?
    (let ((skills (query-agent-skills resources rels "agent-alice" "org:meeting")))
      (check-pred "bidirectional: Alice has facilitation in org"
                  (member "spec:facilitation" skills))
      (check-pred "bidirectional: Alice has participation in org"
                  (member "spec:participation" skills)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Full pipeline — work flows → Intents with suggested assignments
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Full pipeline (work flows → Intents + work-assignments) ──\n")

(define pipeline-result #f)  ;; saved for test 8

(with-vat vat
  (let* ((ns (empty-netter-state))
         (rs ($ scope 'recipe-store))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (als ($ scope 'alert-store))
         (due (+ (current-time) 86400))
         (agents `((receiver . "org:meeting"))))

    ;; Clear alerts from previous tests
    ($ als 'clear)

    ;; Run dependent-demand with agent-store + scope
    (let-values (((ns2 result)
                  (dependent-demand "plan-meeting" "spec:meeting-minutes" 1 due
                    rs ps obs ns
                    #:agents agents
                    #:agent-store agent-store-ref
                    #:scope-agent-id "org:meeting"
                    #:alert-store als)))

      (set! pipeline-result result)

      ;; Should produce at least one process
      (let ((procs (or (assq-ref result 'processes) '()))
            (comms (or (assq-ref result 'commitments) '()))
            (ints  (or (assq-ref result 'intents) '()))
            (assigns (or (assq-ref result 'work-assignments) '())))

        (check-pred "pipeline: has process"
                    (pair? procs))

        ;; All work flows now produce Intents (never Commitments)
        (let ((work-commitments (filter (lambda (c) (eq? (commitment-action c) 'work)) comms))
              (work-intents (filter (lambda (i) (eq? (intent-action i) 'work)) ints)))
          (check "pipeline: zero work commitments"
                 (length work-commitments) 0)
          ;; 4 work flows → 4 work intents
          (check "pipeline: 4 work intents"
                 (length work-intents) 4))

        ;; work-assignments carry suggested providers from skill matching
        ;; 3 in-scope agents matched → 3 assignments
        (check "pipeline: 3 work-assignments"
               (length assigns) 3)

        ;; Each work-assignment has required fields
        (for-each
          (lambda (wa)
            (check-pred (string-append "pipeline: assignment has intent-id: "
                                       (or (assq-ref wa 'intent-id) "?"))
                        (assq-ref wa 'intent-id))
            (check-pred (string-append "pipeline: assignment has suggested-provider: "
                                       (or (assq-ref wa 'suggested-provider) "?"))
                        (assq-ref wa 'suggested-provider))
            (check-pred "pipeline: assignment has spec-id"
                        (assq-ref wa 'spec-id))
            (check-pred "pipeline: assignment has process-id"
                        (assq-ref wa 'process-id)))
          assigns)

        ;; Suggested providers should be in-scope agents
        (let ((providers (map (lambda (wa) (assq-ref wa 'suggested-provider)) assigns)))
          (for-each
            (lambda (p)
              (check-pred (string-append "pipeline: provider in scope: " p)
                          (member p '("agent-alice" "agent-bob" "agent-carol"))))
            providers))

        ;; Check alerts for unmatched roles (1 participation slot unmatched)
        (let ((alerts ($ als 'of-kind 'unmatched-role)))
          (check-pred "pipeline: unmatched role alert emitted"
                      (pair? alerts))
          (when (pair? alerts)
            (check-pred "pipeline: alert has spec-id"
                        (assq-ref (car alerts) 'spec-id))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Promote suggested assignment → Commitment
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Promote suggested assignment ──\n")

(with-vat vat
  (let* ((ps ($ scope 'plan-store))
         (assigns (and pipeline-result (assq-ref pipeline-result 'work-assignments)))
         (ints (and pipeline-result (assq-ref pipeline-result 'intents))))

    (check-pred "promote: have work-assignments from pipeline"
                (and assigns (pair? assigns)))

    (when (and assigns (pair? assigns))
      (let* ((wa (car assigns))
             (iid (assq-ref wa 'intent-id))
             (suggested (assq-ref wa 'suggested-provider))
             ;; Find the matching intent record from DD results
             (the-intent (find (lambda (i) (equal? (intent-id i) iid)) ints)))

        (check-pred "promote: found intent record" the-intent)

        (when the-intent
          ;; Store the intent in plan-store
          ($ ps 'add-intent the-intent)

          ;; Store metadata: suggested-provider
          ($ ps 'set-meta iid `((suggested-provider . ,suggested)))

          ;; Verify metadata round-trips
          (let ((meta ($ ps 'get-meta iid)))
            (check-pred "promote: meta stored" (pair? meta))
            (check "promote: meta has suggested-provider"
                   (assq-ref meta 'suggested-provider) suggested))

          ;; Promote to commitment using suggested provider
          (let ((cid ($ ps 'promote-to-commitment iid
                        `((provider . ,suggested)))))
            (check-pred "promote: commitment ID returned" cid)

            ;; Verify the commitment
            (when cid
              (let ((c ($ ps 'get-commitment cid)))
                (check-pred "promote: commitment exists" c)
                (when c
                  (check "promote: commitment provider matches"
                         (commitment-provider c) suggested)
                  (check "promote: commitment receiver matches"
                         (commitment-receiver c) "org:meeting")
                  (check "promote: commitment action is work"
                         (commitment-action c) 'work))))))))))


;;; ── Summary ─────────────────────────────────────────────────────────────────

(newline)
(display (string-append "══ Meeting Roles: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ══\n"))
(when (> fail-count 0)
  (exit 1))
