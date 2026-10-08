;;; federation-solver.scm — Derive federation graph results from plans.
;;;
;;; Replaces the hand-authored `*fed-results*` alist with a pure
;;; computation over the actual sources of truth: each scope's onhand
;;; resources, its process commitments (the plan), its demand intents,
;;; and the federation-wide trade proposals. The federation graph
;;; therefore always reflects what the data actually implies — change
;;; a trade or a demand and surplus / deficit / fulfillment numbers
;;; update automatically.
;;;
;;; This is the "scope solver" in miniature. A real plan in playnet
;;; carries richer structure (multi-period horizons, alternative paths,
;;; etc.) — but the same shape of inputs and outputs applies. When the
;;; planner-service starts returning real plans, this module is the
;;; integration point: swap `commitments-of` and `demands-of` for the
;;; planner's plan-projection, and the graph follows.
;;;
;;; All functions are pure — data in, data out. No I/O, no actors.

(define-module (playnet ui federation-solver)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils alist)
  #:export (compute-scope-result
            compute-fed-results
            compute-fed-events))


;;; ── Tiny helpers ────────────────────────────────────────────────────

(define (alist-get alist key default)
  (let ((p (assoc key alist equal?)))
    (if p (cdr p) default)))

(define (group-sum xs key-fn val-fn)
  "Returns alist (key . total-val) summing VAL-FN over XS grouped by KEY-FN."
  (let loop ((xs xs) (acc '()))
    (cond
     ((null? xs) acc)
     (else
      (let* ((k (key-fn (car xs)))
             (v (val-fn (car xs)))
             (p (assoc k acc equal?)))
        (cond
         ((not k)   (loop (cdr xs) acc))
         (p         (set-cdr! p (+ (cdr p) v)) (loop (cdr xs) acc))
         (else      (loop (cdr xs) (cons (cons k v) acc)))))))))

(define (sum-where xs pred? val-fn)
  (fold + 0 (map val-fn (filter pred? xs))))


;;; ── Per-spec accounting from plan commitments + trades + onhand ─────

(define (produce? c) (eq? (alist-ref c 'action 'unknown) 'produce))   ; verb-meant: a display choice per action
(define (consume? c) (eq? (alist-ref c 'action 'unknown) 'consume))   ; verb-meant: a display choice per action
(define (work?    c) (eq? (alist-ref c 'action 'unknown) 'work))

(define (spec-of c)         (alist-ref c 'resource-conforms-to #f))
(define (qty-of  c)         (alist-ref c 'qty 0))
(define (onhand-spec r)     (alist-ref r 'conforms-to #f))
(define (onhand-qty r)      (alist-ref r 'onhand 0))
(define (trade-spec t)      (alist-ref t 'spec #f))
(define (trade-qty t)       (alist-ref t 'qty 0))

(define (produced-by-spec commitments)
  (group-sum (filter produce? commitments) spec-of qty-of))
(define (consumed-by-spec commitments)
  (group-sum (filter consume? commitments) spec-of qty-of))
(define (onhand-by-spec resources)
  (group-sum resources onhand-spec onhand-qty))
(define (inbound-by-spec trades scope-id)
  (group-sum (filter (lambda (t) (equal? (alist-ref t 'to)   scope-id)) trades)
             trade-spec trade-qty))
(define (outbound-by-spec trades scope-id)
  (group-sum (filter (lambda (t) (equal? (alist-ref t 'from) scope-id)) trades)
             trade-spec trade-qty))

(define (inbound-providers trades scope-id spec)
  "List of `from` scopes shipping SPEC to SCOPE-ID."
  (filter-map (lambda (t)
                (and (equal? (alist-ref t 'to)   scope-id)
                     (equal? (alist-ref t 'spec) spec)
                     (alist-ref t 'from)))
              trades))


;;; ── Per-scope solver ────────────────────────────────────────────────

(define (compute-scope-result scope-id demands resources commitments trades)
  "Derive a result alist for SCOPE-ID from its plan + onhand + trades.

   Returns an alist with:
     surplus-qty, deficit-count, total-orig, total-short, has-deficits,
     deficits (list of ((spec) (shortfall) (original) (resolved-at))),
     surplus  (list of ((spec) (qty))),
     demand-intents (echoed back so the UI has them in one place).

   Semantics:
   - Available stock per spec = onhand + produced + inbound-trades.
   - Local consumption needs come from CONSUME commitments.
   - Surplus = available − local-consumption − outbound-trades, if positive.
   - For each demand intent, shortfall is what's left over after
     onhand + inbound covers it (production for own use is already
     counted as supply to the local consume commitments)."
  (let* ((onhand     (onhand-by-spec resources))
         (produced   (produced-by-spec commitments))
         (consumed   (consumed-by-spec commitments))
         (inbound    (inbound-by-spec trades scope-id))
         (outbound   (outbound-by-spec trades scope-id))
         ;; A spec's free pool after the local plan and outbound trades.
         (avail-for-demand
          (lambda (spec)
            (+ (alist-get onhand  spec 0)
               (alist-get inbound spec 0))))
         (free-after-plan
          (lambda (spec)
            (- (+ (alist-get onhand   spec 0)
                  (alist-get produced spec 0))
               (alist-get consumed spec 0)
               (alist-get outbound spec 0))))
         ;; Per-demand shortfall row
         (deficits
          (map (lambda (d)
                 (let* ((spec   (alist-ref d 'spec ""))
                        (orig   (alist-ref d 'qty 0))
                        (avail  (avail-for-demand spec))
                        (short  (max 0 (- orig avail)))
                        (provs  (inbound-providers trades scope-id spec))
                        ;; Only mark "resolved-at" when inbound trades exist.
                        (resolved (if (null? provs) '() provs)))
                   `((spec . ,spec)
                     (shortfall . ,short)
                     (original . ,orig)
                     (resolved-at . ,resolved))))
               demands))
         ;; Surplus rows — every spec the scope ends the plan period with > 0.
         (all-specs
          (delete-duplicates
           (append (map car onhand) (map car produced))
           equal?))
         (surplus
          (filter-map
           (lambda (spec)
             (let ((free (free-after-plan spec)))
               (and (> free 0) `((spec . ,spec) (qty . ,free)))))
           all-specs))
         (open-deficits   (filter (lambda (d) (> (alist-ref d 'shortfall 0) 0))
                                  deficits))
         (deficit-count   (length open-deficits))
         (total-orig      (fold + 0 (map (lambda (d) (alist-ref d 'original 0))
                                         deficits)))
         (total-short     (fold + 0 (map (lambda (d) (alist-ref d 'shortfall 0))
                                         deficits)))
         (surplus-qty     (fold + 0 (map (lambda (s) (alist-ref s 'qty 0))
                                         surplus))))
    `((surplus-qty    . ,surplus-qty)
      (deficit-count  . ,deficit-count)
      (total-orig     . ,total-orig)
      (total-short    . ,total-short)
      (has-deficits   . ,(> deficit-count 0))
      (deficits       . ,deficits)
      (surplus        . ,surplus)
      (demand-intents . ,demands))))


;;; ── Federation-wide derivation ──────────────────────────────────────

(define (compute-fed-results scopes demands-by-scope resources-by-scope
                             commitments-by-scope trades)
  "Compute results for every scope. Returns alist (scope-id . result)."
  (filter-map
   (lambda (scope)
     (let* ((sid (alist-ref scope 'id #f))
            (parent (alist-ref scope 'parent #f)))
       ;; Skip federations (non-leaf scopes) — they don't have their
       ;; own demand/supply, they aggregate from children. The graph
       ;; still draws them; only leaf scopes get a result row.
       (cond
        ((or (not sid) (not parent)) #f)
        ;; Heuristic: a scope is a leaf if no other scope has it as a parent.
        ((any (lambda (s) (equal? (alist-ref s 'parent) sid)) scopes) #f)
        (else
         (let ((d (or (alist-get demands-by-scope     sid '()) '()))
               (r (or (alist-get resources-by-scope   sid '()) '()))
               (c (or (alist-get commitments-by-scope sid '()) '())))
           (cons sid (compute-scope-result sid d r c trades)))))))
   scopes))


;;; ── Event derivation ────────────────────────────────────────────────
;;;
;;; Events normally come from plan transitions (the planner's audit
;;; log). For the demo we derive a plausible projection from the
;;; computed results + trades so the event log still tells a story.

(define (compute-fed-events scopes results trades)
  "Synthesize a 3-round event log from derived results and trades:
     round 0 → scope-planned, deficit-announced, surplus-offered
     round 1 → lateral-match (within same parent federation)
     round 2 → cross-fed-match (across federations)."
  (let* ((leaf-results results)
         (parent-of
          (lambda (sid)
            (let ((s (find (lambda (s) (equal? (alist-ref s 'id) sid))
                           scopes)))
              (and s (alist-ref s 'parent)))))
         (planned
          (map (lambda (pair)
                 `((round . 0) (kind . scope-planned)
                   (scope-id . ,(car pair))))
               leaf-results))
         (deficit-events
          (append-map
           (lambda (pair)
             (let ((sid (car pair))
                   (res (cdr pair)))
               (map (lambda (d)
                      `((round . 0) (kind . deficit-announced)
                        (scope-id . ,sid)
                        (spec-id . ,(alist-ref d 'spec ""))
                        (qty . ,(alist-ref d 'original 0))))
                    (alist-ref res 'deficits '()))))
           leaf-results))
         (surplus-events
          (append-map
           (lambda (pair)
             (let ((sid (car pair))
                   (res (cdr pair)))
               (map (lambda (s)
                      `((round . 0) (kind . surplus-offered)
                        (scope-id . ,sid)
                        (spec-id . ,(alist-ref s 'spec ""))
                        (qty . ,(alist-ref s 'qty 0))))
                    (alist-ref res 'surplus '()))))
           leaf-results))
         (match-events
          (map (lambda (t)
                 (let* ((from (alist-ref t 'from))
                        (to   (alist-ref t 'to))
                        (same-fed? (equal? (parent-of from) (parent-of to)))
                        (kind (if same-fed? 'lateral-match 'cross-fed-match))
                        (round (if same-fed? 1 2)))
                   `((round . ,round) (kind . ,kind)
                     (scope-id . ,from) (target-scope-id . ,to)
                     (spec-id . ,(alist-ref t 'spec ""))
                     (qty . ,(alist-ref t 'qty 0)))))
               trades)))
    (append planned deficit-events surplus-events match-events)))
