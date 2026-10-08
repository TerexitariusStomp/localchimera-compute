;;; test-planner-earth-roster.scm — the unification: when the planner-service is wired to
;;; EARTH, its roster IS earth (one source of truth). Creating a commune under earth
;;; (ensure-commune!) makes it durable AND immediately visible to the planner — no separate
;;; add-scope!, no shadow scopes-hm.
;;;
;;; Run: guile --no-auto-compile -q -L module -L tests tests/planner/test-planner-earth-roster.scm

(use-modules (playnet test harness)
             (playnet planner scope earth) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner doors service)
             (playnet planner vf schemas)
             (goblins)
             (goblins vat)
             (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "roster"))
(define earth (with-vat vat (spawn-earth)))
;; planner-service wired to EARTH (4th arg) — the local scopes-hm stays empty
(define dummy-plan-fn (lambda (root id . kw) '((met . 0))))   ; roster test — planning not exercised
(define svc (with-vat vat (spawn ^planner-service (hashmap) dummy-plan-fn earth)))

;; create two communes ONLY under earth (no add-scope!)
(with-vat vat
  ($ earth 'ensure-commune! "E_A" "Alpha")
  ($ earth 'ensure-commune! "E_B" "Beta"))

(display "\n── planner-service reads earth as its roster ──\n")
(define listed (with-vat vat ($ svc 'scope-list)))
(check "scope-list surfaces BOTH earth communes (no add-scope! needed)" (length listed) 2)
(check-pred "…including Alpha by its aid" (assoc "E_A" (map (lambda (e) (cons (assq-ref e 'id) (assq-ref e 'name))) listed)))
(check "…with the right name" (assq-ref (find (lambda (e) (equal? (assq-ref e 'id) "E_B")) listed) 'name) "Beta")

;; a commune added later via ensure-commune! is instantly visible — no re-registration
(with-vat vat ($ earth 'ensure-commune! "E_C" "Gamma"))
(check "a commune added to earth AFTER is instantly in the roster" (length (with-vat vat ($ svc 'scope-list))) 3)

;; add-scope! on the service delegates to earth (external-caller compat)
(with-vat vat ($ svc 'add-scope! "E_D" (spawn-scope-root "Delta")))
(check "service add-scope! writes THROUGH to earth" (with-vat vat ($ earth 'count)) 4)

;; forget-scope! is add-scope!'s symmetric door — a demo/throwaway scope's
;; way out, reachable without exposing earth itself to a caller
(with-vat vat ($ svc 'forget-scope! "E_D"))
(check "service forget-scope! writes THROUGH to earth" (with-vat vat ($ earth 'count)) 3)

;; forget-commune! is the symmetric op to add-commune! — a throwaway/demo
;; commune has a way out of earth's roster, no re-registration needed
(with-vat vat ($ earth 'forget-commune! "E_C"))
(check "forget-commune! removes it from scope-list" (length (with-vat vat ($ svc 'scope-list))) 2)
(check "…and from has-commune?" (with-vat vat ($ earth 'has-commune? "E_C")) #f)
(check "…forgetting an unknown aid is a harmless no-op" (with-vat vat ($ earth 'forget-commune! "E_nope")) #f)

;; scope-geo-path: a commune with no real geography above it still gets a
;; flat, one-segment path naming its own place, rather than the empty list
;; crumb.js's picker silently drops any scope for (Finding A of the
;; /default pass — "playnet development"/"Playnet"/"Garden" all hit this
;; live: a parentless place, or a place directly under biosphere with
;; nothing between, both used to collapse to '())
(define (seed-place! root id name . contained-in)
  ($ ($ root 'spatial-thing-store) 'add-location
     (make-spatial-thing #:id id #:name name
                         #:contained-in (and (pair? contained-in) (car contained-in)))))
(define (path-of svc-id)
  (assq-ref (find (lambda (e) (equal? (assq-ref e 'id) svc-id)) (with-vat vat ($ svc 'scope-list))) 'path))

;; no spatial-things at all: still '() (unchanged — Alpha never got one)
(check "no geography at all ⇒ still an empty path" (path-of "E_A") '())

;; a parentless place (dev-commune's own shape)
(define flat-root (with-vat vat (spawn-scope-root "Flat")))
(with-vat vat (seed-place! flat-root "flat-place" "Flat place"))
(with-vat vat ($ svc 'add-scope! "E_Flat" flat-root))
(check "a parentless place gets a one-segment path naming itself"
       (path-of "E_Flat") (list (list (cons 'id "flat-place") (cons 'name "Flat place"))))

;; a place directly under biosphere and nothing else (Playnet/Garden's shape)
(define under-bio-root (with-vat vat (spawn-scope-root "UnderBiosphere")))
(with-vat vat
  (seed-place! under-bio-root "biosphere" "The biosphere")
  (seed-place! under-bio-root "ub-place" "Under biosphere" "biosphere"))
(with-vat vat ($ svc 'add-scope! "E_UB" under-bio-root))
(check "a place directly under biosphere (only) also gets a one-segment path"
       (path-of "E_UB") (list (list (cons 'id "ub-place") (cons 'name "Under biosphere"))))

;; a real multi-hop chain (Berlin's shape) — unchanged, regression guard
(define nested-root (with-vat vat (spawn-scope-root "Nested")))
(with-vat vat
  (seed-place! nested-root "biosphere" "The biosphere")
  (seed-place! nested-root "region" "A Region" "biosphere")
  (seed-place! nested-root "nested-place" "Nested place" "region"))
(with-vat vat ($ svc 'add-scope! "E_Nested" nested-root))
(check "a real multi-hop chain still climbs to its ancestors, not the leaf"
       (path-of "E_Nested")
       (list (list (cons 'id "region") (cons 'name "A Region"))))

;; the earth=#f path (unit tests) still uses the local scopes-hm — unchanged
(define svc2 (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "S1" (spawn-scope-root "Solo")))))
(check "earth=#f ⇒ falls back to local scopes-hm (back-compat)" (length (with-vat vat ($ svc2 'scope-list))) 1)

(test-summary!)
