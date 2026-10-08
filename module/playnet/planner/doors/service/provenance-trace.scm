;;; provenance-trace.scm — join the provenance graph to live convex-solve values.
;;;
;;; The capstone: a prose claim → the number the planner produced. Kept decoupled
;;; by DEPENDENCY INJECTION — this module imports the pure provenance graph, but
;;; takes the plan value and the two planner lookups as ARGUMENTS. It never imports
;;; the solver, so it can't perturb a solve and is testable with fakes.
;;;
;;;   pull-of : spec-id → μ | #f       (a good's pull from a plan; `make-pull-of`)
;;;   gated-by : aspect-id → (recipe …) (recipes whose process-conforms-to = aspect;
;;;                                       wrap service.scm's find-recipe-process-for-spec)
;;;
;;; Usage (in the live service, where the recipe store `rs` exists):
;;;   (explain-claim 'duress-from-diff plan
;;;     #:pull-of (make-pull-of plan)
;;;     #:gated-by (lambda (a) (recipes-conforming rs a)))
;;;
;;; Hoot-neutral: pure list/alist walking + the provenance relations.

(define-module (playnet planner doors service provenance-trace)
  #:use-module (playnet lang provenance)
  #:use-module (srfi srfi-1)
  #:export (plan-good-pulls make-pull-of explain-claim explain-claim->string))

;;; ── the plan side (pure alist walking) ───────────────────────────────────────

(define (plan-good-pulls plan)
  "The goods' pulls ((located-good . μ) …) from a plan alist, or '(): the
   plan's `good-pulls` (live.scm's plan, the solve report)."
  (or (assoc-ref plan 'good-pulls) '()))

(define (make-pull-of plan)
  "Build spec-id → μ over a plan. The pulls' keys are located goods (lg sid cell);
   we match the spec id as a substring of the key's printed form. Returns #f when
   the plan holds no pull for the spec (e.g. structural-only ids like legal aspects)."
  (let ((gp (plan-good-pulls plan)))
    (lambda (spec-id)
      (let* ((needle (if (symbol? spec-id) (symbol->string spec-id) spec-id))
             (hit (find (lambda (kv)
                          (string-contains (format #f "~a" (car kv)) needle))
                        gp)))
        (and hit (cdr hit))))))

;;; ── the join: claim → basis → realized ids → recipes → numbers ───────────────

(define* (explain-claim claim plan #:key (pull-of (lambda (_) #f))
                                        (gated-by  (lambda (_) '())))
  "Trace CLAIM to the convex plan. Returns an alist:
     claim, grounds (refs), proof (chain), realizes (ids),
     gated ((aspect . (recipes)) …), numbers ((id . μ) …).
   Every hop is a provenance query joined to the injected planner lookups."
  (let* ((refs   (all-grounds claim))
         (ids    (what-realizes claim))
         (deep   (if (null? refs) '() (proof-for claim (last refs))))
         (gated  (map (lambda (id) (cons id (gated-by id))) ids))
         (nums   (filter-map (lambda (id)
                               (let ((mu (pull-of id))) (and mu (cons id mu))))
                             ids)))
    `((claim   . ,claim)
      (grounds . ,refs)
      (proof   . ,deep)
      (realizes . ,ids)
      (gated   . ,gated)
      (numbers . ,nums))))

(define (explain-claim->string e)
  "Render an explain-claim alist as a short human trace."
  (define (g k) (assoc-ref e k))
  (string-append
   (format #f "claim ~a~%" (g 'claim))
   (format #f "  rests on : ~a~%" (g 'grounds))
   (format #f "  proof    : ~a~%" (g 'proof))
   (format #f "  realizes : ~a~%" (g 'realizes))
   (let ((gated (g 'gated)))
     (if (null? gated) ""
         (format #f "  gates    : ~a~%"
                 (map (lambda (kv) (cons (car kv) (length (cdr kv)))) gated))))
   (let ((nums (g 'numbers)))
     (if (null? nums) "  numbers  : (none — structural claim)\n"
         (format #f "  numbers  : ~a~%" nums)))))
