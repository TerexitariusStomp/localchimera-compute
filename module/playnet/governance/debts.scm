;;; debts.scm — the representation of "the commons owes this member back."
;;;
;;; A purchase's reimbursement: a member fronts their own money for something
;;; the commons already wanted, buys it, and the commons owes them back what
;;; it cost, once its own gov-cap accepts the debt (accept-reimbursement,
;;; governance/scope.scm). ONE debt shape (a commitment-credential, issuer =
;;; commune, holder = member, action 'transfer), ONE settlement read.
;;;
;;; This module originally also carried a LOAN primitive — a consume-grant's
;;; accept-socialization reciprocal minting the same debt shape, so a loan's
;;; repayment and a purchase's reimbursement read identically to payout
;;; settlement. The loan half was deliberately removed: private bilateral
;;; repayment let a borrower take commons-lent value into ordinary wage-labour
;;; production and launder the resulting surplus back in as a clean
;;; recipe-priced object — a real circuit seam no provenance check
;;; on the repaid object could close without becoming an unenforceable audit
;;; regime (see socialization.scm's grant-consume? comment for the full
;;; reasoning, and project_consume_grant_money.md). What remains is exactly
;;; the reimbursement half; the shape stays general (nothing here says
;;; "reimbursement" specifically) in case a future non-loan use for "the
;;; commons owes X back" turns up, but accept-reimbursement is its only door
;;; today.
;;;
;;; WHY THIS LIVES IN GOVERNANCE, NOT THE PLANNER: settling a debt needs
;;; BOTH what the acdc-store says is owed AND the planner's own price
;;; (crystallized-snlt-for-spec, to convert into XMR) — and the planner
;;; stays governance-agnostic by design (plan-scope takes a #:resource-view
;;; transform; the caller supplies the projection — socialization.scm's own
;;; header says so). Governance already depends on the planner one-way;
;;; the reverse would be a module cycle. So `^planner-service`'s payout
;;; methods reach this the same way they already reach socialization —
;;; injected as a plain procedure at spawn time (mirroring `socialized-plan-fn`
;;; and `#:plan-fn`), never imported. planner/doors/service.scm never says
;;; `(use-module (playnet governance ...))`.
;;;
;;; PARTIAL SETTLEMENT is event-sourced, not a mutable balance: a debt
;;; commitment states its FULL face amount, immutably, for its whole life.
;;; Each part-payment is its own VF `transfer` event on the observer, id
;;; `"debt-paid:" <said> ":" <stamp>`, in the debt's OWN spec and unit —
;;; "how much is left" is the face amount minus the sum of those events,
;;; read fresh every time, the same "derived at read time, nothing stored"
;;; discipline `credit->wire` already uses for the labour ledger. A debt
;;; fully paid down is REVOKED (issuer-owned, and here the issuer — the
;;; commune — and the settler are the same trusted process, so no
;;; re-signing is needed to revoke; only MINTING a new debt needs the
;;; scope's own signature, which is why accept-reimbursement is a ^scope
;;; method and this file's own functions are not).

(define-module (playnet governance debts)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet governance credentials)
  #:use-module (playnet governance acdc-store)
  #:use-module (playnet keri acdc)
  #:use-module (playnet planner algorithms rollup)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner algorithms rollup)
  #:export (money-rate debt-commitment purchase-claim open-debts debt-remaining
            debt->alist open-debts-alist debts-owed-in-xmr settle-debts! %payout-spec))

(define %payout-spec "spec-xmr")

(define (money-rate rs from-spec to-spec)
  "How many TO-SPEC one FROM-SPEC is worth — through the labour each costs
   to acquire (crystallized SNLT of the acquisition recipes), the one price
   the commons has. #f when either has no recipe."
  (let ((a (false-if-exception (crystallized-snlt-for-spec rs from-spec)))
        (b (false-if-exception (crystallized-snlt-for-spec rs to-spec))))
    (and (number? a) (number? b) (finite? a) (finite? b) (> b 0) (/ a b))))

;; ── Minting: the shape every debt takes ─────────────────────────────────────
;; TRIGGERED-BY: the SAID of the member's own purchase-claim this debt
;; arises from — the VF triggeredBy relation (docs/valueflows examples,
;; "Claim for income"). The debt carries its provenance itself; no
;; Agreement wrapper is minted around the pair, because VF reserves the
;; Agreement for binding reciprocal PROMISES (accept-socialization's case:
;; a grant offer and a return commitment, both forward-looking), and a
;; purchase-claim attests a PAST fact — there is nothing left to promise
;; on the member's side, only the commune's reciprocal to trigger.
(define* (debt-commitment commune-aid member-aid id spec qty unit due
                          #:key (triggered-by #f) (signing-keypair #f))
  (make-commitment-credential
   commune-aid member-aid id 'transfer
   #:resource-conforms-to spec
   #:resource-quantity (cons qty (or unit spec))
   #:due due
   #:triggered-by triggered-by
   #:signing-keypair signing-keypair))

;; ── The trigger: the member's OWN signed claim ──────────────────────────────
;; "I gave the commons QTY of SPEC" — issuer = the member, signed with the
;; member's own key, client-side (mirroring socialize-preimage/-signed —
;; the key never leaves the browser), never fabricated by governance.
;; accept-reimbursement (governance/scope.scm) reads this pre-existing,
;; independently-signed claim and mints the reciprocal debt with
;; triggered-by = this claim's SAID. Same construction as debt-commitment,
;; issuer/holder reversed: the debt says what the commune owes back; the
;; claim says what the member already gave.
;;
;; RESOURCE-INVENTORIED-AS: optionally names WHICH resource actually paid
;; (VF resourceInventoriedAs). Named, the funding-source check becomes a
;; direct read — a resource under a live consume-grant to the commune is a
;; self-attested spend of already-socialized money and the acceptance
;; refuses outright; an ungranted one clears the coarse spec-wide flag.
;; Unnamed (the common case — most members don't track their own cash as
;; an in-system resource), the coarse flag stands. Signed either way, so
;; the naming is the member's own contestable word, not governance's guess.
;; TRIGGERED-BY here is the PURCHASE EVENT's id (VF Claim.triggeredBy is an
;; EconomicEvent — schemas.scm's own <claim> comment), closing the chain:
;; the raise event (which itself fulfills/satisfies the plan's records —
;; record-purchase) triggers the member's claim, which triggers the
;; commune's debt. Provenance end to end, every link an existing VF field.
(define* (purchase-claim member-aid commune-aid id spec qty unit due
                         #:key (resource-inventoried-as #f) (triggered-by #f)
                               (signing-keypair #f))
  (make-commitment-credential
   member-aid commune-aid id 'transfer
   #:resource-conforms-to spec
   #:resource-quantity (cons qty (or unit spec))
   #:due due
   #:resource-inventoried-as resource-inventoried-as
   #:triggered-by triggered-by
   #:signing-keypair signing-keypair))

;; ── Reading: every live debt, whoever minted it ─────────────────────────────
(define (open-debts store commune-aid aid)
  "Every live (unrevoked) debt COMMUNE-AID owes AID: a commitment-credential
   it issued, AID holds, action transfer."
  (filter (lambda (c)
            (and (equal? *schema-playnet-commitment* (cred-schema c))
                 (equal? commune-aid (cred-issuer c))
                 (equal? aid (cred-holder c))
                 (eq? 'transfer (cred-claim c 'action))
                 (cred-live? c #f)))
          ($ store 'all)))

;; how much of a debt's face amount is still open, read off the observer's
;; own part-payment events — see the module header. OBS may be #f (no
;; observer in reach): reads as "nothing paid yet", the safe default.
(define (debt-remaining obs k)
  (let* ((face (cred-claim k 'resource-quantity))
         (amt  (and (pair? face) (car face)))
         (paid (if obs
                   (fold + 0.0
                         (filter-map
                          (lambda (e)
                            (and (string-prefix? (string-append "debt-paid:" (cred-said k) ":")
                                                 (or (economic-event-id e) ""))
                                 (measure-has-numerical-value (economic-event-resource-quantity e))))
                          ($ obs 'all-events)))
                   0.0)))
    (max 0.0 (- (or amt 0) paid))))

(define (debt->alist obs k)
  (let ((face (cred-claim k 'resource-quantity)))
    `((id      . ,(cred-said k))
      (aid     . ,(cred-holder k))
      (spec    . ,(cred-claim k 'resource-conforms-to))
      (amount  . ,(and (pair? face) (car face)))
      (unit    . ,(and (pair? face) (cdr face)))
      (remaining . ,(debt-remaining obs k))
      (due     . ,(or (cred-claim k 'due) ""))
      (since   . ,""))))

;; the ready-made INJECTABLE read: exactly the shape `^planner-service`'s
;; payout methods want to call (obs store commune-aid aid) → the listing a
;; my-reimbursements-equivalent shows. Gateway.scm hands this function
;; itself (not a closure over it) to `^planner-service` at spawn — the same
;; "governance is injected, never imported" seam `socialized-plan-fn` uses.
(define (open-debts-alist obs store commune-aid aid)
  (map (lambda (k) (debt->alist obs k)) (open-debts store commune-aid aid)))

(define (debts-owed-in-xmr rs obs store commune-aid aid)
  "What COMMUNE-AID owes AID, summed in XMR at the acquisition-SNLT ratio.
   A debt in a spec with no recipe to price it by is owed but not payable
   in XMR, so it stays out of the sum — same graceful skip money-rate
   always had."
  (fold + 0.0
        (filter-map
         (lambda (k)
           (let ((left (debt-remaining obs k)))
             (and (> left 1e-9)
                  (let ((rate (money-rate rs (cred-claim k 'resource-conforms-to) %payout-spec)))
                    (and rate (* rate left))))))
         (open-debts store commune-aid aid))))

(define* (settle-debts! rs obs store commune-aid aid xmr #:key (stamp (iso-utc-now)))
  "Pay down AID's open debts, oldest-first, with XMR worth of payout. Each
   part-payment is recorded as its own transfer event on OBS, in the debt's
   own spec; a debt paid down to (near) zero is revoked. Returns the XMR
   left over, for the claim to cover."
  (let loop ((ks (sort (open-debts store commune-aid aid)
                       (lambda (a b) (string<? (cred-said a) (cred-said b)))))
             (left xmr) (n 0))
    (if (or (null? ks) (<= left 1e-9))
        (max 0.0 left)
        (let* ((k     (car ks))
               (spec  (cred-claim k 'resource-conforms-to))
               (unit  (or (and (pair? (cred-claim k 'resource-quantity))
                               (cdr (cred-claim k 'resource-quantity)))
                          spec))
               (rate  (money-rate rs spec %payout-spec))
               (rem   (debt-remaining obs k)))
          (if (or (not rate) (<= rem 1e-9))
              (loop (cdr ks) left n)
              (let* ((rem-in-xmr (* rate rem))
                     (xmr-here   (min left rem-in-xmr))
                     (paid-face  (/ xmr-here rate)))
                ($ obs 'record-event
                   (make-economic-event
                    #:id (string-append "debt-paid:" (cred-said k) ":" stamp "-" (number->string n))
                    #:action 'transfer #:resource-conforms-to spec #:resource-classified-as '("reimbursement")
                    #:provider commune-aid #:receiver aid
                    #:resource-quantity (make-measure paid-face unit) #:has-point-in-time stamp #:created stamp
                    #:note "settled via payout"))
                (when (>= (+ paid-face 1e-9) rem)
                  ($ store 'revoke (cred-said k)))
                (loop (cdr ks) (- left xmr-here) (+ n 1))))))))
