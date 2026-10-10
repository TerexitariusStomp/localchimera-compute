;;; test-drop-event.scm — leaving a thing in a shared container, and taking it out.
;;;
;;; The two acts a public box affords, over the real ^planner-service. They are
;;; the VF pair the ActionDefinition table already names, so the service records
;;; an EconomicEvent and the observer does the rest: `dropoff` increments what is
;;; on hand and hands custody to the container, `pickup` decrements it and hands
;;; custody back. What this pins:
;;;
;;;   • a dropoff puts the thing AT the container's place, HELD by the container
;;;     — and still OWNED by whoever left it, which is the whole difference
;;;     between leaving a thing somewhere and giving it away;
;;;   • a pickup takes it back out, custody and all;
;;;   • you cannot take what is not there, or more than is;
;;;   • and a thing that is not a container is not a place to leave things —
;;;     `keep-in-place` on the spec is what makes a box a box.
;;;
;;; No etiquette is enforced here. "Leave one to take one" is how people keep a
;;; shared box full; it is the map face's rule, not the ledger's, and a ledger
;;; that invented it would be inventing policy it cannot see.
;;;
;;; Run from project root:
;;;   guile -L module tests/playnet/test-drop-event.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet planner scope root) (playnet planner vf schemas)
             (playnet planner doors service)
             (srfi srfi-1))

(display "\n── Setup: a scope with a box under a bridge ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
                        (lambda () (spawn-scope-root "Commune"))
                        store))

(define BRIDGE "under-the-bridge")

(define svc
  (with-vat vat
    ;; the place, the container standing at it, and a loaf already inside
    ($ ($ scope 'spatial-thing-store) 'add-location
       (make-spatial-thing #:id BRIDGE #:name "under the bridge"
                           #:note "third pillar, behind the loose brick"
                           #:lat 52.5163 #:long 13.3777))
    ;; keep-in-place is the whole declaration that this is a container
    ($ ($ scope 'recipe-store) 'add-resource-spec
       (make-resource-specification #:id "spec-box" #:name "Box in a public place"
                                    #:resource-classified-as '("container") #:default-unit-of-resource %effort-unit #:default-unit-of-effort %effort-unit
                                    #:keep-in-place #t))
    ($ ($ scope 'recipe-store) 'add-resource-spec
       (make-resource-specification #:id "sack" #:name "Sack of flour" #:resource-classified-as '()
                                    #:default-unit-of-resource "kg"))
    ($ ($ scope 'observer) 'seed-resource
       (make-economic-resource #:id "box/bridge" #:name "the box" #:conforms-to "spec-box" #:classified-as '()
                               #:accounting-quantity (make-measure 24.0 %effort-unit) #:onhand-quantity (make-measure 24.0 %effort-unit)
                               #:current-location BRIDGE))
    ($ ($ scope 'observer) 'seed-resource
       (make-economic-resource #:id "sack/1" #:name "a sack of flour" #:conforms-to "sack" #:classified-as '()
                               #:accounting-quantity (make-measure 25.0 "kg") #:onhand-quantity (make-measure 25.0 "kg")
                               #:current-location BRIDGE #:primary-accountable "mill"))
    (spawn ^planner-service (hashmap-set (hashmap) "org:commune" scope))))

(define (call method . args) (with-vat vat (apply $ svc method args)))
(define (resource id) (with-vat vat ($ ($ scope 'observer) 'get-resource id)))
;; the service's envelope: (ok . value) | (error . message)
(define (ok? r)  (and (pair? r) (eq? (car r) 'ok)))
(define (err r)  (and (pair? r) (eq? (car r) 'error) (cdr r)))

(check-pred "setup: service spawned" svc)

;;; ── 1. Ada leaves three loaves ─────────────────────────────────────────────

(display "\n── 1. leaving a thing ──\n")

(define left (call 'drop-event "org:commune" "dropoff" "box/bridge" "ada"
                   "bread" 3.0 "kg" "left/loaves" "three loaves, still warm"))
(check-pred "a dropoff is accepted" (ok? left))

(define loaves (resource "left/loaves"))
(check-pred "…and the thing now exists" loaves)
(check "it is at the container's place"
       (economic-resource-current-location loaves) BRIDGE)
(check "three kilos of it are on hand"
       (measure-qty (economic-resource-onhand-quantity loaves)) 3.0)
;; custody is the COMMONS', not the box's: `custodian-scope` names a scope, and
;; a box is a thing. Which box it is in is `contained-in`, below.
(check "the commons holds it"
       (economic-resource-custodian-scope loaves) "org:commune")
(check "it is IN the box"
       (economic-resource-contained-in loaves) "box/bridge")
;; the point of the whole exercise: leaving a thing in a public box does not make
;; it the property of whoever put it down. Claiming nothing, it joins the commons
;; — the scope whose box it is — on the commons rail.
(check "unclaimed, it is the COMMONS' — not the leaver's"
       (economic-resource-primary-accountable loaves) "org:commune")
(check "…and on the commons rail"
       (economic-resource-distribution-mode loaves) 'communal)

;;; ── 1b. …unless somebody says so ───────────────────────────────────────────

(display "\n── 1b. leaving something that IS yours ──\n")

(check-pred "a dropoff can carry the claim"
            (ok? (call 'drop-event "org:commune" "dropoff" "box/bridge" "ada"
                       "bread" 1.0 "kg" "left/adas" "Ada's own loaf" "ada")))
(define adas (resource "left/adas"))
(check "…and then Ada owns it" (economic-resource-primary-accountable adas) "ada")
(check "a claimed thing is NOT on the commons rail"
       (economic-resource-distribution-mode adas) #f)
(check "the commons holds it" (economic-resource-custodian-scope adas) "org:commune")
(check-pred "which is split tenure — the commons holds what Ada owns"
            (resource-rented? adas))
;; …and the case that used to read wrong: what the commons OWNS and HOLDS is not
;; held under anybody else's rights, so it is nobody's dependency.
(check-pred "the commons' own thing in the commons' own box is NOT rented"
            (not (resource-rented? loaves)))
(check-pred "…it is sovereign" (resource-sovereign? loaves "org:commune"))

;;; ── 2. Bo takes one ────────────────────────────────────────────────────────

(display "\n── 2. taking a thing ──\n")

(define taken (call 'drop-event "org:commune" "pickup" "box/bridge" "bo"
                    "bread" 1.0 "kg" "left/loaves" ""))
(check-pred "a pickup is accepted" (ok? taken))
(check "one kilo left the box"
       (measure-qty (economic-resource-onhand-quantity (resource "left/loaves"))) 2.0)
(check "custody followed it to the taker"
       (economic-resource-custodian-scope (resource "left/loaves")) "bo")
;; a stash is ONE record, so a part-take moves that record's custody; what it
;; must not do is pretend the rest is no longer in the box.
(check "…and what is left is still IN the box"
       (economic-resource-contained-in (resource "left/loaves")) "box/bridge")
(check-pred "taking the last of it empties the box"
            (ok? (call 'drop-event "org:commune" "pickup" "box/bridge" "bo"
                       "bread" 2.0 "kg" "left/loaves" "")))
(check "…and only then is it out"
       (economic-resource-contained-in (resource "left/loaves")) #f)

;;; ── 2b. moving something the commons already owns ──────────────────────────
;;; The case that made the old default wrong: carrying a communal loaf to a
;;; public box must not make the carrier its owner.

(display "\n── 2b. moving common property ──\n")

(with-vat vat
  ($ ($ scope 'observer) 'seed-resource
     (make-economic-resource #:id "commons/soup" #:name "the commons' soup pot" #:conforms-to "soup" #:classified-as '()
                             #:accounting-quantity (make-measure 5.0 "L") #:onhand-quantity (make-measure 5.0 "L")
                             #:current-location BRIDGE #:primary-accountable "org:commune" #:custodian-scope "org:commune"
                             #:distribution-mode 'communal)))

(check-pred "a communal thing can be left in a box"
            (ok? (call 'drop-event "org:commune" "dropoff" "box/bridge" "bo"
                       "soup" 2.0 "L" "commons/soup" "")))
(define soup (resource "commons/soup"))
(check "the commons still owns it — the carrier did not acquire it"
       (economic-resource-primary-accountable soup) "org:commune")
(check "the commons still holds it" (economic-resource-custodian-scope soup) "org:commune")
(check "and it is still on the commons rail"
       (economic-resource-distribution-mode soup) 'communal)

;;; ── 3. what the ledger can actually check ──────────────────────────────────

(display "\n── 3. refusals ──\n")

(check-pred "you cannot take more than is there"
            (err (call 'drop-event "org:commune" "pickup" "box/bridge" "bo"
                       "bread" 99.0 "kg" "left/loaves" "")))
(check-pred "you cannot take what was never left"
            (err (call 'drop-event "org:commune" "pickup" "box/bridge" "bo"
                       "bread" 1.0 "kg" "left/ghost" "")))
(check-pred "a sack of flour is not a place to leave things"
            (err (call 'drop-event "org:commune" "dropoff" "sack/1" "ada"
                       "bread" 1.0 "kg" "" "")))
(check-pred "nor is a container nobody has"
            (err (call 'drop-event "org:commune" "dropoff" "box/nowhere" "ada"
                       "bread" 1.0 "kg" "" "")))
(check-pred "and a quantity must be a quantity"
            (err (call 'drop-event "org:commune" "dropoff" "box/bridge" "ada"
                       "bread" 0 "kg" "" "")))

(test-summary!)
