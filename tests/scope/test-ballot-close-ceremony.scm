;;; test-ballot-close-ceremony.scm — closing a ballot takes k signatures,
;;; never one.
;;;
;;; close-ballot alone (gov-cap-gated) lets any single cap holder close a
;;; live ballot unilaterally. open-close-ceremony wraps the SAME
;;; ^attestation-ceremony k-of-n co-signing enrollment and witnessed
;;; work-events already use: opening is procedural (gov-cap, low-stakes,
;;; the same as proposing at all), but the close itself — issue! — only
;;; fires once THRESHOLD-K distinct recognised members have each signed
;;; the ceremony's own statement and someone calls 'finalize.

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet boot scope) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said))
             (goblins) (goblins vat) (goblins utils hashmap))

(define vat (spawn-vat))

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (eco-id (make-keri-identity))
         (eco-aid (keri-identity-aid eco-id))
         (root (spawn-scope-root "Commune"))
         (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                             #:scope-aid eco-aid #:keypair (keri-identity-keypair eco-id)
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (alice (make-keri-identity)) (alice-aid (keri-identity-aid alice))
         (bob   (make-keri-identity)) (bob-aid   (keri-identity-aid bob))
         (stranger (make-keri-identity)) (stranger-aid (keri-identity-aid stranger)))
    ;; Alice and Bob are recognised persons of this commune; the stranger
    ;; is not.
    ($ store 'issue (make-personhood-credential #:ecosystem-aid eco-aid
                                                #:holder-aid alice-aid
                                                #:enrolled-at "2026-01-01T00:00:00Z"))
    ($ store 'issue (make-personhood-credential #:ecosystem-aid eco-aid
                                                #:holder-aid bob-aid
                                                #:enrolled-at "2026-01-01T00:00:00Z"))

    (let* ((ballot ($ scope 'open-ballot-for-scope gov "prop-1" "test proposal"
                     (hashmap) (hashmap)))
           (ceremony ($ scope 'open-close-ceremony gov "prop-1" 2))
           (statement ($ ceremony 'statement-said)))
      (check-pred "ballot starts open" (eq? 'open ($ ballot 'status)))
      (check-pred "one signature is not enough to finalize"
                  (begin
                    ($ ceremony 'attest alice-aid (sign-said statement (keri-identity-keypair alice)))
                    (catch #t (lambda () ($ ceremony 'finalize) #f) (lambda _ #t))))
      (check-pred "ballot still open after one signature"
                  (eq? 'open ($ ballot 'status)))
      (check-pred "a stranger with no PHC from this commune cannot co-sign"
                  (catch #t
                    (lambda () ($ ceremony 'attest stranger-aid
                                  (sign-said statement (keri-identity-keypair stranger)))
                               #f)
                    (lambda _ #t)))
      ($ ceremony 'attest bob-aid (sign-said statement (keri-identity-keypair bob)))
      ($ ceremony 'finalize)
      (check-pred "ballot closed once threshold-k eligible signatures landed and finalize ran"
                  (eq? 'closed ($ ballot 'status))))

    ;; A second ballot, closed the ORDINARY (single gov-cap) way, still
    ;; works unchanged — the ceremony is an alternative, not a replacement.
    (let ((ballot2 ($ scope 'open-ballot-for-scope gov "prop-2" "test proposal 2"
                     (hashmap) (hashmap))))
      ($ scope 'close-ballot gov "prop-2")
      (check-pred "close-ballot alone still works, unchanged"
                  (eq? 'closed ($ ballot2 'status))))))

(display "\n")
(test-summary!)
