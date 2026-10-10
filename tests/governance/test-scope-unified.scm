;;; test-scope-unified.scm — unified ^scope actor (commune + federation kinds)
;;;
;;; Verifies that ^scope correctly specializes by kind: commune-style methods
;;; work on 'commune scopes; federation-style methods work on 'federation
;;; scopes; recomposition (merge, split, rejoin) emits proper ACDCs;
;;; conflict detection surfaces overlapping commitments.

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet org endorsement))
(use-modules (playnet credentials commitments) (playnet credentials membership) (playnet credentials recomposition) (playnet keri acdc) (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (fibers) (fibers conditions) (ice-9 atomic) (srfi srfi-1))


(define (await-vow vat vow-thunk)
  (let ((box  (make-atomic-box #f))
        (err  (make-atomic-box #f))
        (done (make-condition)))
    (with-vat vat
      (on (vow-thunk)
          (lambda (v)
            (atomic-box-set! box v)
            (signal-condition! done)
            'done)
          #:catch
          (lambda (e)
            (atomic-box-set! err e)
            (signal-condition! done)
            'done)))
    (wait done)
    (let ((e (atomic-box-ref err)))
      (if e (raise-exception e) (atomic-box-ref box)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Commune-kind scope: kind dispatch works
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Commune-kind scope ──\n")

(define vat (spawn-vat))

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (scope-root (spawn-scope-root "Watershed"))
         (scope (spawn-scope "Watershed"
                             #:kind 'commune
                             #:scope-root-ref scope-root
                             #:scope-aid "E_watershed"
                             #:acdc-store store))
         (gov-cap ($ scope 'mint-gov-cap "operator")))

    (check "kind = commune" ($ scope 'kind) 'commune)
    (check "scope-aid"      ($ scope 'scope-aid) "E_watershed")
    (check "commune-aid alias" ($ scope 'commune-aid) "E_watershed")
    (check-pred "has scope-root" (and ($ scope 'scope-root) #t))
    (check-pred "has member-seal" ($ scope 'member-cap?
                                       ($ scope 'mint-member-cap "alice")))

    ;; Commune-only operations work
    ($ scope 'admit-member gov-cap "alice")
    ($ scope 'set-ccf gov-cap "alice" 0.8)
    ($ scope 'exclude-member gov-cap "evil-bob")
    (check-pred "evil-bob excluded" ($ scope 'excluded-aid? "evil-bob"))

    ;; Federation-only operations error
    (check-pred "admit-commune errors on commune"
                (catch #t
                  (lambda () ($ scope 'admit-commune gov-cap "X" #f) #f)
                  (lambda _ #t)))
    (check-pred "receive-commune-stance errors on commune"
                (catch #t
                  (lambda () ($ scope 'receive-commune-stance gov-cap "X" "p" '()) #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Federation-kind scope: kind dispatch works
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Federation-kind scope ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (fed (spawn-scope "River-Federation"
                           #:kind 'federation
                           #:scope-aid "E_river_fed"
                           #:acdc-store store))
         (gov-cap ($ fed 'mint-gov-cap "operator")))

    (check "kind = federation" ($ fed 'kind) 'federation)
    (check "federation-aid alias" ($ fed 'federation-aid) "E_river_fed")
    (check-pred "no scope-root" (not ($ fed 'scope-root)))

    ;; mint-member-cap should error on federation (no member-seal)
    (check-pred "mint-member-cap errors on federation"
                (catch #t
                  (lambda () ($ fed 'mint-member-cap "x") #f)
                  (lambda _ #t)))

    ;; Commune-only operations error
    (check-pred "set-ccf errors on federation"
                (catch #t
                  (lambda () ($ fed 'set-ccf gov-cap "x" 0.5) #f)
                  (lambda _ #t)))
    (check-pred "exclude-member errors on federation"
                (catch #t
                  (lambda () ($ fed 'exclude-member gov-cap "x") #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Federation admits communes
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Federation admits communes ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (commune-a (spawn-scope "Watershed-A"
                                 #:kind 'commune
                                 #:scope-root-ref (spawn-scope-root "Watershed-A")
                                 #:scope-aid "E_watershed_a"))
         (commune-b (spawn-scope "Bakery-B"
                                 #:kind 'commune
                                 #:scope-root-ref (spawn-scope-root "Bakery-B")
                                 #:scope-aid "E_bakery_b"))
         (fed (spawn-scope "Test-Fed"
                           #:kind 'federation
                           #:scope-aid "E_testfed"
                           #:acdc-store store))
         (gov-cap ($ fed 'mint-gov-cap "op")))

    ($ fed 'admit-commune gov-cap "watershed" commune-a)
    ($ fed 'admit-commune gov-cap "bakery" commune-b)

    (check "fed has 2 members" (length ($ fed 'member-commune-ids)) 2)
    (check-pred "watershed in fed"
                (and ($ fed 'member-commune "watershed") #t))

    ;; Membership ACDCs issued
    (let ((creds ($ store 'by-schema *schema-playnet-federation-membership*)))
      (check "2 federation-membership ACDCs" (length creds) 2))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Recomposition: merge two scopes
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Merge two communes ──\n")

(with-vat vat
  (let* ((store-a (spawn-acdc-store))
         (store-b (spawn-acdc-store))
         (a (spawn-scope "Commune-A"
                         #:kind 'commune
                         #:scope-root-ref (spawn-scope-root "A-root")
                         #:scope-aid "E_a"
                         #:acdc-store store-a))
         (b (spawn-scope "Commune-B"
                         #:kind 'commune
                         #:scope-root-ref (spawn-scope-root "B-root")
                         #:scope-aid "E_b"
                         #:acdc-store store-b))
         (gov-a ($ a 'mint-gov-cap "op")))

    ;; A initiates merge with B
    (let ((combined-aid ($ a 'merge-with b gov-a)))
      (check-pred "combined AID returned"
                  (string? combined-aid))
      ;; Merger ACDC issued in A's store
      (let ((mergers ($ store-a 'by-schema *schema-playnet-scope-merger*)))
        (check "1 merger ACDC in A's store" (length mergers) 1)
        (check "predecessor-a = E_a"
               (cred-claim (car mergers) 'predecessor-a) "E_a")
        (check "predecessor-b = E_b"
               (cred-claim (car mergers) 'predecessor-b) "E_b")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Recomposition: split a scope
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Split one commune ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (a (spawn-scope "Big-Commune"
                         #:kind 'commune
                         #:scope-root-ref (spawn-scope-root "Big-root")
                         #:scope-aid "E_big"
                         #:acdc-store store))
         (gov ($ a 'mint-gov-cap "op")))

    (let ((sub-aids '("E_sub1" "E_sub2")))
      ($ a 'split sub-aids gov)
      (let ((splits ($ store 'by-schema *schema-playnet-scope-split*)))
        (check "1 split ACDC" (length splits) 1)
        (check "parent-scope-aid"
               (cred-claim (car splits) 'parent-scope-aid) "E_big")
        (check-pred "sub-scope-aids = ('E_sub1 'E_sub2)"
                    (equal? (cred-claim (car splits) 'sub-scope-aids)
                            sub-aids))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Recomposition: rejoin (change federation)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Rejoin different federation ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (commune (spawn-scope "Mobile-Commune"
                               #:kind 'commune
                               #:scope-root-ref (spawn-scope-root "Mobile-root")
                               #:scope-aid "E_mobile"
                               #:acdc-store store))
         (gov ($ commune 'mint-gov-cap "op")))

    ($ commune 'rejoin-federation gov "E_old_fed" "E_new_fed")
    (let ((rejoins ($ store 'by-schema *schema-playnet-scope-rejoin*)))
      (check "1 rejoin ACDC" (length rejoins) 1)
      (check "old-federation-aid"
             (cred-claim (car rejoins) 'old-federation-aid) "E_old_fed")
      (check "new-federation-aid"
             (cred-claim (car rejoins) 'new-federation-aid) "E_new_fed"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Conflict detection: overlapping commitments surface
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Detect commitment conflicts ──\n")

(run-fibers
 (lambda ()
   (let* ((vat (spawn-vat))
          (fed (with-vat vat
                 (let* ((store-a (spawn-acdc-store))
                        (store-b (spawn-acdc-store))
                        (fed-store (spawn-acdc-store))
                        (root-a (spawn-scope-root "A-root"))
                        (root-b (spawn-scope-root "B-root"))
                        (commune-a (spawn-scope "Commune-A"
                                                   #:kind 'commune
                                                   #:scope-root-ref root-a
                                                   #:scope-aid "E_a"
                                                   #:acdc-store store-a))
                        (commune-b (spawn-scope "Commune-B"
                                                   #:kind 'commune
                                                   #:scope-root-ref root-b
                                                   #:scope-aid "E_b"
                                                   #:acdc-store store-b))
                        (f (spawn-scope "Test-Fed"
                                            #:kind 'federation
                                            #:scope-aid "E_fed"
                                            #:acdc-store fed-store))
                        (gov ($ f 'mint-gov-cap "op")))
                   ($ store-a 'issue
                      (make-commitment-credential
                        "E_alice" "E_a" "C-A1" 'use
                        #:resource-conforms-to "spec-bread"))
                   ($ store-b 'issue
                      (make-commitment-credential
                        "E_bob" "E_b" "C-B1" 'use
                        #:resource-conforms-to "spec-bread"))
                   ($ f 'admit-commune gov "a" commune-a)
                   ($ f 'admit-commune gov "b" commune-b)
                   f))))

     ;; Detect conflicts
     (let ((conflicts
            (await-vow vat
                       (lambda () (<- fed 'detect-commitment-conflicts)))))
       (check-pred "1 conflict group on spec-bread"
                   (and (= 1 (length conflicts))
                        (equal? "spec-bread" (caar conflicts))))
       (let ((cred-pair (cdr (car conflicts))))
         (check "2 conflicting commitments" (length cred-pair) 2)))))
 #:drain? #f)


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
