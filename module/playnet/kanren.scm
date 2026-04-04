;;; kanren.scm — miniKanren implementation for playnet
;;; Follows the canonical microKanren (Hemann & Friedman) design:
;;;   state = (substitution . counter) — counter threaded through search
;;; With wrapper-layer additions: Zzz suspension, reification, occurs check.
;;; Hoot/WASM compatible: uses only lambdas, pairs, alists, syntax-rules.
;;;
;;; Substitution is a persistent integer trie (intmap) keyed by var counter.
;;; walk is O(log16 n) per hop instead of O(n) linear scan.

(define-module (playnet kanren)
  #:use-module (srfi srfi-1)
  #:export (var var? var=?
            empty-state empty-subst
            walk walk*
            unify unify-diff
            intmap-ref intmap-set intmap-fold unbound?
            == succeed fail
            call/fresh fresh conde
            disj conj
            run run*
            take reify-1st
            appendo membero
            ;; Higher-order relational combinators
            map-goal-o fold-goal-o filter-goal-o
            any-goal-o find-goal-o
            transitive-closure-o))

;;; ── Logic variables ────────────────────────────────────────────────────────
;;; Tagged lists (var N). Lists instead of vectors for Hoot/WASM compat.

(define (var c) (list 'var c))
(define (var? x) (and (pair? x) (eq? (car x) 'var) (pair? (cdr x)) (null? (cddr x))))
(define (var=? x1 x2) (= (cadr x1) (cadr x2)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Persistent integer trie (intmap) — Hoot-safe, O(log16 n) lookup/insert
;;; ══════════════════════════════════════════════════════════════════════════════
;;; Uses only pairs, lists, symbols. No vectors, no records.
;;;
;;; Representation:
;;;   empty  = '()
;;;   leaf   = ('L full-key . value)     — stores remaining key bits
;;;   branch = ('B (local-idx . child) ...)  — sparse alist of children
;;;
;;; Branching factor 16 (4-bit chunks). For var counters 0-200:
;;; max depth = 2 levels, ~32 comparisons worst case (vs ~200 for alist).

(define *unbound* (list 'unbound))
(define (unbound? v) (eq? v *unbound*))

(define (intmap-ref m k)
  "O(log16 n) lookup. Returns value or *unbound*."
  (cond
    ((null? m) *unbound*)
    ((eq? (car m) 'L)
     (if (= (cadr m) k) (cddr m) *unbound*))
    ((eq? (car m) 'B)
     (let ((slot (assv (logand k 15) (cdr m))))
       (if slot (intmap-ref (cdr slot) (ash k -4)) *unbound*)))
    (else *unbound*)))

(define (intmap-set m k v)
  "O(log16 n) functional insert. Returns new intmap."
  (cond
    ((null? m) (cons 'L (cons k v)))
    ((eq? (car m) 'L)
     (let ((ok (cadr m)))
       (if (= ok k)
           (cons 'L (cons k v))
           (let ((oi (logand ok 15)) (ni (logand k 15)))
             (if (= oi ni)
                 (cons 'B (list (cons oi (intmap-set
                                           (cons 'L (cons (ash ok -4) (cddr m)))
                                           (ash k -4) v))))
                 (cons 'B (list (cons oi (cons 'L (cons (ash ok -4) (cddr m))))
                                (cons ni (cons 'L (cons (ash k -4) v))))))))))
    ((eq? (car m) 'B)
     (let* ((ni (logand k 15))
            (children (cdr m))
            (slot (assv ni children))
            (child (if slot (cdr slot) '()))
            (new-child (intmap-set child (ash k -4) v)))
       (cons 'B (cons (cons ni new-child)
                       (filter (lambda (p) (not (= (car p) ni))) children)))))
    (else (cons 'L (cons k v)))))

(define (intmap-fold proc init m)
  "Fold proc over all (key value acc) -> acc in the intmap."
  (intmap-fold* proc init m 0 0))

(define (intmap-fold* proc acc m shift offset)
  (cond
    ((null? m) acc)
    ((eq? (car m) 'L)
     (proc (+ (ash (cadr m) shift) offset) (cddr m) acc))
    ((eq? (car m) 'B)
     (let loop ((children (cdr m)) (acc acc))
       (if (null? children) acc
           (loop (cdr children)
                 (intmap-fold* proc acc (cdr (car children))
                               (+ shift 4)
                               (+ offset (ash (caar children) shift)))))))
    (else acc)))


;;; ── State: (substitution . counter) ────────────────────────────────────────

(define empty-subst '())
(define empty-state (cons empty-subst 0))

(define (state-subst s/c) (car s/c))
(define (state-counter s/c) (cdr s/c))

;;; ── Substitution ───────────────────────────────────────────────────────────

(define (walk term subst)
  (if (var? term)
      (let ((val (intmap-ref subst (cadr term))))
        (if (unbound? val) term (walk val subst)))
      term))

(define (walk* term subst)
  (let ((v (walk term subst)))
    (cond
     ((var? v) v)
     ((pair? v)
      (let ((a (walk* (car v) subst))
            (d (walk* (cdr v) subst)))
        (if (and (eq? a (car v)) (eq? d (cdr v)))
            v  ;; structural sharing: avoid allocation when unchanged
            (cons a d))))
     (else v))))

;;; ── Occurs check ───────────────────────────────────────────────────────────

(define (occurs? x v subst)
  "Does variable x occur in term v (under substitution)?"
  (let ((v (walk v subst)))
    (cond
     ((var? v) (var=? x v))
     ((pair? v) (or (occurs? x (car v) subst)
                    (occurs? x (cdr v) subst)))
     (else #f))))

(define (ext-s x v subst)
  "Extend substitution with x=v, with occurs check."
  (if (occurs? x v subst)
      #f
      (intmap-set subst (cadr x) v)))

;;; ── Unification ────────────────────────────────────────────────────────────

(define (unify u v subst)
  (let ((u (walk u subst))
        (v (walk v subst)))
    (cond
     ((and (var? u) (var? v) (var=? u v)) subst)
     ((var? u) (ext-s u v subst))
     ((var? v) (ext-s v u subst))
     ((and (pair? u) (pair? v))
      (let ((s (unify (car u) (car v) subst)))
        (and s (unify (cdr u) (cdr v) s))))
     ((equal? u v) subst)
     (else #f))))

(define (unify-diff u v subst)
  "Like unify, but returns (S . added-pairs) or #f.
   Needed by =/= to capture the disequality bindings."
  (let ((u (walk u subst)) (v (walk v subst)))
    (cond
     ((and (var? u) (var? v) (var=? u v)) (cons subst '()))
     ((var? u)
      (if (occurs? u v subst)
          #f
          (cons (intmap-set subst (cadr u) v) (list (cons u v)))))
     ((var? v)
      (if (occurs? v u subst)
          #f
          (cons (intmap-set subst (cadr v) u) (list (cons v u)))))
     ((and (pair? u) (pair? v))
      (let ((r1 (unify-diff (car u) (car v) subst)))
        (and r1
             (let ((r2 (unify-diff (cdr u) (cdr v) (car r1))))
               (and r2
                    (cons (car r2) (append (cdr r1) (cdr r2))))))))
     ((equal? u v) (cons subst '()))
     (else #f))))

;;; ── Goals and streams ──────────────────────────────────────────────────────

(define (== u v)
  (lambda (s/c)
    (let ((s (unify u v (state-subst s/c))))
      (if s
          (list (cons s (state-counter s/c)))
          '()))))

(define (succeed s/c) (list s/c))
(define (fail s/c) '())

;;; ── Stream operations (interleaving) ───────────────────────────────────────

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

;;; ── Suspension (Zzz) ───────────────────────────────────────────────────────

(define-syntax Zzz
  (syntax-rules ()
    ((_ g) (lambda (s/c) (lambda () (g s/c))))))

;;; ── Combinators ────────────────────────────────────────────────────────────

(define (disj g1 g2) (lambda (s/c) (mplus (g1 s/c) (g2 s/c))))
(define (conj g1 g2) (lambda (s/c) (bind (g1 s/c) g2)))

(define (call/fresh f)
  (lambda (s/c)
    (let ((c (state-counter s/c)))
      ((f (var c)) (cons (state-subst s/c) (+ c 1))))))

;;; ── Macros ─────────────────────────────────────────────────────────────────

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

;;; ── Reification ────────────────────────────────────────────────────────────

(define (reify-name n)
  "Produce a reified variable name like _.0, _.1, etc."
  (string->symbol (string-append "_." (number->string n))))

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

(define (reify-1st s/c)
  "Reify the first variable (var 0) from a state."
  (let* ((v (walk* (var 0) (state-subst s/c)))
         (r (car (reify-s v empty-subst 0))))
    (walk* v r)))

;;; ── run / run* ─────────────────────────────────────────────────────────────

(define (take n $)
  (cond
   ((and n (= n 0)) '())
   ((null? $) '())
   ((procedure? $) (take n ($)))
   (else (cons (car $) (take (and n (- n 1)) (cdr $))))))

(define-syntax run
  (syntax-rules ()
    ((_ n (q) g0 g ...)
     (map reify-1st
          (take n
                ((fresh (q) g0 g ...) empty-state))))))

(define-syntax run*
  (syntax-rules ()
    ((_ (q) g0 g ...) (run #f (q) g0 g ...))))

;;; ── Common relations ───────────────────────────────────────────────────────

(define (appendo l r out)
  (conde
   ((== l '()) (== r out))
   ((fresh (h t res)
      (== l (cons h t))
      (== out (cons h res))
      (appendo t r res)))))

(define (membero x lst)
  (conde
   ((fresh (rest)
      (== lst (cons x rest))))
   ((fresh (h rest)
      (== lst (cons h rest))
      (membero x rest)))))


;;; ── Higher-order relational combinators ──────────────────────────────────────
;;; The relational equivalents of map, fold, filter, any, find.
;;; Each takes a goal-producing function and applies it over a ground list.

(define (map-goal-o items item->goal-o results)
  "Relational map: apply a goal to each item, collect results."
  (if (null? items)
      (== results '())
      (fresh (result rest)
        (item->goal-o (car items) result)
        (map-goal-o (cdr items) item->goal-o rest)
        (== results (cons result rest)))))

(define (fold-goal-o items step-goal-o acc-in acc-out)
  "Relational fold: thread an accumulator through a goal per item."
  (if (null? items)
      (== acc-out acc-in)
      (fresh (acc-mid)
        (step-goal-o (car items) acc-in acc-mid)
        (fold-goal-o (cdr items) step-goal-o acc-mid acc-out))))

(define (filter-goal-o items pred-goal-o results)
  "Relational filter: keep items for which pred-goal-o succeeds."
  (if (null? items)
      (== results '())
      (fresh (rest)
        (filter-goal-o (cdr items) pred-goal-o rest)
        (conde
          ((fresh () (pred-goal-o (car items))
                     (== results (cons (car items) rest))))
          ((== results rest))))))

(define (any-goal-o items pred-goal-o)
  "Relational any: succeed if pred-goal-o succeeds for at least one item."
  (if (null? items)
      fail
      (conde
        ((pred-goal-o (car items)))
        ((any-goal-o (cdr items) pred-goal-o)))))

(define (find-goal-o items pred-goal-o found)
  "Relational find: unify FOUND with the first item where pred-goal-o succeeds."
  (if (null? items)
      fail
      (conde
        ((pred-goal-o (car items))
         (== found (car items)))
        ((find-goal-o (cdr items) pred-goal-o found)))))

(define (transitive-closure-o edge-o from to trace . rest)
  "Depth-bounded transitive closure with proof trace.
   edge-o: (a b) -> goal — the one-step relation
   trace: list of nodes visited (proof path)
   Optional depth argument (default 10)."
  (let ((depth (if (pair? rest) (car rest) 10)))
    (if (= depth 0) fail
        (conde
          ((edge-o from to)
           (== trace (list from to)))
          ((fresh (mid rest-trace)
             (edge-o from mid)
             (transitive-closure-o edge-o mid to rest-trace (- depth 1))
             (== trace (cons from rest-trace))))))))
