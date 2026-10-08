;;; demand-critique.scm — feasibility / quality critique for a demand.
;;;
;;; Given a scope and a demand-side <intent>, ask the relational
;;; planner (demand-o) whether the wish can be solved. Return a
;;; structured critique record classifying the demand and offering
;;; suggestions when it's not tractable.
;;;
;;; Categories:
;;;   tractable       — planner finds a non-'unmet plan-term.
;;;   vague           — intent missing the minimum fields demand-o
;;;                     needs (spec-id, quantity). No point probing
;;;                     the planner; suggest elaborations.
;;;   infeasible      — probe returns no result or only 'unmet.
;;;                     Probably no producer recipe exists, or the
;;;                     spec-id is unknown.
;;;   over-specified  — the intent pins a field the planner could
;;;                     have used for a better plan if left free. A
;;;                     simple relaxation check on at-location: if
;;;                     pinning forces 'produce but relaxing yields
;;;                     'satisfied, flag it.
;;;
;;; Critique record: alist with keys
;;;   category, rationale, suggestions (list of strings),
;;;   plan-preview (plan-term | #f).

(define-module (playnet deprecated governance demand-critique)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet deprecated planner)
  #:use-module (playnet deprecated kanren-constraints)
  #:export (critique-demand critique-category critique-rationale
            critique-suggestions critique-plan-preview))


;; =========================================================================
;; Critique accessors (alist shape)
;; =========================================================================

(define (critique-category c)     (assq-ref c 'category))
(define (critique-rationale c)    (assq-ref c 'rationale))
(define (critique-suggestions c)  (assq-ref c 'suggestions))
(define (critique-plan-preview c) (assq-ref c 'plan-preview))

(define (make-critique category rationale suggestions plan-preview)
  `((category     . ,category)
    (rationale    . ,rationale)
    (suggestions  . ,suggestions)
    (plan-preview . ,plan-preview)))


;; =========================================================================
;; Probe: run demand-o once against the lifted facts
;; =========================================================================

(define* (probe-demand ctx spec-id qty due #:key (at-location #f) (depth 6))
  "Run demand-o once; return the first plan-term or #f."
  (let* ((ns (empty-netter-state))
         (results
           (run-plan 1 ns (q)
             (demand-o ctx spec-id qty due q
                       #:depth depth
                       #:at-location at-location))))
    (and (pair? results) (car results))))

(define (plan-term-kind pt)
  "Extract the kind symbol from a plan-term (satisfied / produce /
   transport / unmet), or #f if PT isn't a list."
  (and (list? pt) (pair? pt) (car pt)))

(define (tractable-kind? k)
  (memq k '(satisfied produce transport)))

(define (kind-rank k)
  "Higher is better. #f = no plan-term."
  (case k
    ((satisfied) 3)
    ((produce transport) 2)
    ((unmet) 1)
    (else 0)))

(define (try-relaxation ctx spec-id qty due at-loc depth pinned-kind)
  "If AT-LOC is pinned, run demand-o without it. Return the unpinned
   plan-term iff its kind is strictly better than PINNED-KIND, else #f."
  (and at-loc
       (let* ((un (probe-demand ctx spec-id qty due
                                #:at-location #f
                                #:depth depth))
              (un-kind (plan-term-kind un)))
         (and (> (kind-rank un-kind) (kind-rank pinned-kind)) un))))

(define (has-producer-path? facts spec-id)
  "#t if FACTS contain a recipe with output SPEC-ID, or any inventory
   fact referencing SPEC-ID. Structural feasibility — the planner
   might still return 'unmet at a given world-state (no wheat on
   hand) but the spec itself isn't ontologically unreachable."
  (any (lambda (f)
         (and (pair? f)
              (or (and (eq? (car f) 'recipe)
                       (>= (length f) 4)
                       (equal? (list-ref f 3) spec-id))
                  (and (eq? (car f) 'inventory)
                       (>= (length f) 3)
                       (equal? (list-ref f 2) spec-id)))))
       facts))


;; =========================================================================
;; Public: critique-demand
;; =========================================================================

(define* (critique-demand scope intent #:key (depth 8))
  "Assess whether SCOPE's planner can solve INTENT. Returns a critique
   record (alist). SCOPE is a ^scope-root actor (near-ref); must be
   called inside its vat."
  (let* ((spec-id (intent-resource-conforms-to intent))
         (qty-measure (intent-resource-quantity intent))
         (qty-num (and qty-measure (measure-has-numerical-value qty-measure)))
         (at-loc (intent-at-location intent)))
    (cond
      ((not spec-id)
       (make-critique 'vague
                      "No resource-conforms-to; planner cannot search without a spec."
                      '("Elaborate resource-conforms-to with a known spec-id.")
                      #f))
      ((not qty-num)
       (make-critique 'vague
                      "No resource-quantity; planner needs a quantity to size the plan."
                      '("Elaborate quantity-value + quantity-unit.")
                      #f))
      (else
       (let* ((qty (inexact->exact (ceiling qty-num)))
              (facts (lift-planning-facts ($ scope 'recipe-store)))
              (ctx (make-plan-ctx facts ($ scope 'plan-store)
                                  ($ scope 'observer) #f
                                  "critique" #f))
              ;; Rough placeholder for "due": demand-o uses due for
              ;; scheduling; a distant future date lets feasibility
              ;; dominate over schedule-pressure for this critique.
              (due (+ (current-time) (* 365 86400)))
              (pinned-result (probe-demand ctx spec-id qty due
                                           #:at-location at-loc
                                           #:depth depth)))
         (classify ctx facts spec-id qty due at-loc depth pinned-result))))))


;; =========================================================================
;; Classification logic
;; =========================================================================

(define (classify ctx facts spec-id qty due at-loc depth pinned)
  (let ((kind (plan-term-kind pinned)))
    (cond
      ;; No structural path — spec truly unreachable in this scope.
      ((not (has-producer-path? facts spec-id))
       (make-critique 'infeasible
                      (string-append
                        "No recipe produces " spec-id
                        " and no inventory matches it in this scope.")
                      (list "Verify the spec-id is correct (typo?)."
                            "Add a recipe that outputs this spec, or seed inventory.")
                      pinned))
      (else
       ;; Structural path exists. Try at-location relaxation; if it
       ;; yields a strictly better plan-kind, the demand is
       ;; over-specified.
       (let ((relaxed (try-relaxation ctx spec-id qty due at-loc depth kind)))
         (cond
           (relaxed
            (make-critique 'over-specified
                           "Pinning at-location blocks a better plan; relaxing it finds one."
                           (list (string-append
                                   "Consider un-pinning at-location "
                                   "(currently " (or at-loc "#f") ")."))
                           relaxed))
           ((tractable-kind? kind)
            (make-critique 'tractable
                           (string-append "Planner found a "
                                          (symbol->string kind) " plan.")
                           '()
                           pinned))
           (else
            ;; Recipe exists but planner can't currently satisfy (kind =
            ;; 'unmet or no plan-term): tractable in principle, not in
            ;; this world-state.
            (make-critique 'tractable
                           (string-append
                             "Recipe path exists for " spec-id
                             ", but the planner returned '"
                             (if kind (symbol->string kind) "nothing")
                             "' at current inventory/world state.")
                           (list "Structural feasibility confirmed; satisfaction awaits producer scheduling or inventory.")
                           pinned))))))))
