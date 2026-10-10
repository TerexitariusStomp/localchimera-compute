;;; test-demand-aggregation.scm — elaboration + aggregation
;;;
;;; Exercises the richer pipeline: demand-registry entries carry
;;; partial-intent fields (resource-spec, location, window, quantity),
;;; elaborate fills them in later, and aggregate-demands merges
;;; equivalent promoted intents into one line item for the planner.

(use-modules (playnet test harness)
             (playnet governance demand-registry) (playnet planner pools credit-fold) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet org endorsement)
             (playnet governance delegation-map) (playnet governance expression) (playnet governance voice-signer) (playnet keri acdc-store) (playnet keri first-person credentials)
             (playnet governance demand-registry)
             (playnet governance demand-bridge)
             (playnet governance demand-aggregation)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))


(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.001)))
    (< (abs (- a b)) tol)))

(define (synthetic-aid id) (string-append "E_" id))

(define (make-citizen id voice-share)
  (call-with-values
    (lambda () (spawn-voice-signer id (synthetic-aid id)))
    (lambda (voice sealed?)
      (list id voice sealed? (spawn-delegation-map id) voice-share))))

(define (cid c) (list-ref c 0))
(define (voice c) (list-ref c 1))
(define (sealed c) (list-ref c 2))
(define (deleg c) (list-ref c 3))
(define (share c) (list-ref c 4))

(define (registry-of citizens)
  (fold (lambda (c acc) (hashmap-set acc (cid c) (sealed c)))
        (hashmap) citizens))

(define (vdata-of citizens)
  (fold (lambda (c acc) (hashmap-set acc (cid c) (cons (share c) (deleg c))))
        (hashmap) citizens))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Propose with partial-intent fields
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Propose with partial fields ──\n")

(define vat (spawn-vat))

(with-vat vat
  (define scope (spawn-scope-root "floor-3"))
  (define dreg  ($ scope 'demand-registry))

  ;; Alice: fully-specified demand.
  (define jacuzzi-id
    ($ dreg 'propose "alice" "jacuzzi"
       '((resource-conforms-to   . "spec-hot-tub-v2")
         (resource-classified-as . ("hydrotherapy" "comfort"))
         (quantity-value         . 1)
         (quantity-unit          . "unit")
         (at-location            . "room-302")
         (has-beginning          . "2026-07-01T00:00:00Z")
         (has-end                . "2026-09-30T23:59:59Z"))))

  ;; Bob: pure wish. Description only.
  (define bench-id ($ dreg 'propose "bob" "bench" '()))

  (let ((e ($ dreg 'get jacuzzi-id)))
    (check-pred "jacuzzi entry carries spec"
                (equal? "spec-hot-tub-v2"
                        (demand-entry-resource-conforms-to e)))
    (check-pred "jacuzzi entry carries classification"
                (equal? '("hydrotherapy" "comfort")
                        (demand-entry-resource-classified-as e)))
    (check-pred "jacuzzi entry carries quantity"
                (and (= 1    (demand-entry-quantity-value e))
                     (equal? "unit" (demand-entry-quantity-unit e))))
    (check-pred "jacuzzi entry carries location"
                (equal? "room-302" (demand-entry-at-location e)))
    (check-pred "jacuzzi entry carries window"
                (and (demand-entry-has-beginning e)
                     (demand-entry-has-end e))))

  (let ((e ($ dreg 'get bench-id)))
    (check-pred "bench entry has description only"
                (equal? "bench" (demand-entry-description e)))
    (check-pred "bench entry missing spec"
                (not (demand-entry-resource-conforms-to e)))
    (check-pred "bench entry missing location"
                (not (demand-entry-at-location e)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Elaborate — fill in missing fields after propose
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Elaborate a vague wish ──\n")

(define vat2 (spawn-vat))

(with-vat vat2
  (define scope (spawn-scope-root "floor-3"))
  (define dreg  ($ scope 'demand-registry))

  (define jacuzzi-id ($ dreg 'propose "alice" "jacuzzi" '()))

  ;; Later, alice (the proposer) elaborates it.
  ($ dreg 'elaborate jacuzzi-id
     '((resource-conforms-to . "spec-hot-tub-v2")
       (at-location          . "room-302")
       (quantity-value       . 1)
       (quantity-unit        . "unit"))
     "alice")

  (let ((e ($ dreg 'get jacuzzi-id)))
    (check-pred "elaborate filled spec"
                (equal? "spec-hot-tub-v2"
                        (demand-entry-resource-conforms-to e)))
    (check-pred "elaborate filled location"
                (equal? "room-302" (demand-entry-at-location e)))
    (check-pred "elaborate preserved description"
                (equal? "jacuzzi" (demand-entry-description e)))
    (check-pred "elaborate preserved citizen"
                (equal? "alice" (demand-entry-citizen e))))

  ;; Second elaboration overwrites only named fields.
  ($ dreg 'elaborate jacuzzi-id
     '((has-beginning . "2026-07-01T00:00:00Z")
       (has-end       . "2026-09-30T23:59:59Z"))
     "alice")

  (let ((e ($ dreg 'get jacuzzi-id)))
    (check-pred "second elaborate filled window"
                (and (demand-entry-has-beginning e)
                     (demand-entry-has-end e)))
    (check-pred "second elaborate preserved spec"
                (equal? "spec-hot-tub-v2"
                        (demand-entry-resource-conforms-to e)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Promotion copies partial-intent fields through
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Promotion passes fields through ──\n")

(define vat3 (spawn-vat))

(with-vat vat3
  (define scope (spawn-scope-root "floor-3"))
  (define alice (make-citizen "alice" 20))
  (define citizens (list alice))
  (define dreg ($ scope 'demand-registry))

  (define jacuzzi-id
    ($ dreg 'propose "alice" "jacuzzi"
       '((resource-conforms-to . "spec-hot-tub-v2")
         (at-location          . "room-302")
         (quantity-value       . 1)
         (quantity-unit        . "unit")
         (has-beginning        . "2026-07-01T00:00:00Z")
         (has-end              . "2026-09-30T23:59:59Z"))))

  (define expr
    (open-expression 'demand "cycle-1" 'federation "q3" ($ dreg 'ids)
                     (registry-of citizens) (vdata-of citizens)))
  (let ((d (hashmap-set (hashmap) jacuzzi-id 1.0)))
    ($ expr 'cast "alice" (express (voice alice) 'demand "cycle-1" d)))
  ($ expr 'close)

  (promote-demands scope expr 1)

  (let* ((ps ($ scope 'plan-store))
         (intents ($ ps 'all-intents))
         (i (car intents)))
    (check-pred "promoted intent has spec"
                (equal? "spec-hot-tub-v2" (intent-resource-conforms-to i)))
    (check-pred "promoted intent has location"
                (equal? "room-302" (intent-at-location i)))
    (check-pred "promoted intent has quantity"
                (let ((q (intent-resource-quantity i)))
                  (and q
                       (= 1 (measure-has-numerical-value q))
                       (equal? "unit" (measure-has-unit q)))))
    (check-pred "promoted intent has window"
                (and (intent-has-beginning i) (intent-has-end i)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Post-promotion aggregation: three jacuzzis collapse into one
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Aggregate equivalent demands ──\n")

(define (jacuzzi-intent qty begin end)
  (make-intent #:action 'use #:name "jacuzzi" #:resource-conforms-to "spec-hot-tub-v2" #:resource-classified-as '()
    #:resource-quantity (make-measure qty "unit") #:receiver "floor-3"
    #:has-beginning begin #:has-end end
    #:at-location "room-302" #:in-scope-of '("floor-3")))

(define i-a (jacuzzi-intent 1 "2026-07-01T00:00:00Z" "2026-08-31T23:59:59Z"))
(define i-b (jacuzzi-intent 1 "2026-08-15T00:00:00Z" "2026-09-30T23:59:59Z"))
(define i-c (jacuzzi-intent 2 "2026-09-01T00:00:00Z" "2026-10-31T23:59:59Z"))

(define agg (aggregate-demands (list i-a i-b i-c)))

(check-pred "three overlapping jacuzzis → one aggregated intent"
            (= 1 (length agg)))
(let ((merged (car agg)))
  (check-pred "merged spec preserved"
              (equal? "spec-hot-tub-v2" (intent-resource-conforms-to merged)))
  (check-pred "merged location preserved"
              (equal? "room-302" (intent-at-location merged)))
  (check-pred "merged quantity summed"
              (= 4 (measure-has-numerical-value (intent-resource-quantity merged))))
  (check-pred "merged window covers min→max"
              (and (equal? "2026-07-01T00:00:00Z" (intent-has-beginning merged))
                   (equal? "2026-10-31T23:59:59Z" (intent-has-end merged)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Non-equivalence: different location → stays separate
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Different location, no merge ──\n")

(define i-room-302
  (make-intent #:action 'use #:name "jacuzzi" #:resource-conforms-to "spec-hot-tub-v2" #:resource-classified-as '()
               #:resource-quantity (make-measure 1 "unit") #:receiver "floor-3"
               #:has-beginning "2026-07-01T00:00:00Z" #:has-end "2026-08-31T23:59:59Z" #:at-location "room-302" #:in-scope-of '("floor-3")))
(define i-room-405
  (make-intent #:action 'use #:name "jacuzzi" #:resource-conforms-to "spec-hot-tub-v2" #:resource-classified-as '()
               #:resource-quantity (make-measure 1 "unit") #:receiver "floor-3"
               #:has-beginning "2026-07-01T00:00:00Z" #:has-end "2026-08-31T23:59:59Z" #:at-location "room-405" #:in-scope-of '("floor-3")))

(let ((agg (aggregate-demands (list i-room-302 i-room-405))))
  (check-pred "different locations stay separate"
              (= 2 (length agg))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Non-equivalence: disjoint time-windows → stays separate
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Disjoint windows, no merge ──\n")

(define i-summer
  (make-intent #:action 'use #:name "jacuzzi" #:resource-conforms-to "spec-hot-tub-v2" #:resource-classified-as '()
               #:resource-quantity (make-measure 1 "unit") #:receiver "floor-3"
               #:has-beginning "2026-06-01T00:00:00Z" #:has-end "2026-08-31T23:59:59Z" #:at-location "room-302" #:in-scope-of '("floor-3")))
(define i-winter
  (make-intent #:action 'use #:name "jacuzzi" #:resource-conforms-to "spec-hot-tub-v2" #:resource-classified-as '()
               #:resource-quantity (make-measure 1 "unit") #:receiver "floor-3"
               #:has-beginning "2026-12-01T00:00:00Z" #:has-end "2027-02-28T23:59:59Z" #:at-location "room-302" #:in-scope-of '("floor-3")))

(let ((agg (aggregate-demands (list i-summer i-winter))))
  (check-pred "disjoint windows stay separate"
              (= 2 (length agg))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Under-specified demands pass through unchanged
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Under-specified passthrough ──\n")

(define wish-no-spec
  (make-intent #:action 'use #:name "vague wish" #:resource-classified-as '()                    ;; no spec
 #:receiver "floor-3"
               #:at-location "room-302"                   ;; has location but no spec
 #:in-scope-of '("floor-3")))
(define wish-no-loc
  (make-intent #:action 'use #:name "vague wish" #:resource-conforms-to "spec-hot-tub-v2" #:resource-classified-as '()     ;; has spec but no location
               #:resource-quantity (make-measure 1 "unit") #:receiver "floor-3"
               #:has-beginning "2026-07-01T00:00:00Z" #:has-end "2026-08-31T23:59:59Z"                     ;; no location
 #:in-scope-of '("floor-3")))

(let ((agg (aggregate-demands (list wish-no-spec wish-no-loc))))
  (check-pred "two under-specified pass through"
              (= 2 (length agg))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Transitive overlap: chained windows all merge
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Transitive overlap chain ──\n")

;; A overlaps B, B overlaps C, but A does NOT overlap C directly.
;; All three should collapse into one cluster via transitivity.
(define a (jacuzzi-intent 1 "2026-01-01T00:00:00Z" "2026-03-31T23:59:59Z"))
(define b (jacuzzi-intent 1 "2026-03-01T00:00:00Z" "2026-05-31T23:59:59Z"))
(define c (jacuzzi-intent 1 "2026-05-01T00:00:00Z" "2026-07-31T23:59:59Z"))

(let ((agg (aggregate-demands (list a b c))))
  (check-pred "chain-overlap cluster merges to 1"
              (= 1 (length agg)))
  (let ((m (car agg)))
    (check-pred "chain cluster summed quantity = 3"
                (= 3 (measure-has-numerical-value
                       (intent-resource-quantity m))))
    (check-pred "chain cluster window = full span"
                (and (equal? "2026-01-01T00:00:00Z" (intent-has-beginning m))
                     (equal? "2026-07-31T23:59:59Z" (intent-has-end m))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Pluggable elaborate auth — proposer-only and any-live-PHC-holder
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 9. Pluggable elaborate auth ──\n")

(define vat9 (spawn-vat))

(with-vat vat9
  (define dreg (spawn-demand-registry #:can-elaborate? proposer-only-elaborate?))
  (define d    ($ dreg 'propose "alice" "bench" '()))
  (check-pred "a non-proposer is refused by proposer-only-elaborate?"
              (catch #t
                (lambda () ($ dreg 'elaborate d '((at-location . "room-1")) "bob") #f)
                (lambda (key . args) #t)))
  (check "the store is untouched by the refused elaboration"
         (demand-entry-at-location ($ dreg 'get d)) #f)
  ($ dreg 'elaborate d '((at-location . "room-1")) "alice")
  (check "the proposer's own elaboration lands"
         (demand-entry-at-location ($ dreg 'get d)) "room-1"))

(with-vat vat9
  (define store (spawn-acdc-store))
  (define eco   "E_eco")
  ($ store 'issue (make-personhood-credential eco "E_member" 100))
  (define dreg (spawn-demand-registry
                #:can-elaborate? (any-live-phc-holder-elaborate? store)))
  (define d    ($ dreg 'propose "alice" "bench" '()))
  (check-pred "a caller with no PHC is refused by any-live-phc-holder-elaborate?"
              (catch #t
                (lambda () ($ dreg 'elaborate d '((at-location . "room-2")) "E_stranger") #f)
                (lambda (key . args) #t)))
  (check "the store is untouched by the refused elaboration"
         (demand-entry-at-location ($ dreg 'get d)) #f)
  ($ dreg 'elaborate d '((at-location . "room-2")) "E_member")
  (check "a live PHC holder's elaboration lands, even though they didn't propose it"
         (demand-entry-at-location ($ dreg 'get d)) "room-2"))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
