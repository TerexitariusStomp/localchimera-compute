;;; test-priority.scm — the solver honours priority-weighted desire.
;;;
;;; The doc's harmony objective is Σ w_d g_d² — desires weighted by PRIORITY, so the
;;; plan can "under-serve cake to serve medicine" (§1). The convex engine must be able
;;; to express that, even before any UI feeds the weights: build-located reads a per-
;;; desire weight (*desire-weight*, default uniform), and w_d = (priority-weight ℓ_d)
;;; is the canonical level→weight policy (β^ℓ, β⁹≈1000).
;;;
;;; Scenario: medicine and cake, each made from 1 h of labour, both wanted at 10 — but
;;; only 10 h of labour exists, so at most 10 units total. The objective alone decides
;;; the split:
;;;   (1) UNIFORM weight  → symmetric: ~5 medicine, ~5 cake (both 50% met).
;;;   (2) medicine ≫ cake → medicine fully met (~10), cake sacrificed (~0).
;;; (2) is impossible with flat weights; it is the whole point of priority.
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-priority.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve solver))


;; One solve over {medicine, cake}, 10 h labour, both demanded at 10.
;; `weights` = an alist ((spec . w) …); empty ⇒ uniform (engine default).
;; Returns (medicine-made . cake-made).
(define (solve-split weights)
  (declare-world! #:places '(("p" 0.0 0.0))
                  #:templates
                    (list (list "mkmed"  '(("medicine" . 1.0)) '() 1.0 '())
                          (list "mkcake" '(("cake" . 1.0))     '() 1.0 '())))
  (hash-set! *A* (cell "p" 0) 10.0)                 ; 10 h of labour at the cell
  (hash-set! *demand* (lg "medicine" (cell "p" 0)) 10.0)
  (hash-set! *demand* (lg "cake"     (cell "p" 0)) 10.0)
  (for-each (lambda (sw) (hash-set! *desire-weight* (lg (car sw) (cell "p" 0)) (cdr sw))) weights)
  (set! *willing?* (lambda (w s c) #t)) (set! *legal-decorate* (lambda (p c) (values #f 0.0 '())))
  (set! *backend* 'native-c)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve forms lf (located-warm cols ncol idx) 1.0)) list)))
             (xof (lambda (k) (vector-ref x (hash-ref idx k)))))
        (cons (xof "p|mkmed|p@0") (xof "p|mkcake|p@0"))))))

(format #t "~%=== Priority-weighted desire (Σ w_d g_d²) ===~%")

;; (1) uniform — symmetric split
(let* ((r (solve-split '())) (med (car r)) (cake (cdr r)))
  (format #t "  uniform:      medicine=~,2f  cake=~,2f~%" med cake)
  (check "uniform → symmetric (|medicine − cake| < 0.5)" (< (abs (- med cake)) 0.5))
  (check "uniform → both partially met (~5 each)" (and (> med 4.0) (< med 6.0))))

;; (2) medicine prioritised — cake sacrificed
(let* ((r (solve-split (list (cons "medicine" (priority-weight 9))   ; β⁹ ≈ 1000
                             (cons "cake"     (priority-weight 0))))) ; β⁰ = 1
       (med (car r)) (cake (cdr r)))
  (format #t "  med≫cake:     medicine=~,2f  cake=~,2f   (w_med=~,0f w_cake=~,0f)~%"
          med cake (priority-weight 9) (priority-weight 0))
  (check "priority → medicine (nearly) fully met (> 9)" (> med 9.0))
  (check "priority → cake sacrificed (< 1)" (< cake 1.0))
  (check "priority → medicine ≫ cake" (> med (* 5.0 (max cake 0.01)))))

;; the canonical level→weight policy is the documented geometric ladder
(check "priority-weight 9 ≈ 1000 (β⁹)" (< (abs (- (priority-weight 9) 1000.0)) 1.0))
(check "priority-weight 0 = 1 (β⁰)" (< (abs (- (priority-weight 0) 1.0)) 1e-9))

(test-summary!)
