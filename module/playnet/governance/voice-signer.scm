;;; voice-signer.scm — per-person signing capability for ballots and expressions
;;;
;;; A ^voice-signer binds a KERI AID to a signing function. The signing
;;; function produces an auth-proof for each stance:
;;;
;;;   - Sealer mode (tests): auth-proof is a Goblins sealed blob
;;;   - KERI mode (production): auth-proof is an Ed25519 signature (CESR qb64)
;;;
;;; The ballot doesn't know which mode — it delegates to a verifier.
;;;
;;; For ballot casting, the voice-signer's `stance` method returns:
;;;   (cleartext . auth-proof)
;;; where cleartext is:
;;;   (list 'stance proposal-id position id keri-aid)
;;;
;;; Named ^voice-signer (not ^voice) to distinguish from voice-share,
;;; the labour-proportional weight used in tallying.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.


(define-module (playnet governance voice-signer)
  #:use-module (playnet org endorsement)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^voice-signer spawn-voice-signer spawn-keri-voice-signer voice-signer-env))

(define-actor (^voice-signer bcom id keri-aid sign-fn)
  ;; id:        the holder's stable identifier (string). Voice-signer
  ;;            rides on labor, not citizenship — `id` is just "who signs."
  ;; keri-aid:  qb64 AID string ("E..." or "D..."); bound at spawn
  ;; sign-fn:   (lambda (cleartext) → auth-proof)

  ;; sign-fn is a closure (a sealer-endorse thunk in test mode, a KERI
  ;; Ed25519 signer in production) — Goblins' portrait serializer has no
  ;; case for procedures, so including it in the portrait would crash any
  ;; real portrait-take the moment it reached this actor. Exclude it and
  ;; require a caller to re-supply it via 'rewire-sign-fn! after restore,
  ;; same shape as ^wallet-policy's rewire-credential-check.
  #:portrait
  (lambda () (list id keri-aid))

  #:version 5

  #:restore
  (lambda (version . args)
    (case version
      ((5)
       (apply spawn ^voice-signer
              (append args (list (lambda (_)
                                    (error "^voice-signer: sign-fn not yet rewired after restore — call 'rewire-sign-fn! first"))))))
      (else (error "Unknown ^voice-signer version" version))))

  (methods

    ((stance proposal-id position)
     (let ((cleartext (list 'stance proposal-id position id keri-aid)))
       (cons cleartext (sign-fn cleartext))))

    ((stance-expression domain expression-id distribution)
     (let ((cleartext (list 'expression domain expression-id distribution
                            id keri-aid)))
       (cons cleartext (sign-fn cleartext))))

    ((id)       id)
    ((keri-aid) keri-aid)

    ((rewire-sign-fn! new-sign-fn)
     "Re-supply the signing closure lost on restore (see #:portrait)."
     (bcom (^voice-signer bcom id keri-aid new-sign-fn)))))


(define (spawn-voice-signer id keri-aid)
  "Spawn a voice-signer with sealer-based signing (test mode).
   Returns (values voice-signer-actor sealed?-actor)."
  (call-with-values
    (lambda () (make-endorsement-authority))
    (lambda (seal _unseal sealed?)
      (values (spawn ^voice-signer id keri-aid
                     (lambda (ct) (endorse ct seal)))
              sealed?))))

(define (spawn-keri-voice-signer id keri-aid sign-fn)
  "Spawn a voice-signer with KERI Ed25519 signing (production mode).
   sign-fn: (lambda (cleartext) → signature-qb64-string).
   Returns just the voice-signer actor (no sealed?-actor — verification
   uses keri-verify-signature instead)."
  (spawn ^voice-signer id keri-aid sign-fn))


(define voice-signer-env
  (make-persistence-env
    `((((playnet governance) ^voice-signer) ,^voice-signer))))
