;;; test-scope-declarations.scm — a scope's own word on the rail: span, hosting
;;; willingness, regime claim. Three self-declarations (issuer = holder = the
;;; scope) minted through the governance service by a governor, each read
;;; where it lies: the span through the consent gate (consented-span-of), the
;;; willingness as the consent a foreign span needs (live-willingness-of), the
;;; regime as what licenses a recipe's statistics (live-regime-of). And the
;;; title rail read for the span gate's standing (title-rights-of).
;;; docs/planning/federation/federation-flow-map.md §7 item 4.

(use-modules (playnet credentials custody) (playnet credentials declarations) (playnet economy recipe-standing) (playnet boot governance) (playnet economy socialization) (playnet keri acdc-store) (playnet scope root) (playnet test harness)
             ((playnet economy socialization) #:select (title-rights-of consented-span-of live-willingness-of))
             ((playnet economy recipe-standing) #:select (live-regime-of))
             ((playnet credentials custody) #:select (make-ownership-attestation-credential))
             (goblins) (srfi srfi-1))

(define GOV "EGovernor") (define OTHER "EBystander")
(define TOWN "ETownScope") (define SHOP "EWorkshopScope") (define UC "EUniversalCommune")
(define FUTURE "2099-12-31T00:00:00Z") (define PAST "2000-01-01T00:00:00Z")
(define (ok? r) (and (pair? r) (eq? 'ok (car r))))

(with-vat (spawn-vat)
  (let* ((root  (spawn-scope-root "Town"))
         (store (spawn-acdc-store))
         (svc   (spawn-governance-service (list root) ($ root 'ballot-store)
                                          #:acdc-store store
                                          #:governor? (lambda (aid) (equal? aid GOV)))))
    (display "\n── the gate: a governor speaks for the scope ──\n")
    (check "a bystander's declaration is refused"
           (let ((r ($ svc 'declare-span OTHER SHOP "lathe-1" "town-square"))) (and (pair? r) (eq? 'error (car r)))))
    (check "a governor's declaration lands, with its SAID"
           (let ((r ($ svc 'declare-span GOV SHOP "lathe-1" "town-square"))) (and (ok? r) (string? (cadr r)))))

    (display "\n── the span, read through the consent gate ──\n")
    (define (place-scope-of p) (assoc-ref `(("town-square" . ,TOWN) ("workshop-a" . ,SHOP)) p))
    (define (spec-of rid) (and (equal? rid "lathe-1") "lathe"))
    (check "a foreign place with no host consent: the span drops (refusal is the default)"
           (not (assoc-ref (consented-span-of store #:place-scope-of place-scope-of #:spec-of spec-of) "lathe-1")))
    (check "the host declares hosting willingness with a ceiling"
           (ok? ($ svc 'declare-hosting GOV TOWN "lathe" 20 FUTURE)))
    (check "live-willingness-of reads it as ((host . spec) . ceiling)"
           (equal? 20.0 (assoc-ref (live-willingness-of store) (cons TOWN "lathe"))))
    (check "with the host's consent the span reaches its place"
           (equal? "town-square"
                   (assoc-ref (consented-span-of store #:place-scope-of place-scope-of #:spec-of spec-of) "lathe-1")))
    (check "a lapsed willingness is no consent, with no further event"
           (let ((s2 (spawn-acdc-store)))
             ($ s2 'issue (make-span-declaration-credential #:scope-aid SHOP
                                                            #:resource-id "lathe-1"
                                                            #:span-place "town-square"))
             ($ s2 'issue (make-hosting-willingness-credential #:scope-aid TOWN
                                                               #:resource-spec "lathe"
                                                               #:ceiling 20.0
                                                               #:valid-until PAST))
             (not (assoc-ref (consented-span-of s2 #:place-scope-of place-scope-of #:spec-of spec-of) "lathe-1"))))

    (display "\n── the regime, claimed and read per recipe ──\n")
    (check "no claim: probability-free, the dangerous default"
           (eq? 'probability-free (live-regime-of store "bread")))
    (check "the claim lands (tails and process arrive as strings from the wire)"
           (ok? ($ svc 'claim-regime GOV TOWN "bread" "thin" "stable")))
    (check "thin and stable, live: statistics are licensed on that domain alone"
           (and (eq? 'statistical (live-regime-of store "bread"))
                (eq? 'probability-free (live-regime-of store "wine"))))

    (display "\n── rights off the title rail, for the span gate's standing ──\n")
    (check "no title spoken: unknown, ungated" (not (title-rights-of store "lathe-1" UC)))
    ($ store 'issue (make-ownership-attestation-credential #:owner-aid SHOP
                                                           #:resource-id "lathe-1"
                                                           #:resource-spec "lathe"))
    (check "a live title names its issuer as the rights-holder"
           (equal? SHOP (title-rights-of store "lathe-1" UC)))
    ($ store 'issue (make-ownership-attestation-credential #:owner-aid UC
                                                           #:resource-id "anvil-1"
                                                           #:resource-spec "anvil"))
    (check "a title held by the universal commune reads as common"
           (eq? 'common (title-rights-of store "anvil-1" UC)))
    (check "standing gates the declaration: only the rights-holder's span passes"
           (let ((rights-of (lambda (rid) (title-rights-of store rid UC))))
             (and (equal? "town-square"
                          (assoc-ref (consented-span-of store #:rights-of rights-of #:uc-aid UC) "lathe-1"))
                  (begin ($ svc 'declare-span GOV TOWN "anvil-1" "town-square")
                         (not (assoc-ref (consented-span-of store #:rights-of rights-of #:uc-aid UC) "anvil-1"))))))))

(test-summary!)
