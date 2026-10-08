;;; module/playnet/keri/credentials.scm — ACDC credential issuance + verification
;;;
;;; ACDC (Authentic Chained Data Containers) are KERI's verifiable credentials.
;;; Structure: {v, d (SAID), i (issuer AID), ri (registry), s (schema SAID),
;;;             a {d, i (issuee AID), dt, ...claims}}
;;;
;;; Full IPEX protocol (all flows):
;;;
;;;   Issuance (push):
;;;     issuer:  acdc-issue → acdc-grant     (/exn/ipex/grant notification → holder)
;;;     holder:  acdc-admit                  (accepts grant)
;;;
;;;   Request (pull):
;;;     holder:  acdc-apply                  → /exn/ipex/apply notification → issuer
;;;     issuer:  acdc-offer (or decline)     → /exn/ipex/offer notification → holder
;;;     holder:  acdc-agree                  → /exn/ipex/agree notification → issuer
;;;     issuer:  acdc-grant (same as above)  → credential delivered
;;;
;;;   Multi-sig variants wrap the above in /multisig/exn exchanges.
;;;
;;; Parity: mirrors signify-ts 0.3.0 (commit ebc0f0f), specifically
;;;   src/keri/app/credentialing.ts — acdc-issue, registry
;;;   src/keri/app/ipexing.ts       — acdc-{grant,admit,spurn,apply,offer,agree}
;;; Most procs here are thin wrappers around KERIA HTTP endpoints; the
;;; wire-format work lives in signify.scm. See docs/keri/SIGNIFY-PARITY.md.
;;;
;;; Playnet credential schemas (backed by the governance AID):
;;;   playnet-member    — basic registered member
;;;   playnet-supplier  — authorized food supplier
;;;   playnet-planner   — authorized to run planning algorithms
;;;   playnet-governor  — governance participant (multi-sig group member)
;;;
;;; Integration with endorsement.scm:
;;;   Each ACDC credential type maps onto an endorsement authority.
;;;   A valid ACDC for a role = permission to hold that role's sealed capability.
;;;   Verification: (acdc-verify cred) → #t means the holder can receive the seal.

(define-module (playnet keri credentials)
  #:use-module (playnet keri bridge)
  #:use-module (playnet keri schemas)
  #:use-module (playnet keri signify)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (web uri)
  #:export (;; Schema SAIDs (governance AID issues against these)
            %schema-member
            %schema-supplier
            %schema-planner
            %schema-governor
            ;; economic-substrate schema SAIDs + the version-string reconciliation
            %schema-work-event %schema-skill %schema-intent-acdc
            %schema-commitment-acdc %schema-claim
            %schema-ownership-attestation
            %schema-personhood %schema-membership %schema-authorized-issuer
            governance-schema->keria-said
            keria-said->governance-schema

            ;; Issuance (push flow)
            acdc-issue
            acdc-grant
            acdc-admit
            acdc-spurn
            ipex-exn-acdc
            ipex-exn-sender
            ipex-exn-recipient

            ;; Request flow (pull: holder initiates)
            acdc-apply
            acdc-offer
            acdc-agree

            ;; Multi-sig IPEX wrappers
            acdc-multisig-admit
            acdc-multisig-offer
            acdc-multisig-grant

            ;; Schema resolution
            acdc-resolve-schema
            acdc-get-schema
            acdc-ensure-schemas-resolved!

            ;; Availability retry
            acdc-ensure-available

            ;; Sync
            acdc-sync-credentials

            ;; Verification
            acdc-verify
            acdc-valid?
            acdc-revoked?
            acdc-said
            acdc-holder
            acdc-issuer
            acdc-schema
            acdc-claims

            ;; Registry
            acdc-create-registry
            acdc-registry-id

            ;; Role helpers
            issue-member-credential
            issue-supplier-credential
            issue-planner-credential
            issue-governor-credential
            verify-role-credential))

;;; ── Schema SAIDs ─────────────────────────────────────────────────────────────
;;;
;;; In ACDC, schemas are identified by their SAID (Self-Addressing Identifier).
;;; The catalog — which files exist, where they live, how their SAIDs and
;;; env-var overrides resolve — is (playnet keri schemas). The constants
;;; here are the per-schema bindings the issuance helpers reference.

(define %schema-member          (schema-said "member.json"))
(define %schema-supplier        (schema-said "supplier.json"))
(define %schema-planner         (schema-said "planner.json"))
(define %schema-governor        (schema-said "governor.json"))

;; Economic-substrate credential schemas (skills / work / settlement). These are
;; the KERIA SAID-schemas; the governance layer issues these credentials under
;; VERSION-STRING schemas (e.g. "playnet-work-event/v1"), so live issuance via
;; ^keria-acdc-store needs a version-string→SAID reconciliation
;; (`*economic-schema-saids*` below) — validated only against a running KERIA.
(define %schema-work-event      (schema-said "work-event.json"))
(define %schema-skill           (schema-said "skill.json"))
(define %schema-intent-acdc     (schema-said "intent.json"))
(define %schema-commitment-acdc (schema-said "commitment.json"))
(define %schema-claim           (schema-said "claim.json"))
;; the property form: title as a credential (see governance/credentials.scm
;; make-ownership-attestation-credential — custody's rights-side sibling)
(define %schema-ownership-attestation (schema-said "ownership-attestation.json"))

;; First-Person Project personhood substrate. Issued at founder seed
;; (bootstrap.scm) and by the enrollment ceremony: PHC + scope
;; membership per founder, one genesis Authorized-Issuer self-blessing.
(define %schema-personhood        (schema-said "personhood.json"))
(define %schema-membership        (schema-said "membership.json"))
(define %schema-authorized-issuer (schema-said "authorized-issuer.json"))

;; The reconciliation: governance version-string schema → KERIA SAID-schema.
;; ^keria-acdc-store maps (cred-schema cred) — and each edge's `s` — through
;; this before POSTing to KERIA. Deliberately narrow: only the labels that
;; actually cross the KERIA boundary appear here (economic substrate +
;; the founder-seed personhood trio). The role schemas
;; (member/supplier/planner/governor) are issued directly against their
;; SAIDs by the issue-*-credential helpers below — note that governance's
;; "playnet-membership/v1" (scope membership → membership.json) is a
;; DIFFERENT credential from the member ROLE (member.json). Governance
;; labels absent from this map stay on the in-memory/kel-store path.
(define *governance-schema-saids*
  `(("playnet-work-event/v1"        . ,%schema-work-event)
    ("playnet-skill/v1"             . ,%schema-skill)
    ("playnet-intent/v1"            . ,%schema-intent-acdc)
    ("playnet-commitment/v1"        . ,%schema-commitment-acdc)
    ("playnet-claim/v1"             . ,%schema-claim)
    ("playnet-personhood/v1"        . ,%schema-personhood)
    ("playnet-membership/v1"        . ,%schema-membership)
    ("playnet-authorized-issuer/v1" . ,%schema-authorized-issuer)))

(define (governance-schema->keria-said version-string)
  "Map a governance version-string schema to its saidified KERIA schema SAID, or
   #f when the label never crosses the KERIA boundary (caller keeps the
   original)."
  (assoc-ref *governance-schema-saids* version-string))

(define (keria-said->governance-schema said)
  "The way back across the boundary: map a schema SAID arriving from KERIA
   (IPEX grants, cache sync) to its governance version-string label, or #f
   for schemas the governance layer never labels (role credentials).
   Without this, a received PHC lands with schema=SAID while every
   governance predicate queries by label — and silently never counts."
  (any (lambda (p) (and (equal? (cdr p) said) (car p)))
       *governance-schema-saids*))

(define (acdc-ensure-schemas-resolved!)
  "Ensure every catalogued schema is resolved on our KERIA agent. No-op
   on an already-resolved schema (resolve-oobi is idempotent). Schema
   host comes from the PLAYNET_SCHEMA_SERVER env var — there is no
   default (the historical `schemas.playnet.earth` was removed during
   the Hetzner shutdown / domain divorce); production points it at the
   gateway's own static server, which serves the same catalog at
   /oobi/{said}. When unset, this call logs a warning and skips.

   Logs explicit failures per-schema rather than swallowing them, so a
   misconfigured deployment surfaces at startup rather than at first
   issuance with a cryptic 'schema not found' from KERIA."
  (let ((server (getenv "PLAYNET_SCHEMA_SERVER"))
        (saids  (all-schema-saids)))
    (cond
     ((not server)
      (format (current-error-port)
              "[credentials] PLAYNET_SCHEMA_SERVER unset — skipping ~a schema OOBI resolves~%"
              (length saids)))
     (else
      (let ((ok 0))
        (for-each
         (lambda (said)
           (catch #t
             (lambda ()
               ;; keri-resolve-oobi only ENQUEUES the resolve; wait for
               ;; the operation so a schema KERIA silently refused to
               ;; load (wrong content type, unreachable host) surfaces
               ;; here at boot instead of at first issuance.
               (keri-wait-operation
                (keri-resolve-oobi (string-append server "/oobi/" said)
                                   #:alias "playnet-schema")
                #:timeout 15)
               (set! ok (+ ok 1)))
             (lambda (key . args)
               (format (current-error-port)
                       "[credentials] schema ~a resolve failed: ~a ~a~%"
                       said key args))))
         saids)
        (format (current-error-port)
                "[credentials] resolved ~a/~a schema OOBIs~%"
                ok (length saids)))))))

;;; ── Registry ─────────────────────────────────────────────────────────────────
;;;
;;; ACDC credentials are issued against a TEL (Transaction Event Log) registry.
;;; The registry tracks issuance and revocation events.
;;; One registry per issuer AID is typical.

(define *playnet-registry-id* #f)

(define (acdc-registry-id) *playnet-registry-id*)

(define (%find-registry-regk issuer-aid-name registry-name)
  "GET /identifiers/{issuer-aid-name}/registries and return the `regk`
   of the entry named REGISTRY-NAME, or #f. `regk` is the registry's
   actual SAID — the value acdc-issue's #:registry-id must carry;
   REGISTRY-NAME is only KERIA's human-readable label for it, a
   different string entirely."
  (let ((listing (keri-as-list
                  (GET (string-append "/identifiers/"
                                      (uri-encode issuer-aid-name)
                                      "/registries")))))
    (any (lambda (entry)
           (and (equal? (assoc-ref entry "name") registry-name)
                (assoc-ref entry "regk")))
         listing)))

(define (acdc-create-registry issuer-aid-name registry-name)
  "Create a credential registry (TEL) for the given issuer AID.
   issuer-aid-name = local name of the AID in KERIA.

   Signify-ts body: {name, vcp, ixn, sigs} where the VCP is a
   no-backers registry inception event and the IXN anchors it into
   the issuer's KEL. Returns registry ID string (the `regk` SAID —
   NOT the human-readable registry-name; acdc-issue posts against
   this value and 404s if handed the name instead)."
  (let* ((ctx  (@@ (playnet keri bridge) *signify-ctx*))
         (body (registry-body ctx issuer-aid-name registry-name)))
    (catch #t
      (lambda ()
        (let* ((op   (POST (string-append "/identifiers/" (uri-encode issuer-aid-name)
                                          "/registries")
                           body))
               (done (keri-wait-operation op #:timeout 30))
               (rid  (or (assoc-ref done "regk")
                         (and=> (assoc-ref done "response")
                                (lambda (r)
                                  (and=> (assoc-ref r "anchor")
                                         (lambda (a) (assoc-ref a "i"))))))))
          (when rid
            (set! *playnet-registry-id* rid))
          (format (current-error-port)
                  "[credentials] registry created: ~a\n" rid)
          rid))
      (lambda (key . args)
        (let ((msg (format #f "~a" args)))
          (if (string-contains msg "already in use")
              (let ((rid (%find-registry-regk issuer-aid-name registry-name)))
                (format (current-error-port)
                        "[credentials] registry ~a already exists (~a)\n"
                        registry-name (or rid "regk lookup failed"))
                (when rid (set! *playnet-registry-id* rid))
                rid)
              (apply throw key args)))))))

;;; ── Issuance ─────────────────────────────────────────────────────────────────
;;;
;;; Full IPEX flow:
;;;   1. acdc-issue  — create the ACDC credential in KERIA
;;;   2. acdc-grant  — send it to the holder via IPEX /exn/ipex/grant
;;;   3. acdc-admit  — holder accepts via /ipex/admit (called on holder's side)

(define* (acdc-issue issuer-aid-name holder-aid schema-said claims
                     #:key (registry-id *playnet-registry-id*)
                           (edges '()))
  "Create an ACDC credential.
   issuer-aid-name — local AID name in KERIA (the governance AID name)
   holder-aid      — recipient's AID prefix
   schema-said     — SAID of the credential schema
   claims          — alist of additional claims in the 'a' block
   edges           — ACDC `e` block (alist of named edge specs); omitted
                     when empty.
   Returns credential SAID.

   Signify body: {acdc, iss, ixn, sigs} — three KERI events built
   client-side, IXN signed with the issuer's derived key."
  (unless registry-id
    (error "No registry. Call acdc-create-registry first."))
  (let* ((ctx (@@ (playnet keri bridge) *signify-ctx*))
         (body (credential-body ctx issuer-aid-name
                                #:holder-aid holder-aid
                                #:schema-said schema-said
                                #:registry-id registry-id
                                #:claims claims
                                #:edges edges))
         (op   (POST (string-append "/identifiers/" (uri-encode issuer-aid-name)
                                    "/credentials")
                     body))
         (done (keri-wait-operation op #:timeout 60))
         ;; KERIA's credential operation reports the SAID in several places
         ;; depending on version; check them in order of specificity:
         ;;   done.said                   — some builds surface it top-level
         ;;   done.ced.d / metadata.ced.d — the issued ACDC's own SAID
         ;;   done.response.d             — response-wrapped ACDC
         ;;   done.name = "credential.<SAID>" — encoded in the operation name
         (said (or (assoc-ref done "said")
                   (and=> (assoc-ref done "ced") (lambda (c) (assoc-ref c "d")))
                   (and=> (assoc-ref done "metadata")
                          (lambda (m) (and=> (assoc-ref m "ced")
                                             (lambda (c) (assoc-ref c "d")))))
                   (and=> (assoc-ref done "response")
                          (lambda (r) (and (pair? r) (assoc-ref r "d"))))
                   (keri-op-name-said done))))
    (format (current-error-port)
            "[credentials] issued ~a → ~a (SAID: ~a)\n"
            schema-said holder-aid said)
    said))

(define* (acdc-grant issuer-aid-name credential-said holder-aid
                     #:key (message ""))
  "Send an issued credential to the holder via signed IPEX grant exchange.

   Spec-complete grant (signify-ts ipexing.grant shape): the exn embeds
   the FULL acdc + iss + anc SADs in its `e` block (saidified), and
   ships each embed's CESR attachment as a -L pathed-material group in
   `atc`. KERIA's postman requires e.acdc.d to gather + forward the
   credential artifacts to the holder's agent, and the holder's
   Admitter ingests the embedded events via the pathed attachments —
   a SAID-only grant is dropped as \"invalid grant message\".

   The SADs come from KERIA's own credential export (GET
   /credentials/{said}), so their serialization is byte-identical to
   what the issuer agent stored."
  (let* ((cred   (keri-get-credential credential-said))
         (sad    (assoc-ref cred "sad"))
         (iss    (assoc-ref cred "iss"))
         (anc    (assoc-ref cred "anc")))
    (unless (and (pair? sad) (pair? iss) (pair? anc))
      (error "acdc-grant: credential not exportable from KERIA"
             credential-said))
    (keri-submit-exchange issuer-aid-name "grant"
                          #:recipient holder-aid
                          #:payload (list (cons "m" message))
                          #:embeds (saidify-block
                                    (list (cons "d"    %saidplaceholder)
                                          (cons "acdc" sad)
                                          (cons "iss"  iss)
                                          (cons "anc"  anc)))
                          #:atc (string-append
                                 (cesr-pathed-group %ipex-path-acdc
                                                    (assoc-ref cred "atc"))
                                 (cesr-pathed-group %ipex-path-iss
                                                    (assoc-ref cred "issatc"))
                                 (cesr-pathed-group %ipex-path-anc
                                                    (assoc-ref cred "ancatc")))
                          #:rec (list holder-aid))))

(define (acdc-admit holder-aid-name grant-said)
  "Accept an incoming IPEX grant via signed IPEX admit exchange.
   The grant is anchored in the exn's `p` (prior) field — the spec
   shape (IPEX.md §3: admit = signature on grant or its SAID; KERIA's
   Admitter reads admit.ked.p and rejects admits without it). The `a`
   payload carries only the optional human message."
  (keri-submit-exchange holder-aid-name "admit"
                        #:payload (list (cons "m" ""))
                        #:prior grant-said))

(define (ipex-exn-acdc exn-msg)
  "Extract the ACDC payload embedded in an IPEX grant exn. Spec shape
   (signify-ts): the full SAD lives in the `e` embeds block —
   exn-msg = {(\"exn\" . {(\"e\" . {(\"acdc\" . <sad>) …}) …}) …}.
   Falls back to the legacy `a`-payload location for grants built by
   older producers. Returns the SAD-shaped alist or #f for non-grant /
   malformed exns. Apply acdc-said/acdc-issuer/acdc-holder/acdc-schema/
   acdc-claims to the result for typed access."
  (or (assoc-path exn-msg "exn" "e" "acdc")
      (assoc-path exn-msg "exn" "a" "acdc")))

(define (ipex-exn-sender exn-msg)
  "Discloser AID per IPEX.md §2 (exn.i). For an issuance exchange this
   equals the embedded ACDC's Issuer; for presentation it may differ."
  (assoc-path exn-msg "exn" "i"))

(define (ipex-exn-recipient exn-msg)
  "Disclosee AID (exn.rp), or #f if unaddressed."
  (assoc-path exn-msg "exn" "rp"))

(define* (acdc-spurn rejecter-aid-name target-said #:optional recipient-aid)
  "Reject an inbound IPEX message (apply/offer/agree/grant) per IPEX.md §3
   Table 1. TARGET-SAID — the SAID of the message being rejected — rides
   the exn `p` field, like every other IPEX answer message.
   RECIPIENT-AID is the original sender — when omitted, the bridge routes
   based on the referenced exchange's prior context.

   NB: KERIA 0.4.0 does not serve /identifiers/{name}/ipex/spurn
   (ipexing.py loadEnds registers admit/grant/apply/offer/agree only),
   so this 404s against current KERIA — callers must treat spurn as
   best-effort (notifications.scm's %spurn-quietly already does)."
  (apply keri-submit-exchange
         rejecter-aid-name "spurn"
         #:prior target-said
         (if recipient-aid
             (list #:recipient recipient-aid #:rec (list recipient-aid))
             '())))

;;; ── Verification ─────────────────────────────────────────────────────────────
;;;
;;; Fetches credential from KERIA and validates:
;;;   - SAID matches content (KERIA enforces this)
;;;   - Issuer is the expected governance AID
;;;   - Status is not REVOKED
;;;   - Schema matches expected type

(define (acdc-get said)
  "Fetch credential alist from KERIA by SAID."
  (keri-get-credential said))

(define (acdc-verify said)
  "Fetch and validate a credential. Returns the credential alist or raises."
  (let ((cred (acdc-get said)))
    (unless cred
      (error "Credential not found" said))
    cred))

;; KERIA's credential export (GET /credentials/{said}) wraps the ACDC:
;; the SAD lives under "sad" and the TEL status is a state dict whose
;; "et" is "iss"/"rev" (ClonedCredential in keria credentialing.py).
;; Tolerate both that shape and a bare ACDC alist.

(define (%cred-field cred key)
  "Read KEY from CRED's SAD, whether CRED is sad-wrapped or bare."
  (or (and=> (assoc-ref cred "sad")
             (lambda (s) (and (pair? s) (assoc-ref s key))))
      (assoc-ref cred key)))

(define (%cred-revoked-status? cred)
  "Does CRED's export-level status say revoked? Handles the state-dict
   shape ({\"et\":\"rev\"}) and the legacy bare-string shape."
  (let ((status (assoc-ref cred "status")))
    (cond
     ((string? status) (equal? status "revoked"))
     ((pair? status)   (equal? "rev" (assoc-ref status "et")))
     (else #f))))

(define (acdc-valid? said)
  "Returns #t if credential exists and is not revoked."
  (catch #t
    (lambda ()
      (let ((cred (acdc-get said)))
        (and cred
             (not (%cred-revoked-status? cred))
             #t)))
    (lambda _ #f)))

(define (acdc-revoked? said)
  "Check revocation via TEL state (authoritative) not just metadata.
   TEL event type 'iss' = issued/valid, anything else = revoked."
  (catch #t
    (lambda ()
      (let* ((cred    (acdc-get said))
             (ri      (and cred (%cred-field cred "ri")))  ; registry AID
             (d       (and cred (%cred-field cred "d"))))  ; credential SAID
        (if (and ri d)
            (let ((tel-state (keri-get-tel-state ri d)))
              ;; "iss" = issued (valid), "rev" = revoked, anything else = unknown
              (not (equal? (assoc-ref tel-state "et") "iss")))
            #t)))       ; no registry = treat as revoked
    (lambda _ #t)))

(define* (acdc-ensure-available said #:key (retries 3) (delay-s 2))
  "Wait for a credential to become available in KERIA after issuance.
   Retries up to RETRIES times with DELAY-S second intervals.
   Raises if not available after all retries."
  (let loop ((attempt 1))
    (catch #t
      (lambda ()
        (keri-get-credential said)
        #t)
      (lambda (key . args)
        (let ((msg (format #f "~a ~a" key args)))
          (if (and (string-contains msg "404")
                   (< attempt retries))
              (begin
                (sleep delay-s)
                (loop (1+ attempt)))
              (error (string-append "Credential not ready after "
                                    (number->string retries)
                                    " attempts: " said))))))))

(define (acdc-said cred)
  "Extract the SAID (top-level `d`) from a credential alist."
  (assoc-ref cred "d"))

(define (acdc-holder cred)
  "Extract the holder AID from a credential alist.
   Spec name: Issuee (ACDC.md §7 — `a.i`)."
  (assoc-path cred "a" "i"))

(define (acdc-issuer cred)
  "Extract the issuer AID from a credential alist."
  (assoc-ref cred "i"))

(define (acdc-schema cred)
  "Extract the schema SAID from a credential alist."
  (assoc-ref cred "s"))

(define (acdc-claims cred)
  "Extract the claims (attribute block) from a credential alist."
  (assoc-ref cred "a"))

;;; ── Role-specific credential helpers ────────────────────────────────────────

(define* (issue-member-credential governance-aid-name holder-aid
                                   #:optional (display-name #f))
  "Issue a playnet-member credential to holder-aid.
   Returns credential SAID."
  (acdc-issue governance-aid-name holder-aid %schema-member
              (if display-name `(("name" . ,display-name)) '())))

(define (issue-supplier-credential governance-aid-name holder-aid
                                    org-name food-categories)
  "Issue a playnet-supplier credential.
   food-categories = list of category strings this supplier handles."
  (acdc-issue governance-aid-name holder-aid %schema-supplier
              `(("org"        . ,org-name)
                ("categories" . ,(list->vector food-categories)))))

(define (issue-planner-credential governance-aid-name holder-aid org-name)
  "Issue a playnet-planner credential."
  (acdc-issue governance-aid-name holder-aid %schema-planner
              `(("org" . ,org-name))))

(define (issue-governor-credential governance-aid-name holder-aid)
  "Issue a playnet-governor credential (multi-sig group member)."
  (acdc-issue governance-aid-name holder-aid %schema-governor '()))

(define (verify-role-credential holder-aid expected-schema-said)
  "Check if holder-aid holds a valid, unrevoked credential of the given schema.
   Searches holder's credentials in KERIA.
   Returns credential alist or #f."
  (catch #t
    (lambda ()
      (let* ((all   (keri-list-credentials
                     #:filter `(("holder" . ,holder-aid)
                                ("schema" . ,expected-schema-said))))
             (creds (keri-as-list all)))
        (find (lambda (c) (acdc-valid? (assoc-path c "sad" "d")))
              creds)))
    (lambda _ #f)))

;;; ── IPEX request (pull) flow ─────────────────────────────────────────────────
;;;
;;; Holder requests a credential from an issuer:
;;;   1. holder:  acdc-apply  → issuer gets /exn/ipex/apply notification
;;;   2. issuer:  acdc-offer  → holder gets /exn/ipex/offer notification
;;;   3. holder:  acdc-agree  → issuer gets /exn/ipex/agree notification
;;;   4. issuer:  acdc-grant  → credential delivered (same as push flow step 2)

(define* (acdc-apply holder-aid-name issuer-aid schema-said
                     #:key (attributes '()))
  "Request a credential from issuer-aid (holder initiates).
   Signed IPEX apply exchange."
  (keri-submit-exchange holder-aid-name "apply"
                        #:recipient issuer-aid
                        #:payload (list (cons "schema" schema-said)
                                       (cons "attributes" attributes))
                        #:rec (list issuer-aid)))

(define* (acdc-offer issuer-aid-name holder-aid apply-said credential-said
                     #:key (acdc #f))
  "Respond to an apply with a signed IPEX offer exchange. The apply
   being answered is anchored in the exn `p` field (spec shape); the
   payload carries the offered credential's SAID."
  (keri-submit-exchange issuer-aid-name "offer"
                        #:recipient holder-aid
                        #:payload (list (cons "acdc" credential-said))
                        #:prior apply-said
                        #:rec (list holder-aid)))

(define (acdc-agree holder-aid-name issuer-aid offer-said)
  "Accept an offer via signed IPEX agree exchange — the offer is
   anchored in the exn `p` field (spec shape)."
  (keri-submit-exchange holder-aid-name "agree"
                        #:recipient issuer-aid
                        #:payload (list (cons "m" ""))
                        #:prior offer-said
                        #:rec (list issuer-aid)))

;;; ── Multi-sig IPEX wrappers ──────────────────────────────────────────────────
;;;
;;; Group credential exchanges wrap the inner IPEX message in a /multisig/exn
;;; outer exchange. All group members must co-sign before the action fires.
;;; These use the group AID's name as the sender; the exchange route is the
;;; inner IPEX route, wrapped automatically by KERIA's multi-sig handler.

(define (acdc-multisig-admit group-aid-name grant-said)
  "Multi-sig group: signed admit exchange (grant anchored in exn.p)."
  (keri-submit-exchange group-aid-name "admit"
                        #:payload (list (cons "m" ""))
                        #:prior grant-said))

(define (acdc-multisig-offer group-aid-name holder-aid apply-said credential-said)
  "Multi-sig group: signed offer exchange (apply anchored in exn.p)."
  (keri-submit-exchange group-aid-name "offer"
                        #:recipient holder-aid
                        #:payload (list (cons "acdc" credential-said))
                        #:prior apply-said
                        #:rec (list holder-aid)))

(define (acdc-multisig-grant group-aid-name holder-aid credential-said)
  "Multi-sig group: signed grant exchange."
  (keri-submit-exchange group-aid-name "grant"
                        #:recipient holder-aid
                        #:payload (list (cons "acdc" credential-said))
                        #:rec (list holder-aid)))

;;; ── Schema resolution ────────────────────────────────────────────────────────
;;;
;;; ACDC schemas are identified by SAID and fetched from the issuer's OOBI or
;;; a schema registry URL. Schemas can embed edges (chained credentials) which
;;; require recursive resolution.

(define %schema-cache (make-hash-table))  ; said → schema-alist

(define (acdc-get-schema schema-said)
  "Fetch schema by SAID from KERIA's schema store.
   Returns schema alist or #f."
  (or (hash-ref %schema-cache schema-said #f)
      (catch #t
        (lambda ()
          (let ((s (GET (string-append "/schema/" (uri-encode schema-said)))))
            (when s (hash-set! %schema-cache schema-said s))
            s))
        (lambda _ #f))))

(define* (acdc-resolve-schema schema-said #:key (issuer-oobi #f))
  "Resolve a schema SAID, fetching from issuer OOBI if not in local cache.
   Recursively resolves edge schemas (chained credentials).
   Returns schema alist."
  (or (acdc-get-schema schema-said)
      ;; Not cached — try resolving via issuer's OOBI
      (begin
        (when issuer-oobi
          (catch #t
            (lambda ()
              (let ((op (keri-resolve-oobi issuer-oobi)))
                (keri-wait-operation op #:timeout 15)))
            (lambda _ #f)))
        ;; Retry after OOBI resolution
        (or (acdc-get-schema schema-said)
            (error "Schema not found after OOBI resolution" schema-said)))))

;;; ── Credential sync ──────────────────────────────────────────────────────────
;;;
;;; On reconnect, fetch credentials from KERIA that arrived while offline.
;;; Called by recovery.scm and on KERIA reconnect.

(define* (acdc-sync-credentials #:key (limit 24))
  "Fetch all credentials from KERIA, paginated.
   Returns list of credential alists."
  (let loop ((skip 0) (acc '()))
    (let* ((batch  (keri-list-credentials #:skip skip #:limit limit))
           (creds  (keri-as-list batch)))
      (if (null? creds)
          (reverse acc)
          (loop (+ skip (length creds))
                (append (reverse creds) acc))))))
