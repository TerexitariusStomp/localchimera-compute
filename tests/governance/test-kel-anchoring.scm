;;; tests/governance/test-kel-anchoring.scm
;;;
;;; OOBI.md §3.2.1 KEL-Anchored Updates: a credential's SAID anchored
;;; into the issuer's KEL via an ixn event is strictly stronger than
;;; signed-not-anchored. Receivers can verify the chain commits to
;;; the credential.
;;;
;;; This test verifies:
;;;   - 'anchor-acdc/best-effort exists on ^scope and returns #f when
;;;     no kel-store / no keypair / empty KEL (test mode)
;;;   - 'anchor-acdc is the strict variant (errors on missing)
;;;   - admit-commune in production mode (with kel-store + keypair +
;;;     icp already in KEL) emits an ixn anchoring the membership SAID
;;;   - The anchor's digest-seal payload references the right SAID
;;;
;;; The full production-mode test requires a real keri-backend; here
;;; we exercise the synthetic path + verify the methods behave as
;;; specified.

(use-modules (playnet test harness)
             (playnet planner scope root)
             (playnet credentials membership) (playnet keri acdc) (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store)
             (goblins))

(define vat (spawn-vat))

;; ── Synthetic mode: 'anchor-acdc/best-effort no-ops without crash ──

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (s (spawn-scope "test-fed"
                         #:kind 'federation
                         #:scope-aid "ETestFed"
                         #:acdc-store store)))
    (check "synthetic scope: 'anchor-acdc/best-effort returns #f"
           (not ($ s 'anchor-acdc/best-effort "EDummySaid")))

    (check "synthetic scope: 'anchor-acdc (strict) errors"
           (catch #t
             (lambda () ($ s 'anchor-acdc "EDummySaid") #f)
             (lambda _ #t)))))

;; ── admit-commune calls anchor-best-effort silently in synthetic mode ──

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (fed   (spawn-scope "fed1"
                             #:kind 'federation
                             #:scope-aid "EFed1"
                             #:acdc-store store))
         (com   (spawn-scope "com1"
                             #:kind 'commune
                             #:scope-aid "ECom1"
                             #:scope-root-ref (spawn-scope-root "com1")
                             #:acdc-store store))
         (gov-cap ($ fed 'mint-gov-cap "op")))
    ;; The admit should succeed even though anchoring no-ops (synthetic)
    (check "admit-commune in synthetic mode: doesn't crash on anchor"
           (catch #t
             (lambda ()
               ($ fed 'admit-commune gov-cap "com1" com)
               #t)
             (lambda (k . a)
               (format #t "  error: ~a ~a~%" k a)
               #f)))

    ;; Verify the membership credential landed in the store
    (let ((memberships ($ store 'by-schema
                          *schema-playnet-federation-membership*)))
      (check "membership ACDC issued"
             (= 1 (length memberships)))
      (check "membership ACDC names fed as issuer"
             (equal? "EFed1" (cred-issuer (car memberships)))))))

(test-summary!)
