;;; law/aspects.scm — the legal "aspects" as REAL ValueFlows ProcessSpecifications.
;;; @defines legal-aspects
;;; @builds legal-aspects reform
;;;
;;; Each legal requirement (handwashing, plan-review, temperature-control, …) is a
;;; <process-specification> (schemas.scm) — a TYPE of process/check, is-control-
;;; point for the inspections. This is the grounded vocabulary the reform (L,I,D)
;;; diff runs on, replacing invented bare atoms. ONE governance judgment per
;;; aspect: is this check a genuine function we'd perform, or the exclusionary
;;; SHELL we reject (the duress)? — `shell?`. This replaces the old per-demand
;;; *reform-duress* table: duress now falls out of the diff as L − desired.
;;;
;;; A recipe PERFORMS an aspect by carrying a <recipe-process> whose process-
;;; conforms-to is that aspect's id. So a recipe's aspect-set (`recipe-aspects`)
;;; is READ OFF its processes. Then, per demand (jurisdiction-specific L):
;;;   L = the aspects the LAW requires    (the legal-registry fold)
;;;   I = the aspects our ACTUAL recipe performs   (derived — what we DO)
;;;   D = the aspects our DESIRED recipe performs   (the genuine, no shell)
;;; and reform.scm's diff (redundant/absorb/transform + reproduce-unwanted) is
;;; unchanged. VF: ProcessSpecification + RecipeProcess.process-conforms-to.
;;;
;;; Loads after reform.scm, before worlds/free-food-distribution.scm. Needs schemas.scm
;;; (live service has it via the umbrella; the offline emitter loads it first).

;; It builds ProcessSpecs (schemas) out of the legal vocabulary (legal-registry)
;; and hands them to reform's mirror diff, so all three are named here.
(define-module (playnet planner knowledge law aspects)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner legal registry)
  #:use-module (playnet planner legal reform)
  #:export (*clause-aspects* register-clause-aspect! clause-aspect
            register-practice! practised? actual-aspects *aspect-shell* aspect *legal-aspects* structural-aspect-syms register-structural-aspects!
            aspect-id aspect-name aspect-control? *food-housing-ids*
            legal-aspect? aspect-shell? *genuine-ids* recipe-aspects
            aspect-process make-aspect-recipe recipe-aspect-set
            *desired-aspects* grounded-mirror))

;;; ─── the aspect catalogue : legal requirements as ProcessSpecifications ────
;;; id = the atom as a string (round-trips with the registry's symbol specs and a
;;; recipe-process's process-conforms-to). control? = an inspection; shell? = the
;;; exclusionary duress (excluded from the desired recipe).
(define *aspect-shell* (make-hash-table))    ; aspect-sym → #t if it is the shell
(define* (aspect id name #:key (control? #t) (shell? #f))
  (when shell? (hash-set! *aspect-shell* (string->symbol id) #t))
  (make-process-specification #:id id #:name name #:is-control-point control?))

(define *legal-aspects*
  (list
   ;; ── genuine food-safety functions (a sane commons food op performs these) ──
   (aspect "handwashing"           "Handwashing facility & training")
   (aspect "temperature-control"   "Hot/cold holding temperature control")
   (aspect "overhead-protection"   "Overhead protection from the elements")
   (aspect "sanitation"            "Sanitary preparation & service conditions")
   (aspect "safe-food-handling"    "Safe food handling practice")
   (aspect "hazard-analysis"       "Hazard analysis of the supply")
   (aspect "supplier-approval"     "Approved-supplier verification")
   (aspect "preventive-control-plan" "Preventive control plan")
   (aspect "traceability"          "Lot/source traceability")
   (aspect "pest-free"             "Pest-free phytosanitary condition")
   (aspect "origin-inspected"      "Origin inspection of imports")
   (aspect "sanitary-registration" "Sanitary registration of the import")
   (aspect "labeling"              "Honest product labeling" #:control? #f)
   ;; competence (also modeled as skills via satisfied-by elsewhere; here they are
   ;; the function-aspects "we train our handlers")
   ;; ONE aspect a function: a law that words it its own way — a Houston
   ;; "food-handler-trained", a Mexican "manejo-higienico" — registers the word
   ;; as a clause for the aspect (`register-clause-aspect!`, below).
   (aspect "hygiene-training"      "Food-handler hygiene training" #:control? #f)
   ;; ── genuine housing functions ──
   (aspect "building-code"         "Building-code compliance")
   (aspect "fire-safety"           "Fire-safety / egress")
   (aspect "habitability"          "Habitability standard")
   ;; ── the exclusionary SHELL (the duress — required by some law, no genuine
   ;;    function; the desired recipe omits these, so transform = L − desired) ──
   (aspect "plan-review"           "Bureaucratic operating-plan review" #:shell? #t)
   (aspect "restroom-access"       "On-site restroom access (anti-homeless shell)" #:shell? #t)
   (aspect "site-approval"         "City site approval (anti-homeless shell)" #:shell? #t)
   (aspect "labeling-es"           "Spanish-language labeling (extraterritorial)" #:shell? #t)
   (aspect "permitted-use"         "Zoning permitted-use restriction" #:shell? #t)
   (aspect "density"               "Zoning density restriction" #:shell? #t)
   (aspect "setbacks"              "Zoning setback restriction" #:shell? #t)))

;;; the STRUCTURAL aspects (the abolitions' functions): the social functions a
;;; state monopoly serves + the coercive shell it wraps them in. An abolition
;;; states its own three recipes — incumbent, actual, desired — and a clause is
;;; a structural aspect because an abolition names it there (`grounded-mirror`
;;; registers them). They are recognised by recipe-aspects, and stand apart from
;;; the global regulatory desired/actual pair: each abolition's I ≠ D is its
;;; own.
(define *structural-aspects* (make-hash-table))   ; aspect-sym → #t
(define (register-structural-aspects! syms)
  (for-each (lambda (s) (hash-set! *structural-aspects* s #t)) syms))
(define (structural-aspect-syms)
  (sort (hash-map->list (lambda (k v) k) *structural-aspects*)
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

(define aspect-id   process-specification-id)
(define aspect-name process-specification-name)
(define aspect-control? process-specification-is-control-point)
(define *food-housing-ids* (map (lambda (a) (string->symbol (aspect-id a))) *legal-aspects*))

;;; ─── a law's own words for an aspect ─────────────────────────────────────
;;; A demand's spec is written in its law's words: `hygieneschulung`, where the
;;; federation says `hygiene-training`. A clause is MAPPED when it names a
;;; federation aspect — by being one, or because a steward registered it as
;;; another word for one (the `aspects` section of a context pack) — and
;;; UNMAPPED otherwise. Only a mapped clause enters the (L, I, D) diff: whether
;;; the federation wants a function is a question about the aspect, and of a
;;; clause nobody has mapped there is nothing yet to say.
;;;
;;; The words are ONE vocabulary, as the aspects are: a word names the same
;;; aspect in every law that uses it. So the first registration of a word
;;; stands, an aspect's own id is never another word for something else, and a
;;; second pack that maps the word elsewhere is refused (→ #f; the pack lint
;;; reports it before it ships).
(define *clause-aspects* (make-hash-table))        ; clause-sym → aspect-sym
(define (register-clause-aspect! clause aspect)
  (let ((standing (clause-aspect clause)))
    (cond ((not standing) (hash-set! *clause-aspects* clause aspect) clause)
          ((eq? standing aspect) clause)
          (else #f))))
(define (clause-aspect clause)
  "The federation aspect CLAUSE names, or #f when nobody has mapped it."
  (if (memq clause *food-housing-ids*)
      clause
      (hash-ref *clause-aspects* clause #f)))
(define (legal-aspect? sym)             ; recognised by recipe-aspects
  (and (or (memq sym *food-housing-ids*) (hash-ref *structural-aspects* sym #f)) #t))
(define (aspect-shell? sym) (and (hash-ref *aspect-shell* sym #f) #t))
;; the global regulatory desired = food/housing GENUINE aspects only (no shell,
;; no structural). The structural tier supplies its own desired per abolition.
(define *genuine-ids* (filter (lambda (s) (not (aspect-shell? s))) *food-housing-ids*))

;;; ─── recipe-aspects : the aspect-set a recipe PERFORMS (the derivation) ────
;;; Walk the recipe's <recipe-process> records, collect each process-conforms-to
;;; that is a legal aspect, as symbols. `process-map` = alist (process-id .
;;; <recipe-process>) — the offline law path has no ^recipe-store actor, so the
;;; recipe carries its processes as plain records (the compile-recipe pattern).
(define (recipe-aspects recipe process-map)
  (delete-duplicates
   (filter-map
    (lambda (pid)
      (let ((rp (assoc-ref process-map pid)))
        (and rp
             (let ((c (recipe-process-process-conforms-to rp)))
               (and c (let ((sym (string->symbol c)))
                        (and (legal-aspect? sym) sym)))))))
    (recipe-recipe-processes recipe))))

;;; build a one-aspect <recipe-process> (a step that performs the check it
;;; conforms-to), and a <recipe> over a flat list of such processes.
(define (aspect-process recipe-tag aspect-sym)
  (make-recipe-process #:id (string-append "rp-" recipe-tag "-" (symbol->string aspect-sym))
                       #:name (symbol->string aspect-sym) #:process-conforms-to (symbol->string aspect-sym)))
(define (make-aspect-recipe id name aspect-syms)
  (let ((rps (map (lambda (a) (aspect-process id a)) aspect-syms)))
    (values (make-recipe #:id (string-append "recipe-" id) #:name name
                         #:recipe-processes (map recipe-process-id rps))
            (map (lambda (rp) (cons (recipe-process-id rp) rp)) rps))))
(define (recipe-aspect-set id name aspect-syms)
  (call-with-values (lambda () (make-aspect-recipe id name aspect-syms)) recipe-aspects))

;;; ─── the federation's two views of an aspect ───────────────────────────────
;;; DESIRED = a recipe whose processes perform every GENUINE aspect (no shell).
;;; ACTUAL  = what the federation's running recipes perform. A way of doing an
;;; activity states the aspects it `performs` (law/activities.scm), and each way a
;;; member runs registers them here (`register-practice!`). Per demand, I =
;;; the clauses whose aspect is practised and D = the ones desired, so:
;;;
;;;   practised and desired          → redundant          (provide)
;;;   desired, practised by no way   → absorb-first       (build)
;;;   practised, a shell             → reproduce-unwanted (bear)
;;;   neither                        → transform          (reject)
(define *desired-aspects* (recipe-aspect-set "fed-desired" "Federation desired practice" *genuine-ids*))

(define *practised* (make-hash-table))            ; aspect-sym → #t
(define (register-practice! aspects)
  (for-each (lambda (a) (hash-set! *practised* a #t)) aspects))
(define (practised? aspect) (hash-ref *practised* aspect #f))
(define (actual-aspects)
  (sort (hash-map->list (lambda (k v) k) *practised*)
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

;;; ─── grounded-mirror : a <spec-mirror> built by diffing THREE recipes ──────
;;; For the structural tier (the abolitions), each function has its own three
;;; recipe-views: the INCUMBENT (the state monopoly's full function = L), our
;;; ACTUAL recipe (what the commons reproduces today = I), our DESIRED recipe
;;; (the function minus the coercive shell = D). The mirror's L/I/D are the
;;; aspect-sets of these three recipes — derived, not hand-typed atom lists —
;;; and every clause the three name is thereby an aspect.
(define* (grounded-mirror name #:key incumbent actual desired
                          (kind 'permit))
  (register-structural-aspects! (append incumbent actual desired))
  (spec-mirror name #:kind kind
    #:legal    (recipe-aspect-set (string-append name " · L") "incumbent" incumbent)
    #:internal (recipe-aspect-set (string-append name " · I") "actual"    actual)
    #:desired  (recipe-aspect-set (string-append name " · D") "desired"   desired)))
