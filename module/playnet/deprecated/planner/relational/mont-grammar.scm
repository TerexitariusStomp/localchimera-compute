;;; mont-grammar.scm — Montague-style recursive-descent grammar
;;;
;;; Mirrors the DCG from BB1 ch.2.4 (the experiment3.pl grammar):
;;;
;;;   s  -> np vp                  sem = (app NP VP)
;;;   np -> pn                     sem = PN
;;;   np -> det noun               sem = (app DET NOUN)
;;;   vp -> iv                     sem = IV
;;;   vp -> tv np                  sem = (app TV NP)
;;;
;;; Each parser returns a (cons SEM REMAINING-TOKENS) on success, or #f.
;;; mont-parse parses a complete sentence; mont-meaning also β-normalizes.
;;;
;;; The grammar is uniform across proper names and quantified NPs because
;;; both reduce to functors of type ((e → t) → t) — the lexicon does the
;;; work, the rules just compose with (app FUNCTOR ARG).

(define-module (playnet deprecated planner relational mont-grammar)
  #:use-module (playnet deprecated planner relational lambda)
  #:use-module (playnet deprecated planner relational mont-lex)
  #:export (mont-tokenize mont-parse-pn mont-parse-noun mont-parse-iv mont-parse-tv
            mont-parse-det mont-parse-np mont-parse-vp mont-parse-s mont-parse
            mont-meaning))

(use-modules ((srfi srfi-13) #:select (string-downcase))
             ((srfi srfi-1) #:select (filter)))

(define (mont-tokenize phrase)
  "Split PHRASE into lowercase word tokens."
  (filter (lambda (s) (not (string=? s "")))
          (string-split (string-downcase phrase) #\space)))


;;; ── Terminal parsers ──────────────────────────────────────────────────────

(define (mont-parse-pn tokens)
  (and (pair? tokens)
       (let ((sem (mont-lookup-pn (car tokens))))
         (and sem (cons sem (cdr tokens))))))

(define (mont-parse-noun tokens)
  (and (pair? tokens)
       (let ((sem (mont-lookup-noun (car tokens))))
         (and sem (cons sem (cdr tokens))))))

(define (mont-parse-iv tokens)
  (and (pair? tokens)
       (let ((sem (mont-lookup-iv (car tokens))))
         (and sem (cons sem (cdr tokens))))))

(define (mont-parse-tv tokens)
  (and (pair? tokens)
       (let ((sem (mont-lookup-tv (car tokens))))
         (and sem (cons sem (cdr tokens))))))

(define (mont-parse-det tokens)
  (and (pair? tokens)
       (let ((sem (mont-lookup-det (car tokens))))
         (and sem (cons sem (cdr tokens))))))


;;; ── Phrasal parsers ───────────────────────────────────────────────────────

(define (mont-parse-np tokens)
  ;; np -> det noun  |  pn
  (or (let ((d (mont-parse-det tokens)))
        (and d
             (let ((n (mont-parse-noun (cdr d))))
               (and n
                    (cons `(app ,(car d) ,(car n)) (cdr n))))))
      (mont-parse-pn tokens)))

(define (mont-parse-vp tokens)
  ;; vp -> tv np  |  iv
  (or (let ((tv (mont-parse-tv tokens)))
        (and tv
             (let ((np (mont-parse-np (cdr tv))))
               (and np
                    (cons `(app ,(car tv) ,(car np)) (cdr np))))))
      (mont-parse-iv tokens)))

(define (mont-parse-s tokens)
  ;; s -> np vp
  (let ((np (mont-parse-np tokens)))
    (and np
         (let ((vp (mont-parse-vp (cdr np))))
           (and vp
                (cons `(app ,(car np) ,(car vp)) (cdr vp)))))))


;;; ── Entry points ──────────────────────────────────────────────────────────

(define (mont-parse phrase)
  "Parse PHRASE into a raw (un-reduced) λ-term, or #f if it doesn't parse.
   The phrase must consume all tokens to count as a successful parse."
  (let* ((tokens (mont-tokenize phrase))
         (result (mont-parse-s tokens)))
    (and result
         (null? (cdr result))
         (car result))))

(define (mont-meaning phrase)
  "Parse PHRASE and β-normalize. Returns the normal-form formula, or #f."
  (let ((raw (mont-parse phrase)))
    (and raw (lam-beta-normalize raw))))
