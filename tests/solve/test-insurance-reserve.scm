;;; test-insurance-reserve.scm — the calamity reserve q_r^"res", wired through the
;;; records pipeline as #:insurance and held by `held`.
;;;
;;; playnet.typ §Reproduction labour splits a stock's standing level in two:
;;;   q_r^"op"  the SOFT operating buffer — part of the good's desire, shed first
;;;             (#:reserve: a low-weight `des` tranche);
;;;   q_r^"res" the HARD insurance reserve — "sized by the computation of
;;;             probabilities, in no way calculable by equity", a possibility-
;;;             tension behind its own barrier (#:insurance: `held` — divergent at
;;;             `lo`, satiating at the margin quantile_alpha of [lo,hi]).
;;; social-means.typ §"Reproduction toward a target" gives the shape's numbers:
;;; the plan holds the margin while it can, erodes it as labour binds, and never
;;; breaches `lo`. #:repro-floors is the third shape beside them — a swept `bar`
;;; at bare need with no margin at all.
;;;
;;; Part 1 — one bread economy, three shapes at one number, labour from abundant
;;;          to binding:
;;;   I1  abundant: insurance holds ABOVE `lo` (the margin), the bar floor sits AT it
;;;   I2  binding:  insurance erodes its margin and stops at `lo`; never below
;;;   I3  the soft buffer (#:reserve) is shed under the same scarcity — below `lo`
;;;   I4  the ceiling of the band, when given, is respected alongside (a two-sided
;;;       stock band: hold ≥ lo, and ≤ cap — the granary that must not overflow)
;;;   I5  the same reserve as a floor-sided <fragility> record (solve/ingest.scm SIDE)
;;; Part 2 — the same reserve under two futures (solve/robust.scm), held PER SCENARIO:
;;;   R1  the drought year keeps `lo` intact where the soft buffer starves
;;;   R2  the nominal year holds more than the drought year (the margin is what erodes)
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-insurance-reserve.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve robust) (playnet solve plan)
             (playnet vf schemas) (playnet vf beyond scenario)
             (srfi srfi-1)
             (ice-9 format))

;; ══ Part 1: one bread economy, three shapes ═════════════════════════════════
;; grow → bread, 1 kg per unit of work; a farm with one worker whose hours are
;; the only thing that binds. The stock the reserve concerns is bread on hand.
(define LO 120.0) (define HI 140.0) (define ALPHA 0.5) (define W 5.0)   ; tip = 130
(define spatials (list (make-spatial-thing #:id "farm" #:lat 52.5 #:long 13.4)))
(define procs (list (make-recipe-process #:id "grow" #:name "Grow")))
(define flows (list (make-recipe-flow #:id "gw" #:action 'work    #:resource-conforms-to "farming"
                                      #:effort-quantity (make-measure 1.0 %effort-unit)
                                      #:recipe-input-of "grow")
                    (make-recipe-flow #:id "gb" #:action 'produce #:resource-conforms-to "bread"
                                      #:resource-quantity (make-measure 1.0 "kg")
                                      #:recipe-output-of "grow" #:is-primary #t)))
(define farmer (list (make-agent #:id "ann" #:type 'person #:name "Ann" #:primary-location "farm"
                                 #:classified-as '())))
(define skill  (list (make-economic-resource #:id "sk" #:conforms-to "farming" #:classified-as '()
                       #:accounting-quantity (make-measure 1.0 "u") #:onhand-quantity (make-measure 1.0 "u") #:current-location "farm" #:primary-accountable "ann")))
(define G "bread#farm@0")

(define* (bread hours #:key (shape 'insurance) (cap #f))
  (call-with-values
    (lambda ()
      (plan-from-records skill farmer spatials procs flows
        #:periods '(0) #:agent-hours (lambda (a t) hours)
        #:repro-floors (if (eq? shape 'floor)     `((,G . ,LO)) '())
        #:reserve      (if (eq? shape 'reserve)   `((,G . (,LO . 0.05))) '())   ; the soft buffer, its low weight
        #:insurance    (if (eq? shape 'insurance) `((,G ,LO ,HI ,ALPHA ,W)) '())
        #:repro-caps   (if cap `((,G . (,cap . 5.0))) '())))
    (lambda (i c material fill cols x idx nt rep)
      (vector-ref x (hash-ref idx "p|grow|farm@0")))))

(define rows
  (map (lambda (h) (list h (bread h #:shape 'floor) (bread h #:shape 'reserve) (bread h #:shape 'insurance)))
       '(1000.0 300.0 150.0 130.0 122.0)))
(format #t "~%bread on hand by shape (lo ~a, margin to ~a, tip ~a):~%" LO HI (+ LO (* ALPHA (- HI LO))))
(format #t "  hours    bar-floor   soft-reserve   insurance(held)~%")
(for-each (lambda (r) (apply format #t "  ~6,0f   ~9,2f   ~12,2f   ~15,2f~%" r)) rows)

(define (row h) (assv h rows))
(define abundant (row 1000.0)) (define binding (row 122.0))
(format #t "~%── Part 1 assertions ──~%")
(check "I1 abundant labour: insurance holds a MARGIN above lo (≥ 125), the bar floor sits AT lo (≈120)"
       (and (>= (cadddr abundant) 125.0) (< (abs (- (cadr abundant) LO)) 0.5)))
(check "I2 binding labour: insurance erodes toward lo and NEVER below it"
       (and (>= (cadddr binding) (- LO 0.05))
            (< (cadddr binding) (cadddr abundant))))
(check "I2' the erosion is monotone as labour tightens"
       (apply >= (map cadddr rows)))
(check "I3 the soft buffer (#:reserve) is shed under the same scarcity — below lo"
       (< (caddr binding) (- LO 1.0)))
(define capped (bread 1000.0 #:shape 'insurance #:cap 128.0))
;; the same reserve said as a <fragility> whose SIDE is 'floor — one record, the
;; ecological envelope's own, read from the other side (solve/ingest.scm)
(define via-record
  (call-with-values
    (lambda ()
      (plan-from-records skill farmer spatials procs flows
        #:periods '(0) #:agent-hours (lambda (a t) 1000.0)
        #:eco-spec-frag (list (floor-on-good G (list LO HI ALPHA W) "the granary's calamity stock"))))
    (lambda (i c material fill cols x idx nt rep) (vector-ref x (hash-ref idx "p|grow|farm@0")))))
(check "I5 a floor-sided <fragility> on the good is the same reserve as #:insurance"
       (< (abs (- via-record (cadddr abundant))) 1e-6))
(check "I4 with a ceiling too, the stock sits in its band: lo ≤ on-hand < cap"
       (and (>= capped (- LO 0.05)) (< capped 128.0)))

;; ══ Part 2: the reserve under two futures, held per scenario ════════════════
;; One field, planted ONCE (first stage); two crops: A yields high in a normal year
;; and nothing in a drought, B yields modestly in both. A market wants surplus food
;; (a desire), which alone would plant all A. The insurance reserve says: in EVERY
;; future, hold ≥ 1.0 with a margin toward 1.4.
(define fspat (list (make-spatial-thing #:id "field" #:lat 30.0 #:long 78.0)))
(define fres  (list (make-economic-resource #:id "land1" #:conforms-to "land" #:classified-as '()
                      #:accounting-quantity (make-measure 1.0 "ha") #:onhand-quantity (make-measure 1.0 "ha") #:current-location "field")))
(define fprocs (list (make-recipe-process #:id "growA" #:name "Grow A")
                     (make-recipe-process #:id "growB" #:name "Grow B")))
(define fflows
  (list (make-recipe-flow #:id "aL" #:action 'consume #:resource-conforms-to "land"
                          #:resource-quantity (make-measure 1.0 "ha") #:recipe-input-of "growA")
        (make-recipe-flow #:id "aF" #:action 'produce #:resource-conforms-to "food"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "growA"
                          #:is-primary #t)
        (make-recipe-flow #:id "bL" #:action 'consume #:resource-conforms-to "land"
                          #:resource-quantity (make-measure 1.0 "ha") #:recipe-input-of "growB")
        (make-recipe-flow #:id "bF" #:action 'produce #:resource-conforms-to "food"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "growB"
                          #:is-primary #t)))
(define yields '((normal  . (("growA" . 4.0) ("growB" . 1.3)))
                 (drought . (("growA" . 0.0) ("growB" . 1.2)))))
(define scenarios
  (list (make-planning-scenario "normal"  "sc-normal"  0.7 (assq-ref yields 'normal)  "normal year")
        (make-planning-scenario "drought" "sc-drought" 0.3 (assq-ref yields 'drought) "drought year")))
(define FG "food#field@0")

(define* (plant #:key (shape 'insurance))
  (call-with-values
    (lambda ()
      (plan-robust-from-records fres '() fspat fprocs fflows
        #:scenarios scenarios #:first-stage-procs '("growA" "growB") #:per-agent? #f
        #:demand `((,FG . 5.0))
        #:reserve   (if (eq? shape 'reserve)   `((,FG . (1.0 . 0.05))) '())
        #:insurance (if (eq? shape 'insurance) `((,FG 1.0 1.4 0.5 5.0)) '())))
    (lambda (x fs rc n ns . _)
      (let ((a (first-stage-activity x fs "growA")) (b (first-stage-activity x fs "growB")))
        (define (food-in sc) (let ((y (assq-ref yields sc)))
                               (+ (* a (assoc-ref y "growA")) (* b (assoc-ref y "growB")))))
        (list a b (food-in 'normal) (food-in 'drought))))))

(define ins (plant #:shape 'insurance))
(define res (plant #:shape 'reserve))
(format #t "~%two futures, one planting (A high/none, B modest/modest); reserve lo 1.0 margin→1.4:~%")
(format #t "  insurance(held):  A=~,3f B=~,3f  → normal ~,3f  drought ~,3f~%" (car ins) (cadr ins) (caddr ins) (cadddr ins))
(format #t "  soft (#:reserve): A=~,3f B=~,3f  → normal ~,3f  drought ~,3f~%" (car res) (cadr res) (caddr res) (cadddr res))
(format #t "~%── Part 2 assertions ──~%")
(check "R1 insurance: the drought year keeps lo intact (≥ 1.0)"
       (>= (cadddr ins) 0.99))
(check "R1' the soft buffer starves in the drought (< 1.0) — it is a desire, p-weighted and shed"
       (< (cadddr res) 0.99))
(check "R1'' held keeps a MARGIN even in the drought (> lo): the shape survives the scenario assembly (a bar would sit at lo exactly)"
       (> (cadddr ins) 1.02))
(check "R2 insurance: the nominal year holds more than the drought year — the margin is what erodes"
       (> (caddr ins) (cadddr ins)))

(check-done "insurance reserve")
