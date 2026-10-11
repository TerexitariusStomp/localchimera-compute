;;; module/playnet/economy/payouts.scm — a payout intent: what a member may still ask to send, its state, its row.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet economy payouts)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet vf schemas) #:select (copy-intent economic-resource-onhand-quantity intent-has-beginning intent-id intent-provider intent-resource-quantity intent-state measure-has-numerical-value))
  #:use-module ((srfi srfi-1) #:select (fold))
  #:export (intent-private? payout-source-id monero-address-plausible? payouts-of payout-available
            payout-open? payout-restate!))

(define (intent-private? i)
  "An intent that names something of one member's that no other reader is
   owed — today the payout intents, which carry a destination address. Kept
   out of the snapshot and the query door; the member reads their own via
   my-payouts."
  (let ((id (intent-id i)))
    (and (string? id) (string-prefix? "payout:" id))))
(define (payout-source-id aid)
  "The member's claimed-XMR record: what the shop's claim of `res-xmr-main`
   lands in (account.scm: to-resource = resource-id ^ \"-\" ^ aid)."
  (string-append "res-xmr-main-" aid))
(define (monero-address-plausible? a)
  "Shape check only — a standard/sub address (95) or an integrated one (106)
   in the base58 alphabet. The wallet is the authority on validity; this
   keeps a typo from becoming a parked intent."
  (and (string? a)
       (memv (string-length a) '(95 106))
       (string-every (lambda (c)
                       (string-index "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" c))
                     a)
       #t))
(define (payouts-of ps aid)
  "The payout intents, AID's own or (AID #f) everyone's, oldest first."
  (sort (filter (lambda (i)
                  (and (string? (intent-id i))
                       (string-prefix? "payout:" (intent-id i))
                       (or (not aid) (equal? aid (intent-provider i)))))
                ($ ps 'all-intents))
        (lambda (a b) (string<? (intent-id a) (intent-id b)))))
(define* (payout-available obs ps aid #:key (owed 0.0))
  "What AID may still ask to send: their claimed XMR on hand, plus OWED (what
   the commons owes them, already priced in XMR — economy/debts.scm
   debts-owed-in-xmr, injected as owed-of; see the ^planner-service header),
   less every payout of theirs still OPEN — pending, sending, or unsettled
   (a transfer the gateway lost sight of reserves the claim until an
   operator settles or fails it, so a re-ask can never pay twice)."
  (let* ((r  ($ obs 'get-resource (payout-source-id aid)))
         (oh (and r (economic-resource-onhand-quantity r)))
         (have (+ (if oh (measure-has-numerical-value oh) 0) owed))
         (pending (fold + 0 (map (lambda (i) (measure-has-numerical-value (intent-resource-quantity i)))
                                 (filter (lambda (i) (payout-open? (intent-state i)))
                                         (payouts-of ps aid))))))
    (max 0 (- have pending))))
(define (payout-open? state)
  (or (member state '("pending" "sending"))
      (and (string? state) (string-prefix? "unsettled:" state))))
(define* (payout-restate! ps i state finished? #:key (began (intent-has-beginning i)))
  "The intent with a new STATE (and finished flag), re-added silently —
   an intent is immutable, so a status change is remove + add of its twin.
   BEGAN (has-beginning) is the instant the coins started moving."
  ($ ps 'remove-intent (intent-id i))
  ($ ps 'add-intent-silent
     (copy-intent i #:has-beginning began #:state state #:finished finished?)))