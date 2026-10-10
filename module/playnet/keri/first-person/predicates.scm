;;; first-person.scm — First Person layer over KERI/ACDC
;;;
;;; Two primitives from the First Person Project whitepaper, rendered as
;;; ACDC queries over ^acdc-store:
;;;
;;;   PHC (Personhood Credential) — ecosystem → unique person (vertical).
;;;   VRC (Relationship Credential) — peer ↔ peer (horizontal), mutual.
;;;
;;; Composition: the verifiable-relationship **trust triangle**. Two PHCs
;;; issued by the same ecosystem plus two mutual VRCs whose `issuer-phc-said`
;;; edge (I2I-style) points at the respective issuer's PHC. Defeats the
;;; Sybil-via-multi-VRC attack at the credential layer.
;;;
;;; This module is pure: it only *reads* the acdc-store. Issuance happens
;;; through the usual ^acdc-store 'issue path; seeding rituals live in
;;; bootstrap.scm and the scope invite/vouch methods.
;;;
;;; The verification half of the OpenVTC layer; (playnet governance) re-exports it.

(define-module (playnet keri first-person predicates)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module ((playnet keri acdc-store) #:select (non-revoked-by-schema))
  #:use-module (playnet keri citizen-sig)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (let-optional require-gov-cap! require-store! kw-ref
            *default-sponsor-fanout-cap* *default-sponsor-fanout-window*
            sponsor-recent-invites assert-sponsor-fanout! assert-signature-binds!
            cred-live-at? phc-live? phcs-by-ecosystem phc-for holds-live-phc?
            any-live-phc-for holds-any-live-phc? personhood-bootstrapped?
            ecosystem-personhood-bootstrapped? phcs-in-ecosystem
            set-root-lineage! root-lineage-closure
            aic-valid-by-root? authorized-issuer-cred issuer-chains-to-root?
            phc-issuer-authz-edge phc-chains-to-root? vrc-from-to mutual-vrcs
            vrc-issuer-phc-edge cred-signature-valid? client-signature-ok?
            cred-multisig-valid? ecosystem-chains-to-any-root? trust-triangle-holds?
            multi-ecosystem-triangle-holds?))

;; =========================================================================
;; PHC queries
;; =========================================================================

;; =========================================================================
;; Small helpers used by ^scope's FP methods
;; =========================================================================

(define-syntax let-optional
  ;; (let-optional REST-EXPR ((NAME DEFAULT) ...) BODY ...) — bind each
  ;; NAME from successive positions of REST-EXPR, falling back to
  ;; DEFAULT when the list runs out. Trailing-positional optionals
  ;; without the ladder of (if (pair? rest) (car rest) ...).
  (syntax-rules ()
    ((_ rest-expr () body ...)
     (begin body ...))
    ((_ rest-expr ((name default) more ...) body ...)
     (let* ((tail rest-expr)
            (name (if (pair? tail) (car tail) default)))
       (let-optional (if (pair? tail) (cdr tail) '()) (more ...)
         body ...)))))

(define (require-gov-cap! gov-sealed? cap op scope-name)
  (unless ($ gov-sealed? cap)
    (error (string-append op " requires gov-authority") scope-name)))

(define (require-store! store op scope-name)
  (unless store
    (error (string-append op ": scope has no acdc-store") scope-name)))

(define (kw-ref opts key . default)
  ;; (kw-ref '(foo 1 bar 2) 'bar)        => 2
  ;; (kw-ref '(foo 1) 'bar 'fallback)    => 'fallback
  ;; Keyword-style lookup over a flat opts list. Used by ^scope methods
  ;; whose signature is `(meth . opts)` to recover named options without
  ;; the boilerplate of a hand-rolled cond loop in every method body.
  (let loop ((r opts))
    (cond
     ((or (null? r) (null? (cdr r)))
      (if (pair? default) (car default) #f))
     ((eq? key (car r)) (cadr r))
     (else (loop (cddr r))))))

;; -------------------------------------------------------------------------
;; Sponsor fan-out cap (Sybil-resistance layer 1B)
;; -------------------------------------------------------------------------
;;
;; A single sponsor must not introduce arbitrarily many new PHCs in a
;; short window — that would let one corrupted sponsor flood the
;; ecosystem with Sybils. We use the indexed `sponsor-aid` claim on
;; PHCs to count recent invites in O(1), then bound by a configurable
;; cap. In a follow-up, the cap should scale with the sponsor's
;; voice-share (labor-anchored capacity); the constant default keeps
;; the change pure and self-contained.

(define *default-sponsor-fanout-cap* 5)
(define *default-sponsor-fanout-window* (* 30 24 3600))   ;; 30 days in seconds

(define (sponsor-recent-invites acdc-store ecosystem-aid sponsor-aid since)
  "PHCs in ECOSYSTEM-AID issued by SPONSOR-AID with enrolled-at ≥ SINCE.
   Walks the indexed sponsor-aid claim — O(k) in fan-out, no schema scan."
  (let ((all ($ acdc-store 'by-claim
                *schema-playnet-personhood* 'sponsor-aid sponsor-aid)))
    (filter (lambda (c)
              (and (equal? (cred-claim c 'ecosystem-aid) ecosystem-aid)
                   (let ((ts (cred-timestamp c)))
                     (and ts (>= ts since)))))
            all)))

(define (assert-sponsor-fanout! acdc-store ecosystem-aid sponsor-aid
                                cap window now)
  "Error if SPONSOR-AID has already issued ≥CAP PHCs in the last
   WINDOW seconds (counting from NOW). #f cap disables the check —
   useful for migrations or tests."
  (when (and cap (> cap 0))
    (let* ((since (- now window))
           (recent (sponsor-recent-invites acdc-store ecosystem-aid
                                            sponsor-aid since)))
      (when (>= (length recent) cap)
        (error "invite: sponsor fan-out cap reached"
               sponsor-aid (length recent) cap window)))))


(define (assert-signature-binds! cred expected-aid op)
  "Verify CRED's attached signature actually binds to EXPECTED-AID;
   error otherwise. Used after issuing a credential with a keypair to
   enforce proof-of-possession at the boundary."
  (unless (cred-signature-valid? cred)
    (error (string-append op ": signature does not verify against expected AID")
           expected-aid)))


(define (cred-live-at? c when)
  "Liveness at WHEN — THE law, cred-live? (playnet keri acdc): revoked, `active` suspension, and the
   valid-until/expires-at window all read in the one place."
  (cred-live? c when))

(define (phc-live? c)
  "A PHC is live iff cred-live-at? `now` says so."
  (cred-live-at? c (instant->unix (clock-now))))

(define (phcs-by-ecosystem acdc-store ecosystem-aid)
  ($ acdc-store 'by-claim
     *schema-playnet-personhood* 'ecosystem-aid ecosystem-aid))

(define (phc-for acdc-store ecosystem-aid holder-aid)
  "Return the live PHC for HOLDER-AID in ECOSYSTEM-AID, or #f."
  (find (lambda (c)
          (and (phc-live? c)
               (equal? (cred-holder c) holder-aid)))
        (phcs-by-ecosystem acdc-store ecosystem-aid)))

(define (holds-live-phc? acdc-store ecosystem-aid holder-aid)
  (and (phc-for acdc-store ecosystem-aid holder-aid) #t))

;; PORTABLE personhood — a live PHC from ANY ecosystem. This is the
;; refederation-correct check: personhood travels with the person across
;; communes, so we honour any live PHC in the store rather than one tied
;; to a particular ecosystem-aid string. (Single-commune today; UC-wide
;; once stores federate — same query, larger fold.)
(define (any-live-phc-for acdc-store holder-aid)
  (and acdc-store
       (find (lambda (c) (and (phc-live? c) (equal? (cred-holder c) holder-aid)))
             ($ acdc-store 'by-schema *schema-playnet-personhood*))))
(define (holds-any-live-phc? acdc-store holder-aid)
  (and (any-live-phc-for acdc-store holder-aid) #t))

;; Has ANYONE been recognised as a person yet? Before the first live PHC,
;; the personhood gate must fail OPEN — a commune with no persons can vouch
;; no one in, so gating would deadlock the whole commune. Once bootstrapped,
;; the gate enforces normally.
(define (personhood-bootstrapped? acdc-store)
  (and acdc-store
       (find phc-live? ($ acdc-store 'by-schema *schema-playnet-personhood*))
       #t))

(define (phcs-in-ecosystem acdc-store ecosystem-aid)
  "All live PHCs issued by ECOSYSTEM-AID — the ecosystem's person registry."
  (filter phc-live? (phcs-by-ecosystem acdc-store ecosystem-aid)))

;; Has THIS ecosystem recognised anyone yet? personhood-bootstrapped? asks
;; the same question STORE-WIDE — right for a federation-wide count
;; (set-person-substrate!, fp-status: personhood is deliberately PORTABLE
;; there), wrong for a genesis act or a governance gate scoped to ONE
;; ecosystem (fp-grant, ^scope's mint-gov-cap): another commune's recognised
;; persons must never close THIS one's own bootstrap window just because
;; they share an acdc-store. Confirmed bug, not a hypothetical one: fp-grant
;; used personhood-bootstrapped? here and would permanently refuse genesis
;; for any commune added to an already-active multi-commune store, even one
;; that has recognised nobody of its own.
(define (ecosystem-personhood-bootstrapped? acdc-store ecosystem-aid)
  (and acdc-store (pair? (phcs-in-ecosystem acdc-store ecosystem-aid))))


;; =========================================================================
;; Trust-registry root (FPP "trust registry = registry AID + TEL of
;; authorized-issuer ACDCs", fpp-on-keri.md §2)
;;
;; The root — the Universal Commune's group AID — does not vouch for
;; people; it authorizes the ECOSYSTEMS that issue PHCs. An ecosystem is a
;; legitimate PHC issuer iff it holds a live Authorized-Issuer Credential
;; (AIC) issued by the root. This makes the flat `fp-trusted-issuers`
;; whitelist derivable: trust an issuer because it chains to root, not
;; because a human listed it. Portable multi-ecosystem personhood is
;; preserved — many ecosystems, one root of trust.
;; =========================================================================

;; A root AID can have a history of its own: a deployment whose root
;; recomposes (rotates into a new group AID, merges, splits) supplies the walk
;; from the current root back over its predecessor AIDs, so a blessing signed
;; before the recomposition still chains. The library's own reading is the
;; root alone; (playnet governance root-lineage) installs playnet's walk over
;; ratified scope-merger / scope-split credentials.
(define %root-lineage (lambda (acdc-store root-aid) (list root-aid)))

(define (set-root-lineage! proc)
  "Install PROC : (acdc-store root-aid) → list of AIDs that ARE this root
   across its history, current AID first."
  (set! %root-lineage proc))

(define (root-lineage-closure acdc-store root-aid)
  "ROOT-AID plus every predecessor AID the installed lineage walk names."
  (if acdc-store (%root-lineage acdc-store root-aid) (list root-aid)))

(define* (aic-valid-by-root? aic root #:key (require-signature? #t))
  "The single source of truth for 'this credential is a live root
   blessing': AIC is an authorized-issuer credential, issued by ROOT,
   currently live, and (fail-closed, default) carries the root's valid
   signature. ROOT is a single AID or a LIST of acceptable root AIDs (a
   lineage closure — see `root-lineage-closure`); the issuer must be one
   of them. The schema gate matters on the structural path — it stops an
   `issuer-authz` edge from pointing at some *other* credential root
   happened to issue the ecosystem. WHICH ecosystem is blessed (the
   holder-binding) is enforced by the caller: the registry query filters
   on holder; the structural walk uses the PHC's I2I edge."
  (and aic
       (equal? (cred-schema aic) *schema-playnet-authorized-issuer*)
       (let ((issuer (cred-issuer aic)))
         (if (pair? root) (and (member issuer root) #t) (equal? issuer root)))
       (cred-live-at? aic (instant->unix (clock-now)))
       (or (not require-signature?) (cred-signature-valid? aic))))

(define (authorized-issuer-cred acdc-store root ecosystem-aid)
  "The live Authorized-Issuer Credential blessing ECOSYSTEM-AID as a PHC
   issuer, issued by ROOT (a single AID or a lineage-closure list), or #f.
   Signature is left to the caller (via `aic-valid-by-root?`) so an
   unsigned test blessing still resolves."
  (and acdc-store
       (find (lambda (c)
               (and (equal? (cred-holder c) ecosystem-aid)
                    (aic-valid-by-root? c root #:require-signature? #f)))
             ($ acdc-store 'by-schema *schema-playnet-authorized-issuer*))))

(define* (issuer-chains-to-root? acdc-store root-aid ecosystem-aid
                                 #:key (require-signature? #t))
  "#t iff ECOSYSTEM-AID provably chains to ROOT-AID: it holds a live AIC
   issued by root (or any ratified recomposition ancestor of root — so
   trust survives the root's own merges/splits). When REQUIRE-SIGNATURE?
   (default, fail-closed) the AIC must carry the root's valid Ed25519
   signature. The root authorizing ITSELF — or any predecessor it grew
   from — is trivially rooted."
  (let ((roots (root-lineage-closure acdc-store root-aid)))
    (and (or (member ecosystem-aid roots)
             (aic-valid-by-root? (authorized-issuer-cred acdc-store roots
                                                         ecosystem-aid)
                                 roots #:require-signature? require-signature?))
         #t)))

(define (phc-issuer-authz-edge phc)
  "The PHC's `issuer-authz` edge (pointer to its ecosystem's AIC), or #f."
  (cred-edge phc 'issuer-authz))

(define* (phc-chains-to-root? acdc-store phc root-aid
                              #:key (require-signature? #t))
  "STRUCTURAL root check: walk the PHC's own `issuer-authz` edge to the
   Authorized-Issuer Credential it names, and confirm that AIC is the I2I
   target of the edge (its holder is the PHC's issuer, the ecosystem) AND
   is a live, root-signed blessing (`aic-valid-by-root?`). End-verifiable
   from the PHC alone — no store index, only SAID resolution — unlike
   `issuer-chains-to-root?`, which queries the registry by holder.

   A PHC whose issuer IS the root — or any predecessor root grew from —
   needs no edge (root is its own origin)."
  (let ((roots (root-lineage-closure acdc-store root-aid)))
    (and (or (member (cred-issuer phc) roots)
             (let* ((edge (phc-issuer-authz-edge phc))
                    (aic  (and edge (equal? (edge-operator edge) 'I2I)
                               ($ acdc-store 'get (edge-target edge)))))
               (and (edge-i2i-holds? edge phc aic)  ;; edge binds AIC.holder == PHC.issuer
                    (aic-valid-by-root? aic roots
                                        #:require-signature? require-signature?))))
         #t)))

;; =========================================================================
;; VRC queries
;; =========================================================================

(define (vrc-from-to acdc-store issuer-aid subject-aid)
  "Return the live VRC from ISSUER-AID to SUBJECT-AID, or #f.

   Returns the first match; in practice there should be at most one live
   VRC per ordered pair (newer issuances supersede older ones via
   revocation)."
  (let ((now (instant->unix (clock-now))))
    (find
      (lambda (c)
        (and (cred-live-at? c now)
             (equal? (cred-issuer c) issuer-aid)
             (equal? (cred-holder c) subject-aid)))
      ($ acdc-store 'by-schema *schema-playnet-relationship*))))

(define (mutual-vrcs acdc-store aid-a aid-b)
  "Return (vrc-a→b . vrc-b→a) if both exist and live, else #f."
  (let ((a->b (vrc-from-to acdc-store aid-a aid-b))
        (b->a (vrc-from-to acdc-store aid-b aid-a)))
    (and a->b b->a (cons a->b b->a))))


;; =========================================================================
;; Trust triangle verifier (FPP I6)
;; =========================================================================

(define (vrc-issuer-phc-edge vrc)
  "Return the `issuer-phc` edge spec on VRC, or #f."
  (cred-edge vrc 'issuer-phc))

(define (cred-signature-valid? cred)
  "Verify a credential's attached Ed25519 signature against its issuer
   AID. Returns #t when the signature is present and verifies, #f
   otherwise.

   Interpretation by caller:
   - A #t means the issuer really issued this credential.
   - A #f is ambiguous — either unsigned (legacy), digest-inconsistent,
     or tampered. A verifier that requires signed credentials must check
     `cred-signature` is non-#f before calling this.

   The digest-consistency gate is load-bearing: verifying the issuer
   signed `d` proves nothing about the content unless `d` was actually
   derived from the content (ACDC §2.5). We re-derive first, so a
   validly-signed SAID grafted onto swapped attributes is rejected here
   rather than trusted downstream.

   Verified AT THE CREDENTIAL'S OWN TIME: a key that signed as the issuer
   then — a device the issuer's root had authorized — stays the signer of
   that statement after the device is revoked, expires, or its person is
   forgotten, exactly as a rotated-away root key keeps what it signed
   (key-in-force-at). A credential without a timestamp verifies as of now."
  (let ((sig (cred-signature cred)))
    (and sig
         (cred-said-consistent? cred)
         (string? sig)
         (verify-said-signature (cred-said cred) sig (cred-issuer cred)
                                (cred-timestamp cred)))))

(define (client-signature-ok? cred caller-aid signature)
  "The single gate for the client-signing protocol: SIGNATURE is a valid Ed25519
   over CRED's SAID by CALLER-AID. The server rebuilds CRED from the client's
   echoed intent before calling this, so acceptance binds the signature to
   exactly the credential being issued — it can be neither forged as another
   party (CALLER-AID is session-bound) nor retargeted (the SAID commits to the
   claims)."
  (and (string? signature)
       (verify-said-signature (cred-said cred) signature caller-aid)))

(define (cred-multisig-valid? cred member-aids threshold)
  "Verify a credential issued by a k-of-n governance GROUP AID, whose
   `signature` is a multisig block (alist member-aid → sig-qb64), against
   the group's MEMBER-AIDS and signing THRESHOLD. Like `cred-signature-valid?`
   it gates digest-consistency first — a signature over `d` proves nothing
   unless `d` commits to the content. The member set + threshold come from
   the group's published keystate (KERIA resolves them live; a foreign
   verifier can also carry them out-of-band)."
  (let ((sig (cred-signature cred)))
    (and (pair? sig)
         (cred-said-consistent? cred)
         (verify-said-multisig (cred-said cred) sig member-aids threshold))))

(define* (ecosystem-chains-to-any-root? acdc-store root ecosystem-aid
                                        #:key (require-signature? #t))
  "ROOT is #f (no root check → #t), a single root AID, or a LIST of
   recognized root AIDs. With a list, ECOSYSTEM-AID need only chain to
   ONE — multi-root cross-recognition. Roots federating (each recognizing
   the others' authorized issuers) is the decentralization escape hatch:
   not one global root, but a set of mutually-recognized roots."
  (define (chains? r)
    (issuer-chains-to-root? acdc-store r ecosystem-aid
                            #:require-signature? require-signature?))
  (cond ((not root)    #t)
        ((pair? root)  (any chains? root))
        (else          (chains? root))))

(define* (trust-triangle-holds? acdc-store aid-a aid-b ecosystem-aid
                                #:key (require-signatures? #t) (root #f))
  "Verify the verifiable-relationship trust triangle for AID-A and AID-B
   within ECOSYSTEM-AID.

   Holds iff:
     1. A holds a live PHC issued by ECOSYSTEM-AID.
     2. B holds a live PHC issued by ECOSYSTEM-AID.
     3. VRC(A→B) carries an ACDC edge `issuer-phc` with the I2I
        operator whose target is A's PHC.
     4. VRC(B→A) carries the symmetric edge targeting B's PHC.
     5. (when ROOT is set) ECOSYSTEM-AID chains to ROOT — a #f/single-AID/
        recognized-root-set, per `ecosystem-chains-to-any-root?`. This
        confines a verified relationship to a known root's trust domain,
        so the triangle proves not just 'A and B mutually vouch in some
        ecosystem' but '…in an ecosystem the root authorized'.

   The I2I operator check (edge-i2i-holds?) rejects a forged VRC whose
   claimed issuer does not match the holder of the referenced PHC. A
   forged VRC that points at a PHC in a *different* ecosystem fails
   step 3/4 because that PHC is not what step 1/2 resolved. This is
   ACDC §8.6 applied to FPP I6 — structural, not by-convention.

   When REQUIRE-SIGNATURES? is #t (default — fail-closed), each VRC
   must carry a valid Ed25519 signature by its issuer AID
   (`cred-signature-valid?`), and the root blessing (step 5) is
   signature-checked too; this is the full no-trust-the-store
   verification a foreign verifier would perform. Tests using
   synthetic AIDs (no real keypair) must pass `#:require-signatures?
   #f` explicitly."
  (let ((phc-a (phc-for acdc-store ecosystem-aid aid-a))
        (phc-b (phc-for acdc-store ecosystem-aid aid-b)))
    (and phc-a phc-b
         (ecosystem-chains-to-any-root? acdc-store root ecosystem-aid
                                        #:require-signature? require-signatures?)
         (let ((pair (mutual-vrcs acdc-store aid-a aid-b)))
           (and pair
                (let ((vrc-ab (car pair))
                      (vrc-ba (cdr pair)))
                  (and (edge-i2i-holds? (vrc-issuer-phc-edge vrc-ab)
                                        vrc-ab phc-a)
                       (edge-i2i-holds? (vrc-issuer-phc-edge vrc-ba)
                                        vrc-ba phc-b)
                       (or (not require-signatures?)
                           (and (cred-signature-valid? vrc-ab)
                                (cred-signature-valid? vrc-ba))))))))))

;; =========================================================================
;; Cross-ecosystem amplification
;; =========================================================================
;;
;; A Sybil-resistance amplifier: require the trust triangle to hold in
;; ≥k separate ecosystems before treating two AIDs as a verified pair.
;; Federations are the natural source of multiple ecosystems — a Sybil
;; must compromise enrollment in k communities, not one. This is a thin
;; helper because all the work happens in `trust-triangle-holds?`.

(define* (multi-ecosystem-triangle-holds? acdc-store aid-a aid-b ecosystems
                                          #:key (k 1)
                                                (require-signatures? #t)
                                                (root #f))
  "Hold iff `trust-triangle-holds?` returns #t in at least K of the
   ECOSYSTEMS. Default K=1 reproduces single-ecosystem semantics; set
   K=2+ for cross-ecosystem confirmation. ROOT (if set) root-anchors
   every ecosystem counted — a Sybil must compromise K enrollments,
   each under a root-recognized ecosystem."
  (>= (count (lambda (eco)
               (trust-triangle-holds? acdc-store aid-a aid-b eco
                                      #:require-signatures? require-signatures?
                                      #:root root))
             ecosystems)
      k))
