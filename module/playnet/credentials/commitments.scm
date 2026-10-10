;;; credentials/commitments.scm — what is promised: commitment, fulfillment, intent, agreement, the redistribution mandate and its predicate DSL.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.
;;;
;;; Mandate serialization: a predicate is not portable, so a mandate is compiled
;;; from a small DSL of specs:
;;;
;;;   (equal-position SYMBOL)         → #t iff the stance's position is SYMBOL
;;;   (any-of-position (SYMBOL …))    → #t iff the position is one of them
;;;   (min-distribution PLAN-ID FRAC) → #t iff distribution[PLAN-ID] ≥ FRAC
;;;   opaque                          → a predicate that could not be introspected;
;;;                                     recovers as #f (liquid) with a warning

(define-module (playnet credentials commitments)
  #:use-module (playnet keri acdc)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:export (*predicate-spec-registry*
            *schema-playnet-agreement*
            *schema-playnet-commitment*
            *schema-playnet-commitment-fulfillment*
            *schema-playnet-intent*
            *schema-playnet-redistribution-mandate*
            compile-mandate-spec
            make-agreement-credential
            make-commitment-credential
            make-commitment-fulfillment-credential
            make-intent-credential
            make-redistribution-mandate-credential
            mandate
            mandate-spec-of
            predicate->spec
            register-mandate-predicate))
(define *schema-playnet-commitment*              "playnet-commitment/v1")
(define *schema-playnet-intent*                  "playnet-intent/v1")
(define *schema-playnet-agreement*               "playnet-agreement/v1")
(define *schema-playnet-commitment-fulfillment*  "playnet-commitment-fulfillment/v1")
;; Voice-rule and weight-rule schemas removed in 2026-04 cleanup.
;; This protocol commits to labor-proportional aggregation at every
;; level (see
;; docs/governance/GOVERNANCE-PROPORTIONAL.md). Voice is universal
;; gross/total; federation aggregation is `commune-weight-async`
;; (labor-share, hardcoded). Pluralism at either layer would betray
;; the design center.
(define *schema-playnet-redistribution-mandate*
  "playnet-redistribution-mandate/v1")


(define* (make-commitment-credential provider-aid receiver-aid
                                      commitment-id action
                                      #:key (resource-conforms-to #f)
                                            (resource-classified-as '())
                                            (resource-quantity #f)
                                            (effort-quantity #f)
                                            (due #f) (plan-id #f)
                                            (process-id #f) (satisfies #f)
                                            (resource-inventoried-as #f)
                                            (triggered-by #f)
                                            (signing-keypair #f))
  "Commitment ACDC: provider promises to receiver.
   Issuer = provider, holder = receiver.
   resource-quantity, effort-quantity: pairs (qty . unit) or #f.
   satisfies: optional intent SAID this commitment satisfies.

   resource-inventoried-as: optional id of the EXACT EconomicResource this
   commitment moves (VF resourceInventoriedAs) — names WHICH one when the
   spec alone is ambiguous. A purchase-claim uses it to say which purse or
   balance actually paid, turning accept-reimbursement's funding-source
   check from a spec-wide heuristic into a direct read.

   triggered-by: optional SAID of the credential this one arises FROM —
   the VF `triggeredBy` relation (docs/valueflows examples, \"Claim for
   income\": a real past event entitles a reciprocal obligation, settled
   later; no Agreement, which VF reserves for connecting reciprocal
   PROMISES). governance/scope.scm's accept-reimbursement uses it: the
   commune's debt is triggered by the member's own signed purchase-claim,
   and that link is the whole binding.

   The first ten claims are emitted unconditionally, #f values included —
   exactly as this constructor always has, so every existing commitment
   credential keeps the SAID it was minted with. Only the two NEW fields
   are emitted when set, the same append-only SAID discipline the
   custody-attestation's kind claim established.

   signing-keypair: optional — the provider's Ed25519 keypair, so the promise
   carries its maker's signature (a scope signs its own commitment)."
  (make-credential *schema-playnet-commitment*
                   provider-aid receiver-aid
                   (let* ((base (list (cons 'commitment-id        commitment-id)
                                      (cons 'action               action)
                                      (cons 'resource-conforms-to resource-conforms-to)
                                      (cons 'resource-classified-as resource-classified-as)
                                      (cons 'resource-quantity    resource-quantity)
                                      (cons 'effort-quantity      effort-quantity)
                                      (cons 'due                  due)
                                      (cons 'plan-id              plan-id)
                                      (cons 'process-id           process-id)
                                      (cons 'satisfies            satisfies)))
                          (cl (if resource-inventoried-as
                                  (append base (list (cons 'resource-inventoried-as
                                                           resource-inventoried-as)))
                                  base))
                          (cl (if triggered-by
                                  (append cl (list (cons 'triggered-by triggered-by)))
                                  cl)))
                     cl)
                   '() #:signing-keypair signing-keypair))

(define* (make-redistribution-mandate-credential
          federation-aid scope-aid threshold-spec recipient-policy
          #:key (period "monthly") (effective-from #f)
          (signing-keypair #f) (multisig-signers #f))
  "Redistribution mandate ACDC: FEDERATION-AID requires SCOPE-AID
   (a member) to redistribute surplus above THRESHOLD-SPEC, with
   destination chosen by RECIPIENT-POLICY.

   Issuer = federation (the body imposing the mandate).
   Holder  = member scope (the party bound by it).
   SIGNING-KEYPAIR attaches the federation's issuer signature (the party
   imposing the mandate). A member counter-signature (acceptance of the
   obligation) is the eventual bilateral model — pass MULTISIG-SIGNERS
   then. (No production issuer wires this yet — see the acdc-signing
   audit; the earlier docstring claimed a signature the constructor had
   no parameter to store.)

   THRESHOLD-SPEC is a symbolic form, e.g.
     (surplus-above (qty 100 \"kg\") spec:grain)
     (idle-capacity-above (hours 40))
     (custody-of-spec-above spec:widget 500)

   RECIPIENT-POLICY is symbolic:
     federation-pool
     (equal-share to-leaves)
     (need-weighted to-leaves)

   PERIOD: a string like \"monthly\" / \"quarterly\" / \"weekly\";
   informational — the auditor uses it to decide how often to check."
  (make-credential *schema-playnet-redistribution-mandate*
                   federation-aid scope-aid
                   (list (cons 'federation-aid    federation-aid)
                         (cons 'scope-aid         scope-aid)
                         (cons 'threshold-spec    threshold-spec)
                         (cons 'recipient-policy  recipient-policy)
                         (cons 'period            period)
                         (cons 'effective-from    (or effective-from
                                                       (iso-utc-now))))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))


(define* (make-commitment-fulfillment-credential
          receiver-aid provider-aid commitment-said
          #:key (fulfilled-at #f) (note #f))
  "Commitment-fulfillment ACDC issued by the RECEIVER of a commitment
   to the PROVIDER, marking that commitment as satisfied.

   This replaces the unilateral `(cred-claim c 'finished)` flag for
   purposes of the custody-transfer validator: a commitment is
   'finished' iff a non-revoked fulfillment ACDC referencing its
   SAID exists. A captured provider can no longer mark its own
   commitments finished to escape the orphan check.

   Issuer = receiver (the party attesting that the obligation was met).
   Holder = provider. Carries the commitment SAID as an edge."
  (let ((edges
         (list (cons 'fulfills
                     (make-edge commitment-said
                                #:operator 'NI2I
                                #:schema *schema-playnet-commitment*)))))
    (make-credential *schema-playnet-commitment-fulfillment*
                     receiver-aid provider-aid
                     (list (cons 'commitment-said commitment-said)
                           (cons 'fulfilled-at   (or fulfilled-at
                                                      (iso-utc-now)))
                           (cons 'note           note))
                     edges)))


;; Recognition of a plan or an intent at a federation level is the observer's
;; own rail (observation/observer.scm confirm-plan / recognize-intent): the
;; validation maps every credit and voice read gates on. It is a fact about
;; the scope's own record and needs no credential of its own.


(define* (make-agreement-credential acceptor-aid proposer-aid
                                     agreement-id
                                     #:key (proposal-id #f)
                                           (primary-commitment-ids '())
                                           (reciprocal-commitment-ids '())
                                           (counterparty-provider #f)
                                           (counterparty-receiver #f)
                                           (accepted-at #f)
                                           (signing-keypair #f))
  "Agreement ACDC: ACCEPTOR-AID has accepted PROPOSER-AID's proposal.
   Issuer = acceptor (the party taking on the commitments).
   Holder = proposer (the party whose proposal was accepted).
   Claims anchor the proposal, the agreement record, its primary and
   reciprocal commitment IDs, the counterparty roles used during
   promotion, and the acceptance timestamp.
   signing-keypair: optional — the acceptor's keypair, so the acceptance
   carries the acceptor's signature (a scope signs its own consent)."
  (make-credential *schema-playnet-agreement*
                   acceptor-aid proposer-aid
                   (list (cons 'agreement-id             agreement-id)
                         (cons 'proposal-id              proposal-id)
                         (cons 'primary-commitment-ids   primary-commitment-ids)
                         (cons 'reciprocal-commitment-ids reciprocal-commitment-ids)
                         (cons 'counterparty-provider    counterparty-provider)
                         (cons 'counterparty-receiver    counterparty-receiver)
                         (cons 'accepted-at              accepted-at))
                   '() #:signing-keypair signing-keypair))


(define* (make-intent-credential issuer-aid intent-id action
                                  #:key (provider #f) (receiver #f)
                                        (resource-conforms-to #f)
                                        (resource-classified-as '())
                                        (resource-quantity #f)
                                        (effort-quantity #f)
                                        (available-quantity #f)
                                        (minimum-quantity #f)
                                        (due #f) (plan-id #f)
                                        (process-id #f)
                                        (satisfies #f)
                                        (holder-aid #f))
  "Intent ACDC: unilateral signal — provider XOR receiver.
   Issuer = the agent declaring the intent (provider OR receiver).
   Holder = governance-group-aid (or scope-aid) by default — the
   federation/commune that hosts the intent for discovery.
   resource-quantity / effort-quantity: pairs (qty . unit) or #f.
   satisfies: optional parent intent ID this refines."
  (when (and provider receiver)
    (error "VF constraint: intent has provider XOR receiver, not both"
           intent-id))
  (make-credential *schema-playnet-intent*
                   issuer-aid
                   (or holder-aid issuer-aid)
                   (list (cons 'intent-id           intent-id)
                         (cons 'action              action)
                         (cons 'provider            provider)
                         (cons 'receiver            receiver)
                         (cons 'resource-conforms-to resource-conforms-to)
                         (cons 'resource-classified-as resource-classified-as)
                         (cons 'resource-quantity   resource-quantity)
                         (cons 'effort-quantity     effort-quantity)
                         (cons 'available-quantity  available-quantity)
                         (cons 'minimum-quantity    minimum-quantity)
                         (cons 'due                 due)
                         (cons 'plan-id             plan-id)
                         (cons 'process-id          process-id)
                         (cons 'satisfies           satisfies))))


;; =========================================================================
;; Mandate-spec DSL ↔ predicate
;; =========================================================================

(define (compile-mandate-spec spec)
  "Compile a mandate-spec into a predicate (cleartext-stance → bool).
   Returns #f for opaque or unrecognized specs (recovers as liquid).

   Recognized specs:
     (equal-position SYMBOL)
     (any-of-position (SYMBOL ...))
     (min-distribution PLAN-ID FRACTION)
     opaque    → #f"
  (cond
    ((eq? spec 'opaque) #f)
    ((not (pair? spec)) #f)
    (else
     (case (car spec)
       ((equal-position)
        (let ((target (cadr spec)))
          (lambda (stance) (eq? (caddr stance) target))))
       ((any-of-position)
        (let ((targets (cadr spec)))
          (lambda (stance) (and (memq (caddr stance) targets) #t))))
       ((min-distribution)
        (let ((target-id (cadr spec))
              (min-frac  (caddr spec)))
          (lambda (stance)
            ;; cleartext for expression: (expression DOMAIN EID dist citizen-id keri-aid)
            ;; dist is a hashmap target-id → fraction
            (let ((dist (cadddr stance)))
              (>= (hashmap-ref dist target-id 0) min-frac)))))
       (else #f)))))

(define (mandate-spec-of pred)
  "Best-effort introspection of a mandate predicate. Returns 'opaque
   for predicates we can't recognize. To make a predicate recognizable,
   construct it via the DSL — i.e. callers should keep the spec around
   and use compile-mandate-spec, not arbitrary lambdas.

   Phase-1 limitation: we don't introspect lambda bodies. The signal
   to use the DSL: callers who care about ACDC round-trip should pass
   an additional `:mandate-spec` to delegate-mandated alongside the
   predicate. (In Phase-2 we may invert: callers pass only the spec,
   actor compiles it.)

   For now: return 'opaque if we don't have a registered association."
  (or (predicate->spec pred)
      'opaque))

(define *predicate-spec-registry* (make-hash-table))

(define (register-mandate-predicate pred spec)
  "Associate a predicate with its spec so mandate-spec-of can recover it."
  (hash-set! *predicate-spec-registry* pred spec)
  pred)

(define (predicate->spec pred)
  (hash-ref *predicate-spec-registry* pred #f))

(define (mandate spec)
  "Convenience: compile a spec and register the resulting predicate so
   mandate-spec-of can later recover the spec for ACDC issuance.

   Use:  ($ delegation-map 'delegate-mandated D F (mandate '(equal-position yes)))"
  (let ((pred (compile-mandate-spec spec)))
    (when pred
      (register-mandate-predicate pred spec))
    pred))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-playnet-commitment* (commitment-id))
   (,*schema-playnet-intent*     (intent-id))
   (,*schema-playnet-agreement*  (agreement-id proposal-id) accepted-at)))
