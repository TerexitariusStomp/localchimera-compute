;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-coherence.scm — the solution is REAL ValueFlows, coherent, and respects stock.
;;;
;;; The bread chain (grow→mill→bake) with an EXISTING STOCK of flour (init = 30, as an
;;; ingested EconomicResource onhand would set it), soil capped at 30 (so milling alone
;;; makes only 30 flour), and bread demanded at 50 — so meeting demand REQUIRES drawing on
;;; the stock. We solve, then check three things rigorously:
;;;   (1) RECIPE COHERENCE — reconstruct every located good's balance from the solution;
;;;       delivered = init + Σ(produce − consume + move) ≥ 0 for ALL goods (no negative
;;;       inventory; every consume is covered by stock + production).
;;;   (2) STOCK RESPECTED & USED — flour consumed (50) exceeds flour milled (30), so ~20 is
;;;       drawn from the 30 of stock; the soil raw is never drawn past its cap.
;;;   (3) REAL VF OUTPUT — the plan emits work need/offer Intents + work Commitments AND
;;;       material produce/consume Commitments, topologically ordered (produce before consume).
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-coherence.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve report) (playnet test planner worked-example) (playnet solve world)
             (playnet solve solver)
             (playnet vf schemas))

(declare-world! #:places '(("town" 0.0 0.0)) #:templates *base-templates*   ; grow (soil→grain), mill (grain→flour), bake (flour→bread)
                #:workers (list (list "Ada" '("general") "town@0" 1000.0)))   ; a worker, so the LABOUR side emits VF intents/commitments
(set! *emp-rho* 0.0001)                                       ; tiny EMP here — one worker shouldn't be throttled by overwork-disutility (the point is coherence, not load-spreading)
(hash-set! *cap*  (lg "soil"  (cell "town" 0)) 30.0)          ; raw: only 30 grain growable ⇒ only 30 flour millable
(hash-set! *init* (lg "flour" (cell "town" 0)) 30.0)          ; EXISTING STOCK of flour (a produced good ⇒ *init*)
(hash-set! *demand* (lg "bread" (cell "town" 0)) 50.0)        ; 50 needed ⇒ must use the stock (30 milled + 30 stock = 60)

(call-with-values build-located
  (lambda (forms labform ncol cols goods raws idx)
    (define x (car (call-with-values (lambda () (solve forms labform (located-warm cols ncol idx))) list)))
    (define (lvl key) (let ((i (hash-ref idx key #f))) (if i (vector-ref x i) 0.0)))
    (define (flows-on g) (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if fc (+ a (* (cdr fc) (lvl (col-key c)))) a))) 0.0 cols))
    (define (bound g) (if (member g goods) (hash-ref *init* g 0.0) (or (hash-ref *cap* g #f) (hash-ref *init* g 0.0) 0.0)))
    (define (slack g) (+ (bound g) (flows-on g)))             ; the balance value: ≥ 0 ⇔ coherent
    (define tol 1e-3)

    ;; ── (1) every good's balance holds ──
    (define worst (fold (lambda (g a) (min a (slack g))) 1e9 (append goods raws)))
    (define n-neg (fold (lambda (g a) (if (< (slack g) (- tol)) (+ a 1) a)) 0 (append goods raws)))

    ;; ── (2) stock + demand ──
    (define milled  (lvl "p|mill|town@0"))
    (define baked   (lvl "p|bake|town@0"))
    (define bread   (slack (lg "bread" (cell "town" 0))))      ; delivered bread
    (define flour-d (slack (lg "flour" (cell "town" 0))))      ; flour left
    (define from-stock (max 0.0 (- baked milled)))             ; flour consumed beyond what was milled = stock draw
    (define soil-used (- (flows-on (lg "soil" (cell "town" 0)))))  ; soil consumed (flows are negative)

    ;; ── (3) VF output ──
    (define-values (work-intents work-coms _cands) (plan->work x cols idx))
    (define mat-coms (plan->material x cols idx))
    (define mat-pairs (map (lambda (c) (cons (commitment-action c) (commitment-resource-conforms-to c))) mat-coms))
    (define (idx-of pred) (let loop ((l mat-pairs) (i 0)) (cond ((null? l) -1) ((pred (car l)) i) (else (loop (cdr l) (+ i 1))))))
    (define grain-ok (let ((p (idx-of (lambda (kv) (and (eq? (car kv) 'produce) (equal? (cdr kv) "grain")))))
                           (c (idx-of (lambda (kv) (and (eq? (car kv) 'consume) (equal? (cdr kv) "grain"))))))
                       (and (>= p 0) (>= c 0) (< p c))))       ; grow before mill
    (define flour-ok (let ((p (idx-of (lambda (kv) (and (eq? (car kv) 'produce) (equal? (cdr kv) "flour")))))
                           (c (idx-of (lambda (kv) (and (eq? (car kv) 'consume) (equal? (cdr kv) "flour"))))))
                       (and (>= p 0) (>= c 0) (< p c))))       ; mill before bake

    (format #t "~%── bread chain · flour stock 30 · soil cap 30 · bread demand 50 ──~%")
    (format #t "  milled ~,1f , baked(=bread) ~,1f , flour from stock ~,1f , flour left ~,1f , soil used ~,1f~%"
            milled baked from-stock flour-d soil-used)
    (format #t "  worst balance slack over all ~a goods = ~,4f  (≥0 ⇒ coherent)~%" (length (append goods raws)) worst)
    (format #t "  VF emitted: ~a work-intents, ~a work-commitments, ~a material-commitments~%"
            (length work-intents) (length work-coms) (length mat-coms))
    (format #t "  material order: ~a~%" (map (lambda (kv) (format #f "~a ~a" (car kv) (cdr kv))) (take mat-pairs (min 6 (length mat-pairs)))))

    (let* ((c1 (and (= n-neg 0) (>= worst (- tol))))           ; NO good over-consumed — recipe composition coherent
           (c2 (> bread 49.0))                                 ; demand met
           (c3 (and (> from-stock 15.0) (>= flour-d (- tol)))) ; the stock is USED (not just milled) and never over-drawn
           (c4 (<= soil-used (+ 30.0 tol)))                    ; the soil raw never exceeds its cap
           (c5 (and (> (length work-intents) 0) (> (length work-coms) 0) (> (length mat-coms) 0)))  ; real VF records
           (c6 (and grain-ok flour-ok))                        ; material commitments are dependency-ordered
           (ok (and c1 c2 c3 c4 c5 c6)))
      (format #t "~%  [~a] every good's balance holds — no negative inventory, every consume covered  (worst slack ~,4f, ~a violations)~%" (if c1 "✓" "✗") worst n-neg)
      (format #t "  [~a] demand met from stock + production                                   (bread ~,1f / 50)~%" (if c2 "✓" "✗") bread)
      (format #t "  [~a] EXISTING STOCK drawn down (consumed > milled) and never over-drawn    (from stock ~,1f, flour left ~,1f)~%" (if c3 "✓" "✗") from-stock flour-d)
      (format #t "  [~a] the soil raw is never consumed past its cap                           (soil ~,1f ≤ 30)~%" (if c4 "✓" "✗") soil-used)
      (format #t "  [~a] the plan IS ValueFlows: work intents + commitments + material commitments~%" (if c5 "✓" "✗"))
      (format #t "  [~a] material commitments are dependency-ordered (produce before consume)~%" (if c6 "✓" "✗"))
      (format #t "~%  ~a the solution is real, coherent ValueFlows: balanced recipe composition, existing stock respected & used~%~%" (if ok "✓" "✗"))
      (exit (if ok 0 1)))))
