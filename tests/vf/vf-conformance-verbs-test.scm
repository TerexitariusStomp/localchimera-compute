;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; vf-conformance-verbs-test.scm — the sets of actions, held to the vocabulary.
;;;
;;; `(localchimera vf formulas actions)` answers the questions code asks of the action
;;; table (is this verb an input, does it consume, does it take effort) by predicates
;;; over the table's columns. This test asks the same questions of the TTL itself,
;;; parsed at run time by (localchimera test vf-ttl) and sharing no code with the repo's
;;; table, and the two answers must agree. A change to the table that moves a verb
;;; across one of these lines shows here, and the hand-spelled copies elsewhere in the
;;; tree are the ones that will not follow it (tools/lint/lint-verbs.scm counts them).
;;;
;;; Each pinned list is also the set the call site that was spelled by hand used to
;;; carry; the sites that now read `actions` are named beside it.
;;;
;;; Run:
;;;   cd <repo> && guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tests/vf/vf-conformance-verbs-test.scm

(use-modules (localchimera test harness)
             (localchimera vf schemas)
             (localchimera vf formulas actions)
             (srfi srfi-1))

(use-modules (localchimera test vf-ttl))

(define ttl (ttl-action-table (vf-repo-root)))

(define (ttl-where pred)
  "The TTL's actions whose property alist satisfies PRED."
  (filter-map (lambda (row) (and (pred (cdr row)) (car row))) ttl))
(define (prop row key) (assq-ref row key))

(define (same-set? a b)
  (and (= (length a) (length b)) (every (lambda (x) (memq x b)) a)))

(define-syntax-rule (check-set label derived pinned from-ttl)
  (begin
    (check (format #f "~a: the repo's set is the TTL's" label) (same-set? derived from-ttl))
    (check (format #f "~a: ~s" label pinned) (same-set? derived pinned))))

(format #t "\n── ~a actions in the TTL ──\n" (length ttl))

(check-set "process inputs" process-input-actions
           '(consume use work cite pickup accept combine)
           (ttl-where (lambda (r) (eq? (prop r 'input-output) 'input))))

(check-set "process outputs" process-output-actions
           '(produce dropoff modify separate deliver-service)
           (ttl-where (lambda (r) (memq (prop r 'input-output) '(output output-input)))))

;; ddmrp/buffers.scm read this as its own list: "actions whose onhandEffect is decrement"
(check-set "consuming inputs" consuming-actions
           '(consume combine pickup accept)
           (ttl-where (lambda (r) (and (eq? (prop r 'input-output) 'input)
                                       (eq? (prop r 'onhand-effect) 'decrement)))))

;; VF actions.md: produce makes a new resource, deliverService a new service; modify,
;; separate and dropoff hand back the same one
(check-set "what comes newly into being" creating-actions
           '(produce deliver-service)
           (ttl-where (lambda (r) (or (eq? (prop r 'input-output) 'output-input)
                                      (and (eq? (prop r 'input-output) 'output)
                                           (eq? (prop r 'accounting-effect) 'increment))))))
(check "what comes newly into being is made, and what is made beyond it hands back the same thing"
       (and (every (lambda (a) (memq a making-actions)) creating-actions)
            (same-set? (lset-difference eq? making-actions creating-actions) '(modify separate raise copy))))

;; VF actions.md, consume: "after the process the specified quantity … is gone"
(check-set "what is gone after the process" using-up-actions
           '(consume)
           (ttl-where (lambda (r) (and (eq? (prop r 'input-output) 'input)
                                       (eq? (prop r 'accounting-effect) 'decrement)))))

;; observation/observer.scm read this as its own list: the acts VF reads a custody transfer into
(check-set "acts on a thing in place" in-place-actions
           '(pickup dropoff accept modify)
           (ttl-where (lambda (r) (eq? (prop r 'location-effect) 'update))))

;; algorithms/propagation.scm read this as its own list: the flows that leave the stock alone
(check-set "inert flows" inert-flow-actions
           '(use work cite deliver-service)
           (ttl-where (lambda (r) (and (not (eq? (prop r 'input-output) 'not-applicable))
                                       (eq? (prop r 'onhand-effect) 'no-effect)))))

(check-set "effort-bearing" effort-actions
           '(use work)
           (ttl-where (lambda (r) (memq (prop r 'event-quantity) '(effort-quantity both)))))

;;; ── the books ───────────────────────────────────────────────────────────────

(define (moves-a-stock? r) (memq (prop r 'accounting-effect) '(increment decrement)))

(check-set "stock-moving" *stock-moving-actions*
           '(produce consume raise lower)
           (ttl-where moves-a-stock?))
(check-set "adjustments" *adjustment-actions*
           '(raise lower)
           (ttl-where (lambda (r) (and (moves-a-stock? r) (eq? (prop r 'input-output) 'not-applicable)))))
(check-set "flows" *flow-actions*
           '(produce consume)
           (ttl-where (lambda (r) (and (moves-a-stock? r) (not (eq? (prop r 'input-output) 'not-applicable))))))
(check-set "rights-moving" *rights-moving-actions*
           '(transfer transfer-all-rights)
           (ttl-where (lambda (r) (eq? (prop r 'accountable-effect) 'update-to))))

;;; ── what a recipe makes ─────────────────────────────────────────────────────
;;; The set is the table's (onhand increment, or made and handed over at once) less the
;;; relocations. It is also the set the reading it replaces gave: that reading named
;;; nine verbs "with a role of their own" by hand and then asked the table.

(check-set "making" making-actions
           '(produce modify separate raise copy deliver-service)
           (remove relocating-action?
                   (ttl-where (lambda (r) (or (eq? (prop r 'input-output) 'output-input)
                                              (memq (prop r 'onhand-effect) '(increment increment-to)))))))

(define %own-role-as-it-was
  '(work use cite pickup dropoff move transfer transfer-custody transfer-all-rights))
(check "making is what the hand-spelled reading gave, for every action of the TTL"
       (every (lambda (row)
                (let* ((a (car row))
                       (was (or (eq? a 'deliver-service)
                                (and (not (memq a %own-role-as-it-was))
                                     (memq (prop (cdr row) 'onhand-effect) '(increment increment-to)) #t))))
                  (eq? (and was #t) (and (memq a making-actions) #t))))
              ttl))

;;; ── the declared columns ────────────────────────────────────────────────────

(check "an acquisition planned as a produce is fulfilled by a raise, a loss by a lower"
       (and (same-flow? 'produce 'raise) (same-flow? 'raise 'produce)
            (same-flow? 'consume 'lower) (same-flow? 'lower 'consume)))
(check "an action fulfils its own kind, and the two pairs stay apart"
       (and (same-flow? 'work 'work) (not (same-flow? 'produce 'consume)) (not (same-flow? 'raise 'lower))))
(check "every action the fulfilment pairs name is stock-moving"
       (every (lambda (a) (memq a *stock-moving-actions*)) '(produce raise consume lower)))


(check "a relocation is a pickup or a dropoff" (same-set? relocating-actions '(pickup dropoff)))
(check "every relocating action is an action of the TTL" (every (lambda (a) (assq a ttl)) relocating-actions))
(check "pickup and accept are one row of the table apart from pairsWith"
       (let ((p (assq 'pickup ttl)) (a (assq 'accept ttl)))
         (every (lambda (k) (equal? (prop p k) (prop a k)))
                '(event-quantity input-output create-resource accounting-effect onhand-effect
                  location-effect contained-effect accountable-effect stage-effect state-effect))))
(check "relocating-action? answers for a member and a non-member"
       (and (relocating-action? 'pickup) (not (relocating-action? 'accept))))

(test-summary!)
