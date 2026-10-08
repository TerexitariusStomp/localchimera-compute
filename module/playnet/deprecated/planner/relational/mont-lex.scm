;;; mont-lex.scm — Montague-style lexicon
;;;
;;; Each lookup function returns a FRESH λ-term (with fresh bound variables)
;;; on every call. This mirrors how Prolog DCG rules in BB1 introduce fresh
;;; logic variables on each invocation.
;;;
;;; Lexicon types follow Blackburn & Bos ch.2.4:
;;;
;;;   PN  — proper name:    λP.(P @ NAME)
;;;   N   — common noun:    λx.PRED(x)
;;;   IV  — intransitive:   λx.PRED(x)
;;;   TV  — transitive:     λW.λZ.(W @ λx.PRED(Z,x))
;;;                         takes object NP first, then subject NP
;;;   DET — determiner:     λU.λV.<quantifier-shape>
;;;
;;; Returns #f when the word is not in the lexicon.

;;; ══════════════════════════════════════════════════════════════════════════
;;; Lexical schemata
;;; ══════════════════════════════════════════════════════════════════════════

(define-module (playnet deprecated planner relational mont-lex)
  #:use-module (playnet deprecated planner relational lambda)
  #:export (mont-lex-pn mont-lex-noun mont-lex-iv mont-lex-tv mont-lex-det-every
            mont-lex-det-a mont-lex-det-no *mont-proper-names* *mont-nouns*
            *mont-intransitive-verbs* *mont-transitive-verbs* *mont-determiners*
            mont-lookup-pn mont-lookup-noun mont-lookup-iv mont-lookup-tv
            mont-lookup-det))

(define (mont-lex-pn name)
  "Proper name λP.(P @ NAME)."
  (let ((p (lam-gen-var "P")))
    `(lam ,p (app ,p ,name))))

(define (mont-lex-noun pred)
  "Common noun λx.PRED(x)."
  (let ((x (lam-gen-var "x")))
    `(lam ,x (,pred ,x))))

(define (mont-lex-iv pred)
  "Intransitive verb λx.PRED(x)."
  (let ((x (lam-gen-var "x")))
    `(lam ,x (,pred ,x))))

(define (mont-lex-tv pred)
  "Transitive verb λW.λZ.(W @ λx.PRED(Z,x)) — object NP first, then subject."
  (let ((w (lam-gen-var "W"))
        (z (lam-gen-var "Z"))
        (x (lam-gen-var "x")))
    `(lam ,w (lam ,z (app ,w (lam ,x (,pred ,z ,x)))))))

(define (mont-lex-det-every)
  "every: λU.λV.∀x.(U@x → V@x)"
  (let ((u (lam-gen-var "U"))
        (v (lam-gen-var "V"))
        (x (lam-gen-var "x")))
    `(lam ,u (lam ,v (forall ,x (imp (app ,u ,x) (app ,v ,x)))))))

(define (mont-lex-det-a)
  "a / some: λU.λV.∃x.(U@x ∧ V@x)"
  (let ((u (lam-gen-var "U"))
        (v (lam-gen-var "V"))
        (x (lam-gen-var "x")))
    `(lam ,u (lam ,v (exists ,x (and (app ,u ,x) (app ,v ,x)))))))

(define (mont-lex-det-no)
  "no: λU.λV.¬∃x.(U@x ∧ V@x)"
  (let ((u (lam-gen-var "U"))
        (v (lam-gen-var "V"))
        (x (lam-gen-var "x")))
    `(lam ,u (lam ,v (not (exists ,x (and (app ,u ,x) (app ,v ,x))))))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Word tables
;;; ══════════════════════════════════════════════════════════════════════════

(define *mont-proper-names*
  ;; People are proper names. Resource words (bread, flour, wheat) are also
  ;; proper names because in the planner they denote unique resource specs,
  ;; not predicates over individuals — "make bread" means make THE resource
  ;; spec bread, not "make some thing that is a piece of bread".
  '(("vincent"   . vincent)
    ("mia"       . mia)
    ("butch"     . butch)
    ("marcellus" . marcellus)
    ("bread"     . bread)
    ("flour"     . flour)
    ("wheat"     . wheat)))

(define *mont-nouns*
  '(("man"     . man)
    ("woman"   . woman)
    ("boxer"   . boxer)
    ("commune" . commune)
    ("farmer"  . farmer)
    ("factory" . factory)
    ("worker"  . worker)))

(define *mont-intransitive-verbs*
  '(("walks"  . walk)
    ("snorts" . snort)
    ("runs"   . run)
    ("works"  . work)))

(define *mont-transitive-verbs*
  '(("loves"    . love)
    ("likes"    . like)
    ("hates"    . hate)
    ("makes"    . make)
    ("produces" . produce)
    ("grows"    . grow)
    ("needs"    . need)
    ("uses"     . use)))

(define *mont-determiners*
  `(("every" . ,mont-lex-det-every)
    ("a"     . ,mont-lex-det-a)
    ("an"    . ,mont-lex-det-a)
    ("some"  . ,mont-lex-det-a)
    ("no"    . ,mont-lex-det-no)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Lookup helpers (return a fresh λ-term, or #f)
;;; ══════════════════════════════════════════════════════════════════════════

(define (mont-lookup-pn word)
  (let ((p (assoc word *mont-proper-names*)))
    (and p (mont-lex-pn (cdr p)))))

(define (mont-lookup-noun word)
  (let ((p (assoc word *mont-nouns*)))
    (and p (mont-lex-noun (cdr p)))))

(define (mont-lookup-iv word)
  (let ((p (assoc word *mont-intransitive-verbs*)))
    (and p (mont-lex-iv (cdr p)))))

(define (mont-lookup-tv word)
  (let ((p (assoc word *mont-transitive-verbs*)))
    (and p (mont-lex-tv (cdr p)))))

(define (mont-lookup-det word)
  (let ((p (assoc word *mont-determiners*)))
    (and p ((cdr p)))))
