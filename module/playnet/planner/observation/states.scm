;;; observation/states.scm — the states the books hold as records.
;;;
;;; Three shapes of a reading and one stored record. The readings: how much of a
;;; commitment is fulfilled, how much of an intent is satisfied, how much of a
;;; claim is settled. The observer builds each from the events when it is asked
;;; (fulfillment-of, satisfaction-of, claim-state-of) and stores none: it holds the
;;; registered target, which the Commitment, Intent or Claim states. The record: a
;;; person's credit account (claimed capacity and the contribution-capacity factor). ValueFlows defines none of them as a class:
;;; `fulfills`, `satisfies` and `settles` are relations on events, and the states
;;; are what following them yields.
;;;
;;; Route into the core (docs/planning/codebase-organization.md §7): the three
;;; tracking states are derived from the events and stored nowhere, so they are
;;; already what VF says they are; and an account is an EconomicResource of a credit
;;; specification moved by events (valueflows-accounting-rules.md Q11).

(define-module (playnet planner observation states)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet planner vf serdes) #:select (register-vf-records!))
  #:export (<fulfillment-state> make-fulfillment-state fulfillment-state?
            fulfillment-state-commitment-id fulfillment-state-total-committed
            fulfillment-state-total-fulfilled fulfillment-state-fulfilling-events
            fulfillment-state-finished fulfillment-state-over-fulfilled
            <satisfaction-state> make-satisfaction-state copy-satisfaction-state
            satisfaction-state? satisfaction-state-intent-id
            satisfaction-state-total-desired satisfaction-state-total-satisfied
            satisfaction-state-satisfying-events
            satisfaction-state-satisfying-commitments satisfaction-state-finished
            satisfaction-state-plan-id <claim-state> make-claim-state claim-state?
            claim-state-claim-id claim-state-total-claimed claim-state-total-settled
            claim-state-settling-events claim-state-finished <account> make-account
            account? account-agent-id account-claimed-capacity
            account-contribution-capacity-factor))

;; ═══════════════════════════════════════════════════════════════════════
;; OBSERVER TRACKING STATE
;; ═══════════════════════════════════════════════════════════════════════

;;; FulfillmentState — tracks how much of a Commitment has been fulfilled.
;;; Fields: commitment-id (string), total-committed (<measure>),
;;;         total-fulfilled (<measure>), fulfilling-events (list of event IDs),
;;;         finished (boolean), over-fulfilled (boolean).
(define <fulfillment-state>
  (vf-record-type 'FulfillmentState
    '((immutable commitment-id)
      (immutable total-committed)
      (immutable total-fulfilled)
      (immutable fulfilling-events)
      (immutable finished)
      (immutable over-fulfilled))))

(define make-fulfillment-state              (vf-record-constructor <fulfillment-state>))
(define fulfillment-state?                  (vf-record-predicate   <fulfillment-state>))
(define fulfillment-state-commitment-id     (vf-record-accessor    <fulfillment-state> 'commitment-id))
(define fulfillment-state-total-committed   (vf-record-accessor    <fulfillment-state> 'total-committed))
(define fulfillment-state-total-fulfilled   (vf-record-accessor    <fulfillment-state> 'total-fulfilled))
(define fulfillment-state-fulfilling-events (vf-record-accessor    <fulfillment-state> 'fulfilling-events))
(define fulfillment-state-finished          (vf-record-accessor    <fulfillment-state> 'finished))
(define fulfillment-state-over-fulfilled    (vf-record-accessor    <fulfillment-state> 'over-fulfilled))


;;; SatisfactionState — tracks how much of an Intent has been satisfied,
;;; and which plan it belongs to (mirrored from intent.planned-within).
;;; Federation-level validation lives on the plan (see ^observer's
;;; plan-validations + `confirm-plan`); satisfaction-state's plan-id
;;; is the link the gate joins through.
;;; Fields: intent-id (string), total-desired (<measure>),
;;;         total-satisfied (<measure>), satisfying-events (list of event IDs),
;;;         satisfying-commitments (list of commitment IDs), finished (boolean),
;;;         plan-id (string or #f — the plan this intent is part of, if any).
(define <satisfaction-state>
  (vf-record-type 'SatisfactionState
    '((immutable intent-id)
      (immutable total-desired)
      (immutable total-satisfied)
      (immutable satisfying-events)
      (immutable satisfying-commitments)
      (immutable finished)
      (immutable plan-id))))

(define make-satisfaction-state                  (vf-record-constructor <satisfaction-state>))
(define copy-satisfaction-state                  (vf-record-copier      <satisfaction-state>))
(define satisfaction-state?                      (vf-record-predicate   <satisfaction-state>))
(define satisfaction-state-intent-id             (vf-record-accessor    <satisfaction-state> 'intent-id))
(define satisfaction-state-total-desired         (vf-record-accessor    <satisfaction-state> 'total-desired))
(define satisfaction-state-total-satisfied       (vf-record-accessor    <satisfaction-state> 'total-satisfied))
(define satisfaction-state-satisfying-events     (vf-record-accessor    <satisfaction-state> 'satisfying-events))
(define satisfaction-state-satisfying-commitments (vf-record-accessor   <satisfaction-state> 'satisfying-commitments))
(define satisfaction-state-finished              (vf-record-accessor    <satisfaction-state> 'finished))
(define satisfaction-state-plan-id               (vf-record-accessor    <satisfaction-state> 'plan-id))


;;; ClaimState — tracks how much of a Claim has been settled.
;;; Fields: claim-id (string), total-claimed (<measure>),
;;;         total-settled (<measure>), settling-events (list of event IDs),
;;;         finished (boolean).
(define <claim-state>
  (vf-record-type 'ClaimState
    '((immutable claim-id)
      (immutable total-claimed)
      (immutable total-settled)
      (immutable settling-events)
      (immutable finished))))

(define make-claim-state              (vf-record-constructor <claim-state>))
(define claim-state?                  (vf-record-predicate   <claim-state>))
(define claim-state-claim-id          (vf-record-accessor    <claim-state> 'claim-id))
(define claim-state-total-claimed     (vf-record-accessor    <claim-state> 'total-claimed))
(define claim-state-total-settled     (vf-record-accessor    <claim-state> 'total-settled))
(define claim-state-settling-events   (vf-record-accessor    <claim-state> 'settling-events))
(define claim-state-finished          (vf-record-accessor    <claim-state> 'finished))


;; ═══════════════════════════════════════════════════════════════════════
;; COMMUNE ACCOUNT (labor-credit system)
;; ═══════════════════════════════════════════════════════════════════════

;;; Account — per-agent claim-capacity and capacity-factor tracker.
;;; Gross social labor is NOT stored here — it's derived from observer
;;; events via the Validation Gate (§III.1), so there's no cache to
;;; drift. The account record only holds what is genuinely per-agent
;;; persistent state: how much of the pool this agent has already
;;; claimed, and their Contribution Capacity Factor.
;;; Fields: agent-id (string),
;;;         claimed-capacity (number, running total claimed from pool),
;;;         contribution-capacity-factor (number 0-1, ability to contribute).
(define <account>
  (vf-record-type 'Account
    '((immutable agent-id)
      (immutable claimed-capacity)
      (immutable contribution-capacity-factor))))

(define make-account                              (vf-record-constructor <account>))
(define account?                                  (vf-record-predicate   <account>))
(define account-agent-id                          (vf-record-accessor    <account> 'agent-id))
(define account-claimed-capacity                  (vf-record-accessor    <account> 'claimed-capacity))
(define account-contribution-capacity-factor      (vf-record-accessor    <account> 'contribution-capacity-factor))

;; ── persistence: these records register their own types ─────────────────────
(register-vf-records!
  <fulfillment-state>
  <satisfaction-state>
  <claim-state>
  <account>)
