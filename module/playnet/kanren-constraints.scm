;;; kanren-constraints.scm — miniKanren with symbolic constraints + CLP(FD) + netter
;;;
;;; Extends (playnet kanren-planning) with:
;;;   =/=      — disequality (these must NOT unify)
;;;   numbero  — type constraint (must be a number)
;;;   symbolo  — type constraint (must be a symbol)
;;;   absento  — structural absence (u must not appear in v)
;;;   infd     — finite domain (variable must be in given set/range)
;;;   +fd      — relational addition over finite domains
;;;   -fd      — relational subtraction over finite domains
;;;   *fd      — relational multiplication over finite domains
;;;   <fd      — relational less-than
;;;   <=fd     — relational less-than-or-equal
;;;   distinctfd — all variables must have different values
;;;   rangeo   — shorthand for (infd x (range lo hi))
;;;   labelfd  — enumerate domain values for a variable
;;;
;;; State = #(S C N D Y Nu T FD) — vector, 8 slots.
;;; Drop-in replacement: same API as kanren-planning + constraints + CLP(FD).
;;;
;;; CLP(FD) uses domain propagation (arc consistency), not Peano encoding.
;;; Inspired by cKanren (Alvis, Willcock, Carter, Byrd, Friedman) and
;;; miniKanren-with-symbolic-constraints (Hemann, Byrd, Friedman).

(define-module (playnet kanren-constraints)
  #:use-module ((playnet kanren) #:select (var var? var=? empty-subst walk walk* unify unify-diff intmap-ref intmap-set unbound? appendo membero))
  #:use-module ((playnet kanren-planning) #:select (make-plan-ctx plan-ctx? ctx-facts ctx-ps ctx-obs ctx-ls ctx-plan-id ctx-indexes))
  #:use-module ((srfi srfi-1) #:select (any filter append-map fold delete-duplicates iota last))
  #:use-module (srfi srfi-9)
  #:re-export (var var? var=?
               empty-subst
               walk walk*
               unify
               appendo membero
               make-plan-ctx plan-ctx?
               ctx-facts ctx-ps ctx-obs ctx-ls ctx-plan-id ctx-indexes)
  #:export (;; State
            make-cstate empty-cstate
            cstate-S cstate-C cstate-N cstate-D cstate-Y cstate-Nu cstate-T cstate-FD
            ;; Core forms
            == succeed fail
            call/fresh fresh conde
            disj conj
            Zzz conj+ disj+
            ;; Run
            run-plan run-plan*
            ;; Projection + list
            project in-list-o
            ;; Symbolic constraints
            =/= numbero symbolo absento
            ;; CLP(FD)
            infd rangeo +fd -fd *fd <fd <=fd distinctfd labelfd
            ;; Extra relations
            lasto))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; State: #(S C N D Y Nu T FD P)
;;; P = propagator queue: list of (trigger-vars . goal) pairs.
;;; When == or labelfd grounds a trigger variable, the goal re-fires.
;;; ══════════════════════════════════════════════════════════════════════════════

(define (make-cstate S C N D Y Nu T FD P)
  (vector S C N D Y Nu T FD P))

(define (cstate-S st)  (vector-ref st 0))
(define (cstate-C st)  (vector-ref st 1))
(define (cstate-N st)  (vector-ref st 2))
(define (cstate-D st)  (vector-ref st 3))
(define (cstate-Y st)  (vector-ref st 4))
(define (cstate-Nu st) (vector-ref st 5))
(define (cstate-T st)  (vector-ref st 6))
(define (cstate-FD st) (vector-ref st 7))
(define (cstate-P st)  (vector-ref st 8))

(define (cstate-with st . updates)
  "Functional update: (cstate-with st 'S new-s 'FD new-fd 'P new-p)"
  (let ((v (make-vector 9)))
    (let copy ((i 0))
      (when (< i 9) (vector-set! v i (vector-ref st i)) (copy (+ i 1))))
    (let loop ((u updates))
      (if (null? u) v
          (begin
            (vector-set! v (slot-index (car u)) (cadr u))
            (loop (cddr u)))))))

(define (slot-index sym)
  (cond ((eq? sym 'S) 0) ((eq? sym 'C) 1) ((eq? sym 'N) 2)
        ((eq? sym 'D) 3) ((eq? sym 'Y) 4) ((eq? sym 'Nu) 5)
        ((eq? sym 'T) 6) ((eq? sym 'FD) 7) ((eq? sym 'P) 8)))

(define (empty-cstate ns)
  (make-cstate empty-subst 0 ns '() '() '() '() '() '()))

(define (register-propagator st trigger-vars goal)
  "Register GOAL to re-fire when any variable in TRIGGER-VARS becomes ground."
  (cstate-with st 'P (cons (cons trigger-vars goal) (cstate-P st))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Finite domain representation — interval-first
;;; ══════════════════════════════════════════════════════════════════════════════
;;; FD = alist of (var . domain) pairs.
;;; Domain = <interval> (lo . hi) for contiguous ranges (O(1) operations)
;;;        | sorted list of integers for non-contiguous domains (after =/= gaps)
;;; Most planning domains are contiguous (rangeo creates intervals).

(define-record-type <interval>
  (make-interval lo hi)
  interval?
  (lo interval-lo)
  (hi interval-hi))

(define (domain-ref FD x)
  "O(log n) domain lookup by var counter."
  (let ((val (intmap-ref FD (cadr x))))
    (if (unbound? val) #f val)))

(define (domain-set FD x dom)
  "O(log n) domain store by var counter."
  (intmap-set FD (cadr x) dom))

(define (domain-size dom)
  "Number of values in domain. O(1) for intervals."
  (if (interval? dom)
      (+ 1 (- (interval-hi dom) (interval-lo dom)))
      (length dom)))

(define (domain-lo dom)
  (if (interval? dom) (interval-lo dom) (car dom)))

(define (domain-hi dom)
  (if (interval? dom) (interval-hi dom) (last dom)))

(define (domain-contains? dom val)
  "O(1) for intervals, O(n) for lists."
  (if (interval? dom)
      (and (integer? val) (>= val (interval-lo dom)) (<= val (interval-hi dom)))
      (and (memv val dom) #t)))

(define (domain-intersect d1 d2)
  "Intersect two domains. O(1) for two intervals."
  (cond
    ((and (interval? d1) (interval? d2))
     (let ((lo (max (interval-lo d1) (interval-lo d2)))
           (hi (min (interval-hi d1) (interval-hi d2))))
       (if (> lo hi) #f (make-interval lo hi))))
    ;; Interval + list: filter list by interval bounds
    ((and (interval? d1) (pair? d2))
     (let ((result (filter (lambda (v) (domain-contains? d1 v)) d2)))
       (if (null? result) #f result)))
    ((and (pair? d1) (interval? d2))
     (let ((result (filter (lambda (v) (domain-contains? d2 v)) d1)))
       (if (null? result) #f result)))
    ;; Two lists: sorted intersection
    ((and (pair? d1) (pair? d2))
     (let loop ((a d1) (b d2) (acc '()))
       (cond
         ((or (null? a) (null? b)) (let ((r (reverse acc))) (if (null? r) #f r)))
         ((= (car a) (car b)) (loop (cdr a) (cdr b) (cons (car a) acc)))
         ((< (car a) (car b)) (loop (cdr a) b acc))
         (else (loop a (cdr b) acc)))))
    (else #f)))

(define (domain->list dom)
  "Convert domain to explicit list (for triple enumeration fallback)."
  (if (interval? dom)
      (iota (+ 1 (- (interval-hi dom) (interval-lo dom))) (interval-lo dom))
      dom))

(define (make-range lo hi)
  "O(1) interval creation."
  (make-interval lo hi))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Symbolic constraint checks (from previous version)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (ground-non-symbol? u S)
  (let ((u (walk u S))) (and (not (var? u)) (not (symbol? u)))))

(define (ground-non-number? u S)
  (let ((u (walk u S))) (and (not (var? u)) (not (number? u)))))

(define (same-var? u)
  (lambda (v) (and (var? u) (var? v) (var=? u v))))

(define (mem-check u t S)
  (let ((t (walk t S)))
    (cond
      ((pair? t) (or (term=? u t S) (mem-check u (car t) S) (mem-check u (cdr t) S)))
      (else (term=? u t S)))))

(define (term=? u t S)
  (let ((S0 (unify u t S))) (and S0 (eq? S0 S))))

(define (unify* pairs S)
  (if (null? pairs) S
      (let ((S+ (unify (caar pairs) (cdar pairs) S)))
        (and S+ (unify* (cdr pairs) S+)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; FD constraint check — called after every ==
;;; ══════════════════════════════════════════════════════════════════════════════

(define (fd-fail-check S FD)
  "Check if any FD-constrained variable is now ground but outside its domain."
  (any (lambda (vd)
         (let ((v (walk (car vd) S))
               (dom (cdr vd)))
           (and (not (var? v))           ;; variable is now ground
                (or (not (integer? v))   ;; must be integer
                    (not (domain-contains? dom v))))))  ;; must be in domain
       FD))

(define (fd-narrow-after-unify S FD)
  "After unification, narrow domains and return updated (S . FD) or #f on failure."
  (let loop ((fd FD) (S S) (new-fd '()))
    (if (null? fd)
        (cons S new-fd)
        (let* ((x (caar fd))
               (dom (cdar fd))
               (v (walk x S)))
          (cond
            ;; Variable is now ground — check it's in domain
            ((not (var? v))
             (if (and (integer? v) (domain-contains? dom v))
                 (loop (cdr fd) S new-fd)  ;; satisfied, drop constraint
                 #f))  ;; fail
            ;; Variable unified with another variable — merge domains
            ((and (var? v) (not (var=? v x)))
             (let ((other-dom (domain-ref FD v)))
               (if other-dom
                   (let ((merged (domain-intersect dom other-dom)))
                     (if (not merged) #f
                         (if (= (domain-size merged) 1)
                             ;; Singleton — bind the variable
                             (let ((S+ (unify v (domain-lo merged) S)))
                               (if S+ (loop (cdr fd) S+ new-fd)
                                   #f))
                             (loop (cdr fd) S (domain-set new-fd v merged)))))
                   ;; Other var has no domain — transfer this domain to it
                   (loop (cdr fd) S (domain-set new-fd v dom)))))
            ;; Variable still free with domain — keep constraint
            (else
             (if (= (domain-size dom) 1)
                 ;; Singleton — bind
                 (let ((S+ (unify v (domain-lo dom) S)))
                   (if S+ (loop (cdr fd) S+ new-fd) #f))
                 (loop (cdr fd) S (cons (cons v dom) new-fd)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Combined fail check
;;; ══════════════════════════════════════════════════════════════════════════════

(define (==fail-check S0 D Y Nu T FD)
  (or (any (lambda (y) (ground-non-symbol? y S0)) Y)
      (any (lambda (n) (ground-non-number? n S0)) Nu)
      (let ((walked-Nu (map (lambda (n) (walk n S0)) Nu)))
        (any (lambda (y) (any (same-var? (walk y S0)) walked-Nu)) Y))
      (any (lambda (d) (let ((S+ (unify* d S0))) (and S+ (eq? S+ S0)))) D)
      (any (lambda (t) (mem-check (car t) (cdr t) S0)) T)
      (fd-fail-check S0 FD)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Core goals
;;; ══════════════════════════════════════════════════════════════════════════════

(define (== u v)
  (lambda (st)
    (let ((old-S (cstate-S st))
          (S0 (unify u v (cstate-S st))))
      (if (not S0) '()
          (let ((result (fd-narrow-after-unify S0 (cstate-FD st))))
            (if (not result) '()
                (let ((S* (car result))
                      (FD* (cdr result)))
                  (if (==fail-check S* (cstate-D st) (cstate-Y st)
                                    (cstate-Nu st) (cstate-T st) FD*)
                      '()
                      ;; Fire propagators for newly-ground variables
                      (fire-propagators
                        (cstate-with st 'S S* 'FD FD*)
                        old-S)))))))))

(define (fire-propagators st old-S)
  "Fire propagators whose trigger variables became ground since old-S."
  (let* ((S (cstate-S st))
         (P (cstate-P st))
         ;; Split: propagators to fire vs keep
         (to-fire (filter (lambda (p)
                            (any (lambda (v)
                                   (and (var? (walk v old-S))
                                        (not (var? (walk v S)))))
                                 (car p)))
                          P))
         (to-keep (filter (lambda (p) (not (memq p to-fire))) P))
         (st* (cstate-with st 'P to-keep)))
    (if (null? to-fire)
        (list st*)
        ;; Chain fired propagator goals via bind
        (let chain ((goals (map cdr to-fire)) (stream (list st*)))
          (if (null? goals) stream
              (chain (cdr goals) (bind stream (car goals))))))))

(define (succeed st) (list st))
(define (fail st) '())


;;; ── Symbolic constraints ──────────────────────────────────────────────────────

(define (=/= u v)
  (lambda (st)
    (let* ((S (cstate-S st))
           (result (unify-diff u v S)))
      (cond
        ((not result) (list st))          ;; can't unify → constraint satisfied
        ((null? (cdr result)) '())        ;; already equal → violated
        (else (list (cstate-with st 'D (cons (cdr result) (cstate-D st)))))))))

(define (numbero u)
  (lambda (st)
    (let ((S (cstate-S st)))
      (cond
        ((ground-non-number? u S) '())
        ((mem-check u (cstate-Y st) S) '())
        (else (list (cstate-with st 'Nu (cons u (cstate-Nu st)))))))))

(define (symbolo u)
  (lambda (st)
    (let ((S (cstate-S st)))
      (cond
        ((ground-non-symbol? u S) '())
        ((mem-check u (cstate-Nu st) S) '())
        (else (list (cstate-with st 'Y (cons u (cstate-Y st)))))))))

(define (absento u v)
  (lambda (st)
    (let ((S (cstate-S st)))
      (cond
        ((mem-check u v S) '())
        (else (list (cstate-with st 'T (cons (cons u v) (cstate-T st)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; CLP(FD) goals
;;; ══════════════════════════════════════════════════════════════════════════════

(define (infd x dom-or-vals)
  "Constrain x to DOM-OR-VALS (an <interval> or a list of integers).
   If x is ground, check membership. If x has a domain, intersect."
  (lambda (st)
    (let* ((S (cstate-S st))
           (FD (cstate-FD st))
           (v (walk x S))
           (new-dom (if (interval? dom-or-vals) dom-or-vals
                        (let ((sorted (sort (delete-duplicates dom-or-vals) <)))
                          (if (null? sorted) #f sorted)))))
      (if (not new-dom) '()  ;; empty domain
          (cond
            ;; Ground — check membership
            ((not (var? v))
             (if (domain-contains? new-dom v) (list st) '()))
            ;; Has existing domain — intersect
            ((domain-ref FD v)
             => (lambda (existing)
                  (let ((narrowed (domain-intersect existing new-dom)))
                    (cond
                      ((not narrowed) '())  ;; empty intersection
                      ((= (domain-size narrowed) 1)
                       ((== v (domain-lo narrowed)) st))
                      (else
                       (list (cstate-with st 'FD (domain-set FD v narrowed))))))))
            ;; No existing domain
            (else
             (cond
               ((= (domain-size new-dom) 1)
                ((== v (domain-lo new-dom)) st))
               (else
                (list (cstate-with st 'FD (domain-set FD v new-dom)))))))))))

(define (rangeo x lo hi)
  "O(1): constrain x to integers in [lo, hi]."
  (infd x (make-interval lo hi)))

(define (+fd x y z)
  "x + y = z, over finite domains. All three can be partially or fully ground."
  (lambda (st)
    (let* ((S (cstate-S st))
           (xv (walk x S)) (yv (walk y S)) (zv (walk z S)))
      (cond
        ;; All ground — just check
        ((and (number? xv) (number? yv) (number? zv))
         (if (= (+ xv yv) zv) (list st) '()))
        ;; Two ground, compute third
        ((and (number? xv) (number? yv))
         ((== z (+ xv yv)) st))
        ((and (number? xv) (number? zv))
         ((== y (- zv xv)) st))
        ((and (number? yv) (number? zv))
         ((== x (- zv yv)) st))
        ;; One or zero ground — propagate via interval arithmetic
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (make-interval xv xv)
                        (and (var? xv) (domain-ref FD xv))))
                (yd (if (number? yv) (make-interval yv yv)
                        (and (var? yv) (domain-ref FD yv))))
                (zd (if (number? zv) (make-interval zv zv)
                        (and (var? zv) (domain-ref FD zv)))))
           (if (and xd yd zd)
               ;; All have domains — interval propagation O(1)
               (let* ((x-lo (domain-lo xd)) (x-hi (domain-hi xd))
                      (y-lo (domain-lo yd)) (y-hi (domain-hi yd))
                      (z-lo (domain-lo zd)) (z-hi (domain-hi zd))
                      ;; Narrow: z ∈ [x-lo+y-lo, x-hi+y-hi] ∩ zd
                      (new-z-lo (max z-lo (+ x-lo y-lo)))
                      (new-z-hi (min z-hi (+ x-hi y-hi)))
                      ;; Narrow: x ∈ [z-lo-y-hi, z-hi-y-lo] ∩ xd
                      (new-x-lo (max x-lo (- new-z-lo y-hi)))
                      (new-x-hi (min x-hi (- new-z-hi y-lo)))
                      ;; Narrow: y ∈ [z-lo-x-hi, z-hi-x-lo] ∩ yd
                      (new-y-lo (max y-lo (- new-z-lo new-x-hi)))
                      (new-y-hi (min y-hi (- new-z-hi new-x-lo))))
                 (if (or (> new-x-lo new-x-hi) (> new-y-lo new-y-hi) (> new-z-lo new-z-hi))
                     '()  ;; empty domain → fail
                     ;; Narrow domains, then re-register propagator if vars remain
                     ((conj (maybe-narrow-interval x xv new-x-lo new-x-hi)
                            (conj (maybe-narrow-interval y yv new-y-lo new-y-hi)
                                  (conj (maybe-narrow-interval z zv new-z-lo new-z-hi)
                                        (lambda (st2)
                                          (let ((unground (filter (lambda (v) (var? (walk v (cstate-S st2))))
                                                                  (list x y z))))
                                            (if (null? unground) (list st2)
                                                (list (register-propagator st2 unground (+fd x y z)))))))))
                      st)))
               ;; Not enough domain info — register propagator
               (let ((unground (filter var? (list xv yv zv))))
                 (list (register-propagator st unground (+fd x y z)))))))))))

(define (maybe-narrow-interval x xv lo hi)
  "Narrow x to [lo,hi]. If already ground, check. If singleton, bind."
  (cond
    ((number? xv)
     (if (and (>= xv lo) (<= xv hi)) succeed fail))
    ((= lo hi) (== x lo))
    (else (infd x (make-interval lo hi)))))

(define (-fd x y z)
  "x - y = z. Equivalent to z + y = x."
  (+fd z y x))

(define (*fd x y z)
  "x * y = z, over finite domains."
  (lambda (st)
    (let* ((S (cstate-S st))
           (xv (walk x S)) (yv (walk y S)) (zv (walk z S)))
      (cond
        ((and (number? xv) (number? yv) (number? zv))
         (if (= (* xv yv) zv) (list st) '()))
        ((and (number? xv) (number? yv))
         ((== z (* xv yv)) st))
        ((and (number? xv) (number? zv) (not (zero? xv)) (zero? (remainder zv xv)))
         ((== y (quotient zv xv)) st))
        ((and (number? yv) (number? zv) (not (zero? yv)) (zero? (remainder zv yv)))
         ((== x (quotient zv yv)) st))
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (make-interval xv xv)
                        (and (var? xv) (domain-ref FD xv))))
                (yd (if (number? yv) (make-interval yv yv)
                        (and (var? yv) (domain-ref FD yv))))
                (zd (if (number? zv) (make-interval zv zv)
                        (and (var? zv) (domain-ref FD zv)))))
           (if (and xd yd zd)
               ;; Interval multiplication bounds
               (let* ((x-lo (domain-lo xd)) (x-hi (domain-hi xd))
                      (y-lo (domain-lo yd)) (y-hi (domain-hi yd))
                      (z-lo (domain-lo zd)) (z-hi (domain-hi zd))
                      (products (list (* x-lo y-lo) (* x-lo y-hi)
                                      (* x-hi y-lo) (* x-hi y-hi)))
                      (p-lo (apply min products)) (p-hi (apply max products))
                      (new-z-lo (max z-lo p-lo))
                      (new-z-hi (min z-hi p-hi)))
                 (if (> new-z-lo new-z-hi) '()
                     ;; Narrow z, then re-register propagator if vars remain
                     ((conj (maybe-narrow-interval z zv new-z-lo new-z-hi)
                            (lambda (st2)
                              (let ((unground (filter (lambda (v) (var? (walk v (cstate-S st2))))
                                                      (list x y z))))
                                (if (null? unground) (list st2)
                                    (list (register-propagator st2 unground (*fd x y z)))))))
                      st)))
               (let ((unground (filter var? (list xv yv zv))))
                 (list (register-propagator st unground (*fd x y z)))))))))))

(define (<fd x y)
  "x < y. O(1) with interval domains."
  (lambda (st)
    (let* ((S (cstate-S st))
           (xv (walk x S)) (yv (walk y S)))
      (cond
        ((and (number? xv) (number? yv))
         (if (< xv yv) (list st) '()))
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (make-interval xv xv)
                        (and (var? xv) (domain-ref FD xv))))
                (yd (if (number? yv) (make-interval yv yv)
                        (and (var? yv) (domain-ref FD yv)))))
           (if (and xd yd)
               (let* ((new-x-hi (min (domain-hi xd) (- (domain-hi yd) 1)))
                      (new-y-lo (max (domain-lo yd) (+ (domain-lo xd) 1)))
                      (new-x-lo (domain-lo xd))
                      (new-y-hi (domain-hi yd)))
                 (if (or (> new-x-lo new-x-hi) (> new-y-lo new-y-hi)) '()
                     ((conj (maybe-narrow-interval x xv new-x-lo new-x-hi)
                            (maybe-narrow-interval y yv new-y-lo new-y-hi))
                      st)))
               (let ((unground (filter var? (list xv yv))))
                 (list (register-propagator st unground (<fd x y)))))))))))

(define (<=fd x y)
  "x <= y. O(1) with interval domains."
  (lambda (st)
    (let* ((S (cstate-S st))
           (xv (walk x S)) (yv (walk y S)))
      (cond
        ((and (number? xv) (number? yv))
         (if (<= xv yv) (list st) '()))
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (make-interval xv xv)
                        (and (var? xv) (domain-ref FD xv))))
                (yd (if (number? yv) (make-interval yv yv)
                        (and (var? yv) (domain-ref FD yv)))))
           (if (and xd yd)
               (let* ((new-x-hi (min (domain-hi xd) (domain-hi yd)))
                      (new-y-lo (max (domain-lo yd) (domain-lo xd)))
                      (new-x-lo (domain-lo xd))
                      (new-y-hi (domain-hi yd)))
                 (if (or (> new-x-lo new-x-hi) (> new-y-lo new-y-hi)) '()
                     ((conj (maybe-narrow-interval x xv new-x-lo new-x-hi)
                            (maybe-narrow-interval y yv new-y-lo new-y-hi))
                      st)))
               (let ((unground (filter var? (list xv yv))))
                 (list (register-propagator st unground (<=fd x y)))))))))))

(define (distinctfd . vars)
  "All variables must take different values."
  (lambda (st)
    (let loop ((vs vars) (st st))
      (if (or (null? vs) (null? (cdr vs)))
          (list st)
          (let inner ((rest (cdr vs)) (st st))
            (if (null? rest)
                (loop (cdr vs) st)
                (let ((result ((=/= (car vs) (car rest)) st)))
                  (if (null? result) '()
                      (inner (cdr rest) (car result))))))))))

(define* (labelfd x #:key (order 'min))
  "Enumerate all values in x's domain. Triggers search.
   ORDER: 'min (default, smallest first) or 'max (largest first).
   NOTE: 'max is useful for allocation (try taking the most first)."
  (lambda (st)
    (let* ((S (cstate-S st))
           (v (walk x S)))
      (cond
        ((not (var? v)) (list st))  ;; already ground
        (else
         (let* ((dom (domain-ref (cstate-FD st) v))
                (vals (if (not dom) #f
                          (let ((lst (domain->list dom)))
                            (if (eq? order 'max) (reverse lst) lst)))))
           (if (not vals) (list st)  ;; no domain constraint
               (let try ((vs vals))
                 (if (null? vs) '()
                     (mplus ((== x (car vs)) st)
                            (lambda () (try (cdr vs)))))))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Stream operations + combinators + macros (unchanged from symbolic version)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (mplus $1 $2)
  (cond
   ((null? $1) $2)
   ((procedure? $1) (lambda () (mplus $2 ($1))))
   (else (cons (car $1) (mplus (cdr $1) $2)))))

(define (bind $ goal)
  (cond
   ((null? $) '())
   ((procedure? $) (lambda () (bind ($) goal)))
   (else (mplus (goal (car $)) (bind (cdr $) goal)))))

(define (disj g1 g2) (lambda (st) (mplus (g1 st) (g2 st))))
(define (conj g1 g2) (lambda (st) (bind (g1 st) g2)))

(define (call/fresh f)
  (lambda (st)
    (let ((c (cstate-C st)))
      ((f (var c)) (cstate-with st 'C (+ c 1))))))

(define-syntax Zzz
  (syntax-rules ()
    ((_ g) (lambda (st) (lambda () (g st))))))

(define-syntax conj+
  (syntax-rules ()
    ((_ g) (Zzz g))
    ((_ g0 g ...) (conj (Zzz g0) (conj+ g ...)))))

(define-syntax disj+
  (syntax-rules ()
    ((_ g) (Zzz g))
    ((_ g0 g ...) (disj (Zzz g0) (disj+ g ...)))))

(define-syntax fresh
  (syntax-rules ()
    ((_ () g0 g ...) (conj+ g0 g ...))
    ((_ (x0 x ...) g0 g ...)
     (call/fresh (lambda (x0) (fresh (x ...) g0 g ...))))))

(define-syntax conde
  (syntax-rules ()
    ((_ (g0 g ...) ...)
     (disj+ (conj+ g0 g ...) ...))))

(define-syntax project
  (syntax-rules ()
    ((_ (x ...) g g* ...)
     (lambda (st)
       (let ((x (walk* x (cstate-S st))) ...)
         ((fresh () g g* ...) st))))))

(define (in-list-o x lst)
  (if (null? lst) fail
      (conde
       ((== x (car lst)))
       ((in-list-o x (cdr lst))))))


;;; ── Extra relations ────────────────────────────────────────────────────────────

(define (lasto lst last)
  "Relate LST to its LAST element."
  (conde
    ((fresh (x) (== lst (list x)) (== last x)))
    ((fresh (h t) (== lst (cons h t)) (lasto t last)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Constraint simplification
;;; ══════════════════════════════════════════════════════════════════════════════

(define (simplify-constraints st)
  (let* ((S (cstate-S st))
         (D* (filter (lambda (d) (let ((S+ (unify* d S))) (and S+ (not (eq? S+ S)))))
                     (cstate-D st)))
         (Y* (filter (lambda (y) (let ((v (walk y S))) (or (var? v) (not (symbol? v)))))
                     (cstate-Y st)))
         (Nu* (filter (lambda (n) (let ((v (walk n S))) (or (var? v) (not (number? v)))))
                      (cstate-Nu st)))
         (T* (filter (lambda (t)
                       (let ((u (walk* (car t) S)) (v (walk* (cdr t) S)))
                         (or (var? u) (var? v) (mem-check u v S))))
                     (cstate-T st)))
         ;; Drop FD entries for ground variables
         (FD* (filter (lambda (p) (var? (walk (car p) S))) (cstate-FD st))))
    (make-cstate S (cstate-C st) (cstate-N st) D* Y* Nu* T* FD* (cstate-P st))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Reification
;;; ══════════════════════════════════════════════════════════════════════════════

(define (reify-name n)
  (string->symbol (string-append "_." (number->string n))))

(define (reify-1st st)
  (let* ((st (simplify-constraints st))
         (S (cstate-S st))
         (v (walk* (var 0) S))
         (R (car (reify-s v empty-subst 0)))
         (v (walk* v R))
         (D (walk* (cstate-D st) S))
         (Y (walk* (cstate-Y st) S))
         (Nu (walk* (cstate-Nu st) S))
         (T (walk* (cstate-T st) S))
         (FD (map (lambda (p) (cons (walk* (car p) S) (cdr p))) (cstate-FD st)))
         (D* (filter (lambda (d) (anyvar? d R)) D))
         (Y* (filter (lambda (y) (var? (walk y R))) Y))
         (Nu* (filter (lambda (n) (var? (walk n R))) Nu))
         (T* (filter (lambda (t) (anyvar? t R)) T))
         (FD* (filter (lambda (p) (anyvar? (car p) R)) FD)))
    (if (and (null? D*) (null? Y*) (null? Nu*) (null? T*) (null? FD*))
        v
        (append (list v)
                (if (null? D*) '() (list `(=/= . ,D*)))
                (if (null? Y*) '() (list `(sym . ,Y*)))
                (if (null? Nu*) '() (list `(num . ,Nu*)))
                (if (null? T*) '() (list `(absento . ,T*)))
                (if (null? FD*) '() (list `(fd . ,FD*)))))))

(define (reify-s v subst n)
  "Build a reification substitution (intmap). Returns (subst . counter)."
  (let ((v (walk v subst)))
    (cond
     ((var? v)
      (cons (intmap-set subst (cadr v) (reify-name n)) (+ n 1)))
     ((pair? v)
      (let* ((r (reify-s (car v) subst n)))
        (reify-s (cdr v) (car r) (cdr r))))
     (else (cons subst n)))))

(define (anyvar? term R)
  "Does any variable in term appear in the reification substitution R?"
  (cond
    ((var? term) (not (var? (walk term R))))
    ((pair? term) (or (anyvar? (car term) R) (anyvar? (cdr term) R)))
    (else #f)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Run
;;; ══════════════════════════════════════════════════════════════════════════════

(define (take n $)
  (cond
   ((and n (= n 0)) '())
   ((null? $) '())
   ((procedure? $) (take n ($)))
   (else (cons (car $) (take (and n (- n 1)) (cdr $))))))

(define-syntax run-plan
  (syntax-rules ()
    ((_ n ns (q) g0 g ...)
     (map reify-1st
          (take n
                ((fresh (q) g0 g ...)
                 (empty-cstate ns)))))))

(define-syntax run-plan*
  (syntax-rules ()
    ((_ ns (q) g0 g ...) (run-plan #f ns (q) g0 g ...))))
