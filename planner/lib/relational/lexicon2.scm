;;; lexicon2.scm — Declarative lexicon: words as data, not code
;;;
;;; PAIP ch.21 insight: the lexicon is DATA. Grammar rules are generic.
;;; Surface words belong here; grammar.scm never mentions specific strings.
;;;
;;; Structure:
;;;   *verb-entries*        — single words that express an intent
;;;   *question-triggers*   — multi-word phrases that open a question frame
;;;   *statement-triggers*  — multi-word phrases that open an assertion frame
;;;
;;; Each entry carries an arg-structure that tells np-args-o how to
;;; parse the following noun-phrase arguments:
;;;   qty-spec      — optional-qty  resource-name
;;;   spec          — resource-name
;;;   spec-have     — resource-name  "do" "we" "have"
;;;   spec-from     — resource-name  ("from"|"with")  resource-name
;;;   spec-src-dst  — resource-name  "from"  location  "to"  location
;;;
;;; Adding a new word / phrase:  add one row.  No grammar code changes.

(use-modules (playnet kanren-constraints))


;;; ── Verb entries ──────────────────────────────────────────────────────────
;;; Single-word verbs.  Format: (surface-word  intent  arg-structure)

(define *verb-entries*
  '(;; demand — "make bread", "produce 5 flour", "plan bread", "build 10 chairs"
    ("make"     demand      qty-spec)
    ("produce"  demand      qty-spec)
    ("plan"     demand      qty-spec)
    ("build"    demand      qty-spec)
    ("create"   demand      qty-spec)
    ("grow"     demand      qty-spec)
    ;; inventory — "stock wheat", "have flour"
    ("stock"    inventory   spec)
    ("have"     inventory   spec)
    ("store"    inventory   spec)
    ;; recipes — "show bread"  (less common, mainly via question-triggers)
    ("recipes"  recipes     spec)))

(define (verb-entry-o word intent arg-struct)
  "Relate a surface WORD to its INTENT and ARG-STRUCT via the verb lexicon."
  (in-list-o `(,word ,intent ,arg-struct) *verb-entries*))


;;; ── Question triggers ─────────────────────────────────────────────────────
;;; Multi-word phrases that open a question frame.
;;; Format: (phrase-word-list  intent  arg-structure)

(define *question-triggers*
  '(;; demand
    (("how" "do" "we" "make")          demand      qty-spec)
    (("how" "to" "make")               demand      qty-spec)
    (("how" "do" "i" "make")           demand      qty-spec)
    ;; provenance
    (("what" "is" "needed" "for")      provenance  spec)
    (("what" "goes" "into")            provenance  spec)
    (("inputs" "for")                  provenance  spec)
    (("what" "does" "it" "take" "to" "make") provenance spec)
    ;; destination
    (("what" "can" "we" "make" "from") destination spec)
    (("what" "can" "we" "make" "with") destination spec)
    (("what" "uses")                   destination spec)
    (("what" "needs")                  destination spec)
    ;; inventory
    (("how" "much")                    inventory   spec-have)
    (("inventory" "of")                inventory   spec)
    (("how" "many")                    inventory   spec-have)
    ;; recipes
    (("show" "recipes" "for")          recipes     spec)
    (("recipes" "for")                 recipes     spec)
    (("what" "recipes" "use")          recipes     spec)))

(define (question-trigger-o phrase intent arg-struct)
  "Relate a PHRASE (word list) to INTENT and ARG-STRUCT."
  (in-list-o `(,phrase ,intent ,arg-struct) *question-triggers*))


;;; ── Statement triggers ────────────────────────────────────────────────────
;;; Phrases that introduce an assertion (for `tell`).
;;; Format: (phrase-word-list  assert-type  arg-structure)

(define *statement-triggers*
  '(;; inventory assertions — "we have 200 wheat at the farm"
    (("we" "have")              assert-inventory   qty-spec-loc)
    (("there" "are")            assert-inventory   qty-spec-loc)
    (("there" "is")             assert-inventory   qty-spec-loc)
    ;; requirement assertions — "bread needs flour" / "bread requires flour"
    (("needs")                  assert-requires    spec-from-spec)
    (("requires")               assert-requires    spec-from-spec)
    ;; recipe assertions — "bread is made from flour"
    (("is" "made" "from")       assert-recipe      spec-from-spec)
    (("is" "produced" "from")   assert-recipe      spec-from-spec)))

(define (statement-trigger-o phrase assert-type arg-struct)
  "Relate a PHRASE to ASSERT-TYPE and ARG-STRUCT."
  (in-list-o `(,phrase ,assert-type ,arg-struct) *statement-triggers*))


;;; ── Spec resolution (unchanged from lexicon.scm) ──────────────────────────
;;; Re-exported here so grammar2.scm only needs to load lexicon2.

(define (spec-name-o ctx word spec-id)
  "Relate a single lowercase WORD (string) to a SPEC-ID via live facts."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (fresh ()
          (project (word)
            (let ((w (if (string? word) word (symbol->string word))))
              (let ((matches (idx-ref indexes 'specs-by-word w)))
                (if (null? matches) fail
                    (in-list-o spec-id matches))))))
        (fresh (name)
          (in-list-o `(spec-name ,spec-id ,name) (ctx-facts ctx))
          (project (name word)
            (let ((w (string-downcase
                       (if (string? word) word (symbol->string word)))))
              (if (string=? w (string-downcase name)) succeed fail)))))))

(define (spec-word-o ctx spec-id word)
  "Given ground SPEC-ID, unify WORD with its lowercase display name."
  (fresh (name)
    (in-list-o `(spec-name ,spec-id ,name) (ctx-facts ctx))
    (project (name) (== word (string-downcase name)))))

(define (location-word-o ctx loc-id word)
  "Location-id → display word. Strips 'loc-' prefix."
  (project (loc-id)
    (if (and (string? loc-id)
             (> (string-length loc-id) 4)
             (string=? "loc-" (substring loc-id 0 4)))
        (== word (substring loc-id 4))
        (== word (if (string? loc-id) loc-id "unknown")))))

(define (tokenize-phrase str)
  "Split a phrase into lowercase word tokens. Numbers become integers."
  (map (lambda (w)
         (let ((n (string->number w)))
           (or n (string-downcase w))))
       (filter (lambda (s) (not (string=? s "")))
               (string-split str #\space))))
