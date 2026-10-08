;;; bread.scm — THE live fixture: the grow→mill→bake chain in one town, as
;;; the live suites share it. One copy, so the files that prove the
;;; commitment arc, the live wire and the willingness service plan over the
;;; same economy and cannot drift apart a skill or a window at a time.
;;;
;;; The economy is bread-world in (playnet planner knowledge recipes
;;; bread-commune-seed) — the world the dev gateway's demo commune is seeded
;;; from. spawn-bread-scope seeds it into a REAL scope-root (every store real:
;;; the plan-store the arc's facts live on, the alert-store, an observer
;;; whose record-event folds stock), so a suite here plans over exactly what
;;; the gateway plans over. Pass #:world for the plain variant
;;; (bread-plain-world: one worker per skill, no clock, so every day stays
;;; one period — the recipe-library, material-loop and metabolism suites),
;;; or #:agents / #:resources to replace those tables alone.
;;;
;;; The world's tables (bread-procs, bread-flows, bread-agents, …) are
;;; re-exported so a suite reads them from one place.

(define-module (playnet test planner bread)
  #:use-module (playnet planner scope root)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner knowledge dsl world)
  #:use-module (playnet planner knowledge recipes bread-commune-seed)
  #:use-module (playnet planner knowledge dsl recipe-library)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:re-export (bread-world bread-plain-world bread-world-at
               bread-procs bread-flows bread-recipes bread-specs bread-resources bread-stores bread-storable bread-agents
               bread-spatials bread-window
               bread-plain-resources bread-plain-agents bread-resources-at)
  #:export (spawn-bread-scope bread-hours bread-defs))

(define* (spawn-bread-scope #:key (world bread-world)
                                  (agents (world-agents world)) (resources (world-resources world))
                                  (name "bread"))
  "A real scope-root over the bread economy. Call inside a vat. Returns
   (values scope plan-store alert-store)."
  (let ((scope (spawn-scope-root name)))
    (seed-world! scope (world-with world #:agents agents #:resources resources))
    (values scope ($ scope 'plan-store) ($ scope 'alert-store))))

(define (bread-defs)
  "The world's recipes as recipe-library defs — one per recipe, each with the
   processes it names and their flows — so a suite that plans over the library
   plans the same town the stores seed, the whole table included."
  (map (lambda (r)
         (let ((pids (recipe-recipe-processes r)))
           (recipe-def r
                       (filter (lambda (p) (member (recipe-process-id p) pids)) bread-procs)
                       (filter (lambda (f) (or (member (recipe-flow-recipe-input-of f) pids)
                                               (member (recipe-flow-recipe-output-of f) pids)))
                               bread-flows))))
       bread-recipes))

(define (bread-hours result proc)
  "The work hours a solve result emits for PROC."
  (fold (lambda (w acc) (if (equal? proc (assq-ref w 'input-of))
                            (+ acc (or (assq-ref w 'effort) 0)) acc))
        0.0 (or (assq-ref result 'work) '())))
