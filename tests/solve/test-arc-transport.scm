;;; test-arc-transport.scm — pickup/dropoff transport recipes tile over ARCS.
;;;
;;; A transport recipe `pickup`s a good at the origin and `dropoff`s the SAME good at
;;; the destination (locationEffect). Before, this compiled to a same-cell consume +
;;; produce — a no-op. Now a template carrying pickup/dropoff (proc-relocated) tiles
;;; over ARCS (origin → destination), generating a column that consumes good@origin,
;;; produces good@destination (with retention), and carries the recipe's OWN costs
;;; (driver labour, fuel) scaled by distance — transport as a recipe, costs attached
;;; to the move, instead of the anonymous τ·km move mechanism.
;;;
;;; Verified by inspecting the built columns (solver-independent).
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-arc-transport.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format) ((playnet solve world) #:select (*templates*)))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas))

;; a haul recipe: pickup widget @origin, dropoff widget @destination, driver 0.01 h/km
(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.9))   ; ~100 km east
                #:templates
                  (compile-recipe (list (rp* "p:haul" "Haul"))
                    (list (make-recipe-flow #:id "p1" #:action 'pickup 
                                            #:resource-conforms-to "widget"
                                            #:resource-quantity (make-measure 1.0 %count-unit)
                                            #:recipe-input-of "p:haul")
                          (make-recipe-flow #:id "d1" #:action 'dropoff
                                            #:resource-conforms-to "widget"
                                            #:resource-quantity (make-measure 1.0 %count-unit)
                                            #:recipe-output-of "p:haul")
                          (wk* "w1" #f 0.01 "p:haul"))))

(define tpl (car *templates*))
(define cols (build-columns))
(define d (km (cell "A" 0) (cell "B" 0)))
(define arc  (find (lambda (c) (equal? (car c) "p|p:haul|A@0|B@0")) cols))   ; the A→B arc column
(define same (find (lambda (c) (equal? (car c) "p|p:haul|A@0"))      cols))   ; the old same-cell no-op (should be gone)
(define wA (and arc (assoc (lg "widget" (cell "A" 0)) (cadr arc))))
(define wB (and arc (assoc (lg "widget" (cell "B" 0)) (cadr arc))))

(format #t "~%── transport recipe (pickup/dropoff) → arc tiling, distance ~~~,0f km ──~%" d)
(format #t "  compile-process relocated = ~a~%" (proc-relocated tpl))
(format #t "  arc column p|p:haul|A@0|B@0 exists? ~a~%" (and arc #t))
(format #t "  flows: widget@A = ~a , widget@B = ~a   (relocate: consume@A, produce@B)~%" (and wA (cdr wA)) (and wB (cdr wB)))
(format #t "  driver labour on the arc = ~,3f   (0.01 h/km × ~,0f km)~%" (and arc (caddr arc)) d)
(format #t "  old same-cell column p|p:haul|A@0 (no-op)? ~a~%" (and same #t))

(let* ((c1 (equal? (proc-relocated tpl) '("widget")))               ; pickup/dropoff captured as relocated
       (c2 (and arc #t))                                            ; the arc column was generated
       (c3 (and wA wB (< (abs (- (cdr wA) -1.0)) 1e-9) (< (abs (- (cdr wB) 1.0)) 1e-9)))  ; consume@A, produce@B
       (c4 (and arc (> (caddr arc) 0.0) (< (abs (- (caddr arc) (* 0.01 d))) 1e-6)))       ; driver cost scaled by distance
       (c5 (not same))                                             ; the same-cell no-op is gone
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] pickup/dropoff captured as a relocated good        (relocated = ~a)~%" (if c1 "✓" "✗") (proc-relocated tpl))
  (format #t "  [~a] transport tiles over the A→B ARC                   (column exists = ~a)~%" (if c2 "✓" "✗") (and arc #t))
  (format #t "  [~a] the good is relocated: consume@A, produce@B        (~a / ~a)~%" (if c3 "✓" "✗") (and wA (cdr wA)) (and wB (cdr wB)))
  (format #t "  [~a] the recipe's driver cost rides the move, ×distance (~,3f = 0.01×~,0f)~%" (if c4 "✓" "✗") (and arc (caddr arc)) d)
  (format #t "  [~a] the old same-cell no-op column is gone             (~a)~%" (if c5 "✓" "✗") (if same "present" "absent"))
  (format #t "~%  ~a transport is a recipe over an ARC: pickup→dropoff relocates the good, its driver/fuel costs attached to the move~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
