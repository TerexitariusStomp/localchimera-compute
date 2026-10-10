;;; test-rotate-keys-signing.scm — a scope's rotate-keys produces a real,
;;; signed, chained `rot` event
;;;
;;; rotate-keys used to record a rot event with a fabricated `("d" .
;;; "EROT_...")` SAID and no signature — a placeholder so kel-store
;;; ordering worked, never a real KEL event. Phase 3c (bran-derived
;;; keypairs) removed the stated blocker; this pins the real wiring:
;;; the rot is built via build-rot against the prior (icp) event's own
;;; SAID, its `d` is a real recomputable SAID, and it's signed by the
;;; NEW signing key (the previously pre-committed next-keypair).
;;;
;;; Run: guile -L module -L tests tests/governance/test-rotate-keys-signing.scm

(use-modules (playnet test harness)
             (playnet keys kel-store) (playnet governance scope) (playnet keri citizen-sig)
             ((playnet keys kel-store)
              #:select (spawn-kel-store kel-event-said kel-event-seq))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
             ((playnet keri signify-portable)
              #:select (build-icp sign-event next-key-digest
                        ed25519-keypair-public recompute-event-said
                        scm->json-canonical))
             ((playnet keri cesr) #:select (cesr-qb64->bytes))
             ((playnet keri crypto-primitives) #:select (keri-crypto-ed25519-verify))
             ((srfi srfi-13) #:select (string-prefix?))
             (goblins) (goblins vat) (rnrs bytevectors))

(define vat (spawn-vat))

(with-vat vat
  (define kel-store (spawn-kel-store))

  ;; A real, self-signed inception — same crypto shape production takes
  ;; (module/playnet/keri/inception.scm's governance-create-scope-aid!),
  ;; built by hand here so the test has no dependency beyond build-icp/
  ;; sign-event themselves.
  (define signer  (make-keri-identity (make-bytevector 32 91)))
  (define nsigner (make-keri-identity (make-bytevector 32 92)))
  (define scope-aid (keri-identity-aid signer))
  (define kp0  (keri-identity-keypair signer))
  (define nkp0 (keri-identity-keypair nsigner))

  (call-with-values
    (lambda ()
      (build-icp #:keys (list scope-aid)
                 #:nkeys (list (next-key-digest (ed25519-keypair-public nkp0)))))
    (lambda (icp-json _icp-said icp-alist)
      (let* ((sig      (sign-event icp-json kp0))
             (icp-body (list (cons "name" (string-append "scope-" scope-aid))
                             (cons "icp"  icp-alist)
                             (cons "sigs" (vector sig)))))
        ($ kel-store 'append icp-body))))

  (check "kel-store holds the icp before any rotation" ($ kel-store 'count) 1)
  (define icp-said (kel-event-said ($ kel-store 'latest)))

  (define scope
    (spawn-scope "Rotating-Commune"
                 #:kind 'federation
                 #:scope-aid scope-aid
                 #:keypair kp0
                 #:next-keypair nkp0
                 #:kel-store kel-store))

  (display "\n── rotate-keys builds a real, chained, signed rot event ──\n")
  ($ scope 'rotate-keys)
  (check "kel-store now holds icp + rot" ($ kel-store 'count) 2)

  (define rot-body ($ kel-store 'latest))
  (check "the rot is sequence 1" (kel-event-seq rot-body) 1)
  (define rot-alist (assoc-ref rot-body "rot"))
  (define rot-said  (assoc-ref rot-alist "d"))

  (check-pred "the SAID is not the old EROT_ placeholder"
              (not (string-prefix? "EROT_" rot-said)))
  (check "the SAID is a real, recomputable digest over the event's own content"
         (recompute-event-said rot-alist) rot-said)
  (check "the rot chains to the icp's own SAID via `p`"
         (assoc-ref rot-alist "p") icp-said)

  ;; The rot's signing key (k[0]) must be the icp's pre-committed next-key:
  ;; kp0 was the icp's OWN signing key; nkp0 was pre-committed as next —
  ;; rotate-keys reveals nkp0 as the new signer.
  (define sig-qb64    (vector-ref (assoc-ref rot-body "sigs") 0))
  (define signer-pub  (ed25519-keypair-public nkp0))
  ;; scm->json-canonical on the CONCRETE rot-alist reproduces the exact
  ;; bytes sign-event signed: saidify's final string is that same
  ;; serialization with only the placeholder substring swapped for the
  ;; (same-length) real SAID — see signify-portable.scm's saidify-document.
  (check-pred "the rot event verifies against the pre-committed next-keypair"
              (keri-crypto-ed25519-verify
               signer-pub
               (string->utf8 (scm->json-canonical rot-alist))
               (cesr-qb64->bytes sig-qb64))))

(test-summary!)
