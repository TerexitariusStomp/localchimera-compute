;;; test-frag-spec.scm — the per-spec RATE boundary in isolation.
;;;
;;; *frag-spec* (eco-spec-frag) is a PER-PERIOD flux limit applied at every cell the spec is drawn —
;;; distinct from a cumulative budget (which caps the horizon SUM) and from a per-located-good cap.
;;; The decisive test: over two periods, a rate boundary caps EACH period, so the horizon total can
;;; exceed the tip — whereas a budget would cap the total. We assert exactly that distinction.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/planner/test-frag-spec.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver))

(define tip 10.0)   ; quantile_0.5(8,12)
(define (emit-recipe)
  (compile-recipe (list (rp "emit" "Emit"))
                  (list (out "o1" "widget" 1.0 "emit") (wrk "o2" 0.1 "emit") (in "o3" "co2" 1.0 "emit"))))

;; spec-rate vs budget over the SAME 2-period problem
(define (run kind)   ; 'rate (eco-spec-frag) or 'budget (eco-budget)
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods '(0 1)
                  #:templates (emit-recipe))
  (hash-set! *A* (cell "town" 0) 1000000.0) (hash-set! *A* (cell "town" 1) 1000000.0)
  (if (eq? kind 'rate)
      (hash-set! *frag-spec*   "co2" (list 8.0 12.0 0.5 50.0))     ; per-PERIOD rate, tip 10
      (hash-set! *frag-budget* "co2" (list 8.0 12.0 0.5 50.0)))    ; cumulative budget, tip 10
  (hash-set! *demand* (lg "widget" (cell "town" 0)) 25.0)          ; want past the tip in BOTH periods
  (hash-set! *demand* (lg "widget" (cell "town" 1)) 25.0)
  (hash-set! *desire-weight* (lg "widget" (cell "town" 0)) 1000.0) ; a strong desire (else the fixed-w barrier just crushes the draw)
  (hash-set! *desire-weight* (lg "widget" (cell "town" 1)) 1000.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (list (V "p|emit|town@0") (V "p|emit|town@1"))))))

(define rate (run 'rate))     ; each period ≤ tip ⇒ total ≈ 2·tip
(define budg (run 'budget))   ; total ≤ tip
(define (p0 r)(first r))(define (p1 r)(second r))
(define (total r)(+ (p0 r)(p1 r)))

(format #t "~%── per-spec RATE vs cumulative BUDGET, 2 periods, tip ~a ──~%" tip)
(format #t "  rate:   p0 ~,3f  p1 ~,3f  total ~,3f~%" (p0 rate) (p1 rate) (total rate))
(format #t "  budget: p0 ~,3f  p1 ~,3f  total ~,3f~%" (p0 budg) (p1 budg) (total budg))

(let* ((c1 (and (< (p0 rate) tip) (< (p1 rate) tip)))    ; rate caps EACH period
       (c2 (> (total rate) tip))                         ; …so the total EXCEEDS the tip (it is NOT a budget)
       (c3 (and (> (p0 rate) 1.0) (> (p1 rate) 1.0)))    ; both periods draw substantially
       (c4 (< (total budg) tip))                         ; budget caps the TOTAL
       (c5 (> (- tip (p0 rate)) 0.05))                   ; rate eases off before the per-period tip
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] rate caps EACH period below the tip (~,1f, ~,1f < ~a)~%" (if (and c1 c5) "✓" "✗") (p0 rate) (p1 rate) tip)
  (format #t "  [~a] …so the horizon TOTAL exceeds the tip (~,1f > ~a) — a rate, not a budget~%" (if c2 "✓" "✗") (total rate) tip)
  (format #t "  [~a] the budget, by contrast, caps the TOTAL (~,1f < ~a)~%" (if c4 "✓" "✗") (total budg) tip)
  (format #t "  [~a] both periods still draw — a rate limit, not a shutoff~%" (if c3 "✓" "✗"))
  (format #t "~%  ~a a per-spec rate boundary caps each period independently, distinct from a cumulative budget~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
