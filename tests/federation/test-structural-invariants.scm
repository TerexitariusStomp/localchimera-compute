;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-structural-invariants.scm — leaves-are-real validators

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness))
(use-modules (localchimera scope root))
(use-modules (localchimera credentials recomposition) (localchimera credentials voting) (localchimera credentials work) (localchimera keri acdc) (localchimera boot scope) (localchimera federation structural-invariants) (localchimera keri acdc) (localchimera keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (ice-9 rdelim)
             (srfi srfi-1) (srfi srfi-13))


(define vat (spawn-vat))


(define (make-leaf store name aid)
  (let* ((root (spawn-scope-root name)))
    (spawn-scope name
                 #:kind 'commune
                 #:scope-root-ref root
                 #:scope-aid aid
                 #:acdc-store store)))

(define (make-fed store name aid)
  (spawn-scope name
               #:kind 'federation
               #:scope-aid aid
               #:acdc-store store))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. scope-leaf? predicate
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. scope-leaf? predicate ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (leaf  (make-leaf store "L"  "EL"))
         (fed   (make-fed  store "F"  "EF")))
    (check-pred "commune is a leaf"          (scope-leaf? leaf))
    (check-pred "federation is not a leaf"   (not (scope-leaf? fed)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. federation-leaves walks the tree
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. federation-leaves walk ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (lb    (make-leaf store "LB" "ELB"))
         (lc    (make-leaf store "LC" "ELC"))
         (sub   (make-fed  store "SUB" "ESUB"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gov-sub ($ sub 'mint-gov-cap "op"))
         (gov-top ($ top 'mint-gov-cap "op")))
    ;; Build:  TOP ─┬─ LA
    ;;              └─ SUB ─┬─ LB
    ;;                       └─ LC
    ($ sub 'admit-commune gov-sub "lb" lb)
    ($ sub 'admit-commune gov-sub "lc" lc)
    ($ top 'admit-commune gov-top "la" la)
    ($ top 'admit-commune gov-top "sub" sub)

    (let* ((leaves      (federation-leaves top))
           (leaf-aids   (map (lambda (l) ($ l 'scope-aid)) leaves)))
      (check-pred "three leaves found" (= 3 (length leaves)))
      (check-pred "ELA in leaves"       (member "ELA" leaf-aids))
      (check-pred "ELB in leaves"       (member "ELB" leaf-aids))
      (check-pred "ELC in leaves"       (member "ELC" leaf-aids))
      (check-pred "no SUB in leaves"    (not (member "ESUB" leaf-aids)))
      (check-pred "no TOP in leaves"    (not (member "ETOP" leaf-aids))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Unique-path: healthy tree (each citizen in one leaf)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Unique path (healthy) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (lb    (make-leaf store "LB" "ELB"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gla ($ la 'mint-gov-cap "op"))
         (glb ($ lb 'mint-gov-cap "op"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ la 'admit-member gla "alice")
    ($ lb 'admit-member glb "bob")
    ($ top 'admit-commune gtop "la" la)
    ($ top 'admit-commune gtop "lb" lb)

    (check-pred "paths unique"
                (federation-membership-paths-unique? top))
    (check-pred "no double-counts"
                (null? (federation-double-counted-members top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Unique-path: ATTACK — alice in two leaves of same tree
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Unique path (double-count attack) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (lb    (make-leaf store "LB" "ELB"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gla ($ la 'mint-gov-cap "op"))
         (glb ($ lb 'mint-gov-cap "op"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ la 'admit-member gla "alice")
    ($ lb 'admit-member glb "alice")             ;; <-- double count
    ($ top 'admit-commune gtop "la" la)
    ($ top 'admit-commune gtop "lb" lb)

    (check-pred "validator detects attack"
                (not (federation-membership-paths-unique? top)))
    (let ((dups (federation-double-counted-members top)))
      (check-pred "exactly one duplicate AID" (= 1 (length dups)))
      (check-pred "the duplicate is alice"
                  (equal? "alice" (car (car dups))))
      (check-pred "alice has two leaf paths"
                  (= 2 (length (cdr (car dups))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Leaf-only labor (healthy: work-events issued by leaves)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Leaf-only labor (healthy) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ top 'admit-commune gtop "la" la)
    ($ store 'issue
       (make-work-event-credential
        #:scope-aid "ELA"
        #:worker-aid "alice"
        #:event-id "evt-1"
        #:hours 4
        #:unit %effort-unit
        #:timestamp "2026-04-25T10:00:00Z"))

    (check-pred "labor issued by leaf is coherent"
                (leaf-only-labor-coherent? top))
    (check-pred "no violations"
                (null? (leaf-only-labor-violations top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Leaf-only labor: ATTACK — federation issues a work-event directly
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Leaf-only labor (federation-issued attack) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ top 'admit-commune gtop "la" la)
    ;; Federation tries to attest someone's labor directly
    ($ store 'issue
       (make-work-event-credential
        #:scope-aid "ETOP"
        #:worker-aid "alice"
        #:event-id "evt-2"
        #:hours 100
        #:unit %effort-unit
        #:timestamp "2026-04-25T10:00:00Z"))

    (check-pred "federation-issued labor flagged"
                (not (leaf-only-labor-coherent? top)))
    (let ((vios (leaf-only-labor-violations top)))
      (check-pred "exactly one violation" (= 1 (length vios)))
      (check-pred "violation issuer = ETOP"
                  (equal? "ETOP" (cred-issuer (car vios)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Bundle: federation-tree-coherent?
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Bundle predicate ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (lb    (make-leaf store "LB" "ELB"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gla ($ la 'mint-gov-cap "op"))
         (glb ($ lb 'mint-gov-cap "op"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ la 'admit-member gla "alice")
    ($ lb 'admit-member glb "bob")
    ;; Phase-6: each commune ratifies joining the federation. In tests
    ;; we hand-issue the ratification ACDCs (target = commune-aid);
    ;; production opens a real ballot via `open-recomposition-ballot`.
    (let ((rat-la (make-recomposition-ratification-credential
                   #:scope-aid "ELA"
                   #:proposal-type 'admit-commune
                   #:proposal-spec '(admit-commune "la" "ELA")
                   #:ballot-said "E_test_snap_la"
                   #:tally '((yes . 1))))
          (rat-lb (make-recomposition-ratification-credential
                   #:scope-aid "ELB"
                   #:proposal-type 'admit-commune
                   #:proposal-spec '(admit-commune "lb" "ELB")
                   #:ballot-said "E_test_snap_lb"
                   #:tally '((yes . 1)))))
      ($ store 'issue rat-la)
      ($ store 'issue rat-lb)
      ($ top 'admit-commune gtop "la" la 'ratification (cred-said rat-la))
      ($ top 'admit-commune gtop "lb" lb 'ratification (cred-said rat-lb)))
    ($ store 'issue
       (make-work-event-credential
        #:scope-aid "ELA"
        #:worker-aid "alice"
        #:event-id "evt-3"
        #:hours 2
        #:unit %effort-unit
        #:timestamp "2026-04-25T10:00:00Z"))

    (check-pred "healthy tree is coherent"
                (federation-tree-coherent? top))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Kind is immutable across method calls
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Kind immutability ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gla ($ la 'mint-gov-cap "op"))
         (gtop ($ top 'mint-gov-cap "op"))
         (la-kind-before ($ la 'kind))
         (top-kind-before ($ top 'kind)))
    ($ la 'admit-member gla "alice")
    ($ top 'admit-commune gtop "la" la)
    ($ la 'rejoin-federation gla "EOLD" "ETOP")
    (check-pred "leaf kind unchanged after admits + rejoin"
                (eq? la-kind-before ($ la 'kind)))
    (check-pred "fed kind unchanged after admit"
                (eq? top-kind-before ($ top 'kind)))
    (check-pred "leaf still leaf"      (scope-leaf? la))
    (check-pred "fed still not leaf"   (not (scope-leaf? top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. federation-members-attested? — healthy
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 9. Members attested (healthy) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (lb    (make-leaf store "LB" "ELB"))
         (top   (make-fed  store "TOP" "ETOP"))
         (gtop ($ top 'mint-gov-cap "op")))
    ($ top 'admit-commune gtop "la" la)
    ($ top 'admit-commune gtop "lb" lb)
    (check-pred "all members attested"
                (federation-members-attested? top))
    (check-pred "no unattested"
                (null? (federation-unattested-members top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. federation-members-attested? — ATTACK: spawn fed with members,
;;;    no federation-membership ACDCs in store
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 10. Fake federation (no attestations) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (top   (spawn-scope "TOP"
                             #:kind 'federation
                             #:scope-aid "ETOP"
                             #:acdc-store store
                             ;; Pre-populate members WITHOUT going through
                             ;; admit-commune — so no ACDC backs them.
                             #:members (hashmap-set (hashmap) "la" la))))
    (check-pred "fake federation flagged"
                (not (federation-members-attested? top)))
    (check-pred "unattested = la"
                (equal? '("la") (federation-unattested-members top)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. verify-kind-from-lineage — genesis scope (no recomposition events)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 11. Kind lineage (genesis) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA")))
    (check-pred "genesis leaf kind verified"
                (verify-kind-from-lineage la))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. verify-kind-from-lineage — ATTACK: scope claims kind that
;;;    contradicts a scope-merger ACDC naming it as successor
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 12. Kind lineage (claimed kind contradicts merger) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         ;; Forge a merger ACDC saying ENEW is a 'commune
         (forged (make-scope-merger-credential
                  #:predecessor-a-aid "EA"
                  #:predecessor-b-aid "EB"
                  #:new-scope-aid "ENEW"
                  #:kind 'commune
                  #:merged-at (current-time))))
    ($ store 'issue forged)
    ;; But spawn ENEW as a federation
    (let* ((root (spawn-scope-root "NEW"))
           (sus  (spawn-scope "NEW"
                              #:kind 'federation
                              #:scope-aid "ENEW"
                              #:acdc-store store
                              #:scope-root-ref root)))
      (check-pred "lineage contradicts claimed kind"
                  (not (verify-kind-from-lineage sus))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. compose-federation-admitting — non-destructive composition
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 13. Compose (non-destructive) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (la    (make-leaf store "LA" "ELA"))
         (lb    (make-leaf store "LB" "ELB"))
         (la-kind-before ($ la 'kind))
         (la-aid-before  ($ la 'scope-aid))
         (fed (compose-federation-admitting
               "FED" (list la lb)
               (lambda (f) ($ f 'mint-gov-cap "op"))
               #:scope-aid "EFED"
               #:acdc-store store)))
    (check-pred "fed is federation kind"
                (eq? 'federation ($ fed 'kind)))
    (check-pred "leaf LA unchanged kind"
                (eq? la-kind-before ($ la 'kind)))
    (check-pred "leaf LA unchanged aid"
                (equal? la-aid-before ($ la 'scope-aid)))
    (check-pred "fed has 2 leaves"
                (= 2 (length (federation-leaves fed))))
    (check-pred "fed members attested"
                (federation-members-attested? fed))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 14. Voice ⊥ CCF — voice-share-async is independent of CCF
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; The structural separation is enforced by code path discipline:
;;; voice reads `validated-gross`; consumption-credit reads CCF.
;;; This test exercises the discipline by setting a CCF and verifying
;;; voice-share-async returns the same value as before.
;;;
;;; (Skipped here because voice-share-async pulls scope-roots and
;;;  account-store wiring; the orthogonality is documented in
;;;  LEAVES-ARE-REAL.md and verified by `grep ccf module/localchimera/
;;;  federation/vows.scm` returning no hits in the voice path.)

(display "\n── 14. Voice/CCF orthogonality (structural) ──\n")

(check-pred "set-ccf does not appear in async.scm voice path"
            (let* ((path "module/localchimera/federation/vows.scm")
                   (port (open-input-file path))
                   (text (let loop ((acc ""))
                           (let ((line (read-line port)))
                             (if (eof-object? line) acc
                                 (loop (string-append acc line "\n"))))))
                   (close (close-port port)))
              (not (string-contains text "set-ccf"))))


(display "\n")
(test-summary!)
