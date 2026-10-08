;;; module/playnet/monero/specs.scm — XMR ResourceSpecification + bootstrap
;;;
;;; Wires a Monero wallet actor into a planner scope as a first-class
;;; economic resource. Callers get back the ^live-resource reference so
;;; a poller (see poller.scm) can resize it in response to on-chain
;;; balance changes.
;;;
;;; Flow at bootstrap time:
;;;
;;;   1. Register spec-xmr in the scope's recipe-store.
;;;   2. Seed res-xmr-main in the observer at quantity 0.
;;;   3. Spawn a vanilla ^live-resource with the same id and total 0.
;;;   4. Register it in the scope's ^live-registry.
;;;
;;; After step 4, `lift-planning-facts` prefers the live-resource's
;;; 'available for this resource-id — so any subsequent call to
;;; plan-for-unit sees the current wallet balance with no planner
;;; changes. See planning-facts.scm:162-176.
;;;
;;; Conventions:
;;;
;;;   spec id        "spec-xmr"
;;;   resource id    "res-xmr-main"     (the "account 0" wallet)
;;;   unit           "XMR"
;;;   classified-as  ("currency" "cryptocurrency")
;;;
;;; medium-of-exchange? is set to #t — the ResourceSpecification record
;;; carries this flag specifically for currency-like resources
;;; (schemas.scm:650).
;;;
;;; NOTE: quantities stored in the observer and the live-resource are in
;;; XMR (not atomic units) because the planner works in domain units.
;;; The wallet actor deals in atomic units; the poller bridges between
;;; the two via atomic->xmr / xmr->atomic (wallet.scm).

(define-module (playnet monero specs)
  #:use-module (goblins)
  #:use-module (playnet planner observation live-resource)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet monero wallet)
  #:export (xmr-spec
            %xmr-spec-id
            %xmr-resource-id
            %xmr-unit
            bootstrap-monero-resource!
            bootstrap-external-asset!))

(define %xmr-spec-id     "spec-xmr")
(define %xmr-resource-id "res-xmr-main")
(define %xmr-unit        "XMR")

;;; ── External assets as CLAIMABLE resources (playnet.typ §Credits and
;;; external liquidity) ──────────────────────────────────────────────────
;;;
;;; Any external asset — fiat, crypto, a world-market commodity — enters the
;;; commons as an ordinary resource specification whose crystallized SNLT is
;;; the SOCIAL COST OF ACQUISITION: the labour the federation spends to
;;; obtain one unit. That cost is carried by an acquisition RECIPE (a work
;;; flow of N hours producing 1 unit), so min-snlt-for-spec prices it and
;;; the account layer's pool-value/claim path needs NO special case. The
;;; plan puts the stock on the individual rail by the same reading as bread —
;;; made by a recipe, nobody's input, nothing's means — and citizens draw it
;;; against earned credit exactly like bread. STRICTLY one-directional: credits buy
;;; external liquidity; nothing external ever mints credit (donations enter
;;; as 'raise events on the resource, not as anyone's balance).

(define (external-asset-spec spec-id name note unit categories)
  (make-resource-specification
   #:id spec-id #:name name #:note note                                    ; image
   #:resource-classified-as (cons "external" categories)          ; classified-as → folksonomy shelves
   #:default-unit-of-resource unit
   #:substitutable #t                                    ; substitutable (fungible)
   #:medium-of-exchange #t                                    ; medium-of-exchange
))

(define (make-external-asset-resource resource-id spec-id name unit
                                      accountable-agent location)
  (make-economic-resource
   #:id resource-id #:name name
   #:conforms-to spec-id
   #:classified-as '("currency")
   #:accounting-quantity (make-measure 0 unit)                 ; accounting-quantity
   #:onhand-quantity (make-measure 0 unit)                 ; onhand-quantity
   #:current-location location
   #:primary-accountable accountable-agent
   #:distribution-mode 'individual-claimable))

(define (add-acquisition-recipe! rs spec-id name unit hours-per-unit)
  "The acquisition recipe: HOURS-PER-UNIT of labour produce 1 UNIT of the
   asset. Its rollup IS the asset's crystallized SNLT — the price every
   claim settles at. The federation governs the number by editing the
   recipe, the same way it governs any other recipe."
  (let ((rp-id (string-append "rp-acquire-" spec-id))
        (rid   (string-append "recipe-acquire-" spec-id)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id rp-id #:name (string-append "Acquire " name)
                            #:process-conforms-to (string-append "pspec-acquire-" spec-id)
                            #:has-duration (make-duration hours-per-unit "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append "rf-" rp-id "-work") #:action 'work #:resource-conforms-to "spec-labor" #:effort-quantity (make-measure hours-per-unit "hours")
                         #:recipe-input-of rp-id))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append "rf-" rp-id "-out") #:action 'produce #:resource-conforms-to spec-id
                         #:resource-quantity (make-measure 1 unit) #:recipe-output-of rp-id))
    ($ rs 'add-recipe
       (make-recipe #:id rid #:name (string-append "Acquire " name) #:primary-output spec-id
                    #:recipe-processes (list rp-id)))))

(define* (bootstrap-external-asset! scope
                                    #:key
                                    spec-id name unit
                                    (note "")
                                    (categories '())
                                    (acquisition-hours 20)
                                    (accountable-agent "agent-playnet")
                                    (location "loc-playnet-server"))
  "Register an external asset (fiat, crypto, …) as an individually-claimable
   resource in SCOPE, priced by its acquisition recipe. Must run inside the
   scope's vat. Returns the resource id."
  (let ((rs  ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (rid (string-append "res-" spec-id "-pool")))
    ($ rs 'add-resource-spec
       (external-asset-spec spec-id name note unit categories))
    (add-acquisition-recipe! rs spec-id name unit acquisition-hours)
    ($ obs 'record-resource
       (make-external-asset-resource rid spec-id name unit
                                     accountable-agent location))
    rid))

;;; ── Monero: the first instance of the generic external asset ───────────
;;; XMR is not a special case — the same spec/resource constructors as any
;;; fiat or commodity, plus the wallet-backed ^live-resource so the poller
;;; can resize availability from the chain.

(define xmr-spec
  ;; "external/crypto" shelves it under the folksonomy's external branch —
  ;; the shop face badges it ⇄ and the seed puts it in the commons' cut
  (external-asset-spec
   %xmr-spec-id
   "Monero"
   "Monero (XMR) — privacy-preserving cryptocurrency used by playnet as a medium of exchange for donations and vendor payments."
   %xmr-unit
   '("external/crypto" "currency" "cryptocurrency")))

(define* (bootstrap-monero-resource! scope
                                     #:key
                                     (accountable-agent "agent-playnet")
                                     (location "loc-playnet-server")
                                     ;; hours of social labour to acquire 1 XMR —
                                     ;; the crystallized SNLT every claim settles
                                     ;; at; governed by editing the recipe
                                     (acquisition-hours 20))
  "Register XMR as a live resource in SCOPE.

SCOPE is a ^scope-root actor reference. Must be called inside
  (with-vat scope-vat ...) because it touches recipe-store, observer,
  and live-registry.

Returns the ^live-resource actor reference for the wallet balance,
which a poller should later resize from the actual wallet state via
  ($ live-resource 'resize new-total-xmr)."
  (let ((rs  ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (lr  ($ scope 'live-registry)))
    ;; 1. Spec (idempotent-ish — add-resource-spec overwrites), plus the
    ;;    acquisition recipe that prices it (crystallized SNLT).
    ($ rs 'add-resource-spec xmr-spec)
    (add-acquisition-recipe! rs %xmr-spec-id "Monero" %xmr-unit acquisition-hours)
    ;; 2. Observer resource stub at zero balance — the wallet balance IS the
    ;;    commons' claimable XMR pool (one-directional, credits → XMR).
    ($ obs 'record-resource
       (make-external-asset-resource %xmr-resource-id %xmr-spec-id
                                     "Playnet Monero wallet" %xmr-unit
                                     accountable-agent location))
    ;; 3. Spawn the live-resource actor.
    (let ((live (spawn ^live-resource
                       %xmr-resource-id
                       %xmr-spec-id
                       0                  ; total (XMR)
                       0                  ; available (XMR)
                       %xmr-unit
                       location
                       '())))             ; reservations
      ;; 4. Register with the scope's live-registry.
      ($ lr 'register %xmr-resource-id live)
      live)))
