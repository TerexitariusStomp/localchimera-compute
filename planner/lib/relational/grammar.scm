;;; grammar.scm — Relational query grammar (miniKanren DCG)
;;;
;;; Difference-list style, following PAIP ch.20: each rule relates an input
;;; word list S0 to a remainder S and a semantic MEANING. Bidirectional —
;;; ground the words to parse, ground the meaning to generate.
;;;
;;; The grammar is organized in layers:
;;;   terminals → noun phrases → question frames → top-level query

(use-modules (playnet kanren-constraints)
             (ice-9 match))


;;; ── Terminals ──────────────────────────────────────────────────────────────

(define (word-o w s0 s)
  "Consume literal word W from the head of S0, leaving S."
  (== s0 (cons w s)))

(define (words-o ws s0 s)
  "Consume a fixed sequence of words WS from S0."
  (if (null? ws)
      (== s0 s)
      (fresh (s1)
        (word-o (car ws) s0 s1)
        (words-o (cdr ws) s1 s))))


;;; ── Noun phrases ───────────────────────────────────────────────────────────

(define (spec-np-o ctx s0 s spec-id)
  "Parse/generate a resource name — single word resolved against live facts."
  (fresh (word)
    (word-o word s0 s)
    (spec-name-o ctx word spec-id)))

(define (qty-np-o s0 s qty)
  "Parse/generate a quantity — a number token."
  (fresh (token)
    (word-o token s0 s)
    (project (token)
      (if (number? token) (== qty token) fail))))

(define (qty-spec-np-o ctx s0 s qty spec-id)
  "Match '<qty> <spec>' or just '<spec>' (qty left fresh if absent)."
  (conde
    ((fresh (s1)
       (qty-np-o s0 s1 qty)
       (spec-np-o ctx s1 s spec-id)))
    ((spec-np-o ctx s0 s spec-id))))


;;; ── Question frames ────────────────────────────────────────────────────────
;;; Each frame consumes a phrase pattern and produces a (query-type . args).

(define (demand-question-o ctx s0 s goal)
  "Parse: 'how do we make 10 bread' | 'make bread' | 'produce 5 flour'"
  (fresh (qty spec-id s1)
    (conde
      ((words-o '("how" "do" "we" "make") s0 s1))
      ((words-o '("how" "to" "make") s0 s1))
      ((word-o "make" s0 s1))
      ((word-o "plan" s0 s1))
      ((word-o "produce" s0 s1)))
    (qty-spec-np-o ctx s1 s qty spec-id)
    (== goal `(demand ,spec-id ,qty))))

(define (provenance-question-o ctx s0 s goal)
  "Parse: 'what is needed for flour' | 'what goes into bread'"
  (fresh (spec-id s1)
    (conde
      ((words-o '("what" "is" "needed" "for") s0 s1))
      ((words-o '("what" "goes" "into") s0 s1))
      ((words-o '("inputs" "for") s0 s1)))
    (spec-np-o ctx s1 s spec-id)
    (== goal `(provenance ,spec-id))))

(define (destination-question-o ctx s0 s goal)
  "Parse: 'what can we make from wheat' | 'what uses wheat'"
  (fresh (spec-id s1)
    (conde
      ((words-o '("what" "can" "we" "make" "from") s0 s1))
      ((words-o '("what" "can" "we" "make" "with") s0 s1))
      ((words-o '("what" "uses") s0 s1)))
    (spec-np-o ctx s1 s spec-id)
    (== goal `(destination ,spec-id))))

(define (inventory-question-o ctx s0 s goal)
  "Parse: 'how much wheat do we have' | 'inventory of wheat'"
  (fresh (spec-id s1 s2)
    (conde
      ((words-o '("how" "much") s0 s1)
       (spec-np-o ctx s1 s2 spec-id)
       (words-o '("do" "we" "have") s2 s))
      ((words-o '("inventory" "of") s0 s1)
       (spec-np-o ctx s1 s spec-id))
      ((word-o "stock" s0 s1)
       (spec-np-o ctx s1 s spec-id)))
    (== goal `(inventory ,spec-id))))

(define (recipe-question-o ctx s0 s goal)
  "Parse: 'show recipes for bread' | 'recipes for bread'"
  (fresh (spec-id s1)
    (conde
      ((words-o '("show" "recipes" "for") s0 s1))
      ((words-o '("recipes" "for") s0 s1)))
    (spec-np-o ctx s1 s spec-id)
    (== goal `(recipes ,spec-id))))


;;; ── Top-level query ────────────────────────────────────────────────────────
;;; conde ordering provides implicit preference (earlier = higher priority).

(define (query-o ctx s0 s goal)
  "The union of all question frames."
  (conde
    ((demand-question-o ctx s0 s goal))
    ((inventory-question-o ctx s0 s goal))
    ((provenance-question-o ctx s0 s goal))
    ((destination-question-o ctx s0 s goal))
    ((recipe-question-o ctx s0 s goal))))


;;; ── Entry points (ground helpers) ──────────────────────────────────────────

(define (parse-query ctx phrase)
  "Parse a natural language phrase into a list of planning goals."
  (let ((tokens (tokenize-phrase phrase)))
    (run-plan* '() (goal)
      (query-o ctx tokens '() goal))))

(define (execute-query ctx goal due)
  "Dispatch a parsed goal to the appropriate planning relation."
  (match goal
    (('demand spec-id qty)
     (let ((q (if (number? qty) qty 1)))
       (run-plan 3 '() (plan)
         (demand-o ctx spec-id q due plan))))
    (('provenance spec-id)
     (run-plan* '() (q)
       (fresh (ancestor trace)
         (provenance-o (ctx-facts ctx) spec-id ancestor trace)
         (== q `(needs ,ancestor ,trace)))))
    (('destination spec-id)
     (run-plan* '() (q)
       (fresh (downstream trace)
         (destination-o (ctx-facts ctx) spec-id downstream trace)
         (== q `(produces ,downstream ,trace)))))
    (('inventory spec-id)
     (run-plan* '() (q)
       (fresh (rid qty loc)
         (fact-inventory-o ctx rid spec-id qty loc)
         (== q `(stock ,qty ,loc)))))
    (('recipes spec-id)
     (run-plan* '() (q)
       (fresh (rid name)
         (fact-recipe-o ctx rid name spec-id)
         (== q `(recipe ,rid ,name)))))))

(define* (ask ctx phrase #:optional (due #f))
  "Parse a natural language phrase, execute it, and narrate the results.
   Returns a human-readable string. The full pipeline:
   phrase → tokens → goal → plan-terms → narration."
  (let ((goals (parse-query ctx phrase)))
    (if (null? goals)
        (string-append "I don't understand: " phrase "\n")
        (let* ((goal (car goals))
               (results (execute-query ctx goal due)))
          (narrate-query-result ctx goal results)))))
