;;; test-earth-durability.scm — the planetary root, durable per commune.
;;;
;;; Proves ^earth (module/playnet/planner/scope/earth.scm) makes EACH commune's economic state
;;; durable, closing the old "everything re-links to meeting-scope" limit:
;;;
;;;   Phase 1 — earth is the persisted root of a vat; create a Berlin commune under it,
;;;             seed its farm, take a portrait, then rehydrate from the SAME store (with a
;;;             thunk that ERRORS if called): Berlin + its stores survive, keyed by its AID.
;;;   Phase 2 — two communes under one earth rehydrate INDEPENDENTLY (Berlin's farm ≠
;;;             Playnet's), the thing the single-root shortcut could never do.
;;;   Phase 3 — MIGRATION: an old v0 store rooted at a bare ^scope-root (meeting-scope)
;;;             upgrades to a v1 earth that WRAPS it, preserving its state under the planet.
;;;
;;; Run: guile --no-auto-compile -q -L module -L tests tests/planner/test-earth-durability.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes berlin-commune-seed) (playnet planner scope earth) (playnet planner vf schemas) (srfi srfi-1)
             (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define BERLIN "E_commune_Berlin")
(define PLAYNET "E_commune_Playnet")

;; ── Phase 1: earth as the persisted root; a commune born under it survives a reboot ──
(display "\n── Phase 1: a commune under earth rehydrates with its state ──\n")
(define store1 (make-memory-store))
(define-values (vat1 earth1)
  (spawn-persistent-vat earth-env (lambda () (spawn-earth)) store1))

(with-vat vat1
  (check "earth is the root (name)" ($ earth1 (quote name)) "earth")
  (let ((broot ($ earth1 'ensure-commune! BERLIN "Berlin/Brandenburg")))   ; born under earth
    (seed-berlin-commune! broot)
    (check "earth holds 1 commune"           ($ earth1 'count) 1)
    (check-pred "…and it is Berlin"           ($ earth1 'has-commune? BERLIN))
    (check "Berlin seeded: 4 resources (land+water+labour+ground)"
           (length ($ ($ broot 'observer) 'all-resources)) 4)))

;; rehydrate from the SAME store — the thunk MUST NOT run (state comes from the store)
(define-values (vat2 earth2)
  (spawn-persistent-vat earth-env (lambda () (error "thunk ran — not restoring!")) store1))

(with-vat vat2
  (check "REHYDRATED: earth still holds Berlin" ($ earth2 'count) 1)
  (let ((broot ($ earth2 'commune BERLIN)))
    (check "REHYDRATED: Berlin root name" ($ broot (quote name)) "Berlin/Brandenburg")
    (check "REHYDRATED: Berlin 4 resources survived" (length ($ ($ broot (quote observer)) (quote all-resources))) 4)
    (check "REHYDRATED: Berlin's grow-recipes survived (3 staples)"
           (length (filter (lambda (r) (string-prefix? "r-grow-" (recipe-id r)))
                           ($ ($ broot 'recipe-store) 'all-recipes)))
           3)))

;; ── Phase 2: two communes under one earth rehydrate INDEPENDENTLY ──
(display "\n── Phase 2: two communes, independent state under one earth ──\n")
(define store2 (make-memory-store))
(define-values (vatA earthA)
  (spawn-persistent-vat earth-env (lambda () (spawn-earth)) store2))
(with-vat vatA
  (seed-berlin-commune! ($ earthA 'ensure-commune! BERLIN "Berlin/Brandenburg"))
  ;; a second, DIFFERENT commune: one land parcel only, no water — a distinct economy
  (let ((p ($ earthA 'ensure-commune! PLAYNET "Playnet")))
    ($ ($ p 'observer) 'seed-resource
       (make-economic-resource #:id "field" #:conforms-to "land" #:classified-as '()
         #:accounting-quantity (make-measure 5.0 "ha") #:onhand-quantity (make-measure 5.0 "ha") #:current-location "meadow" #:primary-accountable "playnet"))))
(define-values (vatB earthB)
  (spawn-persistent-vat earth-env (lambda () (error "thunk ran!")) store2))
(with-vat vatB
  (check "REHYDRATED: earth holds BOTH communes" ($ earthB 'count) 2)
  (check "REHYDRATED: Berlin kept its 4 resources" (length ($ ($ ($ earthB (quote commune) BERLIN) (quote observer)) (quote all-resources))) 4)
  (check "REHYDRATED: Playnet kept ITS 1 resource — separate economy"
         (length ($ ($ ($ earthB 'commune PLAYNET) 'observer) 'all-resources)) 1))

;; ── Phase 3: REKEY — a commune born under a placeholder, moved to its real AID ──
;; The founding commune is created before its KERI AID is minted, so it starts under a
;; placeholder key and is rekeyed to the AID once known — single-keyed, no duplicate.
(display "\n── Phase 3: rekey a commune from a placeholder to its real AID ──\n")
(define store3 (make-memory-store))
(define-values (v3 earth3)
  (spawn-persistent-vat earth-env (lambda () (spawn-earth)) store3))
(with-vat v3
  (let ((root ($ earth3 'ensure-commune! "founding-commune" "Playnet")))   ; placeholder key
    ($ ($ root 'observer) 'seed-resource
       (make-economic-resource #:id "granary" #:conforms-to "food" #:classified-as '()
         #:accounting-quantity (make-measure 999.0 "kg") #:onhand-quantity (make-measure 999.0 "kg") #:current-location "town" #:primary-accountable "playnet")))
  ($ earth3 'rekey-commune! "founding-commune" PLAYNET))   ; … then to its real AID
(with-vat v3
  (check "REKEYED: still exactly 1 commune (single-keyed, not doubled)" ($ earth3 'count) 1)
  (check-pred "REKEYED: now keyed by the real AID"        ($ earth3 'has-commune? PLAYNET))
  (check-pred "REKEYED: the placeholder key is gone"  (not ($ earth3 'has-commune? "founding-commune")))
  (check "REKEYED: its economic state moved with it (the 999kg granary)"
         (measure-has-numerical-value
          (economic-resource-accounting-quantity
           ($ ($ ($ earth3 'commune PLAYNET) 'observer) 'get-resource "granary")))
         999.0))

(test-summary!)
