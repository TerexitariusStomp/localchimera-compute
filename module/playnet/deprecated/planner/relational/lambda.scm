;;; lambda.scm — λ-calculus engine for Montague-style semantic composition
;;;
;;; Direct port of the machinery from Blackburn & Bos, *Representation and
;;; Inference for Natural Language*, ch.2.4 (betaConversion.pl). The book
;;; uses Prolog vars for bound variables (HOAS) and rides on Prolog's
;;; destructive unification to do substitution. We use gensymmed symbols
;;; instead, which means substitution is an explicit recursion — but the
;;; α-conversion logic is identical in shape.
;;;
;;; Term language:
;;;
;;;   (lam <sym> <body>)        — abstraction
;;;   (app <f> <a>)             — application
;;;   (forall <sym> <body>)     — universal
;;;   (exists <sym> <body>)     — existential
;;;   (and <a> <b>)
;;;   (or  <a> <b>)
;;;   (imp <a> <b>)             — implication
;;;   (not <a>)
;;;   (<pred> <arg> ...)        — atomic predicate; <pred> is a symbol
;;;                                 that is NOT a binder/connective head
;;;   <sym>                     — variable or constant
;;;
;;; The reserved binder/connective heads are: lam app forall exists and or
;;; imp not. Anything else heading a list is an atomic predicate.

(define-module (playnet deprecated planner relational lambda)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (lam-counter lam-reset-counter! lam-gen-var lam-reserved-heads
            lam-free-vars lam-subst lam-subst-binder lam-prefix-of lam-beta-step
            lam-beta-step-binary lam-beta-step-list lam-beta-normalize lam-beta-trace
            lam-alpha-equiv? lam-alpha-go lam-pretty))

(use-modules (ice-9 match)
             ((srfi srfi-1) #:select (delete-duplicates lset-difference
                                       lset-union append-map every any))
             ((srfi srfi-13) #:select (string-join)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Fresh-variable generator
;;; ══════════════════════════════════════════════════════════════════════════

(define lam-counter 0)

(define (lam-reset-counter!)
  "Reset the gensym counter so test output is deterministic."
  (set! lam-counter 0))

(define (lam-gen-var prefix)
  "Return a fresh symbol like x42, with PREFIX as the human-readable hint."
  (set! lam-counter (+ lam-counter 1))
  (string->symbol
    (string-append prefix (number->string lam-counter))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Reserved heads (binders + connectives)
;;; ══════════════════════════════════════════════════════════════════════════

(define lam-reserved-heads '(lam app forall exists and or imp not))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Free variables
;;; ══════════════════════════════════════════════════════════════════════════

(define (lam-free-vars term)
  "Return a duplicate-free list of free variables in TERM."
  (match term
    (('lam    x body) (lset-difference eq? (lam-free-vars body) (list x)))
    (('forall x body) (lset-difference eq? (lam-free-vars body) (list x)))
    (('exists x body) (lset-difference eq? (lam-free-vars body) (list x)))
    (('app f a)       (lset-union eq? (lam-free-vars f) (lam-free-vars a)))
    (('and a b)       (lset-union eq? (lam-free-vars a) (lam-free-vars b)))
    (('or  a b)       (lset-union eq? (lam-free-vars a) (lam-free-vars b)))
    (('imp a b)       (lset-union eq? (lam-free-vars a) (lam-free-vars b)))
    (('not a)         (lam-free-vars a))
    (((? symbol? p) . args)
     (delete-duplicates (append-map lam-free-vars args)))
    ((? symbol? s) (list s))
    (_ '())))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Capture-avoiding substitution
;;;
;;; lam-subst replaces every free occurrence of VAR by VAL in BODY,
;;; α-renaming a binder's bound variable when it would otherwise capture
;;; a free variable of VAL.
;;; ══════════════════════════════════════════════════════════════════════════

(define (lam-subst var val body)
  (match body
    ((? symbol? s)
     (if (eq? s var) val s))
    (('lam y bod)    (lam-subst-binder 'lam    var val y bod))
    (('forall y bod) (lam-subst-binder 'forall var val y bod))
    (('exists y bod) (lam-subst-binder 'exists var val y bod))
    (('app f a) `(app ,(lam-subst var val f) ,(lam-subst var val a)))
    (('and a b) `(and ,(lam-subst var val a) ,(lam-subst var val b)))
    (('or  a b) `(or  ,(lam-subst var val a) ,(lam-subst var val b)))
    (('imp a b) `(imp ,(lam-subst var val a) ,(lam-subst var val b)))
    (('not a)   `(not ,(lam-subst var val a)))
    (((? symbol? p) . args)
     `(,p ,@(map (lambda (a) (lam-subst var val a)) args)))
    (_ body)))

(define (lam-subst-binder head var val bound-var bod)
  "Substitute VAR := VAL under (HEAD BOUND-VAR BOD), capture-avoiding."
  (cond
    ;; Shadowed: var is the binder's own variable; substitution stops here.
    ((eq? bound-var var)
     `(,head ,bound-var ,bod))
    ;; bound-var would capture a free variable of val: α-rename it first.
    ((memq bound-var (lam-free-vars val))
     (let* ((fresh (lam-gen-var (lam-prefix-of bound-var)))
            (renamed-bod (lam-subst bound-var fresh bod)))
       `(,head ,fresh ,(lam-subst var val renamed-bod))))
    ;; Safe: substitute directly under the binder.
    (else
     `(,head ,bound-var ,(lam-subst var val bod)))))

(define (lam-prefix-of sym)
  "Strip trailing digits from SYM's name to recover its prefix."
  (let* ((s (symbol->string sym))
         (n (string-length s)))
    (let loop ((i n))
      (cond
        ((zero? i) s)
        ((char-numeric? (string-ref s (- i 1))) (loop (- i 1)))
        (else (substring s 0 i))))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; β-reduction (one-step, leftmost-outermost)
;;;
;;; lam-beta-step performs ONE β-reduction step. Returns the reduced term,
;;; or #f if there is no redex anywhere in TERM.
;;; ══════════════════════════════════════════════════════════════════════════

(define (lam-beta-step term)
  (match term
    ;; The redex itself: (app (lam x B) A) → B[x := A]
    (('app ('lam x body) arg)
     (lam-subst x arg body))
    ;; Otherwise descend left-to-right looking for a redex.
    (('app f a)
     (let ((f* (lam-beta-step f)))
       (if f*
           `(app ,f* ,a)
           (let ((a* (lam-beta-step a)))
             (and a* `(app ,f ,a*))))))
    (('lam x body)
     (let ((b* (lam-beta-step body)))
       (and b* `(lam ,x ,b*))))
    (('forall x body)
     (let ((b* (lam-beta-step body)))
       (and b* `(forall ,x ,b*))))
    (('exists x body)
     (let ((b* (lam-beta-step body)))
       (and b* `(exists ,x ,b*))))
    (('and a b) (lam-beta-step-binary 'and a b))
    (('or  a b) (lam-beta-step-binary 'or  a b))
    (('imp a b) (lam-beta-step-binary 'imp a b))
    (('not a)
     (let ((a* (lam-beta-step a))) (and a* `(not ,a*))))
    (((? symbol? p) . args)
     (let ((args* (lam-beta-step-list args)))
       (and args* `(,p ,@args*))))
    (_ #f)))

(define (lam-beta-step-binary head a b)
  (let ((a* (lam-beta-step a)))
    (if a*
        `(,head ,a* ,b)
        (let ((b* (lam-beta-step b)))
          (and b* `(,head ,a ,b*))))))

(define (lam-beta-step-list args)
  "Try to β-step exactly one element of ARGS. Return new list, or #f."
  (let loop ((before '()) (rest args))
    (cond
      ((null? rest) #f)
      (else
       (let ((r* (lam-beta-step (car rest))))
         (if r*
             (append (reverse before) (cons r* (cdr rest)))
             (loop (cons (car rest) before) (cdr rest))))))))

(define* (lam-beta-normalize term #:optional (max-steps 1000))
  "Reduce TERM to β-normal form. Errors out after MAX-STEPS."
  (let loop ((t term) (n 0))
    (when (> n max-steps)
      (error "β-reduction did not terminate within max-steps" term))
    (let ((t* (lam-beta-step t)))
      (if t* (loop t* (+ n 1)) t))))

(define (lam-beta-trace term)
  "Return a list of TERMs: TERM, then each successive β-reduct, ending in
   the normal form. Useful for showing the reduction sequence."
  (let loop ((t term) (acc '()))
    (let ((t* (lam-beta-step t)))
      (if t*
          (loop t* (cons t acc))
          (reverse (cons t acc))))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; α-equivalence
;;;
;;; lam-alpha-equiv? walks two terms in lockstep, building a bidirectional
;;; binding map. Bound variables match if they correspond under that map;
;;; free variables (and constants) must be eq? and not be shadowed.
;;; ══════════════════════════════════════════════════════════════════════════

(define (lam-alpha-equiv? t1 t2)
  (lam-alpha-go t1 t2 '()))

(define (lam-alpha-go a b env)
  (cond
    ;; Both binders of the same kind.
    ((and (pair? a) (pair? b)
          (eq? (car a) (car b))
          (memq (car a) '(lam forall exists)))
     (lam-alpha-go (caddr a) (caddr b)
                   (cons (cons (cadr a) (cadr b)) env)))
    ;; Both applications.
    ((and (pair? a) (pair? b)
          (eq? (car a) 'app) (eq? (car b) 'app))
     (and (lam-alpha-go (cadr a) (cadr b) env)
          (lam-alpha-go (caddr a) (caddr b) env)))
    ;; Same binary connective.
    ((and (pair? a) (pair? b)
          (eq? (car a) (car b))
          (memq (car a) '(and or imp)))
     (and (lam-alpha-go (cadr a) (cadr b) env)
          (lam-alpha-go (caddr a) (caddr b) env)))
    ;; Both negations.
    ((and (pair? a) (pair? b)
          (eq? (car a) 'not) (eq? (car b) 'not))
     (lam-alpha-go (cadr a) (cadr b) env))
    ;; Same atomic predicate head.
    ((and (pair? a) (pair? b)
          (symbol? (car a)) (symbol? (car b))
          (eq? (car a) (car b))
          (not (memq (car a) lam-reserved-heads)))
     (and (= (length (cdr a)) (length (cdr b)))
          (every (lambda (x y) (lam-alpha-go x y env))
                 (cdr a) (cdr b))))
    ;; Both bare symbols.
    ((and (symbol? a) (symbol? b))
     (let ((bound (assq a env)))
       (if bound
           (eq? (cdr bound) b)
           ;; a is free on the left; b must be the same symbol AND not be
           ;; bound on the right (otherwise it would be a different variable).
           (and (eq? a b)
                (not (any (lambda (p) (eq? (cdr p) b)) env))))))
    (else (equal? a b))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Pretty printing
;;;
;;; lam-pretty renders a term using λ ∀ ∃ → ∧ ∨ ¬, in the style of BB1.
;;; ══════════════════════════════════════════════════════════════════════════

(define (lam-pretty term)
  (match term
    (('lam x body)
     (string-append "λ" (symbol->string x) "." (lam-pretty body)))
    (('app f a)
     (string-append "(" (lam-pretty f) " " (lam-pretty a) ")"))
    (('forall x body)
     (string-append "∀" (symbol->string x) "." (lam-pretty body)))
    (('exists x body)
     (string-append "∃" (symbol->string x) "." (lam-pretty body)))
    (('and a b)
     (string-append "(" (lam-pretty a) " ∧ " (lam-pretty b) ")"))
    (('or  a b)
     (string-append "(" (lam-pretty a) " ∨ " (lam-pretty b) ")"))
    (('imp a b)
     (string-append "(" (lam-pretty a) " → " (lam-pretty b) ")"))
    (('not a)
     (string-append "¬" (lam-pretty a)))
    (((? symbol? p) . args)
     (string-append (symbol->string p) "("
                    (string-join (map lam-pretty args) ",")
                    ")"))
    ((? symbol? s) (symbol->string s))
    (_ (format #f "~a" term))))
