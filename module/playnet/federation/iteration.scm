;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/iteration.scm — Budget disclosure + counter-proposal loop.
;;;
;;; Each round: leaves submit rising Proposals → UC solves matching →
;;; UC discloses alternative budgets → leaves volunteer counter-
;;; proposals (new Proposals) → matching re-runs.
;;;
;;; Terminates because re-drawn/volunteered Proposals are strictly
;;; smaller in labour-demand.

(define-module (playnet federation iteration)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet matching schemas)
  #:use-module (playnet matching spatial)
  #:use-module (playnet federation plan-bundle)
  #:use-module (playnet pools availability-pool)
  #:use-module ((playnet vf facts availability) #:select (iso-dates-through))
  #:use-module (playnet federation uc-matching)
  #:use-module ((playnet plan accepts) #:select (deployment-bindings))
  #:export (labour-matching-iterate
            disclose-budgets
            accept-counter-proposals
            strictly-smaller?
            *max-labour-rounds*))


(define *max-labour-rounds* 10)

(define (assoc-ref alist key)
  (let ((p (assoc key alist equal?))) (if p (cdr p) #f)))


;;; ── Budget disclosure ───────────────────────────────────────────────────────
;;; B_disclosed(ℓ,k,t,r) = (⋃_{c ∈ ring(cell(ℓ),r)} A_k(t,c)) ∩ A^free

(define* (disclose-budgets matching-result pool proposals plan-store
                            #:key (catchment-radius
                                   *default-search-radius-km*))
  "For each rising Proposal, compute the disclosed budget: available
   hours within catchment ring, per skill, after deployed agents are
   subtracted. Returns alist of (proposal-id . budget)."
  (let* ((deployment (or (assoc-ref matching-result 'deployment) '()))
         (residual (pool-free pool deployment)))
    (map (lambda (prop)
           (let* ((wis (proposal-work-intents prop plan-store))
                  ;; the days the proposal's intents name: the budget is the
                  ;; roster's hours ON them (a week where none is named)
                  (dates (delete-duplicates
                          (append-map (lambda (wi)
                                        (let ((b (intent-has-beginning wi)) (e (intent-has-end wi)))
                                          (if (and (string? b) (string? e)) (iso-dates-through b e) '())))
                                      wis)))
                  (leaf-cell (and (pair? wis)
                                  (intent-at-location (car wis))))
                  (skills (delete-duplicates
                           (map intent-resource-conforms-to wis)))
                  (budget
                   (map (lambda (sk)
                          (let ((slots
                                 (pool-query residual
                                   #:skill sk
                                   #:cell (or leaf-cell *remote-h3-index*)
                                   #:radius catchment-radius)))
                            (cons sk (fold (lambda (s acc)
                                            (+ (if (null? dates) (entry-hours s) (entry-hours-on s dates))
                                               acc))
                                          0 slots))))
                        skills)))
             (cons (proposal-id prop) budget)))
         proposals)))


;;; ── Counter-proposals ───────────────────────────────────────────────────────

(define (accept-counter-proposals existing new-proposals)
  "Merge new counter-proposal Proposals into the plan set. Each new
   Proposal replaces the existing one from the same scope."
  (let ((new-by-scope
         (fold (lambda (p hm)
                 (let ((scopes (proposal-in-scope-of p)))
                   (if (pair? scopes)
                       (hashmap-set hm (car scopes) p)
                       hm)))
               (hashmap) new-proposals)))
    (append
     (filter (lambda (p)
               (let ((scopes (proposal-in-scope-of p)))
                 (not (and (pair? scopes)
                           (hashmap-ref new-by-scope (car scopes) #f)))))
             existing)
     new-proposals)))

(define (strictly-smaller? new-proposals old-proposals plan-store)
  "True if every new Proposal has strictly less total hours than the
   old Proposal from the same scope it replaces."
  (every (lambda (np)
           (let* ((scope (and (pair? (proposal-in-scope-of np))
                              (car (proposal-in-scope-of np))))
                  (old (find (lambda (op)
                               (and (pair? (proposal-in-scope-of op))
                                    (equal? (car (proposal-in-scope-of op))
                                            scope)))
                             old-proposals)))
             (or (not old)
                 (< (proposal-total-hours np plan-store)
                    (proposal-total-hours old plan-store)))))
         new-proposals))


;;; ── Iteration loop ──────────────────────────────────────────────────────────

(define* (labour-matching-iterate proposals plan-store pool
                                  #:key (voice-weight-fn #f)
                                        (affinity-fn #f)
                                        (continuity-fn #f)
                                        (counter-proposal-fn #f))
  "Run the full iteration protocol. PROPOSALS is a list of VF
   Proposals (rising plans). COUNTER-PROPOSAL-FN: (budgets result →
   new-proposals-or-'()). Returns final matching-result. The plan-store's
   standing bindings enter every round (commitment-horizon.md): accepts
   consume their provider's pool entry and book the slot, held offers
   book the proposed person's slot only — deployment-bindings compiles
   both, once, before the loop."
  (call-with-values (lambda () (deployment-bindings plan-store))
    (lambda (seed tentative)
  (let loop ((current proposals) (round 0))
    (let ((result (solve-uc-matching current plan-store pool
                                     #:voice-weight-fn voice-weight-fn
                                     #:affinity-fn affinity-fn
                                     #:continuity-fn continuity-fn
                                     #:seed seed #:tentative tentative)))
      (if (or (not counter-proposal-fn)
              (>= round *max-labour-rounds*))
          (append result `((rounds . ,(+ round 1))))
          (let* ((budgets (disclose-budgets result pool current plan-store))
                 (new (counter-proposal-fn budgets result)))
            (if (or (null? new)
                    (not (strictly-smaller? new current plan-store)))
                (append result `((rounds . ,(+ round 1))))
                (loop (accept-counter-proposals current new)
                      (+ round 1))))))))))
