;;; test-solve-freshness.scm — warm starts and the time tick.
;;;
;;; The service pops the solve's x off the alist into an in-process table and
;;; hands it to the next current-plan solve as #:warm-x; resolve-stale! walks
;;; the roster and re-solves what has fallen behind the clock — a scope with
;;; standing declared needs that has never solved, and a cache older than
;;; max-age — and leaves fresh caches alone.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-solve-freshness.scm
(use-modules (playnet planner scope root) (playnet planner vf schemas)
             (playnet planner doors service)
             ((playnet planner facts tension-terms) #:select (with-tension-terms))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))
(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ok: ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  FAIL: ~a~%" name))))
(define calls '())                       ; newest first: the kw list of each solve
(define (kw-ref kws k)
  (let loop ((l kws)) (cond ((null? l) #f) ((eq? (car l) k) (cadr l)) (else (loop (cdr l))))))
(define (stub-plan-fn root sid . kw)
  (set! calls (cons kw calls))
  `((met . 1.0) (feasible . #t) (x . #(1.0 2.0 3.0)) (intend) (work) (material)))
(define vat (spawn-vat #:name "freshness"))
(with-vat vat
  (let* ((svc  (spawn ^planner-service (hashmap) stub-plan-fn))
         (root (spawn-scope-root "S"))
         (root2 (spawn-scope-root "S2")))
    ;; a standing declared need, so the tick sees demand before any solve
    ($ ($ root 'plan-store) 'add-intent
       (make-intent #:id "need:ada:soup" #:action 'consume #:name "soup" #:image "🍲" #:resource-conforms-to "soup"
                    #:resource-classified-as (with-tension-terms '() "des" 1)
                    #:resource-quantity (make-measure 2.0 "kg") #:receiver "ada"
                    #:at-location "town"))
    ($ svc 'add-scope! "S" root)
    ;; a second scope with NO declared needs at all: "nothing to plan" is
    ;; still an answer the wire must give, so it is due exactly like the first
    ($ svc 'add-scope! "S2" root2)
    (check "every never-solved scope is due at the first tick — needs or none"
           (= 2 ($ svc 'resolve-stale!)))
    (check "…and each solve ran once" (= 2 (length calls)))
    (check "a fresh cache is left alone" (= 0 ($ svc 'resolve-stale!)))
    (check "max-age 0 re-solves both" (= 2 ($ svc 'resolve-stale! 0)))
    (check "the re-solve is warm-started from the previous x"
           (equal? #(1.0 2.0 3.0) (kw-ref (car calls) #:warm-x)))
    ;; the re-stand door: a declaration owner's thunk runs BEFORE the walk,
    ;; on every tick, whether or not any scope is due
    (let ((log '()))
      ($ svc 're-stand! (lambda () (set! log (cons 're-stand log))))
      ($ svc 'resolve-stale!)
      (check "a re-stand hook runs on a tick that re-solves nothing"
             (equal? '(re-stand) log))
      ($ svc 'resolve-stale! 0)
      (check "…and BEFORE the walk when a scope is due"
             (equal? '(re-stand re-stand) log)))
    (let ((r ($ svc 'solve "S" '())))
      (check "a solve door returns ok" (eq? 'ok (car r)))
      (check "…and its alist carries no solution vector" (not (assq 'x (cdr r))))
      (check "…while the door itself was warm-started"
             (equal? #(1.0 2.0 3.0) (kw-ref (car calls) #:warm-x))))

    ;; ── the restart: a SECOND service over the SAME durable stores ────────
    ;; %solve-at is in-process and starts empty in svc2 — the only question
    ;; is whether it reads the durable timestamp `cache-solve!` left beside
    ;; the plan (last-solve-at-ref), or reads #f and re-solves a plan that
    ;; is seconds old. A gateway restart is exactly this: same plan-store on
    ;; disk, fresh service closure.
    (set! calls '())
    (let ((svc2 (spawn ^planner-service (hashmap) stub-plan-fn)))
      ($ svc2 'add-scope! "S" root)
      ($ svc2 'add-scope! "S2" root2)
      (check "a restart does not re-solve what the durable row says is fresh"
             (= 0 ($ svc2 'resolve-stale!)))
      (check "…no solve ran at all" (null? calls)))))
(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
