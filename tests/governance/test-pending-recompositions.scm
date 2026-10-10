;;; tests/governance/test-pending-recompositions.scm
;;;
;;; Unit coverage for the pending-recompositions registry. Doesn't
;;; spin up two gateways; just verifies the registry's behavior +
;;; the pattern combinators. Cross-gateway end-to-end goes in #47's
;;; integration test (deferred).

(use-modules (playnet test harness)
             (playnet credentials voting) (playnet keri acdc) (playnet keri acdc)
             (playnet federation pending-recompositions)
             (goblins)
             (srfi srfi-1))

(define vat (spawn-vat))

(define %reg (with-vat vat (spawn-pending-recompositions)))

;; ── empty state ──────────────────────────────────────────────────────

(check "fresh registry: count 0"
       (= 0 (with-vat vat ($ %reg 'count))))

;; ── register + fire-matching ────────────────────────────────────────

(define %fired '())

;; A "pattern" that matches anything; an "action" that records it.
(define %any-pattern (lambda (_cred) #t))
(define (record-action cred) (set! %fired (cons (cred-said cred) %fired)))

(with-vat vat ($ %reg 'register %any-pattern record-action))

(check "after register: count 1"
       (= 1 (with-vat vat ($ %reg 'count))))

(define %synthetic-cred
  (make-credential *schema-playnet-recomposition-ratification*
                   "E_uc_aid" "E_holder"
                   '((proposal-type . merge-with)
                     (predecessors  . ("E_fed_A" "E_fed_B")))
                   '()))

(define %n-matched
  (with-vat vat ($ %reg 'fire-matching %synthetic-cred)))

(check "fire-matching: returns 1"
       %n-matched 1)

(check "action fired with the credential"
       (and (= 1 (length %fired))
            (equal? (car %fired) (cred-said %synthetic-cred))))

(check "after fire: entry removed (one-shot)"
       (= 0 (with-vat vat ($ %reg 'count))))

;; ── non-matching pattern stays in registry ──────────────────────────

(define %never-pattern (lambda (_cred) #f))

(with-vat vat
  ($ %reg 'register %any-pattern record-action)
  ($ %reg 'register %never-pattern record-action))

(set! %fired '())
(with-vat vat ($ %reg 'fire-matching %synthetic-cred))

(check "mixed: only matching pattern fired (1)"
       (= 1 (length %fired)))

(check "mixed: non-matching pattern still in registry"
       (= 1 (with-vat vat ($ %reg 'count))))

;; ── pattern combinators ─────────────────────────────────────────────

(define %merge-pattern (proposal-type-is 'merge-with))
(define %split-pattern (proposal-type-is 'split-with))

(check "proposal-type-is matches merge ratification"
       (%merge-pattern %synthetic-cred))

(check "proposal-type-is rejects non-merge"
       (not (%split-pattern %synthetic-cred)))

(define %fed-a-pattern (predecessors-include "E_fed_A"))
(define %fed-c-pattern (predecessors-include "E_fed_C"))

(check "predecessors-include matches E_fed_A"
       (%fed-a-pattern %synthetic-cred))

(check "predecessors-include rejects unknown E_fed_C"
       (not (%fed-c-pattern %synthetic-cred)))

(check "and-pattern: matches when both match"
       ((and-pattern %merge-pattern %fed-a-pattern) %synthetic-cred))

(check "and-pattern: rejects when one fails"
       (not ((and-pattern %merge-pattern %fed-c-pattern) %synthetic-cred)))

(check "any-pattern: matches when either matches"
       ((any-pattern %split-pattern %fed-a-pattern) %synthetic-cred))

(check "any-pattern: rejects when none match"
       (not ((any-pattern %split-pattern %fed-c-pattern) %synthetic-cred)))

;; ── clear! ──────────────────────────────────────────────────────────

(with-vat vat ($ %reg 'clear!))
(check "clear! empties the registry"
       (= 0 (with-vat vat ($ %reg 'count))))

(test-summary!)
