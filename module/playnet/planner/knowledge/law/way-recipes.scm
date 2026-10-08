;;; way-recipes.scm — what a way trips, read off the recipe that is it.
;;;
;;; A way of doing an activity (law/activities.scm) names a recipe, and the
;;; crossings it trips and the channel it hands its good on by are that recipe's
;;; own: read off its records by the same fold the gate runs over a scope's
;;; recipes (legal/gate.scm `process-crossings`, legal/crossings.scm). So a way states
;;; nothing a recipe already says.
;;;
;;; The recipes live in one small store, seeded once from the files that hold
;;; them: recipes/ways.scm, recipes/dwelling.scm (a night's shelter),
;;; recipes/food-surplus.scm (surplus recovery).

(define-module (playnet planner knowledge law way-recipes)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module ((goblins core) #:select (make-actormap actormap-run!))
  #:use-module (goblins utils hashmap)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner knowledge recipes store) #:select (^recipe-store))
  #:use-module ((playnet planner legal crossings) #:select (recipe-channel))
  #:use-module ((playnet planner legal gate) #:select (process-crossings legal-proc-flows))
  #:use-module ((playnet planner knowledge recipes ways) #:select (seed-ways-recipes))
  #:use-module ((playnet planner knowledge recipes dwelling) #:select (seed-dwelling-recipe))
  #:use-module ((playnet planner knowledge recipes food-surplus) #:select (seed-food-surplus-recipe))
  #:export (way-recipe-ids way-recipe-crossings way-recipe-channel way-recipes-lint-store))

;;; Read once, when this module loads: recipe id → (crossings . channel), the
;;; union over the recipe's processes. Plain data from here on. The store lives
;;; in an actormap of its own, run in this thread — a module's load is no place
;;; to wait on another thread's vat.
(define %read
  (let ((am (make-actormap)))
    (actormap-run! am
     (lambda ()
      (let ((rs (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap))))
        (for-each (lambda (seed) (seed rs))
                  (list seed-dwelling-recipe seed-food-surplus-recipe seed-ways-recipes))
        (let ((resolve (lambda (id) ($ rs 'get-resource-spec id))))
          (map (lambda (r)
                 (let ((pids (map recipe-process-id ($ rs 'get-process-chain (recipe-id r)))))
                   (cons (recipe-id r)
                         (cons (delete-duplicates
                                (append-map (lambda (pid) (process-crossings rs pid)) pids))
                               (any (lambda (pid) (recipe-channel (legal-proc-flows rs pid) resolve rs))
                                    pids)))))
               ($ rs 'all-recipes))))))))

(define (way-recipe-ids) (map car %read))
(define (way-recipe id)
  (or (assoc-ref %read id) (error "way-recipes: no such recipe" id)))
(define (way-recipe-crossings id) (car (way-recipe id)))
(define (way-recipe-channel id) (cdr (way-recipe id)))

;;; a fresh store holding the same recipes, for a lint or a test to walk
(define (way-recipes-lint-store)
  (let ((rs (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                   (hashmap) (hashmap) (hashmap) (hashmap) (hashmap))))
    (for-each (lambda (seed) (seed rs))
              (list seed-dwelling-recipe seed-food-surplus-recipe seed-ways-recipes))
    rs))
