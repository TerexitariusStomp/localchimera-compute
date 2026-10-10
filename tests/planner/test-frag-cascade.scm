;;; test-frag-cascade.scm — the Leontief cascade (Space coordinate): coupled ecological agents.
;;;
;;; Slice 3. Ecological agents stress each other: drawing agent j degrades agent k. The frag barrier
;;; reads agent k's EFFECTIVE pressure p = (I−C)^{-1}·draw, not its own draw alone. So a draw on a
;;; COUPLED agent raises k's pull and out-competes desire that nears k's tip — the same propagation
;;; operator (Leontief inverse) the planner already runs for the crystallized-SNLT value rollup.
;;;
;;; Two agents: `forest` (frag-capped, tip 10) and `soil`. Drawing soil stresses forest by 0.5
;;; (C[forest][soil]=0.5), so forest's effective pressure = timber + 0.5·grain. With strong demand for
;;; both timber (draws forest) and grain (draws soil), the cascade routes soil's draw into forest's
;;; budget. Proves: (a) effective pressure stays below the tip (never crossed); (b) coupling SUPPRESSES
;;; timber vs the uncoupled solve (soil's stress eats forest's headroom); (c) uncoupled, forest is
;;; limited by its own draw only and soil draws freely.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/planner/test-frag-cascade.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver))

(define s-tip 10.0)   ; forest tip = quantile_0.5 of [8,12]
(define cpl   0.5)    ; drawing soil stresses forest by 0.5
(define (recipes)
  (compile-recipe
    (list (rp "log" "Log") (rp "till" "Till"))
    (list (out "a1" "timber" 1.0 "log") (wrk "a2" 0.1 "log") (in "a3" "forest" 1.0 "log")    ; log draws forest 1:1
          (out "b1" "grain" 1.0 "till") (wrk "b2" 0.1 "till") (in "b3" "soil" 1.0 "till"))))  ; till draws soil 1:1

(define (run couple?)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (recipes))
  (hash-set! *A* (cell "town" 0) 10000.0)
  (hash-set! *cap* (lg "soil" (cell "town" 0)) 100.0)                              ; soil available (loose, non-binding)
  (hash-set! *frag-cap* (lg "forest" (cell "town" 0)) (list 8.0 12.0 0.5 50.0))    ; forest fragility, tip 10
  (hash-set! *demand* (lg "timber" (cell "town" 0)) 8.0)
  (hash-set! *demand* (lg "grain"  (cell "town" 0)) 8.0)
  (when couple? (hash-set! *eco-couple* "forest" (list (cons "soil" cpl))))        ; C[forest][soil] = 0.5
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
             (timber (V "p|log|town@0")) (grain (V "p|till|town@0")))
        (list timber grain)))))

(define free (run #f))   ; uncoupled: forest limited by its own draw only
(define cpld (run #t))   ; coupled: forest sees timber + 0.5·grain
(define (tmb r)(first r))(define (grn r)(second r))
(define eff-free (+ (tmb free) (* cpl (grn free))))   ; what forest pressure WOULD be (not enforced when uncoupled)
(define eff-cpld (+ (tmb cpld) (* cpl (grn cpld))))   ; the ENFORCED effective pressure when coupled

(format #t "~%── Leontief cascade · forest tip=~a, drawing soil stresses forest by ~a ──~%" s-tip cpl)
(format #t "  uncoupled: timber ~,3f  grain ~,3f   (forest pressure would be ~,3f)~%" (tmb free) (grn free) eff-free)
(format #t "  coupled:   timber ~,3f  grain ~,3f   (forest EFFECTIVE pressure ~,3f)~%" (tmb cpld) (grn cpld) eff-cpld)

(let* ((c1 (< eff-cpld s-tip))                          ; effective pressure never crosses the tip
       (c2 (> (- s-tip eff-cpld) 0.05))                 ; …eased off before it (real margin)
       (c3 (< (tmb cpld) (- (tmb free) 0.5)))           ; coupling SUPPRESSES timber (soil's stress eats forest headroom)
       (c4 (< (tmb free) s-tip))                        ; uncoupled: forest still limited by its own draw
       (c5 (> eff-free s-tip))                          ; …and that uncoupled draw WOULD have breached the tip via the cascade
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] coupled effective pressure eases off before the tip (~,3f < ~a)~%" (if (and c1 c2) "✓" "✗") eff-cpld s-tip)
  (format #t "  [~a] coupling suppresses timber: ~,3f (coupled) < ~,3f (uncoupled)~%" (if c3 "✓" "✗") (tmb cpld) (tmb free))
  (format #t "  [~a] uncoupled forest is limited only by its own draw (~,3f < ~a)~%" (if c4 "✓" "✗") (tmb free) s-tip)
  (format #t "  [~a] …and that draw WOULD breach the tip through the cascade (~,3f > ~a)~%" (if c5 "✓" "✗") eff-free s-tip)
  (format #t "~%  ~a a frag agent reads its effective pressure p=(I−C)^{-1}·draw — stressing one agent raises a coupled agent's pull~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
