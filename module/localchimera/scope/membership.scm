;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/scope/membership.scm — the membership methods of a scope: the policies, the CCF, admission, exclusion and reinstatement.
;;;
;;; A fragment of the scope actor (localchimera scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (localchimera boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (localchimera scope membership)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera keri first-person predicates)
  #:use-module (localchimera credentials membership)
  #:use-module (localchimera keri acdc)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera utils governed-row)
  #:use-module (goblins)
  #:use-module (localchimera scope actor)
  #:use-module ((localchimera protocol dispatch) #:select (declared-doors))
  #:export (scope-membership-doors))

(define (scope-membership-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ;; The ecosystem's word on how a person is recognised: the
    ;; personhood-policy row on this commune's plan-store (enrollment-k,
    ;; witness-cap, witness-window, ceremony-ttl — first-person/personhood-policy.scm).
    ;; Gov-cap gated; a partial alist updates only the keys it names, and
    ;; every reader reads the row fresh, so the change binds the next act.
    ((set-personhood-policy! gov-cap changes)
     (require-gov-cap! gov-sealed? gov-cap "set-personhood-policy!" name)
     (unless scope-root-ref
       (error "set-personhood-policy!: scope has no economic root" name))
     (merge-governed-row! ($ scope-root-ref 'plan-store) "personhood-policy" changes
                          #:who "set-personhood-policy!" #:shape "(key . positive integer)"
                          #:valid? (lambda (kv) (and (pair? kv) (symbol? (car kv))
                                                     (integer? (cdr kv)) (>= (cdr kv) 1)))))

    ;; This scope's own word on whether its governance acts (admit-commune,
    ;; merge-with, split, rejoin-federation, accept-socialization,
    ;; accept-reimbursement) require a passing `^ballot` ratification, or
    ;; accept a bare gov-cap alone (scope/policy.scm). Same shape as
    ;; set-personhood-policy! above: gov-cap gated, partial-alist merge,
    ;; read fresh by require-ratification! on every act.
    ((set-governance-policy! gov-cap changes)
     (require-gov-cap! gov-sealed? gov-cap "set-governance-policy!" name)
     (unless scope-root-ref
       (error "set-governance-policy!: scope has no economic root" name))
     (merge-governed-row! ($ scope-root-ref 'plan-store) "governance-policy" changes
                          #:who "set-governance-policy!"))

    ((set-ccf gov-cap aid new-ccf . rest)
     (unless (eq? kind 'commune)
       (error "set-ccf: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "set-ccf requires gov-authority" name aid))
     (when (or (< new-ccf 0) (> new-ccf 1))
       (error "CCF must be in [0, 1]" aid new-ccf))
     (let ((assessed-at (if (pair? rest) (car rest) (current-time)))
           (reason      (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest) #f)))
       ;; the credential IS the factor (account.scm reads it through the
       ;; standing); the store hears that the standing moved
       (when acdc-store
         ($ acdc-store 'issue
            (make-ccf-credential #:issuer-group-aid scope-aid
                                 #:holder-aid aid
                                 #:commune name
                                 #:ccf new-ccf
                                 #:assessed-at assessed-at
                                 #:reason reason
                                 #:signing-keypair keypair)))
       (when scope-root-ref
         ($ ($ scope-root-ref 'account-store) 'standing-changed))
       'ok))

    ((exclude-member gov-cap aid . rest)
     (unless (eq? kind 'commune)
       (error "exclude-member: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "exclude-member requires gov-authority" name aid))
     (let ((excluded-at (if (pair? rest) (car rest) (current-time))))
       (when acdc-store
         ($ acdc-store 'issue
            (make-exclusion-credential #:issuer-group-aid scope-aid
                                       #:holder-aid aid
                                       #:commune name
                                       #:excluded-at excluded-at
                                       #:signing-keypair keypair)))
       (bcom (rebuild #:excluded (hashmap-set (or excluded (hashmap)) aid #t)))))

    ((reinstate-member gov-cap aid)
     (unless (eq? kind 'commune)
       (error "reinstate-member: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "reinstate-member requires gov-authority" name aid))
     ;; Revoke matching exclusion ACDCs
     (when acdc-store
       (let ((matches
               (filter
                 (lambda (c)
                   (and (not (cred-revoked? c))
                        (equal? (cred-schema c) *schema-localchimera-exclusion*)
                        (equal? (cred-holder c) aid)
                        (equal? (cred-claim c 'commune) name)))
                 ($ acdc-store 'by-issuer scope-aid))))
         (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c))) matches)))
     (bcom (rebuild #:excluded (and excluded (hashmap-remove excluded aid)))))

    ((admit-member gov-cap aid . rest)
     (unless (eq? kind 'commune)
       (error "admit-member: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "admit-member requires gov-authority" name aid))
     (let ((admitted-at (if (pair? rest) (car rest) (current-time))))
       ;; the credential IS the membership (account.scm `account-holders`)
       (when acdc-store
         ($ acdc-store 'issue
            (make-membership-credential #:issuer-group-aid scope-aid
                                        #:holder-aid aid
                                        #:commune name
                                        #:admitted-at admitted-at
                                        #:signing-keypair keypair)))
       (when scope-root-ref
         ($ ($ scope-root-ref 'account-store) 'standing-changed))
       'ok)))))
