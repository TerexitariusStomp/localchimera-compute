;;; grammar3.scm — Relational utterance grammar: table + interpreter
;;;
;;; PAIP ch.2 (rule-based generation) + ch.11 (uniform DB) +
;;; ch.20 (DCG) + ch.21 (subcategorization frames as data).
;;;
;;; The grammar IS the table. One interpreter runs all of it.
;;;
;;; Compared to grammar.scm:
;;;   grammar.scm  — 5 hardcoded question functions, no statements
;;;   grammar2.scm — 3 tables, 4 frame functions, np-args-o dispatch
;;;   grammar3.scm — 1 table, 1 interpreter, utterance-o is 3 lines
;;;
;;; Adding a new utterance form: one row in *utterances*.
;;; Adding a new constituent type: one cond branch in match-pattern-o.
;;; utterance-o never changes.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1)
             (ice-9 match))


;;; ══════════════════════════════════════════════════════════════════════════
;;; *utterances* — the entire grammar as data
;;;
;;; Format: (surface-pattern  goal-template)
;;;
;;; surface-pattern slots:
;;;   "word"  — literal word to consume (not collected into goal)
;;;   :spec   — one resource name (first or only)
;;;   :spec2  — second resource name (SVO patterns)
;;;   :qty    — one required number
;;;   :?qty   — optional number (absent → #f in goal)
;;;   :loc    — one location name
;;;   :?loc   — optional "at" + location (absent → #f in goal)
;;;
;;; goal-template: (intent slot ...)
;;;   intent  — goal head symbol
;;;   :spec :spec2 :qty :loc — substituted with parsed value, or #f if absent
;;; ══════════════════════════════════════════════════════════════════════════

(define *utterances*
  '(;; ── demand ──────────────────────────────────────────────────────────
    (("make"    :?qty :spec)             (demand :spec :qty))
    (("produce" :?qty :spec)             (demand :spec :qty))
    (("plan"    :?qty :spec)             (demand :spec :qty))
    (("build"   :?qty :spec)             (demand :spec :qty))
    (("create"  :?qty :spec)             (demand :spec :qty))
    (("grow"    :?qty :spec)             (demand :spec :qty))
    (("harvest" :?qty :spec)             (demand :spec :qty))
    (("how" "do" "we" "make"  :?qty :spec)  (demand :spec :qty))
    (("how" "to" "make"       :?qty :spec)  (demand :spec :qty))
    (("how" "do" "i" "make"   :?qty :spec)  (demand :spec :qty))
    ;; ── inventory ───────────────────────────────────────────────────────
    (("how" "much" :spec "do" "we" "have")  (inventory :spec))
    (("how" "many" :spec "do" "we" "have")  (inventory :spec))
    (("how" "much" :spec "is" "there")      (inventory :spec))
    (("inventory" "of" :spec)               (inventory :spec))
    (("stock" :spec)                        (inventory :spec))
    ;; ── provenance ──────────────────────────────────────────────────────
    (("what" "is" "needed" "for"             :spec)  (provenance :spec))
    (("what" "goes" "into"                   :spec)  (provenance :spec))
    (("inputs" "for"                         :spec)  (provenance :spec))
    (("what" "does" "it" "take" "to" "make" :spec)  (provenance :spec))
    ;; ── destination ─────────────────────────────────────────────────────
    (("what" "can" "we" "make" "from" :spec)  (destination :spec))
    (("what" "can" "we" "make" "with" :spec)  (destination :spec))
    (("what" "uses"                   :spec)  (destination :spec))
    (("what" "needs"                  :spec)  (destination :spec))
    ;; ── recipes ─────────────────────────────────────────────────────────
    (("show" "recipes" "for"    :spec)  (recipes :spec))
    (("recipes" "for"           :spec)  (recipes :spec))
    (("what" "recipes" "use"    :spec)  (recipes :spec))
    ;; ── assertions: phrase-led ───────────────────────────────────────────
    (("we" "have"    :?qty :spec :?loc)  (assert-inventory :spec :qty :loc))
    (("there" "are"  :?qty :spec :?loc)  (assert-inventory :spec :qty :loc))
    (("there" "is"   :?qty :spec :?loc)  (assert-inventory :spec :qty :loc))
    ;; ── assertions: SVO (subject-verb-object) ────────────────────────────
    ((:spec "needs"            :spec2)   (assert-requires :spec :spec2))
    ((:spec "requires"         :spec2)   (assert-requires :spec :spec2))
    ((:spec "is" "made" "from" :spec2)   (assert-recipe   :spec :spec2))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Terminals
;;; ══════════════════════════════════════════════════════════════════════════

(define (word-o w s0 s)
  (== s0 (cons w s)))

(define (spec-np ctx spec-id s0 s)
  "Consume one word and resolve it to a resource spec-id."
  (fresh (word)
    (word-o word s0 s)
    (spec-name-o ctx word spec-id)))

(define (qty-np qty s0 s)
  "Consume one number token."
  (fresh (token)
    (word-o token s0 s)
    (project (token)
      (if (number? token) (== qty token) fail))))

(define (location-np ctx loc-id s0 s)
  "Consume one word and resolve it to a location id (strips 'loc-' prefix)."
  (fresh (word)
    (word-o word s0 s)
    (project (word)
      (let ((candidate (string-append "loc-" word)))
        (if (any (lambda (f)
                   (and (eq? (car f) 'inventory)
                        (equal? (cadr f) candidate)))
                 (ctx-facts ctx))
            (== loc-id candidate)
            fail)))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; match-pattern-o — the interpreter
;;;
;;; Walks PATTERN against the word stream S0 → S.
;;; Collects slot values into BINDINGS: an alist of (slot-keyword . value).
;;; Literal strings are consumed but not added to bindings.
;;; Optional slots leave no binding if absent.
;;;
;;; PATTERN is ground (comes from *utterances*) so cond dispatch is clean.
;;; ══════════════════════════════════════════════════════════════════════════

(define (match-pattern-o ctx pattern bindings s0 s)
  (if (null? pattern)
      (fresh () (== s0 s) (== bindings '()))
      (let ((elem (car pattern))
            (rest (cdr pattern)))
        (cond

          ;; "literal" — consume word, don't collect
          ((string? elem)
           (fresh (s1)
             (word-o elem s0 s1)
             (match-pattern-o ctx rest bindings s1 s)))

          ;; :spec — required resource name
          ((eq? elem ':spec)
           (fresh (v s1 more)
             (spec-np ctx v s0 s1)
             (match-pattern-o ctx rest more s1 s)
             (== bindings (cons (cons ':spec v) more))))

          ;; :spec2 — second resource name (SVO)
          ((eq? elem ':spec2)
           (fresh (v s1 more)
             (spec-np ctx v s0 s1)
             (match-pattern-o ctx rest more s1 s)
             (== bindings (cons (cons ':spec2 v) more))))

          ;; :qty — required number
          ((eq? elem ':qty)
           (fresh (v s1 more)
             (qty-np v s0 s1)
             (match-pattern-o ctx rest more s1 s)
             (== bindings (cons (cons ':qty v) more))))

          ;; :?qty — optional number; absent → no :qty binding
          ((eq? elem ':?qty)
           (conde
             ((fresh (v s1 more)
                (qty-np v s0 s1)
                (match-pattern-o ctx rest more s1 s)
                (== bindings (cons (cons ':qty v) more))))
             ((match-pattern-o ctx rest bindings s0 s))))

          ;; :loc — required location
          ((eq? elem ':loc)
           (fresh (v s1 more)
             (location-np ctx v s0 s1)
             (match-pattern-o ctx rest more s1 s)
             (== bindings (cons (cons ':loc v) more))))

          ;; :?loc — optional "at" + location; absent → no :loc binding
          ((eq? elem ':?loc)
           (conde
             ((fresh (v s1 s2 more)
                (word-o "at" s0 s1)
                (location-np ctx v s1 s2)
                (match-pattern-o ctx rest more s2 s)
                (== bindings (cons (cons ':loc v) more))))
             ((match-pattern-o ctx rest bindings s0 s))))

          (else fail)))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; assemble-goal-o — build the goal from template + bindings
;;;
;;; Substitutes each slot keyword in TEMPLATE with its value from BINDINGS.
;;; Absent optional slots become #f.
;;; TEMPLATE is ground; BINDINGS is ground after match-pattern-o resolves.
;;; ══════════════════════════════════════════════════════════════════════════

(define (slot-keyword? sym)
  "True if SYM is a slot keyword (:spec, :qty, :loc, :spec2)."
  (and (symbol? sym)
       (let ((s (symbol->string sym)))
         (and (> (string-length s) 0)
              (char=? #\: (string-ref s 0))))))

(define (assemble-goal-o template bindings goal)
  (project (template bindings)
    (== goal
        (map (lambda (elem)
               (if (slot-keyword? elem)
                   (let ((entry (assq elem bindings)))
                     (if entry (cdr entry) #f))
                   elem))
             template))))


;;; ══════════════════════════════════════════════════════════════════════════
;;; utterance-o — the grammar (3 lines)
;;; ══════════════════════════════════════════════════════════════════════════

(define (utterance-o ctx s0 s goal)
  (fresh (pattern template bindings)
    (in-list-o `(,pattern ,template) *utterances*)
    (match-pattern-o ctx pattern bindings s0 s)
    (assemble-goal-o template bindings goal)))


;;; ══════════════════════════════════════════════════════════════════════════
;;; Entry points
;;; ══════════════════════════════════════════════════════════════════════════

(define (parse-utterance3 ctx phrase)
  "Parse PHRASE into a list of semantic goals. Returns '() if none match."
  (let ((tokens (tokenize-phrase phrase)))
    (run-plan* '() (goal)
      (utterance-o ctx tokens '() goal))))

(define (execute-goal3 ctx goal due)
  "Execute a grammar3 goal against the planning relations.
   Goal format: (intent arg ...) where absent optional slots are #f."
  (match goal
    ;; demand: spec-id required, qty optional (#f → default 1)
    ((list 'demand spec-id qty)
     (let ((q (if (and qty (number? qty)) qty 1)))
       (run-plan 3 '() (plan)
         (demand-o ctx spec-id q due plan))))
    ;; single-spec queries
    ((list 'inventory spec-id)
     (run-plan* '() (q)
       (fresh (rid qty loc)
         (fact-inventory-o ctx rid spec-id qty loc)
         (== q `(stock ,qty ,loc)))))
    ((list 'provenance spec-id)
     (run-plan* '() (q)
       (fresh (ancestor trace)
         (provenance-o (ctx-facts ctx) spec-id ancestor trace)
         (== q `(needs ,ancestor ,trace)))))
    ((list 'destination spec-id)
     (run-plan* '() (q)
       (fresh (downstream trace)
         (destination-o (ctx-facts ctx) spec-id downstream trace)
         (== q `(produces ,downstream ,trace)))))
    ((list 'recipes spec-id)
     (run-plan* '() (q)
       (fresh (rid name)
         (fact-recipe-o ctx rid name spec-id)
         (== q `(recipe ,rid ,name)))))
    ;; assertion goals: not executed here (tell3 handles them)
    (_ '())))

(define (narrate-goal3 ctx goal results)
  "Bridge grammar3 goal format to narrate-query-result.
   Reshapes (demand spec qty-or-#f) to (demand spec qty) for the narrator."
  (match goal
    ((list 'demand spec-id qty)
     (narrate-query-result ctx `(demand ,spec-id ,(or qty 1)) results))
    (_ (narrate-query-result ctx goal results))))

(define* (ask3 ctx phrase #:optional (due #f))
  "Parse any question or statement, execute it, and narrate.
   Full pipeline: phrase → tokens → utterance-o → goal → results → narration."
  (let ((goals (parse-utterance3 ctx phrase)))
    (if (null? goals)
        (string-append "I don't understand: " phrase "\n")
        (let* ((goal    (car goals))
               (results (execute-goal3 ctx goal due)))
          (narrate-goal3 ctx goal results)))))

(define (tell3 ctx phrase)
  "Parse PHRASE and return the assertion goal if it is one, otherwise #f.
   Caller is responsible for applying the assertion to the world model."
  (let ((goals (parse-utterance3 ctx phrase)))
    (and (pair? goals)
         (let ((goal (car goals)))
           (and (pair? goal)
                (memq (car goal) '(assert-inventory assert-requires assert-recipe))
                goal)))))
