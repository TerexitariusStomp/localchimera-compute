;;; test-planner-service.scm — integration test for ^planner-service
;;;
;;; Spawns a planner-vat with the meeting-commune seed, wraps it in
;;; ^planner-service, then exercises every public method end-to-end:
;;; scope-list, scope-snapshot, accept-assignment, record-effort,
;;; decline-assignment, process-context.
;;;
;;; This is the integration that the calendar UI depends on. If this
;;; test passes, the browser → OCapN → ^planner-service path is wired
;;; correctly server-side.
;;;
;;; Run from project root:
;;;   guile -L module tests/ai/test-planner-service.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules ((playnet wire rows) #:select (wire->plain))   ; a door's rows, read back as alists
             (playnet test harness))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet utils alist)        ; alist-ref
             (playnet ai key-pool)
             (playnet boot prelude)
             (playnet doors service)
             (playnet scope live)         ; persist-materialized! (the bridge)
             (playnet test meeting-scope)     ; seed-meeting-scope!
             (srfi srfi-1))
;;; ── Harness ────────────────────────────────────────────────────────────────

;;; ── Spawn the planner + service ────────────────────────────────────────────

(display "\n── Setup: planner-vat + scope + service ──\n")

(define planner-store (make-memory-store))
(define-values (planner-vat meeting-scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Meeting Commune"))
    planner-store))

(define planner-service
  (with-vat planner-vat
    (seed-meeting-scope! meeting-scope)
    (spawn ^planner-service
           (hashmap-set (hashmap) "org:meeting" meeting-scope))))

(define (svc method . args)
  (with-vat planner-vat (apply $ planner-service method args)))

(check-pred "setup: planner-service spawned" planner-service)
;;; ── 1. scope-list ──────────────────────────────────────────────────────────

(display "\n── 1. scope-list ──\n")

(let ((scopes (svc 'scope-list)))
  (check "scope-list returns one scope" (length scopes) 1)
  (check "scope id is org:meeting"
         (alist-ref (car scopes) 'id) "org:meeting")
  (check "scope name is Meeting Commune"
         (alist-ref (car scopes) 'name) "Meeting Commune"))
;;; ── 2. scope-snapshot — initial state ──────────────────────────────────────

(display "\n── 2. scope-snapshot (initial) ──\n")

(define snap0 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))

(check "snapshot scope-id"
       (alist-ref snap0 'scope-id) "org:meeting")
(check "snapshot scope-name"
       (alist-ref snap0 'scope-name) "Meeting Commune")
(check "members count = 3 (alice/bob/carol; dave excluded by scope)"
       (length (or (alist-ref snap0 'members) '())) 3)
(check "plans count = 1"
       (length (or (alist-ref snap0 'plans) '())) 1)
(check-pred "intents present"
            (pair? (or (alist-ref snap0 'intents) '())))
(check "no commitments yet"
       (length (or (alist-ref snap0 'commitments) '())) 0)
(check-pred "unmatched-role alert emitted"
            (pair? (or (alist-ref snap0 'alerts) '())))
;;; ── 3. Intent shape ────────────────────────────────────────────────────────

(display "\n── 3. Intent wire shape ──\n")

(define alice-intent
  (find (lambda (i) (equal? (alist-ref i 'suggested) "agent-alice"))
        (alist-ref snap0 'intents)))

(check-pred "alice intent exists" alice-intent)
(check "alice intent process-name"
       (alist-ref alice-intent 'proc-name) "Run Meeting")
(check "alice intent match-status"
       (alist-ref alice-intent 'match) "matched")
(check "alice intent suggested-provider-name"
       (alist-ref alice-intent 'suggested-name) "Alice")
(check "alice intent fulfilled-qty starts at 0"
       (alist-ref alice-intent 'done) 0)
(check-pred "alice intent has YYYY-MM-DD date"
            (and (string? (alist-ref alice-intent 'date))
                 (= 10 (string-length (alist-ref alice-intent 'date)))))
(check-pred "an unstated clock stays absent (no fabricated hour)"
            (not (assq 'sh alice-intent)))
;;; ── 4. accept-assignment ───────────────────────────────────────────────────

(display "\n── 4. accept-assignment ──\n")

(define accept-result
  (svc 'accept-assignment "org:meeting"
       (alist-ref alice-intent 'id) "agent-alice"))

(check-pred "accept returns ok envelope"
            (and (pair? accept-result) (eq? (car accept-result) 'ok)))
(define commit-id (and (eq? (car accept-result) 'ok) (cdr accept-result)))
(check-pred "accept returns commitment id" (string? commit-id))
;;; ── 5. Snapshot after accept ───────────────────────────────────────────────

(display "\n── 5. snapshot after accept ──\n")

(define snap1 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
(define cmts1 (alist-ref snap1 'commitments))

(check "commitments count = 1" (length cmts1) 1)
(check "commitment provider"
       (alist-ref (car cmts1) 'provider) "agent-alice")
(check "commitment provider-name"
       (alist-ref (car cmts1) 'provider) "agent-alice")
(check "commitment match-status"
       (alist-ref (car cmts1) 'match) "accepted")
(check "commitment fulfilled-qty starts at 0"
       (alist-ref (car cmts1) 'done) 0)
(check "commitment effort-qty"
       (alist-ref (car cmts1) 'effort) 1)
;; commitments-for-plan index update from the planner fix should mean
;; the commitment is found through the plan-id filter.
(check-pred "commitment is found through the plan-id filter" (pair? cmts1))
;;; ── 6. record-effort → fulfillment ────────────────────────────────────────

(display "\n── 6. record-effort → fulfillment-state advances ──\n")

(define rec-result
  (svc 'record-effort "org:meeting" commit-id "agent-alice" 1 %effort-unit))

(check-pred "record-effort returns ok envelope"
            (and (pair? rec-result) (eq? (car rec-result) 'ok)))
(check-pred "record-effort returns event id"
            (string? (cdr rec-result)))

(define snap2 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
(define cmts2 (alist-ref snap2 'commitments))

(check "fulfilled-qty advanced to 1"
       (alist-ref (car cmts2) 'done) 1)
;;; ── 7. decline-assignment ─────────────────────────────────────────────────
;;;
;;; Decline does two things:
;;;   - Clears the suggested-provider meta for the intent
;;;   - Re-runs match-work-flows with the declining agent in #:already-assigned
;;; If another in-scope agent has the right skill, that agent becomes the
;;; new suggestion. Otherwise the intent stays unmatched.
;;;
;;; Bob is the only note-taker in the scope, so declining note-taking has
;;; no fallback → 'unmatched. Carol could fall back to participation but
;;; Carol's already suggested for that, so it depends on which intent we pick.
;;;
;;; To get a deterministic test, we pick a participation intent (Carol's
;;; or unmatched) and decline it as Carol — Alice or Bob could plausibly
;;; fall back. Actually the cleanest test: Bob declines note-taking (no
;;; rematch — only Bob has note-taking), and we verify the unmatched fallback.

(display "\n── 7a. decline (no rematch available) ──\n")

(define bob-intent
  (find (lambda (i) (equal? (alist-ref i 'suggested) "agent-bob"))
        (alist-ref snap0 'intents)))

(when bob-intent
  (let ((dec-result
         (svc 'decline-assignment "org:meeting"
              (alist-ref bob-intent 'id) "agent-bob")))
    (check-pred "decline returns ok envelope"
                (and (pair? dec-result) (eq? (car dec-result) 'ok)))
    (check "no rematch found → 'cleared"
           (cdr dec-result) 'cleared))

  (let* ((snap3 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
         (declined
          (find (lambda (i) (equal? (alist-ref i 'id) (alist-ref bob-intent 'id)))
                (alist-ref snap3 'intents))))
    (check "declined intent now unmatched"
           (alist-ref declined 'match) "unmatched")
    (check "declined intent has no suggested-provider"
           (alist-ref declined 'suggested) "")))

;;; Decline Carol's participation as Carol — Alice and Bob both have
;;; participation skill, so the rematch should propose one of them.

(display "\n── 7b. decline (rematch available) ──\n")

(define carol-intent
  (find (lambda (i) (equal? (alist-ref i 'suggested) "agent-carol"))
        (alist-ref snap0 'intents)))

(when carol-intent
  (let ((dec-result
         (svc 'decline-assignment "org:meeting"
              (alist-ref carol-intent 'id) "agent-carol")))
    (check-pred "decline returns ok envelope"
                (and (pair? dec-result) (eq? (car dec-result) 'ok)))
    (check-pred "rematch returned a new provider"
                (and (pair? dec-result) (string? (cdr dec-result))))
    (check-pred "new provider is not Carol"
                (and (pair? dec-result)
                     (string? (cdr dec-result))
                     (not (equal? (cdr dec-result) "agent-carol")))))

  (let* ((snap4 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
         (rematched
          (find (lambda (i) (equal? (alist-ref i 'id) (alist-ref carol-intent 'id)))
                (alist-ref snap4 'intents))))
    (check "rematched intent is matched"
           (alist-ref rematched 'match) "matched")
    (check-pred "rematched intent has a suggested provider"
                (string? (alist-ref rematched 'suggested)))
    (check-pred "rematched provider is not Carol"
                (not (equal? (alist-ref rematched 'suggested)
                             "agent-carol")))))
;;; ── 7c. express-willingness → snapshot overlay (solver-offers-first) ────────
;;; The offer-side loop: a worker marks willing for a need; it persists as
;;; oi|worker|skill|cell meta and surfaces in the snapshot's willing 'race —
;;; no re-solve on the read path. Withdrawing flips the status to declined.

(display "\n── 7c. willingness overlay ──\n")

(let* ((snapc (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
       (open  (or (alist-ref snapc 'intents) '())))
  (when (pair? open)
    (let* ((it0  (car open))
           (spec (alist-ref it0 'spec))
           (cell (string-append (or (alist-ref it0 'at-location) "") "@0"))
           (wid  "agent-bob"))
      (check-pred "snapshot intent carries a cell key" (string? (alist-ref it0 'cell)))
      (check-pred "snapshot intent carries candidate-ids" (list? (alist-ref it0 'candidates)))
      (let ((wr (svc 'express-willingness "org:meeting" wid spec cell #t)))
        (check-pred "express-willingness returns ok envelope"
                    (and (pair? wr) (eq? (car wr) 'ok)))
        (check "express-willingness records status=willing" (cdr wr) 'willing))
      (let* ((snapw (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
             (it (find (lambda (i) (equal? (alist-ref i 'spec) spec))
                       (alist-ref snapw 'intents)))
             (mine (and it (member wid (alist-ref it 'willing '())))))
        (check-pred "bob's hand is up in the willing race after opting in" (and mine #t)))
      ;; withdraw → status flips to declined
      (svc 'express-willingness "org:meeting" wid spec cell #f)
      (let* ((snapw2 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
             (it (find (lambda (i) (equal? (alist-ref i 'spec) spec))
                       (alist-ref snapw2 'intents)))
             (mine (and it (member wid (alist-ref it 'willing '())))))
        (check "withdrawing lowers the hand: the row lists no one declined"
               (and mine #t) #f)))))
;;; ── 7d. materialize bridge: convex assignment → 'Awaiting your acceptance' ──
;;; persist-materialized! is what the service's `materialize` method calls after
;;; a willing-only plan: each assignment becomes a stored suggested intent
;;; (mi|worker|skill|cell) that surfaces in the snapshot as matched → the worker
;;; accepts → promote-to-commitment. Re-persisting clears the prior set.

(display "\n── 7d. materialize bridge ──\n")

(define (mi-prefix? s) (and (string? s) (>= (string-length s) 3) (string=? (substring s 0 3) "mi|")))

(let* ((work (list `((provider . "agent-bob") (conforms-to . "spec:participation")
                     (effort . 1.0) (input-of . "proc-meeting") (at-location . #f)))))
  ;; what a willing-only plan yields, persisted into the plan-store:
  (with-vat planner-vat (persist-materialized! meeting-scope work #:plan-id "plan-meeting"))
  (let* ((snap (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
         (mi (find (lambda (i) (mi-prefix? (alist-ref i 'id))) (alist-ref snap 'intents))))
    (check-pred "materialized intent surfaced in snapshot" (and mi #t))
    (check "materialized intent suggests the willing worker"
           (alist-ref mi 'suggested) "agent-bob")
    (check "materialized intent is matched (→ 'Awaiting your acceptance')"
           (alist-ref mi 'match) "matched")
    ;; the worker accepts → promote-to-commitment (the budget bind + lock)
    (let ((r (svc 'accept-assignment "org:meeting" (alist-ref mi 'id) "agent-bob")))
      (check-pred "accept the materialized assignment → ok"
                  (and (pair? r) (eq? (car r) 'ok)))))
  ;; re-materialize with the worker gone (withdrew / rebalanced out) → cleared
  (with-vat planner-vat (persist-materialized! meeting-scope '() #:plan-id "plan-meeting"))
  (let* ((snap2 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
         (mi2 (find (lambda (i) (mi-prefix? (alist-ref i 'id))) (alist-ref snap2 'intents))))
    (check-pred "stale materialized intent cleared on re-persist" (not mi2))))
;;; ── 7e. live/expected position — set-position round-trip ────────────────────
;;; All three sharing modes (manual / continuous / expected) call set-position;
;;; the planner then uses the place as the commute origin (engine effect proven
;;; in test-position.scm). Here we just confirm the service method persists it.

(display "\n── 7e. set-position (live/expected location) ──\n")

(let ((r (svc 'set-position "org:meeting" "agent-bob" 0 "town")))
  (check-pred "set-position returns ok" (and (pair? r) (eq? (car r) 'ok)))
  (check "set-position echoes the place" (cdr r) "town"))
(let ((r (svc 'set-position "org:meeting" "agent-bob" 0 #f)))
  (check "clearing position returns 'cleared" (cdr r) 'cleared))
;;; the registered home: the agent record's primary-location, the floor the
;;; position rule falls back to. "" with coordinates declares the member's own
;;; place; a known place id is taken as-is; an unknown one is refused.
(display "\n── 7e'. set-home (the registered home) ──\n")
(let ((r (svc 'set-home "org:meeting" "agent-bob" "" 52.52 13.4)))
  (check-pred "set-home from coordinates returns ok" (and (pair? r) (eq? (car r) 'ok)))
  (check "set-home declares the member's own place" (alist-ref (cdr r) 'place) "place:agent-bob:home"))
(let ((r (svc 'set-home "org:meeting" "agent-bob" "place:agent-bob:home" 0 0)))
  (check "set-home takes a known place" (alist-ref (cdr r) 'place) "place:agent-bob:home"))
(let ((r (svc 'set-profile "org:meeting" "agent-bob" "[\"age:41\"]")))
  (check-pred "set-profile updates an existing member" (and (pair? r) (eq? (car r) 'ok))))
(let ((r (svc 'set-home "org:meeting" "agent-bob" "nowhere-such" 0 0)))
  (check-pred "set-home refuses an unknown place" (and (pair? r) (eq? (car r) 'error))))

(display "\n── 7e''. declare-dwelling (the dwelling the housing closure reads) ──\n")
(let ((r (svc 'declare-dwelling "org:meeting" "agent-bob" "" 40 2 19 24 2 "[\"hs-sanitation\",\"hs-safety\"]" #t 20 "rent")))
  (check-pred "declare-dwelling at the registered home returns ok" (and (pair? r) (eq? (car r) 'ok)))
  (check "declare-dwelling seeds dwelling:AID" (alist-ref (cdr r) 'resource) "dwelling:agent-bob")
  (check "declare-dwelling stands at the registered home" (alist-ref (cdr r) 'place) "place:agent-bob:home")
  (check-pred "the unit's tags carry area, rooms, warmth, beds, gates, certificate, rent and tenure"
              (let ((tags (alist-ref (cdr r) 'tags)))
                (and (member "area-m2:40.0" tags) (member "rooms:2.0" tags) (member "warmth-winter-degc:19.0" tags) (member "warmth-summer-degc:24.0" tags) (member "beds:2" tags)
                     (member "attests:hs-safety" tags) (member "attests:hs-sanitation" tags)
                     (member "certified" tags) (member "rent-eur-night:20" tags) (member "tenure:rent" tags) #t))))
(check-pred "a rented dwelling is held under split custody — the wheel's rented family reads it"
            (let ((d (find (lambda (r) (equal? "dwelling:agent-bob" ((@ (playnet vf schemas) economic-resource-id) r)))
                           (with-vat planner-vat ($ ($ meeting-scope 'observer) 'all-resources)))))
              (and d ((@ (playnet vf schemas) resource-rented?) d)
                   (equal? "agent-bob" ((@ (playnet vf schemas) economic-resource-custodian-scope) d)))))
(let ((r (svc 'declare-dwelling "org:meeting" "agent-bob" "" 0 1 19 24 1 "" #f 0 "own")))
  (check-pred "declare-dwelling refuses a measurement that is not positive" (and (pair? r) (eq? (car r) 'error))))
(let ((r (svc 'declare-dwelling "org:meeting" "agent-bob" "nowhere-such" 40 2 19 24 1 "" #f 0 "own")))
  (check-pred "declare-dwelling refuses an unknown place" (and (pair? r) (eq? (car r) 'error))))
;;; ── 7f. materialize-willing: willing → 'Awaiting your acceptance' (live race) ──
;;; The browser calls materialize-willing right after express-willingness, so
;;; marking willing on an open need immediately assigns the willing worker (the
;;; race) and surfaces it as matched → they accept.

(display "\n── 7f. materialize-willing (the live calendar race) ──\n")

(let* ((snap (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
       (open (or (alist-ref snap 'intents) '())))
  (when (pair? open)
    (let* ((need (car open))
           (spec (alist-ref need 'spec))
           (cell (alist-ref need 'cell)))
      (svc 'express-willingness "org:meeting" "agent-bob" spec cell #t)
      (let ((r (svc 'materialize-willing "org:meeting")))
        (check-pred "materialize-willing returns ok" (and (pair? r) (eq? (car r) 'ok)))
        (check-pred "at least one assignment materialized"
                    (>= (alist-ref (cdr r) 'materialized 0) 1)))
      (let* ((snap2 (wire->plain (svc 'scope-snapshot "org:meeting" "plan-meeting")))
             (mi (find (lambda (i) (and (mi-prefix? (alist-ref i 'id))
                                        (equal? (alist-ref i 'suggested) "agent-bob")))
                       (alist-ref snap2 'intents))))
        (check-pred "willing worker now has a suggested mi| intent" (and mi #t))
        (when mi
          (check "the materialized assignment is matched (→ 'Awaiting your acceptance')"
                 (alist-ref mi 'match) "matched")
          (let ((a (svc 'accept-assignment "org:meeting" (alist-ref mi 'id) "agent-bob")))
            (check-pred "the willing worker accepts → ok"
                        (and (pair? a) (eq? (car a) 'ok)))))))))
;;; ── 8. process-context ────────────────────────────────────────────────────

(display "\n── 8. process-context (recipe topology lookup) ──\n")

(let* ((proc-id (alist-ref (car cmts1) 'proc))
       (ctx (svc 'process-context "org:meeting" proc-id)))
  (check "process-name resolved via process-registry → recipe-process"
         (alist-ref ctx 'proc-name) "Run Meeting")
  (check "inputs count = 4 (4 work flows in the recipe)"
         (length (or (alist-ref ctx 'inputs) '())) 4)
  (check "outputs count = 1 (the meeting-minutes produce flow)"
         (length (or (alist-ref ctx 'outputs) '())) 1))
;;; ── 9. Error envelopes ────────────────────────────────────────────────────

(display "\n── 9. error envelopes ──\n")

(let ((bad (wire->plain (svc 'scope-snapshot "no-such-scope" #f))))
  (check-pred "snapshot for unknown scope returns failure envelope"
              (and (pair? bad) (eq? (car bad) 'error))))

(let ((bad (svc 'accept-assignment "no-such-scope" "no-such-intent" "agent-alice")))
  (check-pred "accept for unknown scope returns failure envelope"
              (and (pair? bad) (eq? (car bad) 'error))))
;;; ── Summary ───────────────────────────────────────────────────────────────

(newline)
(display (string-append "══ Planner Service: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ══\n"))
(when (> fail-count 0)
  (exit 1))
