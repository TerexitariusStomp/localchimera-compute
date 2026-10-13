;;; test-free-time-whatif.scm — a question never moves the published f.
;;;
;;; Credit and consumer voice read ONE social free time, `current-social-free-time`,
;;; the f of the plan that stands. A solve asked as a question — a what-if with
;;; its own demand, the three bills, a dilemma horn — answers and stands for
;;; nothing, so it leaves f where the standing plan put it. The standing plan
;;; (the live planner's) publishes.
;;;
;;; Run:  guile -L module tests/scope/test-free-time-whatif.scm
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet algorithms elastic) (playnet vf schemas)
             (playnet scope live)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define procs bread-procs) (define flows bread-flows) (define recipes bread-recipes)
(define obs-res (bread-resources-at 30.0))
(define agents bread-plain-agents) (define spatials bread-spatials)

(define (free-time-of alist) (assq-ref (assq-ref alist 'social) 'free-time))

(set-social-free-time! 0)

(define results
  (with-vat (spawn-vat #:name "free-time-whatif")
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () obs-res)))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes)) (get-process-chain . ,(lambda (r) procs))
                               (flows-for-process . ,(lambda (pid) (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid) (equal? (recipe-flow-recipe-output-of f) pid))) flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs))
           (lp (spawn-live-planner scope #:demand '(("bread#town@0" . 20.0)) #:reproduce? #f))
           (standing ($ lp 'plan))
           (f-standing (current-social-free-time))
           ;; the question: a smaller demand, so a different plan with a different f
           (what-if (plan-scope->alist scope #:demand '(("bread#town@0" . 4.0)) #:reproduce? #f))
           (f-after (current-social-free-time))
           (bills (scope-bills scope #:demand '(("bread#town@0" . 20.0)) #:reproduce? #f))
           (f-after-bills (current-social-free-time)))
      (list standing f-standing what-if f-after f-after-bills))))

(define standing       (list-ref results 0))
(define f-standing     (list-ref results 1))
(define what-if        (list-ref results 2))
(define f-after        (list-ref results 3))
(define f-after-bills  (list-ref results 4))

(display "\n── the standing plan publishes; a question leaves it ──\n")
(check "the standing plan published its own f"
       (and (> f-standing 0) (< (abs (- f-standing (free-time-of standing))) 1e-9)))
(check "the what-if is a different plan with a different f (the question is real)"
       (> (abs (- (free-time-of what-if) f-standing)) 1e-6))
(check "a what-if solve leaves the published f where the standing plan put it"
       (< (abs (- f-after f-standing)) 1e-9))
(check "the three bills leave it there too"
       (< (abs (- f-after-bills f-standing)) 1e-9))

(test-summary!)
