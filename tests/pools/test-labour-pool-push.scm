;;; test-labour-pool-push.scm — ^labour-pool converged onto the scope-tree push.
;;;
;;; Proves the labour pool now forwards its per-agent event UP the scope tree
;;; (the same path ^folksonomy uses), instead of the parent pull-rebuilding the
;;; whole subtree. A member's availability change at a leaf scope shows up in
;;; the parent commune's pool via the forwarded agent-changed.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/pools/test-labour-pool-push.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet pools labour-fold)
             ((playnet vf formulas actions) #:select (labour?))
             ((playnet vf facts person-facts) #:select (generic-labour-spec))
             (playnet pools availability-pool)
             (playnet vf facts availability)
             (playnet observation observer) (playnet vf schemas) (playnet vf beyond schedules)               ; make-agent, availability accessors
             (playnet observation observer)
             (playnet knowledge dsl shorthand)
             (goblins)
             (srfi srfi-1))

;; A minimal agent available 09:00–17:00 (8h), no location (→ remote cell).
;; The pool carries hours a WEEK — a recurring window's one date-free measure,
;; and the shape the app ships (one schedule per weekday): 09:00–17:00 every day
;; is 56 h, 09:00–13:00 is 28 h.
(define (agent id)
  (make-agent #:id id #:type 'person #:name id #:note "" #:image "" #:classified-as '()
              #:availability-window (make-availability-window
               #f #f #f (list (make-time-range "09:00" "17:00")))))

(define (skills-fn aid) (list "skill:cook"))

(define vat (spawn-vat))

(with-vat vat

  ;; leaf scope pool + parent commune pool.
  (define commune (spawn ^labour-pool (make-labour-pool) '()))
  (define scope   (spawn ^labour-pool (make-labour-pool) '()))

  ;; Wire scope → commune with a plain parent link (the converged path).
  ($ scope 'set-parent commune)

  (display "\n── A member's availability lands at the leaf scope ──\n")

  ($ scope 'agent-changed (agent "agent:1") skills-fn)
  (check "leaf scope has 56 hours a week of cook labour"
         ($ scope 'total-hours #:skill "skill:cook") 56)

  (display "\n── The agent-changed event propagated UP to the commune ──\n")

  (check "parent commune also holds the 56 hours a week (forwarded, not pull-rebuilt)"
         ($ commune 'total-hours #:skill "skill:cook") 56)

  (display "\n── A second member at the same scope ──\n")

  ($ scope 'agent-changed (agent "agent:2") skills-fn)
  (check "leaf scope now 112 hours a week" ($ scope 'total-hours #:skill "skill:cook") 112)
  (check "commune aggregated both members: 112 hours a week"
         ($ commune 'total-hours #:skill "skill:cook") 112)

  (display "\n── Refold is idempotent per agent (re-fire same agent) ──\n")

  ($ scope 'agent-changed (agent "agent:1") skills-fn)
  (check "leaf scope still 16 (agent:1 refolded, not double-counted)"
         ($ scope 'total-hours #:skill "skill:cook") 112)
  (check "commune still 16 as well"
         ($ commune 'total-hours #:skill "skill:cook") 112)

  (display "\n── on-update sink still fires ──\n")
  (define fired 0)
  ($ scope 'set-on-update (lambda (pool) (set! fired (+ fired 1))))
  ($ scope 'agent-changed (agent "agent:3") skills-fn)
  (check "on-update fired on the next change" (> fired 0) #t)
  (check "commune saw the third member: 168 hours a week"
         ($ commune 'total-hours #:skill "skill:cook") 168)

  (display "\n── skill-specs-for-agent reads ONLY skill resources ──\n")
  ;; An observer holding one skill resource and one non-skill holding
  ;; (a declared means) for the same agent: only the skill's spec folds in.
  (define (resource rid spec aid)
    (er rid spec aid #:name rid #:tags #f #:place #f #:qty 1 #:unit %count-unit))
  (define obs (spawn ^observer (empty-observer-state) '()))
  ($ obs 'seed-resource (resource "skill:agent:4:spec-cook" "spec-cook" "agent:4"))
  ($ obs 'seed-resource (resource "skill-agent:4-labor" "spec-labor" "agent:4"))
  ($ obs 'seed-resource (resource "means:agent:4:oven" "spec-oven" "agent:4"))
  ;; what labour is here: the recipes' word (formulas/actions labour?) — a
  ;; bare observer has no store, so the suite states it
  (define labour-here (labour? (list (make-recipe-flow #:id "w" #:action 'work #:resource-conforms-to "spec-cook"))
                               (list generic-labour-spec)))
  (check "the two skill resources' specs, and only those"
         (sort (skill-specs-for-agent obs "agent:4" labour-here) string<?)
         '("spec-cook" "spec-labor"))
  ($ scope 'agent-changed (agent "agent:4")
     (lambda (aid) (skill-specs-for-agent obs aid labour-here)))
  (check "the pool folds agent:4 under spec-cook (56h a week)"
         ($ scope 'total-hours #:skill "spec-cook") 56)
  (check "and never under the means spec"
         ($ scope 'total-hours #:skill "spec-oven") 0)

  (display "\n── the merge is commutative: one person in two scopes, either order ──\n")
  ;; ana is declared in two communes — 8h in one, 4h in the other. The
  ;; total keeps ONE reading (her fuller declaration), and which child the
  ;; parent combined first makes no difference.
  (define (agent-for id from to)
    (make-agent #:id id #:type 'person #:name id #:note "" #:image "" #:classified-as '()
                #:availability-window (make-availability-window #f #f #f (list (make-time-range from to)))))
  (define (two-scope-total first-second?)
    (let ((parent (spawn ^labour-pool (make-labour-pool) '()))
          (c1 (spawn ^labour-pool (make-labour-pool) '() "c1"))
          (c2 (spawn ^labour-pool (make-labour-pool) '() "c2")))
      ($ c1 'agent-changed (agent-for "ana" "09:00" "17:00") skills-fn)   ; 8h
      ($ c2 'agent-changed (agent-for "ana" "09:00" "13:00") skills-fn)   ; 4h
      (if first-second?
          (begin ($ parent 'child-changed "c1" ($ c1 'fold-total))
                 ($ parent 'child-changed "c2" ($ c2 'fold-total)))
          (begin ($ parent 'child-changed "c2" ($ c2 'fold-total))
                 ($ parent 'child-changed "c1" ($ c1 'fold-total))))
      ($ parent 'total-hours #:skill "skill:cook")))
  (check "c1 then c2: her fuller declaration stands (56h a week, not 84h a week)"
         (two-scope-total #t) 56)
  (check "c2 then c1: the same 56h a week — the merge is order-free"
         (two-scope-total #f) 56)
  ;; direct law on the monoid: a ⊕ b = b ⊕ a, and a ⊕ a = a
  ;; a week of 09:00–17:00 (56 h) beside a week of 09:00–13:00 (28 h)
  (let* ((e8 (make-entry "ana" "skill:cook" #f "r" 56))
         (e4 (make-entry "ana" "skill:cook" #f "r" 28))
         (pa (pool-add (make-labour-pool) e8))
         (pb (pool-add (make-labour-pool) e4)))
    (check "commutative: hours agree both ways"
           (list (pool-total-hours (pool-merge pa pb)) (pool-total-hours (pool-merge pb pa)))
           '(56 56))
    (check "idempotent: a pool merged with itself is itself"
           (pool-total-hours (pool-merge pa pa)) 56)))

(test-summary!)
