;;; world.scm — the synthetic space-time mesh the scale benchmarks measure on.
;;;
;;; P places × T periods, each cell a chain of K goods with its own labour and
;;; eco caps, plus storage (time) and transport (space) moves. n ≈ 3·P·T·K
;;; activities of BLOCK-SPARSE structure — which is the property the near-linear
;;; scaling claim rests on, so the generator that makes it belongs beside the
;;; benches rather than inside the engine.
;;;
;;; Loaded by demo.scm (§9c, §9d) and bench/bench-scale.scm. Assumes the engine
;;; is already loaded: it calls mk-bar / mk-des / f-coeffs / solve-native.

(define* (build-world P T K #:optional (dem (lambda (p t) 100.0)))
  (let* ((ncell (* P T)) (cellof (lambda (p t) (+ (* p T) t)))
         (gid (make-hash-table)) (ng 0)
         (g! (lambda (good c) (let ((key (cons good c))) (or (hash-ref gid key) (let ((i ng)) (set! ng (+ ng 1)) (hash-set! gid key i) i)))))
         (acts '()) (na 0))
    (define (act! flows labour lcell warm) (set! acts (cons (vector na flows labour lcell warm) acts)) (set! na (+ na 1)))
    (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
      (let ((c (cellof p t)))
        (do ((i 0 (+ i 1))) ((= i K))
          (let ((o (g! (* 1000 i) c)) (inp (if (< i (- K 1)) (g! (* 1000 (+ i 1)) c) (g! 'raw c))))
            (act! (list (cons o 1.0) (cons inp -1.0)) 0.3 c (+ 110.0 i)))))))
    (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t (- T 1)))
      (do ((i 0 (+ i 1))) ((= i K))
        (act! (list (cons (g! (* 1000 i) (cellof p t)) -1.0) (cons (g! (* 1000 i) (cellof p (+ t 1))) 1.0)) 0.05 (cellof p t) 0.02))))
    (do ((p 0 (+ p 1))) ((= p (- P 1))) (do ((t 0 (+ t 1))) ((= t T))
      (do ((i 0 (+ i 1))) ((= i K))
        (act! (list (cons (g! (* 1000 i) (cellof p t)) -1.0) (cons (g! (* 1000 i) (cellof (+ p 1) t)) 1.0)) 0.1 (cellof p t) 0.02))))
    (let ((n na) (flowsby (make-vector ng '())) (forms '()) (labform '()) (bycell (make-vector ncell '())))
      (for-each (lambda (a)
                  (for-each (lambda (fc) (vector-set! flowsby (car fc) (cons (cons (vector-ref a 0) (cdr fc)) (vector-ref flowsby (car fc))))) (vector-ref a 1))
                  (when (> (vector-ref a 2) 0.0) (let ((c (vector-ref a 3))) (vector-set! bycell c (cons (cons (vector-ref a 0) (vector-ref a 2)) (vector-ref bycell c))))))
                acts)
      (let ((raw? (make-vector ng #f)))                              ; raw goods get ONLY the eco cap,
        (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))  ; NOT a delivered≥0 balance (which
          (let ((r (hash-ref gid (cons 'raw (cellof p t))))) (when r (vector-set! raw? r #t)))))  ; would force consumption to 0)
        (do ((lg 0 (+ lg 1))) ((= lg ng)) (unless (vector-ref raw? lg) (set! forms (cons (mk-bar 0.0 (vector-ref flowsby lg)) forms)))))
      (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
        (let ((lg (hash-ref gid (cons 0 (cellof p t))))) (when lg (set! forms (cons (mk-des (mk-bar 0.0 (vector-ref flowsby lg)) (dem p t) 1000.0) forms))))))
      (do ((c 0 (+ c 1))) ((= c ncell))
        (let ((lst (vector-ref bycell c)))
          (unless (null? lst)
            (set! forms (cons (mk-bar (* 1000.0 K) (map (lambda (al) (cons (car al) (- (cdr al)))) lst)) forms))
            (set! labform (append lst labform)))))
      (do ((p 0 (+ p 1))) ((= p P)) (do ((t 0 (+ t 1))) ((= t T))
        (let ((lg (hash-ref gid (cons 'raw (cellof p t))))) (when lg (set! forms (cons (mk-bar 1e6 (vector-ref flowsby lg)) forms))))))
      (do ((ai 0 (+ ai 1))) ((= ai n)) (set! forms (cons (mk-bar 0.0 (list (cons ai 1.0))) forms)))
      (let ((x0 (make-vector n 0.05)))
        (for-each (lambda (a) (vector-set! x0 (vector-ref a 0) (vector-ref a 4))) acts)
        (values forms labform n (fold (lambda (f a) (+ a (length (f-coeffs f)))) 0 forms) x0)))))
(define (timed thunk) (let ((t0 (get-internal-run-time))) (call-with-values thunk (lambda a (cons (/ (* 1000.0 (- (get-internal-run-time) t0)) internal-time-units-per-second) a)))))
;; solve* is the engine's (planner.scm, beside the federation-solve load) — three
;; studies outside the benches read a solve as a list too, so it belongs there
;; rather than here. This file would only be redefining it identically.
