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
  #:use-module ((playnet kanren) #:select (var var? var=? empty-subst walk walk* unify unify-diff intmap-ref intmap-set intmap-fold unbound? appendo membero))
  #:use-module ((playnet kanren-planning) #:select (make-plan-ctx plan-ctx? ctx-facts ctx-ps ctx-obs ctx-ls ctx-plan-id ctx-indexes))
  #:use-module ((srfi srfi-1) #:select (any filter filter-map append-map fold delete-duplicates iota last))
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
            cstate-S cstate-C cstate-N cstate-CS cstate-FD cstate-P
            cstate-with
            ;; Core forms
            == succeed fail
            call/fresh fresh conde
            disj conj
            Zzz conj+ disj+
            ;; Stream
            bind mplus
            ;; Run
            run-plan run-plan*
            ;; Projection + list
            project in-list-o
            ;; Symbolic constraints
            =/= numbero symbolo absento
            ;; CLP(FD)
            infd rangeo +fd -fd *fd <fd <=fd distinctfd labelfd
            ;; CLP(FD) internals (for custom constraints)
            domain-ref domain-lo domain-hi make-interval
            register-propagator
            ;; Extra relations
            lasto))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; State: #(S C N CS FD P)
;;; CS = per-variable constraint store (intmap: var-counter → constraint-record)
;;; constraint-record = (T D A) where:
;;;   T  = type constraint: #f | 'sym | 'num
;;;   D  = list of disequality constraints (each is a list of (var . val) pairs)
;;;   A  = list of absento terms
;;; FD = finite domain store (intmap: var-counter → domain)
;;; P  = propagator queue (intmap: var-counter → list-of-goals)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (make-cstate S C N CS FD P)
  (vector S C N CS FD P))

(define (cstate-S st)  (vector-ref st 0))
(define (cstate-C st)  (vector-ref st 1))
(define (cstate-N st)  (vector-ref st 2))
(define (cstate-CS st) (vector-ref st 3))
(define (cstate-FD st) (vector-ref st 4))
(define (cstate-P st)  (vector-ref st 5))


(define (cstate-with st . updates)
  "Functional update: (cstate-with st 'S new-s 'FD new-fd 'P new-p)"
  (let ((v (make-vector 6)))
    (let copy ((i 0))
      (when (< i 6) (vector-set! v i (vector-ref st i)) (copy (+ i 1))))
    (let loop ((u updates))
      (if (null? u) v
          (begin
            (vector-set! v (slot-index (car u)) (cadr u))
            (loop (cddr u)))))))

(define (slot-index sym)
  (cond ((eq? sym 'S) 0) ((eq? sym 'C) 1) ((eq? sym 'N) 2)
        ((eq? sym 'CS) 3) ((eq? sym 'FD) 4) ((eq? sym 'P) 5)
        (else (error "bad slot" sym))))

(define (empty-cstate ns)
  (make-cstate empty-subst 0 ns '() '() '()))

;;; Per-variable constraint records
(define empty-c '(#f () ()))
(define (c-T c) (car c))
(define (c-D c) (cadr c))
(define (c-A c) (caddr c))
(define (c-with-T c T) (list T (c-D c) (c-A c)))
(define (c-with-D c D) (list (c-T c) D (c-A c)))
(define (c-with-A c A) (list (c-T c) (c-D c) A))

(define (lookup-c st x)
  "Get constraint record for var x. Returns empty-c if none."
  (let ((val (intmap-ref (cstate-CS st) (cadr x))))
    (if (unbound? val) empty-c val)))

(define (set-c st x c)
  "Set constraint record for var x."
  (cstate-with st 'CS (intmap-set (cstate-CS st) (cadr x) c)))

(define (register-propagator st trigger-vars goal)
  "Register GOAL to re-fire when any trigger var becomes ground.
   P is an intmap: var-counter → list-of-goals."
  (let loop ((vs trigger-vars) (P (cstate-P st)))
    (if (null? vs)
        (cstate-with st 'P P)
        (let* ((v (car vs))
               (k (cadr v))
               (existing (let ((val (intmap-ref P k)))
                           (if (unbound? val) '() val))))
          (loop (cdr vs) (intmap-set P k (cons goal existing)))))))


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
;;; Symbolic constraint helpers
;;; ══════════════════════════════════════════════════════════════════════════════

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


(define (fd-narrow-after-unify S FD added)
  "Narrow FD constraints for vars affected by ADDED bindings.
   O(|added|) instead of O(|FD|)."
  (let* (;; Collect var counters affected by unification
         (affected (map (lambda (a)
                          (let ((x (car a)))
                            (if (var? x) (cadr x) #f)))
                        added))
         ;; Only check FD entries for affected vars
         (entries (filter-map (lambda (counter)
                                (and counter
                                     (let ((dom (intmap-ref FD counter)))
                                       (if (unbound? dom) #f
                                           (cons counter dom)))))
                              affected)))
    (let loop ((fd entries) (S S) (new-fd FD))
      (if (null? fd)
          (cons S new-fd)
          (let* ((counter (caar fd))
                 (dom (cdar fd))
                 (x (var counter))
                 (v (walk x S)))
          (cond
            ;; Variable is now ground — check it's in domain
            ((not (var? v))
             (if (and (integer? v) (domain-contains? dom v))
                 (loop (cdr fd) S new-fd)  ;; satisfied, drop constraint
                 #f))  ;; fail
            ;; Variable unified with another variable — merge domains
            ((and (var? v) (not (var=? v x)))
             (let ((other-dom (domain-ref new-fd v)))
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
                 (loop (cdr fd) S (domain-set new-fd v dom))))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Core goals
;;; ══════════════════════════════════════════════════════════════════════════════

(define (and-foldl proc init lst)
  "Fold with short-circuit on #f."
  (if (null? lst) init
      (let ((res (proc (car lst) init)))
        (and res (and-foldl proc res (cdr lst))))))

(define (apply-goals goals st)
  "Apply a list of goals sequentially to state. Returns state or #f on failure.
   Goals return streams (lists); we extract the first result."
  (if (null? goals) st
      (let ((result ((car goals) st)))
        (if (null? result) #f
            (apply-goals (cdr goals) (car result))))))

(define (update-constraints binding st)
  "When var x is bound to term v, propagate x's constraints to v.
   Returns updated state or #f on failure."
  (let* ((x (car binding))
         (v (cdr binding)))
    (if (not (var? x)) st
        (let ((c (lookup-c st x)))
          (if (equal? c empty-c) st
              ;; Remove constraints from x, then re-apply to v
              (let ((st (set-c st x empty-c)))
                (apply-goals
                  (append
                    (cond
                      ((eq? (c-T c) 'sym) (list (symbolo v)))
                      ((eq? (c-T c) 'num) (list (numbero v)))
                      (else '()))
                    (map (lambda (a) (absento a v)) (c-A c))
                    (map (lambda (d) (=/=* d)) (c-D c)))
                  st)))))))

(define (=/=* S+)
  "Re-apply a disequality constraint from its stored bindings."
  (lambda (st)
    (let* ((S (cstate-S st))
           (result (unify-diff (map car S+) (map cdr S+) S)))
      (cond
        ((not result) (list st))       ;; can't unify → satisfied
        ((null? (cdr result)) '())     ;; already equal → violated
        (else
         (let* ((added (cdr result))
                (el (car added))
                (first-var (car el))
                (c (lookup-c st first-var))
                (st (set-c st first-var (c-with-D c (cons added (c-D c))))))
           (if (var? (cdr el))
               (let* ((second-var (cdr el))
                      (c2 (lookup-c st second-var)))
                 (list (set-c st second-var (c-with-D c2 (cons added (c-D c2))))))
               (list st))))))))

(define (== u v)
  (lambda (st)
    (let ((unify-result (unify-diff u v (cstate-S st))))
      (if (not unify-result) '()
          (let* ((S0 (car unify-result))
                 (added (cdr unify-result))
                 (result (fd-narrow-after-unify S0 (cstate-FD st) added)))
            (if (not result) '()
                (let* ((S* (car result))
                       (FD* (cdr result))
                       (st* (cstate-with st 'S S* 'FD FD*))
                       (st* (and-foldl update-constraints st* added)))
                  (if (not st*) '()
                      (fire-propagators st* added)))))))))

(define (fire-propagators st added)
  "Fire propagators for variables in ADDED that became ground.
   O(|added|) lookups instead of scanning all propagators."
  (let* ((S (cstate-S st))
         (P (cstate-P st))
         ;; For each added binding, check if var is now ground and collect its goals
         (result
          (fold (lambda (binding acc)
                  (let* ((x (car binding))
                         (goals-so-far (car acc))
                         (P-so-far (cdr acc)))
                    (if (var? x)
                        (let* ((k (cadr x))
                               (val (intmap-ref P-so-far k)))
                          (if (unbound? val)
                              acc  ;; no propagators for this var
                              ;; Fire these goals, remove from P
                              (cons (append val goals-so-far)
                                    (intmap-set P-so-far k '()))))
                        acc)))  ;; binding was to non-var (shouldn't happen)
                (cons '() P)
                added))
         (goals (car result))
         (new-P (cdr result))
         (st* (cstate-with st 'P new-P)))
    (if (null? goals)
        (list st*)
        (let chain ((gs goals) (stream (list st*)))
          (if (null? gs) stream
              (chain (cdr gs) (bind stream (car gs))))))))

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
        (else
         ;; Attach disequality to variables in the first added binding
         (let* ((added (cdr result))
                (el (car added))
                (first-var (car el))
                (c (lookup-c st first-var))
                (st (set-c st first-var (c-with-D c (cons added (c-D c))))))
           ;; If RHS is also a var, attach there too
           (if (var? (cdr el))
               (let* ((second-var (cdr el))
                      (c2 (lookup-c st second-var)))
                 (list (set-c st second-var (c-with-D c2 (cons added (c-D c2))))))
               (list st))))))))

(define (numbero u)
  (lambda (st)
    (let* ((S (cstate-S st))
           (v (walk u S)))
      (cond
        ((and (not (var? v)) (not (number? v))) '())  ;; ground non-number → fail
        ((not (var? v)) (list st))                     ;; ground number → ok
        (else
         (let ((c (lookup-c st v)))
           (cond
             ((eq? (c-T c) 'num) (list st))    ;; already constrained
             ((eq? (c-T c) 'sym) '())           ;; conflicts with symbolo
             (else (list (set-c st v (c-with-T c 'num)))))))))))

(define (symbolo u)
  (lambda (st)
    (let* ((S (cstate-S st))
           (v (walk u S)))
      (cond
        ((and (not (var? v)) (not (symbol? v))) '())
        ((not (var? v)) (list st))
        (else
         (let ((c (lookup-c st v)))
           (cond
             ((eq? (c-T c) 'sym) (list st))
             ((eq? (c-T c) 'num) '())
             (else (list (set-c st v (c-with-T c 'sym)))))))))))

(define (absento u v)
  (lambda (st)
    (let* ((S (cstate-S st))
           (wv (walk v S)))
      (cond
        ((mem-check u wv S) '())
        ((var? wv)
         (let* ((c (lookup-c st wv))
                (A (c-A c)))
           (if (memv u A) (list st)  ;; already constrained
               (list (set-c st wv (c-with-A c (cons u A)))))))
        ((pair? wv)
         ;; Push absento into structure
         (let ((st1 ((absento u (car wv)) st)))
           (if (null? st1) '()
               ((absento u (cdr wv)) (car st1)))))
        (else (list st))))))


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
  "All variables must take different values. O(k) forward-checking.
   Removes ground values from unground vars' domains, then registers
   a propagator to re-check when any var becomes ground."
  (lambda (st)
    (let* ((S (cstate-S st))
           (FD (cstate-FD st))
           (walked (map (lambda (v) (walk v S)) vars))
           ;; Separate ground from unground
           (ground-vals (filter (lambda (w) (not (var? w))) walked))
           (unground-vars (filter var? walked)))
      ;; Check: no duplicate ground values
      (if (not (= (length ground-vals) (length (delete-duplicates ground-vals =))))
          '()
          ;; Remove ground values from each unground var's domain
          (let narrow ((gvs ground-vals) (st st))
            (if (null? gvs)
                ;; Register propagator if >1 unground var remains
                (if (< (length unground-vars) 2)
                    (list st)
                    (list (register-propagator st unground-vars
                                              (apply distinctfd vars))))
                (let prune ((uvs unground-vars) (st st))
                  (if (null? uvs)
                      (narrow (cdr gvs) st)
                      (let* ((u (car uvs))
                             (dom (domain-ref (cstate-FD st) u)))
                        (if (and dom (domain-contains? dom (car gvs)))
                            ;; Remove ground val from domain
                            (let ((new-dom (domain-remove dom (car gvs))))
                              (cond
                                ((not new-dom) '())  ;; empty domain
                                ((= (domain-size new-dom) 1)
                                 (let ((result ((== u (domain-lo new-dom)) st)))
                                   (if (null? result) '()
                                       (prune (cdr uvs) (car result)))))
                                (else
                                 (prune (cdr uvs)
                                        (cstate-with st 'FD
                                          (domain-set (cstate-FD st) u new-dom))))))
                            (prune (cdr uvs) st)))))))))))

(define (domain-remove dom val)
  "Remove a value from a domain. Returns new domain or #f if empty."
  (if (interval? dom)
      (cond
        ((and (= val (interval-lo dom)) (= val (interval-hi dom))) #f)
        ((= val (interval-lo dom)) (make-interval (+ val 1) (interval-hi dom)))
        ((= val (interval-hi dom)) (make-interval (interval-lo dom) (- val 1)))
        ;; Interior removal: split to list
        (else (let ((lst (filter (lambda (v) (not (= v val))) (domain->list dom))))
                (if (null? lst) #f lst))))
      (let ((lst (filter (lambda (v) (not (= v val))) dom)))
        (if (null? lst) #f lst))))

(define* (labelfd x #:key (order 'min))
  "Enumerate values in x's domain. O(log Q) binary splitting for intervals.
   ORDER: 'min (default, smallest first) or 'max (largest first)."
  (lambda (st)
    (let* ((S (cstate-S st))
           (v (walk x S)))
      (cond
        ((not (var? v)) (list st))  ;; already ground
        (else
         (let ((dom (domain-ref (cstate-FD st) v)))
           (if (not dom) (list st)  ;; no domain constraint
               (cond
                 ;; Singleton — bind directly
                 ((= (domain-size dom) 1)
                  ((== x (domain-lo dom)) st))
                 ;; Interval — binary split for large domains, linear for small
                 ((interval? dom)
                  (let ((lo (interval-lo dom)) (hi (interval-hi dom)))
                    (if (<= (domain-size dom) 32)
                        ;; Small interval: enumerate linearly (preserves order)
                        (let* ((vals (domain->list dom))
                               (vals (if (eq? order 'max) (reverse vals) vals)))
                          (let try ((vs vals))
                            (if (null? vs) '()
                                (mplus ((== x (car vs)) st)
                                       (lambda () (try (cdr vs)))))))
                        ;; Large interval: binary split, O(log Q)
                        (let ((mid (quotient (+ lo hi) 2)))
                          (if (eq? order 'max)
                              (mplus ((conj (infd x (make-interval (+ mid 1) hi))
                                            (labelfd x #:order order)) st)
                                     (lambda ()
                                       ((conj (infd x (make-interval lo mid))
                                              (labelfd x #:order order)) st)))
                              (mplus ((conj (infd x (make-interval lo mid))
                                            (labelfd x #:order order)) st)
                                     (lambda ()
                                       ((conj (infd x (make-interval (+ mid 1) hi))
                                              (labelfd x #:order order)) st))))))))
                 ;; List domain — enumerate as before
                 (else
                  (let* ((vals (if (eq? order 'max) (reverse dom) dom)))
                    (let try ((vs vals))
                      (if (null? vs) '()
                          (mplus ((== x (car vs)) st)
                                 (lambda () (try (cdr vs))))))))))))))))


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
         ;; Simplify per-variable constraint store
         (CS* (intmap-fold
                (lambda (counter c acc)
                  (let* ((v (var counter))
                         (wv (walk v S))
                         ;; Keep type only if still a var
                         (T (and (var? wv) (c-T c)))
                         ;; Keep disequalities that aren't yet satisfied or violated
                         (D (filter (lambda (d) (let ((S+ (unify* d S)))
                                                  (and S+ (not (eq? S+ S)))))
                                    (c-D c)))
                         ;; Keep absento if still relevant
                         (A (filter (lambda (a)
                                      (let ((wa (walk* a S)))
                                        (or (var? wa) (var? wv)
                                            (mem-check wa wv S))))
                                    (c-A c))))
                    (if (and (not T) (null? D) (null? A))
                        acc  ;; no constraints left, drop
                        (intmap-set acc counter (list (or T #f) D A)))))
                '() (cstate-CS st)))
         ;; Drop FD entries for ground variables
         (FD* (intmap-fold (lambda (counter dom acc)
                             (if (var? (walk (var counter) S))
                                 (intmap-set acc counter dom)
                                 acc))
                           '() (cstate-FD st))))
    (make-cstate S (cstate-C st) (cstate-N st) CS* FD* (cstate-P st))))


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
         ;; Single pass over CS: extract relevant D, Y, Nu, T for vars in R
         (cs-result
          (intmap-fold
            (lambda (k c acc)
              (if (unbound? (intmap-ref R k)) acc  ;; var not in result
                  (let ((wk (walk* (var k) S)))
                    (list
                      ;; D: keep diseqs relevant to result
                      (append (filter (lambda (d) (anyvar? (walk* d S) R))
                                      (c-D c))
                              (car acc))
                      ;; Y
                      (if (eq? (c-T c) 'sym) (cons wk (cadr acc)) (cadr acc))
                      ;; Nu
                      (if (eq? (c-T c) 'num) (cons wk (caddr acc)) (caddr acc))
                      ;; T
                      (append (filter-map
                                (lambda (a)
                                  (let ((t (cons (walk* a S) wk)))
                                    (and (anyvar? t R) t)))
                                (c-A c))
                              (cadddr acc))))))
            '(() () () ())
            (cstate-CS st)))
         (D* (walk* (car cs-result) R))
         (Y* (walk* (cadr cs-result) R))
         (Nu* (walk* (caddr cs-result) R))
         (T* (walk* (cadddr cs-result) R))
         ;; FD constraints
         (FD* (intmap-fold
                (lambda (counter dom acc)
                  (let ((wk (walk* (var counter) S)))
                    (if (anyvar? wk R) (cons (cons (walk* wk R) dom) acc) acc)))
                '() (cstate-FD st))))
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
