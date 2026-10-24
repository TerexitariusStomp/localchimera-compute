;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/keri/inception.scm — AID inception: this agent's controller, autonomous signers, groups
;;;
;;; Three things share this file because they all sit at the KERI/scope
;;; boundary:
;;;
;;;   1. Autonomous-signer SCOPE AID inception (governance-create-scope-aid!
;;;      and the <scope-inception> record) — the pure function every ^scope
;;;      actor's bootstrap path calls to mint its own single-controller AID.
;;;      Nothing here is shared across scopes; each scope's signing key
;;;      lives only in that scope's own actor state.
;;;
;;;   2. This agent's OWN controller identity (gateway-controller-aid-name
;;;      etc.) — the one identity every process already has via keri-boot!,
;;;      used as a local KERIA routing/signing fallback for signers that
;;;      have none of their own yet (demo/synthetic/bootstrap). A real commune
;;;      always signs with its OWN key — this file never holds cryptographic
;;;      authority over any commune's content. (The peers and parent a
;;;      deployment federates with are its own wiring: localchimera's is
;;;      (localchimera keys peers).)
;;;
;;;   3. Generic K-of-N multi-sig group AID creation (governance-create-group!)
;;;      — a pure protocol primitive over KERIA's multisig inception flow,
;;;      with no opinion on WHO the members are or WHY they're grouping.
;;;      Its live caller today is scope.scm's `merge-with`, via the
;;;      `create-group` entry of (localchimera keys keri-backend live)'s
;;;      keri-backend alist: two communes recomposing into one co-signed AID.
;;;      It does NOT touch this gateway's own controller-identity state
;;;      (§2) — creating a multi-sig group for some scope merge has nothing
;;;      to do with who THIS gateway is.
;;;
;;; This file used to ALSO frame governance-create-group! as the entry point
;;; for a separate "localchimera-governance" maintainer group AID, with its own
;;; bootstrap ceremony issuing member/supplier/planner/governor role
;;; credentials (governance-join-group!, -authorize-member!, -inception-
;;; status, -issue-role!, -revoke-role!, -has-role?/-member?/-supplier?/
;;; -planner?/-governor?, make-keri-governed-org). That ceremony never ran
;;; in production — the one place its role check mattered (the governance
;;; service's ballot-open gate) already had a founders.txt fallback that
;;; was the only branch ever satisfied, and per-scope credentialing already
;;; does what a maintainer-role credential would have done, one layer
;;; lower and without a second identity to bootstrap. Removed 2026-08-19;
;;; governance-create-group! itself stayed, because merge-with's use of it
;;; is real and unrelated to that ceremony — it was always just a generic
;;; multi-sig primitive that ONE caller happened to default its group-name
;;; to "localchimera-governance".

(define-module (localchimera keri inception)
  #:use-module ((localchimera utils host) #:select (string-contains))
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (localchimera keri bridge)
  #:use-module (localchimera keri witnesses)
  #:use-module ((localchimera keri credentials)
                #:select (acdc-registry-id acdc-create-registry))
  #:use-module ((localchimera keri signify-portable)
                #:select (build-icp sign-event
                          public-key->aid-prefix next-key-digest
                          bran->signing-keypair bran->next-keypair
                          bran->rotation-keypair
                          oobi-endpoint-replies-for-icp))
  #:use-module ((localchimera keri signify) #:select (signify-timestamp))
  #:use-module ((localchimera keri receiptor) #:select (receipt-event!))
  #:use-module ((localchimera keri crypto-primitives)
                #:select (keri-crypto-random-bytes
                          ed25519-keypair-public))
  #:use-module ((localchimera utils hex) #:select (bv->hex))
  #:use-module ((goblins) #:select ($))   ; the kel-store is an actor: ($ kel-store 'append body)
  #:use-module (rnrs bytevectors)
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module ((localchimera utils common)
                #:select (parse-csv-env for-each-catching))
  #:re-export (parse-csv-env)  ; existing callers import it from here
  #:use-module (ice-9 format)
  #:export (;; This gateway's own controller identity
            gateway-controller-init!
            gateway-controller-aid-name
            gateway-controller-aid-prefix

            ;; Autonomous-signer scope AID inception
            governance-create-scope-aid!
            ;; Result record from governance-create-scope-aid!
            <scope-inception>
            make-scope-inception
            scope-inception?
            scope-inception-aid
            scope-inception-bran
            scope-inception-keypair
            scope-inception-next-keypair
            scope-inception-signed-icp

            ;; Generic K-of-N multi-sig group AID creation (merge-with's
            ;; keri-backend 'create-group entry calls this)
            governance-create-group!))

;;; ── This gateway's controller AID ───────────────────────────────────────────
;;;
;;; The name here MUST match the literal passed to keri-boot! in
;;; server/gateway.scm — single source of truth so the two can't drift.

(define %gateway-controller-aid-name "localchimera-gateway")
(define *gateway-controller-aid-prefix* #f)   ; set after keri-boot!/connect

(define (gateway-controller-aid-name)   %gateway-controller-aid-name)
(define (gateway-controller-aid-prefix) *gateway-controller-aid-prefix*)

(define* (gateway-controller-init! #:key
                                    (aid-name %gateway-controller-aid-name)
                                    (registry-name "localchimera-credentials"))
  "Resolve this gateway's own controller AID and ensure its credential
   registry exists. Call at gateway startup after keri-boot!/keri-connect!.
   Returns the controller's AID prefix, or #f if not yet resolvable.

   keri-boot! establishes the CONTROLLER (the /boot agent identity) but
   does not itself register a queryable /identifiers/{name} entry — that's
   a separate KERI concept (a Signify-managed AID under the controller,
   created via POST /identifiers). keri-create-aid is idempotent (a second
   call returns the existing state instead of erroring), so calling it
   here on every boot is the register-or-fetch this needs, not a ceremony.
   Its own return value is an unresolved operation shape, not the AID
   state — keri-get-aid right after is what reliably has \"prefix\"."
  (catch #t
    (lambda ()
      (keri-create-aid aid-name)
      (let* ((aid-state (keri-get-aid aid-name))
             (prefix    (assoc-ref aid-state "prefix")))
        (set! *gateway-controller-aid-prefix* prefix)
        ;; acdc-create-registry already logs + swallows "already in use"
        ;; itself; this catch is only for anything ELSE it re-throws, and
        ;; unlike its own silent callers elsewhere, logs before swallowing —
        ;; a registry failure here just means the KERIA-backed tier degrades
        ;; to unsigned/local-disk, not that the gateway should crash.
        (when (not (acdc-registry-id))
          (catch #t
            (lambda () (acdc-create-registry aid-name registry-name))
            (lambda (key . args)
              (format (current-error-port)
                      "[gateway-controller] registry setup failed: ~a ~a\n"
                      key args)
              #f)))
        (format (current-error-port)
                "[gateway-controller] resolved: ~a\n" prefix)
        prefix))
    (lambda (key . args)
      (format (current-error-port)
              "[gateway-controller] AID resolution failed: ~a ~a\n" key args)
      #f)))

;;; ── Autonomous-signer scope AIDs ────────────────────────────────────────────

(define-record-type <scope-inception>
  (make-scope-inception aid bran keypair next-keypair signed-icp)
  scope-inception?
  (aid          scope-inception-aid)
  (bran         scope-inception-bran)
  (keypair      scope-inception-keypair)
  (next-keypair scope-inception-next-keypair)
  (signed-icp   scope-inception-signed-icp))
;;;
;;; A scope (per docs/governance/democracy-on-keri.md §4.1) is a transferable
;;; single-controller AID whose keypair is held inside the scope's Goblins
;;; actor — voice/membership churn doesn't drive KERI rotations: the scope
;;; signs ACDCs by executing its own governance logic with a key the host
;;; operator cannot extract.

(define* (governance-create-scope-aid! #:key
                                       (bran #f)
                                       (anchors '())
                                       (witnesses '())
                                       (toad 0)
                                       (witness-oobis '())
                                       (kel-store #f)
                                       (endpoint-url #f))
  "Build a signed inception event for an autonomous-signer scope AID.

   Pure function: takes (or generates) a 32-byte BRAN and derives both
   the signing keypair and the next keypair from it via HKDF (using
   existing `bran->signing-keypair` and `bran->next-keypair`).
   Future rotations derive their keypair from the same bran via
   `bran->rotation-keypair`, so persisting the bran is sufficient to
   recover any rotation key. Builds a single-controller ICP with optional
   ANCHORS (seal alists for ratification gating per §4.3), signs the
   event, and returns a `<scope-inception>` record with fields aid,
   bran, keypair, next-keypair, signed-icp.

   The caller (typically the ^scope actor's bootstrap path) stores
   KEYPAIR and NEXT-KEYPAIR in the actor's bcom state, and persists
   BRAN via Shamir share-holders or an encrypted vault file (see
   `(localchimera keys bran-custody)`). The actor itself never holds
   the bran in bcom.

   BRAN — supply for recovery / deterministic restart (32-byte
     bytevector). When #f, fresh entropy is drawn and the returned
     record carries it for the caller to persist.
   ANCHORS — list of seal alists; see `build-icp` doc.
   WITNESSES, TOAD — passthrough to `build-icp` (the icp's b/bt).
   WITNESS-OOBIS — the witnesses' OOBI URLs, pairwise with WITNESSES.
     Required whenever WITNESSES is non-empty: a locally-built bt>0
     inception MUST ship with receipts or every resolver escrows its
     KEL and the OOBI stops verifying. Receipts are collected at mint
     time via each witness's HTTP /receipts endpoint
     ((localchimera keri receiptor)) and ride the body as
     (\"receipts\" . #(rct-streams…)) — served verbatim after the KEL.
   KEL-STORE — optional `^kel-store` actor ref. When supplied, the
     signed inception body is appended via `($ kel-store 'append body)`,
     so the KEL is durable from the moment the AID is minted.
   ENDPOINT-URL — optional public base URL the AID is reachable at
     (e.g. the gateway origin serving /oobi/{aid}). When supplied, the
     body also carries framed OKEA endpoint replies (/end/role/add +
     /loc/scheme, endorsed here with the freshly-minted keypair — the
     only moment it's in hand), which ^oobi-host-mirror forwards to the
     oobi-host so resolvers learn WHERE the AID is, not just WHO
     (OOBI §3.4; prerequisite for witness receipting)."
  (let* ((bran-bv  (or bran (keri-crypto-random-bytes 32)))
         ;; bran->* functions consume a string IKM; we hex-encode for
         ;; stable encoding-independent derivation.
         (bran-str (bv->hex bran-bv))
         (kp       (bran->signing-keypair bran-str))
         (nkp      (bran->next-keypair    bran-str))
         (kq       (public-key->aid-prefix (ed25519-keypair-public kp)))
         (nq       (next-key-digest        (ed25519-keypair-public nkp))))
    (call-with-values
      (lambda ()
        (build-icp #:keys (list kq) #:nkeys (list nq)
                   #:wits witnesses #:toad toad
                   #:anchors anchors))
      (lambda (icp-json _said icp-alist)
        (let* ((sig     (sign-event icp-json kp))
               (aid     kq)  ; transferable AID prefix is the qb64 of pubkey
               ;; The endpoint replies must reference the icp's saidified
               ;; `i` — the identifier resolvers key their KEL/location dbs
               ;; by — not the kq label the scope stack uses internally.
               (replies (and endpoint-url
                             (list->vector
                              (oobi-endpoint-replies-for-icp
                               icp-alist endpoint-url kp
                               (signify-timestamp)))))
               ;; Witnessed inception: collect receipts NOW (raises below
               ;; toad — a bt>0 icp served receipt-less is escrow-doomed).
               (receipts (and (pair? witnesses)
                              (begin
                                (unless (pair? witness-oobis)
                                  (error "governance-create-scope-aid!: witnesses without #:witness-oobis — receipts cannot be collected"))
                                (list->vector
                                 (receipt-event! icp-json (vector sig)
                                                 witness-oobis
                                                 #:toad (max toad 1))))))
               (body    `(("name" . ,(string-append "scope-" aid))
                          ("icp"  . ,icp-alist)
                          ("sigs" . ,(vector sig))
                          ,@(if replies  `(("replies"  . ,replies))  '())
                          ,@(if receipts `(("receipts" . ,receipts)) '()))))
          (when kel-store ($ kel-store 'append body))
          (make-scope-inception aid bran-bv kp nkp body))))))

;;; ── Generic multi-sig group AID creation ────────────────────────────────────

(define* (governance-create-group! member-aid-names
                                    #:key
                                    group-name
                                    (signing-threshold 2)
                                    (witnesses #f))
  "Create a KERIA-managed k-of-n multi-sig group AID. Generic protocol
   primitive — has no opinion on who the members are or why they're
   grouping. Its live caller is scope.scm's `merge-with`, via the
   `create-group` entry of the keri-backend alist ((localchimera keys keri-backend live)): two communes recomposing into one co-signed AID.
   Deliberately does NOT touch this gateway's own controller-identity
   state — creating a group AID for some scope merge has nothing to do
   with who this gateway is.

   MEMBER-AID-NAMES — local KERIA names of the k-of-n members; by
     convention the first is the initiator (the caller signs at that
     index).
   GROUP-NAME — local KERIA name for the new group AID. Required — no
     default, since there's no longer a single \"the\" group this
     creates (that was the deleted maintainer-governance ceremony's
     assumption).
   SIGNING-THRESHOLD — k (how many members must sign for group actions).
   WITNESSES — explicit list, or auto-fetched from KERIA config if #f.

   Returns the new group AID's prefix."
  (unless group-name (error "governance-create-group!: #:group-name is required"))
  (let*-values (((auto-witnesses auto-toad)
                 (if witnesses
                     (values witnesses (length witnesses))
                     (keri-get-available-witnesses))))
    (let* ((witness-eids (map (lambda (w)
                                (if (pair? w) (car w) w))
                              auto-witnesses))
           (toad         (if witnesses signing-threshold auto-toad))
           ;; Fetch each member's current state: prefix, signing key, next-key digest.
           ;; The group icp commits to all member keys ordered by member-aid-names.
           ;; KERIA returns state.k / state.n as JSON arrays — guile-json
           ;; parses them as vectors, but we go through keri-as-list so a
           ;; missing-key #f or already-list payload is handled the same.
           (member-states (map (lambda (name)
                                 (let* ((data  (keri-get-aid name))
                                        (state (assoc-ref data "state"))
                                        (ks    (keri-as-list (and state (assoc-ref state "k"))))
                                        (ns    (keri-as-list (and state (assoc-ref state "n")))))
                                   (list (assoc-ref data "prefix")
                                         (and (pair? ks) (car ks))
                                         (and (pair? ns) (car ns)))))
                               member-aid-names))
           (member-prefixes (map car member-states))
           (keys            (map cadr member-states))
           (ndigs           (map caddr member-states))
           ;; The CALLING member (initiator) signs the group icp at their index.
           ;; By convention, the first member in member-aid-names is the caller.
           (caller-name     (car member-aid-names))
           ;; Resolve witness OOBIs on our agent before inception.
           (_ (keri-share-witness-oobis! (car member-prefixes) (cdr member-prefixes)))
           ;; Log each member's OOBI (joiners resolve via their own agent).
           (_ (for-each (lambda (pre)
                          (keri-share-member-oobi! pre
                            (filter (lambda (p) (not (equal? p pre))) member-prefixes)))
                        member-prefixes))
           (op   (keri-create-group group-name caller-name
                                    member-prefixes keys ndigs
                                    #:signing-threshold signing-threshold
                                    #:rotation-threshold signing-threshold
                                    #:toad toad
                                    #:witnesses witness-eids))
           (done (keri-wait-operation op #:timeout 120))
           (prefix (assoc-ref done "prefix")))
      (format (current-error-port)
              "[multisig-group] created: ~a (threshold ~a/~a, toad ~a)\n"
              prefix signing-threshold (length member-aid-names) toad)
      prefix)))
