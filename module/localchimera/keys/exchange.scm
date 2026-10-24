;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/keys/exchange.scm — IPEX exchanges signed by
;;;                                            scope-owned keys
;;;
;;; The localchimera stack mints scope AIDs in pure Scheme via
;;; `governance-create-scope-aid!` and stores their keys in vault. Those
;;; AIDs are not registered with signify-ts, so signify can't sign
;;; outbound IPEX exchanges on their behalf — its key-derivation path
;;; assumes the AID was created with `(controller-bran, name)`, which
;;; doesn't match our scopes.
;;;
;;; This module fills the gap: a thin layer that builds + signs IPEX
;;; `exn` events (grant, admit, spurn) using the scope's own keypair,
;;; then submits them via KERIA's generic `/exchanges` endpoint. The
;;; receiving side verifies the signature against the scope's KEL
;;; (fetched via OOBI), so cross-gateway IPEX chains back to the
;;; scope's KEL rather than the gateway's umbrella AID.
;;;
;;; This is the IPEX counterpart of what we already do for ICP / IXN
;;; in (localchimera keri inception): build and sign with scope keys, POST
;;; pre-signed to KERIA.
;;;
;;; Signing-side only. Inbound admit/spurn for scope-addressed
;;; credentials lands at the gateway's own controller signify identity
;;; (via the existing notification poller); whether that identity can
;;; admit on behalf of a scope-AID Issuee is a separate question handled
;;; in (localchimera federation ipex-policy).

(define-module (localchimera keys exchange)
  #:use-module (goblins)
  #:use-module (localchimera keri bridge)
  #:use-module (localchimera keri signify)
  #:use-module ((localchimera keri inception) #:select (gateway-controller-aid-name))
  #:use-module (localchimera keys pending-grants)
  #:use-module ((localchimera keri signify-portable) #:select (ed25519-keypair-secret))
  #:use-module ((localchimera utils hex) #:select (bv->hex hex->bv))
  #:use-module ((localchimera keri crypto-primitives)
                #:select (keri-crypto-ed25519-from-seed))
  #:re-export (current-pending-grants)
  #:export (scope-grant-body
            scope-admit-body
            scope-spurn-body
            governance-cred->wire
            scope-issue-grant!
            scope-submit-admit!
            scope-submit-spurn!
            scope-deliver-grant!))

;; ── Body builders (pure; testable without KERIA) ────────────────────

(define (governance-cred->wire cred)
  "SAD-shaped wire projection of a governance credential alist (the
   symbol-keyed shape `make-credential` returns): d/i/s/a(+e), with
   `a.i` = holder and the claims string-keyed — the shape the
   receiving side's accessors (`acdc-said`/`acdc-holder`/
   `acdc-schema`/`acdc-claims`) and `handle-ipex-grant`'s policy
   checks consume.

   NB `d` is the GOVERNANCE SAID (compute-said over issuer/holder/
   schema/claims/edges) — the discipline every scope-side reference
   (pending queue, admit dedup, ratification edges) is keyed by — not
   a recomputable ACDC-canonical SAID. Receivers verify authenticity
   the governance way: the issuer's signature over `d`
   (verify-said-signature), with the issuer's key state resolved via
   its OOBI."
  (define (->str k) (if (symbol? k) (symbol->string k) k))
  (let ((claims (or (assq-ref cred 'claims) '()))
        (edges  (or (assq-ref cred 'edges)  '()))
        (holder (assq-ref cred 'holder)))
    `(("d" . ,(assq-ref cred 'said))
      ("i" . ,(assq-ref cred 'issuer))
      ("s" . ,(assq-ref cred 'schema))
      ;; `a.i` (the issuee) is emitted ONLY for targeted ACDCs. A #f holder is
      ;; an UNTARGETED ACDC (ACDC §7.5 — a published observation with no target
      ;; AID); emitting `a.i: #f` would wrongly present it as targeted-at-null,
      ;; so the field is omitted entirely, which is what makes it untargeted.
      ("a" . (,@(if holder (list (cons "i" holder)) '())
              ,@(map (lambda (p) (cons (->str (car p)) (cdr p))) claims)))
      ,@(if (null? edges) '()
            `(("e" . ,(map (lambda (p) (cons (->str (car p)) (cdr p)))
                           edges)))))))

(define* (scope-grant-body aid-prefix aid-keypair credential-said holder-aid
                           #:key (cred #f))
  "Build a {exn, sigs, atc, rec} body for IPEX.md §3 `grant` signed by
   the scope at AID-PREFIX using AID-KEYPAIR.

   CREDENTIAL-SAID is the SAID of the ACDC being delivered.
   HOLDER-AID is the Issuee receiving the credential.
   CRED — the governance credential alist from the scope's acdc-store.
   When supplied, its wire projection is EMBEDDED in the exn's `e`
   block (saidified, like acdc-grant's spec-complete shape), so
   localchimera receivers (`handle-ipex-grant` → `ipex-exn-acdc`) get the
   full credential inside the grant — no out-of-band fetch. The
   legacy `a.acdc` SAID also rides for older receivers.

   REMAINING DIVERGENCE (documented, structural): no iss/anc embeds —
   scopes run no TEL (issuance is KEL-ixn-anchored), and KERIA's
   postman cannot forward scope credentials regardless (its Granter
   gathers artifacts from KERIA's OWN registry, which never holds
   scope-issued creds). The embed is what makes the exn itself
   self-contained for localchimera receivers."
  (let ((embeds (and cred
                     (saidify-block
                      (list (cons "d" %saidplaceholder)
                            (cons "acdc" (governance-cred->wire cred)))))))
    (scope-exchange-body aid-prefix aid-keypair "/ipex/grant"
                         #:recipient holder-aid
                         #:payload (list (cons "acdc" credential-said))
                         #:embeds  (or embeds '())
                         #:rec     (list holder-aid))))

(define (scope-admit-body aid-prefix aid-keypair grant-said)
  "Build a signed IPEX `admit` body. GRANT-SAID — the SAID of the grant
   being accepted — is anchored in the exn `p` field (spec shape:
   IPEX.md §3 admit = signature on grant or its SAID; KERIA's Admitter
   reads admit.ked.p and rejects admits without it). No recipient —
   admit is a terminal local acknowledgement; the originating Discloser
   learns of acceptance via their own poller seeing the notification."
  (scope-exchange-body aid-prefix aid-keypair "/ipex/admit"
                       #:payload (list (cons "m" ""))
                       #:prior grant-said))

(define* (scope-spurn-body aid-prefix aid-keypair target-said
                           #:optional recipient-aid)
  "Build a signed IPEX `spurn` body. TARGET-SAID — the SAID of the
   message being rejected (apply / offer / agree / grant per IPEX.md
   §3 Table 1) — rides the exn `p` field like every IPEX answer.
   RECIPIENT-AID is the original Discloser; omit to let KERIA route
   based on the referenced exchange's prior context. NB KERIA 0.4.0
   serves no /ipex/spurn route — submission is best-effort."
  (scope-exchange-body aid-prefix aid-keypair "/ipex/spurn"
                       #:recipient (or recipient-aid "")
                       #:prior target-said
                       #:rec     (if recipient-aid
                                     (list recipient-aid)
                                     '())))

;; ── Submission helpers (one-step build + POST) ──────────────────────
;;
;; KERIA's IPEX endpoints are /identifiers/{transport}/ipex/{verb} where
;; `transport` is a signify-managed local identifier. The exn.i carried
;; in the body can be external (KERIA doesn't validate sender against
;; local registry — confirmed in keria/app/ipexing.py). For localchimera we
;; route through the gateway's own controller AID; the cryptographic
;; content (scope-signed exn) is what receivers verify.

(define* (scope-issue-grant! aid-prefix aid-keypair credential-said holder-aid
                             #:key (cred #f))
  "Build and submit an IPEX `grant` under a scope-owned key. Returns
   KERIA's response (an operation alist) on success; propagates any
   transport error so callers (e.g. the gateway's pending-grants queue)
   can retry. CRED — see scope-grant-body."
  (keri-submit-scope-exchange
   (gateway-controller-aid-name) "grant"
   (scope-grant-body aid-prefix aid-keypair credential-said holder-aid
                     #:cred cred)))

(define (scope-submit-admit! aid-prefix aid-keypair grant-said)
  "Build and submit an IPEX `admit` under a scope-owned key."
  (keri-submit-scope-exchange
   (gateway-controller-aid-name) "admit"
   (scope-admit-body aid-prefix aid-keypair grant-said)))

(define* (scope-submit-spurn! aid-prefix aid-keypair target-said
                              #:optional recipient-aid)
  "Build and submit an IPEX `spurn` under a scope-owned key."
  (keri-submit-scope-exchange
   (gateway-controller-aid-name) "spurn"
   (scope-spurn-body aid-prefix aid-keypair target-said recipient-aid)))

;; ── Best-effort delivery ────────────────────────────────────────────
;;
;; Used by governance callsites (admit-commune, admit-commune-remote)
;; that have JUST issued a credential locally and want to push it via
;; IPEX *if* KERIA is reachable. Local issuance is the source of
;; truth; the grant is delivery, and it being deferred (KERIA down,
;; synthetic scope, missing inputs) is not an error condition.

;; Replay function for scope-grant entries. Registered at load time so
;; the gateway's drain fiber knows how to retry these. The payload
;; carries the raw keypair seed (hex) rather than the keypair record,
;; because the disk-persistence format has to be serialisable.
(define (%replay-scope-grant payload)
  (let ((aid       (assoc-ref payload 'scope-aid))
        (seed-hex  (assoc-ref payload 'seed-hex))
        (cred-said (assoc-ref payload 'cred-said))
        (holder    (assoc-ref payload 'holder))
        (cred      (assoc-ref payload 'cred)))   ; #f for pre-embed entries
    (and aid seed-hex cred-said holder
         (let ((kp (keri-crypto-ed25519-from-seed (hex->bv seed-hex))))
           (scope-issue-grant! aid kp cred-said holder #:cred cred)
           #t))))

(register-replay-fn! 'scope-grant %replay-scope-grant)

(define* (scope-deliver-grant! scope-aid scope-keypair cred-said holder-aid
                               #:key (acdc-store #f) (cred #f))
  "Best-effort IPEX-grant delivery under the scope's own signature.
   On transient failure (KERIA down etc.), enqueue to the
   `current-pending-grants` actor for retry by the gateway's drain
   fiber. No-ops when inputs are missing or KERIA was never connected
   in this process (e.g. tests, browser personas).

   CRED (or ACDC-STORE to look it up by CRED-SAID, same-vat `$`) turns
   on the spec-shaped embed: the credential's wire projection rides
   the exn `e` block, so receivers need no out-of-band fetch. The
   retry entry carries the credential alist too — deferred grants
   replay with the same embed."
  (when (and scope-keypair cred-said holder-aid (keri-connected?))
    (let ((cred (or cred
                    (and acdc-store
                         (catch #t
                           (lambda () ($ acdc-store 'get cred-said))
                           (lambda _ #f))))))
      (catch #t
        (lambda ()
          (scope-issue-grant! scope-aid scope-keypair cred-said holder-aid
                              #:cred cred))
        (lambda (key . args)
          (format (current-error-port)
                  "[scope-exchange] grant deferred (~a → ~a): ~a ~a~%"
                  cred-said holder-aid key args)
          ;; Enqueue for retry. We pass the keypair as a hex-encoded seed
          ;; so the entry survives gateway restart (closures don't
          ;; serialise; raw bytes do).
          (let ((q (current-pending-grants)))
            (when q
              (<- q 'enqueue
                  (make-pending-grant
                   'scope-grant
                   `((scope-aid . ,scope-aid)
                     (seed-hex  . ,(bv->hex (ed25519-keypair-secret
                                             scope-keypair)))
                     (cred-said . ,cred-said)
                     (holder    . ,holder-aid)
                     ,@(if cred `((cred . ,cred)) '())))))))))))
