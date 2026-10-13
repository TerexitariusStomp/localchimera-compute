;;; module/playnet/doors/planner/money.scm — money: a member's payouts from request to settlement, a purchase for the commons, and a credit balance read
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner money)
  #:use-module ((playnet vf formulas flows) #:select (make-transfer-event))
  #:use-module ((playnet observation adjustment) #:select (adjustment-event))
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors counts) #:select (fresh-label))
  #:use-module ((playnet doors plan-wire) #:select (wire-number))
  #:use-module ((playnet doors record-rows) #:select (payout->alist))
  #:use-module ((playnet economy debts) #:select (%payout-spec))
  #:use-module ((playnet economy payouts) #:select (monero-address-plausible? payout-available payout-move! payout-pending? payout-sending? payout-source-id payout-row-context payout-txid payouts-of payouts-where))
  #:use-module ((playnet wire rows) #:select (with-context))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure success))
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet vf formulas actions) #:select (same-flow? using-up-actions))
  #:use-module ((playnet vf schemas) #:select (commitment-action commitment-finished commitment-id commitment-resource-conforms-to economic-resource-id intent-action intent-due intent-finished intent-id intent-provider intent-resource-conforms-to intent-resource-quantity make-economic-event make-economic-resource make-intent make-measure measure-has-numerical-value))
  #:use-module ((srfi srfi-1) #:select (filter-map find))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-money-doors))

;; what a payout row reads its word and began through (doors/record-rows.scm
;; payout table): the plan-store's reading of each intent, handed in context
(define (payout-ctx ps)
  `((payout-of . ,(lambda (i) (payout-row-context ps i)))))

(define (planner-money-doors ctx)
  (with-planner-ctx ctx
    ;; the ledger's side of a settlement: what the commons OWED is paid first,
    ;; via the injected settle-of (economy/debts.scm settle-debts!, which
    ;; records its own "debt-paid:" events per debt and revokes any fully-paid
    ;; ones); the claim bears the rest. The records say the coins LEFT — to
    ;; the chain, as one opaque external holder — and never the address: the
    ;; event, its destination record and the txid note reach every member's
    ;; snapshot; the address stays on the private payout intent (my-payouts)
    ;; and the chain itself.
    (define (ledger-settled! root scope-id i txid store)
      (let* ((obs  ($ root 'observer))
             (rs   ($ root 'recipe-store))
             (aid  (intent-provider i))
             (xmr  (measure-has-numerical-value (intent-resource-quantity i)))
             (left (if (and settle-of store) (settle-of rs obs store scope-id aid xmr) xmr))
             (transfer (lambda (id from provider qty note)
                         ($ obs 'record-event
                            (make-transfer-event
                             #:id id #:from from #:to "res-xmr-chain"
                             #:spec %payout-spec #:tags '("currency" "external")
                             #:provider provider #:receiver "monero-chain"
                             #:qty qty #:unit "XMR" #:when (iso-now)
                             #:fulfills (string-append "sending:" (intent-id i))   ; the commons' commitment to send it (economy/payouts.scm)
                             #:note (string-append note txid))))))
        (when (> (- xmr left) 1e-12)
          (transfer (string-append "payout-owed:" txid) "res-xmr-main" scope-id (- xmr left) "reimbursement paid on-chain, txid "))
        (when (> left 1e-12)
          (transfer (string-append "payout-sent:" txid) (payout-source-id aid) aid left "sent on-chain, txid "))))
    ;; the rows of everyone's payouts that KEEP? accepts, as the runner reads them
    (define (payout-rows scope-id keep?)
      (scoped scope-id (lambda (root)
                         (let ((ps ($ root 'plan-store)))
                           (map (lambda (i) (payout->alist i (payout-ctx ps))) (payouts-where ps keep?))))))

    (declared-doors planner

      ;; Read: a person's credit standing in this scope — gross (validated work)
      ;; minus claimed (individually-claimable draws). The UI shows it as purchasing
      ;; power; it equals reconstruct-credit-balance over the scope's ACDC set.
      ((credit-balance scope-id agent-id)
       (scoped scope-id
         (lambda (root)
`((balance . ,(wire-number ($ ($ root 'observer) 'credit-balance agent-id)))))))

      ;; ── Payouts: "send N XMR of mine to ⟨address⟩" ───────────────────────
      ;; A member's monero is a CLAIM on the commons' wallet (the shop's claim
      ;; path moves `res-xmr-main` into `res-xmr-main-<aid>` against earned
      ;; credit). A payout is the member's standing INTENT to have the commons
      ;; send some of that claim on-chain to a destination they name — a VF
      ;; `transfer` intent under the reserved prefix "payout:", provider = the
      ;; member, the external address as its at-location, kept in the plan-store so it
      ;; persists with the scope and shows in their slots. No member key is
      ;; ever involved: the wallet is the commons' and its ^wallet-policy is
      ;; the only thing that spends. The runner (monero/payout.scm) reads
      ;; `due-payouts`, moves the coins under the policy, and calls
      ;; `settle-payout` (a VF transfer event out of the member's claim, fulfilling
      ;; the commons' commitment to send, txid on its ending) or `fail-payout`
      ;; (the claim stays whole). economy/payouts.scm states the records.
      ((request-payout scope-id agent-id store address xmr due note)
       (scoped scope-id
         (lambda (root)
(let* ((ps   ($ root 'plan-store))
                      (obs  ($ root 'observer))
                      (rs   ($ root 'recipe-store))
                      (addr (and (string? address) (string-trim-both address)))
                      (q    (cond ((number? xmr) xmr)
                                  ((and (string? xmr) (string->number xmr)) => (lambda (n) n))
                                  (else 0))))
                 (unless (monero-address-plausible? addr)
                   (error "that is not a Monero address" addr))
                 (unless (> q 0) (error "amount must be positive" xmr))
                 (let* ((owed  (if (and owed-of store) (owed-of rs obs store scope-id agent-id) 0.0))
                        (avail (payout-available obs ps agent-id #:owed owed))
                        ;; the instant plus the member's running count — two asks
                        ;; in one second are two intents
                        (iid   (string-append "payout:" agent-id ":" (iso-now) ":"
                                              (number->string (length (payouts-of ps agent-id))))))
                   (when (> q avail)
                     (error (format #f "you hold ~a XMR claimable; ~a asked" avail q)))
                   ($ ps 'add-intent-silent
                      (make-intent
                       #:id iid #:action 'transfer #:name "send XMR" #:note (string-or-false note) #:image "🪙"
                       #:resource-inventoried-as (payout-source-id agent-id) #:resource-conforms-to %payout-spec
                       #:resource-quantity (make-measure q "XMR")
                       #:provider agent-id #:due (string-or-false due)
                       ;; the destination is a PLACE outside the commons — an
                       ;; intent names one side (VF: provider xor receiver), and
                       ;; the member is the provider; the address rides as
                       ;; at-location, read back by payout->alist
                       #:at-location (string-append "xmr:" addr) #:in-scope-of '()))
                   `((id . ,iid) (available . ,(- avail q))))))))

      ((my-payouts scope-id agent-id store)
       (scoped scope-id
         (lambda (root)
           (let* ((obs ($ root 'observer)) (rs ($ root 'recipe-store)) (ps ($ root 'plan-store))
                  (owed-list (if (and debts-of store) (debts-of obs store scope-id agent-id) '())))
             ;; the my-payouts table (doors/record-rows.scm) writes the reply, the
             ;; payout rows reading their word and began through the context's reader
             (with-context
              `((available . ,(payout-available obs ps agent-id
                                #:owed (if (and owed-of store) (owed-of rs obs store scope-id agent-id) 0.0)))
                (owed . ,owed-list)
                (payouts . ,(payouts-of ps agent-id)))
              (payout-ctx ps))))))

      ;; ── the lifecycle: five verbs, one table (economy/payouts.scm %payout-moves);
      ;; each dated by the store's clock, unix seconds ──
      ;; RETIRE: only the requester, only while pending — a sent payout is history.
      ((retire-payout scope-id agent-id id)
       (scoped scope-id
         (lambda (root) (payout-move! ($ root 'plan-store) id 'retire #:by agent-id #:at (current-time)) `((id . ,id)))))

      ;; BEGIN: the runner's claim on a payout before the coins move, "pending"
      ;; → "sending", so a second tick never sends it twice.
      ((begin-payout scope-id id)
       (scoped scope-id
         (lambda (root) (payout-move! ($ root 'plan-store) id 'begin #:at (current-time) #:began (iso-now)) `((id . ,id)))))

      ;; SETTLE: the VF transfer out of the member's claim (the coins left the
      ;; commons' wallet; the claim shrinks by exactly that), txid on the event
      ;; and on the commitment's ending.
      ((settle-payout scope-id id txid store)
       (scoped scope-id
         (lambda (root)
           (payout-move! ($ root 'plan-store) id 'settle txid #:at (current-time)
                         #:effect (lambda (i) (ledger-settled! root scope-id i txid store)))
           `((id . ,id) (txid . ,txid)))))

      ;; UNSETTLE: the reconciler found no matching outgoing transfer inside
      ;; the grace window: parked, still reserving the claim, for an operator
      ;; to settle (with the txid) or fail by hand. Never "failed" on its own:
      ;; the coins may have moved.
      ((unsettle-payout scope-id id reason)
       (scoped scope-id
         (lambda (root) (payout-move! ($ root 'plan-store) id 'unsettle reason #:at (current-time)) `((id . ,id)))))

      ;; FAIL leaves the claim whole and parks the intent with the reason — the
      ;; member may retire it and ask again.
      ((fail-payout scope-id id reason)
       (scoped scope-id
         (lambda (root) (payout-move! ($ root 'plan-store) id 'fail reason #:at (current-time)) `((id . ,id)))))

      ;; ── the runner's and the reconciler's reads, each a predicate over the records ──
      ;; pending payouts whose due is unset or ≤ NOW-ISO
      ((due-payouts scope-id now-iso)
       (payout-rows scope-id (lambda (ps i) (and (payout-pending? ps i)
                                                  (let ((due (intent-due i))) (or (not due) (string<=? due now-iso)))))))

      ;; payouts that began moving and were never settled — a gateway that
      ;; died mid-transfer leaves these
      ((sending-payouts scope-id)
       (payout-rows scope-id (lambda (ps i) (payout-sending? ps i))))

      ;; the transactions that have already settled a payout: a wallet row that
      ;; paid one payout is not evidence for another
      ((settled-payout-txids scope-id)
       (scoped scope-id
         (lambda (root) (let ((ps ($ root 'plan-store))) (filter-map (lambda (i) (payout-txid ps i)) (payouts-of ps #f))))))

      ;; ── Purchases for the commons, and what the commons then owes ──────────
      ;; A member buys a thing the commons wanted with their own money and
      ;; records it: the good is RAISED into the commons (provider = the member,
      ;; the receipt on the event). What the commons then owes them back is a
      ;; DEBT (economy/debts.scm) — minted through governance's own
      ;; accept-reimbursement (governance/scope.scm),
      ;; a ^scope method, because minting a debt needs the scope's own signature;
      ;; this service only states whether the purchase fulfils a plan the commons
      ;; already committed to (PLANNED?, informational — the plan is the
      ;; authorisation the lobby checks before it calls accept-reimbursement) —
      ;; it never mints the debt itself. A donation records the raise and owes
      ;; nothing. Settlement is a payout (XMR, at the acquisition-SNLT ratio) —
      ;; see payout-available / settle-payout.
      ;;
      ;; THE RAISE BINDS to the plan records that already exist, rather than
      ;; passing #f where its VF edges belong: `fulfills` names the live
      ;; `produce` commitment for this spec (the same record the PLANNED? scan
      ;; reads — kept now, not collapsed to a boolean), `satisfies` names an
      ;; open declared NEED for it (declare-need's consume-intent), and both
      ;; are registered on the observer first (register-commitment /
      ;; register-intent state the target and keep what the events already
      ;; show) so fulfilment and satisfaction read this very event. The whole linkage
      ;; machinery is the one work and journeys already use; nothing new is
      ;; minted — a purchase corroborates the demand rail, it never duplicates
      ;; it. The event id returns to the caller so a purchase-claim can carry
      ;; it as `triggered-by` (VF Claim.triggeredBy IS an EconomicEvent id):
      ;; raise → claim → debt, one provenance chain on existing fields.
      ((record-purchase scope-id agent-id spec qty unit money-spec cost where note receipt #:optional (donation? #f))
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let* ((obs  ($ root 'observer))
                      (ps   ($ root 'plan-store))
                      (q    (if (and (number? qty) (> qty 0)) qty 1))
                      (c    (cond ((number? cost) cost)
                                  ((and (string? cost) (string->number cost)) => (lambda (n) n))
                                  (else 0)))
                      (donation? (and donation? #t))
                      (u    (or (string-or-false unit) %count-unit))
                      (stamp (iso-now))
                      ;; the instant alone is second-precision (iso-now) — two
                      ;; purchases of the same spec by the same agent within one
                      ;; second collide on an identical rid, and seed-resource's
                      ;; hashmap-set silently overwrites the first purchase's
                      ;; resource entirely (verified live: the second purchase's
                      ;; note replaces the first's under the same key). The
                      ;; running count of this agent's own existing purchases of
                      ;; this spec disambiguates, the same pattern request-payout
                      ;; already uses a few hundred lines above.
                      (prior (length (filter (lambda (r) (string-prefix? (string-append "bought:" agent-id ":" spec ":")
                                                                          (economic-resource-id r)))
                                             ($ obs 'conforming-resources spec))))
                      (rid  (string-append "bought:" agent-id ":" spec ":" stamp ":" (number->string prior)))
                      (eid  (string-append "purchase:" rid))
                      (loc  (string-or-false where))
                      ;; the plan records this purchase corroborates, if any
                      (planned-c (find (lambda (k)
                                         (and (not (commitment-finished k))
                                              (same-flow? 'produce (commitment-action k))   ; an acquisition fulfils a produce
                                              (equal? spec (commitment-resource-conforms-to k))))
                                       ($ ps 'all-commitments)))
                      (need-i (find (lambda (i)
                                      (and (not (intent-finished i))
                                           (memq (intent-action i) using-up-actions)
                                           (equal? spec (intent-resource-conforms-to i))))
                                    ($ ps 'all-intents))))
                 (unless (string-or-false spec) (error "what was bought?"))
                 (unless (or donation? (> c 0)) (error "what did it cost?"))
                 ;; the good, held by the commune from the moment it is recorded
                 ($ obs 'record-resource
                    (make-economic-resource #:id rid #:name (or (string-or-false note) spec) #:note (string-or-false note) #:tracking-identifier (fresh-label obs)
                                            #:conforms-to spec #:classified-as '("bought") #:accounting-quantity (make-measure 0 u) #:onhand-quantity (make-measure 0 u)
                                            #:current-location loc #:primary-accountable scope-id))
                 ;; the good enters the books by no process: a `raise`, the table's word
                 ($ obs 'record-event
                    (adjustment-event eid rid spec q u #:classified-as '("bought")
                                      #:provider agent-id #:receiver scope-id
                                      #:when stamp #:created stamp #:to loc
                                      ;; ONE edge: the commitment this corroborates (the intent it
                                      ;; satisfies takes its satisfaction from the commitment's own
                                      ;; edge), else the intent itself — the observer refuses both
                                      #:fulfills (and planned-c (commitment-id planned-c))
                                      #:satisfies (and (not planned-c) need-i (intent-id need-i))
                                      #:note (string-append (if donation? "donated" "bought")
                                                            (if (string-or-false receipt) (string-append " · receipt " receipt) ""))))
                 ;; whether the commons owes — unless it was a gift
                 (if donation?
                     (success `((resource . ,rid) (event . ,eid) (owed . #f)))
                     (success `((resource . ,rid) (event . ,eid)
                                (cost . ,c) (money-spec . ,(or (string-or-false money-spec) "spec-eur"))
                                (planned? . ,(and planned-c #t))
                                (fulfills . ,(and planned-c (commitment-id planned-c)))
                                (satisfies . ,(and (not planned-c) need-i (intent-id need-i)))))))))))))))
