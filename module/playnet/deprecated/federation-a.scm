;;; federation-a.scm — Layer 1, Option A: ranked-alternatives stream
;;;
;;; Each scope hosts a ^ranked-leaf that returns K ranked alternatives
;;; as ref-mode federation-results (plan-ref + summary scalars/lists,
;;; no inline plan). The coordinator fans out a demand in parallel,
;;; collects via vow-all, and picks a combination — touching only
;;; scope/residual/coherence/plan-ref on each result. Full plan
;;; structure stays behind the plan-refs and is never materialized at
;;; the coordinator unless the eventual consumer asks.
;;;
;;; Message-size intuition (5 alts × 3 leaves × ~400 B summary):
;;;   ~6 KB per federation plan, vs ~37 KB if alts carried inline plans.
;;;   Bigger wins come with deeper recipe chains behind each plan-ref
;;;   because nothing in the hot path recurses into sub-plans.
;;;
;;; Coordinator strategy here is greedy-first-fit (doc calls it
;;; "ref-passing A"): walk leaves in list order, give each up to the
;;; remaining demand. Smarter combination search (backtracking over K^N
;;; alts for better coherence) is a drop-in replacement for
;;; combine-ranked-greedy and can land later without touching the
;;; leaf or transport code.
;;;
;;; Pairs with Option B (fragment-stream) — see future federation-b.scm.
;;; B wins on LoRa-class latency; A wins everywhere else (doc has the table).
;;;
;;; NOT Hoot-compatible — uses goblins (native Guile only).

(define-module (playnet deprecated federation-a)
  #:use-module (playnet deprecated federation-a leaf)
  #:use-module (playnet deprecated federation-a coordinator)
  #:use-module (playnet deprecated federation-a config)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (playnet deprecated planner)
  #:use-module (playnet deprecated vat-federation)
  #:re-export (
              ;; from (playnet deprecated federation-a config)
              <federation-a-config> federation-a-config-attenuate?
              federation-a-config-leaf-planner federation-a-config-max-leaf-results
              federation-a-config-max-steps federation-a-config-resilient?
              federation-a-config-weight-fn federation-a-config?
              make-federation-a-config
              ;; from (playnet deprecated federation-a coordinator)
              evaluate-state-a federate-planning federate-planning-resilient
              ;; from (playnet deprecated federation-a leaf)
              ^planning-leaf attenuate-plan-ref-in-result plan-for-leaf
              spawn-planning-leaf)
  #:export (;; Transport-demo tier (inventory leaves)
            ^ranked-leaf spawn-ranked-leaf
            federate-ranked federate-ranked-resilient
            combine-ranked-greedy
            ;; Real-planning tier
            ))


;; Real-planning tier fragments — loaded before the transport-demo
;; body so both tiers share the same module scope.


;;; ── ^ranked-leaf ─────────────────────────────────────────────────────
;;;
;;; Inventory-backed leaf that returns a 1-element ranked list. The
;;; "1 alternative" comes from the inventory being a single static
;;; offer — there's nothing to rank against. Real production leaves
;;; will wrap default-relational-leaf-planner (federation.scm) with
;;; cfg.plan-actor? = #t to emit K > 1 alternatives from actual
;;; relational search; the coordinator below doesn't care which leaf
;;; kind it's talking to, as long as propose-for-demand returns a
;;; list of ref-mode federation-results.
;;;
;;; attenuate?:  if #t, wrap each plan-ref in spawn-plan-facet before
;;;              returning. Coordinator only needs summary-tier methods,
;;;              so this is the safe default for untrusted peers. Local
;;;              vats can leave it #f and get raw refs for richer
;;;              downstream consumption.

(define (^ranked-leaf bcom scope-id inventory weight-fn attenuate?)
  (methods
    ((describe) scope-id)

    ((propose-for-demand demand)
     (let* ((spec  (car demand))
            (need  (cadr demand))
            (have  (or (assoc-ref inventory spec) 0))
            (alloc (min have need))
            (unmet (- need alloc))
            (plan  (if (> alloc 0)
                       `((produce ,spec #f ,alloc ()))
                       `((unmet ,spec ,unmet #f))))
            (plan-actor (spawn ^plan-actor plan scope-id weight-fn))
            (plan-ref (if attenuate? (spawn-plan-facet plan-actor) plan-actor)))
       (list
         `((scope . ,scope-id)
           (plan-ref . ,plan-ref)
           (deficits . ,(if (> unmet 0)
                            `(((scope-id . ,scope-id)
                               (spec-id  . ,spec)
                               (qty      . ,unmet)))
                            '()))
           (surpluses . ())
           (residual  . ,unmet)
           (coherence . ,(if (zero? need) 1 (/ alloc need)))))))))


(define* (spawn-ranked-leaf scope-id inventory
                            #:key (weight-fn #f) (attenuate? #f))
  "Spawn a ^ranked-leaf for SCOPE-ID backed by INVENTORY (alist of
   spec → qty). WEIGHT-FN feeds harmony; ATTENUATE? gates plan-refs
   through spawn-plan-facet so coordinators only see summary methods."
  (spawn ^ranked-leaf scope-id inventory weight-fn attenuate?))


;;; ── Coordinator ─────────────────────────────────────────────────────

(define (federate-ranked leaf-refs demand)
  "Fan out DEMAND = (spec qty) to LEAF-REFS in parallel. Each leaf
   returns a list of ranked ref-mode federation-results. Returns a vow
   of an aggregated federation-result produced by combine-ranked-greedy.

   Strict mode: if any leaf's propose-for-demand breaks, the whole
   federation breaks. Use federate-ranked-resilient otherwise."
  (let ((proposals (map (lambda (ref) (<- ref 'propose-for-demand demand))
                        leaf-refs)))
    (on (vow-all proposals)
        (lambda (per-leaf-lists)
          (combine-ranked-greedy per-leaf-lists demand))
        #:promise? #t)))


(define (federate-ranked-resilient leaf-refs demand)
  "Resilient variant: broken leaf vows become synthetic dead-peer
   proposals (empty ranked list with full-demand deficit) so the
   coordinator still produces a result. Wraps with on-sever for early
   diagnostic log output."
  (with-sever-handling
    leaf-refs
    (lambda (ref reason)
      (format (current-error-port)
              "[federation-a] peer severed: ~a (reason: ~a)~%" ref reason))
    (lambda ()
      (let ((proposals (map (lambda (ref)
                              (<- ref 'propose-for-demand demand))
                            leaf-refs)))
        (on (vow-allsettled proposals)
            (lambda (outcomes)
              (let ((per-leaf-lists
                      (map (lambda (outcome idx)
                             (if (eq? (car outcome) 'fulfilled)
                                 (cdr outcome)
                                 (list (dead-peer-result demand idx
                                                         (cdr outcome)))))
                           outcomes
                           (iota (length outcomes)))))
                (combine-ranked-greedy per-leaf-lists demand)))
            #:promise? #t)))))


(define (dead-peer-result demand idx reason)
  "Synthetic result for a leaf whose vow broke: plan-ref is #f so
   combine-ranked-greedy skips its allocation; the full demand qty
   becomes a scope-attributed deficit with the break reason attached."
  (let ((spec (car demand))
        (need (cadr demand))
        (sid  (string->symbol
                (string-append "dead-peer-" (number->string idx)))))
    `((scope     . ,sid)
      (plan-ref  . #f)
      (deficits  . (((scope-id . ,sid)
                     (spec-id  . ,spec)
                     (qty      . ,need)
                     (reason   . ,reason))))
      (surpluses . ())
      (residual  . ,need)
      (coherence . 0))))


;;; ── Greedy first-fit combiner ───────────────────────────────────────
;;;
;;; Touches only scope/residual/plan-ref/deficits/coherence on each
;;; leaf result — never plan-ref itself. Plan content stays behind
;;; the ref and is only pulled if a downstream consumer explicitly
;;; asks for it.

(define (combine-ranked-greedy per-leaf-lists demand)
  "Pick each leaf's rank-1 alternative, greedy-allocate against DEMAND,
   emit an aggregated federation-result that preserves the per-leaf
   plan-refs for downstream inspection."
  (let* ((spec (car demand))
         (need (cadr demand))
         (top-per-leaf (filter-map (lambda (lst)
                                     (and (pair? lst) (car lst)))
                                   per-leaf-lists))
         (final-allocs (greedy-allocate top-per-leaf spec need))
         (total-alloc  (fold + 0 (map (lambda (a) (assq-ref a 'alloc))
                                      final-allocs)))
         (residual     (max 0 (- need total-alloc)))
         (per-leaf-def (append-map (lambda (r)
                                     (or (assq-ref r 'deficits) '()))
                                   top-per-leaf)))
    `((scope       . federation-a)
      (demand      . ,demand)
      (allocations . ,final-allocs)
      (chosen-alternatives . ,top-per-leaf)
      (deficits    . ,(if (> residual 0)
                          (cons `((scope-id . federation-a)
                                  (spec-id  . ,spec)
                                  (qty      . ,residual))
                                per-leaf-def)
                          per-leaf-def))
      (surpluses   . ())
      (residual    . ,residual)
      (coherence   . ,(if (zero? need) 1 (/ total-alloc need))))))


(define (greedy-allocate top-per-leaf spec need)
  "Walk leaves in list order; give each up to its offered qty, capped
   by remaining demand. Returns list of ((scope . id) (spec . s)
   (alloc . qty) (plan-ref . ref)) alists."
  (let loop ((rs top-per-leaf) (remaining need) (out '()))
    (cond
      ((null? rs) (reverse out))
      (else
       (let* ((r (car rs))
              (leaf-resid (or (assq-ref r 'residual) need))
              (offered    (max 0 (- need leaf-resid)))
              (give       (min offered remaining)))
         (loop (cdr rs) (- remaining give)
               (cons `((scope    . ,(assq-ref r 'scope))
                       (spec     . ,spec)
                       (alloc    . ,give)
                       (plan-ref . ,(assq-ref r 'plan-ref)))
                     out)))))))
