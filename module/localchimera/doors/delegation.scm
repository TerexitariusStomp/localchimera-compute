;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/doors/delegation.scm — the delegation doors of the governance service: a citizen's map, liquid and mandated, signed by the citizen
;;;
;;; A fragment of the governance service (localchimera doors governance): a procedure
;;; from the actor's context to the doors it serves, composed into the service by
;;; (localchimera boot governance). `with-governance-ctx` binds the actor's arguments,
;;; cells and shared helpers under their own names, so each clause reads as it did
;;; inside the actor (docs/planning/codebase-layout.md §5).

(define-module (localchimera doors delegation)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera keri first-person predicates)
  #:use-module (localchimera credentials commitments)
  #:use-module (localchimera credentials delegation)
  #:use-module (localchimera keri acdc)
  #:use-module (localchimera voice delegation-map)
  #:use-module (goblins utils hashmap)
  #:use-module ((localchimera personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (localchimera doors governance)
  #:use-module ((localchimera protocol dispatch) #:select (declared-doors))
  #:export (governance-delegation-doors))

(define (governance-delegation-doors ctx)
  (with-governance-ctx ctx

    (declared-doors governance

      ((delegation-map identity-key)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm) dm)))

      ;; The caller's federation-default delegations as DATA (for the dial's
      ;; liquid-democracy view): a list of (delegate-aid fraction mandated?).
      ;; The fraction you keep is 1 − Σ delegated.
      ((list-delegations identity-key)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (hashmap-fold
             (lambda (delegate entry acc)
               (cons (list delegate (entry-fraction entry)
                           (and (entry-mandate entry) #t))
                     acc))
             '() ($ dm 'federation-default)))))

      ;; --- Delegation writes (caller must be the AID) ---
      ((set-delegation identity-key delegate-aid fraction . rest)
       ;; rest: () for federation-default, ('scope SID) for scope override
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (cond
             ((null? rest)
              ($ dm 'delegate delegate-aid fraction))
             (else
              ($ dm 'delegate delegate-aid fraction (car rest) (cadr rest))))
           'ok)))

      ;; Client-signed delegation — the same shape as the stance path. A
      ;; delegation is the CITIZEN's assertion, so the conformant ACDC must
      ;; carry the citizen's own signature, and their key is client-side. This
      ;; pair handles LIQUID delegations; mandated ones use the mandate-spec
      ;; variant below (same protocol, credential carries a mandate spec).
      ;;
      ;;   delegation-preimage → the SAID-relevant fields of the exact
      ;;   credential we would issue. The client re-derives the SAID
      ;;   (compute-said, shared via keri/said-portable) and signs it — not
      ;;   blind-signing, since it re-derives from the claims it can inspect
      ;;   (who it delegates to, what fraction).
      ;;
      ;;   set-delegation-signed → we rebuild the same credential from the
      ;;   client's own delegate/fraction, verify the signature against the
      ;;   caller's AID, and issue it signed. The caller AID is session-bound
      ;;   and we rebuild from the client's args, so the delegation can be
      ;;   neither forged as another citizen nor silently retargeted.
      ((delegation-preimage identity-key delegate-aid fraction . rest)
       (list 'ok
             (credential-preimage-fields
              (make-delegation-credential
               #:issuer-aid identity-key
               #:holder-aid delegate-aid
               #:franchise (if (and (pair? rest) (eq? (car rest) 'scope))
                               (list 'scope (cadr rest))
                               'federation)
               #:fraction fraction
               #:mandate-spec #f))))

      ((set-delegation-signed identity-key delegate-aid fraction signature . rest)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (catch #t
             (lambda ()
               (let ((cred (make-delegation-credential
                            #:issuer-aid identity-key
                            #:holder-aid delegate-aid
                            #:franchise (if (and (pair? rest) (eq? (car rest) 'scope))
                                            (list 'scope (cadr rest))
                                            'federation)
                            #:fraction fraction
                            #:mandate-spec #f)))
                 (cond
                   ((not (client-signature-ok? cred identity-key signature))
                    (list 'error "delegation signature does not verify against caller AID"))
                   (else
                    (if (null? rest)
                        ($ dm 'delegate-signed delegate-aid fraction signature)
                        ($ dm 'delegate-signed delegate-aid fraction signature
                           (car rest) (cadr rest)))
                    'ok))))
             (lambda (key . args)
               (list 'error (format #f "set-delegation-signed failed: ~a ~a" key args)))))))

      ;; Mandated delegation — the same client-signing shape as liquid, but the
      ;; credential carries a mandate SPEC (a data expression like
      ;; '(equal-position yes)), never a predicate closure. A closure can't cross
      ;; the wire and can't be signed; the spec can. The client re-derives the
      ;; SAID over the credential-with-mandate-spec and signs it; we rebuild,
      ;; verify against the caller AID, then compile the spec into the live
      ;; predicate via `(mandate spec)` (which registers spec↔predicate so the
      ;; issued ACDC's SAID matches what the client signed).
      ((delegation-mandated-preimage identity-key delegate-aid fraction mandate-spec . rest)
       (list 'ok
             (credential-preimage-fields
              (make-delegation-credential
               #:issuer-aid identity-key
               #:holder-aid delegate-aid
               #:franchise (if (and (pair? rest) (eq? (car rest) 'scope))
                               (list 'scope (cadr rest))
                               'federation)
               #:fraction fraction
               #:mandate-spec mandate-spec))))

      ((set-delegation-mandated-signed identity-key delegate-aid fraction mandate-spec signature . rest)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (catch #t
             (lambda ()
               (let ((cred (make-delegation-credential
                            #:issuer-aid identity-key
                            #:holder-aid delegate-aid
                            #:franchise (if (and (pair? rest) (eq? (car rest) 'scope))
                                            (list 'scope (cadr rest))
                                            'federation)
                            #:fraction fraction
                            #:mandate-spec mandate-spec))
                     (pred (mandate mandate-spec)))
                 (cond
                   ((not pred)
                    (list 'error (format #f "unrecognized mandate spec: ~s" mandate-spec)))
                   ((not (client-signature-ok? cred identity-key signature))
                    (list 'error "mandated delegation signature does not verify against caller AID"))
                   (else
                    (if (null? rest)
                        ($ dm 'delegate-mandated-signed delegate-aid fraction pred signature)
                        ($ dm 'delegate-mandated-signed delegate-aid fraction pred signature
                           (car rest) (cadr rest)))
                    'ok))))
             (lambda (key . args)
               (list 'error (format #f "set-delegation-mandated-signed failed: ~a ~a" key args)))))))

      ((revoke-delegation identity-key delegate-aid . rest)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (cond
             ((null? rest) ($ dm 'revoke delegate-aid))
             (else ($ dm 'revoke delegate-aid (car rest) (cadr rest))))
           'ok))))))
