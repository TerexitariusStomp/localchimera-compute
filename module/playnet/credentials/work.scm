;;; credentials/work.scm — work and what was seen: the work event, the observation event, the contrary observation, a skill, a claim, an external index observation.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet credentials commitments) #:select (*schema-playnet-commitment* *schema-playnet-intent*))
  #:export (*schema-playnet-claim*
            *schema-playnet-contrary-observation*
            *schema-playnet-external-index-observation*
            *schema-playnet-observation-event*
            *schema-playnet-skill*
            *schema-playnet-work-event*
            make-claim-event-credential
            make-contrary-observation-credential
            make-external-index-observation-credential
            make-observation-event-credential
            make-skill-credential
            make-work-event-credential))
(define *schema-playnet-work-event*              "playnet-work-event/v1")
(define *schema-playnet-observation-event*       "playnet-observation-event/v1")
(define *schema-playnet-external-index-observation*
  "playnet-external-index-observation/v1")
;; A worker's word against a mapped figure: "I ran PROCESS and its ACTION on
;; SPEC read READING where the map says NOMINAL" — a contrary observation
;; (docs/planning/voice/feasibility-follows-the-map.md). Issued and held by
;; the observer, in their own name, on the witness of a work event of theirs
;; on that process; the solve reads it as the world as observed, in every
;; future (planner/solve/engine/robust.scm observed-shocks).
(define *schema-playnet-contrary-observation*
  "playnet-contrary-observation/v1")

;; Skill: the membership token for competence. A scope (or training
;; authority) issues this to a worker AID to attest "WORKER holds SKILL",
;; minted ONCE per (worker, skill) the first time the worker does work
;; conforming to that skill. It is immutable and derive-don't-store: the
;; accumulated hours are NOT carried here — they are summed on demand from
;; the worker's work-event log (observer `practiced-hours`). The credential
;; edges to its FOUNDING work event, anchoring provenance; the growing set
;; of work events is the derived index, not a field on this token.
(define *schema-playnet-skill* "playnet-skill/v1")

;; Claim: the CONSUMPTION mirror of the work-event ACDC. When a person draws
;; earned credit to receive an individually-claimable good (an EconomicEvent of
;; action `transfer`, effortQuantity = the labour-hours drawn), the scope attests
;; it. ledger-claimed sums these; credit-balance = gross (work-event ACDCs) −
;; claimed (claim ACDCs), so the WHOLE ledger — both halves — reconstructs from
;; the portable ACDC set, exactly as the contribution side does.
(define *schema-playnet-claim* "playnet-claim/v1")

(define* (make-work-event-credential scope-aid worker-aid
                                     event-id hours unit
                                     #:key (scope-id #f) (process-id #f)
                                           (timestamp #f)
                                           (resource-conforms-to #f)
                                           (fulfills #f)
                                           (satisfies #f)
                                           (skill-said #f)
                                           ;; the trust floor: k-of-n WITNESSES on the
                                           ;; event itself, so the evidence layer the
                                           ;; recipe metabolism reads is not one scope's
                                           ;; word (multisig block; cred-multisig-valid?)
                                           (multisig-signers #f))
  "Work event ACDC: scope governance witnesses worker's labor.
   Issuer = scope-aid, holder = worker-aid.
   fulfills:  optional commitment SAID this event fulfills (planning).
   satisfies: optional intent SAID this event satisfies (validation —
              §III.1 anchors credit on recipient-side satisfaction).
   skill-said: optional SAID of the skill ACDC this work exercises — every
              work event after the founding one edges to its skill, so the
              skill's whole history (earned-skills / practiced-hours / credit)
              is a single offline-walkable graph, not a server-side index.

   When supplied, FULFILLS / SATISFIES / SKILL-SAID are emitted as `e`-block
   NI2I edges (named 'fulfills / 'satisfies / 'skill) so verifiers can walk the
   property graph natively. Claim values are retained for back-compat."
  (let ((edges
         (append
          (if fulfills
              (list (cons 'fulfills
                          (make-edge fulfills
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-commitment*)))
              '())
          (if satisfies
              (list (cons 'satisfies
                          (make-edge satisfies
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-intent*)))
              '())
          (if skill-said
              (list (cons 'skill
                          (make-edge skill-said
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-skill*)))
              '()))))
    (make-credential *schema-playnet-work-event*
                     scope-aid worker-aid
                     (list (cons 'event-id            event-id)
                           (cons 'hours               hours)
                           (cons 'unit                unit)
                           (cons 'scope-id            scope-id)
                           (cons 'process-id          process-id)
                           (cons 'timestamp           timestamp)
                           (cons 'resource-conforms-to resource-conforms-to)
                           (cons 'fulfills            fulfills)
                           (cons 'satisfies           satisfies))
                     edges
                     #:multisig-signers multisig-signers)))

(define* (make-observation-event-credential scope-aid holder-aid event-id action
                                            #:key (qty #f) (unit #f) (scope-id #f)
                                                  (resource-conforms-to #f)
                                                  (at-location #f) (to-location #f)
                                                  (timestamp #f) (fulfills #f)
                                                  (evidence #f))
  "Observation event ACDC: scope governance witnesses an occurrence the
   ledger folded — ONE shape for every quantified observational action
   (produce / consume / use / move / raise / lower / pickup / dropoff /
   deliver-service), the material half of the evidence layer beside
   work-event's labour half and claim-event's draw half.
   Issuer = scope-aid; holder = the agent observed acting.
   FULFILLS, when present, edges to the commitment the event discharges
   (NI2I, like work-event's), so verifiers walk the confirmation mile as a
   property graph. Both ends of a move ride the claims, so the journey the
   routing table learned from is reconstructable offline.
   EVIDENCE, when present, is the sha256 of the picture a photo read was made
   from; the claim is appended only when set, so every record that names no
   picture keeps the SAID it always had."
  (make-credential *schema-playnet-observation-event*
                   scope-aid holder-aid
                   (append
                    (list (cons 'event-id             event-id)
                          (cons 'action               action)
                          (cons 'qty                  qty)
                          (cons 'unit                 unit)
                          (cons 'scope-id             scope-id)
                          (cons 'resource-conforms-to resource-conforms-to)
                          (cons 'at-location          at-location)
                          (cons 'to-location          to-location)
                          (cons 'timestamp            timestamp)
                          (cons 'fulfills             fulfills))
                    (if evidence (list (cons 'evidence evidence)) '()))
                   (if fulfills
                       (list (cons 'fulfills
                                   (make-edge fulfills
                                              #:operator 'NI2I
                                              #:schema *schema-playnet-commitment*)))
                       '())))

(define* (make-contrary-observation-credential observer-aid scope-id process action spec
                                                nominal reading witness observed-at
                                                #:key (signing-keypair #f))
  "Contrary-observation ACDC: OBSERVER-AID, who ran PROCESS in SCOPE-ID, read
   ACTION on SPEC at READING where the map states NOMINAL; WITNESS is the id
   of the work event the reading came from. Issuer = holder = the observer:
   a constative statement in their own name, signed with their own key,
   revocable by them alone. One live statement per (observer, scope,
   process, action) — a restatement supersedes (governance/service.scm). Who
   may speak — the worker the witness names — is a fact the service reads
   off the observer; what the solve makes of it is planner/solve/engine/robust.scm
   observed-shocks: the read moves in the cautious direction only."
  (make-credential *schema-playnet-contrary-observation*
                   observer-aid observer-aid
                   (list (cons 'scope-id    scope-id)
                         (cons 'process     process)
                         (cons 'action      (if (symbol? action) (symbol->string action) action))
                         (cons 'spec        spec)
                         (cons 'nominal     nominal)
                         (cons 'reading     reading)
                         (cons 'witness     witness)
                         (cons 'observed-at observed-at))
                   '()
                   #:signing-keypair signing-keypair))

(define* (make-skill-credential
          issuing-aid worker-aid skill founding-event-said
          #:key (valid-from #f) (valid-until #f))
  "Skill membership ACDC: ISSUING-AID attests that WORKER-AID holds SKILL,
   minted ONCE per (worker, skill) on the first work event conforming to it.

   Issuer = the witnessing scope (or a training authority that produced the
   skill — just *who* issued it, never a 'certification' flag). Holder =
   worker. There is no hours field: accumulated competence is DERIVED from
   the worker's work-event log (observer `practiced-hours`), so this token
   never drifts and a retroactively-voided work simply drops from the sum.

   FOUNDING-EVENT-SAID: the work-event ACDC SAID this skill was first earned
   on. Added as an NI2I edge so the skill's provenance is attestable; the
   later works that exercise the skill are the derived index, not edges here.

   valid-from / valid-until: optional (epoch or ISO); #f = open-ended. A
   skill whose valid-until is past is treated as lapsed by observers — the
   same live/expiry convention as custody attestations (so `*-cred-live?`
   transfers), the structural home for recertification-style decay."
  (let ((edges (if founding-event-said
                   (list (cons 'founding-event
                               (make-edge founding-event-said
                                          #:operator 'NI2I
                                          #:schema *schema-playnet-work-event*)))
                   '())))
    (make-credential *schema-playnet-skill*
                     issuing-aid worker-aid
                     (list (cons 'skill              skill)
                           (cons 'founding-event-id  founding-event-said)
                           (cons 'valid-from         valid-from)
                           (cons 'valid-until        valid-until)
                           (cons 'issued-by          issuing-aid))
                     edges)))

(define* (make-claim-event-credential
          scope-aid claimant-aid event-id labor-cost unit
          #:key (resource-spec #f) (qty #f) (timestamp #f) (settles #f))
  "Claim-event ACDC: the consumption mirror of the work-event ACDC. CLAIMANT-AID
   draws LABOR-COST hours of earned credit to receive RESOURCE-SPEC. Issuer =
   scope, holder = claimant. No balance lives on the token — credit is DERIVED:
   gross (work-event ACDCs) − claimed (these). When SETTLES is a <claim> SAID,
   an NI2I edge records which planning-layer claim this draw settles."
  (let ((edges (if settles
                   (list (cons 'settles (make-edge settles #:operator 'NI2I #:schema #f)))
                   '())))
    (make-credential *schema-playnet-claim*
                     scope-aid claimant-aid
                     (list (cons 'event-id      event-id)
                           (cons 'claimant      claimant-aid)
                           (cons 'labor-cost    labor-cost)
                           (cons 'unit          unit)
                           (cons 'resource-spec resource-spec)
                           (cons 'qty           qty)
                           (cons 'timestamp     timestamp)
                           (cons 'settles       settles))
                     edges)))

(define* (make-external-index-observation-credential
          oracle-aid index-uri observed-value observed-at
          #:key (holder-aid #f) (source-note #f)
          (signing-keypair #f) (multisig-signers #f))
  "External index observation ACDC: an oracle records a scalar reading
   of an external data stream at a timestamp.

   index-uri:     string identifying the external source (e.g.
                  \"market:slabs-aaa-abx\", \"fred:gdp-us\").
   observed-value: number.
   observed-at:   epoch seconds (number) or ISO-8601 string.
   source-note:   optional provenance string.

   Issuer = oracle-aid; holder defaults to oracle-aid unless specified
   (e.g. federated dashboards may hold externally-issued observations)."
  (make-credential *schema-playnet-external-index-observation*
                   oracle-aid
                   (or holder-aid oracle-aid)
                   (list (cons 'index-uri      index-uri)
                         (cons 'observed-value observed-value)
                         (cons 'observed-at    observed-at)
                         (cons 'source-note    source-note))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-playnet-work-event*                 (event-id fulfills)       timestamp)
   (,*schema-playnet-observation-event*          (event-id fulfills))
   (,*schema-playnet-external-index-observation* (index-uri)               observed-at)
   (,*schema-playnet-contrary-observation*       (scope-id process action) observed-at)
   (,*schema-playnet-skill*                      (skill))
   (,*schema-playnet-claim*                      (event-id))))
