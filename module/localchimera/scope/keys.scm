;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/scope/keys.scm — the KERI methods of a scope: sign, anchor into the key event log, rotate, the backend and lineage setters.
;;;
;;; A fragment of the scope actor (localchimera scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (localchimera boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (localchimera scope keys)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera keri key-state) #:select (state-sn state-said rotation-count))
  #:use-module (localchimera keri signify-portable)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera keri citizen-sig)
  #:use-module (localchimera keys kel-store)
  #:use-module (goblins)
  #:use-module (localchimera scope actor)
  #:use-module ((localchimera protocol dispatch) #:select (declared-doors))
  #:export (scope-keys-doors))

(define (scope-keys-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ;; --- Autonomous-signer signing surface (democracy-on-keri.md §4.1) ---
    ;;
    ;; The scope's keypair lives only in this actor's bcom state and is
    ;; never exported by any method. Callers ask the scope to sign a SAID
    ;; (or a credential's SAID); the scope produces a CESR-qb64 signature
    ;; using its own keys. The legitimacy of the signature is "the scope's
    ;; methods executed and produced it," not "this quorum signed."
    ((sign-said said-string)
     (unless keypair
       (error "scope has no keypair (synthetic mode)" name))
     (sign-said said-string keypair))

    ;; --- §4.6: anchor an ACDC SAID into the scope's KEL ---
    ;;
    ;; Builds a signed interaction (ixn) event with one digest-seal
    ;; pointing at TARGET-SAID, appends it to the kel-store. Witnesses
    ;; receive the new event via the existing async-broadcast path.
    ;; Returns the SAID of the new ixn event.
    ;;
    ;; Used by ballot-open and tally-close to commit ballot ACDCs into
    ;; the scope's KEL chain so a verifier walking the chain sees the
    ;; ballots in cryptographic order, not just the acdc-store's
    ;; unordered set.
    ((anchor-acdc target-said)
     ;; Strict-mode anchor: errors if keypair or kel-store are missing.
     ;; Use 'anchor-acdc/best-effort for the silent-skip variant.
     (unless keypair
       (error "scope has no keypair (synthetic mode)" name))
     (unless kel-store
       (error "scope has no kel-store" name))
     (do-anchor-acdc-into-kel! kel-store scope-aid keypair target-said))

    ((anchor-acdc/best-effort target-said)
     ;; OOBI.md §3.2.1 KEL-Anchored Updates pattern. Called after every
     ;; credential issuance so receivers can verify "issuer's KEL
     ;; commits to this credential's SAID at sequence N" — strictly
     ;; stronger than signed-not-anchored (§3.2.2). When the scope is
     ;; synthetic (no keypair) or has no kel-store (test mode, in-memory
     ;; scope), silently returns #f. Production scopes always have both.
     (cond
      ((and keypair kel-store (positive? ($ kel-store 'count)))
       (do-anchor-acdc-into-kel! kel-store scope-aid keypair target-said))
      (else #f)))

    ;; --- Key rotation ---
    ;; Rotate to the pre-committed next-keypair, derive a fresh
    ;; next-keypair, and append a signed rot event to the kel-store. The
    ;; previous keypair becomes unrecoverable from outside the actor.
    ;; rest-args carries optional #:anchors — a list of seal alists
    ;; ((d . SAID) (s . schema) ...) folded into the rot event's `a`
    ;; block per KERI §2 (anchored seals). UC's curator uses this to
    ;; anchor a digest of the member-set on every rotation, giving
    ;; observers a verifiable trail of who-was-in-UC-when without
    ;; bloating the KEL with the full membership.
    ((rotate-keys . rest-args)
     (unless keypair
       (error "scope has no keypair (synthetic mode)" name))
     ;; A real rot event chains to the prior KEL event's own SAID (icp, or
     ;; the last rot) — spawn-scope's own contract is that a real KEYPAIR
     ;; always comes with a KEL-STORE (either supplied or minted alongside
     ;; it at inception), so this is an invariant violation, not a mode
     ;; this method degrades gracefully for.
     (unless kel-store
       (error "scope has a keypair but no kel-store — cannot rotate without a KEL to chain from" name))
     (let* ((anchors    (let loop ((r rest-args))
                          (cond
                           ((null? r) '())
                           ((eq? (car r) #:anchors) (cadr r))
                           (else (loop (cddr r))))))
            (new-kp     next-keypair)
            (next-seq   ($ kel-store 'count))
            ;; the key this rotation commits to as the next: derived from the bran at
            ;; the index after the one it reveals, when the scope's spawner registered
            ;; how, so a restart finds it again; fresh entropy otherwise, which is
            ;; only in this actor's state until the next rotation
            (rotations  (rotation-count ($ kel-store 'all)))
            (derive     (hash-ref %rotation-keypair-fns scope-aid #f))
            (new-nkp    (if derive
                            (derive (+ rotations 2))
                            (keri-identity-keypair (make-keri-identity))))
            (prior-said (let ((latest ($ kel-store 'latest)))
                          (or (and latest (kel-event-said latest))
                              (error "rotate-keys: kel-store has no prior event to rotate from" scope-aid))))
            (kkey       (public-key->aid-prefix (ed25519-keypair-public new-kp)))
            (nkey       (next-key-digest (ed25519-keypair-public new-nkp))))
       (call-with-values
         (lambda ()
           (build-rot (kel-identifier kel-store scope-aid) prior-said
                      #:keys (list kkey) #:nkeys (list nkey)
                      #:sn next-seq #:anchors anchors))
         (lambda (rot-json _said rot-alist)
           (let* ((sig       (sign-event rot-json new-kp))
                  (rot-event (list (cons "name" (string-append "scope-" scope-aid))
                                   (cons "rot"  rot-alist)
                                   (cons "sigs" (vector sig)))))
             ($ kel-store 'append rot-event)
             (bcom (rebuild #:keypair new-kp #:next-keypair new-nkp)))))))

    ((set-keri-backend backend)
     ;; Late-bind the KERI backend (alist of create-scope-aid / create-group /
     ;; rotate-keys / create-aid).
     (bcom (rebuild #:keri-backend backend)))

    ((keri-backend) keri-backend)

    ((set-lineage new-lineage)
     ;; Late-bind lineage (used by recover-lineage from recomposition ACDCs).
     (bcom (rebuild #:lineage new-lineage))))))
