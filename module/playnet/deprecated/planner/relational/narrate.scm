;;; narrate.scm — Plan-term narration via relational grammar
;;;
;;; The explanation direction: relate plan-terms to word lists.
;;; Bidirectional — ground the plan-term to generate words,
;;; or ground the words to infer what plan-term they describe.

(define-module (playnet deprecated planner relational narrate)
  #:use-module (playnet deprecated planner relational planning-facts)
  #:use-module (playnet deprecated planner relational lexicon)
  #:use-module (ice-9 match)
  #:export (narrate-o narrate-satisfied-o narrate-produce-o narrate-transport-o
            narrate-unmet-o narrate-plan narrate-plan-tree narrate-sub-plans
            narrate-query-result))

(use-modules (playnet deprecated kanren-constraints))


;;; ── Narration relations ────────────────────────────────────────────────────

(define (narrate-o ctx plan-term s0 s)
  "Relate a plan-term to a difference-list of words."
  (conde
    ((narrate-satisfied-o ctx plan-term s0 s))
    ((narrate-produce-o ctx plan-term s0 s))
    ((narrate-transport-o ctx plan-term s0 s))
    ((narrate-unmet-o ctx plan-term s0 s))))

(define (narrate-satisfied-o ctx plan-term s0 s)
  "'use 50 wheat from farm inventory'"
  (fresh (spec-id qty allocated loc spec-word loc-word)
    (== plan-term `(satisfied ,spec-id ,qty ,allocated ,loc))
    (spec-word-o ctx spec-id spec-word)
    (location-word-o ctx loc loc-word)
    (project (allocated spec-word loc-word)
      (== s0 `("use" ,(number->string allocated) ,spec-word
               "from" ,loc-word "inventory" . ,s)))))

(define (narrate-produce-o ctx plan-term s0 s)
  "'produce bread at scale 2 via bread production'"
  (fresh (spec-id rid scale consume use cite)
    (== plan-term `(produce ,spec-id ,rid ,scale ,consume ,use ,cite))
    ;; project plan-term fields so fact-recipe-o gets ground args for indexing
    (project (spec-id rid scale)
      (fresh (spec-word rname)
        (spec-word-o ctx spec-id spec-word)
        (fact-recipe-o ctx rid rname spec-id)
        (project (spec-word rname)
          (== s0 `("produce" ,spec-word "at" "scale"
                   ,(number->string scale) "via"
                   ,(string-downcase rname) . ,s)))))))

(define (narrate-transport-o ctx plan-term s0 s)
  "'transport 50 wheat from farm to mill'"
  (fresh (spec-id allocated src dest trid spec-word src-word dest-word)
    (== plan-term `(transport ,spec-id ,allocated ,src ,dest ,trid))
    (spec-word-o ctx spec-id spec-word)
    (location-word-o ctx src src-word)
    (location-word-o ctx dest dest-word)
    (project (spec-word allocated src-word dest-word)
      (== s0 `("transport" ,(number->string allocated) ,spec-word
               "from" ,src-word "to" ,dest-word . ,s)))))

(define (narrate-unmet-o ctx plan-term s0 s)
  "'5 yeast cannot be sourced'"
  (fresh (spec-id remaining loc spec-word)
    (== plan-term `(unmet ,spec-id ,remaining ,loc))
    (spec-word-o ctx spec-id spec-word)
    (project (remaining spec-word)
      (== s0 `(,(number->string remaining) ,spec-word
               "cannot" "be" "sourced" . ,s)))))


;;; ── Ground helpers ─────────────────────────────────────────────────────────

(define (narrate-plan ctx plan-term)
  "Generate a natural language string from a plan-term.
   Returns the string, or #f if no narration is available."
  (let ((results (run-plan 1 '() (words)
                   (narrate-o ctx plan-term words '()))))
    (if (pair? results)
        (string-join (car results) " ")
        #f)))

(define* (narrate-plan-tree ctx plan-term #:optional (indent 0))
  "Recursively narrate a plan-term tree, producing indented multi-line text.
   Walks sub-plans (consume-plans, use-plans, cite-plans) depth-first."
  (let ((prefix (make-string (* indent 2) #\space))
        (line (narrate-plan ctx plan-term)))
    (if (not line)
        (string-append prefix "(unknown plan term)\n")
        (let ((base (string-append prefix line "\n")))
          (match plan-term
            (('produce spec-id rid scale consume-plans use-plans cite-plans)
             (string-append base
               (narrate-sub-plans ctx "inputs" consume-plans (+ indent 1))
               (narrate-sub-plans ctx "tools" use-plans (+ indent 1))
               (narrate-sub-plans ctx "references" cite-plans (+ indent 1))))
            (_ base))))))

(define (narrate-sub-plans ctx label plans indent)
  "Narrate a list of sub-plans under a label. Empty list → empty string."
  (if (or (not (pair? plans)) (null? plans))
      ""
      (let ((prefix (make-string (* indent 2) #\space)))
        (string-append
          prefix label ":\n"
          (apply string-append
            (map (lambda (p) (narrate-plan-tree ctx p (+ indent 1))) plans))))))

(define (narrate-query-result ctx goal results)
  "Narrate the results of a parsed query goal into readable text."
  (match goal
    (('demand spec-id qty)
     (if (null? results)
         "No plan found.\n"
         (apply string-append
           (map (lambda (r) (narrate-plan-tree ctx r)) results))))
    (('inventory spec-id)
     (if (null? results)
         "No inventory found.\n"
         (apply string-append
           (map (lambda (r)
                  (match r
                    (('stock qty loc)
                     (string-append "  " (number->string qty) " in " loc "\n"))
                    (_ (string-append "  " (object->string r) "\n"))))
                results))))
    (('recipes spec-id)
     (if (null? results)
         "No recipes found.\n"
         (apply string-append
           (map (lambda (r)
                  (match r
                    (('recipe rid name)
                     (string-append "  " name " (" rid ")\n"))
                    (_ (string-append "  " (object->string r) "\n"))))
                results))))
    (('provenance spec-id)
     (if (null? results)
         "No inputs found.\n"
         (apply string-append
           (map (lambda (r)
                  (match r
                    (('needs ancestor trace)
                     (string-append "  needs " ancestor
                       " (via " (string-join (map object->string trace) " → ") ")\n"))
                    (_ (string-append "  " (object->string r) "\n"))))
                results))))
    (('destination spec-id)
     (if (null? results)
         "No outputs found.\n"
         (apply string-append
           (map (lambda (r)
                  (match r
                    (('produces downstream trace)
                     (string-append "  produces " downstream
                       " (via " (string-join (map object->string trace) " → ") ")\n"))
                    (_ (string-append "  " (object->string r) "\n"))))
                results))))
    (_ (object->string results))))

;; object->string is Guile core, and core's defaults to `write` — identical
;; output on every type tried. Redefining it was invisible while this was an
;; include-fragment; as a module it shadowed core for every importer.
