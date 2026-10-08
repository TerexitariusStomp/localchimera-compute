;;; test-mode-identity.scm — a travel mode is one recipe, named by its own specification.
;;;
;;; A mode recipe's process conforms to a ProcessSpecification of its own
;;; ("pspec-<mode>"), so a performed ride, which is `based-on` that specification,
;;; names its recipe without a guess. These properties hold:
;;;
;;;   OWN      every mode has its own specification; the shared "pspec-transport"
;;;            belongs to the carry and hold recipes, which are no modes
;;;   UNIQUE   a store resolves a mode's specification to that mode alone
;;;   WHOLE    every mode's specification is in the store that holds the mode
;;;   LINT     two modes on one specification, or a process naming a specification
;;;            the store lacks, are findings
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-mode-identity.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes bay-area-commune-seed) (playnet planner knowledge recipes berlin-commune-seed) (playnet planner knowledge recipes berlin-transit) (playnet planner knowledge recipes farm-commune-seed) (playnet planner knowledge recipes transport) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1) (srfi srfi-11)
             (playnet planner scope live)
             (playnet planner knowledge recipes berlin-transit)
             (playnet planner knowledge dsl vf-lint)
             (playnet planner knowledge dsl findings)
             (goblins) (goblins vat) (goblins persistence-store memory)
             (srfi srfi-1))

(define find-for-spec find-recipe-process-for-spec)
(define (pspec-of entry) (recipe-process-process-conforms-to (car entry)))

(display "\n── OWN: a mode's specification is its own ──\n")
(check "a mode is named for its specification" (pspec-of (mode-recipe "ferry" #:pace 0.1)) "pspec-ferry")
(check "…unless the caller names one" (pspec-of (mode-recipe "ferry" #:pace 0.1 #:pspec "pspec-water")) "pspec-water")
(check "the car ride is a mode" (pspec-of car-ride) "pspec-car")
(check "no Berlin mode shares a specification"
       (let ((ids (map pspec-of *berlin-mode-recipes*))) (= (length ids) (length (delete-duplicates ids)))) #t)
(check "…none is the shared one" (member "pspec-transport" (map pspec-of *berlin-mode-recipes*)) #f)
(call-with-values (lambda () (recipe-carry "spec-x" "skill-x"))
  (lambda (rp flows) (check "a carry recipe stays on the shared specification"
                            (recipe-process-process-conforms-to rp) "pspec-transport")))

(display "\n── UNIQUE, WHOLE: the store resolves each mode, and holds its specification ──\n")
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Modes")) (make-memory-store)))
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-transport-specs rs)
    (seed-transport-recipe rs)
    (seed-berlin-transit! rs)
    (for-each
     (lambda (entry)
       (let* ((rp (car entry)) (spec (recipe-process-process-conforms-to rp)))
         (check (string-append spec " resolves to its own mode")
                (and=> (find-for-spec rs spec) recipe-process-id) (recipe-process-id rp))
         (check (string-append spec " is in the store") (and ($ rs 'get-process-spec spec) #t) #t)))
     (cons car-ride *berlin-mode-recipes*))))

(display "\n── LINT: a shared or missing specification is a finding ──\n")
(define (kinds rs ks) (filter-map (lambda (f) (and (memq (finding-kind f) ks) (finding-kind f))) (lint-recipe-store rs)))
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (check "a store of whole, distinct modes has no process-specification finding"
           (kinds rs '(unknown-process-spec shared-mode-spec)) '())
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-orphan" #:name "Orphan"
                                                   #:process-conforms-to "pspec-absent"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-orphan" #:name "Orphan"
                                   #:recipe-processes (list "rp-orphan")))
    (check "a process naming a specification the store lacks is a finding"
           (kinds rs '(unknown-process-spec)) '(unknown-process-spec))))
(define-values (vat2 scope2)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Shared")) (make-memory-store)))
(with-vat vat2
  (let ((rs ($ scope2 'recipe-store)))
    (seed-transport-specs rs)
    (seed-recipe-entry! rs (mode-recipe "a" #:pace 0.1 #:pspec "pspec-shared"))
    (seed-recipe-entry! rs (mode-recipe "b" #:pace 0.2 #:pspec "pspec-shared"))
    (check "two modes on one specification are a finding" (kinds rs '(shared-mode-spec)) '(shared-mode-spec))))

(display "\n── BASELINE: every scope can walk, ride a bike and drive ──\n")
;; A journey is filed under its scope's mode for the way it was made, so a scope
;; with no transit shed still records one against a recipe.
(define (modes-of scope vat*)
  (with-vat vat*
    (let ((rs ($ scope 'recipe-store)))
      (map (lambda (pid) (and=> ($ rs 'get-recipe-process pid) recipe-process-process-conforms-to))
           '("rp-mode-walk" "rp-mode-bike" "rp-ride")))))
(define want '("pspec-walk" "pspec-bike" "pspec-car"))
(let-values (((v s) (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Farm")) (make-memory-store))))
  (with-vat v (seed-farm-commune! s))
  (check "a farm scope has the three" (modes-of s v) want))
(let-values (((v s) (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Bay")) (make-memory-store))))
  (with-vat v (seed-bay-area-commune! s))
  (check "a Bay Area scope has the three" (modes-of s v) want))
(let-values (((v s) (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Berlin")) (make-memory-store))))
  (with-vat v (seed-berlin-commune! s #:transit? #t))
  (check "a Berlin scope has the three" (modes-of s v) want)
  (check "…and its own bike still rides the commune's bikes, not the baseline's free one"
         (with-vat v (let ((rs ($ s 'recipe-store)))
                       (sort (map recipe-flow-resource-conforms-to
                                  (filter (lambda (f) (eq? 'use (recipe-flow-action f)))
                                          (car ($ rs 'flows-for-process "rp-mode-bike"))))
                             string<?)))
         '("spec-bt-bike")))

(display "\n── CAPACITY: a vehicle held only for a mode is a capacity, with no cap stated ──\n")
;; The network a mode rides (`use`) is read off the scope's mode recipes, so what the
;; commune holds of it is the service it can render each period, as for any means a
;; recipe uses. Nothing here states #:eco-caps.
(define-values (cvat croot)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Berlin")) (make-memory-store)))
(with-vat cvat (seed-berlin-commune! croot #:transit? #t))
(with-vat cvat
  (plan-scope->alist croot #:manners berlin-transit-manners
                     #:demand (list (cons "food#berlin-commune-farm@0" 20000.0))))
(define cap (@@ (playnet planner solve engine) *cap*))
(define (capped? spec)
  (hash-fold (lambda (k v found) (or found (and (> v 0.0) (string-prefix? (string-append "Svc|" spec "#") k) #t)))
             #f cap))
(for-each (lambda (spec) (check (string-append spec " is a capacity") (capped? spec) #t))
          '("spec-bt-ubahn" "spec-bt-sbahn" "spec-bt-tram" "spec-bt-bus" "spec-bt-cargo-bike"))

(test-summary!)
