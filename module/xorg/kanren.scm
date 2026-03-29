;;; kanren.scm — miniKanren implementation for xorg
;;; Follows the canonical microKanren (Hemann & Friedman) design:
;;;   state = (substitution . counter) — counter threaded through search
;;; With wrapper-layer additions: Zzz suspension, reification, occurs check.
;;; Hoot/WASM compatible: uses only lambdas, pairs, alists, syntax-rules.

(define-module (xorg kanren)
  #:use-module (srfi srfi-1)
  #:export (var var? var=?
            empty-state empty-subst
            walk walk*
            unify
            == succeed fail
            call/fresh fresh conde
            disj conj
            run run*
            take reify-1st
            appendo membero))

;;; ── Logic variables ────────────────────────────────────────────────────────
;;; Tagged lists (var N). Lists instead of vectors for Hoot/WASM compat.

(define (var c) (list 'var c))
(define (var? x) (and (pair? x) (eq? (car x) 'var) (pair? (cdr x)) (null? (cddr x))))
(define (var=? x1 x2) (= (cadr x1) (cadr x2)))

;;; ── State: (substitution . counter) ────────────────────────────────────────
;;; The counter is threaded through the state, not global. Each search branch
;;; gets its own counter value — no shared mutable state during search.

(define empty-subst '())
(define empty-state (cons empty-subst 0))

(define (state-subst s/c) (car s/c))
(define (state-counter s/c) (cdr s/c))

;;; ── Substitution ───────────────────────────────────────────────────────────

(define (walk term subst)
  (if (var? term)
      (let loop ((s subst))
        (cond
         ((null? s) term)
         ((and (var? (caar s)) (var=? term (caar s)))
          (walk (cdar s) subst))
         (else (loop (cdr s)))))
      term))

(define (walk* term subst)
  (let ((v (walk term subst)))
    (cond
     ((var? v) v)
     ((pair? v) (cons (walk* (car v) subst) (walk* (cdr v) subst)))
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
      (cons (cons x v) subst)))

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

;;; ── Goals and streams ──────────────────────────────────────────────────────
;;; Stream protocol (same as microKanren):
;;;   empty    = '()
;;;   mature   = (cons state stream)
;;;   immature = (lambda () stream)
;;; Goals: state -> stream

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
;;; Wraps a goal to create a suspension point, ensuring recursive goals yield.

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

;; conj+: conjunction with Zzz suspension on each goal
(define-syntax conj+
  (syntax-rules ()
    ((_ g) (Zzz g))
    ((_ g0 g ...) (conj (Zzz g0) (conj+ g ...)))))

;; disj+: flat disjunction with Zzz suspension on each branch
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

(define (reify-s v subst)
  "Build a reification substitution mapping unbound vars to _.N names."
  (let ((v (walk v subst)))
    (cond
     ((var? v)
      (let ((name (reify-name (length subst))))
        (cons (cons v name) subst)))
     ((pair? v)
      (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))

(define (reify-1st s/c)
  "Reify the first variable (var 0) from a state."
  (let* ((v (walk* (var 0) (state-subst s/c)))
         (r (reify-s v empty-subst)))
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
