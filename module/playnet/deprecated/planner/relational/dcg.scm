;;; dcg.scm — Definite Clause Grammar macro for miniKanren
;;;
;;; Based on PAIP ch.20 (Norvig): make-dcg auto-threads difference-list
;;; variables ?s0 ?s1 ... ?sN so grammar rules look like grammar rules,
;;; not like plumbing.
;;;
;;; Usage:
;;;
;;;   (define-dcg-rule (name arg ...) rhs ...)
;;;
;;; Generates:  (define (name arg ... s0 s) (dcg-body s0 s rhs ...))
;;;
;;; RHS element forms:
;;;   (:word  "w")          — consume one literal word token
;;;   (:words "w1" "w2")    — consume a fixed sequence of words
;;;   (:test  goal)         — pure miniKanren goal; no word consumption
;;;   (nt     a ...)        — non-terminal: calls (nt a ... s_i s_{i+1})
;;;
;;; Bidirectional: ground s0 to parse; ground s and leave s0 fresh to generate.
;;;
;;; Hoot/WASM compatible: uses only syntax-rules, no eval or define-macro.

(define-module (playnet deprecated planner relational dcg)
  #:export (dcg-body define-dcg-rule define-dcg-rules))

(use-modules (playnet deprecated kanren-constraints))


;;; ── dcg-body ───────────────────────────────────────────────────────────────
;;; Core recursive macro. Threads s0 → s1 → ... → s through all RHS elements.

(define-syntax dcg-body
  (syntax-rules (:word :words :test)

    ;; Base case: nothing left to consume — input equals output.
    ((_ s0 s)
     (== s0 s))

    ;; :word — consume one literal word token.
    ((_ s0 s (:word w) rest ...)
     (fresh (s1)
       (word-o w s0 s1)
       (dcg-body s1 s rest ...)))

    ;; :words — consume a fixed sequence of words.
    ((_ s0 s (:words w ...) rest ...)
     (fresh (s1)
       (words-o (list w ...) s0 s1)
       (dcg-body s1 s rest ...)))

    ;; :test — pure goal, no word consumption; s0 passes through unchanged.
    ((_ s0 s (:test g) rest ...)
     (fresh ()
       g
       (dcg-body s0 s rest ...)))

    ;; Non-terminal — append s_i and s_{i+1} to the call.
    ((_ s0 s (nt a ...) rest ...)
     (fresh (s1)
       (nt a ... s0 s1)
       (dcg-body s1 s rest ...)))))


;;; ── define-dcg-rule ────────────────────────────────────────────────────────
;;; Wraps dcg-body in a named relation that takes explicit s0 and s args.
;;; Multiple rules for the same name compose via conde — each call to
;;; define-dcg-rule adds one alternative.  To define multiple alternatives
;;; in one place, use define-dcg-rules (see below).

(define-syntax define-dcg-rule
  (syntax-rules ()
    ((_ (name arg ...) rhs ...)
     (define (name arg ... s0 s)
       (dcg-body s0 s rhs ...)))))


;;; ── define-dcg-rules ───────────────────────────────────────────────────────
;;; Define multiple alternatives for one non-terminal in a single form.
;;; Each alternative is a list of RHS elements, wrapped in an extra pair
;;; of parens to separate them.
;;;
;;; Example:
;;;   (define-dcg-rules (demand-frame ctx goal)
;;;     ((:words "how" "do" "we" "make") (qty-spec-np ctx goal))
;;;     ((:word "make")                  (qty-spec-np ctx goal))
;;;     ((:word "produce")               (qty-spec-np ctx goal)))

(define-syntax define-dcg-rules
  (syntax-rules ()
    ((_ (name arg ...) (rhs ...) ...)
     (define (name arg ... s0 s)
       (conde
         ((dcg-body s0 s rhs ...))
         ...)))))
