;;; test-legal-gate-assets.scm — the gate sees the activity's THINGS and their
;;; HOLDERS, under the schema's own field names.
;;;
;;; Two rules that place and channel cannot express:
;;;   · a thing inside a sealed container, however deep (`asset-has 'contained-in`
;;;     over the climbed chain — the resource twin of `place-path`)
;;;   · a thing whose holder is a food business (`agent-has 'classified-as` over
;;;     the custodian the observer names — the Betreiber question)
;;; fire only when an observer and an agent store are handed in; without them
;;; the gate stays place-and-channel, so the feed is additive.
;;;
;;; Run: guile -L module tests/scope/test-legal-gate-assets.scm

(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet knowledge recipes food-surplus) (playnet scope spatial-things) (playnet observation observer) (playnet scope agents) (playnet vf schemas)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor))
(use-modules (playnet legal gate))
(use-modules (playnet observation observer))

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

(define sealed-rule
  (rule (all-of (on-crossing 'share-food) (asset-has 'contained-in "res:bonded-crate"))
        (list (forbid #:reason "sealed under customs bond"))
        #:label "bond/sealed" #:confidence 'verified #:steward "scope:test"))
(define operator-rule
  (rule (all-of (on-crossing 'share-food) (agent-has 'classified-as "food-business"))
        (list (forbid #:reason "operator is a Lebensmittelunternehmer"))
        #:label "lmu/operator" #:confidence 'verified #:steward "scope:test"))

(define (res id spec loc holder inside)
  (make-economic-resource #:id id #:name id #:conforms-to spec #:classified-as '()
                          #:current-location loc #:primary-accountable holder
                          #:custodian-scope holder #:contained-in inside))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((rs  (empty-recipe-store))
          (sts (spawn ^spatial-thing-store (hashmap)))
          (obs (spawn ^observer (empty-observer-state) '()))
          (as  (spawn ^agent-store (hashmap) (hashmap) (hashmap)))
          (reg (spawn ^legal-registry (list sealed-rule operator-rule))))
      (seed-food-surplus-recipe rs)
      (seed-food-surplus-3step-recipe rs)
      ($ sts 'add-location (make-spatial-thing #:id "world"))
      ($ sts 'add-location (make-spatial-thing #:id "port" #:lat 40.0 #:long -74.0
                                               #:contained-in "world"))
      ($ sts 'add-location (make-spatial-thing #:id "pier" #:lat 40.0 #:long -74.0
                                               #:contained-in "port"))
      ;; crate ⊃ box ⊃ produce: the produce has NO location of its own — it sits
      ;; where the crate sits (pier ⊂ port), held by the co-op.
      ($ obs 'seed-resource (res "res:bonded-crate" "spec-crate" "pier" "agent:coop" #f))
      ($ obs 'seed-resource (res "res:box"     "spec-box"            #f "agent:coop" "res:bonded-crate"))
      ($ obs 'seed-resource (res "res:produce" "spec-sorted-produce" #f "agent:coop" "res:box"))
      ;; a free pallet elsewhere, held by a registered food business
      ($ obs 'seed-resource (res "res:pallet"  "spec-sorted-produce" "world" "agent:kantine" #f))
      ($ as 'add-agent (make-agent #:id "agent:coop"    #:type 'organization #:name "Co-op"
                                   #:primary-location "port"  #:classified-as '("commune")))
      ($ as 'add-agent (make-agent #:id "agent:kantine" #:type 'organization #:name "Kantine"
                                   #:primary-location "world" #:classified-as '("food-business")))
      (let ((blind (make-legal-gate #:recipe-store rs #:spatial-thing-store sts #:registry reg))
            (seeing (make-legal-gate #:recipe-store rs #:spatial-thing-store sts #:registry reg
                                     #:observer obs #:agent-store as)))
        (list (blind  "rp-cd-deliver" "port@0")
              (seeing "rp-cd-deliver" "port@0")      ; produce under port, inside the crate
              (seeing "rp-cd-deliver" "pier@0")      ; same, at the leaf
              (seeing "rp-cd-deliver" "world@0")     ; everything under world: the kantine's pallet too
              (let ((fields (legal-asset-fields ($ obs 'get-resource "res:produce")
                                                (lambda (id) ($ obs 'get-resource id)))))
                (list (assq-ref fields 'contained-in) (assq-ref fields 'current-location))))))))

(display "\n── The gate, with things and holders in view ──\n")
(check-pred "no observer ⇒ asset/agent guards silent (place-and-channel gate unchanged)"
            (not (list-ref out 0)))
(check-pred "a thing two containers deep inside the bonded crate is caught at its port"
            (list-ref out 1))
(check-pred "…and at the pier the crate actually sits on" (list-ref out 2))
(check-pred "at world the food-business holder's pallet trips the operator rule"
            (list-ref out 3))
(check-pred "contained-in is the climbed chain, nearest first; location is the chain's"
            (equal? '(("res:box" "res:bonded-crate") "pier") (list-ref out 4)))
(test-summary!)
