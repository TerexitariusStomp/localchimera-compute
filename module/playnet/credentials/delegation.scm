;;; credentials/delegation.scm — the delegation credential: a franchise handed from one person to another.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials delegation)
  #:use-module (playnet keri acdc)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet credentials commitments) #:select (mandate))
  #:export (*schema-playnet-delegation*
            make-delegation-credential))
;; =========================================================================
;; Schema identifiers (stable strings)
;; =========================================================================

(define *schema-playnet-delegation*             "playnet-delegation/v1")



;; =========================================================================
;; Schema-specific constructors
;;
;; TWO DISCIPLINES every constructor here lives under, both SAID-load-
;; bearing (a SAID commits to the exact claims alist — #f entries
;; included, key order excluded; said-portable.scm):
;;
;;   1. EMISSION IS FROZEN. Most constructors emit every claim
;;      unconditionally, #f values included. Changing any existing
;;      field's emission (e.g. "cleaning up" #f fields to
;;      emit-when-set) silently re-SAIDs every credential ever minted
;;      by that constructor — durable stores then hold the old SAID, a
;;      re-mint gets a new one, and issue-idempotent duplicates instead
;;      of deduping. NEW fields are the one safe extension: append-only,
;;      emitted ONLY when set, so every prior credential keeps its SAID
;;      (the custody-attestation `kind` claim set the pattern;
;;      commitment's `resource-inventoried-as`/`triggered-by` follow it).
;;
;;   2. `(iso-utc-now)` DEFAULTS DEFEAT IDEMPOTENT RE-MINTING. Several
;;      constructors default a SAID-material timestamp to now — every
;;      call with the default is a fresh SAID, so "re-attesting the
;;      same fact" duplicates rather than dedups. A caller re-minting
;;      an existing fact MUST pass the fact's own timestamp explicitly
;;      (as observation/credentials' attest-* and cast-signed already do).
;; =========================================================================

(define* (make-delegation-credential issuer-aid holder-aid franchise
                                     fraction mandate-spec
                                     #:key (mandate-text #f) (at #f))
  "Delegation: issuer (citizen) authorizes holder (delegate) to receive
   FRACTION of issuer's voice in FRANCHISE, optionally constrained by
   MANDATE-SPEC.

   franchise: 'federation OR (list 'scope SCOPE-ID-STRING)
   fraction:  rational/real in (0, 1]
   mandate-spec: #f (liquid) OR a spec — see compile-mandate-spec.
   mandate-text: optional human-readable gloss explaining the mandate
                 in plain language. Per democracy-on-keri.md §4.4: the
                 machine predicate (`mandate-spec`) drives tally-time
                 enforcement; the text travels alongside in the same
                 ACDC's claims so a recipient or auditor reading the
                 credential sees both forms — closer to the spirit of
                 ACDC's rule section + `l` (Legal Language) field
                 without yet introducing a separate rule block."
  (make-credential *schema-playnet-delegation*
                   issuer-aid
                   holder-aid
                   ;; AT (append-only, emit-when-set — SAID-stable for every
                   ;; delegation minted before it existed): the write's own
                   ;; timestamp. Without it the SAID was fully determined by
                   ;; (delegator, delegate, franchise, fraction, mandate), so
                   ;; RETURNING to a previously-used fraction rebuilt a SAID
                   ;; the supersede path had already revoked — the issue
                   ;; crashed the whole delegation write, and recovery's
                   ;; replay (non-revoked only) would have dropped the
                   ;; restored state even if it hadn't.
                   (let ((base (list (cons 'franchise    franchise)
                                     (cons 'fraction     fraction)
                                     (cons 'mandate      mandate-spec)
                                     (cons 'mandate-text mandate-text))))
                     (if at (append base (list (cons 'at at))) base))))
