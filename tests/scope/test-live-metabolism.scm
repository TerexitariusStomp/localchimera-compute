;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-live-metabolism.scm — the live planner re-solves on drift, warm-started.
;;;
;;; "Solved" sets targets; "metabolised" adapts them between solves. A ^live-planner
;;; holds the standing plan and warm-starts the next solve from it. It ignores small
;;; drifts (the standing plan stands) and re-solves big ones — cheaper than a cold
;;; solve because it re-centres from the standing optimum.

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet algorithms elastic) (playnet vf schemas)
             (playnet scope live)
             (playnet test planner bread)
             (goblins) (goblins vat)
             (srfi srfi-1))

;; bread chain; the farmer's 8h caps grow at 16 grain ⇒ soil binds only below ~16.
(define procs bread-procs) (define flows bread-flows) (define recipes bread-recipes)
(define resources-at bread-resources-at)
(define obs-res (resources-at 30.0))
(define agents bread-plain-agents) (define spatials bread-spatials)

(define results
  (with-vat (spawn-vat #:name "metab")
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () obs-res)))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:procs procs #:flows flows))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs))
           ;; reproduce? #f: this suite isolates the WARM-START METABOLISM (drift
           ;; detection + re-centring), so it plans the bread demand alone. With
           ;; reproduction on (the live default, since c163eddd) the three worker-
           ;; persons would also be fed from this same chain, spending labour and
           ;; pulling met below the clean labour-bound 66.7% the comments below
           ;; describe. Reproduction economics have their own coverage
           ;; (test-reproduction-diet.scm); here we want the bare solver regime.
           (lp (spawn-live-planner scope #:demand '(("bread#town@0" . 20.0))
                                   #:drift-threshold 0.1 #:reproduce? #f)))
      (let ((initial ($ lp 'plan)))
        (set! obs-res (resources-at 28.0)) (define small  ($ lp 'on-event 'e1))    ; tiny drift
        (set! obs-res (resources-at 22.0)) (define modst  ($ lp 'on-event 'e2))    ; crosses threshold; optimum stable (labour-bound)
        (set! obs-res (resources-at 8.0))  (define shock  ($ lp 'on-event 'e3))    ; soil now binds below labour
        (list initial small modst shock ($ lp 'plan))))))

(define initial (list-ref results 0))
(define small   (list-ref results 1))
(define modst   (list-ref results 2))
(define shock   (list-ref results 3))
(define final   (list-ref results 4))

(display "\n── live planner: drift-triggered, warm-started metabolism ──\n")
(check "initial cold solve met ~66.7% (labour-bound)" (> (assq-ref initial 'met) 0.6))
(check "small drift (soil 30→28): NOT re-solved (standing plan stands)"
       (not (assq-ref small 'resolved)))
(check "small drift is below the threshold" (< (assq-ref small 'drift) 0.1))
(check "moderate drift (soil 30→22): re-solved" (assq-ref modst 'resolved))
(check "moderate re-solve is WARM and cheap (fewer Newton steps than the cold solve)"
       (< (assq-ref modst 'newton) (assq-ref initial 'newton)))
(check "moderate re-solve keeps met (optimum still labour-bound, barely moves)"
       (> (assq-ref modst 'met) 0.6))
(check "big shock (soil 30→8): re-solved, met DROPS (soil now binds)"
       (and (assq-ref shock 'resolved) (< (assq-ref shock 'met) 0.5)))
(check "the standing plan reflects the shock" (< (assq-ref final 'met) 0.5))

;; Enabled by default: every live solve publishes the plan's social free time f
;; (plan-results->alist → set-social-free-time!), so drawable credit + consumer
;; voice fold in the citizenship dividend with no extra call. Before any solve it
;; is 0; here real solves have run, so f is a live fraction in (0,1].
(check "live solve publishes social free time f (citizenship enabled by default)"
       (let ((f (current-social-free-time))) (and (> f 0) (<= f 1))))

(test-summary!)
