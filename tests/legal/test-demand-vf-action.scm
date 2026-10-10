;;; test-demand-vf-action.scm — the single source of truth for the demand → VF
;;; action correspondence, and its use at the obligation lowering site.
;;;
;;; A <demand> is a legal requirement, not a flow; demand-kind->vf-action names
;;; the action its FULFILLMENT event carries when it lowers into VF. `forbid` has
;;; none — a prohibition prunes a column, it is not an economic event.
;;;
;;; Run: guile -L module tests/legal/test-demand-vf-action.scm

(use-modules (playnet test harness) (playnet vf schemas) (srfi srfi-1)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor)) (use-modules (playnet legal compliance))

;;; ─── 1. the canonical mapping (the single source of truth) ─────────────────
(display "\n── demand-kind->vf-action : obtain/pay/tell map, forbid does not ──\n")
(check "obtain fulfils by producing the held credential"
       (demand-kind->vf-action 'obtain) 'produce)
(check "pay fulfils by transferring money to the authority"
       (demand-kind->vf-action 'pay) 'transfer)
(check "tell fulfils by delivering a disclosure"
       (demand-kind->vf-action 'tell) 'deliver-service)
(check "forbid has NO fulfilment action (it prunes a column, not a flow)"
       (demand-kind->vf-action 'forbid) #f)
(check "every mapped action is a real VF action (or #f)"
       (every (lambda (k) (let ((a (demand-kind->vf-action k)))
                            (or (not a) (vf-action? a))))
              '(obtain pay tell forbid))
       #t)

;;; ─── 2. the lowering site routes the periodic-filing action through it ─────
(display "\n── obligation-for derives the periodic action from the demand kind ──\n")
(define exp "2026-12-31")
(define (periodic-action kind)
  (commitment-action
   (obligation-for "spec:levy" (cons 'every 'year) exp "scope:us" "auth:irs" #:kind kind)))
(check "a `pay` obligation is a transfer to the authority"
       (periodic-action 'pay) 'transfer)
(check "a `tell` obligation delivers a service (a disclosure)"
       (periodic-action 'tell) 'deliver-service)
(check "with no kind, the caller's default action is unchanged (compat)"
       (commitment-action
        (obligation-for "spec:levy" (cons 'every 'year) exp "scope:us" "auth:irs"))
       'deliver-service)
(check "renewal still lowers to `modify`, not obtain's fresh `produce`"
       (commitment-action
        (obligation-for "spec:permit" (cons 'renew-before 30) exp "scope:us" "auth:health"
                        #:kind 'obtain))
       'modify)

(display "\n")
(test-summary!)
