;;; spacetime-newton.scm — THE DECISIVE EXPERIMENT.
;;;
;;; Hypothesis: the spatial/temporal/federation problem is ONE convex program, and
;;; the certified interior-point NEWTON method (the one relaxation.scm now uses)
;;; solves it monolithically — no ADMM, no hinge, no proximal, no dual clamp, no
;;; barrier-restore hack. If so, spatial-core's whole first-order scaffold (and its
;;; infeasible-cell TRAP) dissolves, and two solvers become one.
;;;
;;; The activity vector is x = { p(good,cell) production, m(good,edge) move }, and
;;; — crucially — delivered(g,c), labour(c) and draw(r,c) are all LINEAR in x. So
;;; the program is (quadratic desire) + (log-barriers of linear forms): its
;;; gradient and Hessian are ANALYTIC and exact (no finite-difference noise). We
;;; minimise, along the central path t: 1 → 0.02 with a full-Newton step at each t,
;;;
;;;   −harmony(x;t) = Σ_demand w·gap²                              (desire, the f₀)
;;;                 + t·[ Σ −log(delivered) + Σ −log(A−labour)
;;;                     + Σ −log(cap−draw) + Σ −log(x_i) ]         (the barriers)
;;;
;;; Transport (spatial move) and storage (temporal move) are just activities with a
;;; labour cost; site- and timing-selection are the continuous optimum choosing
;;; among them. Run:  guile -L module module/playnet/planner/spacetime-newton.scm

(use-modules (srfi srfi-1) (ice-9 format))

;; ── dense linear solve (Gaussian elimination, partial pivot) ─────────────────
(define (gauss-solve A b n)
  (let ((M (make-vector n)) (x (make-vector n 0.0)))
    (do ((i 0 (+ i 1))) ((= i n))
      (let ((row (make-vector (+ n 1) 0.0)))
        (do ((j 0 (+ j 1))) ((= j n)) (vector-set! row j (vector-ref (vector-ref A i) j)))
        (vector-set! row n (vector-ref b i)) (vector-set! M i row)))
    (do ((c 0 (+ c 1))) ((= c n))
      (let ((piv c) (best (abs (vector-ref (vector-ref M c) c))))
        (do ((r (+ c 1) (+ r 1))) ((= r n))
          (let ((v (abs (vector-ref (vector-ref M r) c)))) (when (> v best) (set! best v) (set! piv r))))
        (let ((tmp (vector-ref M c))) (vector-set! M c (vector-ref M piv)) (vector-set! M piv tmp))
        (let ((d (vector-ref (vector-ref M c) c)))
          (when (> (abs d) 1e-14)
            (do ((r (+ c 1) (+ r 1))) ((= r n))
              (let ((f (/ (vector-ref (vector-ref M r) c) d)))
                (do ((j c (+ j 1))) ((> j n))
                  (vector-set! (vector-ref M r) j
                               (- (vector-ref (vector-ref M r) j) (* f (vector-ref (vector-ref M c) j)))))))))))
    (do ((i (- n 1) (- i 1))) ((< i 0))
      (let ((s (vector-ref (vector-ref M i) n)))
        (do ((j (+ i 1) (+ j 1))) ((= j n)) (set! s (- s (* (vector-ref (vector-ref M i) j) (vector-ref x j)))))
        (let ((d (vector-ref (vector-ref M i) i)))
          (vector-set! x i (if (> (abs d) 1e-14) (/ s d) 0.0)))))
    x))

;; ── the located activity model (the ONE program's data) ─────────────────────
(define *goods* '())          ; producible goods (finals first)
(define *raws*  '())          ; drawn, not produced
(define *cells* '())          ; spacetime cells "place@period"
(define *bom*   (make-hash-table))  ; good -> alist (input . qty)
(define *ell*   (make-hash-table))  ; good -> work-hours per unit
(define *cons*  (make-hash-table))  ; input -> alist (output . qty)   [reverse BOM]
(define *demand* (make-hash-table)) ; "good|cell" -> D
(define *prio*   (make-hash-table)) ; good -> desire weight
(define *A*      (make-hash-table)) ; cell -> labour available
(define *cap*    (make-hash-table)) ; "raw|cell" -> ecological cap
(define *init*   (make-hash-table)) ; "good|cell" -> initial on-hand
(define *edges*  '())         ; list of (good from to cost ret) — allowed moves
(define *keys*   '())         ; activity keys (ordered) -> the vector x
(define *idx*    (make-hash-table)) ; key-string -> index

(define (kk . parts) (string-join (map (lambda (p) (if (number? p) (number->string p) p)) parts) "|"))
(define (fidx k) (hash-ref *idx* k))
(define (consumers g) (hash-ref *cons* g '()))
(define (derive-cons!)
  (hash-clear! *cons*)
  (hash-for-each (lambda (out ins) (for-each (lambda (io)
                   (hash-set! *cons* (car io) (acons out (cdr io) (consumers (car io))))) ins)) *bom*))
(define (build-keys!)
  (set! *keys*
    (append (append-map (lambda (g) (map (lambda (c) (kk "p" g c)) *cells*)) *goods*)
            (map (lambda (e) (kk "m" (car e) (cadr e) (caddr e))) *edges*)))
  (hash-clear! *idx*)
  (let ((i 0)) (for-each (lambda (k) (hash-set! *idx* k i) (set! i (+ i 1))) *keys*)))
(define (edge-cost e) (list-ref e 3))
(define (edge-ret  e) (list-ref e 4))

;; value readers over an activity vector x (for the warm start + reporting)
(define (getp x g c) (let ((i (fidx (kk "p" g c)))) (if i (vector-ref x i) 0.0)))
(define (getm x g a b) (let ((i (fidx (kk "m" g a b)))) (if i (vector-ref x i) 0.0)))
(define (consumed x g c) (fold (lambda (oc a) (+ a (* (cdr oc) (getp x (car oc) c)))) 0.0 (consumers g)))
(define (labour-v x c)
  (+ (fold (lambda (g a) (+ a (* (getp x g c) (hash-ref *ell* g 0.0)))) 0.0 *goods*)
     (fold (lambda (e a) (if (equal? (cadr e) c) (+ a (* (edge-cost e) (getm x (car e) c (caddr e)))) a)) 0.0 *edges*)))
(define (delivered-v x g c)
  (- (+ (hash-ref *init* (kk g c) 0.0) (getp x g c)
        (fold (lambda (e a) (if (and (equal? (car e) g) (equal? (caddr e) c)) (+ a (* (edge-ret e) (getm x g (cadr e) c))) a)) 0.0 *edges*))
     (consumed x g c)
     (fold (lambda (e a) (if (and (equal? (car e) g) (equal? (cadr e) c)) (+ a (getm x g c (caddr e))) a)) 0.0 *edges*)))
(define (gap supply D) (if (<= D 0.0) 0.0 (max 0.0 (/ (- D supply) D))))

;; ── linear forms: (constant . ((index . coeff) …)) ───────────────────────────
(define (fval f x) (+ (car f) (fold (lambda (ic a) (+ a (* (cdr ic) (vector-ref x (car ic))))) 0.0 (cdr f))))
(define (fneg f)   (cons (- (car f)) (map (lambda (ic) (cons (car ic) (- (cdr ic)))) (cdr f))))   ; const − form
(define (fshift k f) (cons (+ k (car f)) (cdr f)))
(define (delivered-form g c)                ; LINEAR: init + p + Σret·m_in − consumed − Σm_out
  (let ((coeffs (list (cons (fidx (kk "p" g c)) 1.0))) (const (hash-ref *init* (kk g c) 0.0)))
    (for-each (lambda (oc) (set! coeffs (cons (cons (fidx (kk "p" (car oc) c)) (- (cdr oc))) coeffs))) (consumers g))
    (for-each (lambda (e)
                (when (equal? (car e) g)
                  (cond ((equal? (caddr e) c) (set! coeffs (cons (cons (fidx (kk "m" g (cadr e) c)) (edge-ret e)) coeffs)))
                        ((equal? (cadr e) c)  (set! coeffs (cons (cons (fidx (kk "m" g c (caddr e))) -1.0) coeffs))))))
              *edges*)
    (cons const coeffs)))
(define (labour-form c)                     ; LINEAR: Σ ell·p + Σ cost·m_out
  (let ((coeffs '()))
    (for-each (lambda (g) (let ((e (hash-ref *ell* g 0.0))) (when (> e 0.0) (set! coeffs (cons (cons (fidx (kk "p" g c)) e) coeffs))))) *goods*)
    (for-each (lambda (e) (when (equal? (cadr e) c) (set! coeffs (cons (cons (fidx (kk "m" (car e) c (caddr e))) (edge-cost e)) coeffs)))) *edges*)
    (cons 0.0 coeffs)))
(define (draw-form r c)                      ; LINEAR: Σ bom[h][r]·p(h,c)
  (cons 0.0 (map (lambda (oc) (cons (fidx (kk "p" (car oc) c)) (cdr oc))) (consumers r))))

(define *bforms* '())   ; barrier slack-forms (each must stay > 0)
(define *dforms* '())   ; desires: (delivered-form D weight)
(define *labform* '())  ; total labour, as ONE linear form (the free-time term)
(define *kappa* 0.02)   ; weight on free time: a small cost on labour prunes wasted activity
(define (build-forms!)
  (set! *bforms* '()) (set! *dforms* '())
  (set! *labform* (cons 0.0 (append-map (lambda (c) (cdr (labour-form c))) *cells*)))
  (for-each (lambda (g) (for-each (lambda (c) (set! *bforms* (cons (delivered-form g c) *bforms*))) *cells*)) *goods*)
  (for-each (lambda (c) (let ((A (hash-ref *A* c #f))) (when A (set! *bforms* (cons (fshift A (fneg (labour-form c))) *bforms*))))) *cells*)
  (for-each (lambda (r) (for-each (lambda (c) (let ((cap (hash-ref *cap* (kk r c) #f)))
              (when cap (set! *bforms* (cons (fshift cap (fneg (draw-form r c))) *bforms*))))) *cells*)) *raws*)
  (for-each (lambda (k) (set! *bforms* (cons (cons 0.0 (list (cons (fidx k) 1.0))) *bforms*))) *keys*)   ; x ≥ 0
  (for-each (lambda (kc) (let* ((p (string-split (car kc) #\|)) (g (car p)) (c (cadr p)))
              (set! *dforms* (cons (list (delivered-form g c) (cdr kc) (hash-ref *prio* g 0.0)) *dforms*)))) (hash-map->list cons *demand*)))

;; ── analytic value / gradient / Hessian of −harmony at barrier t ─────────────
(define (obj-value x t)
  (+ (* *kappa* (fval *labform* x))               ; free time: a little labour-thrift
     (fold (lambda (d a) (let* ((s (fval (car d) x)) (D (cadr d)) (w (caddr d)))
                           (if (< s D) (+ a (* w (expt (/ (- D s) D) 2))) a))) 0.0 *dforms*)
     (fold (lambda (f a) (let ((v (fval f x))) (if (<= v 1e-12) (+ a 1e12) (+ a (* (- t) (log v)))))) 0.0 *bforms*)))
(define (obj-grad-hess x t)
  (let* ((n (vector-length x)) (g (make-vector n 0.0)) (H (make-vector n)))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! H i (make-vector n 0.0)))
    (for-each (lambda (f)                       ; barrier: −t·a_i/v in grad, +t·a_i a_j/v² in Hess
                (let ((v (fval f x)))
                  (when (> v 1e-12)
                    (let ((tv (/ t v)) (tv2 (/ t (* v v))))
                      (for-each (lambda (ic)
                        (let ((i (car ic)) (ai (cdr ic)))
                          (vector-set! g i (- (vector-ref g i) (* tv ai)))
                          (for-each (lambda (jc) (let ((row (vector-ref H i)))
                            (vector-set! row (car jc) (+ (vector-ref row (car jc)) (* tv2 ai (cdr jc)))))) (cdr f))))
                        (cdr f))))))
              *bforms*)
    (for-each (lambda (d)                        ; desire (when gap>0): grad −2w(D−s)a_i/D², Hess 2w a_i a_j/D²
                (let* ((f (car d)) (D (cadr d)) (w (caddr d)) (s (fval f x)))
                  (when (< s D)
                    (let ((gc (/ (* -2.0 w (- D s)) (* D D))) (hc (/ (* 2.0 w) (* D D))))
                      (for-each (lambda (ic)
                        (let ((i (car ic)) (ai (cdr ic)))
                          (vector-set! g i (+ (vector-ref g i) (* gc ai)))
                          (for-each (lambda (jc) (let ((row (vector-ref H i)))
                            (vector-set! row (car jc) (+ (vector-ref row (car jc)) (* hc ai (cdr jc)))))) (cdr f))))
                        (cdr f))))))
              *dforms*)
    (for-each (lambda (ic) (vector-set! g (car ic) (+ (vector-ref g (car ic)) (* *kappa* (cdr ic))))) (cdr *labform*))  ; free time (linear)
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! (vector-ref H i) i (+ (vector-ref (vector-ref H i) i) 1e-7)))   ; ridge
    (values g H)))

(define (newton x t iters)
  (let loop ((k 0) (x x))
    (if (>= k iters) x
        (call-with-values (lambda () (obj-grad-hess x t))
          (lambda (g H)
            (let* ((n (vector-length x))
                   (gn (sqrt (let ((s 0.0)) (do ((i 0 (+ i 1))) ((= i n) s) (set! s (+ s (expt (vector-ref g i) 2)))))))
                   (negg (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (- (vector-ref g i)))) v))
                   (d (gauss-solve H negg n)) (f0 (obj-value x t)))
              (if (< gn 1e-7) x
                  (let ls ((eta 1.0))
                    (let* ((y (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (+ (vector-ref x i) (* eta (vector-ref d i))))) v))
                           (fy (obj-value y t)))
                      (cond ((and (< fy 1e11) (< fy (- f0 1e-12))) (loop (+ k 1) y))
                            ((< eta 1e-9) x)
                            (else (ls (* eta 0.5)))))))))))))

(define (solve)
  (build-keys!) (build-forms!)
  (let* ((n (length *keys*)) (x (make-vector n 0.05)))
    (for-each (lambda (c)                      ; feasible warm start: chain-consistent tiny production
                (let ((mult (make-hash-table)))
                  (for-each (lambda (g)
                              (let ((need (fold (lambda (oc a) (+ a (* (cdr oc) (hash-ref mult (car oc) 0.0)))) 0.0 (consumers g))))
                                (hash-set! mult g (+ 0.5 need))
                                (let ((i (fidx (kk "p" g c)))) (when i (vector-set! x i (+ 0.5 need))))))
                            *goods*)))                ; finals first, so each good's level exceeds what its consumers draw
              *cells*)
    (let loop ((t 1.0) (x x))
      (let ((x* (newton x t 60)))
        (if (<= t 0.02) (values x* t) (loop (max 0.02 (* t 0.5)) x*))))))

;; ── reporting ────────────────────────────────────────────────────────────────
(define (period-of c) (substring c (1+ (string-index c #\@))))
(define (report)
  (call-with-values solve
    (lambda (x t)
      (format #t "   production p(good, cell):~%")
      (for-each (lambda (g)
                  (format #t "     ~8a ~a~%" g
                          (string-concatenate (map (lambda (c) (format #f "  ~a ~6,1f" c (getp x g c))) *cells*))))
                *goods*)
      (let ((any #f))
        (for-each (lambda (e) (let ((v (getm x (car e) (cadr e) (caddr e))))
                                (when (> v 0.5) (unless any (format #t "   moves:~%") (set! any #t))
                                      (format #t "     ~a  ~a -> ~a  ~6,1f  (~a)~%" (car e) (cadr e) (caddr e) v
                                              (if (string=? (period-of (cadr e)) (period-of (caddr e))) "ship" "store")))))
                  *edges*))
      (for-each (lambda (c)
                  (let ((u (labour-v x c)) (A (hash-ref *A* c 1e9)))
                    (when (< A 1e8)
                      (format #t "     labour@~a  ~6,1f/~a  pull ~7,3f~%" c u A (if (>= u A) 1e6 (/ t (- A u)))))))
                *cells*)
      (for-each (lambda (kc)
                  (let* ((p (string-split (car kc) #\|)) (g (car p)) (c (cadr p)) (dlv (delivered-v x g c)))
                    (format #t "   demand ~a@~a delivered ~6,1f/~a  (gap ~,2f)~%" g c dlv (cdr kc) (gap dlv (cdr kc)))))
                (hash-map->list cons *demand*))
      (format #t "   [interior-point: t=~,3f]~%" t))))

;; ── world setup ──────────────────────────────────────────────────────────────
(define (reset!)
  (set! *goods* '()) (set! *raws* '()) (set! *cells* '()) (set! *edges* '())
  (for-each hash-clear! (list *bom* *ell* *cons* *demand* *prio* *A* *cap* *init*)))
(define (chain!)
  (set! *goods* '("bread" "flour" "grain")) (set! *raws* '("soil"))
  (hash-set! *bom* "bread" '(("flour" . 1.0))) (hash-set! *ell* "bread" 0.5)
  (hash-set! *bom* "flour" '(("grain" . 1.2))) (hash-set! *ell* "flour" 0.3)
  (hash-set! *bom* "grain" '(("soil"  . 1.0))) (hash-set! *ell* "grain" 0.5)
  (derive-cons!) (hash-set! *prio* "bread" 1000.0))

(define (setup-space tau)                   ; city/country; soil scarce in city, abundant in country
  (reset!) (chain!) (set! *cells* '("city@0" "country@0"))
  (set! *edges* (append-map (lambda (g) (list (list g "city@0" "country@0" (* tau 111.0) 1.0)
                                              (list g "country@0" "city@0" (* tau 111.0) 1.0))) *goods*))
  (hash-set! *demand* (kk "bread" "city@0") 100.0)
  (hash-set! *cap* (kk "soil" "city@0") 20.0) (hash-set! *cap* (kk "soil" "country@0") 200.0)
  (hash-set! *A* "city@0" 120.0) (hash-set! *A* "country@0" 70.0))
(define (setup-time t1-labour hold storable?) ; one town, two periods; bread wanted at t1
  (reset!) (chain!) (set! *cells* '("town@0" "town@1"))
  (set! *edges* (if storable? (map (lambda (g) (list g "town@0" "town@1" hold 1.0)) *goods*) '()))
  (hash-set! *demand* (kk "bread" "town@1") 100.0)
  (hash-set! *cap* (kk "soil" "town@0") 400.0) (hash-set! *cap* (kk "soil" "town@1") 400.0)
  (hash-set! *A* "town@0" 250.0) (hash-set! *A* "town@1" t1-labour))

;; ── run ──────────────────────────────────────────────────────────────────────
(format #t "~%==== ONE PROGRAM, ONE NEWTON — SPACE ====~%")
(format #t "~%-- cheap transport (grow country, ship to city)~%")          (setup-space 0.002) (report)
(format #t "~%-- dear transport (processing pulls toward country)~%")       (setup-space 0.04)  (report)
(format #t "~%==== ONE PROGRAM, ONE NEWTON — TIME ====~%")
(format #t "~%-- deep valley (t1=40), storable -> build ahead + store~%")   (setup-time 40.0 0.01 #t) (report)
(format #t "~%-- shallow valley (t1=100), storable -> less built ahead~%")  (setup-time 100.0 0.01 #t) (report)
(format #t "~%-- THE TRAP CASE: perishable spike (t1=40, NOT storable) -> clean gap?~%")
(setup-time 40.0 0.01 #f) (report)
(newline)
