;;; test-recover-lineage.scm — recover scope lineage from recomposition ACDCs
;;;
;;; Verifies that a fresh scope, given an acdc-store containing scope-merger
;;; and scope-split credentials referencing its AID, can reconstruct its
;;; lineage chain via recover-lineage.

(use-modules (playnet test harness))
(use-modules (playnet planner scope root))
(use-modules (playnet credentials recomposition) (playnet keri acdc) (playnet governance recovery) (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Recover lineage from a single merger
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Lineage from single merger ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         ;; Pre-populate store with a merger ACDC for E_combined.
         (_ ($ store 'issue
               (make-scope-merger-credential
                 "E_a" "E_b" "E_combined" 'commune 1000)))
         ;; Spawn a fresh scope with empty lineage.
         (root (spawn-scope-root "Combined"))
         (combined (spawn-scope "Combined"
                                 #:kind 'commune
                                 #:scope-root-ref root
                                 #:scope-aid "E_combined"
                                 #:acdc-store store)))

    (check "lineage initially empty" ($ combined 'lineage) '())

    (recover-lineage combined store)

    (let ((lineage ($ combined 'lineage)))
      (check "lineage has 2 ancestors" (length lineage) 2)
      (check-pred "predecessor-a in lineage" (and (member "E_a" lineage) #t))
      (check-pred "predecessor-b in lineage" (and (member "E_b" lineage) #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Recover lineage from a split (scope is one of the children)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Lineage from split (child scope) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (_ ($ store 'issue
               (make-scope-split-credential
                 "E_parent" '("E_sub1" "E_sub2") 'commune 2000)))
         (root (spawn-scope-root "Sub1"))
         (sub1 (spawn-scope "Sub1"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "E_sub1"
                             #:acdc-store store)))

    (recover-lineage sub1 store)

    (let ((lineage ($ sub1 'lineage)))
      (check "lineage has 1 ancestor" (length lineage) 1)
      (check "parent in lineage" (car lineage) "E_parent"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Multi-event lineage — split then merge
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Multi-event lineage ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         ;; Earlier event: E_root split into E_left and E_right
         (_1 ($ store 'issue
                (make-scope-split-credential
                  "E_root" '("E_left" "E_right") 'commune 1000)))
         ;; Later event: E_left and E_other merge into E_final
         (_2 ($ store 'issue
                (make-scope-merger-credential
                  "E_left" "E_other" "E_final" 'commune 2000)))
         (root (spawn-scope-root "Final"))
         (final (spawn-scope "Final"
                              #:kind 'commune
                              #:scope-root-ref root
                              #:scope-aid "E_final"
                              #:acdc-store store)))

    (recover-lineage final store)

    ;; Only the merger event references E_final; split is for E_left,
    ;; not E_final. So lineage should be just (E_left E_other).
    (let ((lineage ($ final 'lineage)))
      (check "final's lineage has 2 ancestors" (length lineage) 2)
      (check-pred "E_left in lineage" (and (member "E_left" lineage) #t))
      (check-pred "E_other in lineage" (and (member "E_other" lineage) #t))
      (check-pred "E_root NOT in lineage" (not (member "E_root" lineage))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Revoked merger credentials are ignored
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Revoked credentials excluded ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (cred (make-scope-merger-credential
                 "E_x" "E_y" "E_revoked" 'commune 1000))
         (_ ($ store 'issue cred))
         (_2 ($ store 'revoke (cred-said cred)))
         (root (spawn-scope-root "Revoked"))
         (scope (spawn-scope "Revoked"
                              #:kind 'commune
                              #:scope-root-ref root
                              #:scope-aid "E_revoked"
                              #:acdc-store store)))

    (recover-lineage scope store)
    (check "revoked merger ignored — empty lineage"
           ($ scope 'lineage) '())))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. set-lineage method works directly
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. set-lineage method ──\n")

(with-vat vat
  (let* ((root (spawn-scope-root "Direct"))
         (scope (spawn-scope "Direct"
                              #:kind 'commune
                              #:scope-root-ref root
                              #:scope-aid "E_direct")))
    (check "lineage starts empty" ($ scope 'lineage) '())
    ($ scope 'set-lineage '("E_one" "E_two"))
    (check "lineage after set-lineage"
           ($ scope 'lineage) '("E_one" "E_two"))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
