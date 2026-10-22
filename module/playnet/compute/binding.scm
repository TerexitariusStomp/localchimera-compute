;;; module/playnet/compute/binding.scm — the AccountLink ceremony (spec §1).
;;;
;;; An AccountLink says three things: WHO the machine-side signer is (a
;;; did:key), WHICH accountable identity it stands behind (the scope's grant
;;; or a member's AID — one accountable identity per bridge, named
;;; grant.subjectDid), and WHAT external account it controls (a CAIP-10, or
;;; the `keri:<aid>` form that binds a did:key to a KERI AID directly —
;;; the binding whose issuance is the AID↔did:key link event).
;;;
;;; The link is only what it is once BOTH sides have signed the same
;;; statement: the did:key countersigns (the machine side agreeing to
;;; answer for it) and the account side signs (the EOA's EIP-712/191, or
;;; the AID's own signature for the keri: form). A binding carries both
;;; signatures or it is not a binding.
;;;
;;; WHAT IS HERE:
;;;   • binding-statement — the canonical bytes both parties sign over.
;;;     Field order IS the format: didKey, scopeAid, account, purpose,
;;;     nonce, expiry — one line each, NUL-terminated, under a domain tag.
;;;   • <account-binding> — the link + both signatures + its standing
;;;     ('live, 'unlinked-by-signer, 'unlinked-by-account). Either side
;;;     unlinks, and the record keeps WHO ended it — an unlinked binding is
;;;     a fact, not an absence.
;;;   • verify-binding — injected verifiers, fail-closed: the did:key sig
;;;     and the account sig are each checked by a caller-supplied verifier
;;;     (noble-ed25519 / a KERI SAID verifier on the keri: form). Absent a
;;;     verifier the answer is 'unverifiable, never a silent pass.
;;;   • keri-account? — the "keri:<aid>" account form.
;;;
;;; Verdicts: 'ok | 'bad-signature | 'expired | 'unlinked | 'unverifiable.

(define-module (playnet compute binding)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (playnet compute settlement)
  #:export (binding-statement keri-account?
            <account-binding> make-account-binding account-binding?
            account-binding-link account-binding-signer-sig
            account-binding-account-sig account-binding-status
            binding-live? binding-unlink
            verify-binding %sig-unverified))


;;; ── the statement ───────────────────────────────────────────────────────
;;; What both signatures cover: the domain tag, then each field of the
;;; AccountLink in order, NUL-terminated — no JSON, no ambiguity, the same
;;; bytes wherever either side signs them.

(define (binding-statement link)
  (string-append
   "playnet-account-link/v1\0"
   (account-link-did-key link)   "\0"
   (account-link-scope-aid link) "\0"
   (account-link-account link)   "\0"
   (symbol->string (account-link-purpose link)) "\0"
   (account-link-nonce link)     "\0"
   (number->string (account-link-expiry link)) "\0"))

(define (keri-account? account)
  "The AID↔did:key binding is an AccountLink whose account is `keri:<aid>` —
   the link event IS the binding ACDC's issuance (spec §1)."
  (and (string? account) (string-prefix? "keri:" account)))


;;; ── the binding ─────────────────────────────────────────────────────────

(define-record-type <account-binding>
  (%make-account-binding link signer-sig account-sig status)
  account-binding?
  (link        account-binding-link)        ; <account-link>
  (signer-sig  account-binding-signer-sig)  ; string — the did:key's countersignature (qb64)
  (account-sig account-binding-account-sig) ; string — the EOA/AID signature (qb64)
  (status      account-binding-status))     ; 'live | 'unlinked-by-signer | 'unlinked-by-account

(define (make-account-binding link signer-sig account-sig)
  (%make-account-binding link signer-sig account-sig 'live))

(define* (binding-live? b #:optional (now #f))
  "Live means standing AND unexpired."
  (and (eq? (account-binding-status b) 'live)
       (account-link-live? (account-binding-link b) now)))

(define (binding-unlink b side)
  "Either side ends it — SIDE is 'signer (the did:key) or 'account (the EOA/AID)."
  (unless (memq side '(signer account))
    (error "binding-unlink: side must be signer or account" side))
  (if (eq? (account-binding-status b) 'live)
      (%make-account-binding
       (account-binding-link b)
       (account-binding-signer-sig b)
       (account-binding-account-sig b)
       (if (eq? side 'signer) 'unlinked-by-signer 'unlinked-by-account))
      b))


;;; ── verification ────────────────────────────────────────────────────────
;;; (verify-sig pubkey-or-account statement signature) → truthy | #f.
;;; Two verifiers, one per side — the did:key's is an Ed25519 check, the
;;; account side's is whatever its form needs (secp256k1 for CAIP-10, KERI
;;; for keri:). Both are injected; the default refuses to guess.

(define (%sig-unverified who statement signature)
  (error "binding: no verifier injected for this side" who))

(define* (verify-binding b #:key
                         (verify-signer %sig-unverified)
                         (verify-account %sig-unverified)
                         (now #f))
  "Verdict on both signatures and the binding's standing."
  (let ((link (account-binding-link b))
        (stmt #f))
    (cond
     ((not (eq? (account-binding-status b) 'live)) 'unlinked)
     ((not (account-link-live? link now)) 'expired)
     (else
      (set! stmt (binding-statement link))
      (catch #t
        (lambda ()
          (cond
           ((not (verify-signer (account-link-did-key link) stmt
                                (account-binding-signer-sig b)))
            'bad-signature)
           ((not (verify-account (account-link-account link) stmt
                                 (account-binding-account-sig b)))
            'bad-signature)
           (else 'ok)))
        (lambda (k . a) 'unverifiable))))))
