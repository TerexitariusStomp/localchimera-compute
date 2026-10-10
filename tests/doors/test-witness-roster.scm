;;; test-witness-roster.scm — who is there to witness: the scope's community.
;;;
;;; Opening a witnessing over a work event asks the people who are there to ask.
;;; That is the scope's community, not the scope's agent store: a person whose
;;; home is here and who has only stated a want holds no agent record, and a
;;; visitor who worked here holds theirs at their home. The roster is the scope's
;;; agents, the people homed here and the people who took part in an event
;;; recorded here, each a person we know (homed or recorded somewhere).
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/doors/test-witness-roster.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             ((playnet test scope) #:select (record-work!))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat))

(with-vat vat
  (let* ((a (spawn-scope-root "Granary")) (h (spawn-scope-root "Home"))
         (svc (spawn ^planner-service (hashmap)))
         (oa ($ a 'observer))
         (seen #f))
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Home" h)
    ;; ada has a record here; cleo stated a want here and has none; vic lives at Home
    ($ svc 'set-profile "Granary" "ada" "[]")
    ($ svc 'declare-need "Granary" "cleo" "spec-bread" 2 "loaf" "" "" "" "🍞" #f #f "bread")
    ($ svc 'set-profile "Home" "vic" "[]")
    (record-work! oa "ada" 3 "ev-ada" "in-ada" #:skill "spec-labor")
    (record-work! oa "vic" 2 "ev-vic" "in-vic" #:skill "spec-labor")                 ; vic worked at the Granary
    (record-work! oa "zed" 1 "ev-zed" "in-zed" #:skill "spec-labor")                 ; nobody we know
    ($ oa 'record-event                                                              ; the scope itself as a receiver
       (make-economic-event #:id "ev-buy" #:action 'consume #:resource-conforms-to "spec-bread" #:provider "vic" #:receiver "Granary"
                            #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-02T08:00:00Z"))
    ($ svc 'set-witness-door!
       `((open . ,(lambda (scope-aid ev roster) (set! seen roster) "said-1"))))

    (display "\n── the roster is the scope's community ──\n")
    (let ((r ($ svc 'witness-open "Granary" "ada" "ev-ada")))
      (check "the door opens" (car r) 'ok)
      (check "the scope's own agent is asked"          (and (member "ada" seen) #t) #t)
      (check "so is a person homed here with only a want" (and (member "cleo" seen) #t) #t)
      (check "so is a visitor who worked here, whose record is at Home" (and (member "vic" seen) #t) #t)
      (check "the scope's own id is no person"          (member "Granary" seen) #f)
      (check "nor is someone no scope knows"            (member "zed" seen) #f)
      (check "each person once" (length seen) (length (delete-duplicates seen))))))

(test-summary!)
