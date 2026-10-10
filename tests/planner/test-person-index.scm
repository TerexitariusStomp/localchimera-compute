;;; test-person-index.scm — a move's home-index points at the new scope.
;;;
;;; `home-scope-of` used to scan every commune on the roster on every call;
;;; it now trusts a warm index of `adopt-home!`'s own writes, falling back to
;;; the full scan only on a cold miss. `move-home` calls `adopt-home!` for the
;;; new scope, then `set-home-row!` to tombstone the old one — and the index
;;; write belongs to `adopt-home!` alone, never to the shared tombstone path,
;;; or the second call silently overwrites the index back to the scope the
;;; person just left, with nothing to ever self-heal it (the index is warm,
;;; so the cold-miss fallback never fires again). This is that regression,
;;; caught before it ships.
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/planner/test-person-index.scm

(use-modules (playnet test harness)
             (playnet scope root)
             (playnet doors service)
             ((playnet vf facts person-facts) #:select (need-id))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat))

(with-vat vat
  (let* ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
         (svc (spawn ^planner-service (hashmap))))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)

    (display "\n── a citizen never seen before has simply no home yet ──\n")
    (check "a cold AID's home is #f, not an error" ($ svc 'home-of "zed") #f)

    (display "\n── a home is adopted where the first write landed ──\n")
    ($ svc 'set-profile "Granary" "bob" "[]")
    (check "bob's home is the Granary, the scope his write dialed"
           ($ svc 'home-of "bob") "Granary")

    (display "\n── the move: the index must follow, not lag ──\n")
    ($ svc 'move-home "bob" "Table")
    (check "home-of reads the new scope right after the move"
           ($ svc 'home-of "bob") "Table")
    ;; ask again, through a door that itself calls home-scope-of afresh — a
    ;; stale index entry still pointing at "Granary" answers this the SAME
    ;; wrong way every time (it is warm, so the fallback scan never
    ;; retriggers), where a live bug reading the row directly would at least
    ;; self-heal on this second ask
    (check "and a second ask afterwards still agrees"
           ($ svc 'home-of "bob") "Table")
    ;; dial the write at the VACATED scope: route-home redirects a person-write
    ;; to home-scope-of's own answer, so this independently exercises the
    ;; same read the two checks above made directly — a stale index would
    ;; route this write right back to "Granary" instead of "Table". Checked
    ;; against the raw stores, not through another door that would retrace
    ;; the same (possibly stale) home-scope-of call and mask the bug
    ($ svc 'declare-need "Granary" "bob" "spec-bread" 1 "loaf" "" "" "" "🍞" #f #f)
    (check "the need landed in the TRUE home's own store (Table)…"
           (and ($ ($ b 'plan-store) 'get-intent (need-id "bob" "spec-bread")) #t) #t)
    (check "…and never in the vacated scope's store (Granary)"
           ($ ($ a 'plan-store) 'get-intent (need-id "bob" "spec-bread")) #f)))

(test-summary!)
