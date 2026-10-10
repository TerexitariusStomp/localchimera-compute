;;; test-offer-work-drift-door.scm — offer-work/commitment-drift at the
;;; ^planner-service DOOR, the layer nothing tested before.
;;;
;;; offers.scm's own functions are covered directly by test-offer-doors.scm
;;; and test-commitment-drift.scm (calling offer-work/commitment-drift as
;;; plain procedures, bypassing the service entirely). This covers the door
;;; boundary itself: offer-work's positional args → the `wc` alist
;;; (input-of/effort/when/at-location/conforms-to/until, with the "" → #f
;;; normalization every optional gets), and commitment-drift's window-days/
;;; at forwarding by NAME rather than by hand-counted position (the door
;;; used to read `. opts` with `(and (pair? opts) (number? (car opts)) …)`).
;;;
;;; Run: guile -L module -L tests tests/doors/test-offer-work-drift-door.scm

(use-modules (playnet scope root) (playnet doors service) (playnet test harness)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat #:name "offer-work-drift-door"))
(define root (with-vat vat (spawn-scope-root "Commune")))
(define scopes (hashmap-set (hashmap) "c1" root))
(define svc (with-vat vat (spawn ^planner-service scopes)))

(display "\n── offer-work: required args, no until (epoch-scoped, never expires) ──\n")
(define r1 (with-vat vat ($ svc 'offer-work "c1" "alice" "bake" 2 "2026-03-01T09:00:00Z" "town" "skill-bake")))
(check "ok" (car r1) 'ok)
(check-pred "a proposal id comes back" (assq-ref (cdr r1) 'proposal))

(display "\n── offer-work: re-offering the same slot replaces it, not duplicates ──\n")
(define r2 (with-vat vat ($ svc 'offer-work "c1" "alice" "bake" 3 "2026-03-01T09:00:00Z" "town" "skill-bake")))
(check "ok" (car r2) 'ok)
(check "same proposal id — re-offer replaces the standing offer"
       (assq-ref (cdr r1) 'proposal) (assq-ref (cdr r2) 'proposal))

(display "\n── offer-work: a past UNTIL is refused at the door as (error . msg), never an uncaught throw ──\n")
(define r3 (with-vat vat ($ svc 'offer-work "c1" "alice" "mill" 1 "2020-01-01T09:00:00Z" "town" "skill-mill" "2020-01-02")))
(check "error envelope" (car r3) 'error)

(display "\n── offer-work: blank optionals (\"\") normalize to #f, not the literal empty string ──\n")
(define r4 (with-vat vat ($ svc 'offer-work "c1" "bob" "grow" 1 "" "" "")))
(check "ok — a blank when/place/skill is still a valid offer" (car r4) 'ok)

(display "\n── commitment-drift: defaults, read by NAME ──\n")
(define d1 (with-vat vat ($ svc 'commitment-drift "c1")))
(check "ok" (car d1) 'ok)
(check "default window-days is 7.0" (assq-ref (cdr d1) 'window-days) 7.0)

(display "\n── commitment-drift: window-days and at forward by name, independent of each other ──\n")
(define d2 (with-vat vat ($ svc 'commitment-drift "c1" 30.0)))
(check "ok" (car d2) 'ok)
(check "window-days lands, at stays the default (now)" (assq-ref (cdr d2) 'window-days) 30.0)

(define d3 (with-vat vat ($ svc 'commitment-drift "c1" 7.0 1700000000)))
(check "ok" (car d3) 'ok)
(check "at lands: as-of reflects the asked epoch, not now" (assq-ref (cdr d3) 'as-of) 1700000000)

(display "\n── commitment-drift: a non-number at/window-days is ignored, not a crash ──\n")
(define d4 (with-vat vat ($ svc 'commitment-drift "c1" "not-a-number" "also-not")))
(check "ok — falls back to the real defaults" (car d4) 'ok)
(check "window-days falls back to 7.0" (assq-ref (cdr d4) 'window-days) 7.0)

(test-summary!)
