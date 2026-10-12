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

(define-module (playnet observation states)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet vf serdes) #:select (register-vf-records! register-vf-record!))
  #:export (make-fulfillment-state
            make-satisfaction-state
            copy-satisfaction-state
            make-claim-state
            make-account
            ;; the record declarations below define these (define-vf-record; check-record-exports holds the list)
            <fulfillment-state> fulfillment-state? fulfillment-state-commitment-id fulfillment-state-total-committed fulfillment-state-total-fulfilled fulfillment-state-fulfilling-events
            fulfillment-state-finished fulfillment-state-over-fulfilled <satisfaction-state> satisfaction-state? satisfaction-state-intent-id satisfaction-state-total-desired
            satisfaction-state-total-satisfied satisfaction-state-satisfying-events satisfaction-state-satisfying-commitments satisfaction-state-finished satisfaction-state-plan-id <claim-state>
            claim-state? claim-state-claim-id claim-state-total-claimed claim-state-total-settled claim-state-settling-events claim-state-finished
            <account> account? account-agent-id account-contribution-capacity-factor))

;; ═══════════════════════════════════════════════════════════════════════
;; OBSERVER TRACKING STATE
;; ═══════════════════════════════════════════════════════════════════════

;;; FulfillmentState — tracks how much of a Commitment has been fulfilled.
;;; Fields: commitment-id (string), total-committed (<measure>),
;;;         total-fulfilled (<measure>), fulfilling-events (list of event IDs),
;;;         finished (boolean), over-fulfilled (boolean).
(define-vf-record <fulfillment-state> FulfillmentState
  (commitment-id total-committed total-fulfilled fulfilling-events finished over-fulfilled)
  #:register register-vf-record!)

(define make-fulfillment-state              (vf-record-constructor <fulfillment-state>))


;;; SatisfactionState — tracks how much of an Intent has been satisfied,
;;; and which plan it belongs to (mirrored from intent.planned-within).
;;; Federation-level validation lives on the plan (see ^observer's
;;; plan-validations + `confirm-plan`); satisfaction-state's plan-id
;;; is the link the gate joins through.
;;; Fields: intent-id (string), total-desired (<measure>),
;;;         total-satisfied (<measure>), satisfying-events (list of event IDs),
;;;         satisfying-commitments (list of commitment IDs), finished (boolean),
;;;         plan-id (string or #f — the plan this intent is part of, if any).
(define-vf-record <satisfaction-state> SatisfactionState
  (intent-id total-desired total-satisfied satisfying-events satisfying-commitments finished plan-id)
  #:register register-vf-record!)

(define make-satisfaction-state                  (vf-record-constructor <satisfaction-state>))
(define copy-satisfaction-state                  (vf-record-copier      <satisfaction-state>))


;;; ClaimState — tracks how much of a Claim has been settled.
;;; Fields: claim-id (string), total-claimed (<measure>),
;;;         total-settled (<measure>), settling-events (list of event IDs),
;;;         finished (boolean).
(define-vf-record <claim-state> ClaimState
  (claim-id total-claimed total-settled settling-events finished)
  #:register register-vf-record!)

(define make-claim-state              (vf-record-constructor <claim-state>))


;; ═══════════════════════════════════════════════════════════════════════
;; COMMUNE ACCOUNT (labor-credit system)
;; ═══════════════════════════════════════════════════════════════════════

;;; Account — a person's Contribution Capacity Factor, and nothing else.
;;; Gross social labour is derived from the observer's work events through
;;; the Validation Gate (§III.1), and what the person has claimed from the
;;; pool from the observer's claim events (`claim-effort`): each a reading,
;;; so there is no cache to drift. The record holds the one fact that is
;;; stated rather than read: the factor.
;;; Fields: agent-id (string),
;;;         contribution-capacity-factor (number 0-1, ability to contribute).
(define-vf-record <account> Account
  (agent-id contribution-capacity-factor)
  #:register register-vf-record!)

(define make-account                              (vf-record-constructor <account>))

;; ── persistence: these records register their own types ─────────────────────
;; each type registers itself as it is declared (define-vf-record #:register)
