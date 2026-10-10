;;; test-granary-under-uncertainty.scm — the granary the plan sizes itself, from
;;; the probabilities, before it knows the weather.
;;;
;;; Two halves of this proof already existed and each was half:
;;;   endogenous-reserve / deep-time-reserve  the plan banks good years to carry a
;;;                                           drought — for a KNOWN weather sequence;
;;;   antifragile-reserve                     a granary raises the tail carrying
;;;                                           capacity under real Doon futures — but
;;;                                           the granary is handed in (*init*).
;;; This is the whole: a Doon-Valley farm over two seasons, the first known, the
;;; second one of the record's futures (normal / drought / flood) plus the p=0
;;; famine tail — a scenario TREE, so season 0 (growing AND storing forward) is one
;;; shared decision made before the monsoon resolves, and season 1 is recourse per
;;; branch. Food is storable. Next season's subsistence is a FLOOR (`#:repro-floors`,
;;; a bar in every future — people eat in every world). The plan then banks, of its
;;; own accord, exactly what the worst defended future needs — a granary sized by
;;; the computation of probabilities, "in no way calculable by equity". G7 then adds
;;; the RESERVE proper (`#:insurance`) on top and shows which futures it yields to.
;;;
;;;   G1  the store column is ONE index shared by every branch — the root decides it
;;;   G2  the plan banks (store > 0) although a market wants the surplus NOW
;;;   G3  the famine branch is fed: own harvest + bank ≥ floor (p = 0, defended anyway)
;;;   G4  the bank is sized to the tail: bank ≈ floor − tail harvest
;;;   G5  the certainty-equivalent (one mean world) banks LESS and the tail starves
;;;   G6  the soft buffer (#:reserve) banks nothing at all — it is a want, p-weighted
;;;   G7  "yields to TRUE calamity": with a subsistence floor due every season in every
;;;       future and the reserve behind season 1, the reserve stands through the
;;;       recorded drought and is SPENT in the p=0 tail — the bank is sized to feed the
;;;       tail, not to carry a reserve through it; strict (held in the tail too) banks a
;;;       reserve's worth more, unspent
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-granary-under-uncertainty.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge worlds bioregions)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet knowledge worlds doon-valley))
(primitive-load (or (%search-load-path "playnet/knowledge/recipes/navdanya-farm.scm")
                    "module/playnet/knowledge/recipes/navdanya-farm.scm"))

;; ── the farm: land as a renewable per-season capacity, rice, food storable ──
(define PLACE "doon-farm") (define PEOPLE 28) (define HA 2.0)
(define YIELD (assoc-ref *doon-valley-crop-yields* "rice"))       ; kg/ha, normal season
(define FLOOR (navdanya-food-floor PEOPLE))                        ; kg / season
(define LO FLOOR) (define HI (* 1.3 FLOOR)) (define ALPHA 0.5) (define W 5.0)
(define spatials (list (make-spatial-thing #:id PLACE #:name "Navdanya-style farm" #:lat 30.32
                                           #:long 78.03)))
(define resources (list (make-economic-resource #:id "land" #:image (list "stationary") #:conforms-to "land" #:classified-as (list "stationary")
                          #:accounting-quantity (make-measure 100.0 "ha") #:onhand-quantity (make-measure 100.0 "ha") #:current-location PLACE)))
(define procs (list (make-recipe-process #:id "grow" #:name "Grow rice")))
(define flows (list (make-recipe-flow #:id "gl" #:action 'use #:resource-conforms-to "land"
                                      #:resource-quantity (make-measure 1.0 "ha")
                                      #:recipe-input-of "grow")
                    (make-recipe-flow #:id "gf" #:action 'produce #:resource-conforms-to "food"
                                      #:resource-quantity (make-measure YIELD "kg")
                                      #:recipe-output-of "grow" #:is-primary #t)))
(define SEASONS '(0 1))
(define eco-caps (map (lambda (t) (cons (format #f "Svc|land#~a@~a" PLACE t) (stock->flow HA t))) SEASONS))
(define (food@ t) (format #f "food#~a@~a" PLACE t))

;; ── the futures: the Doon record's, as a TREE — season 0 known, season 1 branches.
;; Each future's rice multiplier becomes a PERIOD-TAGGED produce shock on `grow` at
;; season 1 only (the root's harvest cannot depend on a monsoon not yet observed).
(define (rice-mult s) (or (assoc-ref (planning-scenario-yield-multipliers s) "rice") 1.0))
(define futures
  (map (lambda (s)
         (make-planning-scenario (planning-scenario-id s) #f (planning-scenario-probability s)
           (list (list 'produce "grow" 1 (rice-mult s)))
           (planning-scenario-note s)
           (list (planning-scenario-id s))))                     ; #:path — one branch each
       *doon-valley-scenarios/tail-robust*))
(define tail (last futures))
;; a constructed future carries exactly one shock, (produce "grow" 1 r): read r off it
(define (season1-mult s) (cadddr (car (planning-scenario-yield-multipliers s))))

;; the plan, by the shape of next season's guarantee
(define* (plan #:key (shape 'floor) (scenarios futures))
  (call-with-values
    (lambda ()
      (plan-robust-from-records resources '() spatials procs flows
        #:scenarios scenarios #:periods SEASONS #:storable '("food") #:eco-caps eco-caps #:per-agent? #f
        #:repro-floors (append `((,(food@ 0) . ,FLOOR))                 ; eat this season, in every world
                               (if (eq? shape 'floor) `((,(food@ 1) . ,FLOOR)) '()))   ; …and next
        #:demand `((,(food@ 0) . ,(* 6.0 FLOOR)))                       ; a market wants the surplus NOW
        #:reserve   (if (eq? shape 'reserve)   `((,(food@ 1) . (,LO . 0.05))) '())))
    (lambda (x fs rc n ns . more)
      (let* ((idx  (lambda (si k) (or (hash-ref fs k #f) (hash-ref rc (cons si k) #f))))
             (at   (lambda (si k) (let ((i (idx si k))) (if i (vector-ref x i) 0.0))))
             (bank (or (carried-forward x fs "food" PLACE 0) 0.0))    ; the granary: food carried 0 → 1, one root decision
             (grow0 (* YIELD (at 0 (format #f "p|grow|~a@0" PLACE))))
             (branches
              (let loop ((ss scenarios) (si 0) (acc '()))
                (if (null? ss) (reverse acc)
                    (let* ((s (car ss)) (id (planning-scenario-id s))
                           (own (* YIELD (season1-mult s) (at si (format #f "p|grow|~a@1" PLACE)))))
                      (loop (cdr ss) (+ si 1)
                            (cons (list id (planning-scenario-probability s) own (+ own bank)) acc)))))))
        (list bank grow0 branches
              (if (carried-forward x fs "food" PLACE 0) 1 0))))))       ; shared ⇒ one index; recourse ⇒ none at the root

(define ins (plan))                       ; the floor next season, held in every future
(define res (plan #:shape 'reserve))
(define ce-scenario (certainty-equivalent-scenario futures))       ; the record collapsed to one mean world (engine/robust.scm)
(define ce  (plan #:scenarios (list ce-scenario)))

(define (bank-of p) (car p)) (define (grow0-of p) (cadr p)) (define (branches-of p) (caddr p)) (define (nstore p) (cadddr p))
(define (branch p id) (assoc id (branches-of p)))
(define tail-id (planning-scenario-id tail))
(define tail-own (* YIELD (season1-mult tail) HA))                 ; the most the tail can grow on its own

(format #t "~%A ~a-ha Doon farm feeding ~a people (floor ~,0f kg/season); season 0 known, season 1 = the record's futures + the famine tail:~%" HA PEOPLE FLOOR)
(format #t "  floor next season (every future):  grows ~,0f kg, BANKS ~,0f kg forward~%" (grow0-of ins) (bank-of ins))
(for-each (lambda (b) (format #t "     ~8a p=~,2f  own harvest ~,0f + bank = ~,0f  ~a~%" (car b) (cadr b) (caddr b) (cadddr b)
                              (if (>= (cadddr b) (- LO 1.0)) "≥ lo" "*** BELOW lo ***")))
          (branches-of ins))
(format #t "  soft (#:reserve):                grows ~,0f kg, banks ~,0f kg~%" (grow0-of res) (bank-of res))
(format #t "  certainty-equivalent (1 world):  grows ~,0f kg, banks ~,0f kg; the tail would have ~,0f (lo ~,0f)~%"
          (grow0-of ce) (bank-of ce) (+ tail-own (bank-of ce)) LO)

(format #t "~%── assertions ──~%")
(check "G1 the store forward is ONE shared index across every branch — decided at the root, before the monsoon"
       (= 1 (nstore ins)))
(check "G2 the plan BANKS although a market wants the surplus now"
       (> (bank-of ins) 1.0))
(check "G3 the famine branch is FED: own harvest + bank ≥ floor (p = 0, defended anyway)"
       (>= (cadddr (branch ins tail-id)) (- LO 1.0)))
(check "G3' every branch is fed"
       (every (lambda (b) (>= (cadddr b) (- LO 1.0))) (branches-of ins)))
(check "G4 the bank is sized to the tail: ≈ floor − the tail's own harvest, no more"
       (< (abs (- (bank-of ins) (- LO tail-own))) 1.0))
(check "G5 the certainty-equivalent banks LESS, and its tail starves"
       (and (< (bank-of ce) (bank-of ins))
            (< (+ tail-own (bank-of ce)) (- LO 1.0))))
(check "G5' the certainty-equivalent keeps the shock at season 1 only — the root's harvest is untouched by a monsoon nobody saw"
       (let ((sh (planning-scenario-yield-multipliers ce-scenario)))
         (and (= 1 (length sh)) (= 4 (length (car sh))) (eqv? 1 (caddr (car sh)))
              (< 0.8 (cadddr (car sh)) 1.0))))
(check "G6 the soft buffer banks nothing — a want, p-weighted, outbid by the market"
       (< (bank-of res) 1.0))


;; ── G7: the reserve yields to the tail ─────────────────────────────────────────
;; people eat every season in every future (a floor at 0 AND 1); the reserve is a
;; quarter-season behind season 1. Default: it yields to the p=0 tail. Strict: '().
(define RES (* 0.25 FLOOR))
(define* (plan-eating #:key (yields-to 'tail))
  (call-with-values
    (lambda ()
      (plan-robust-from-records resources '() spatials procs flows
        #:scenarios futures #:periods SEASONS #:storable '("food") #:eco-caps eco-caps #:per-agent? #f
        #:repro-floors `((,(food@ 0) . ,FLOOR) (,(food@ 1) . ,FLOOR))
        #:demand `((,(food@ 0) . ,(* 6.0 FLOOR)))
        #:insurance `((,(food@ 1) ,RES ,(* 1.3 RES) 0.5 5.0))
        #:reserve-yields-to yields-to))
    (lambda (x fs rc n ns . more)
      (let ((bank (or (carried-forward x fs "food" PLACE 0) 0.0)))
        (cons bank
              (let loop ((ss futures) (si 0) (acc '()))
                (if (null? ss) (reverse acc)
                    (let* ((s (car ss)) (k (format #f "p|grow|~a@1" PLACE))
                           (i (or (hash-ref fs k #f) (hash-ref rc (cons si k) #f)))
                           (own (* YIELD (season1-mult s) (if i (vector-ref x i) 0.0))))
                      (loop (cdr ss) (+ si 1)
                            (cons (cons (planning-scenario-id s) (- (+ own bank) FLOOR)) acc))))))))))
(define yielding (plan-eating))
(define strict   (plan-eating #:yields-to '()))
(define (left p id) (assoc-ref (cdr p) id))
(format #t "~%eating every season; reserve ~,0f behind season 1:~%" RES)
(format #t "  yields to the tail: bank ~,0f — left after eating: drought ~,0f · tail ~,0f~%"
        (car yielding) (left yielding "doon-drought") (left yielding tail-id))
(format #t "  strict:             bank ~,0f — left after eating: drought ~,0f · tail ~,0f~%"
        (car strict) (left strict "doon-drought") (left strict tail-id))
(check "G7 the reserve stands through the recorded drought (left ≥ reserve)"
       (>= (left yielding "doon-drought") (- RES 1.0)))
(check "G7' …and is SPENT in the p=0 tail (left ≈ 0): the bank feeds the famine, it does not outlast it"
       (< (left yielding tail-id) 1.0))
(check "G7'' strict banks a reserve's worth MORE and leaves the tail holding it, unspent"
       (and (> (car strict) (+ (car yielding) (- RES 1.0)))
            (>= (left strict tail-id) (- RES 1.0))))

(check-done "granary under uncertainty")
