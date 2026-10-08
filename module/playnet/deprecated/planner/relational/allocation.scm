;;; allocation.scm — Buffer-aware relational allocation via CLP(FD)
;;;
;;; Global sum constraint: each allocation declares a claim via claim-from-o.
;;; The constraint solver ensures sum(claims per resource) <= inventory.
;;; No sums threading — claims are stored in the N field of the cstate,
;;; backtracking-safe (restored with cstate on backtrack like FD and P).
;;;
;;; The conservation floor is TOR for buffered specs, 0 for unbuffered.
;;; Two conde branches: buffer-safe first, sacrifice second.

(define-module (playnet deprecated planner relational allocation)
  #:use-module (playnet deprecated planner relational planning-facts)
  #:export (claims-ref claims-add conservation-floor narrow-domain-hi sum-leq-check
            claim-from-o allocate-o allocate-with-floors allocate-from-o))

(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))


;;; ── Claim registry helpers (stored in cstate N field) ────────────────────────
;;; N = alist: ((resource-id inv-qty take-var1 take-var2 ...) ...)

(define (claims-ref N rid)
  "Look up claim entry for resource RID. Returns (inv-qty . take-vars) or #f."
  (if (not (pair? N)) #f
      (let ((entry (assoc rid N)))
        (if entry (cdr entry) #f))))

(define (claims-add N rid inv-qty take-var)
  "Add TAKE-VAR to the claim list for RID. Creates entry if needed."
  (let* ((claims (if (pair? N) N '()))
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


;;; ── sum-leq-check — immediate feasibility check (no propagators) ─────────────

(define (narrow-domain-hi st var new-hi)
  "Narrow VAR's domain upper bound to NEW-HI. Returns st or #f on failure."
  (let ((dom (domain-ref (cstate-FD st) var)))
    (if (not dom) st
        (cond
          ((< new-hi (domain-lo dom)) #f)
          ((= new-hi (domain-hi dom)) st)
          (else (let ((r ((infd var (make-interval (domain-lo dom) new-hi)) st)))
                  (if (null? r) #f (car r))))))))

(define (sum-leq-check rid)
  "Immediate check: sum of all take vars for RID <= inv-qty.
   Walks all take vars, checks ground sum, narrows unground domains.
   No propagator registration — runs once per claim, O(k) per call."
  (lambda (st)
    (let* ((entry (claims-ref (cstate-N st) rid)))
      (if (not entry) (list st)
          (let* ((inv-qty (car entry))
                 (walked (map (lambda (tv) (walk tv (cstate-S st))) (cdr entry)))
                 (ground-sum (apply + (filter number? walked)))
                 (unground (filter var? walked))
                 (budget (- inv-qty ground-sum)))
            (if (< budget 0) '()
                (if (null? unground) (list st)
                    (let* ((mins (map (lambda (uv)
                                        (let ((d (domain-ref (cstate-FD st) uv)))
                                          (if d (domain-lo d) 0)))
                                      unground))
                           (total-mins (apply + mins)))
                      (if (> total-mins budget) '()
                          (let narrow ((uvs unground) (ms mins) (st st))
                            (if (null? uvs) (list st)
                                (let ((st* (narrow-domain-hi st (car uvs)
                                             (- budget (- total-mins (car ms))))))
                                  (if (not st*) '()
                                      (narrow (cdr uvs) (cdr ms) st*))))))))))))))


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
                    (sum-leq-check rid)))
            ;; Ground: check feasibility, still register for global constraint
            (if (and (integer? take-v) (>= take-v 0) (<= take-v available))
                (let* ((new-N (claims-add (cstate-N st) rid inv-qty take-v))
                       (st* (cstate-with st 'N new-N)))
                  ((sum-leq-check rid) st*))
                '()))))))


;;; ── allocate-o ────────────────────────────────────────────────────────────────

(define* (allocate-o facts spec-id qty remaining allocated
                      #:key (indexes #f) (at-location #f) (container-id #f)
                            (floors #f))
  "Buffer-aware allocation. Each resource gets a claim-from-o constraint.

   FLOORS is an optional list of conservation-floor values; one conde
   branch is generated per floor (highest first). Default (#f) gives
   the legacy 2-tier behavior: try TOR floor first, then sacrifice
   (floor=0). Pass an explicit list — e.g. '(toy tor 0) — for richer
   tier strategies like DDMRP."
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
         (effective-floors
           (or floors
               ;; Default: legacy 2-tier (TOR floor → sacrifice)
               (list (conservation-floor facts spec-id) 0))))
    (allocate-with-floors qty resources remaining allocated effective-floors)))

(define (allocate-with-floors qty resources remaining allocated floors)
  "Build a conde branching one allocate-from-o call per floor in FLOORS."
  (cond
    ((null? floors) fail)
    ((null? (cdr floors))
     (allocate-from-o qty resources remaining allocated (car floors)))
    (else
     (conde
       ((allocate-from-o qty resources remaining allocated (car floors)))
       ((allocate-with-floors qty resources remaining allocated (cdr floors)))))))


;;; ── allocate-from-o — pure goal, no walk* hack ──────────────────────────────

(define (allocate-from-o qty resources remaining allocated floor)
  "Post claim constraints per resource. Pure goal composition.

   Note: take's upper bound is constrained via two FD constraints
   (rangeo to AVAILABLE, plus <=fd against qty) instead of a single
   Scheme (min available qty). This matters when QTY is a logic
   variable rather than a ground integer — which happens on the
   recursive call where qty=rest-remaining (a domain var produced
   by -fd from the previous resource). Without the FD-only path,
   multi-resource allocation throws a wrong-type error in min."
  (if (null? resources)
      (fresh ()
        (== remaining qty)
        (== allocated '()))
      (let* ((r (car resources))
             (rid (cadr r))
             (inv-qty (cadddr r))
             (available (max 0 (- inv-qty floor))))
        (fresh (take rest-remaining rest-alloc)
          ;; Constrain take to [0, available] AND take <= qty (FD).
          (rangeo take 0 available)
          (<=fd take qty)
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
