;;; test-per-recipe-composition.scm — two ways of growing one crop are two
;;; compositions, said literally.
;;;
;;; The engine has preferred a per-recipe composition key all along —
;;; `spec-element-fraction spec element proc` reads a `(proc . spec)` row before
;;; the spec's — but the knowledge side flattened its derivations to one row per
;;; spec, so the preference had nothing to prefer. `recipe-derived-contains
;;; #:per-process? #t` now emits the same derivations keyed by process, and
;;; `scope-composition` hands both to the solve: a process's outputs read their
;;; OWN recipe's residual, inputs read the spec's, and social-material.typ's
;;; "two ways of growing the same crop are two recipes, hence two compositions"
;;; stops being merely permitted.
;;;
;;; A lot, likewise, is a stage/state qualification (`qualified-good`) — its own
;;; spec, its own row — so lot separation costs schema nothing; this suite pins
;;; the composition half.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-per-recipe-composition.scm

(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas)
             (playnet planner doors service)
             (playnet planner knowledge catalogues substances)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define (~= a b) (and a b (< (abs (- a b)) 1e-4)))

;; two recipes, one crop: RICH draws 8 kg of soil-N per 100 kg, LEAN draws 3 kg
(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Two Growers")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (for-each
     (lambda (spec)
       ($ rs 'add-resource-spec (make-resource-specification #:id spec #:name spec
                                                             #:default-unit-of-resource "kg")))
     '("crop" "soil-n"))
    (for-each
     (lambda (def)
       (let ((rid (car def)) (pid (cadr def)) (n (caddr def)))
         ($ rs 'add-recipe-process (make-recipe-process #:id pid #:name pid))
         ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-in") #:action 'consume #:resource-conforms-to "soil-n"
                                                  #:resource-quantity (make-measure n "kg") #:recipe-input-of pid))
         ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-out") #:action 'produce #:resource-conforms-to "crop"
                                                  #:resource-quantity (make-measure 100.0 "kg") #:recipe-output-of pid #:is-primary #t))
         ($ rs 'add-recipe (make-recipe #:id rid #:name rid #:primary-output "crop"
                                        #:recipe-processes (list pid) #:recipe-exchanges '()))))
     '(("r-rich" "rp-rich" 8.0)
       ("r-lean" "rp-lean" 3.0)))))

(display "\n── the derivations, keyed per process ──\n")
(define per-proc (with-vat vat (recipe-derived-contains ($ scope 'recipe-store) #:per-process? #t)))
(define (row proc) (assoc-ref per-proc (cons proc "crop")))
(check-pred "one row per process, both present"
            (and (row "rp-rich") (row "rp-lean") #t))
(check-pred "the rich grower's crop carries 8/100 nitrogen"
            (~= (assoc-ref (row "rp-rich") "N") 0.08))
(check-pred "the lean grower's crop carries 3/100 — same spec, different composition"
            (~= (assoc-ref (row "rp-lean") "N") 0.03))

(display "\n── the spec-keyed reading still exists, for inputs and fallbacks ──\n")
(define spec-rows (with-vat vat (recipe-derived-contains ($ scope 'recipe-store))))
(check-pred "a bare `crop` row is still derived" (and (assoc-ref spec-rows "crop") #t))

(display "\n── scope-composition hands the solve BOTH ──\n")
(define comp (with-vat vat (scope-composition scope)))
(check-pred "the per-process rows reach the solve's composition"
            (and (assoc-ref comp (cons "rp-rich" "crop"))
                 (assoc-ref comp (cons "rp-lean" "crop")) #t))
(check-pred "…with their own values, not one flattened number"
            (not (~= (assoc-ref (assoc-ref comp (cons "rp-rich" "crop")) "N")
                     (assoc-ref (assoc-ref comp (cons "rp-lean" "crop")) "N"))))
(check-pred "and a spec row for readers that name no process"
            (and (assoc-ref comp "crop") #t))

(test-summary!)
