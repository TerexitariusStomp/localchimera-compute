;;; grammar2.scm — Relational utterance grammar (DCG, lexicon-driven)
;;;
;;; PAIP ch.11 (uniform database) + ch.20 (DCG) + ch.21 (lexicon as data).
;;;
;;; Differences from grammar.scm:
;;;
;;;   1. define-dcg-rule / define-dcg-rules auto-threads s0/s.
;;;      No manual fresh + threading in any rule.
;;;
;;;   2. *verb-entries* and *question-triggers* in lexicon2.scm own all
;;;      surface words. Grammar rules are generic: adding a new verb or
;;;      question phrase = one row in the lexicon, zero grammar changes.
;;;
;;;   3. Covers QUESTIONS and STATEMENTS via utterance-o.
;;;      ask2 and tell are symmetric entry points.
;;;
;;;   4. np-args-o is the single dispatch point for argument structures.
;;;      New argument patterns: add one conde branch there.
;;;
;;; Layers (PAIP ch.20 convention):
;;;   terminals → NP rules → frame rules → utterance-o → entry points

(use-modules (playnet kanren-constraints)
             (srfi srfi-1)
             (ice-9 match))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Terminals
;;; ══════════════════════════════════════════════════════════════════════════

(define (word-o w s0 s)
  "Consume literal word W from head of S0, leaving S."
  (== s0 (cons w s)))

(define (words-o ws s0 s)
  "Consume fixed sequence WS from S0."
  (if (null? ws)
      (== s0 s)
      (fresh (s1)
        (word-o (car ws) s0 s1)
        (words-o (cdr ws) s1 s))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Noun-phrase terminals
;;; These are regular relations (not DCG rules) so they compose cleanly
;;; as non-terminals inside define-dcg-rule bodies.
;;; ══════════════════════════════════════════════════════════════════════════

(define (spec-np ctx spec-id s0 s)
  "Consume one word token and resolve it to a SPEC-ID via live facts."
  (fresh (word)
    (word-o word s0 s)
    (spec-name-o ctx word spec-id)))

(define (qty-np qty s0 s)
  "Consume one number token and unify it with QTY."
  (fresh (token)
    (word-o token s0 s)
    (project (token)
      (if (number? token) (== qty token) fail))))

;;; qty-spec-np: optional quantity then resource name
;;; Uses define-dcg-rules so each alternative is a declared shape.
(define-dcg-rules (qty-spec-np ctx qty spec-id)
  ;; "<qty> <spec>"
  ((qty-np qty)
   (spec-np ctx spec-id))
  ;; "<spec>" alone — qty stays unbound
  ((spec-np ctx spec-id)))

;;; location-np: consume a word and try to match it to a known location
(define (location-np ctx loc-id s0 s)
  "Consume one word and resolve it to a location id.
   Accepts bare location names (strips the 'loc-' prefix)."
  (fresh (word)
    (word-o word s0 s)
    (project (word)
      (let ((candidate (string-append "loc-" word)))
        ;; check whether any inventory fact has this location
        (if (any (lambda (f)
                   (and (eq? (car f) 'inventory)
                        (equal? (cadr f) candidate)))
                 (ctx-facts ctx))
            (== loc-id candidate)
            fail)))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Argument-structure dispatcher
;;;
;;; np-args-o reads the arg-structure from the lexicon and decides which
;;; noun phrases to parse and how to assemble the semantic goal.
;;; This is the SINGLE place where argument patterns are defined.
;;; Adding a new pattern: one new conde branch.
;;; ══════════════════════════════════════════════════════════════════════════

(define (np-args-o ctx s0 s intent arg-struct goal)
  (conde

    ;; qty-spec — optional quantity then resource name
    ;; e.g. "10 bread" | "bread"
    ((== arg-struct 'qty-spec)
     (fresh (qty spec-id)
       (qty-spec-np ctx qty spec-id s0 s)
       (== goal `(,intent ,spec-id ,qty))))

    ;; spec — bare resource name
    ;; e.g. "flour"
    ((== arg-struct 'spec)
     (fresh (spec-id)
       (spec-np ctx spec-id s0 s)
       (== goal `(,intent ,spec-id))))

    ;; spec-have — resource name followed by "do we have" tail
    ;; e.g. (after "how much") "wheat do we have"
    ((== arg-struct 'spec-have)
     (fresh (spec-id s1)
       (spec-np ctx spec-id s0 s1)
       (words-o '("do" "we" "have") s1 s)
       (== goal `(,intent ,spec-id))))

    ;; spec-from-spec — two resource names in sequence
    ;; e.g. "flour wheat" (after SVO verb, caller provides first spec)
    ((== arg-struct 'spec-from-spec)
     (fresh (spec1 spec2 s1)
       (spec-np ctx spec1 s0 s1)
       (spec-np ctx spec2 s1 s)
       (== goal `(,intent ,spec1 ,spec2))))

    ;; qty-spec-loc — quantity, resource, "at", location
    ;; e.g. "200 wheat at farm"
    ((== arg-struct 'qty-spec-loc)
     (fresh (qty spec-id loc-id s1 s2 s3)
       (qty-spec-np ctx qty spec-id s0 s1)
       (word-o "at" s1 s2)
       (location-np ctx loc-id s2 s)
       (== goal `(,intent ,spec-id ,qty ,loc-id))))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Frame rules
;;; Each frame type queries the lexicon for triggers and dispatches to np-args-o.
;;; ══════════════════════════════════════════════════════════════════════════

;;; question-trigger-frame: multi-word trigger then NP arguments
;;; e.g. "what is needed for" (flour)  → (provenance "spec-flour")
(define (question-trigger-frame-o ctx s0 s goal)
  (fresh (trigger intent arg-struct s1)
    (question-trigger-o trigger intent arg-struct)
    (words-o trigger s0 s1)
    (np-args-o ctx s1 s intent arg-struct goal)))

;;; verb-frame: single verb word then NP arguments
;;; e.g. "make" (10 bread) → (demand "spec-bread" 10)
(define (verb-frame-o ctx s0 s goal)
  (fresh (word intent arg-struct s1)
    (word-o word s0 s1)
    (verb-entry-o word intent arg-struct)
    (np-args-o ctx s1 s intent arg-struct goal)))

;;; statement-trigger-frame: assertion trigger then NP arguments
;;; e.g. "we have" (200 wheat at farm) → (assert-inventory "spec-wheat" 200 "loc-farm")
(define (statement-trigger-frame-o ctx s0 s goal)
  (fresh (trigger assert-type arg-struct s1)
    (statement-trigger-o trigger assert-type arg-struct)
    (words-o trigger s0 s1)
    (np-args-o ctx s1 s assert-type arg-struct goal)))

;;; svo-frame: Subject-Verb-Object assertions
;;; e.g. "bread needs flour" → (assert-requires "spec-bread" "spec-flour")
;;; The subject NP is parsed BEFORE the verb, so np-args-o can't handle it.
;;; Here we look up the verb in statement-triggers with a single-word phrase.
(define (svo-frame-o ctx s0 s goal)
  (fresh (spec1 verb assert-type s1 s2 spec2)
    (spec-np ctx spec1 s0 s1)                      ;; subject
    (word-o verb s1 s2)                             ;; verb
    (statement-trigger-o (list verb) assert-type 'spec-from-spec)
    (spec-np ctx spec2 s2 s)                        ;; object
    (== goal `(,assert-type ,spec1 ,spec2))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Top-level utterance relation
;;; ══════════════════════════════════════════════════════════════════════════

(define (question-o ctx s0 s goal)
  "Any question: trigger-led or verb-led."
  (conde
    ((question-trigger-frame-o ctx s0 s goal))
    ((verb-frame-o             ctx s0 s goal))))

(define (statement-o ctx s0 s goal)
  "Any statement/assertion: trigger-led or SVO."
  (conde
    ((statement-trigger-frame-o ctx s0 s goal))
    ((svo-frame-o               ctx s0 s goal))))

(define (utterance-o ctx s0 s goal)
  "The union of all question and statement frames.
   Ground s0 to parse; ground goal to enumerate matching phrases."
  (conde
    ((question-o  ctx s0 s goal))
    ((statement-o ctx s0 s goal))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Entry points
;;; ══════════════════════════════════════════════════════════════════════════

(define (parse-utterance ctx phrase)
  "Parse PHRASE into a list of semantic goals. Returns '() if none match."
  (let ((tokens (tokenize-phrase phrase)))
    (run-plan* '() (goal)
      (utterance-o ctx tokens '() goal))))

(define (execute-goal ctx goal due)
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
         (== q `(recipe ,rid ,name)))))
    ;; Assertion goals: execution is handled by the caller via tell
    (('assert-inventory . _) '())
    (('assert-requires  . _) '())
    (('assert-recipe    . _) '())
    (_ '())))

(define* (ask2 ctx phrase #:optional (due #f))
  "Parse any question or statement, execute, and narrate.
   Pipeline: phrase → tokens → goal → plan-terms → narration string."
  (let ((goals (parse-utterance ctx phrase)))
    (if (null? goals)
        (string-append "I don't understand: " phrase "\n")
        (let* ((goal    (car goals))
               (results (execute-goal ctx goal due)))
          (narrate-query-result ctx goal results)))))

(define (tell ctx phrase)
  "Parse PHRASE as a statement and return its assertion goal s-expression.
   Returns #f if the phrase is not a recognizable statement.
   The caller is responsible for applying the assertion to the world model."
  (let ((goals (run-plan* '() (goal)
                 (statement-o ctx (tokenize-phrase phrase) '() goal))))
    (and (pair? goals) (car goals))))
