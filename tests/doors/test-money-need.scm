;;; test-money-need.scm — the need is HOUSING, never money, and never "rent".
;;;
;;; A first version of this test declared a need against "spec-rent" — wrong
;;; in the same way declaring a need in EUR is wrong, one level up. The real
;;; need is spec-shelter (dwelling.scm); rent is not the need, it is the
;;; OTHER recipe for it. `rp-shelter-night` delivers a person-night from a
;;; socialized bed, no money at all; `rp-rent-shelter` (dwelling.scm)
;;; delivers the identical person-night by paying an external landlord, no
;;; bed at all. Both are ordinary competing producers of one spec, so the
;;; solve — not a declaration — decides the mix: beds first (crystallized
;;; SNLT ≈ 0, already-existing capacity lent for free), rent only for
;;; whatever the beds can't cover, and only as far as the purse allows.
;;;
;;; Alice offers 2 beds (night-windowed, one sleeper each) into the commons
;;; AND lends part of her EUR purse as a consume-grant. Demand is 10 person-
;;; nights.
;;;
;;; WHAT RANKS THE TWO: neither recipe draws labour, so κ·labour is silent
;;; between them. The ranking is the stock draw (engine.scm `stock-draw-costs`):
;;; a rented night takes €25 of a purse nothing in the plan remakes, and those
;;; euros weigh the labour congealed in them — their crystallized SNLT where a
;;; recipe acquires the euro, their share of the standing purse where none
;;; does; a bed's night uses capacity that renews and weighs nothing. So the solve fills the beds, rents
;;; the nights they leave unhoused, and stops at what is asked — to the barrier's
;;; own residue, a little inside every wall. crystallized-snlt-for-spec
;;; (rollup.scm) stays the READ-time price, what the shop charges to claim a
;;; good; the plan's mix and the shop's price agree on the order, bed before
;;; rent.
;;;
;;; Run:  guile -L module -L tests tests/doors/test-money-need.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet algorithms rollup) (playnet knowledge recipes dwelling) (playnet knowledge recipes household) (playnet scope root) (playnet vf schemas) (playnet vf beyond schedules) (srfi srfi-1)
             (playnet doors service)
             ((playnet solve engine) #:select (set-dial!))
             (playnet knowledge recipes household)
             (playnet economy socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define BOB     "EBob")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")
(define DAYS '(monday tuesday wednesday thursday friday saturday sunday))

;; offered 00:00–08:00 every day: one sleeper per bed per night, not three
(define night-window
  (make-availability-window #f #f
    (list (make-day-schedule DAYS (list (make-time-range "00:00" "08:00"))))
    #f))
(define (alice-flat)
  (make-economic-resource #:id "res:flat" #:name "Alice's flat" #:image "🏠"
                          #:conforms-to "spec-dwelling" #:classified-as '() #:onhand-quantity (make-measure 1 %count-unit)
                          #:current-location "town" #:primary-accountable OWNER))
(define (alice-beds)
  (make-economic-resource #:id "res:beds" #:name "Alice's guest room" #:image "🏠"
                          #:conforms-to "spec-bed" #:classified-as '() #:onhand-quantity (make-measure 2 %count-unit) #:primary-accountable OWNER #:contained-in "res:flat"
                          #:availability-window night-window))
(define (alice-purse)
  (make-economic-resource #:id "res:purse" #:name "Alice's purse" #:conforms-to "spec-eur" #:classified-as '()
                          #:onhand-quantity (make-measure 300 "EUR") #:current-location "town" #:primary-accountable OWNER))

(define vat (spawn-vat #:name "housing-money"))

(define* (run lend-beds? purse-eur #:key (euro-recipe? #f))
  (with-vat vat
    (let* ((sr    (spawn-scope-root "Housing"))
           (store (spawn-acdc-store))
           (svc   (spawn ^planner-service (hashmap-set (hashmap) COMMUNE sr)))
           (rs    ($ sr 'recipe-store))
           (obs   ($ sr 'observer)))
      (seed-household-specs rs)          ; spec-eur
      (seed-dwelling-specs rs)
      (seed-dwelling-recipe rs)          ; rp-shelter-night — the socialized leg
      (seed-rent-recipe rs)              ; rp-rent-shelter  — the market leg
      ;; the deposit return — the one recipe that ACQUIRES a euro, so the rollup
      ;; prices it; no bottles stand here, so the plan cannot run it, only read it
      (when euro-recipe? (seed-household-waste-recipes rs))
      ($ ($ sr 'spatial-thing-store) 'add-location (make-spatial-thing #:id "town" #:name "Town"
                                                                       #:lat 52.5 #:long 13.4))
      ($ obs 'seed-resource (alice-flat))
      ($ obs 'seed-resource (alice-beds))
      ($ obs 'seed-resource (alice-purse))
      ;; socializing the FLAT cascades to its contents (dwelling.scm: "socializing
      ;; a container socializes its contents") — the beds need no grant of
      ;; their own
      (when lend-beds?
        (socialize-private-resource store OWNER COMMUNE "spec-dwelling" 1 #:until FUTURE))
      (when (> purse-eur 0)
        (socialize-private-resource store OWNER COMMUNE "spec-eur" purse-eur #:until FUTURE #:kind 'consume))
      (let ((r ($ svc 'declare-need COMMUNE BOB "spec-shelter" 10 "person-nights" "town" "" "a place to sleep" "🏠" "" "" "held" 8)))
        (unless (eq? 'ok (car r)) (error "declare-need" r)))
      (plan-commune-scope sr store COMMUNE
        #:demand-scope (spawn (lambda (bcom)
                                (lambda (msg . args)
                                  (case msg
                                    ((scope-root) sr)
                                    ((members) (hashmap))
                                    (else (error "mock scope" msg))))))
        #:home-of (lambda (aid) "town")
        #:backend 'native-c))))

(define (met r) (or (assq-ref r 'met) 0))
(define (by-process r pid)
  (fold + 0.0 (map (lambda (m) (abs (or (assq-ref m 'quantity) 0)))
                   (filter (lambda (m) (and (equal? "spec-shelter" (assq-ref m 'conforms-to))
                                            (equal? pid (assq-ref m 'output-of))))
                           (or (assq-ref r 'material) '())))))
(define (rent-spend r)
  (fold + 0.0 (map (lambda (m) (abs (or (assq-ref m 'quantity) 0)))
                   ;; what RENT took: a purse carried across the night is consumed and
                   ;; re-produced by its keep, and that is no spending
                   (filter (lambda (m) (and (eq? 'consume (assq-ref m 'action))
                                            (equal? "spec-eur" (assq-ref m 'conforms-to))
                                            (equal? "rp-rent-shelter" (assq-ref m 'input-of))))
                           (or (assq-ref r 'material) '())))))

(define beds-only    (run #t 0))
(define ample          (run #t 300))
(define scarce         (run #t 50))
(define money-no-bed (run #f 300))
(define nothing        (run #f 0))
(define lavish         (run #t 10000))

(display "\n── housing (10 person-nights wanted): beds first, rent for the rest, never money declared ──\n")
(format #t "  2 beds, no purse    ⇒ met ~,2f, spent €~,0f~%" (met beds-only) (rent-spend beds-only))
(format #t "  2 beds + €300 purse ⇒ met ~,2f, spent €~,0f (bed-nights ~,2f, rent-nights ~,2f)~%" (met ample) (rent-spend ample) (by-process ample "rp-shelter-night") (by-process ample "rp-rent-shelter"))
(format #t "  2 beds + €50 purse  ⇒ met ~,2f, spent €~,0f~%" (met scarce) (rent-spend scarce))
(format #t "  no beds, €300 purse ⇒ met ~,2f, spent €~,0f~%" (met money-no-bed) (rent-spend money-no-bed))
(format #t "  neither                ⇒ met ~,2f, spent €~,0f~%" (met nothing) (rent-spend nothing))
(format #t "  2 beds + €10,000     ⇒ met ~,2f, spent €~,0f  (rent never buys past demand)~%" (met lavish) (rent-spend lavish))

(check "beds alone: exactly 2 of 10, the night window's own limit"
       (and (> (met beds-only) 0.15) (< (met beds-only) 0.25)))
(check "beds alone: no money moves — nobody declared a euro"
       (< (rent-spend beds-only) 0.01))
(check "an ample purse buys the rest: fully met, one way or another"
       (> (met ample) 0.97))
(check "…through the free beds first: both stand all but full"
       (> (by-process ample "rp-shelter-night") 1.8))
(check "…and rent houses the rest: what is made is what is asked, to the barrier's residue"
       (let ((made (+ (by-process ample "rp-shelter-night") (by-process ample "rp-rent-shelter"))))
         (and (> made 9.7) (< made 10.5))))
(check "a scarce purse buys only what it can: 2 beds + 2 rented = 4 of 10"
       (and (> (met scarce) 0.36) (< (met scarce) 0.44)))
(check "no beds at all: the purse alone still houses 12 nights worth, capped by demand at 10"
       (> (met money-no-bed) 0.97))
(check "neither plan nor market: nothing — money is never conjured, capacity is never assumed"
       (< (met nothing) 0.01))
;; rent is felt, so the purse's size buys nothing: the spend is the unhoused
;; nights at €25, whatever is lent
(check "a lavish purse spends what the ample one did — the purse's size buys nothing more"
       (< (abs (- (rent-spend lavish) (rent-spend ample))) 1.0))
(check "…the unhoused nights at €25 each, and never the whole purse"
       (< (rent-spend lavish) (* 8.6 25.0)))
(check "a scarce purse is spent to its last euro and no further"
       (and (> (rent-spend scarce) 49.0) (<= (rent-spend scarce) 50.01)))
;; THE EURO'S OWN PRICE. Where a recipe acquires the euro, its crystallized SNLT is
;; what a drawn euro weighs (playnet.typ "Credits and external liquidity"): the
;; deposit return makes €5 in 0.4 h, so a €25 night weighs about two hours of work
;; beside a bed's nothing — the plan's mix and the shop's price are one number.
(define priced (run #t 300 #:euro-recipe? #t))
(format #t "  2 beds + €300, euro priced by its recipe ⇒ met ~,2f (bed-nights ~,2f, rent-nights ~,2f)~%"
        (met priced) (by-process priced "rp-shelter-night") (by-process priced "rp-rent-shelter"))
(check "a euro priced by the recipe that acquires it: the beds stand full, the rent stops at the nights asked"
       (and (> (by-process priced "rp-shelter-night") 1.97)
            (< (+ (by-process priced "rp-shelter-night") (by-process priced "rp-rent-shelter")) 10.05)
            (> (met priced) 0.97)))
(check "…closer than the share reads it, where no recipe reaches the euro"
       (< (by-process priced "rp-rent-shelter") (by-process ample "rp-rent-shelter")))

;; the weight is governed (engine *stock-draw-hours*): the barrier's residue past
;; what is asked runs as t/(κ·w), so a scope that holds its purse dearer rents closer
(set-dial! 'stock-draw-hours 16.0)
(define dear (run #t 300))
(set-dial! 'stock-draw-hours 1.0)
(check "a purse held dearer: the beds stand full and the rent stops at the nights asked"
       (and (> (by-process dear "rp-shelter-night") 1.97)
            (< (+ (by-process dear "rp-shelter-night") (by-process dear "rp-rent-shelter")) 10.05)
            (> (met dear) 0.97)))
(check "crystallized SNLT — the shop's own price, not the solve's — ranks the bed free and the rent real"
       (with-vat vat
         (let* ((sr (spawn-scope-root "Pricing"))
                (rs ($ sr 'recipe-store)))
           (seed-household-specs rs) (seed-dwelling-specs rs) (seed-dwelling-recipe rs) (seed-rent-recipe rs)
           (seed-household-waste-recipes rs)                               ; the deposit return: the one recipe that makes a euro
           (let ((eur (crystallized-snlt-for-spec rs "spec-eur")))
             (and (< (crystallized-snlt-for-spec rs "spec-shelter") 0.001) ; the infimum takes the free bed
                  (> eur 0.0) (< eur +inf.0))))))                          ; a euro costs the work of returning bottles: real and finite

(test-summary!)
