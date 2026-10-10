;;; module/playnet/federation/conflicts.scm — the conflict methods of a scope: commitment conflicts detected and resolved.
;;;
;;; A fragment of the scope actor (playnet scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (playnet boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (playnet federation conflicts)
  #:use-module (srfi srfi-1)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials recomposition)
  #:use-module (playnet keri acdc)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet federation vows)
  #:use-module (srfi srfi-11)
  #:use-module (goblins)
  #:use-module (playnet scope actor)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (scope-conflicts-doors))

(define (scope-conflicts-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ;; ====================================================================
    ;; Conflict detection (free composition's deliberation surface)
    ;; ====================================================================

    ((detect-commitment-conflicts)
     ;; Walk member scopes' acdc-stores for overlapping commitments on the
     ;; same resource-conforms-to. Returns a vow resolving to a list of
     ;; conflict groups: ((resource-spec . (commitment-creds...)) ...)
     (let-values (((p r) (spawn-promise-and-resolver)))
       (let* ((member-list (hashmap-fold (lambda (_k v acc) (cons v acc))
                                         '() members)))
         (on-> (vow-fold-async
                 member-list
                 (lambda (mem acc)
                   (on-> (<- mem 'acdc-store)
                         (lambda (store)
                           (cond
                             ((not store) acc)
                             (else
                              (on-> (<- store 'by-schema
                                         *schema-playnet-commitment*)
                                    (lambda (creds)
                                      (append (filter (lambda (c)
                                                        (not (cred-revoked? c)))
                                                      creds)
                                              acc))))))))
                 '())
               (lambda (all-commitments)
                 ;; Group by resource-conforms-to
                 (let ((groups (hashmap)))
                   (for-each
                     (lambda (cred)
                       (let ((res (cred-claim cred 'resource-conforms-to)))
                         (when res
                           (let ((existing (hashmap-ref groups res '())))
                             (set! groups (hashmap-set groups res
                                                       (cons cred existing)))))))
                     all-commitments)
                   ;; Conflicts = groups with >1 commitment
                   (let ((conflicts
                          (hashmap-fold
                            (lambda (res creds acc)
                              (if (> (length creds) 1)
                                  (cons (cons res creds) acc)
                                  acc))
                            '() groups)))
                     (<-np r 'fulfill conflicts)))))
         p)))

    ((resolve-conflict gov-cap resource-id conflicting-saids
                       prevailing-said resolution-method)
     ;; Record a resolution decision as ACDC.
     (unless ($ gov-sealed? gov-cap)
       (error "resolve-conflict requires gov-authority" name))
     (when acdc-store
       ($ acdc-store 'issue
          (make-conflict-resolution-credential
            scope-aid resource-id conflicting-saids
            prevailing-said resolution-method (current-time)
            #:signing-keypair keypair)))
     'ok))))
