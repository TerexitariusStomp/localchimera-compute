;;; container.scm — a lockable container (strongbox, safe, cashbox, drop box)
;;; as a generic durable good. This file registers the SPEC only.
;;;
;;; Deliberately unspecialized — not "the cash strongbox," the container ANY
;;; scope reaches for when something needs to sit somewhere securely between
;;; two people's independent visits. `#:keep-in-place #t` is what makes it a
;;; CONTAINER in the sense `service.scm`'s `%container-resource?` already
;;; checks (`resource-spec-keep-in-place?`) — the flag that lets
;;; `do-drop-event` (dropoff/pickup, service.scm:2318) operate on it at all,
;;; and the flag `recipe-hold` (below) reads via `proc-temporal?`
;;; (engine.scm:921) to tile the arc through TIME rather than SPACE.
;;;
;;; This is not "does containment-through-time happen," which is universal —
;;; ANY process that takes time delays its output to a later period, and
;;; `arrival-cell`/`arrival-period` (engine.scm:777-792) already advance a
;;; genuinely long MOBILE trip several periods forward, the same displacement
;;; storage produces. `keep-in-place` names the DEGENERATE case: a container
;;; with no spatial neighbours to relocate to, so its containment is ALWAYS
;;; exactly one period, unscaled by any distance (`arc-scale` engine.scm:923-924)
;;; — because there is no distance. Storage is transport's zero-distance limit,
;;; not a different mechanism from it.
;;;
;;; So a real strongbox that gets physically carried between errands is not a
;;; second, "mobile," container spec — it is this SAME spec-strongbox used as
;;; the CARGO of an ordinary `recipe-carry` (or `use`d the way transport.scm's
;;; spec-car is `use`d, a genuinely mobile container inside a spatial
;;; process). docs/playnet.typ says it exactly: "Relocating the warehouse
;;; itself is another recipe, in which the warehouse is the cargo." The box's
;;; CUSTODY, separately, moves scope-to-scope through the ordinary
;;; `transfer-custody` action (governance/scope.scm) or a socialization
;;; grant's `movable?` (governance/socialization.scm) — unrelated to which
;;; arc the planner routes it along.
;;;
;;; NO RECIPE IS DEFINED HERE — docs/playnet.typ, "Transport and storage are
;;; one recipe": "You never label a recipe 'storage'... What it takes to move
;;; something lives in its classification, not in a flag." Holding a spec IN
;;; this container is `recipe-hold` (knowledge/recipes/transport.scm), already
;;; generic over any spec and any keep-in-place container spec:
;;;
;;;   (recipe-hold "spec-eur" "spec-strongbox" #:id "rp-hold-petty-cash")
;;;
;;; — pick it up, `use` the strongbox, drop it off; because spec-strongbox is
;;; keep-in-place, that pair tiles through TIME. A courier leaving
;;; pre-committed cash for a receiver to later take is the identical
;;; pickup/dropoff pair `do-drop-event` already runs live, needing no recipe
;;; at all when it happens once, ad hoc; `recipe-hold` is for when a scope
;;; wants that same shape to compile into a standing plan.
(define-module (playnet planner knowledge recipes container)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:export (seed-container-specs))

(define (seed-container-specs recipe-store)
  "Register the generic lockable-container spec — keep-in-place, so both
   do-drop-event and recipe-hold can operate on it."
  ($ recipe-store 'add-resource-spec
     (make-resource-specification
      #:id "spec-strongbox" #:name "Strongbox (lockable container)" #:image "🔒"
      #:resource-classified-as '("custody" "container") #:default-unit-of-resource "each"
      #:keep-in-place #t)))
