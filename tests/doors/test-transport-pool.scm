;;; test-transport-pool.scm — the genericity proof: transport on housing's rails.
;;;
;;; Housing (test-housing-socialization) rides declaration → grant → projected
;;; caps → use-need → solve → recall. This test runs a CARGO-BIKE through the
;;; SAME rails with ZERO new planner code: no transport-specific seam, no
;;; housing-specific seam — the spec family and the unit are the only things
;;; that change. That absence is the claim (housing-socialization.md §7): the
;;; socialized-resource pattern is one mechanism, instantiated per kind by a
;;; denomination row.
;;;
;;;   1. a need declared in "seat-hours" rides the *service-units* wire —
;;;      action 'use, effort-quantity — exactly as hours and person-nights do;
;;;   2. the scope-wide pool wire (slots-at) shows the need with its citizen;
;;;   3. Bob's cargo-bike, socialized cross-scope, carries a ride demand
;;;      bounded by the grant; recalled, it carries nothing.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/doors/test-transport-pool.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store)
             (goblins) (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists

(define OWNER   "EBob")
(define COMMUNE "ERadlerkommune")
(define FUTURE  "2099-12-31T00:00:00Z")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Transport Pool Test"))
    store))

;; ── 1+2: the need side, through the SERVICE — seat-hours are occupancy ──────
(display "\n── a seat-hours need rides the service-units wire as 'use ──\n")
(define svc-reply
  (with-vat vat
    (let ((svc (spawn ^planner-service (hashmap-set (hashmap) "s1" scope))))
      ($ svc 'declare-need "s1" "alice" "spec-ride" 5 "seat-hours"
         "depot" "" "to the market and back" "🚲" #f #f "a ride")
      (list ($ ($ scope 'plan-store) 'get-intent "need:alice:spec-ride")
            (plain-reply ($ svc 'slots-at "s1"))))))
(define ride-intent (car svc-reply))
(check-pred "the intent's action is 'use — a service OCCUPIES, it is never held"
            (eq? 'use (intent-action ride-intent)))
(check-pred "…and seat-hours ride effort-quantity (the same rail as hours)"
            (let ((m (intent-effort-quantity ride-intent)))
              (and m (= 5 (measure-has-numerical-value m))
                   (string=? "seat-hours" (measure-has-unit m)))))
(check-pred "…with no resource-quantity — nothing here is consumed"
            (not (intent-resource-quantity ride-intent)))
(define pool-needs (assq-ref (cdr (cadr svc-reply)) 'needs))
(check-pred "slots-at shows the need scope-wide, with its citizen on the row"
            (let ((n (find (lambda (x) (equal? "spec-ride" (assq-ref x 'spec)))
                           pool-needs)))
              (and n (equal? "alice" (assq-ref n 'who)))))

;; ── 3: the offer side — Bob's cargo-bike, socialized cross-scope ────────────
;; The ride recipe is seeded HERE, in-test, from the same constructors any
;; domain file uses: proof that no knowledge file and no planner change is
;; needed to put a new resource kind on the rails.
(define acdc #f)
(define grant #f)
(define resolve #f)

(define (bobs-bike)
  (make-economic-resource #:id "res:lastenrad" #:name "Bob's Lastenrad" #:image "🚲"
                          #:conforms-to "spec-cargo-bike" #:classified-as '() #:onhand-quantity (make-measure 2 %count-unit)
                          #:current-location "depot" #:primary-accountable OWNER))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-cargo-bike" #:name "Cargo bike" #:image "🚲"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-ride" #:name "A ride" #:image "🚲"
                                    #:default-unit-of-resource "seat-hours"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-ride" #:name "Riding"))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-ride" #:name "An hour's ride"
                            #:process-conforms-to "pspec-ride" #:process-classified-as '("tag:transport")
                            #:has-duration (make-duration 1 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-ride-bike" #:action 'use #:resource-conforms-to "spec-cargo-bike"
                         #:resource-quantity (make-measure 1 %count-unit) #:effort-quantity (make-measure 1 %effort-unit)
                         #:recipe-input-of "rp-ride"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-ride-out" #:action 'deliver-service #:resource-conforms-to "spec-ride"
                         #:resource-quantity (make-measure 1 "seat-hours") #:recipe-output-of "rp-ride" #:is-primary #t))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-ride" #:name "A ride" #:primary-output "spec-ride"
                    #:recipe-processes (list "rp-ride"))))
  ($ ($ scope 'spatial-thing-store) 'add-location
     (make-spatial-thing #:id "depot" #:name "Depot" #:lat 52.5 #:long 13.4))
  ;; Bob's home commune, reachable only through the federation resolver
  (let* ((m-obs  (spawn ^mock `((all-resources . ,(lambda () (list (bobs-bike)))))))
         (m-root (spawn ^mock `((observer   . ,(lambda () m-obs)))))
         (m-comm (spawn ^mock `((scope-root . ,(lambda () m-root)))))
         (fed    (spawn ^mock `((members    . ,(lambda () (hashmap-set (hashmap) "commB" m-comm)))))))
    (set! resolve (federation-resource-resolver fed)))
  (set! acdc (spawn-acdc-store))
  (set! grant (socialize-private-resource acdc OWNER COMMUNE "spec-cargo-bike" 2
                                          #:until FUTURE)))

(define (solve)
  (with-vat vat
    (plan-commune-scope scope acdc COMMUNE
                        #:resolve resolve
                        #:demand '(("spec-ride#depot@0" . 5.0))
                        #:backend 'native-c)))

(define res (solve))
(define met (assq-ref res 'met))
(format #t "\n  lent 2 bike-units ⇒ ride demand met ~,2f~%" met)

(display "\n── the plan carries riders from the socialized pool, bounded by it ──\n")
(check-pred "rides are delivered from the granted capacity"
            (and (number? met) (> met 0.1)))
(check-pred "…and BOUNDED by the grant (2 of the 5 wanted)"
            (and (> met 0.3) (< met 0.5)))
(check-pred "the bike is a rented good (the same recall-fragility as a bed)"
            (member "Svc|spec-cargo-bike" (or (assq-ref res 'rented-goods) '())))
(check-pred "…and a 🚲 slot for the map, on the SAME wire as the 🏠"
            (let ((s (find (lambda (x) (equal? "res:lastenrad" (assq-ref x 'id)))
                           (or (assq-ref res 'socialized-slots) '()))))
              (and s (equal? "🚲" (assq-ref s 'emoji))
                   (equal? "depot" (assq-ref s 'where)))))

(display "\n── recall: Bob takes the bike back; the pool carries nothing ──\n")
(with-vat vat (desocialize-private-resource! acdc OWNER (cred-said grant)))
(define met2 (assq-ref (solve) 'met))
(format #t "  after recall ⇒ ride demand met ~,2f~%" met2)
(check-pred "after recall the next solve carries nobody"
            (and (number? met2) (< met2 0.01)))

(test-summary!)
