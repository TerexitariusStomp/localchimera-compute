;;; test-move-scope.scm — refederation as one verb over every aggregate.
;;;
;;; Three scopes stand under the UC; Table moves under Granary. The claim
;;; fold-node.scm:269 has carried since it was written — a refederation is
;;; two exact messages, no rebuild — runs live through the service here,
;;; for every aggregate at once:
;;;   • the labour roster: the UC total is unchanged by the move (the hours
;;;     took a different path up), and Granary's total now carries Table's
;;;   • the descent: a matched commitment still lands in Table's own
;;;     plan-store, routed UC → Granary → Table by the %scope-parent climb
;;;   • moving BACK restores the flat tree exactly — the verb is its own
;;;     inverse, because drop-child is deletion, not subtraction
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/planner/test-move-scope.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (playnet vf beyond schedules)
             (playnet doors service)
             (playnet federation plan-bundle)
             (playnet vf facts availability)
             ((playnet federation scope-graph) #:select (^scope-graph))
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

  (define granary (spawn-scope-root "Granary"))
  (define table   (spawn-scope-root "Table"))
  (define svc     (spawn ^planner-service (hashmap)))

  ($ ($ granary 'agent-store) 'add-agent
     (make-agent #:id "aid:ana" #:type 'person #:name "Ana" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "17:00")))
  ($ ($ table 'agent-store) 'add-agent
     (make-agent #:id "aid:bo" #:type 'person #:name "Bo" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "13:00")))
  ($ svc 'add-scope! "Granary" granary)
  ($ svc 'add-scope! "Table"   table)
  ($ svc 'declare-skill "Granary" "aid:ana" "spec-cook")
  ($ svc 'declare-skill "Table"   "aid:bo"  "spec-cook")

  (check "flat: the UC roster holds both (84h a week)"
         ($ svc 'labour-total-hours #:skill "spec-cook") 84)

  (display "\n── Table moves under Granary: two messages per aggregate ──\n")
  (define moved ($ svc 'move-scope! "Table" "Granary"))
  (check "the verb answers ok" (car moved) 'ok)
  (check "the UC total is unchanged — the hours took a different path up"
         ($ svc 'labour-total-hours #:skill "spec-cook") 84)
  (check "Granary's node now carries Table's total beside its own"
         ($ ($ svc 'labour-pool "Granary") 'total-hours #:skill "spec-cook") 84)
  (check "Table's own node is untouched by the move"
         ($ ($ svc 'labour-pool "Table") 'total-hours #:skill "spec-cook") 28)

  (display "\n── a change in the moved scope climbs the new path ──\n")
  ($ svc 'set-availability "Table" "aid:bo" (window "09:00" "18:00"))
  (check "Bo's 63h a week reach the UC through Granary: 119h a week"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)
  (check "and stand in Granary's subtree total"
         ($ ($ svc 'labour-pool "Granary") 'total-hours #:skill "spec-cook") 119)

  (display "\n── the descent routes through the intermediate scope ──\n")
  (define psT ($ table 'plan-store))
  ($ psT 'add-intent
     (make-intent #:id "wi1" #:action 'work #:resource-conforms-to "spec-cook"
                  #:effort-quantity (make-measure 2.0 %effort-unit) #:planned-within "plan-t"))
  ($ psT 'add-proposal (make-rising-proposal "prop-t" "plan-t" "Table" '("wi1")))
  (define r ($ svc 'match-labour!))
  (check "the match succeeds over the nested tree" (car r) 'ok)
  (check "the commitment landed in Table's plan-store, via Granary"
         (length (filter (lambda (c)
                           (equal? (commitment-planned-within c) "plan-t"))
                         ($ psT 'all-commitments)))
         1)
  (check "and never in Granary's"
         (filter (lambda (c) (equal? (commitment-planned-within c) "plan-t"))
                 ($ ($ granary 'plan-store) 'all-commitments))
         '())

  (display "\n── moving back restores the flat tree exactly ──\n")
  ($ svc 'move-scope! "Table" #f)
  (check "the UC total stands" ($ svc 'labour-total-hours #:skill "spec-cook") 119)
  (check "Granary's subtree is its own again"
         ($ ($ svc 'labour-pool "Granary") 'total-hours #:skill "spec-cook") 56)

  (display "\n── the credential graph PROJECTS: a membership edge moves the tree ──\n")
  ;; the gateway's wiring, in miniature: the scope-graph's reparent sink
  ;; points at move-scope!, so an admission's note-parent-link (fired after
  ;; the membership ACDC issues) IS the refederation
  (define graph (spawn ^scope-graph))
  ($ graph 'set-on-reparent
     (lambda (child parents)
       ($ svc 'move-scope! child (and (pair? parents) (car parents)))))
  ($ graph 'note-parent-link "Table" "Granary")
  (check "the admission's edge carried Table's folds under Granary"
         ($ ($ svc 'labour-pool "Granary") 'total-hours #:skill "spec-cook") 119)
  ($ graph 'note-unlink "Table" "Granary")
  (check "the removal's edge returned them to the UC"
         ($ ($ svc 'labour-pool "Granary") 'total-hours #:skill "spec-cook") 56)
  (check "and the UC total never moved through any of it"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)
  ;; an edge to a parent the planner does not aggregate degrades to the UC
  ($ graph 'note-parent-link "Table" "E_some_remote_federation")
  (check "an unaggregated parent files the child under the UC, not an error"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)

  (display "\n── the tree is the projection in every order the edge and the roots arrive ──\n")
  ;; the edge names a parent the planner has not registered yet: the child
  ;; stands under the UC until the parent registers, then hangs beneath it
  ;; with no second edge — and a scope registered after its edge is wired
  ;; under its parent at birth
  (define mill (spawn-scope-root "Mill"))
  ($ ($ mill 'agent-store) 'add-agent
     (make-agent #:id "aid:cy" #:type 'person #:name "Cy" #:note "" #:image "" #:classified-as '()
                 #:availability-window (window "09:00" "12:00")))
  ($ graph 'note-unlink "Table" "E_some_remote_federation")
  ($ graph 'note-parent-link "Table" "Mill")          ; Mill unknown: Table waits under the UC
  (check "Table stands under the UC while Mill is unregistered"
         ($ svc 'labour-total-hours #:skill "spec-cook") 119)
  ($ graph 'note-parent-link "Mill" "Granary")        ; Mill's own edge, before Mill exists
  ($ svc 'add-scope! "Mill" mill)
  ($ svc 'declare-skill "Mill" "aid:cy" "spec-cook")
  ;; Table stands at 63h here (Bo's window grew above); Granary's own is 56
  (check "Table was re-hung under Mill the moment Mill registered: Mill carries Cy's 21h and Table's 63h"
         ($ ($ svc 'labour-pool "Mill") 'total-hours #:skill "spec-cook") (+ 21 63))
  (check "and Mill was born under Granary: Granary's node carries its own 56h and Mill's 84h"
         ($ ($ svc 'labour-pool "Granary") 'total-hours #:skill "spec-cook") (+ 56 21 63))
  (check "the UC total never moved through any of it"
         ($ svc 'labour-total-hours #:skill "spec-cook") (+ 119 21)))

(test-summary!)
