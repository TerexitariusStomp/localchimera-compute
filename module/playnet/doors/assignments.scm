;;; module/playnet/doors/assignments.scm — an assignment accepted or declined, and the willingness a person marks on a cell.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet doors assignments)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet algorithms skill-matcher) #:select (match-work-flows))
  #:use-module ((playnet scope live) #:select (willing-tuples))
  #:use-module ((playnet vf facts work-ids) #:select (offer-intent-id))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet vf formulas actions) #:select (drawing-actions))
  #:use-module ((playnet vf formulas flows) #:select (row-scopes))
  #:use-module ((playnet vf schemas) #:select (intent-action intent-input-of intent-provider intent-receiver intent-resource-conforms-to make-recipe-flow))
  #:export (do-accept-assignment willing-key do-express-willingness willing-predicate do-decline-assignment))


(define* (do-accept-assignment scope-root iid provider scope-id #:key (admit? #f))
  "Promote an intent to a commitment, register the new commitment with
   the observer so fulfillment tracking is armed, return (ok . cid).
   ADMIT? (provider proc → bool), when given, is the steward gate — the
   owners' rule over who may draw the means the work's process uses; this
   door is where every assignment path ends, so it is asked here whatever
   presented the work."
  (let ((ps  ($ scope-root 'plan-store))
        (obs ($ scope-root 'observer)))
    (catch-as-failure
      (lambda ()
        ;; a DEMAND is worked toward, never accepted shut: a consume/use
        ;; intent addressed to someone else is the scope's standing terms —
        ;; the very demand the plan runs on — and only FULFILLMENT (events)
        ;; finishes it. Stated at the door, so no presentation rule
        ;; anywhere upstream has to remember it.
        (let ((it ($ ps 'get-intent iid)))
          (when (and it (memq (intent-action it) drawing-actions)
                     (intent-receiver it)
                     (not (equal? (intent-receiver it) provider)))
            (error "a demand is worked toward, never accepted shut" iid))
          ;; an offer that names its provider is that provider's to accept
          (when (and it (intent-provider it) (not (equal? provider (intent-provider it))))
            (error "this offer names another provider" iid provider))
          (when (and it admit? (not (admit? provider (intent-input-of it))))
            (error "the means this work draws are lent under a steward rule that names others"
                   iid provider)))
        (let ((cid ($ ps 'promote-to-commitment iid
                       `((provider . ,provider)
                         (receiver . ,scope-id)))))
          (cond
            ((not cid) (failure "promote-to-commitment returned #f"))
            (else
             ;; the store armed its target on the observer as it stood
             (success cid))))))))

;; ── Willingness: the solver-offers-first labour loop ─────────────────────────
;; The convex plan offers a candidate FIELD (per need, who'd help + a fair share).
;; A person responds by marking themselves WILLING (or withdrawing → DECLINED) for a
;; given skill@cell. Willingness is over-subscribable and binds NOTHING here — it is
;; an option, not a commitment; the single hours-budget bounds materialization later.
;; State lives as `status` meta on the DETERMINISTIC offer-intent id (oi|w|skill|cell),
;; so it persists across re-solves even though the intents are re-derived each plan.
(define willing-key offer-intent-id)   ; a willingness is kept under its offer intent's id

(define* (do-express-willingness scope-root worker skill cell willing? #:optional (hours #f))
  "Stamp WORKER's willingness for SKILL at CELL. willing? = #t marks status=willing
   (the person opts in to be materializable here); #f marks status=declined (withdraw).
   HOURS = the willing hours (an upper option, not a budget bind). The next
   gated re-solve admits only status=willing workers; the bundle hour-cap bounds them."
  (let ((ps ($ scope-root 'plan-store)))
    (catch-as-failure
      (lambda ()
        ($ ps 'set-meta (willing-key worker skill cell)
           `((status        . ,(if willing? 'willing 'declined))
             (worker        . ,worker) (skill . ,skill) (cell . ,cell)
             ,@(if hours `((willing-hours . ,hours)) '())))
        (success (if willing? 'willing 'declined))))))

;; Build the *willing?* gate predicate from persisted willingness meta. Returns #f
;; (⇒ the engine's default *willing?* ≡ #t, ungated — today's behaviour, the FIELD)
;; unless someone has opted in; once any status=willing exists, the predicate admits
;; ONLY status=willing (worker skill cell) triples — the MATERIALIZATION binding.
(define (willing-predicate scope-root)
  (let ((willing (willing-tuples ($ scope-root 'plan-store))))   ; shared scan (live.scm)
    (and (pair? willing)
         (lambda (w s c) (and (member (list w s c) willing) #t)))))      ; else derived expected, per period

(define (do-decline-assignment scope-root iid acting-as)
  "Decline a suggested assignment. Two-step:
     1. Clear the existing suggested-provider metadata.
     2. Re-run match-work-flows for this intent's spec, with ACTING-AS
        in #:already-assigned, so the matcher proposes a different
        in-scope agent. If found, stamp the new suggestion. Otherwise
        the intent stays unmatched and surfaces in 'Needs a volunteer'.
   Returns (ok . new-provider) if a fresh match was found,
   (ok . cleared) otherwise."
  (catch-as-failure
    (lambda ()
      (let* ((ps    ($ scope-root 'plan-store))
             (obs   ($ scope-root 'observer))
             (as    ($ scope-root 'agent-store))
             (it    ($ ps 'get-intent iid)))
        (cond
          ((not it) (failure "intent not found"))
          (else
           ;; Step 1: clear existing suggestion
           ($ ps 'set-meta iid '())
           ;; Step 2: synthesize a single-element work-flow list and
           ;; re-run the matcher with the declining agent excluded.
           ;; match-work-flows only reads recipe-flow-id and
           ;; recipe-flow-resource-conforms-to from each flow.
           (let* ((spec    (intent-resource-conforms-to it))
                  (synthetic-flow
                    (make-recipe-flow #:id iid #:action 'work #:resource-conforms-to spec))
                  (scope-id (let ((scopes (row-scopes it)))   ; inScopeOf, a list (or one id on an older row)
                              (and (pair? scopes) (car scopes))))
                  (result (match-work-flows
                            (list synthetic-flow) obs as
                            #:scope-id scope-id
                            #:already-assigned (if acting-as
                                                   (list acting-as)
                                                   '())))
                  (new-provider (and (pair? result)
                                     (cdr (car result)))))
             (cond
               (new-provider
                ($ ps 'set-meta iid `((suggested-provider . ,new-provider)))
                (success new-provider))
               (else
                (success 'cleared))))))))))