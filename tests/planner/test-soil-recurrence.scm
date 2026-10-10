;;; test-soil-recurrence.scm — the soil-condition recurrence on the REAL Doon farm.
;;;
;;; navdanya-farm.scm long carried a comment: the biofertilisers are "NOT yet in the
;;; yield model — that needs the soil-condition recurrence". This is that recurrence,
;;; made real. The farm's topsoil is a REGENERATING STOCK (planner/formulas/stocks.scm): its
;;; fertility starts at the SoilGrids state (SOC 34.3 g/kg), CANNOT fall below the
;;; degradation floor (20 g/kg), is DRAWN as crops grow, and is RESTORED by a legume
;;; (biological N-fixation — a crop that FEEDS while it rebuilds soil).
;;;
;;;   SOC[t+1] = SOC[t] − draw(cropping) + restore(legume),   SOC ≥ degradation floor
;;;
;;; A household's subsistence floor is due EVERY season, for 8 seasons. Growing only
;;; RICE (a heavy feeder, the Green-Revolution monoculture) mines the topsoil — and
;;; once it hits the degradation floor the farm can no longer feed the household. Let
;;; the planner also grow PULSES (a legume, lower-yielding but soil-restoring) and it
;;; DISCOVERS crop rotation: it mixes in pulses to hold the soil up and feeds the
;;; household every season. The rotation is not a rule we wrote — it is what staying
;;; feasible across deep time COSTS, and the planner finds it.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-soil-recurrence.scm

(use-modules (srfi srfi-1) (ice-9 format))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        (error "sibling not found" f)))
(use-modules (playnet solve engine)
             (playnet vf schemas)
             (playnet vf formulas stocks)
             (playnet knowledge worlds bioregions)
             (playnet knowledge dsl shorthand))
;; engine/robust.scm arrives with the engine — (playnet solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).
(use-modules (playnet knowledge worlds doon-valley))
(primitive-load (sibling "../../module/playnet/knowledge/recipes/navdanya-farm.scm"))

(define SEASONS '(0 1 2 3 4 5 6 7))
(define LAND 2.0)                                        ; hectares croppable per season
(define HH 29)                                           ; a ~29-person community on the 2 ha (intensive smallholding)
(define FLOOR (navdanya-food-floor HH))                 ; its subsistence floor, kg/season (≈2610 — a level a legume rotation CAN sustain)
(define place "doon-farm")

;; the DRAWABLE fertility = SOC above the degradation floor; ≥0 ⇒ SOC ≥ floor.
(define DRAWABLE (* (- *navdanya-soil-init* *navdanya-soil-floor*) LAND))    ; (34.3−20)·2 = 28.6
(define rice-y  (assoc-ref *doon-valley-crop-yields* "rice"))
(define pulse-y (assoc-ref *doon-valley-crop-yields* "pulses"))

(define spatials (list (place* place #:name "Navdanya-style farm" #:lat 30.32 #:lon 78.03)))
(define land-res (er "land" "land" #f #:place place #:qty 100.0 #:unit "ha" #:tags '("stationary")))

;; rice: 1 ha + draw 2.4 fertility → rice yield.   pulses: 1 ha, RESTORE 1.2 fertility → pulse yield.
(define rice-proc  (rp* "rice"   "Grow rice"))
(define pulse-proc (rp* "pulses" "Grow pulses"))
(define (grow-flows crop proc yield)
  (let ((draw (navdanya-crop-draw crop)))
    (append
     (list (use* (string-append crop "-l") "land" proc #f #:qty 1.0 #:unit "ha")
           (out* (string-append crop "-f") "food" yield proc))
     (if (>= draw 0.0)
         (list (stock-draw-flow    (string-append crop "-s") "soil-fertility" draw proc "cropping draws fertility" "idx"))
         (list (stock-restore-flow (string-append crop "-s") "soil-fertility" (- draw) proc "legume fixes nitrogen" "idx"))))))

(define (run rotate?)                                    ; rotate? ⇒ pulses also available
  (clear-regenerating-stocks!)
  (register-regenerating-stock! (make-regenerating-stock "soil-fertility" "Topsoil fertility (SOC over floor)" place DRAWABLE "idx"))
  (let* ((procs (if rotate? (list rice-proc pulse-proc) (list rice-proc)))
         (flows (append (grow-flows "rice" "rice" rice-y)
                        (if rotate? (grow-flows "pulses" "pulses" pulse-y) '())))
         (resources (cons land-res (regenerating-stock-resources)))
         (storables (regenerating-stock-storables))      ; ("soil-fertility") — carries in time; food does NOT
         (eco-caps (map (lambda (t) (cons (format #f "Svc|land#~a@~a" place t)
                                          (stock->flow LAND t)))   ; ha × the season's hours — capacity is a flow
                         SEASONS))
         (floors   (map (lambda (t) (cons (format #f "food#~a@~a" place t) FLOOR)) SEASONS)))
    (call-with-values
      (lambda () (plan-from-records resources '() spatials procs flows
                   #:periods SEASONS #:storable storables #:eco-caps eco-caps #:repro-floors floors #:per-agent? #f))
      (lambda (ints coms material fill cols x idx ntot report)
        (define (vof k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
        (define rice-ha  (map (lambda (t) (vof (format #f "p|rice|~a@~a" place t))) SEASONS))
        (define pulse-ha (map (lambda (t) (vof (format #f "p|pulses|~a@~a" place t))) SEASONS))
        (define food (map (lambda (t r p) (+ (* r rice-y) (* p pulse-y))) SEASONS rice-ha pulse-ha))
        ;; SOC trajectory (g/kg): floor + drawable-remaining/LAND, opening each season
        (define soc
          (let loop ((ts SEASONS) (draw 0.0) (acc '()))
            (if (null? ts) (reverse acc)
                (let* ((t (car ts))
                       (d (- (* (list-ref rice-ha t)  (navdanya-crop-draw "rice"))
                             (* (list-ref pulse-ha t) (- (navdanya-crop-draw "pulses")))))
                       (soc-now (+ *navdanya-soil-floor* (/ (- DRAWABLE draw) LAND))))
                  (loop (cdr ts) (+ draw d) (cons soc-now acc))))))
        (list rice-ha pulse-ha food soc
              (length (filter (lambda (f) (>= f (* 0.98 FLOOR))) food)))))))   ; seasons fed

(define mono (run #f))
(define rota (run #t))
(define (fed r) (list-ref r 4))
(define (soc r) (cadddr r))
(define (decline r) (- (car (soc r)) (last (soc r))))               ; SOC lost over the 8 seasons
(define (rate r) (/ (decline r) (- (length SEASONS) 1)))            ; g/kg lost per season
;; soil-life: seasons of feeding still banked before the soil hits its floor, at
;; this decline rate. A mined soil has few; a tended one, effectively unbounded.
(define (soil-life r) (if (< (rate r) 0.06) 999.0 (/ (- (last (soc r)) *navdanya-soil-floor*) (rate r))))

(format #t "~%── a community floor of ~,0f kg every season, 8 seasons; topsoil SOC starts 34.3, floor 20 (g/kg) ──~%" FLOOR)
(format #t "  RICE MONOCULTURE:  rice ha/season = ~a~%" (map (lambda (h) (/ (round (* 100 h)) 100.0)) (car mono)))
(format #t "                     SOC (g/kg)     = ~a~%" (map (lambda (s) (/ (round (* 10 s)) 10.0)) (soc mono)))
(format #t "                     mines ~,1f g/kg over 8 seasons → ~,0f seasons of soil-life left~%" (decline mono) (soil-life mono))
(format #t "  RICE + PULSES:     rice ha = ~a~%" (map (lambda (h) (/ (round (* 100 h)) 100.0)) (car rota)))
(format #t "                     pulse ha= ~a  → the ROTATION the planner discovered~%" (map (lambda (h) (/ (round (* 100 h)) 100.0)) (cadr rota)))
(format #t "                     SOC (g/kg)= ~a~%" (map (lambda (s) (/ (round (* 10 s)) 10.0)) (soc rota)))
(format #t "                     mines only ~,1f g/kg → ~a soil-life~%" (decline rota)
        (if (>= (soil-life rota) 999.0) "effectively UNBOUNDED" (format #f "~,0f seasons" (soil-life rota))))

(define *pass* 0) (define *fail* 0)
(define (check name ok) (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
                            (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(format #t "~%── assertions ──~%")
(check "monoculture MINES the topsoil steadily (SOC falls season to season)"
       (and (> (decline mono) 5.0)
            (> (car (soc mono)) (cadr (soc mono))) (> (cadr (soc mono)) (caddr (soc mono)))))
(check "SOC never crosses the degradation floor (the ≥-floor gate holds)"
       (>= (apply min (soc mono)) (- *navdanya-soil-floor* 0.5)))
(check "both plans feed the community every season (the floor is met)"
       (and (= (fed mono) 8) (= (fed rota) 8)))
(check "with a legume available the planner DISCOVERS rotation (pulses > 0)"
       (> (apply + (cadr rota)) 0.3))
(check "rotation nearly HALTS the decline (its mining rate is a fraction of the monoculture's)"
       (< (rate rota) (* 0.5 (rate mono))))
(check "…so it banks far more soil-life — mono is on borrowed time, rotation is not (the payoff)"
       (> (soil-life rota) (* 2.0 (soil-life mono))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  Soil-condition recurrence on the real Doon farm: rotation EMERGES.~%  All ~a checks passed.~%" *pass*)
    (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)))
(format #t "════════════════════════════════════════════~%")
(when (> *fail* 0) (exit 1))
