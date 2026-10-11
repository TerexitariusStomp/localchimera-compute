;;; module/playnet/doors/planner/work.scm — work at a scope: the witness ceremony, willingness, assignments taken and declined, effort recorded, the offer loop, contacts invited, and UC matching over the roster
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner work)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors assignments) #:select (do-accept-assignment do-decline-assignment do-express-willingness))
  #:use-module ((playnet doors effort) #:select (do-record-effort))
  #:use-module ((playnet doors offers) #:select (accept-regret commitment-drift offer-work plan-hours present-offers settled-solves))
  #:use-module ((playnet doors planner solve-cache) #:select (last-solve-ref))
  #:use-module ((playnet federation descent) #:select (deploy!))
  #:use-module ((playnet federation uc-matching) #:select (solve-uc-matching))
  #:use-module ((playnet plan accepts) #:select (deployment-bindings))
  #:use-module ((playnet pools availability-pool) #:select (entry-agent))
  #:use-module ((playnet scope policy) #:select (governance-policy))
  #:use-module ((playnet solve externality) #:select (voice-displacement))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) instant->unix now))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet vf schemas) #:select (commitment-effort-quantity intent-id intent-input-of make-intent make-proposal measure-has-numerical-value proposal-id proposal-name proposal-purpose))
  #:use-module ((srfi srfi-1) #:select (fold))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-work-doors))

(define (planner-work-doors ctx)
  (with-planner-ctx ctx
    ;; one proposal from each scope, then one more from each — the order the
    ;; union matching's greedy assignment walks, so no scope's whole slate
    ;; drains the pool before another scope's first proposal is heard
    (define (round-robin lists)
      (let ((live (filter pair? lists)))
        (if (null? live) '()
            (append (map car live) (round-robin (map cdr live))))))
    (declared-doors planner

      ;; ── the WITNESS ceremony: a work event asks its peers to co-sign ──────
      ;; OPEN spawns (or finds) the collecting ceremony over an already-recorded
      ;; event — the roster is the scope's own agents, the worker excluded by
      ;; the ceremony itself. INBOX lists what a citizen may co-sign. ATTEST
      ;; lands one signature; at quorum the single-signer provenance credential
      ;; STRENGTHENS in place to its witnessed, multisig form.
      ((witness-open scope-id aid event-id)
       (with-scope scope-id
         (lambda (root)
           (cond
             ((not witness-door) (failure "witnessing is not wired on this gateway"))
             ((not (ph-ok? aid)) (failure "needs-personhood"))
             (else
              (catch-as-failure
                (lambda ()
                  (let ((ev ($ ($ root 'observer) 'get-event event-id)))
                    (if (not ev)
                        (failure "event not found")
                        (let* ((roster (scope-community scope-id))
                               (said ((assq-ref witness-door 'open) scope-id ev roster)))
                          (if said
                              (success `((said . ,said)))
                              (failure "nothing to witness — no attestable work, or no peers"))))))))))))

      ((witness-inbox scope-id aid)
       (if (not witness-door)
           (failure "witnessing is not wired on this gateway")
           (catch-as-failure
             (lambda ()
               (success `((requests . ,((assq-ref witness-door 'inbox) aid))))))))

      ((witness-attest scope-id aid said sig)
       (cond
         ((not witness-door) (failure "witnessing is not wired on this gateway"))
         ((not (ph-ok? aid)) (failure "needs-personhood"))
         (else
          (catch-as-failure
            (lambda ()
              (let ((r ((assq-ref witness-door 'attest) said aid sig)))
                (if r
                    (success `((status . ,(symbol->string r))))
                    (failure "no ceremony collecting under that statement"))))))))

      ;; ── UC matching over the standing roster, landed by the descent ──
      ;; Every scope's rising proposals (purpose 'request, plan-bundle.scm)
      ;; meet the UC pool in ONE solve: the shadow prices coordinate every
      ;; scope's scale decision against the one supply, every scope's standing
      ;; accepts/holds seed the round before any assignment (so a person one
      ;; scope's accept already holds is consumed for all of them), and the
      ;; greedy walk takes the proposals round-robin across scopes — roster
      ;; position confers nothing. The flat deployment then enters the descent
      ;; at the root and each scope's plan-store receives exactly its own
      ;; commitments.
      ((match-labour!)
       (catch-as-failure
         (lambda ()
           (let ((stores (make-hash-table)))        ; proposal-id → plan-store
             (let loop ((rows (roster-entries))
                        (grouped '()) (seed '()) (tentative '()))
               (if (null? rows)
                   (let* ((result (solve-uc-matching
                                   (round-robin (reverse grouped)) #f
                                   ($ (nodes-labour uc) 'pool)
                                   #:plan-store-of
                                   (lambda (p) (hash-ref stores (proposal-id p) #f))
                                   ;; the steward gate on each candidate: the
                                   ;; plan's scope (the routing table) names the
                                   ;; root whose recipes say what the intent's
                                   ;; process draws
                                   #:admit?
                                   (and may-steward-of
                                        (lambda (e wi pid)
                                          (let* ((sid (hash-ref deployment-table pid #f))
                                                 (root (and sid (roster-ref sid))))
                                            (or (not root)
                                                (steward-ok? root sid (entry-agent e)
                                                             (intent-input-of wi))))))
                                   #:seed seed #:tentative tentative))
                          (dep (or (assq-ref result 'deployment) '())))
                     (deploy! (nodes-deployment uc) dep)
                     (success
                      `((commitments . ,(length dep))
                        (hours . ,(fold (lambda (c a)
                                          (+ a (let ((m (commitment-effort-quantity c)))
                                                 (if m (measure-has-numerical-value m) 0))))
                                        0 dep)))))
                   (let* ((sid  (caar rows))
                          (root (cdar rows))
                          (ps   (false-if-exception ($ root 'plan-store)))
                          (props (if ps
                                     (filter (lambda (p) (eq? (proposal-purpose p) 'request))
                                             ($ ps 'all-proposals))
                                     '())))
                     (for-each (lambda (p)
                                 (let ((n (proposal-name p)))
                                   (when (and (string? n) (string-prefix? "plan:" n))
                                     (hash-set! deployment-table (substring n 5) sid))
                                   (hash-set! stores (proposal-id p) ps)))
                               props)
                     (if (not ps)
                         (loop (cdr rows) grouped seed tentative)
                         (call-with-values (lambda () (deployment-bindings ps))
                           (lambda (s t)
                             (loop (cdr rows)
                                   (if (null? props) grouped (cons props grouped))
                                   (append s seed) (append t tentative))))))))))))

      ((accept-assignment scope-id intent-id acting-as)
       (with-person scope-id acting-as
         (lambda (root)
           (let ((r (do-accept-assignment root intent-id acting-as scope-id
                                          #:admit? (steward-admit root scope-id))))
             (when (and (pair? r) (eq? (car r) 'ok))
               (resolve-scope! scope-id root))   ; the accept re-plans the scope
             r))))

      ((decline-assignment scope-id intent-id acting-as)
       (with-scope scope-id
         (lambda (root) (do-decline-assignment root intent-id acting-as))))

      ;; The solver-offers-first loop: respond to a candidate-field offer by marking
      ;; willing (opt in to be materializable for skill@cell) or withdrawing it. Over-
      ;; subscribable; binds nothing here. A subsequent `plan` with (willing-only . #t)
      ;; materializes the feasible optimum over the willing, bounded by each hours-budget.
      ((express-willingness scope-id worker skill cell willing? #:optional (hours #f))
       (with-person scope-id worker
         (lambda (root)
           (do-express-willingness root worker skill cell willing? hours))))

      ((record-effort scope-id commitment-id acting-as qty unit)
       (with-scope scope-id
         (lambda (root) (do-record-effort root commitment-id acting-as qty unit))))

      ;; Social invite (non-work). The inviter creates an Intent (action='use,
      ;; name=human label, event time on has-beginning/has-end, provider=inviter,
      ;; receiver=invitee) wrapped in a directed Proposal (proposed-to=[invitee]).
      ;; The invitee sees it under their snapshot's `proposals` (build-snapshot
      ;; filters by proposed-to) and accepts via accept-invite. Reuses the VF
      ;; proposal machinery; no schema change. The proposal's own temporal window is
      ;; left #f (always acceptable) — validate-proposal-acceptance! compares it to
      ;; (instant->unix (clock-now)) as a STRING, which would misbehave against an ISO datetime.
      ((invite-contact scope-id inviter invitee label t0-iso t1-iso)
       (with-person scope-id inviter
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let* ((ps  ($ root 'plan-store))
                      ;; scope-wide bare epoch-seconds collided: two invites
                      ;; from DIFFERENT people in one second silently
                      ;; overwrote each other (add-intent/add-proposal are
                      ;; hashmap-set) and the first invitee never saw
                      ;; theirs. The inviter + their own running count
                      ;; disambiguates — the record-purchase pattern.
                      (iid (string-append "inv-" inviter ":"
                                          (number->string (instant->unix (clock-now))) ":"
                                          (number->string
                                           (length (filter (lambda (i)
                                                             (string-prefix? (string-append "inv-" inviter ":")
                                                                             (or (intent-id i) "")))
                                                           ($ ps 'all-intents))))))
                      (pid (string-append "prop-" iid))
                      (lbl (if (and (string? label) (not (string=? label ""))) label "event"))
                      ;; VF: an Intent is one-sided — provider=inviter only; the
                      ;; invitee rides in the proposal's proposed-to and fills the
                      ;; receiver slot at accept (counterparty), avoiding the
                      ;; "Intent cannot have both provider and receiver" constraint.
                      (intent (make-intent #:id iid #:action 'use #:name lbl       ; id action name note image
                         ; input/output/res-inv/res-conf/res-class
                            ; resource/effort/available/minimum qty
                                #:provider inviter                           ; provider receiver(open)
                                #:has-beginning t0-iso #:has-end t1-iso                  ; has-beginning has-end has-point due
                            ; at-location stage state planned-within
   #:in-scope-of (list scope-id)))           ; satisfies in-scope-of finished avail-window
                      (proposal (make-proposal #:id pid #:name lbl #:created (now) ; id name note has-beg has-end unit-based created
                                  #:purpose 'offer #:in-scope-of (list scope-id)          ; purpose eligible-location in-scope-of
                                  #:publishes (list iid) #:proposed-to (list invitee))))    ; publishes reciprocal proposed-to
                 ($ ps 'add-intent intent)
                 ($ ps 'add-proposal proposal)
                 (success `((proposal . ,pid) (invitee . ,invitee)))))))))

      ;; The invitee accepts a social invite → promotes the event intent to a
      ;; commitment for both. accepting-agent-id is whitelist-validated against the
      ;; proposal's proposed-to (validate-proposal-acceptance!).
      ((accept-invite scope-id agent-id proposal-id)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               ;; counterparty fills the intent's open receiver slot with the
               ;; accepting agent → the event becomes a commitment inviter→invitee.
               ($ ($ root 'plan-store) 'accept-proposal proposal-id
                  (list (cons 'receiver agent-id))
                  (list (cons 'accepting-agent-id agent-id)))
               (success `((accepted . ,proposal-id))))))))

      ;; ── the offer loop's two doors (commitment-horizon.md: the bounded rung) ──
      ;; A work offer is a DIRECTED proposal with an acceptance window: the
      ;; invitee sees it under their snapshot's `proposals` (the proposed-to
      ;; filter invite-contact already rides), the solve holds its column
      ;; while they decide (live.scm's offer loop), and the horizon gate
      ;; stands at the accept as at every accept.
      ((offer-work scope-id agent-id proc hours when-iso place skill #:optional (until #f))
       (scoped scope-id
         (lambda (root)
           (let ()
             `((proposal . ,(offer-work root
                              `((input-of . ,proc) (effort . ,hours)
                                (when . ,(string-or-false when-iso)) (at-location . ,(string-or-false place))
                                (conforms-to . ,(string-or-false skill))
                                (until . ,(string-or-false until)))
                              agent-id)))))))

      ;; the presentation caller: the LAST solve's work rows walked
      ;; nearest-forcing-first, each deployment suggestion turned into a
      ;; directed offer (live.scm present-offers — ranking pluggable there;
      ;; this door carries the default policy). Self-serve stays open.
      ((present-offers scope-id)
       (scoped scope-id
         (lambda (root)
           (let ((cached (last-solve-ref cache scope-id)))
             (unless cached
               (error "present-offers: no solve stands for this scope — plan first"))
             `((proposals . ,(present-offers root (cdr cached))))))))

      ;; κ against the lapse and release rates, one window, one clock — the
      ;; empirical read the renegotiation-cadence conjecture has to pass
      ((commitment-drift scope-id #:optional (window-days 7.0) (at #f))
       (scoped scope-id
         (lambda (root)
           (commitment-drift ($ root 'plan-store)
                             #:window-days (if (number? window-days) window-days 7.0)
                             #:at (and (number? at) at)))))

      ;; the regret diagnostic at the accept door: the standing accepts
      ;; priced against the pins-freed counterfactual of the last solve's
      ;; own demand (live.scm accept-regret) — the number a person weighs
      ;; before locking in more. Two solves; an explicit ask, never ambient.
      ((accept-regret scope-id)
       (scoped scope-id
         (lambda (root)
           ;; the standing solve's demand when one stands, else the scope's own
           ;; declared demand (the base of the pair is a solve either way)
           (accept-regret root #:demand (let ((cached (last-solve-ref cache scope-id))) (if cached (car cached) '()))
                          #:solve (lambda kw (apply plan-fn* root scope-id kw))))))

      ;; what voice displaces, as a total (externality voice-displacement): the standing
      ;; field against the same program at τ = 0, on the last solve's demand,
      ;; both through this scope's one door — the number beside the marginal
      ;; the solve's own alist carries under `voice`. An explicit ask, two solves.
      ((voice-displacement scope-id)
       (scoped scope-id
         (lambda (root)
           (let ((cached (last-solve-ref cache scope-id)))
             (let* ((tau (governance-policy ($ root 'plan-store) 'voice-tau))
                    (solve-at (settled-solves (lambda kw (apply plan-fn* root scope-id kw))
                                              (list #:demand (if cached (car cached) '()))
                                              `((,tau . (#:voice-tau ,tau)) (0.0 . (#:voice-tau 0.0)))))
                    (met-of (lambda (r) (or (assq-ref r 'met) 0.0))))
               `((tau . ,tau)
                 (hours-at-tau . ,(plan-hours (solve-at tau)))
                 (hours-at-zero . ,(plan-hours (solve-at 0.0)))
                 (moved-hours . ,(voice-displacement solve-at plan-hours tau))
                 (moved-met . ,(voice-displacement solve-at met-of tau))
                 (parts . ,(let ((v (assq-ref (solve-at tau) 'voice))) (if v (or (assq-ref v 'parts) '()) '())))))))))

      ;; the accepting worker is the PROVIDER (an invite's mirror image, where
      ;; the invitee fills receiver); the scope receives the work
      ((accept-work-offer scope-id agent-id proposal-id)
       (scoped scope-id
         (lambda (root)
           ($ ($ root 'plan-store) 'accept-proposal proposal-id
              (list (cons 'provider agent-id) (cons 'receiver scope-id))
              (list (cons 'accepting-agent-id agent-id)))
           (resolve-scope! scope-id root)             ; the accept re-plans the scope
           `((accepted . ,proposal-id)))))

      ;; the decided rung's withdrawal — retire-need's mirror at the
      ;; commitment layer: the provider releases their own accept, the pin
      ;; drops at the next solve, the satisfied intent reopens as a
      ;; standing declaration (planning.scm release-commitment)
      ((release-commitment scope-id agent-id cid)
       (scoped scope-id
         (lambda (root)
           ($ ($ root 'plan-store) 'release-commitment cid agent-id (instant->unix (clock-now)))
           (resolve-scope! scope-id root)             ; the freed slot re-enters the plan NOW
           `((released . ,cid))))))))
