;;; allocation.scm — Buffer-aware relational allocation via CLP(FD)
;;;
;;; Global sum constraint: each allocation declares a claim via claim-from-o.
;;; The constraint solver ensures sum(claims per resource) <= inventory.
;;; No sums threading — claims are stored in the N field of the cstate,
;;; backtracking-safe (restored with cstate on backtrack like FD and P).
;;;
;;; The conservation floor is TOR for buffered specs, 0 for unbuffered.
;;; Two conde branches: buffer-safe first, sacrifice second.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ── Claim registry helpers (stored in cstate N field) ────────────────────────
;;; N = alist: ((resource-id inv-qty take-var1 take-var2 ...) ...)

(define (ensure-claims-alist N)
  "Ensure N is a claims alist. If it's something else (e.g., netter-state), return '()."
  (if (and (list? N) (or (null? N) (pair? (car N)))) N '()))

(define (claims-ref N rid)
  "Look up claim entry for resource RID. Returns (inv-qty . take-vars) or #f."
  (let* ((claims (ensure-claims-alist N))
         (entry (assoc rid claims)))
    (if entry (cdr entry) #f)))

(define (claims-add N rid inv-qty take-var)
  "Add TAKE-VAR to the claim list for RID. Creates entry if needed."
  (let* ((claims (ensure-claims-alist N))
         (existing (assoc rid claims)))
    (if existing
        (cons (cons rid (cons (car (cdr existing))
                              (cons take-var (cddr existing))))
              (filter (lambda (e) (not (equal? (car e) rid))) claims))
        (cons (list rid inv-qty take-var) claims))))


;;; ── Conservation floor lookup ─────────────────────────────────────────────────

(define (conservation-floor facts spec-id)
  "TOR for buffered specs, 0 for unbuffered."
  (let ((bz (find (lambda (f)
                    (and (eq? (car f) 'buffer-zone)
                         (equal? (cadr f) spec-id)))
                  facts)))
    (if bz (caddr bz) 0)))


;;; ── sum-leq-for-resource — global constraint (follows distinctfd pattern) ────

(define (sum-leq-for-resource rid)
  "Global constraint: sum of all take vars for RID <= inv-qty.
   1. Walk all take vars — separate ground/unground
   2. Check: ground-sum <= inv-qty
   3. Narrow each unground var: hi <= budget - other-minimums
   4. Re-register propagator for remaining unground vars"
  (lambda (st)
    (let* ((S (cstate-S st))
           (FD (cstate-FD st))
           (N (cstate-N st))
           (entry (claims-ref N rid)))
      (if (not entry) (list st)
          (let* ((inv-qty (car entry))
                 (take-vars (cdr entry))
                 ;; Walk each take var
                 (walked (map (lambda (tv) (walk tv S)) take-vars))
                 ;; Separate ground from unground
                 (ground-vals (filter number? walked))
                 (unground (filter var? walked))
                 (ground-sum (apply + ground-vals)))
            ;; Check: ground sum must not exceed limit
            (if (> ground-sum inv-qty) '()
                (let ((budget (- inv-qty ground-sum)))
                  ;; Get minimums for each unground var
                  (let* ((unground-mins
                           (map (lambda (uv)
                                  (let ((dom (domain-ref FD uv)))
                                    (if dom (domain-lo dom) 0)))
                                unground))
                         (total-mins (apply + unground-mins)))
                    ;; Check: sum of minimums <= budget
                    (if (> total-mins budget) '()
                        ;; Narrow each var: hi <= budget - other-minimums
                        (let narrow ((uvs unground) (mins unground-mins) (st st))
                          (if (null? uvs)
                              ;; Re-register propagator if >1 unground remain
                              (if (< (length unground) 2)
                                  (list st)
                                  (list (register-propagator st unground
                                          (sum-leq-for-resource rid))))
                              (let* ((uv (car uvs))
                                     (my-min (car mins))
                                     (other-mins (- total-mins my-min))
                                     (my-max (- budget other-mins))
                                     (dom (domain-ref (cstate-FD st) uv)))
                                (if dom
                                    (let ((new-hi (min (domain-hi dom) my-max)))
                                      (if (< new-hi (domain-lo dom)) '()
                                          (if (= new-hi (domain-hi dom))
                                              ;; No change — continue
                                              (narrow (cdr uvs) (cdr mins) st)
                                              ;; Narrow domain
                                              (let ((result
                                                      ((infd uv (make-interval
                                                                  (domain-lo dom) new-hi))
                                                       st)))
                                                (if (null? result) '()
                                                    (narrow (cdr uvs) (cdr mins)
                                                            (car result)))))))
                                    (narrow (cdr uvs) (cdr mins) st))))))))))))))


;;; ── claim-from-o — declare a claim against a resource ────────────────────────

(define (claim-from-o rid inv-qty floor take)
  "Register a claim of TAKE units from resource RID.
   Constrains take to [0, available], registers in claim registry (N),
   and posts the global sum-leq constraint."
  (let ((available (max 0 (- inv-qty floor))))
    (lambda (st)
      (let* ((S (cstate-S st))
             (take-v (walk take S)))
        (if (var? take-v)
            ;; Unground: register in N, constrain, post sum-leq
            (let* ((new-N (claims-add (cstate-N st) rid inv-qty take-v))
                   (st* (cstate-with st 'N new-N)))
              (bind ((rangeo take 0 available) st*)
                    (sum-leq-for-resource rid)))
            ;; Ground: check feasibility, still register for global constraint
            (if (and (integer? take-v) (>= take-v 0) (<= take-v available))
                (let* ((new-N (claims-add (cstate-N st) rid inv-qty take-v))
                       (st* (cstate-with st 'N new-N)))
                  ((sum-leq-for-resource rid) st*))
                '()))))))


;;; ── allocate-o ────────────────────────────────────────────────────────────────

(define* (allocate-o facts spec-id qty remaining allocated
                      #:key (indexes #f) (at-location #f) (container-id #f))
  "Buffer-aware allocation. Each resource gets a claim-from-o constraint."
  (let* ((raw (if indexes
                  (filter (lambda (f) (> (cadddr f) 0))
                          (idx-ref indexes 'inventory-by-spec spec-id))
                  (filter (lambda (f)
                            (and (eq? (car f) 'inventory)
                                 (equal? (caddr f) spec-id)
                                 (> (cadddr f) 0)))
                          facts)))
         (by-location (if at-location
                          (filter (lambda (f) (equal? (list-ref f 4) at-location)) raw)
                          raw))
         (resources (if container-id
                        (filter (lambda (f) (equal? (list-ref f 5) container-id)) by-location)
                        (filter (lambda (f) (not (list-ref f 5))) by-location)))
         (floor (conservation-floor facts spec-id)))
    ;; Try buffer-safe allocation first, then unrestricted as fallback
    (conde
      ((allocate-from-o qty resources remaining allocated floor))
      ((allocate-from-o qty resources remaining allocated 0)))))


;;; ── allocate-from-o — pure goal, no walk* hack ──────────────────────────────

(define (allocate-from-o qty resources remaining allocated floor)
  "Post claim constraints per resource. Pure goal composition."
  (if (null? resources)
      (fresh ()
        (== remaining qty)
        (== allocated '()))
      (let* ((r (car resources))
             (rid (cadr r))
             (inv-qty (cadddr r))
             (available (max 0 (- inv-qty floor))))
        (fresh (take rest-remaining rest-alloc)
          ;; Constrain take to [0, min(available, qty)]
          (rangeo take 0 (min available qty))
          ;; Register the global sum constraint
          (claim-from-o rid inv-qty floor take)
          ;; remaining = qty - take
          (-fd qty take rest-remaining)
          ;; Label (max-first: try taking the most first)
          (labelfd take #:order 'max)
          ;; Recurse
          (allocate-from-o rest-remaining (cdr resources) remaining rest-alloc floor)
          ;; Build allocation list
          (project (take)
            (if (= take 0)
                (== allocated rest-alloc)
                (== allocated (cons (list rid take) rest-alloc))))))))
