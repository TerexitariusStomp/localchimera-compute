;;; test-commute-network.scm — commute as provisioned movement on a SHARED network.
;;;
;;; Whole-worker, no fixed home. The worker stays ONE budget; we never disaggregate
;;; their time into a flowing good. What moves is the PERSON, in one piece: their
;;; presence flows through the lattice. Relocation = move presence once and let it
;;; stay (B becomes where they are — no permanent home); commute = oscillate it back.
;;; Presence is whole (pA+pB=1, the convex relaxation of "you're at one place"); the
;;; worker's CURRENT location is just a state (here: at A in period 0), not an
;;; assumption — the plan decides the trajectory forward.
;;;
;;; Person-moves and freight share ONE road of capacity K: moving the worker and
;;; shipping goods compete for the same edge. So the plan can meet demand-at-B three
;;; ways and picks the cheapest on the shared network:
;;;   • move the WORKER to B (presence flow, transit time off their budget), produce local
;;;   • keep the worker at A and move the WORK (ship the widget A→B as freight)
;;; The "penalty" is gone: commute is a person-trip the plan PROVISIONS (real road
;;; capacity + the worker's transit time as faux frais), reducible by relocating, by
;;; moving the work instead, or by investing in the road.
;;;
;;; widget@B demanded periods 1..3. widget = 1 worker-hour, produced at A or B.
;;;   move-worker scenario: cheap to move the person, costly to ship the widget ⇒ RELOCATE.
;;;   move-work   scenario: costly to move the person (transit eats the day) ⇒ SHIP the widget.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-commute-network.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve solver))

(define H  40.0)   ; the worker's hours per period (ONE whole budget)
(define D  30.0)   ; widget demanded at B, periods 1..3
(define W  1000.0) ; desire weight
;; activity indices
(define (mAB t) (- t 1))            ; presence flow A→B into period t (t=1..3) → 0,1,2
(define (mBA t) (+ 2 t))            ; presence flow B→A into period t (t=1..3) → 3,4,5
(define (wA t)  (+ 6 t))            ; work at A, t=0..3 → 6,7,8,9
(define (wB t)  (+ 9 t))            ; work at B, t=1..3 → 10,11,12
(define (sh t)  (+ 13 t))           ; widget shipped A→B, t=0..3 → 13,14,15,16
(define NA 17)

(define (pBco t)                    ; presence-at-B = Σ_{s≤t}(mAB_s − mBA_s) — substituted, no extra var
  (append-map (lambda (s) (list (cons (mAB s) 1.0) (cons (mBA s) -1.0))) (iota t 1)))
(define (scale co k) (map (lambda (ic) (cons (car ic) (* k (cdr ic)))) co))

(define (build roadW roadP transit K)
  (let ((forms '()))
    (define (add! f) (set! forms (cons f forms)))
    (do ((i 0 (+ i 1))) ((= i NA)) (add! (mk-bar 0.0 (list (cons i 1.0)))))   ; x ≥ 0
    (for-each (lambda (t)
      (add! (mk-bar 0.0 (pBco t)))                                            ; presence_B ≥ 0
      (add! (mk-bar 1.0 (scale (pBco t) -1.0)))                               ; presence_B ≤ 1 (whole person)
      (add! (mk-bar 0.0 (cons (cons (wB t) -1.0) (scale (pBco t) H))))        ; work@B ≤ H·presence_B  (work where you ARE)
      (add! (mk-des (mk-bar 0.0 (list (cons (wB t) 1.0) (cons (sh t) 1.0))) D W)))  ; widget@B = wB + shipped → D
      '(1 2 3))
    (for-each (lambda (t)
      (add! (mk-bar H (cons (cons (wA t) -1.0) (scale (pBco t) (- H)))))      ; work@A ≤ H·(1−presence_B)
      (add! (mk-bar 0.0 (list (cons (wA t) 1.0) (cons (sh t) -1.0))))         ; ship ≤ produced@A (widget@A balance)
      (add! (mk-bar H (cons (cons (wA t) -1.0)                                ; budget: work + transit ≤ H (ONE whole budget)
                            (if (> t 0) (list (cons (wB t) -1.0)
                                              (cons (mAB t) (- transit)) (cons (mBA t) (- transit))) '()))))
      (add! (mk-bar K (cons (cons (sh t) (- roadW))                           ; SHARED road: roadW·ship + roadP·moves ≤ K
                            (if (> t 0) (list (cons (mAB t) (- roadP)) (cons (mBA t) (- roadP))) '())))))
      '(0 1 2 3))
    (values forms
            (append (map (lambda (t) (cons (wA t) 1.0)) '(0 1 2 3))           ; free-time κ on worked hours
                    (map (lambda (t) (cons (wB t) 1.0)) '(1 2 3))
                    (map (lambda (t) (cons (sh t) 0.1)) '(0 1 2 3))           ; freight carries some transport-labour
                    (append-map (lambda (t) (list (cons (mAB t) transit)      ; transit time is faux frais — unfree hours, in the objective
                                                  (cons (mBA t) transit))) '(1 2 3))))))

(define (form-val co x) (fold (lambda (ic s) (+ s (* (cdr ic) (vector-ref x (car ic))))) 0.0 co))
(define (run roadW roadP transit K)
  (call-with-values (lambda () (build roadW roadP transit K))
    (lambda (forms lab)
      (let* ((res (solve* forms lab (make-vector NA 0.0))) (x (car res)))
        (list (apply + (map (lambda (t) (+ (vector-ref x (mAB t)) (vector-ref x (mBA t)))) '(1 2 3)))  ; total person-trips
              (form-val (pBco 3) x)                                            ; presence@B by period 3 (relocated?)
              (apply + (map (lambda (t) (vector-ref x (wB t))) '(1 2 3)))      ; produced at B
              (apply + (map (lambda (t) (vector-ref x (sh t)))  '(0 1 2 3)))   ; widget shipped (work moved)
              (apply + (map (lambda (t) (+ (vector-ref x (wB t)) (vector-ref x (sh t)))) '(1 2 3))))))))  ; widget@B delivered

(define mover (run 20.0 1.0 2.0  50.0))    ; shipping is road-heavy & capacity-capped, person cheap to move ⇒ MOVE WORKER
(define ship  (run 1.0  1.0 35.0 200.0))   ; moving the worker burns 35/40 hrs; shipping cheap & road ample ⇒ MOVE THE WORK
(define (trips r)(first r))(define (pB r)(second r))(define (madeB r)(third r))(define (shipped r)(fourth r))(define (got r)(fifth r))

(format #t "~%── whole worker, shared road: meet widget@B (D=~a×3 periods, budget ~a) ──~%" D H)
(format #t "  ~14a ~10a ~9a ~9a ~9a~%" "scenario" "presence@B" "made@B" "shipped" "got@B")
(format #t "  ~14a ~10,2f ~9,1f ~9,1f ~9,1f~%" "move-worker" (pB mover)(madeB mover)(shipped mover)(got mover))
(format #t "  ~14a ~10,2f ~9,1f ~9,1f ~9,1f~%" "move-work"   (pB ship)(madeB ship)(shipped ship)(got ship))

(let* ((c1 (> (pB mover) 0.5))                                ; move-worker: the person relocates to B (and stays — no fixed home)
       (c2 (< (shipped mover) 12.0))                          ;   …work done where the worker is, little shipping
       (c3 (< (pB ship) 0.3))                                 ; move-work: the worker mostly stays at A (transit too dear to relocate)
       (c4 (> (shipped ship) 25.0))                           ;   …the WORK moves instead (widgets shipped on the shared road)
       (c5 (and (> (got mover) 25.0) (> (got ship) 25.0)))    ; both meet demand@B — same end, different means
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] move-worker: presence relocates to B            (presence@B ~,2f)~%"             (if c1 "✓" "✗") (pB mover))
  (format #t "  [~a] …produced where the worker is, little shipping    (shipped ~,1f)~%"                (if c2 "✓" "✗") (shipped mover))
  (format #t "  [~a] move-work: the worker mostly stays at A (transit dear) (presence@B ~,2f)~%"        (if c3 "✓" "✗") (pB ship))
  (format #t "  [~a] …the WORK moves instead — widgets shipped to B     (shipped ~,1f)~%"                (if c4 "✓" "✗") (shipped ship))
  (format #t "  [~a] both meet demand@B by different means              (got ~,0f / ~,0f)~%"             (if c5 "✓" "✗") (got mover)(got ship))
  (format #t "~%  ~a commute = a person-trip the plan provisions on the shared road; no disaggregation, no fixed home~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
