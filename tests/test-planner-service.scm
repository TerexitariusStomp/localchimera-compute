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
;;;   guile -L module -L key-pool tests/test-planner-service.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet ddmrp)        ; alist-ref
             (srfi srfi-1))

(add-to-load-path "key-pool")
(primitive-load "server/planner-loader.scm")
(primitive-load "server/planner-service.scm")
(primitive-load "server/seed-meeting-scope.scm")


;;; ── Harness ────────────────────────────────────────────────────────────────

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


;;; ── Spawn the planner + service ────────────────────────────────────────────

(display "\n── Setup: planner-vat + scope + service ──\n")

(define planner-store (make-memory-store))
(define-values (planner-vat meeting-scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Meeting Commune"))
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

(define snap0 (svc 'scope-snapshot "org:meeting" "plan-meeting"))

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
  (find (lambda (i) (equal? (alist-ref i 'suggested-provider) "agent-alice"))
        (alist-ref snap0 'intents)))

(check-pred "alice intent exists" alice-intent)
(check "alice intent process-name"
       (alist-ref alice-intent 'process-name) "Run Meeting")
(check "alice intent match-status"
       (alist-ref alice-intent 'match-status) 'matched)
(check "alice intent suggested-provider-name"
       (alist-ref alice-intent 'suggested-provider-name) "Alice")
(check "alice intent fulfilled-qty starts at 0"
       (alist-ref alice-intent 'fulfilled-qty) 0)
(check-pred "alice intent has YYYY-MM-DD date"
            (and (string? (alist-ref alice-intent 'date))
                 (= 10 (string-length (alist-ref alice-intent 'date)))))
(check-pred "alice intent has start-hour as a number"
            (number? (alist-ref alice-intent 'start-hour)))


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

(define snap1 (svc 'scope-snapshot "org:meeting" "plan-meeting"))
(define cmts1 (alist-ref snap1 'commitments))

(check "commitments count = 1" (length cmts1) 1)
(check "commitment provider"
       (alist-ref (car cmts1) 'provider) "agent-alice")
(check "commitment provider-name"
       (alist-ref (car cmts1) 'provider-name) "Alice")
(check "commitment match-status"
       (alist-ref (car cmts1) 'match-status) 'accepted)
(check "commitment fulfilled-qty starts at 0"
       (alist-ref (car cmts1) 'fulfilled-qty) 0)
(check "commitment effort-qty"
       (alist-ref (car cmts1) 'effort-qty) 1)
;; commitments-for-plan index update from the planner fix should mean
;; the commitment is found through the plan-id filter.
(check "commitment plan-id matches"
       (alist-ref (car cmts1) 'plan-id) "plan-meeting")


;;; ── 6. record-effort → fulfillment ────────────────────────────────────────

(display "\n── 6. record-effort → fulfillment-state advances ──\n")

(define rec-result
  (svc 'record-effort "org:meeting" commit-id "agent-alice" 1 "hours"))

(check-pred "record-effort returns ok envelope"
            (and (pair? rec-result) (eq? (car rec-result) 'ok)))
(check-pred "record-effort returns event id"
            (string? (cdr rec-result)))

(define snap2 (svc 'scope-snapshot "org:meeting" "plan-meeting"))
(define cmts2 (alist-ref snap2 'commitments))

(check "fulfilled-qty advanced to 1"
       (alist-ref (car cmts2) 'fulfilled-qty) 1)


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
  (find (lambda (i) (equal? (alist-ref i 'suggested-provider) "agent-bob"))
        (alist-ref snap0 'intents)))

(when bob-intent
  (let ((dec-result
         (svc 'decline-assignment "org:meeting"
              (alist-ref bob-intent 'id) "agent-bob")))
    (check-pred "decline returns ok envelope"
                (and (pair? dec-result) (eq? (car dec-result) 'ok)))
    (check "no rematch found → 'cleared"
           (cdr dec-result) 'cleared))

  (let* ((snap3 (svc 'scope-snapshot "org:meeting" "plan-meeting"))
         (declined
          (find (lambda (i) (equal? (alist-ref i 'id) (alist-ref bob-intent 'id)))
                (alist-ref snap3 'intents))))
    (check "declined intent now unmatched"
           (alist-ref declined 'match-status) 'unmatched)
    (check "declined intent has no suggested-provider"
           (alist-ref declined 'suggested-provider) #f)))

;;; Decline Carol's participation as Carol — Alice and Bob both have
;;; participation skill, so the rematch should propose one of them.

(display "\n── 7b. decline (rematch available) ──\n")

(define carol-intent
  (find (lambda (i) (equal? (alist-ref i 'suggested-provider) "agent-carol"))
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

  (let* ((snap4 (svc 'scope-snapshot "org:meeting" "plan-meeting"))
         (rematched
          (find (lambda (i) (equal? (alist-ref i 'id) (alist-ref carol-intent 'id)))
                (alist-ref snap4 'intents))))
    (check "rematched intent is matched"
           (alist-ref rematched 'match-status) 'matched)
    (check-pred "rematched intent has a suggested provider"
                (string? (alist-ref rematched 'suggested-provider)))
    (check-pred "rematched provider is not Carol"
                (not (equal? (alist-ref rematched 'suggested-provider)
                             "agent-carol")))))


;;; ── 8. process-context ────────────────────────────────────────────────────

(display "\n── 8. process-context (recipe topology lookup) ──\n")

(let* ((proc-id (alist-ref (car cmts1) 'process-id))
       (ctx (svc 'process-context "org:meeting" proc-id)))
  (check "process-name resolved via process-registry → recipe-process"
         (alist-ref ctx 'process-name) "Run Meeting")
  (check "inputs count = 4 (4 work flows in the recipe)"
         (length (or (alist-ref ctx 'inputs) '())) 4)
  (check "outputs count = 1 (the meeting-minutes produce flow)"
         (length (or (alist-ref ctx 'outputs) '())) 1))


;;; ── 9. Error envelopes ────────────────────────────────────────────────────

(display "\n── 9. error envelopes ──\n")

(let ((bad (svc 'scope-snapshot "no-such-scope" #f)))
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
