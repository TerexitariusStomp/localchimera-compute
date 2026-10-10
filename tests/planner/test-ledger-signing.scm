;;; test-ledger-signing.scm — the ledger's records carry a signature that binds
;;;
;;; install-credentialing! takes a #:signer, and the records the ledger mints
;;; under that scope's own AID are provenance-signed by it: the signature says
;;; "this scope recorded this occurrence". The invariant has two halves, and
;;; the second is what gives the first its meaning:
;;;
;;;   1. a record the scope ISSUES carries a signature that VERIFIES against
;;;      the issuer AID — it binds; and
;;;   2. a record issued under another party's AID carries none.
;;;
;;; A signature that fails to bind is not a weaker attestation, it is a broken
;;; one, and a verifier reading it learns nothing. So the issuer passed to
;;; install-credentialing! is the signing scope's own AID — this test pins
;;; that pairing rather than the bare presence of a signature field. And where
;;; the issuer is a party the scope holds no key for (an intent belongs to the
;;; provider or receiver who wants the thing), the scope leaves the record
;;; open for that party's own key, which is the client-side signing protocol's
;;; half of the same rule.
;;;
;;; The gateway wires the live meeting commune exactly this way (server/
;;; gateway.scm, "Turn ON the credential substrate"): the founding commune's
;;; restored ^scope is the signer and its AID is the issuer. Before that, the
;;; ledger issued every work / claim / intent / commitment with signature #f.
;;;
;;; Constructs ACDCs + mints a real KERI scope ⇒ run under the canonical runner:
;;;   guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -L module tests/planner/test-ledger-signing.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet governance acdc-bridge) (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri first-person predicates))
(use-modules (playnet keys keri-backend live))
(use-modules (playnet keri signify))   ;; install crypto backend
(use-modules (goblins) (goblins vat) (srfi srfi-1))

(define vat (spawn-vat))

(with-vat vat
  (let* ((scope (spawn-scope "Signing Commune"
                             #:kind 'commune
                             #:durable? #f
                             #:keri-backend (live-keri-backend)))
         (aid   ($ scope 'scope-aid))
         (sr    (spawn-scope-root "Signing Commune"))
         (acdc  (spawn-acdc-store)))

    (check "scope holds a keypair to sign with" ($ scope 'has-keypair?))

    ;; The pairing under test: issuer AID == the scope that signs.
    (install-credentialing! sr acdc aid #:signer scope)

    (let ((obs ($ sr 'observer))
          (ps  ($ sr 'plan-store)))

      ;; A work intent, the work event that satisfies it, and an
      ;; individually-claimable draw — one of each arm of the ledger, so the
      ;; work-event / skill / intent / claim schemas all get exercised.
      ($ ps 'add-intent
         (make-intent #:id "in1" #:action 'work #:resource-conforms-to "spec:baker"
                      #:effort-quantity (make-measure 12 %effort-unit) #:provider "ada"))
      ($ obs 'record-event
         (make-economic-event #:id "ev1" #:action 'work #:resource-conforms-to "spec:baker"
                              #:provider "ada" #:effort-quantity (make-measure 12 %effort-unit)
                              #:has-point-in-time "2026-08-07T08:00:00Z" #:satisfies "in1"
                              #:in-scope-of '()))
      ($ obs 'record-event
         (make-economic-event #:id "cl1" #:action 'transfer #:resource-conforms-to "spec:bread"
           #:resource-classified-as '("individually-claimable") #:receiver "ada" #:effort-quantity (make-measure 4 %effort-unit) #:has-point-in-time "2026-08-07T09:00:00Z" #:in-scope-of '()))

      (let* ((all   ($ acdc 'all))
             ;; The ledger issues under two different issuers, and the rule
             ;; differs by which. Work / skill / claim records are the scope's
             ;; own attestation of what it witnessed, so the scope is the
             ;; issuer. An intent's issuer is the PARTY who wants the thing
             ;; (its provider or receiver) — "ada" here, not the commune.
             (own   (filter (lambda (c) (equal? (cred-issuer c) aid)) all))
             (other (remove (lambda (c) (equal? (cred-issuer c) aid)) all)))
        (check "the ledger issued credentials at all" (> (length all) 0))
        (format #t "  issued ~a credential(s): ~a under the scope's own AID, ~a under another party's~%"
                (length all) (length own) (length other))

        (check "the scope issues records of its own witnessing" (> (length own) 0))

        ;; What the fix buys: the scope's own records are signed, and the
        ;; signature verifies against the issuer AID — it binds.
        (check "every record the scope issues carries a signature"
               (every (lambda (c) (and (cred-signature c) #t)) own))
        (check "and every one of those signatures binds to the issuer AID"
               (every cred-signature-valid? own))

        ;; The other half of the same rule, and the reason this is not simply
        ;; "sign everything": a scope holds no key for "ada", so signing an
        ;; ada-issued intent would produce a signature that cannot verify
        ;; against its issuer. Forging one would be worse than leaving it
        ;; open — those are the client-side signing protocol's to sign, from
        ;; the holder's own key. So the scope must leave them alone.
        (check "records issued under another party's AID are left unsigned"
               (every (lambda (c) (not (cred-signature c))) other))

        (for-each (lambda (c)
                    (format #t "    ~a issuer=~a sig=~a binds=~a~%"
                            (cred-schema c)
                            (if (equal? (cred-issuer c) aid) 'scope 'other-party)
                            (if (cred-signature c) 'yes 'no)
                            (if (cred-signature-valid? c) 'yes 'no)))
                  all)))))

;; The negative half: with no signer the records still issue — a synthetic or
;; demo scope has no key and the ledger must not refuse to record — but they
;; issue unsigned. This is the state the live gateway was in, kept here so the
;; difference between the two wirings stays visible rather than assumed.
(with-vat vat
  (let* ((sr   (spawn-scope-root "Keyless Scope"))
         (acdc (spawn-acdc-store)))
    (install-credentialing! sr acdc "EKeyless")
    (let ((obs ($ sr 'observer)))
      ($ obs 'record-event
         (make-economic-event #:id "ev2" #:action 'work #:resource-conforms-to "spec:baker"
                              #:provider "bo" #:effort-quantity (make-measure 5 %effort-unit)
                              #:has-point-in-time "2026-08-07T10:00:00Z" #:in-scope-of '()))
      (let ((all ($ acdc 'all)))
        (check "a keyless scope still records the work" (> (length all) 0))
        (check "and those records are unsigned"
               (every (lambda (c) (not (cred-signature c))) all))))))

(display "\n")
(test-summary!)
