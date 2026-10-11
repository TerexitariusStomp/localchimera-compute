;;; test-stone-paper-siting.scm — which binder a hub gets is a question about DISTANCE
;;;
;;; One compounding line and one Regeneration Hub, solved at a range of distances.
;;; The hub wants 1000 kg of writing sheet a period and carries an obligation for
;;; every kilo of it: an end of life, discharged. Three routes are open, and all
;;; three stay open whatever the grade:
;;;
;;;   HDPE grade + take-back   sheet home again → regrind → 0.98 kg of compounder feed
;;;   HDPE grade + landfill    buried locally, at a price
;;;   bio grade   + compost    windrowed on site → 0.65 kg of calcitic soil residue
;;;
;;; Nothing in the model prefers a grade. The bio binder costs three times HDPE's
;;; labour per kg and the bio compound carries 33% resin against HDPE's 18%, so the
;;; bio sheet leaves the line dearer every single time. What it does not carry is a
;;; return leg. Take-back pays the road twice — out with the sheet, home with the
;;; used sheet — and that second crossing is the only cost in the whole model that
;;; separates the two grades by distance.
;;;
;;; Each grade is planned to its own optimum at three ranges, and the two optima are
;;; compared on the planner's own objective. The HDPE plan's cost RISES with range
;;; and the bio plan's stays flat, so the ordering turns over once: past a radius the
;;; bio grade is the cheaper plan, dearer resin and all. Each plan also picks its own
;;; end of life unprompted — the HDPE plan sends most of its sheet home to be
;;; reground, the bio plan windrows every kilo of it, and burial stays open the whole
;;; way and is declined.
;;;
;;; WHAT TO READ, AND WHAT NOT TO. The point is the SHAPE: "biodegradable is better"
;;; is not a fact about a polymer, it is a fact about how far a hub sits from a
;;; compounder. Three things keep the numbers themselves from being quotable:
;;;
;;;   • Total plan labour carries a large COMMON residue. Every plan here settles
;;;     near 179 h — about 90% of the labour on hand — because the log barrier pushes
;;;     non-binding activity up until something stops it. Differences between two
;;;     plans mean something; the levels do not.
;;;   • That residue DAMPS the distance response. The coefficients say the HDPE plan
;;;     should gain 0.04 h per km per tonne, ~79 h across the range swept here; the
;;;     solve shows ~6 h. Direction and monotonicity survive, magnitude does not, and
;;;     the turnover therefore lands far inside the ~885 km the coefficients imply.
;;;   • At the near range the two plans are a TIE inside that noise (a tenth of an
;;;     hour apart), so nothing below asserts a winner there.
;;;
;;; The labour coefficients are illustrative placeholders chosen to be the right order
;;; and the right ratio (biopolymer ~3× HDPE per kg, burial dear, windrowing cheap);
;;; the MASS ratios are the real ones, out of recipes/stone-paper.scm and
;;; CN103131145B. A crossover radius worth quoting to anyone needs costed local
;;; figures in place of these AND a solve read closer to its vertex than this one.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-stone-paper-siting.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas))

;; ── coefficients ────────────────────────────────────────────────────────────
(define RESIN-H  0.02)     ; h/kg — HDPE resin
(define RESIN-B  0.06)     ; h/kg — biodegradable polyester: ~3× HDPE, PBS/PLA-PBAT/PHA
(define ROAD     0.00002)  ; h/kg/km — one crossing of a kilometre with a kilo aboard
(define BURY     0.02)     ; h/kg — landfill: haulage, tipping, the long tail of a hole
(define WINDROW  0.001)    ; h/kg — turning a heap
(define TAKEBACK 0.001)    ; h/kg — baling used sheet for the road home
(define RECLAIM  0.002)    ; h/kg — granulating it back to compounder feed
(define SHEET    0.005)    ; h/kg — compound, extrude, stretch, convert
(define FEEDWORK 0.001)    ; h/kg — batching virgin feed

;; the two grades, at the mass ratios the recipes carry
(define H-RESIN 0.18) (define H-MIN 0.80) (define H-ADD 0.02)   ; 80 / 18 / 2
(define B-RESIN 0.33) (define B-MIN 0.65) (define B-ADD 0.02)   ; 65 / 33 / 2  (CN103131145B)
(define RECOVERY 0.98)   ; kg feed per kg used sheet reground
(define RESIDUE  0.65)   ; kg calcitic residue per kg bio sheet composted

(define NEED 1000.0)     ; kg of sheet each hub writes on per period

;; ── flow builders the shared ones don't cover ───────────────────────────────
(define (usef id spec hrs proc)   ; USE a durable → consume its per-period service Svc|spec
  (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec #:resource-quantity (make-measure 1.0 %count-unit)
                    #:effort-quantity (make-measure hrs %effort-unit) #:recipe-input-of proc))
(define (pick id spec proc)
  (make-recipe-flow #:id id #:action 'pickup #:resource-conforms-to spec
                    #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of proc))
(define (drop id spec proc)
  (make-recipe-flow #:id id #:action 'dropoff #:resource-conforms-to spec
                    #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of proc))

;; ── the templates ───────────────────────────────────────────────────────────
;; `plant` is the line itself — compounder, flat die, stretcher, converter as one
;; durable. Its service is capped to 0 at the hubs, which is the whole geography of
;; the problem: a hub can turn a windrow, and cannot run a twin-screw compounder.
(define (mk-templates)
  (compile-recipe
    (list (rp "resin-h"  "Make HDPE resin")
          (rp "resin-b"  "Make biodegradable polyester")
          (rp "feed"     "Batch virgin compounder feed")
          (rp "sheet-h"  "Make stone paper, HDPE grade")
          (rp "sheet-b"  "Make stone paper, bio grade")
          (rp "ship-h"   "Ship HDPE sheet to a hub")
          (rp "ship-b"   "Ship bio sheet to a hub")
          (rp "write-h"  "Write on HDPE sheet")
          (rp "write-b"  "Write on bio sheet")
          (rp "compost"  "Windrow used bio sheet")
          (rp "landfill" "Bury used HDPE sheet")
          (rp "takeback" "Bale used HDPE sheet for the road home")
          (rp "return"   "Carry used sheet back to the line")
          (rp "reclaim"  "Granulate returned sheet into feed")
          (rp "certify"  "Carry the reclamation certificate to the hub")
          (rp "discharge" "Discharge the hub's end-of-life duty against a certificate"))
    (list
      ;; resin, two ways
      (out "r1" "resin-h" 1.0 "resin-h") (wrk "r2" RESIN-H "resin-h")
      (out "r3" "resin-b" 1.0 "resin-b") (wrk "r4" RESIN-B "resin-b")
      ;; virgin feed for the HDPE grade — 80 / 18 / 2
      (out "f1" "feed" 1.0 "feed") (in "f2" "resin-h" H-RESIN "feed")
      (in "f3" "mineral" H-MIN "feed") (in "f4" "additive" H-ADD "feed")
      (wrk "f5" FEEDWORK "feed") (usef "f6" "plant" 1.0 "feed")
      ;; sheet, two grades, one line
      (out "h1" "sheet-h" 1.0 "sheet-h") (in "h2" "feed" 1.0 "sheet-h")
      (wrk "h3" SHEET "sheet-h") (usef "h4" "plant" 1.0 "sheet-h")
      (out "b1" "sheet-b" 1.0 "sheet-b") (in "b2" "resin-b" B-RESIN "sheet-b")
      (in "b3" "mineral" B-MIN "sheet-b") (in "b4" "additive" B-ADD "sheet-b")
      (wrk "b5" SHEET "sheet-b") (usef "b6" "plant" 1.0 "sheet-b")
      ;; the road out — identical for both grades, so it biases neither
      (pick "s1" "sheet-h" "ship-h") (drop "s2" "sheet-h" "ship-h") (wrk "s3" ROAD "ship-h")
      (pick "s4" "sheet-b" "ship-b") (drop "s5" "sheet-b" "ship-b") (wrk "s6" ROAD "ship-b")
      ;; Writing on it leaves used sheet behind, by grade — and happens where the
      ;; school is. Svc|school is what pins that down, and it earns its place: with
      ;; writing possible at the line too, the line writes on its own sheet purely to
      ;; mint reclamation certificates and posts them to the hub, which discharges its
      ;; duty on paper without sending a kilo home.
      (out "w1" "written" 1.0 "write-h") (out "w2" "used-h" 1.0 "write-h")
      (in  "w3" "sheet-h" 1.0 "write-h") (usef "w7" "school-h" 1.0 "write-h")
      (out "w4" "written" 1.0 "write-b") (out "w5" "used-b" 1.0 "write-b")
      (in  "w6" "sheet-b" 1.0 "write-b") (usef "w8" "school-b" 1.0 "write-b")
      ;; ── the three end-of-life routes ──
      ;; compost: on site, and the 65% that was always mineral comes back as lime
      (out "c1" "discharged" 1.0 "compost") (out "c2" "residue" RESIDUE "compost")
      (in  "c3" "used-b" 1.0 "compost") (wrk "c4" WINDROW "compost")
      (usef "c5" "windrow" 1.0 "compost")
      ;; landfill: on site, at a price, and nothing comes back
      (out "l1" "discharged" 1.0 "landfill") (in "l2" "used-h" 1.0 "landfill")
      (wrk "l3" BURY "landfill")
      ;; take-back: bale it, carry it home, regrind it into feed — and the duty is
      ;; discharged only when the certificate for that reclamation reaches the hub
      (out "t1" "returnable" 1.0 "takeback") (in "t2" "used-h" 1.0 "takeback")
      (wrk "t3" TAKEBACK "takeback")
      (pick "n1" "returnable" "return") (drop "n2" "returnable" "return")
      (wrk "n3" ROAD "return")
      (out "k1" "feed" RECOVERY "reclaim") (out "k2" "cert" 1.0 "reclaim")
      (in  "k3" "returnable" 1.0 "reclaim") (wrk "k4" RECLAIM "reclaim")
      (usef "k5" "plant" 1.0 "reclaim")
      (pick "e1" "cert" "certify") (drop "e2" "cert" "certify")
      (out "d1" "discharged" 1.0 "discharge") (in "d2" "cert" 1.0 "discharge"))))

;; ── the geography ───────────────────────────────────────────────────────────
;; Places sit on a meridian so a degree of latitude is ~111 km of road.
;; ONE hub per solve, and that is load-bearing. A reclamation certificate is
;; fungible: put two hubs in one solve and the far one discharges its duty against
;; certificates earned by the near one's returns, writes on HDPE, and never sends a
;; kilo home — which is exactly how certificate-based take-back leaks in the world,
;; and exactly what this scenario is not about. One hub to a solve makes every
;; certificate the hub's own.
;;
;; GRADE is 'hdpe or 'bio: the school's service comes in that grade only, so each
;; run is one grade planned to ITS OWN optimum, with every end-of-life route that
;; grade could use still open to it. What comes back is the plan's TOTAL LABOUR —
;; the planner's own objective — and the comparison between two optima is the
;; instrument. Reading the grade MIX out of a single solve does not work here: the
;; two plans differ by ~22 h on a horizon where nothing else binds, and an
;; interior-point solution that far from a vertex splits the mix on its centering
;; rather than on the road. Comparing optima asks the same question of the same
;; objective and gets an answer that holds still.
(define (run hub-km grade)
  (declare-world! #:places (list (list "line" 0.0 0.0) (list "hub" (/ hub-km 111.0) 0.0))   ; a degree of latitude ≈ 111 km
                  #:templates (mk-templates))
  (for-each (lambda (p)
              (hash-set! *A* (cell p 0) 100.0)                     ; a real week of hands: enough for any one plan, scarce enough that the free-time term bites
              (hash-set! *cap* (lg "Svc|windrow" (cell p 0)) 1e6)  ; anyone can turn a heap
              (hash-set! *cap* (lg "Svc|plant" (cell p 0))
                         (if (string=? p "line") 1e6 0.0))         ; the compounder exists in ONE place
              ;; …and the pupils in the OTHER, in a finite number: the school's service
              ;; is capped at exactly what the hub writes, so the plan settles at NEED
              ;; instead of sprawling on the barrier's centering. The grade under test
              ;; is the grade the school has sheet in.
              (let ((hub? (not (string=? p "line"))))
                (hash-set! *cap* (lg "Svc|school-h" (cell p 0))
                           (if (and hub? (eq? grade 'hdpe)) NEED 0.0))
                (hash-set! *cap* (lg "Svc|school-b" (cell p 0))
                           (if (and hub? (eq? grade 'bio)) NEED 0.0))))
            *places*)
  ;; Everything meant to be ABUNDANT is set far above any plan's draw, so its log
  ;; barrier stays flat. This matters: at a snug cap the barrier reads as a shadow
  ;; cost, and the two grades draw these resources very unevenly — the bio grade
  ;; takes 0.65 kg of mineral per kg of sheet against the HDPE grade's 0.016 (regrind
  ;; supplies the rest), while the HDPE grade passes through the line twice to the
  ;; bio grade's once. Snug caps price those differences and drown the road.
  (hash-set! *init* (lg "mineral" (cell "line" 0)) 1e6)
  (hash-set! *init* (lg "additive" (cell "line" 0)) 1e6)
  (hash-set! *demand* (lg "written" (cell "hub" 0)) NEED)          ; the hub writes
  (hash-set! *init* (lg "discharged" (cell "hub" 0)) (- NEED))     ; …and owes an end of life for every kilo
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                       (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (at (lambda (key) (let ((i (hash-ref idx key #f))) (if i (vector-ref x i) 0.0))))
             (hours (fold (lambda (p a) (+ a (* (cdr p) (vector-ref x (car p))))) 0.0 labform)))
        (cons hours at)))))

(define (hours r) (car r))
(define (act r key) ((cdr r) key))
(define (cheaper h b) (if (< (hours h) (hours b)) 'HDPE 'bio))

;; ── each grade, planned to its own optimum, at three ranges ─────────────────
;; Predicted from the coefficients: the HDPE plan costs 8.09 + 0.04·d hours per
;; 1000 kg and the bio plan 25.8 + 0.02·d, so they meet near 885 km.
(define RANGES '(20.0 900.0 2000.0))
(define runs (map (lambda (d) (list d (run d 'hdpe) (run d 'bio))) RANGES))

(format #t "~%── one line, one hub, 1000 kg of sheet a period. Total plan labour: ──~%")
(format #t "  ~10a ~14a ~14a ~10a~%" "range" "HDPE grade" "bio grade" "cheaper")
(for-each (lambda (r)
            (let ((d (first r)) (h (second r)) (b (third r)))
              (format #t "  ~6,0f km  ~12,1f h ~12,1f h   ~a~%"
                      d (hours h) (hours b) (cheaper h b))))
          runs)

(define near-h (second (first runs)))  (define near-b (third (first runs)))
(define far-h  (second (last runs)))   (define far-b  (third (last runs)))

(format #t "~%── what each plan actually does with the sheet ──~%")
(format #t "  ~22a ~11a ~11a ~9a~%" "plan" "returned" "composted" "buried")
(for-each (lambda (row)
            (format #t "  ~22a ~11,1f ~11,1f ~9,1f~%" (car row)
                    (act (cdr row) "p|takeback|hub@0")
                    (act (cdr row) "p|compost|hub@0")
                    (act (cdr row) "p|landfill|hub@0")))
          (list (cons "HDPE @   20 km" near-h) (cons "bio  @   20 km" near-b)
                (cons "HDPE @ 2000 km" far-h)  (cons "bio  @ 2000 km" far-b)))

;; Claims stated against what survives the residue: the SLOPES, their ordering, and
;; the end-of-life each plan reaches for. The near-range comparison is reported and
;; deliberately not asserted — a tenth of an hour is not a result.
(define h-costs (map (lambda (r) (hours (second r))) runs))
(define b-costs (map (lambda (r) (hours (third r))) runs))
(define (rising? xs) (every (lambda (a b) (< a b)) (drop-right xs 1) (cdr xs)))
(define (spread xs) (- (apply max xs) (apply min xs)))

(let* ((c1 (rising? h-costs))                                     ; the road falls on the take-back plan…
       (c2 (< (spread b-costs) (* 0.25 (spread h-costs))))        ; …and barely on the compost plan
       (c3 (> (- (hours far-h) (hours far-b)) 2.0))               ; far out, bio wins by a real margin
       (c4 (> (act near-h "p|takeback|hub@0") (* 0.5 NEED)))      ; the HDPE plan reclaims, unprompted
       (c5 (> (act far-b "p|compost|hub@0") (* 0.9 NEED)))        ; the bio plan windrows, unprompted
       (c6 (and (< (act far-b "p|landfill|hub@0") 1.0)            ; burial stays open the whole way, and loses
                (< (act near-b "p|landfill|hub@0") 1.0)))
       (c7 (rising? (map (lambda (r) (- (hours (second r)) (hours (third r)))) runs)))   ; the bio plan's margin only widens with range
       (ok (and c1 c2 c3 c4 c5 c6 c7)))
  (format #t "~%  [~a] the road falls on the TAKE-BACK plan: its cost rises with range (~,1f → ~,1f h)~%"
          (if c1 "✓" "✗") (first h-costs) (last h-costs))
  (format #t "  [~a] …and barely on the compost plan, which has no return leg (spread ~,1f h vs ~,1f h)~%"
          (if c2 "✓" "✗") (spread b-costs) (spread h-costs))
  (format #t "  [~a] so far from the line the bio plan is cheaper, dearer resin and all (~,1f h vs ~,1f h)~%"
          (if c3 "✓" "✗") (hours far-b) (hours far-h))
  (format #t "  [~a] the HDPE plan reaches for reclamation unprompted    (~,0f kg home)~%"
          (if c4 "✓" "✗") (act near-h "p|takeback|hub@0"))
  (format #t "  [~a] the bio plan reaches for the windrow unprompted     (~,0f kg of ~,0f)~%"
          (if c5 "✓" "✗") (act far-b "p|compost|hub@0") NEED)
  (format #t "  [~a] burial is open at every range, and the bio plan never buries a kilo~%" (if c6 "✓" "✗"))
  (format #t "  [~a] the compost plan's margin over the take-back plan widens with every range~%" (if c7 "✓" "✗"))
  (format #t "~%  (near range is a TIE inside the residue — ~,1f h vs ~,1f h — and is not claimed)~%"
          (hours near-h) (hours near-b))
  (format #t "~%  ~a same model, same routes: distance prices the return leg, and the binder follows~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
