;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-frag-catalogue.scm — the real catalogue, end to end: governance figures → solver limits.
;;;
;;; The fragility catalogue (eco-catalogue.scm) holds REAL planetary-boundary AND climate-tipping-point
;;; figures (Richardson et al. 2023; Armstrong McKay et al. 2022), custodied by the tension-registry.
;;; catalogue->policy is the attenuated solver view — the planner's (eco-spec-frag eco-budget eco-couple)
;;; lists. This drives those figures through a real solve and checks they actually bind.
;;;
;;; The headline this test exercises: CLIMATE is a CASCADE. The federation draws ONE flux — co2 — and the
;;; same draw stresses TWO driven states through the coupling graph:
;;;   • warming (°C)            = co2 × TCRE(0.00045)   — tipping-point cluster, tip 0.2°C ⇒ co2 < ~444 GtCO2
;;;   • ocean-acidification (Ω) = co2 × 0.00027         — aragonite wall,        tip 0.05  ⇒ co2 < ~185 GtCO2
;;; so ocean acidification is the TIGHTER wall and binds first — two planetary frameworks, one frag, one draw.
;;; Plus the nitrogen RATE boundary ([62,82] Tg/yr, α=0.5 ⇒ tip 72) caps per-period N.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-catalogue.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver))   ; tests/ → planner dir
(use-modules (playnet knowledge catalogues eco))

(define ocean-co2-tip (/ 0.05 0.00027))  ; aragonite headroom 0.05 Ω / (Ω per GtCO2)  ≈ 185.2 — the BINDING wall
(define warm-co2-tip  (/ 0.2  0.00045))  ; warming headroom 0.2°C / TCRE              ≈ 444.4 — slacker
(define n-tip   72.0)                     ; quantile_0.5(62,82) — recoverable ⇒ central
(define (recipes)
  (compile-recipe
    (list (rp "emit" "Emit") (rp "fert" "Fertilize"))
    (list (out "a1" "widget" 1.0 "emit") (wrk "a2" 0.1 "emit") (in "a3" "co2" 1.0 "emit")
          (out "b1" "grain" 1.0 "fert") (wrk "b2" 0.1 "fert") (in "b3" "nitrogen" 1.0 "fert"))))

;; apply the catalogue's solver policy to the planner's eco-* state
(define (apply-policy!)
  (call-with-values (lambda () (catalogue->policy *planetary-catalogue*))
    (lambda (rates budgets couples)
      (for-each (lambda (e) (hash-set! *frag-spec* (car e) (cdr e))) rates)
      (for-each (lambda (e) (hash-set! *frag-budget* (car e) (cdr e))) budgets)
      (for-each (lambda (e) (hash-set! *eco-couple* (car e)
                              (cons (cons (cadr e) (caddr e)) (hash-ref *eco-couple* (car e) '())))) couples)
      (list (length rates) (length budgets) (length couples)))))

(declare-world! #:places '(("town" 0.0 0.0)) #:templates (recipes))
(hash-set! *A* (cell "town" 0) 1000000.0)
(define shape (apply-policy!))                                  ; (n-rates n-budgets n-couples)
(hash-set! *demand* (lg "widget" (cell "town" 0)) 1000.0)       ; want well past the climate walls
(hash-set! *demand* (lg "grain"  (cell "town" 0)) 1000.0)       ; …and past the nitrogen rate
(define-values (co2 nitro)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (values (V "p|emit|town@0") (V "p|fert|town@0"))))))
(define warming  (* 0.00045 co2))   ; the driven states the cascade produces from the co2 draw
(define omega    (* 0.00027 co2))

(format #t "~%── the real catalogue, end to end (climate as a cascade) ──~%")
(format #t "  policy shape: ~a rate boundaries, ~a budgets, ~a couplings~%" (first shape) (second shape) (third shape))
(format #t "  co2 draw   ~,2f   → warming ~,4f°C (tip 0.2)   ocean Ω-draw ~,4f (tip 0.05)~%" co2 warming omega)
(format #t "  binding wall: ocean acidification at co2≈~,1f  (warming would allow ~,1f)~%" ocean-co2-tip warm-co2-tip)
(format #t "  nitrogen   ~,2f   (rate boundary tip ~a, α=0.5)~%" nitro n-tip)

(let* ((c1 (and (= (first shape) 2) (= (second shape) 2) (= (third shape) 2)))   ; N,P rates; warming+ocean budgets; 2 couplings
       (c2 (< co2 ocean-co2-tip))                    ; the tighter (ocean) wall never crossed
       (c3 (> (- ocean-co2-tip co2) 1.0))            ; …eased off before it (real margin)
       (c4 (< co2 warm-co2-tip))                     ; warming wall also respected (slacker)
       (c5 (< nitro n-tip))                          ; nitrogen rate never crossed
       (c6 (> (- n-tip nitro) 0.1))                  ; …eased off before it
       (c7 (and (> co2 1.0) (> nitro 1.0)))          ; both still draw substantially (limits, not shutoffs)
       (ok (and c1 c2 c3 c4 c5 c6 c7)))
  (format #t "~%  [~a] catalogue → policy: 2 rate boundaries, 2 cascaded budgets, 2 couplings~%" (if c1 "✓" "✗"))
  (format #t "  [~a] OCEAN acidification is the tighter wall: co2 ~,1f eases below ~,1f (Ω 0.05)~%" (if (and c2 c3) "✓" "✗") co2 ocean-co2-tip)
  (format #t "  [~a] WARMING wall (tipping cluster) also respected: co2 below ~,1f (0.2°C)~%" (if c4 "✓" "✗") warm-co2-tip)
  (format #t "  [~a] nitrogen RATE binds: N ~,1f eases off below the boundary tip ~a~%" (if (and c5 c6) "✓" "✗") nitro n-tip)
  (format #t "  [~a] all still produce — fragilities are limits, not shutoffs~%" (if c7 "✓" "✗"))
  (format #t "~%  ~a two planetary frameworks (boundaries + tipping points), one frag, one draw — they bind a real plan~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
