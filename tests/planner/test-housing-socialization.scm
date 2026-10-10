;;; test-housing-socialization.scm — housing, end-to-end on the generic rails.
;;;
;;; Alice's flat stands in a SIBLING commune; only her grant makes it (and the
;;; beds inside it) reachable at all. She socializes the FLAT alone — the
;;; beds are never granted by name: the containment cascade carries them into
;;; the pool (lend the flat and its beds come with it), their capacity
;;; projects as Svc|spec-bed, and the plan fills a citizen's shelter need
;;; from them — through the REAL dwelling recipe (rp-shelter-night), the same
;;; knowledge every scope seeds. Recall the grant and the next solve houses
;;; nobody: reach, custody and capacity were all projections of one live
;;; credential.
;;;
;;; The same solve surfaces the pool as `socialized-slots` — the map's 🏠
;;; source — each means at the place the containment climb resolves (the bed
;;; inherits the flat's location), with its owner and its face.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-housing-socialization.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet knowledge recipes dwelling) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store)
             (goblins) (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")

(display "\n── Setup: a commune; Alice's flat (two beds inside) next door ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Housing Test"))
    store))

;; a minimal mock for the SIBLING commune that holds Alice's records
(define (alice-flat)
  (make-economic-resource #:id "res:flat" #:name "Alice's flat" #:image "🏠"
                          #:conforms-to "spec-dwelling" #:classified-as '() #:onhand-quantity (make-measure 1 %count-unit)
                          #:current-location "town" #:primary-accountable OWNER))
(define (alice-beds)
  (make-economic-resource #:id "res:beds" #:name "Alice's guest room" #:image "🏠"
                          #:conforms-to "spec-bed" #:classified-as '() #:onhand-quantity (make-measure 2 %count-unit) #:primary-accountable OWNER #:contained-in "res:flat"))

(define acdc #f)
(define grant #f)
(define resolve #f)

(with-vat vat
  ;; the commune's own knowledge: the REAL dwelling seeders, one place
  (let ((rs ($ scope 'recipe-store)))
    (seed-dwelling-specs rs)
    (seed-dwelling-recipe rs))
  ($ ($ scope 'spatial-thing-store) 'add-location
     (make-spatial-thing #:id "town" #:name "Town" #:lat 52.5 #:long 13.4))
  ;; Alice's home commune, reachable only through the federation resolver
  (let* ((m-obs  (spawn ^mock `((all-resources . ,(lambda () (list (alice-flat) (alice-beds)))))))
         (m-root (spawn ^mock `((observer   . ,(lambda () m-obs)))))
         (m-comm (spawn ^mock `((scope-root . ,(lambda () m-root)))))
         (fed    (spawn ^mock `((members    . ,(lambda () (hashmap-set (hashmap) "commA" m-comm)))))))
    (set! resolve (federation-resource-resolver fed)))
  ;; the grant: ONE credential, over the FLAT alone — the beds ride containment
  (set! acdc (spawn-acdc-store))
  (set! grant (socialize-private-resource acdc OWNER COMMUNE "spec-dwelling" 1
                                          #:until FUTURE)))

;; a shelter need of 10 person-nights at town, solved over the commune scope
;; with its live socialization folded in — the one call the live path uses.
;; The pool's ceiling at this granularity: 2 beds × 24 h / 8 h = 6 nights a
;; day — an abstract day-band lets a bed time-multiplex; it is the need's own
;; NIGHT window (declare-need's arcs), when a citizen states one, that pins a
;; bed to one sleeper a night. What this solve proves is the bound itself:
;; the plan draws bed-hours the grant projected and not one more.
(define (solve)
  (with-vat vat
    (plan-commune-scope scope acdc COMMUNE
                        #:resolve resolve
                        #:demand '(("spec-shelter#town@0" . 10.0))
                        #:backend 'native-c)))

(display "\n── the pool stands BEFORE any solve: the grant is the row ──\n")
;; the map reads what stands in the commons off the store, live; a solve
;; only adds how occupied each slot came out. So the rows are there now.
(define pre (with-vat vat (commune-socialized-slots scope acdc COMMUNE #:resolve resolve)))
(check-pred "the flat is a slot the moment its grant is issued (no solve yet)"
            (find (lambda (s) (equal? "res:flat" (assq-ref s 'id))) pre))
(check-pred "…and the beds inside it, by containment"
            (find (lambda (s) (equal? "res:beds" (assq-ref s 'id))) pre))
(check-pred "a live row carries no `drawn`: occupancy is the solve's to say"
            (not (any (lambda (s) (assq 'drawn s)) pre)))

(define res (solve))
(define met (assq-ref res 'met))
(format #t "  lent 1 flat (2 beds inside) ⇒ shelter demand met ~,2f~%" met)

(display "\n── the plan houses people from the socialized pool, bounded by it ──\n")
(check-pred "the shelter need is met from beds the grant never named"
            (and (number? met) (> met 0.1)))
(check-pred "…and BOUNDED by what stands in the pool (6 of the 10 wanted)"
            (and (> met 0.5) (< met 0.7)))

(display "\n── the pool surfaces for the wheel and for the map ──\n")
(check-pred "the beds' service is a rented good (recall-fragility prices it)"
            (member "Svc|spec-bed" (or (assq-ref res 'rented-goods) '())))
(define slots (or (assq-ref res 'socialized-slots) '()))
(define bed-slot (find (lambda (s) (equal? "res:beds" (assq-ref s 'id))) slots))
(define flat-slot  (find (lambda (s) (equal? "res:flat"  (assq-ref s 'id))) slots))
(check-pred "the flat is a socialized slot (the map's 🏠)"
            (and flat-slot (equal? "🏠" (assq-ref flat-slot 'emoji))))
(check-pred "the beds are a slot too — carried in by containment, never named"
            (and bed-slot (= 2 (assq-ref bed-slot 'qty))))
(check-pred "…standing at the FLAT's place (the containment climb resolves it)"
            (equal? "town" (assq-ref bed-slot 'where)))
(check-pred "…with the owner on the row (rights never moved)"
            (equal? OWNER (assq-ref bed-slot 'owner)))
(check-pred "…and its occupancy: demand past the ceiling leaves the beds fully drawn"
            (let ((d (assq-ref bed-slot 'drawn)))
              (and (number? d) (> d 0.99))))

(display "\n── recall: the owner pulls the flat back; the pool empties ──\n")
(with-vat vat (desocialize-private-resource! acdc OWNER (cred-said grant)))
(check-pred "recalled ⇒ the live pool is empty at once, before any solve"
            (null? (with-vat vat (commune-socialized-slots scope acdc COMMUNE #:resolve resolve))))
(define res2 (solve))
(define met2 (assq-ref res2 'met))
(format #t "  after recall ⇒ shelter demand met ~,2f~%" met2)
(check-pred "after recall the next solve houses nobody — reach, custody and capacity were one projection"
            (and (number? met2) (< met2 0.01)))
(check-pred "…and the map's pool is empty with it"
            (null? (or (assq-ref res2 'socialized-slots) '())))

(display "\n── care terms compile to scheduled labour (the material half) ──\n")
;; A fresh grant WITH a condition-floor: the care compile asks for the means'
;; upkeep deliverable at its place, in the last period before the return — a
;; demand row the solve fills through whatever repair recipe delivers it.
;; The knowledge join (lent spec → deliverable) is the caller's #:upkeep-of;
;; a spec the mapping does not name compiles to nothing, fail-closed.
(define g2 (with-vat vat
             (socialize-private-resource acdc OWNER COMMUNE "spec-dwelling" 1
                                         #:until FUTURE
                                         #:condition-floor "left clean")))
(define (care-rows upkeep)
  (with-vat vat
    (socialization-care-demand acdc COMMUNE (list (alice-flat) (alice-beds))
                               '(0 1 2) #:upkeep-of upkeep)))
(check "the floor-termed grant asks for one upkeep unit, at the flat, by the return"
       (care-rows (lambda (s) (and (equal? s "spec-dwelling") "spec-hh-floor-washed")))
       '(("spec-hh-floor-washed#town@2" . 1.0)))
(check "an unnamed deliverable compiles to nothing — fail-closed, the breach check reports it"
       (care-rows (lambda (s) #f)) '())
(with-vat vat (desocialize-private-resource! acdc OWNER (cred-said g2)))
(check "a recalled grant's care compiles to nothing, like every projection of it"
       (care-rows (lambda (s) "spec-hh-floor-washed")) '())

(test-summary!)
