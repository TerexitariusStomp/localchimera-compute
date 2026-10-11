;;; test-socialized-capacity.scm — a socialized private means enters the live
;;; solve as scheduled use-capacity.
;;;
;;; A privately-held cargo-bike is temporarily socialized into a commune's
;;; use-pool. Its per-period service `Svc|bike` is injected exactly as any
;;; durable's capacity — an eco-cap poured into *cap* by the SAME loop
;;; ingest-located uses — but derived from the live grant via `svc-eco-caps`
;;; (the instrument twin of a live skill credential contributing labour).
;;;
;;; What the grant governs is HOW MUCH communal use is possible: the delivery runs
;;; BOUNDED by exactly what the owner lent (custody, not ownership — the bike is
;;; `use`d, never consumed, and returns whole). Lend 2 bike-hours and 2 parcels
;;; move; lend 4 and 4 move. Capacity is a declared property (an uncapped `Svc|`
;;; is a free structural raw, so "not socialized" is modelled as no capacity
;;; declared — the mapping below emits nothing, and a lapsed grant likewise stops
;;; contributing).
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-socialized-capacity.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))
(use-modules (playnet vf formulas capacity))  ; svc-eco-caps

;; deliver 1 parcel per bike-hour: a `use` of the bike (Svc|bike) + a produced good.
(define deliver-tpl
  (car (compile-recipe (list (rp "deliver" "Deliver"))
         (list (out "d1" "delivered" 1.0 "deliver")
               (wrk "d2" 0.1 "deliver")
               (use* "d3" "bike" "deliver" 1.0 #:qty 1.0)))))

;; SOCIALIZED-CAPS is a list of (spec place per-period-capacity) grant facts — what
;; commune-socialized-caps produces on the governance side from live attestations.
(define (run socialized-facts demand)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (list deliver-tpl))
  (hash-set! *A* (cell "town" 0) 1000.0)                          ; labour abundant
  (hash-set! *demand* (lg "delivered" (cell "town" 0)) demand)
  ;; THE INJECTION: pour the socialized-means caps into *cap* — the exact loop
  ;; ingest-located runs for eco-caps (planner.scm:2086).
  (for-each (lambda (ec) (hash-set! *cap* (car ec) (cdr ec)))
            (svc-eco-caps socialized-facts *periods*))
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))))
        (vector-ref x (hash-ref idx "p|deliver|town@0"))))))

(define lent-2 (run '(("bike" "town" 2.0)) 8.0))                  ; lent 2 bike-hours, demand 8
(define lent-4 (run '(("bike" "town" 4.0)) 8.0))                  ; lent 4 bike-hours, demand 8

;; The pure mapping: grant facts → Svc|spec@cell eco-caps, over the solve periods.
(define caps-2  (svc-eco-caps '(("bike" "town" 2.0)) '(0)))
(define caps-mp (svc-eco-caps '(("bike" "town" 2.0)) '(0 1)))
(define caps-0  (svc-eco-caps '() '(0)))

(format #t "~%── delivery `use`s a bike (Svc|bike); demand 8 ──~%")
(format #t "  ~22a ~10,2f~%" "socialized (2 h lent)" lent-2)
(format #t "  ~22a ~10,2f~%" "socialized (4 h lent)" lent-4)

(let* ((c0 (member "Svc|bike" (map car (proc-inputs deliver-tpl))))  ; `use` compiled to a Svc consume
       (c1 (and (> lent-2 1.9) (< lent-2 2.1)))                      ; use BOUNDED by what was lent (2)
       (c2 (and (> lent-4 3.9) (< lent-4 4.1)))                      ; lend more ⇒ more use (4), still ≤ demand
       (c3 (equal? caps-2 '(("Svc|bike#town@0" . 2.0))))            ; mapping: one grant → one cell cap
       (c4 (= 2 (length caps-mp)))                                   ; one cap per solve period
       (c5 (null? caps-0))                                           ; no live grant ⇒ no capacity declared
       (ok (and c0 c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] `use` compiles to a consume of Svc|bike~%" (if c0 "✓" "✗"))
  (format #t "  [~a] communal use bounded by the grant                (lent 2 ⇒ delivered ~,2f ≈ 2)~%" (if c1 "✓" "✗") lent-2)
  (format #t "  [~a] lend more ⇒ more communal use                    (lent 4 ⇒ delivered ~,2f ≈ 4)~%" (if c2 "✓" "✗") lent-4)
  (format #t "  [~a] mapping: grant fact → Svc|spec@cell eco-cap       (~s)~%" (if c3 "✓" "✗") caps-2)
  (format #t "  [~a] one cap per solve period                         (~a periods ⇒ ~a caps)~%" (if c4 "✓" "✗") 2 (length caps-mp))
  (format #t "  [~a] no live grant ⇒ nothing declared                 (~s)~%" (if c5 "✓" "✗") caps-0)
  (format #t "~%  ~a a socialized means enters the solve as Svc capacity — same machinery as any durable, sized by the live grant~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
