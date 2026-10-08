;;; test-log-observe.scm — the captain's log observes, over the real
;;; ^planner-service.
;;;
;;; A spoken log entry narrates what HAPPENED, and `log-observe` turns one
;;; such narration into an EconomicEvent on the scope's observer. What this
;;; pins is the width of the door:
;;;
;;;   • the event is SELF-scoped — provider = receiver = the speaker — so the
;;;     log can never move rights or custody between agents;
;;;   • `work` records effort (hours) and mints nothing;
;;;   • `produce` mints a resource as the speaker's own, in the event's unit,
;;;     with the quantity on hand;
;;;   • `consume` with no resource named records the FACT alone — the ledger
;;;     keeps the observation, and no stock anywhere moves;
;;;   • the note (the entry's own line) and the narrated time land on the
;;;     event; and the action set is closed — a `transfer` does not fit
;;;     through this door.
;;;
;;; Run from project root:
;;;   guile -L module tests/playnet/test-log-observe.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules (playnet test harness))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet planner scope root) (playnet planner vf schemas)
             (playnet planner doors service)
             (srfi srfi-1))

(display "\n── Setup: a scope and its service ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
                        (lambda () (spawn-scope-root "Commune"))
                        store))

(define svc
  (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "org:commune" scope))))

(define (call method . args) (with-vat vat (apply $ svc method args)))
(define (obs method . args)
  (with-vat vat (apply $ ($ scope 'observer) method args)))
(define (ok? r)  (and (pair? r) (eq? (car r) 'ok)))
(define (err r)  (and (pair? r) (eq? (car r) 'error) (cdr r)))
(define (field r k) (and (ok? r) (assq-ref (cdr r) k)))

(check-pred "setup: service spawned" svc)

;;; ── 1. work: hours spent, nothing minted ─────────────────────────────────

(display "\n── 1. work observed ──\n")

(define worked (call 'log-observe "org:commune" "ada"
                     "work" "pump repair" 2.5 "h"
                     "captain's log 26619.2: fixed the greenhouse pump"
                     "2026-08-14T16:00:00Z"))
(check-pred "a work observation is accepted" (ok? worked))
(check "…and mints no resource" (field worked 'resource) "")

(define w-ev (obs 'get-event (field worked 'event)))
(check-pred "the event is on the ledger" w-ev)
(check "it is the speaker's own act"
       (economic-event-provider w-ev) "ada")
(check "…received by the speaker too (self-scoped)"
       (economic-event-receiver w-ev) "ada")
(check "the effort is 2.5 h"
       (measure-qty (economic-event-effort-quantity w-ev)) 2.5)
(check "the narrated time lands as point-in-time"
       (economic-event-has-point-in-time w-ev) "2026-08-14T16:00:00Z")
(check-pred "the entry's line rides as the note"
            (string-contains (economic-event-note w-ev) "greenhouse pump"))
(check-pred "the speaker's ledger finds it"
            (member (field worked 'event)
                    (map economic-event-id (obs 'events-for-agent "ada"))))

;;; ── 2. produce: the speaker's own stock appears ─────────────────────────

(display "\n── 2. produce observed ──\n")

(define baked (call 'log-observe "org:commune" "ada"
                    "produce" "bread" 3.0 "kg" "baked three loaves" ""))
(check-pred "a produce observation is accepted" (ok? baked))
(check-pred "…and mints a resource" (not (string-null? (field baked 'resource))))

(define loaves (obs 'get-resource (field baked 'resource)))
(check-pred "the thing now exists" loaves)
(check "three kilos of it are on hand"
       (measure-qty (economic-resource-onhand-quantity loaves)) 3.0)
(check "born in the event's unit"
       (measure-has-unit (economic-resource-onhand-quantity loaves)) "kg")
(check "it is the speaker's own"
       (economic-resource-primary-accountable loaves) "ada")

;;; ── 3. consume with no stock: the fact alone ────────────────────────────

(display "\n── 3. consume observed, nothing named ──\n")

(define resources-before (length (obs 'all-resources)))
(define ate (call 'log-observe "org:commune" "ada"
                  "consume" "coffee" 2.0 "l" "" ""))
(check-pred "a consume observation is accepted" (ok? ate))
(check "…and mints nothing" (field ate 'resource) "")
(check "no stock anywhere moved"
       (length (obs 'all-resources)) resources-before)
(check-pred "but the fact is on the ledger, by action"
            (member (field ate 'event)
                    (map economic-event-id (obs 'events-with-action 'consume))))
(check "a note left empty defaults honestly"
       (economic-event-note (obs 'get-event (field ate 'event))) "captain's log")

;;; ── 4. the door is narrow ───────────────────────────────────────────────

(display "\n── 4. what does not fit through ──\n")

(check-pred "a transfer does not fit through this door"
            (err (call 'log-observe "org:commune" "ada"
                       "transfer" "bread" 1.0 "kg" "" "")))
(check-pred "a quantity must be a quantity"
            (err (call 'log-observe "org:commune" "ada"
                       "work" "pump repair" 0 "h" "" "")))
(check-pred "an observation names its resource"
            (err (call 'log-observe "org:commune" "ada"
                       "work" "" 1.0 "h" "" "")))

;;; ── an observation stated at an instant lands once ──────────────────────

(display "\n── an observation of an instant lands once ──\n")
(define (picked) (call 'log-observe "org:commune" "ada" "produce" "apples" 12 "kg"
                       "picked the low branches" "2026-09-21T16:00:00Z"))
(define first-pick (picked))
(define events-then (length (with-vat vat ($ ($ scope 'observer) 'all-events))))
(define second-pick (picked))
(check "the second names the same event" (cdr second-pick) (cdr first-pick))
(check "…and lands nothing more"
       (length (with-vat vat ($ ($ scope 'observer) 'all-events))) events-then)
(check "the same act at another instant is another event"
       (equal? (assq-ref (cdr (call 'log-observe "org:commune" "ada" "produce" "apples" 12 "kg"
                                    "picked the low branches" "2026-09-22T16:00:00Z"))
                         'event)
               (assq-ref (cdr first-pick) 'event))
       #f)

(test-summary!)
