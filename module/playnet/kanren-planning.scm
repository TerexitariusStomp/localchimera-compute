;;; kanren-planning.scm — miniKanren with netter allocation state
;;;
;;; Self-contained miniKanren for planning. Same names as (playnet kanren)
;;; (==, fresh, conde, etc.) but over extended state:
;;;
;;;   State = (substitution counter . netter-state)
;;;
;;; Users import (playnet kanren-planning) alone — never both modules.
;;; Re-exports state-independent helpers from (playnet kanren):
;;;   var, var?, var=?, walk, walk*, unify, appendo, membero
;;;
;;; Adds:
;;;   project  — syntax-rules macro (from faster-minikanren pattern)
;;;   <plan-ctx> — record bundling store references
;;;
;;; The netter's fork = identity means conde branches automatically
;;; fork the allocation state for free.

(define-module (playnet kanren-planning)
  #:use-module (playnet kanren)
  #:use-module (srfi srfi-9)
  #:re-export (var var? var=?
               empty-subst
               walk walk*
               unify
               appendo membero)
  #:export (;; State
            make-planning-state
            planning-state-subst
            planning-state-counter
            planning-state-netter
            empty-planning-state
            ;; Core forms (same names as kanren.scm)
            == succeed fail
            call/fresh fresh conde
            disj conj
            Zzz conj+ disj+
            ;; Run
            run-plan run-plan*
            ;; Projection
            project
            ;; List membership (for concrete Scheme lists)
            in-list-o
            ;; Planning context
            make-plan-ctx plan-ctx?
            ctx-facts ctx-ps ctx-obs ctx-ls ctx-plan-id))


;;; ── State ─────────────────────────────────────────────────────────────────────

(define (make-planning-state subst counter netter)
  (cons subst (cons counter netter)))

(define (planning-state-subst st) (car st))
(define (planning-state-counter st) (cadr st))
(define (planning-state-netter st) (cddr st))

(define (empty-planning-state ns)
  (make-planning-state empty-subst 0 ns))


;;; ── Planning context ──────────────────────────────────────────────────────────
;;; Bundles lifted facts (plain tuples) and store references for netter.
;;; facts = list of tagged tuples, queried relationally via in-list-o.
;;; plan-store + observer = Goblins actors for imperative netter allocation.

(define-record-type <plan-ctx>
  (make-plan-ctx facts plan-store observer location-store plan-id)
  plan-ctx?
  (facts          ctx-facts)
  (plan-store     ctx-ps)
  (observer       ctx-obs)
  (location-store ctx-ls)
  (plan-id        ctx-plan-id))


;;; ── Goals ─────────────────────────────────────────────────────────────────────

(define (== u v)
  (lambda (st)
    (let ((s (unify u v (planning-state-subst st))))
      (if s
          (list (make-planning-state s
                  (planning-state-counter st)
                  (planning-state-netter st)))
          '()))))

(define (succeed st) (list st))
(define (fail st) '())


;;; ── Stream operations ─────────────────────────────────────────────────────────

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


;;; ── Combinators ───────────────────────────────────────────────────────────────

(define (disj g1 g2) (lambda (st) (mplus (g1 st) (g2 st))))
(define (conj g1 g2) (lambda (st) (bind (g1 st) g2)))

(define (call/fresh f)
  (lambda (st)
    (let ((c (planning-state-counter st)))
      ((f (var c))
       (make-planning-state (planning-state-subst st)
                            (+ c 1)
                            (planning-state-netter st))))))


;;; ── Suspension ────────────────────────────────────────────────────────────────

(define-syntax Zzz
  (syntax-rules ()
    ((_ g) (lambda (st) (lambda () (g st))))))


;;; ── Macros ────────────────────────────────────────────────────────────────────

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


;;; ── Project (from faster-minikanren/mk.scm:533-538) ──────────────────────────

(define-syntax project
  (syntax-rules ()
    ((_ (x ...) g g* ...)
     (lambda (st)
       (let ((x (walk* x (planning-state-subst st))) ...)
         ((fresh () g g* ...) st))))))


;;; ── List membership (concrete Scheme lists) ───────────────────────────────────

(define (in-list-o x lst)
  "x is a member of concrete Scheme list LST (not a logic variable).
   Produces conde branches — one per element."
  (if (null? lst) fail
      (conde
       ((== x (car lst)))
       ((in-list-o x (cdr lst))))))


;;; ── Reification ───────────────────────────────────────────────────────────────

(define (reify-1st st)
  (let* ((v (walk* (var 0) (planning-state-subst st)))
         (r (reify-s v empty-subst)))
    (walk* v r)))

(define (reify-s v subst)
  (let ((v (walk v subst)))
    (cond
     ((var? v)
      (let ((name (string->symbol
                    (string-append "_." (number->string (length subst))))))
        (cons (cons v name) subst)))
     ((pair? v)
      (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))


;;; ── Run ───────────────────────────────────────────────────────────────────────

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
                 (empty-planning-state ns)))))))

(define-syntax run-plan*
  (syntax-rules ()
    ((_ ns (q) g0 g ...) (run-plan #f ns (q) g0 g ...))))
