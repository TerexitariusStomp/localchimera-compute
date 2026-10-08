;;; test-labour-pool-live.scm — the labour fold, wired by the service itself.
;;;
;;; add-scope! is the one door every scope crosses into the planner roster;
;;; crossing it now spawns that scope's ^labour-pool, wires it under the UC
;;; root, and seeds it from the agent-store. From then on the standing roster
;;; answers without any rebuild:
;;;   • declare-skill  → the scope refolds → the UC total gains the hours
;;;   • revoke-skill   → the hours leave
;;;   • set-availability → the hours change
;;; across scopes, summed at the root — the push path of labour-fold.scm,
;;; driven end-to-end through ^planner-service.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/planner/test-labour-pool-live.scm

(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas) (playnet planner beyond schedules)
             (playnet planner doors service)
             (playnet planner pools availability-pool)
             (playnet planner facts availability)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))

;; The pool carries hours a WEEK — a recurring window's one date-free measure,
;; and the shape the app ships (one schedule per weekday): 09:00–17:00 every day
;; is 56 h, 09:00–13:00 is 28 h.
(define (window from to)
  (make-availability-window #f #f #f (list (make-time-range from to))))

(define vat (spawn-vat))

(with-vat vat

  (define scopeA (spawn-scope-root "Granary"))
  (define scopeB (spawn-scope-root "Table"))
  (define svc    (spawn ^planner-service (hashmap)))

  ;; one member per scope, available before the scopes register — the seed path
  ($ ($ scopeA 'agent-store) 'add-agent
     (make-agent #:id "aid:ana" #:type 'person #:name "Ana" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "17:00")))
  ($ ($ scopeB 'agent-store) 'add-agent
     (make-agent #:id "aid:bo" #:type 'person #:name "Bo" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "13:00")))

  ($ svc 'add-scope! "Granary" scopeA)
  ($ svc 'add-scope! "Table"   scopeB)

  (display "\n── registration wires a pool per scope under the UC root ──\n")
  (check "each scope holds a standing pool" (and ($ svc 'labour-pool "Granary")
                                                 ($ svc 'labour-pool "Table")
                                                 #t) #t)
  (check "no skills declared yet ⇒ generic labour comes with the person"
         ($ svc 'labour-total-hours #:skill "spec-labor") 84)

  (display "\n── declare-skill refolds without any rebuild ──\n")
  ($ svc 'declare-skill "Granary" "aid:ana" "spec-cook")
  (check "Ana's 56h a week of cooking stand at the UC root"
         ($ svc 'labour-total-hours #:skill "spec-cook") 56)
  ($ svc 'declare-skill "Table" "aid:bo" "spec-cook")
  (check "Bo's 28h a week joined across the scope boundary: 84h a week"
         ($ svc 'labour-total-hours #:skill "spec-cook") 84)
  (check "the scope pool reads its own share"
         ($ ($ svc 'labour-pool "Table") 'total-hours #:skill "spec-cook") 28)

  (display "\n── availability changes climb the same rail ──\n")
  ($ svc 'set-availability "Table" "aid:bo" (window "09:00" "18:00"))
  (check "Bo now offers 63h a week ⇒ 119h a week at the root"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)

  (display "\n── revoke-skill withdraws exactly ──\n")
  ($ svc 'revoke-skill "Granary" "aid:ana" "spec-cook")
  (check "Ana's hours left; Bo's remain"
         ($ svc 'labour-total-hours #:skill "spec-cook") 63)

  (display "\n── re-declaration is a raise: the same resource comes back ──\n")
  ($ svc 'declare-skill "Granary" "aid:ana" "spec-cook")
  (check "Ana's 56h a week return through the raise event: 119h a week"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)
  ($ svc 'declare-skill "Granary" "aid:ana" "spec-cook")
  (check "declaring a held skill changes nothing"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)
  ($ svc 'revoke-skill "Granary" "aid:ana" "spec-cook")

  (display "\n── my-skills answers the held set (the roster's reading) ──\n")
  ($ svc 'declare-skill "Table" "aid:bo" "spec-weld")
  (check "Bo holds cook + weld"
         (sort (assq-ref (cdr ($ svc 'my-skills "Table" "aid:bo")) 'skills)
               string<?)
         '("spec-cook" "spec-weld"))
  ($ svc 'revoke-skill "Table" "aid:bo" "spec-weld")

  (display "\n── re-registration re-seeds idempotently ──\n")
  ($ svc 'add-scope! "Table" scopeB)
  (check "the same total stands after a re-add (restart story)"
         ($ svc 'labour-total-hours #:skill "spec-cook") 63))

(test-summary!)
