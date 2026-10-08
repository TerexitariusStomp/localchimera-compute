;;; test-use-mop.scm — capacity is a SERVICE good; `use` is a consume of it.
;;;
;;; A means of production is `use`d, not consumed — it persists. Its per-period
;;; capacity is the service good `Svc|durable`, capped by the durable's onhand
;;; (*cap* on Svc), and a `use` flow compiles to a CONSUME of that service. The
;;; Svc ≥ 0 balance is auto (like any capped raw) and its DUAL is the capacity /
;;; expand pull — exactly parallel to labour (a worker supplies Lab, capped by
;;; hours; a durable supplies Svc, capped by onhand). No bespoke *use-cap*, no
;;; special section.
;;;
;;; Bake bread, `use`ing an oven (1 oven-hour per loaf). Demand 50.
;;;   ample oven (Svc cap 100): demand met, capacity pull ~0.
;;;   scarce oven (Svc cap 20): output capped at the oven, pull steep.
;;;
;;; Run:  guile -L module/playnet/planner module/playnet/planner/use-mop-test.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))

(define bake-tpl
  (car (compile-recipe (list (rp "bake" "Bake"))
         (list (out "b1" "bread" 1.0 "bake") (in "b2" "flour" 1.0 "bake") (wrk "b3" 0.5 "bake")
               (use* "b4" "oven" "bake" 1.0 #:qty 1.0)))))
(format #t "~%`use` compiled to a Svc consume:  bake inputs = ~a~%" (proc-inputs bake-tpl))

(define (run K)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (list bake-tpl))
  (hash-set! *cap* (lg "flour" (cell "town" 0)) 1000.0)        ; flour abundant
  (hash-set! *cap* (lg "Svc|oven" (cell "town" 0)) K)          ; OVEN capacity = cap on its service good
  (hash-set! *A* (cell "town" 0) 1000.0)                       ; labour abundant
  (hash-set! *demand* (lg "bread" (cell "town" 0)) 50.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((res (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))
             (x (car res)) (t (cadr res))
             (bread (vector-ref x (hash-ref idx "p|bake|town@0")))
             (slack (max 1e-9 (- K bread)))                    ; Svc|oven used = 1·bake; slack = capacity − use
             (pull  (/ t slack)))                              ; the capacity/expand pull = dual of the Svc balance
        (list bread pull)))))

(define ample  (run 100.0))
(define scarce (run 20.0))
(define (bread r) (first r)) (define (pull r) (second r))

(format #t "~%── bake uses an oven (Svc|oven); demand 50 loaves ──~%")
(format #t "  ~14a ~10a ~14a~%" "Svc capacity" "bread" "capacity pull")
(format #t "  ~14a ~10,1f ~14,4f~%" "ample (100)" (bread ample)  (pull ample))
(format #t "  ~14a ~10,1f ~14,4f~%" "scarce (20)" (bread scarce) (pull scarce))

(let* ((c0 (member "Svc|oven" (map car (proc-inputs bake-tpl))))   ; `use` became a Svc consume
       (c1 (> (bread ample) 45.0))
       (c2 (< (bread scarce) 22.0))
       (c3 (> (pull scarce) (* 20.0 (pull ample))))
       (ok (and c0 c1 c2 c3)))
  (format #t "~%  [~a] `use` compiles to a consume of Svc|oven           (inputs = ~a)~%" (if c0 "✓" "✗") (proc-inputs bake-tpl))
  (format #t "  [~a] ample capacity ⇒ demand met, pull ~~0              (bread ~,1f, pull ~,4f)~%" (if c1 "✓" "✗") (bread ample) (pull ample))
  (format #t "  [~a] scarce capacity ⇒ output capped by the durable     (bread ~,1f ≤ 20)~%"     (if c2 "✓" "✗") (bread scarce))
  (format #t "  [~a] the capacity pull rises when the durable binds      (~,4f → ~,4f)~%"          (if c3 "✓" "✗") (pull ample) (pull scarce))
  (format #t "~%  ~a capacity is a Svc good, `use` consumes it — same machinery as labour; no bespoke *use-cap*~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
