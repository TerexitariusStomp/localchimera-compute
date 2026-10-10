;;; test-optimal-face.scm — on a plateau, the honest claim is membership in the
;;; optimal FACE, not distance to a point.
;;;
;;; Spec: docs/social-category.typ §5.3 + §8 Obligation 8 (a plan carries its
;;;       proof) and docs/playnet.typ §7.11.
;;;
;;; The certified bound is f(x) − f(x*) ≤ m·μ + min(‖r‖·D, ‖r‖²/(2σ)). Where the
;;; objective is flat the curvature branch is +inf and only the geometry branch
;;; survives, often loosely. The standard remedy is to weaken the regularity
;;; assumption — Polyak–Łojasiewicz, or Kurdyka–Łojasiewicz with an exponent —
;;; and on THIS objective it does not apply, for a reason worth being exact
;;; about: the flatness is not a failure of regularity. A desire term is
;;; w·((D−s)/D)² only while s < D and is identically zero afterwards, so past
;;; satiation f is genuinely constant along those directions. A PL constant
;;; vanishes there for the same reason σ does. There is no distance to bound
;;; because the optimum is not a point.
;;;
;;; What IS provable is the dimension of the optimal face, constructively: a
;;; coordinate with no gradient and no curvature at barrier weight 0 is a
;;; direction the plan can move along with no loss, and an interior-point iterate
;;; is strictly feasible so a small step stays feasible. This test does not take
;;; that argument on trust — it takes the coordinates the certificate reports as
;;; free and MOVES ALONG THEM, checking that the objective is unchanged and the
;;; plan still feasible. A claim about a direction is checked by walking it.
;;;
;;; DIMENSION IS NOT EXTENT. A free direction the plan has no room to take is
;;; still a free direction, and reporting only the dimension would call that
;;; "many equally good plans" when there is effectively one. Each section below
;;; therefore measures how far the plan can actually move before a constraint
;;; stops it, and the priced-cycle case exists precisely because its answer is
;;; "not at all".
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-optimal-face.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet vf formulas tension-kinds)
             (srfi srfi-1)
             (ice-9 format))

(define (res spec loc q)
  (make-economic-resource #:id (string-append spec "@" loc) #:conforms-to spec #:classified-as '()
    #:accounting-quantity (make-measure q "kg") #:onhand-quantity (make-measure q "kg") #:current-location loc))
(define (place id lat lon) (make-spatial-thing #:id id #:lat lat #:long lon))
(define (worker id loc) (make-agent #:id id #:type 'person #:name id #:primary-location loc
                                    #:classified-as '("general")))

;; ════════════════════════════════════════════════════════════════════════════
;; (1) a curved program: the optimum is a POINT, and nothing claims otherwise
;; ════════════════════════════════════════════════════════════════════════════
;; The rig from test-certificate.scm, whose optimum is known analytically to be
;; x* = 9.0839543 — a single point. The desire is unsatiated there (s = 9.08 < 20)
;; so it carries curvature, and the frag term carries its own fixed weight. No
;; coordinate is free, and the report must say 0 rather than volunteering a face
;; that is not there.
(display "\n── a strictly curved optimum is a point ──\n")

(define (rig)
  (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 20.0 1000.0)
        (mk-frag 10.0 (list (cons 0 -1.0)) 50.0)
        (mk-bar 0.0 '((0 . 1.0)))))

(let* ((r (call-with-values (lambda () (solve-native-c-pd (rig) '() (vector 1.0))) list))
       (x (car r))
       (k (kkt-report (flatten (rig)) '() x)))
  (format #t "  x = ~,6f   σ = ~,3e   face-dim = ~a\n"
          (vector-ref x 0) (assq-ref k 'sigma) (assq-ref k 'face-dim))
  (check "the curved rig reports no free direction"
         (= (assq-ref k 'face-dim) 0))
  (check "…and it still certifies a finite bound"
         (< (assq-ref k 'gap-bound) +inf.0)))

;; ════════════════════════════════════════════════════════════════════════════
;; (2) a free bidirectional arc: the optimum is a FACE, and the report says so
;; ════════════════════════════════════════════════════════════════════════════
;; The economy from decomposition-invariance-test, but with the transport arc
;; left BIDIRECTIONAL at τ = 0 — the configuration that test deliberately avoids.
;; Its header records what happens: flour can be shipped A→B→A forever at no
;; charge, "a null direction of the objective — strict concavity fails along it
;; and 'the' optimum stops being unique (observed: both move columns running at
;; ~5·10⁴ with a net of ~160)". That was a diagnosis written in prose next to a
;; workaround. Here it is a measured property of the certificate.
(display "\n── a zero-cost cycle makes the optimum a face ──\n")

(define A (place "a-home" 42.70 23.32))
(define B (place "b-home" 42.75 23.40))
(define bake-p (list (rp "bake" "Bake bread")))
(define bake-f (list (out "o" "bread" 1.0 "bake")
                     (in  "i" "flour" 1.0 "bake")
                     (wrk "w" 0.1 "bake")))

(ingest-records!
  (list (res "flour" "a-home" 300.0))
  (list (worker "wa" "a-home") (worker "wb" "b-home"))
  (list A B) bake-p bake-f
  #:demand (list (cons (lg "bread" (cell "a-home" 0)) 5.0)
                 (cons (lg "bread" (cell "b-home" 0)) 40.0))
  #:never-raw '("flour")
  #:movable '("flour")
  #:tau 0.0                     ; free transport, BOTH ways — the null direction
  #:per-agent? #f)

(define fx #f) (define fforms #f) (define flab #f) (define fidx #f)
(call-with-values build-located
  (lambda (forms labform ncol cols goods raws idx)
    (call-with-values (lambda () (solve forms labform (located-warm cols ncol idx)))
      (lambda (x . _)
        (set! fx x) (set! fforms forms) (set! flab labform) (set! fidx idx)))))

(define C (flatten fforms))
(define kf (kkt-report C flab fx))
(define face (assq-ref kf 'face-dim))

(format #t "  σ = ~,3e   ‖r‖ = ~,3e   face-dim = ~a\n"
        (assq-ref kf 'sigma) (assq-ref kf 'residual) face)
(format #t "  ~a\n" (let () (set-certificate-from-kkt! kf) (certificate-summary)))

(check "the free cycle is detected as a face, not reported as a unique optimum"
       (> face 0))
(check "…and the summary says equally good plans lie along it"
       (string-contains (certificate-summary) "equally good plans lie along it"))
;; The certificate now MEASURES the room rather than declining to. It used to
;; say the extent was "a separate measurement" — true, and useless to a reader
;; who then had no way to make it. Same dimension reads opposite ways depending
;; on this number, so the number travels with the plan.
(check "…and reports how much room there actually is"
       (> (assq-ref kf 'face-extent) 1.0))
(check "…in words too, as a choice rather than a computation"
       (string-contains (certificate-summary) "not a computation"))

;; ── the constructive part: walk the directions the certificate exhibits ─────
;; A face of dimension ≥ k is a claim about k directions. It is checked by
;; building them, stepping along each, and confirming both things asserted: the
;; objective does not change and the plan stays feasible. The basis is built by
;; the same two rules the certificate counts by, so if either rule ever counts a
;; direction that is not free, this fails — which is the only thing separating a
;; proof from a plausible argument about one.
(display "\n── walking the exhibited directions ──\n")

(define (curved-signatures C n sv)        ; → vector of ((form . coeff) …) over curved forms
  (let ((sig (make-vector n '())) (nt (cnt C))
        (ptr (cptr C)) (idx (cidx C)) (val (cval C)))
    (do ((ti 0 (+ ti 1))) ((= ti nt))
      (let ((c ((kind-curv (vector-ref *kind-fns* (vector-ref (ckind C) ti)))
                (vector-ref sv ti) 0.0 (vector-ref (cD C) ti) (vector-ref (cw C) ti))))
        (when (> c 0.0)
          (do ((k (vector-ref ptr ti) (+ k 1))) ((= k (vector-ref ptr (+ ti 1))))
            (let ((j (vector-ref idx k)))
              (vector-set! sig j (cons (cons ti (vector-ref val k)) (vector-ref sig j))))))))
    sig))

(define (face-directions C n g0 sv)       ; → list of dense direction vectors
  (let* ((sig (curved-signatures C n sv))
         (gs (sqrt (let lp ((i 0) (a 0.0))
                     (if (= i n) a (lp (+ i 1) (+ a (expt (vector-ref g0 i) 2)))))))
         (tol (* 1e-9 (+ 1.0 gs)))
         (free (let lp ((j (- n 1)) (acc '()))
                 (if (< j 0) acc (lp (- j 1) (if (null? (vector-ref sig j)) (cons j acc) acc)))))
         (binds (find (lambda (j) (> (abs (vector-ref g0 j)) tol)) free))
         (e (lambda (j) (let ((d (make-vector n 0.0))) (vector-set! d j 1.0) d))))
    (append
     ;; FAMILY 1 — untouched columns. With the gradient inert on them, each axis
     ;; is free on its own. With it live, one condition binds and the free set is
     ;; the differences that cancel it: e_j − (g_j/g_p)·e_p against a pivot p.
     (cond ((null? free) '())
           ((not binds) (map e free))
           (else
            (let ((p binds) (gp (vector-ref g0 binds)))
              (filter-map
               (lambda (j)
                 (and (not (= j p))
                      (let ((d (e j)))
                        (vector-set! d p (- (/ (vector-ref g0 j) gp)))
                        d)))
               free))))
     ;; FAMILY 2 — interchangeable columns: identical across every curved form and
     ;; equal in gradient, so e_j − e_k moves neither the objective nor any curved
     ;; slack. A group of g yields g−1 of them.
     (let ((groups (make-hash-table)))
       (let lp ((j 0))
         (when (< j n)
           (unless (null? (vector-ref sig j))
             (hash-set! groups (vector-ref sig j)
                        (cons j (hash-ref groups (vector-ref sig j) '()))))
           (lp (+ j 1))))
       (hash-fold
        (lambda (k cols acc)
          (let lp ((cs (sort cols (lambda (a b) (< (vector-ref g0 a) (vector-ref g0 b)))))
                   (out acc))
            (if (or (null? cs) (null? (cdr cs))) out
                (if (<= (abs (- (vector-ref g0 (car cs)) (vector-ref g0 (cadr cs)))) tol)
                    (let ((d (e (car cs))))
                      (vector-set! d (cadr cs) -1.0)
                      (lp (cdr cs) (cons d out)))
                    (lp (cdr cs) out)))))
        '() groups)))))

;; How far the plan can actually MOVE along d before a constraint stops it. The
;; slacks are affine in the step — s_i(x + t·d) = s_i + t·(a_i·d) — so this is
;; exact, not a search. It matters because a face's DIMENSION says nothing about
;; its EXTENT: the plan can sit on the face's own boundary, with a genuine free
;; direction it has no room to take. Reporting dimension alone would call that
;; "many equally good plans" when there is exactly one.
(define (max-step C x d)
  (let ((nt (cnt C)) (ptr (cptr C)) (idx (cidx C)) (val (cval C))
        (sv (term-values C x)))
    (let lp ((ti 0) (best +inf.0))
      (if (= ti nt) best
          (lp (+ ti 1)
              (if (memv (vector-ref (ckind C) ti) '(0 3))
                  (let ((ad (let l2 ((k (vector-ref ptr ti)) (a 0.0))
                              (if (= k (vector-ref ptr (+ ti 1))) a
                                  (l2 (+ k 1) (+ a (* (vector-ref val k)
                                                      (vector-ref d (vector-ref idx k)))))))))
                    (if (< ad 0.0) (min best (- (/ (vector-ref sv ti) ad))) best))
                  best))))))

;; walk a basis → (largest-objective-change feasible? extent)
(define (walk C labform x dirs step)
  (let* ((sv0 (term-values C x))
         (f0 (obj-value C labform 0.0 x sv0))
         (worst 0.0) (ok #t) (extent +inf.0) (roomiest 0.0))
    (for-each
     (lambda (d)
       (for-each
        (lambda (sgn)
          (let* ((sd (let ((v (make-vector (vector-length x) 0.0)))
                       (do ((i 0 (+ i 1))) ((= i (vector-length x)) v)
                         (vector-set! v i (* sgn (vector-ref d i))))))
                 (room (max-step C x sd))
                 ;; step INSIDE the feasible interval: the claim is about a
                 ;; neighbourhood, so a step that leaves the region tests nothing
                 (t (* 0.5 (min step room))))
            (set! extent (min extent room))
            (set! roomiest (max roomiest room))
            (let ((y (vector-copy x)))
              (do ((i 0 (+ i 1))) ((= i (vector-length x)))
                (vector-set! y i (+ (vector-ref y i) (* t (vector-ref sd i)))))
              (let* ((sv (term-values C y))
                     (f1 (obj-value C labform 0.0 y sv))
                     (mins (let lp ((ti 0) (m +inf.0))
                             (if (= ti (cnt C)) m
                                 (lp (+ ti 1)
                                     (if (memv (vector-ref (ckind C) ti) '(0 3))
                                         (min m (vector-ref sv ti)) m))))))
                (set! worst (max worst (abs (- f1 f0))))
                (unless (> mins 0.0) (set! ok #f))))))
        '(1.0 -1.0)))
     dirs)
    ;; TWO statistics, because they answer different questions. EXTENT is the
    ;; min over every direction AND both signs — "the plan is interior in every
    ;; direction at once", which an optimum generally is not: being optimal
    ;; means sitting ON some bound. ROOMIEST is the best room along a free
    ;; direction, which is what `optimal-face-extent` reports in the certificate
    ;; and what "is this face inhabited?" actually asks.
    (list worst ok extent roomiest)))

(define n (vector-length fx))
(define sv0 (term-values C fx))
(define g00 (csr-grad C flab 0.0 sv0 n))
(define dirs (face-directions C n g00 sv0))
(define f0 (obj-value C flab 0.0 fx sv0))

(format #t "  ~a exhibited direction(s); objective at the plan = ~,8f\n" (length dirs) f0)
(check "the exhibited basis has exactly the dimension the certificate claims"
       (= (length dirs) face))

(let ((w (walk C flab fx dirs 1e-3)))
  (format #t "  largest objective change ~,3e; feasible: ~a; room to move ~,3e\n"
          (car w) (if (cadr w) "yes" "NO") (caddr w))
  (check "moving along every exhibited direction leaves the objective unchanged"
         (< (car w) (* 1e-9 (+ 1.0 (abs f0)))))
  (check "…and leaves the plan feasible" (cadr w))
  ;; A FREE arc gives genuine room: this face is inhabited, not a boundary
  ;; artefact. Read as the BEST room along a free direction, the same statistic
  ;; the certificate carries (255 here) — not the min over all four
  ;; direction/sign pairs, which is 4·10⁻⁶ because the plan sits against a bound
  ;; in one of them, as an optimum does.
  (check "the face is inhabited — there is real room along a free direction"
         (> (cadddr w) 1.0))
  (check "…and the plan is still up against a bound somewhere, as an optimum is"
         (< (caddr w) 1e-3)))

(define frees (let ((sig (curved-signatures C n sv0)))
                (let lp ((j (- n 1)) (acc '()))
                  (if (< j 0) acc
                      (lp (- j 1) (if (null? (vector-ref sig j)) (cons j acc) acc))))))

;; ── and the direction is REAL work being reshuffled, not numerical dust ──────
;; A face of free directions matters only if the coordinates on it carry
;; something. These are the transport columns, and the plan is running them hard
;; in both directions at once — flour circulating A→B→A for free. That is the
;; concrete meaning of a non-unique optimum here, and it is worth showing rather
;; than leaving as an abstraction.
(let ((moved (fold (lambda (j a) (+ a (vector-ref fx j))) 0.0 frees)))
  (format #t "  total activity on the free coordinates: ~,1f units\n" moved)
  (check "the free directions carry real activity, so the face is not a rounding artefact"
         (> moved 1.0)))

;; ════════════════════════════════════════════════════════════════════════════
;; (3) a PRICED cycle: no coordinate is flat, and the face is there anyway
;; ════════════════════════════════════════════════════════════════════════════
;; The same two-place economy with τ > 0, so shipping costs labour in both
;; directions. Now NO single transport column is free — moving either one alone
;; changes the objective — and a per-coordinate test reports 0. But the two cost
;; the same, so shifting a unit from one to the other is free, and the face is
;; still there. This is the case the sharpened rule exists for: a set of columns
;; untouched by curvature needs to be COLLECTIVELY orthogonal to the gradient,
;; not individually flat.
(display "\n── a priced cycle: flat in combination, not in any coordinate ──\n")

(ingest-records!
  (list (res "flour" "a-home" 300.0))
  (list (worker "wa" "a-home") (worker "wb" "b-home"))
  (list A B) bake-p bake-f
  #:demand (list (cons (lg "bread" (cell "a-home" 0)) 5.0)
                 (cons (lg "bread" (cell "b-home" 0)) 40.0))
  #:never-raw '("flour")
  #:movable '("flour")
  #:tau 0.05                    ; shipping now COSTS — no axis is flat
  #:per-agent? #f)

(define px #f) (define pforms #f) (define plab #f)
(call-with-values build-located
  (lambda (forms labform ncol cols goods raws idx)
    (call-with-values (lambda () (solve forms labform (located-warm cols ncol idx)))
      (lambda (x . _) (set! px x) (set! pforms forms) (set! plab labform)))))

(define PC (flatten pforms))
(define pn (vector-length px))
(define psv (term-values PC px))
(define pg0 (csr-grad PC plab 0.0 psv pn))
(define pk (kkt-report PC plab px))
(define pface (assq-ref pk 'face))

;; the per-coordinate rule, computed here so the comparison is a measurement
(define per-coordinate
  (let ((sig (curved-signatures PC pn psv))
        (gs (sqrt (let lp ((i 0) (a 0.0))
                    (if (= i pn) a (lp (+ i 1) (+ a (expt (vector-ref pg0 i) 2))))))))
    (let lp ((j 0) (c 0))
      (if (= j pn) c
          (lp (+ j 1) (if (and (null? (vector-ref sig j))
                               (<= (abs (vector-ref pg0 j)) (* 1e-9 (+ 1.0 gs))))
                          (+ c 1) c))))))

(format #t "  per-coordinate rule: ~a    sharpened: ~a (~a free, ~a interchangeable)\n"
        per-coordinate (car pface) (cadr pface) (caddr pface))

(check "a priced cycle still has a face"
       (> (car pface) 0))
(check "…that the per-coordinate rule cannot see"
       (> (car pface) per-coordinate))

(let* ((pdirs (face-directions PC pn pg0 psv))
       (w (walk PC plab px pdirs 1e-4)))
  (format #t "  ~a direction(s); largest objective change ~,3e; feasible: ~a; room to move ~,3e\n"
          (length pdirs) (car w) (if (cadr w) "yes" "NO") (caddr w))
  (check "the sharpened basis has the claimed dimension"
         (= (length pdirs) (car pface)))
  (check "walking it leaves the objective unchanged — the combination really is free"
         (< (car w) (* 1e-7 (+ 1.0 (abs (obj-value PC plab 0.0 px psv))))))
  (check "…and feasible" (cadr w))
  ;; THE POINT OF THIS SECTION. The direction is genuinely free, and the plan has
  ;; essentially no room to take it: shipping costs labour, so the reverse arc
  ;; sits pinned against its own barrier and the face is one-sided here. Dimension
  ;; and extent are different questions, and only the second says whether a
  ;; federation really has a choice to make.
  (check "…but the plan sits on the face's EDGE, with no room to move — dimension is not extent"
         (< (caddr w) 1e-2))
  ;; and the CERTIFICATE says so, in the same units, without the reader having to
  ;; run this walk themselves — the whole point of carrying extent alongside
  ;; dimension rather than leaving it in a test.
  (check "the certificate reports the edge, not just the dimension"
         (< (assq-ref pk 'face-extent) 1e-2))
  (check "…and words it as nominal rather than as a choice"
         (begin (set-certificate-from-kkt! pk)
                (string-contains (certificate-summary) "nominal, not available"))))

;; ════════════════════════════════════════════════════════════════════════════
;; (4) INTERCHANGEABLE technologies: the same recipe entered twice
;; ════════════════════════════════════════════════════════════════════════════
;; Two processes with identical flows and identical labour. Any split between
;; them is equally good, so the plan's choice is arbitrary — and this is
;; invisible to every per-coordinate test, because each column is touched by the
;; bread desire and neither is flat on its own. Demand exceeds what the flour can
;; supply, so that desire is UNSATIATED and therefore curved: the columns are
;; caught by the interchangeability rule rather than by absence of curvature.
(display "\n── two names for one technology ──\n")

(define bake2-p (list (rp "bake" "Bake bread") (rp "bake2" "Bake bread, again")))
(define bake2-f (list (out "o"  "bread" 1.0 "bake")  (in "i"  "flour" 1.0 "bake")
                      (wrk "w"  0.1 "bake")
                      (out "o2" "bread" 1.0 "bake2") (in "i2" "flour" 1.0 "bake2")
                      (wrk "w2" 0.1 "bake2")))

(ingest-records!
  (list (res "flour" "a-home" 300.0))
  (list (worker "wa" "a-home"))
  (list A) bake2-p bake2-f
  #:demand (list (cons (lg "bread" (cell "a-home" 0)) 500.0))   ; unsatiable ⇒ curved
  #:never-raw '("flour")
  #:per-agent? #f)

(define tx #f) (define tforms #f) (define tlab #f)
(call-with-values build-located
  (lambda (forms labform ncol cols goods raws idx)
    (call-with-values (lambda () (solve forms labform (located-warm cols ncol idx)))
      (lambda (x . _) (set! tx x) (set! tforms forms) (set! tlab labform)))))

(define TC (flatten tforms))
(define tn (vector-length tx))
(define tsv (term-values TC tx))
(define tg0 (csr-grad TC tlab 0.0 tsv tn))
(define tface (assq-ref (kkt-report TC tlab tx) 'face))

(format #t "  face ~a = ~a free + ~a interchangeable\n"
        (car tface) (cadr tface) (caddr tface))

(check "duplicating a technology is detected as an interchangeable pair"
       (> (caddr tface) 0))

(let* ((tdirs (face-directions TC tn tg0 tsv))
       (w (walk TC tlab tx tdirs 1e-4)))
  (format #t "  ~a direction(s); largest objective change ~,3e; feasible: ~a; room to move ~,3e\n"
          (length tdirs) (car w) (if (cadr w) "yes" "NO") (caddr w))
  (check "the interchange basis has the claimed dimension"
         (= (length tdirs) (car tface)))
  (check "shifting work between the twins costs nothing"
         (< (car w) (* 1e-7 (+ 1.0 (abs (obj-value TC tlab 0.0 tx tsv))))))
  (check "…and stays feasible" (cadr w))
  (check "and here the room is real — the split between the twins is a genuine choice"
         (> (caddr w) 1.0)))

(check-done "  On a plateau the plan reports the face it lies on, not a false point.~%")
