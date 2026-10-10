;;; test-purchase-claim.scm — reimbursement as restitution, in the VF Claim
;;; shape: the member signs their own purchase-claim (the exact twin of
;;; socialize-preimage/-signed), and the commune's OWN gov-cap mints the
;;; reciprocal debt TRIGGERED BY it (docs/valueflows examples, "Claim for
;;; income" — a past fact entitles a reciprocal, no Agreement, which VF
;;; reserves for binding reciprocal PROMISES). Funding source: a claim
;;; naming WHICH resource paid (resourceInventoriedAs) is checked exactly —
;;; a consume-granted resource is refused outright, an ungranted one clears
;;; the coarse flag; a claim naming nothing falls back to the spec-wide
;;; flag, surfaced for governance, never auto-deducted.
;;;
;;; Run: guile -L module -L tests tests/governance/test-purchase-claim.scm

(use-modules (playnet credentials commitments) (playnet keri acdc) (playnet governance debts) (playnet boot scope) (playnet governance service) (playnet governance socialization) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet scope root) (srfi srfi-1) (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said verify-said-signature))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (pre-ar pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema)
                                   (ar 'claims) (or (ar 'edges) '())))
(define FUTURE "2099-12-31T00:00:00Z")

(display "\n── purchase-claim: client-signed, the reimbursement trigger ──\n")
(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (skp (keri-identity-keypair sid))
         (commune-aid (keri-identity-aid sid))
         (alice-id (make-keri-identity)) (alice-kp (keri-identity-keypair alice-id))
         (alice (keri-identity-aid alice-id))
         (eve (make-keri-identity)) (eve-kp (keri-identity-keypair eve))
         (root (spawn-scope-root "Commune")) (store (spawn-acdc-store))
         (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                             #:scope-aid commune-aid #:keypair skp #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope))
         (by  (lambda (s) (find (lambda (c) (equal? s (cred-said c))) ($ store 'all))))
         ;; both signing legs, as the browser runs them
         (claim! (lambda (spec qty unit due res ref)
                   (let* ((pre  (cadr ($ svc 'purchase-claim-preimage alice commune-aid
                                         spec qty unit due res ref "")))
                          (said (said-of (pre-ar pre)))
                          (sig  (sign-said said alice-kp)))
                     ($ svc 'purchase-claim-signed alice commune-aid spec qty unit due res ref "" sig)
                     said)))
         (refused? (lambda (said)
                     (catch #t
                       (lambda () ($ scope 'accept-reimbursement gov said) #f)
                       (lambda _ #t)))))

    (display "\n── the member signs their own claim ──\n")
    (let* ((pre  (cadr ($ svc 'purchase-claim-preimage alice commune-aid "spec-eur" 10 "EUR" "" "" "r0" "")))
           (ar   (pre-ar pre))
           (said (said-of ar))
           (sig  (sign-said said alice-kp)))
      (check "preimage issuer = the member (session-bound caller)" (equal? (ar 'issuer) alice))
      (check "preimage holder = the commune" (equal? (ar 'holder) commune-aid))
      (check "a forged (wrong-key) signature is rejected"
             (eq? 'error (car ($ svc 'purchase-claim-signed alice commune-aid "spec-eur" 10 "EUR" "" "" "r0" ""
                                  (sign-said said eve-kp)))))
      (let ((r ($ svc 'purchase-claim-signed alice commune-aid "spec-eur" 10 "EUR" "" "" "r0" "" sig)))
        (check "the member's real signature is accepted, returns the claim's SAID"
               (and (eq? 'ok (car r)) (equal? (cadr r) said)))
        (check "the issued claim carries the MEMBER's signature, not the commune's"
               (let ((c (by said)))
                 (and c (equal? alice (cred-issuer c)) (equal? commune-aid (cred-holder c))
                      (verify-said-signature said (cred-signature c) alice)))))

      (display "\n── the commune accepts: a debt TRIGGERED BY the claim, no Agreement ──\n")
      (let* ((r (car (list ($ scope 'accept-reimbursement gov said))))
             (debt-said (car r))
             (flagged   (cadr r))
             (debt      (by debt-said)))
        (check-pred "no live purse for alice in this spec: nothing flagged" (= flagged 0))
        (check-pred "the debt is a commitment credential, commune owes alice"
                    (and (equal? *schema-playnet-commitment* (cred-schema debt))
                         (eq? 'transfer (cred-claim debt 'action))
                         (equal? commune-aid (cred-issuer debt))
                         (equal? alice (cred-holder debt))))
        (check-pred "…TRIGGERED BY alice's own signed claim — the VF Claim link IS the binding"
                    (equal? said (cred-claim debt 'triggered-by)))
        (check-pred "the debt names exactly the claimed amount — 0% interest, nothing to configure"
                    (equal? (cons 10 "EUR") (cred-claim debt 'resource-quantity)))
        (check-pred "no Agreement is minted — a past fact triggers, promises agree"
                    (not (find (lambda (c) (equal? *schema-playnet-agreement* (cred-schema c)))
                               ($ store 'all))))
        (check "settlement reads it like any other debt (governance/debts.scm, unchanged)"
               (length (open-debts store commune-aid alice)) 1)

        (display "\n── re-accepting the same claim is idempotent, not a duplicate ──\n")
        (let ((r2 ($ scope 'accept-reimbursement gov said)))
          (check "same debt SAID" (car r2) debt-said)
          (check "still exactly one open debt" (length (open-debts store commune-aid alice)) 1))))

    (display "\n── two same-shaped purchases are two claims, by ref ──\n")
    (let ((s1 (claim! "spec-flour" 5 "kg" "" "" "rcpt-1"))
          (s2 (claim! "spec-flour" 5 "kg" "" "" "rcpt-2")))
      (check-pred "distinct refs ⇒ distinct SAIDs — the second never dedupes away"
                  (not (equal? s1 s2)))
      (check "an EMPTY ref is refused — it would degrade the id to the colliding shape"
             (car ($ svc 'purchase-claim-preimage alice commune-aid "spec-flour" 5 "kg" "" "" "" ""))
             'error)

      ;; a claim carrying its purchase EVENT as triggered-by (VF
      ;; Claim.triggeredBy — record-purchase replies the event id)
      (let* ((pre  (cadr ($ svc 'purchase-claim-preimage alice commune-aid
                            "spec-flour" 2 "kg" "" "" "rcpt-3" "purchase:ev-x")))
             (tsaid (said-of (pre-ar pre)))
             (tsig  (sign-said tsaid alice-kp)))
        ($ svc 'purchase-claim-signed alice commune-aid "spec-flour" 2 "kg" "" "" "rcpt-3" "purchase:ev-x" tsig)
        (check-pred "the claim carries the purchase event as its own trigger"
                    (equal? "purchase:ev-x" (cred-claim (by tsaid) 'triggered-by))))

      (display "\n── a member cannot accept their own reimbursement claim ──\n")
      (check "alice accepting her own claim is refused"
             (eq? 'error (car ($ svc 'accept-reimbursement alice commune-aid s1))))
      (check "a stranger (governance-open today — the stated security gap) can accept it"
             (eq? 'ok (car ($ svc 'accept-reimbursement eve commune-aid s1)))))

    (display "\n── a claim naming NOTHING against a live purse: flagged, never deducted ──\n")
    (let* ((cpre  (cadr ($ svc 'socialize-preimage alice commune-aid "spec-eur" 50 FUTURE #f "" "" "" "consume" "g0")))
           (csaid (said-of (pre-ar cpre)))
           (csig  (sign-said csaid alice-kp)))
      ($ svc 'socialize-signed alice commune-aid "spec-eur" 50 FUTURE #f "" "" "" "consume" "g0" csig)
      (let* ((said (claim! "spec-eur" 12 "EUR" FUTURE "" "r-flag"))
             (r    ($ scope 'accept-reimbursement gov said))
             (debt (by (car r))))
        (check-pred "alice's live €50 purse is flagged, but the debt STILL mints in full"
                    (= (cadr r) 50))
        (check "the debt names the full €12 claimed — the flag informs, never auto-reduces"
               (car (cred-claim debt 'resource-quantity)) 12)))

    (display "\n── a claim NAMING its resource is checked exactly ──\n")
    ;; the grant names ITS resource (the refinement socialize documents), so
    ;; the precise check has an exact id to match, not just a spec
    (socialize-private-resource store alice commune-aid "spec-gold" 100
                                #:until FUTURE #:kind 'consume
                                #:resource "res-gold-purse")
    (check-pred "naming the consume-granted resource: REFUSED — socialized money owes nothing back"
                (refused? (claim! "spec-gold" 30 "g" "" "res-gold-purse" "g1")))
    (let* ((said (claim! "spec-gold" 30 "g" "" "res-gold-mine" "g2"))
           (r    ($ scope 'accept-reimbursement gov said)))
      (check-pred "naming an UNGRANTED resource clears the flag, despite the live spec-gold purse"
                  (= (cadr r) 0))
      (check-pred "…and the debt mints, carrying the claim as its trigger"
                  (equal? said (cred-claim (by (car r)) 'triggered-by))))
    ;; a SPEC-LEVEL purse (no resource named — the €50 spec-eur one above)
    ;; covers "the one such resource the owner holds" (socialize's stated
    ;; convention), so naming ANY spec-eur resource reads as spending it
    (check-pred "a named resource under a spec-level purse of that spec: refused too"
                (refused? (claim! "spec-eur" 5 "EUR" "" "res-my-eur-account" "e1")))))

(test-summary!)
