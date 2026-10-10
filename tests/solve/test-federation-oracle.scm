;;; test-federation-oracle.scm — QUESTION ZERO for federated planning:
;;; does the base located solver satisfy REMOTE demand via transport?
;;;
;;; Two communes A and B, ~7 km apart. Commune A can produce bread (flour +
;;; a baker); commune B has demand but, alone, no productive capacity. The
;;; solver must BAKE at A and HAUL to B to meet B's demand — the economic
;;; content of federation (a deficit met by a neighbour's surplus).
;;;
;;; Proven facts this pins:
;;;   (1) transport is a pickup/dropoff RECIPE tiling over arcs (p|haul|A@0|B@0),
;;;       NOT the `#:movable` keyword nor a bare `move` flow;
;;;   (2) plan-from-records is the entry that wires arcs (ingest-travel-times!,
;;;       #:arc-topology? #t) — the raw ingest/build-located path does not;
;;;   (3) a haul needs LABOUR AT BOTH cells (pickup@origin, dropoff@destination);
;;;   (4) the demanded good's dual pull μ is high where it is scarce (B) and
;;;       ~0 where it is in surplus (A) — the signal cross-vat DUAL DECOMPOSITION
;;;       reconciles (docs/planning/federation/FEDERATED-SOLVE.md).
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-federation-oracle.scm
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define (res spec loc q) (er (string-append spec "@" loc) spec #f #:place loc #:qty q #:unit "kg"))
(define (place id lat lon) (place* id #:lat lat #:lon lon))
(define (worker id loc) (person* id #:place loc #:tags '("general")))
(define A (place "a-home" 42.70 23.32))
(define B (place "b-home" 42.75 23.40))       ; ~7 km from A
;; bake (flour+work→bread) + haul (pickup bread @origin, dropoff @dest, driver work)
(define procs (list (rp "bake" "Bake bread") (rp "haul" "Haul bread")))
(define flows (list (out "o" "bread" 1.0 "bake") (in "i" "flour" 1.0 "bake") (wrk "w" 0.1 "bake")
                    (make-recipe-flow #:id "p1" #:action 'pickup  #:resource-conforms-to "bread"
                                      #:resource-quantity (make-measure 1.0 "kg")
                                      #:recipe-input-of "haul")
                    (make-recipe-flow #:id "d1" #:action 'dropoff #:resource-conforms-to "bread"
                                      #:resource-quantity (make-measure 1.0 "kg")
                                      #:recipe-output-of "haul")
                    (wrk "hw" 0.01 "haul")))

(define (run-plan label resources agents spatials demand)
  (call-with-values
    (lambda () (plan-from-records resources agents spatials procs flows
                 #:demand demand #:arc-topology? #t #:per-agent? #f #:periods '(0)))
    (lambda (intents commitments material fill cols x idx ntot report)
      (define (V k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
      (define (mu g) (let ((p (assoc g (or (assq-ref report 'good-pulls) '())))) (if p (cdr p) 0.0)))
      (format #t "~%── ~a ──   met = ~,3f~%" label fill)
      (for-each (lambda (k) (when (> (abs (V k)) 1e-3) (format #t "   ~a = ~,2f~%" k (V k))))
                (sort (hash-map->list (lambda (k i) k) idx) string<?))
      (format #t "   μ(bread@A)=~,3f  μ(bread@B)=~,3f~%"
              (mu (lg "bread" (cell "a-home" 0))) (mu (lg "bread" (cell "b-home" 0))))
      fill)))

;; ISOLATED B: B alone, no worker → no productive capacity → cannot meet its demand.
(define iso (run-plan "ISOLATED B (no worker, no capacity): wants 40 bread"
                   '() '() (list B)
                   (list (cons (lg "bread" (cell "b-home" 0)) 40.0))))
;; FEDERATED: A has flour + baker; B has a receiver. A bakes and HAULS to B.
(define fed (run-plan "FEDERATED A+B: flour@A + workers@both → BAKE@A, HAUL→B"
                   (list (res "flour" "a-home" 200.0))
                   (list (worker "wa" "a-home") (worker "wb" "b-home")) (list A B)
                   (list (cons (lg "bread" (cell "b-home" 0)) 40.0))))

(define haul-ab
  (call-with-values
    (lambda () (plan-from-records (list (res "flour" "a-home" 200.0))
                 (list (worker "wa" "a-home") (worker "wb" "b-home")) (list A B) procs flows
                 #:demand (list (cons (lg "bread" (cell "b-home" 0)) 40.0))
                 #:arc-topology? #t #:per-agent? #f #:periods '(0)))
    (lambda (i c m fill cols x idx n r) (let ((h (hash-ref idx "p|haul|a-home@0|b-home@0" #f)))
                                          (if h (vector-ref x h) 0.0)))))

(format #t "~%════════════════════════════════════════════════════════════~%")
(let* ((c1 (< iso 0.01))            ; B alone cannot provision
       (c2 (> fed 0.99))            ; federated, demand is fully met
       (c3 (> haul-ab 35.0))        ; via a real A→B haul of ~40
       (ok (and c1 c2 c3)))
  (format #t "  [~a] B ALONE cannot meet its demand        (met = ~,3f)~%" (if c1 "✓" "✗") iso)
  (format #t "  [~a] FEDERATED, B's demand is fully met     (met = ~,3f)~%" (if c2 "✓" "✗") fed)
  (format #t "  [~a] met by a real A→B haul of A's surplus  (haul = ~,2f)~%" (if c3 "✓" "✗") haul-ab)
  (format #t "~%  ~a base solver satisfies REMOTE demand via transport — federation's economic core works~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
