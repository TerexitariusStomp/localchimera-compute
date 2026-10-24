;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-legal-gate-store.scm — the gate, built from the REAL stores + actor.
;;;
;;; Extends test-legal-gate.scm: instead of hand-built flows, the crossings are
;;; DERIVED from the actual food-surplus <recipe> in a live ^recipe-store, the
;;; jurisdiction path is walked from a live ^spatial-thing-store's contained-in
;;; tree, and the `forbid` comes from a live ^legal-registry actor. This is the
;;; legal layer using the schemas records + actor-stores + governance actor —
;;; no alias data. Pure data path ⇒ no blake3.
;;;
;;; Run: guile -L module tests/scope/test-legal-gate-store.scm

(use-modules (localchimera test harness) (localchimera knowledge recipes store) (localchimera knowledge recipes food-surplus) (localchimera scope spatial-things) (localchimera vf schemas)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

(use-modules (localchimera legal crossings))             ; recipe-crossings
(use-modules (localchimera legal registry))        ; the fold + vocabulary
(use-modules (localchimera legal registry-actor))  ; ^legal-registry
(use-modules (localchimera legal gate))            ; make-legal-gate

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

;; a forbidding law: "banland" bans public food-sharing.
(define (banland-ban)
  (rule (all-of (in-jurisdiction "banland") (on-crossing 'share-food))
        (list (forbid #:reason "public food-sharing ordinance"))
        #:label "banland/no-sharing" #:source "(test ordinance)"
        #:confidence 'verified #:steward "scope:test"))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((rs  (empty-recipe-store))
          (sts (spawn ^spatial-thing-store (hashmap)))
          (reg (spawn ^legal-registry (list (banland-ban)))))
      ;; seed the REAL recovery recipe (tagged specs live inside it). The base
      ;; seed registers the produce/sorted-produce specs (carrying the crossing
      ;; tags); the 3-step seed adds the pickup→sort→deliver processes.
      (seed-food-surplus-recipe rs)
      (seed-food-surplus-3step-recipe rs)
      ;; a REAL contained-in tree: banland, freeland ⊂ world
      ($ sts 'add-location (make-spatial-thing #:id "world"))
      ($ sts 'add-location (make-spatial-thing #:id "banland" #:lat 41.0 #:long -75.0
                                               #:contained-in "world"))
      ($ sts 'add-location (make-spatial-thing #:id "freeland" #:lat 40.0 #:long -74.0
                                               #:contained-in "world"))
      (let* ((gate (make-legal-gate #:recipe-store rs #:spatial-thing-store sts #:registry reg))
             ;; crossings DERIVED from the store's deliver process
             (derived (process-crossings rs "rp-cd-deliver"))
             (path (map spatial-thing-id ($ sts 'resolve-chain "banland"))))
        (list derived path
              (gate "rp-cd-deliver" "banland@0")
              (gate "rp-cd-deliver" "freeland@0")
              ;; after repealing the law, banland is no longer forbidden
              (begin ($ reg 'repeal "banland/no-sharing")
                     (gate "rp-cd-deliver" "banland@0")))))))

(define derived (list-ref out 0))
(define path    (list-ref out 1))
(define forbid-banland  (list-ref out 2))
(define forbid-freeland (list-ref out 3))
(define after-repeal    (list-ref out 4))

(display "\n── The gate, derived from the REAL stores + ^legal-registry ──\n")
(format #t "  crossings derived from the recipe store: ~a\n" derived)
(format #t "  jurisdiction path from the contained-in store: ~a\n" path)
(check-pred "crossings DERIVED from the live recipe store (share-food)" (memq 'share-food derived))
(check-pred "path WALKED from the live contained-in tree (banland⊂world)"
            (equal? path '("banland" "world")))
(check-pred "the ^legal-registry forbids the recipe at banland"        forbid-banland)
(check-pred "… but permits it at freeland"                             (not forbid-freeland))
(check-pred "repeal withers the ban — banland no longer forbidden"     (not after-repeal))

(display "\n")
(test-summary!)
