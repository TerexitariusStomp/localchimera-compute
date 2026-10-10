;;; module/playnet/identity/recovery.scm — the personhood audit
;;;
;;; What a scope can say of its personhood corpus from the credentials
;;; alone: the live PHCs of an ecosystem and the VRCs that vouch for them,
;;; each VRC read for a signature (verified at its own time —
;;; keri/first-person/predicates.scm cred-signature-valid?), a live issuer PHC and
;;; an I2I edge that holds. Pure: it never mutates the store; callers decide
;;; whether to revoke. Moved from governance/recovery.scm, which re-exports
;;; it (identity centralization, step 6).

(define-module (playnet identity recovery)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet governance credentials)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet governance acdc-store)
  #:export (recover-personhood-state))

(define (recover-personhood-state acdc-store ecosystem-aid)
  "Audit ECOSYSTEM-AID's personhood corpus. Returns alist:
     ((phc-count . N)
      (vrc-count . M)
      (live-triangles . list-of-(a . b))
      (issues . list-of-(symbol . SAID)))
   Issue symbols:
     - 'unsigned-vrc      — VRC has no Ed25519 signature
     - 'invalid-vrc-sig   — sig doesn't verify against issuer AID
     - 'orphan-vrc        — issuer-phc edge doesn't resolve to a live PHC
     - 'broken-i2i        — issuer-phc edge fails I2I
   Pure: never mutates the store; callers decide whether to revoke."
  (define (vrc-issue vrc)
    (let* ((edge     (cred-edge vrc 'issuer-phc))
           (target-c (and edge ($ acdc-store 'get (edge-target edge)))))
      (cond
        ((not (cred-signature vrc))                'unsigned-vrc)
        ((not (cred-signature-valid? vrc))         'invalid-vrc-sig)
        ((or (not target-c) (not (phc-live? target-c))) 'orphan-vrc)
        ((not (edge-i2i-holds? edge vrc target-c)) 'broken-i2i)
        (else                                      #f))))

  (let* ((phcs (phcs-in-ecosystem acdc-store ecosystem-aid))
         (vrcs (filter (lambda (c) (not (cred-revoked? c)))
                       ($ acdc-store 'by-schema
                          *schema-playnet-relationship*)))
         (issues
           (filter-map
             (lambda (v)
               (let ((sym (vrc-issue v)))
                 (and sym (cons sym (cred-said v)))))
             vrcs))
         (triangles
           (append-map
             (lambda (a)
               (filter-map
                 (lambda (b)
                   (and (string<? (cred-holder a) (cred-holder b))
                        (trust-triangle-holds? acdc-store
                                               (cred-holder a)
                                               (cred-holder b)
                                               ecosystem-aid)
                        (cons (cred-holder a) (cred-holder b))))
                 phcs))
             phcs)))
    `((phc-count      . ,(length phcs))
      (vrc-count      . ,(length vrcs))
      (live-triangles . ,triangles)
      (issues         . ,issues))))
