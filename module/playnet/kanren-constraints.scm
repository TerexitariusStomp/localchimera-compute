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
  #:use-module ((playnet kanren) #:select (var var? var=? empty-subst walk walk* unify appendo membero))
  #:use-module ((playnet kanren-planning) #:select (make-plan-ctx plan-ctx? ctx-facts ctx-ps ctx-obs ctx-ls ctx-plan-id))
  #:use-module ((srfi srfi-1) #:select (any filter append-map fold delete-duplicates iota))
  #:re-export (var var? var=?
               empty-subst
               walk walk*
               unify
               appendo membero
               make-plan-ctx plan-ctx?
               ctx-facts ctx-ps ctx-obs ctx-ls ctx-plan-id)
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
;;; Finite domain representation
;;; ══════════════════════════════════════════════════════════════════════════════
;;; FD = alist of (var . domain) pairs.
;;; Domain = sorted list of integers (finite enumeration).

(define (domain-ref FD x)
  "Get the domain for variable x, or #f if unconstrained."
  (let ((pair (assq x FD)))
    (and pair (cdr pair))))

(define (domain-set FD x dom)
  "Set the domain for variable x."
  (cons (cons x dom)
        (filter (lambda (p) (not (var=? (car p) x))) FD)))

(define (domain-intersect d1 d2)
  "Intersection of two sorted domain lists."
  (cond
    ((or (null? d1) (null? d2)) '())
    ((= (car d1) (car d2))
     (cons (car d1) (domain-intersect (cdr d1) (cdr d2))))
    ((< (car d1) (car d2))
     (domain-intersect (cdr d1) d2))
    (else
     (domain-intersect d1 (cdr d2)))))

(define (domain-remove dom val)
  "Remove a single value from a domain."
  (filter (lambda (v) (not (= v val))) dom))

(define (make-range lo hi)
  "Create a domain from lo to hi (inclusive)."
  (iota (+ 1 (- hi lo)) lo))


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

(define (prefix-S S+ S)
  (if (eq? S+ S) '() (cons (car S+) (prefix-S (cdr S+) S))))

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
                    (not (memv v dom))))))  ;; must be in domain
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
             (if (and (integer? v) (memv v dom))
                 (loop (cdr fd) S new-fd)  ;; satisfied, drop constraint
                 #f))  ;; fail
            ;; Variable unified with another variable — merge domains
            ((and (var? v) (not (var=? v x)))
             (let ((other-dom (domain-ref FD v)))
               (if other-dom
                   (let ((merged (domain-intersect (sort dom <) (sort other-dom <))))
                     (if (null? merged) #f
                         (if (= 1 (length merged))
                             ;; Singleton — bind the variable
                             (let ((S+ (unify v (car merged) S)))
                               (if S+ (loop (cdr fd) S+ new-fd)
                                   #f))
                             (loop (cdr fd) S (domain-set new-fd v merged)))))
                   ;; Other var has no domain — transfer this domain to it
                   (loop (cdr fd) S (domain-set new-fd v dom)))))
            ;; Variable still free with domain — keep constraint
            (else
             (if (= 1 (length dom))
                 ;; Singleton — bind
                 (let ((S+ (unify v (car dom) S)))
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
           (S0 (unify u v S)))
      (cond
        ((not S0) (list st))
        ((eq? S0 S) '())
        (else (list (cstate-with st 'D (cons (prefix-S S0 S) (cstate-D st)))))))))

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

(define (infd x vals)
  "Constrain x to be one of VALS (a list of integers).
   If x is already ground, check membership. If x has an existing domain, intersect."
  (lambda (st)
    (let* ((S (cstate-S st))
           (FD (cstate-FD st))
           (v (walk x S))
           (sorted-vals (sort (delete-duplicates vals) <)))
      (cond
        ;; Ground — just check membership
        ((not (var? v))
         (if (and (integer? v) (memv v sorted-vals))
             (list st) '()))
        ;; Has existing domain — intersect
        ((domain-ref FD v)
         => (lambda (existing)
              (let ((narrowed (domain-intersect (sort existing <) sorted-vals)))
                (cond
                  ((null? narrowed) '())
                  ((= 1 (length narrowed))
                   ;; Singleton — bind via ==
                   ((== v (car narrowed)) st))
                  (else
                   (list (cstate-with st 'FD (domain-set FD v narrowed))))))))
        ;; No existing domain
        (else
         (cond
           ((null? sorted-vals) '())
           ((= 1 (length sorted-vals))
            ((== v (car sorted-vals)) st))
           (else
            (list (cstate-with st 'FD (domain-set FD v sorted-vals))))))))))

(define (rangeo x lo hi)
  "Shorthand: constrain x to integers in [lo, hi]."
  (infd x (make-range lo hi)))

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
        ;; One or zero ground — propagate via domains
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (list xv) (or (and (var? xv) (domain-ref FD xv)) #f)))
                (yd (if (number? yv) (list yv) (or (and (var? yv) (domain-ref FD yv)) #f)))
                (zd (if (number? zv) (list zv) (or (and (var? zv) (domain-ref FD zv)) #f))))
           (if (and xd yd zd)
               ;; All have domains — enumerate valid triples via conde
               (let ((valid (fd-triples-add xd yd zd)))
                 (if (null? valid) '()
                     ;; Enumerate: each valid triple is a conde branch
                     (let try ((triples valid))
                       (if (null? triples) '()
                           (let ((t (car triples)))
                             (mplus ((conj (== x (car t))
                                           (conj (== y (cadr t))
                                                 (== z (caddr t)))) st)
                                    (lambda () (try (cdr triples)))))))))
               ;; Not enough domain info — register propagator to re-fire later
               (let ((unground (filter var? (list xv yv zv))))
                 (list (register-propagator st unground (+fd x y z)))))))))))

(define (fd-triples-add xd yd zd)
  (append-map
    (lambda (xv)
      (append-map
        (lambda (yv)
          (let ((zv (+ xv yv)))
            (if (memv zv zd) (list (list xv yv zv)) '())))
        yd))
    xd))

(define (maybe-narrow x xv new-dom)
  "Narrow x's domain to new-dom. If x is ground, check. If var, constrain."
  (cond
    ((number? xv)
     (if (memv xv new-dom) succeed fail))
    ((= 1 (length new-dom))
     (== x (car new-dom)))
    (else
     (infd x new-dom))))

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
                (xd (if (number? xv) (list xv) (or (and (var? xv) (domain-ref FD xv)) #f)))
                (yd (if (number? yv) (list yv) (or (and (var? yv) (domain-ref FD yv)) #f)))
                (zd (if (number? zv) (list zv) (or (and (var? zv) (domain-ref FD zv)) #f))))
           (if (and xd yd zd)
               (let ((valid (fd-triples-mul xd yd zd)))
                 (if (null? valid) '()
                     (let try ((triples valid))
                       (if (null? triples) '()
                           (let ((t (car triples)))
                             (mplus ((conj (== x (car t))
                                           (conj (== y (cadr t))
                                                 (== z (caddr t)))) st)
                                    (lambda () (try (cdr triples)))))))))
               (let ((unground (filter var? (list xv yv zv))))
                 (list (register-propagator st unground (*fd x y z)))))))))))

(define (fd-triples-mul xd yd zd)
  (append-map
    (lambda (x)
      (append-map
        (lambda (y)
          (let ((z (* x y)))
            (if (memv z zd) (list (list x y z)) '())))
        yd))
    xd))

(define (<fd x y)
  "x < y, over finite domains."
  (lambda (st)
    (let* ((S (cstate-S st))
           (xv (walk x S)) (yv (walk y S)))
      (cond
        ((and (number? xv) (number? yv))
         (if (< xv yv) (list st) '()))
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (list xv) (or (and (var? xv) (domain-ref FD xv)) #f)))
                (yd (if (number? yv) (list yv) (or (and (var? yv) (domain-ref FD yv)) #f))))
           (if (and xd yd)
               (let* ((max-y (apply max yd))
                      (min-x (apply min xd))
                      (new-xd (filter (lambda (v) (< v max-y)) xd))
                      (new-yd (filter (lambda (v) (> v min-x)) yd)))
                 (if (or (null? new-xd) (null? new-yd)) '()
                     ((conj (maybe-narrow x xv new-xd)
                            (maybe-narrow y yv new-yd))
                      st)))
               (let ((unground (filter var? (list xv yv))))
                 (list (register-propagator st unground (<fd x y)))))))))))

(define (<=fd x y)
  "x <= y, over finite domains."
  (lambda (st)
    (let* ((S (cstate-S st))
           (xv (walk x S)) (yv (walk y S)))
      (cond
        ((and (number? xv) (number? yv))
         (if (<= xv yv) (list st) '()))
        (else
         (let* ((FD (cstate-FD st))
                (xd (if (number? xv) (list xv) (or (and (var? xv) (domain-ref FD xv)) #f)))
                (yd (if (number? yv) (list yv) (or (and (var? yv) (domain-ref FD yv)) #f))))
           (if (and xd yd)
               (let* ((max-y (apply max yd))
                      (min-x (apply min xd))
                      (new-xd (filter (lambda (v) (<= v max-y)) xd))
                      (new-yd (filter (lambda (v) (>= v min-x)) yd)))
                 (if (or (null? new-xd) (null? new-yd)) '()
                     ((conj (maybe-narrow x xv new-xd)
                            (maybe-narrow y yv new-yd))
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
                          (if (eq? order 'max) (reverse dom) dom))))
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

(define (reify-1st st)
  (let* ((st (simplify-constraints st))
         (S (cstate-S st))
         (v (walk* (var 0) S))
         (R (reify-s v empty-subst))
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

(define (reify-s v subst)
  (let ((v (walk v subst)))
    (cond
     ((var? v)
      (cons (cons v (string->symbol (string-append "_." (number->string (length subst)))))
            subst))
     ((pair? v) (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))

(define (anyvar? term R)
  (cond
    ((var? term) (assq term R))
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
