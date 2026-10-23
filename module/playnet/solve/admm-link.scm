;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; solve/admm-link.scm — the ADMM step on one good, and the arithmetic around it.
;;;
;;; A good crosses between the scopes that share it: some supply it, some draw
;;; it, and which does which is what the solve finds. Each participant's flow
;;; is SIGNED — y > 0 it supplies, y < 0 it draws — so the good's constraint is
;;; Σ y = 0, and each has a copy z_p of its own flow with the consensus form
;;; y_p = z_p,  Σ z_p = 0. The z-step projects onto Σ z = 0 and the duals, all
;;; one after the first step, become ONE scaled dual u for the good — the
;;; exchange problem's ADMM (Boyd et al. 2011, §7.3). Every scope that has ever
;;; run this arithmetic — the monolith's rounds (solve-decomposed), the
;;; coordinator over oracles (solve-consensus), a good's participants
;;; exchanging messages with no coordinator at all (federation/async) — runs
;;; THIS step, so they cannot drift apart.
;;;
;;;     yh_p = α·y_p + (1−α)·z_p       z_p' = yh_p − mean(yh)       u' = u + mean(yh)
;;;
;;; α over-relaxes each flow toward its old z (1 = plain ADMM). A participant
;;; solves against the centre z_p − u, and the good's PULL is λ = ρ·u, the
;;; same number for every participant: the labour-hours one more unit of the
;;; good is worth where the crossing stands.
;;;
;;; How a scope's own columns carry its flow — a column that can only give, one
;;; that can only take, one measured from what the scope can give — is the
;;; scope's to know (the engine's crossings); nothing here reads a side.
;;;
;;; A LINK is the crossing of two: z_a = z, z_b = −z. `link-step` is
;;; `crossing-step` on those two, written for one that gives and one that takes.

(define-module (playnet solve admm-link)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (link-step link-centres crossing-step
            make-exchange exchange-keys exchange-sizes exchange-live? exchange-centre exchange-flow
            exchange-pull exchange-u exchange-rho exchange-step! exchange->vector exchange-load!
            exchange-rescale! exchange-balance! exchange-flow-scale exchange-vector-within?
            make-exchange-accelerator rho-balance exchange-rounds allocate-caps
            admm-vsub admm-vnorm admm-gsolve admm-anderson-step))

(define (crossing-step zs u ys alpha)
  "ZS, YS: per participant, its signed agreed flow and its signed flow as last
   solved; U the good's scaled dual. → (values zs' u')."
  (let* ((yh (map (lambda (z y) (+ (* alpha y) (* (- 1.0 alpha) z))) zs ys))
         (mean (/ (fold + 0.0 yh) (length yh))))
    (values (map (lambda (h) (- h mean)) yh) (+ u mean))))

(define (link-step z us ur y-a y-b alpha)
  "→ (values z' us' ur') after one step on what the one that gives put on the
   good, Y-A, and what the one that takes took of it, Y-B, both as amounts. The
   two duals are each other's negation, so US carries the pull and UR follows."
  (call-with-values
      (lambda () (crossing-step (list z (- z)) us (list y-a (- y-b)) alpha))
    (lambda (zs u) (values (car zs) u (- u)))))

(define (link-centres z us ur)
  "→ (values giving-centre taking-centre): what each side solves against."
  (values (- z us) (- z ur)))

;; ── an exchange: the state of every good in one solve ────────────────────────
;; The loops that run the step over all goods at once (solve-decomposed's
;; rounds, solve-consensus over oracles) keep the same state, so they keep it in
;; one place: for each good the SIGNED agreed flow of each participant and the
;; good's scaled dual u, and the penalty weight ρ they all share (the pull on a
;; good is ρ·u). A good is LIVE when two scopes share it; one that a single
;; scope holds has nothing to agree on and no state.
(define-record-type <exchange>
  (make-exchange* keys sizes zs us rho)
  exchange?
  (keys exchange-keys)                        ; the live goods, in order
  (sizes exchange-sizes)                      ; good → how many participate
  (zs exchange-zs)                            ; good → list of signed flows, participant order
  (us exchange-us)                            ; good → the scaled dual
  (rho exchange-rho set-exchange-rho!))       ; the penalty weight

(define* (make-exchange parts z0 #:key (rho 4.0))
  "PARTS: ((good . n) …), each good and how many participate in it, its
   participants in a fixed order. Z0: ((good y …) …), the signed flows to
   start a good from, one per participant and summing to nothing; a good with
   no start begins at no flow. RHO the penalty weight."
  (let* ((live (filter (lambda (g) (>= (cdr g) 2)) parts))
         (zs (make-hash-table)) (us (make-hash-table)) (sizes (make-hash-table)))
    (for-each
     (lambda (g)
       (let ((start (let ((w (assoc (car g) z0))) (and w (pair? (cdr w)) (= (length (cdr w)) (cdr g)) (cdr w)))))
         (hash-set! sizes (car g) (cdr g))
         (hash-set! zs (car g) (if start (map exact->inexact start) (make-list (cdr g) 0.0)))
         (hash-set! us (car g) 0.0)))
     live)
    (make-exchange* (map car live) sizes zs us rho)))

(define (exchange-live? ex key) (and (member key (exchange-keys ex)) #t))

(define (exchange-centre ex key pos)
  "What participant POS of KEY solves against: z − u, its signed agreed flow
   less the good's scaled dual; 0 for a good that is not live."
  (if (exchange-live? ex key)
      (- (list-ref (hash-ref (exchange-zs ex) key) pos) (hash-ref (exchange-us ex) key))
      0.0))

(define (exchange-flow ex key pos)
  "The signed flow agreed for participant POS: z; 0 for a good that is not live."
  (if (exchange-live? ex key) (list-ref (hash-ref (exchange-zs ex) key) pos) 0.0))

(define (exchange-pull ex key)
  "λ = ρ·u, the pull on KEY, the same for every participant."
  (if (exchange-live? ex key) (* (exchange-rho ex) (hash-ref (exchange-us ex) key)) 0.0))

(define (exchange-u ex key) (if (exchange-live? ex key) (hash-ref (exchange-us ex) key) 0.0))

(define* (exchange-step! ex key ys alpha #:key (damping 1.0))
  "One step on KEY from the participants' SIGNED flows YS, DAMPING the fraction
   of it taken (η of the asynchronous-iteration theorems; 1 = all of it).
   → (values imbalance prim dual): Σ y, what the crossing is out of balance; and
   the consensus form's residuals (Boyd et al. 2011, §3.3) — the primal
   ‖y − z'‖, how far the flows are from the agreed ones, and the dual ρ‖z' − z‖,
   how far the agreed ones moved."
  (let ((zs (hash-ref (exchange-zs ex) key)) (u (hash-ref (exchange-us ex) key)))
    (define (damped old new) (if (= damping 1.0) new (+ old (* damping (- new old)))))
    (define (dist as bs) (sqrt (fold + 0.0 (map (lambda (a b) (* (- a b) (- a b))) as bs))))
    (call-with-values (lambda () (crossing-step zs u ys alpha))
      (lambda (zs-step u-step)
        (let ((zs* (map damped zs zs-step)) (u* (damped u u-step)))
          (hash-set! (exchange-zs ex) key zs*) (hash-set! (exchange-us ex) key u*)
          (values (fold + 0.0 ys) (dist ys zs*) (* (exchange-rho ex) (dist zs* zs))))))))

;; Anderson's iterate: for each good the FREE coordinates of its agreed flows —
;; all but the last, which Σ z = 0 fixes — and the good's dual u once for every
;; participant. With two participants that is [z u u]: the weight the rounds
;; have always given the dual beside the flow, so their counts and the
;; certificates measured on their iterates stand. (Anderson's least squares is
;; invariant under a sign of a coordinate: every product it forms is of two
;; entries of one coordinate.)
(define (exchange->vector ex)
  (list->vector
   (append-map
    (lambda (k)
      (let ((zs (hash-ref (exchange-zs ex) k)) (u (hash-ref (exchange-us ex) k)))
        (append (drop-right zs 1) (make-list (hash-ref (exchange-sizes ex) k) u))))
    (exchange-keys ex))))

(define (exchange-load! ex v)
  "The inverse of exchange->vector: the last agreed flow of each good is what
   makes them sum to nothing, and its dual is read off its first copy."
  (let lp ((ks (exchange-keys ex)) (i 0))
    (unless (null? ks)
      (let* ((k (car ks)) (n (hash-ref (exchange-sizes ex) k))
             (free (map (lambda (j) (vector-ref v (+ i j))) (iota (- n 1)))))
        (hash-set! (exchange-zs ex) k (append free (list (- (fold + 0.0 free)))))
        (hash-set! (exchange-us ex) k (vector-ref v (+ i (- n 1))))
        (lp (cdr ks) (+ i (- n 1) n))))))

(define (exchange-flow-scale ex)
  "The size of the agreed flows over every good: what a leap of the iterate is
   measured against."
  (sqrt (fold (lambda (k s) (fold (lambda (z s) (+ s (* z z))) s (hash-ref (exchange-zs ex) k))) 0.0 (exchange-keys ex))))

(define (exchange-vector-within? ex v bound)
  "Whether every dual in the iterate V (exchange->vector's layout) is within
   BOUND: a scaled dual is a flow's worth of pull, in the flows' units, and
   one beyond any multiple of the flows is not a pull the economy produces."
  (let lp ((ks (exchange-keys ex)) (i 0))
    (or (null? ks)
        (let* ((n (hash-ref (exchange-sizes ex) (car ks))) (u (vector-ref v (+ i (- n 1)))))
          (and (<= (abs u) bound) (lp (cdr ks) (+ i (- n 1) n)))))))

(define (exchange-rescale! ex factor)
  "ρ multiplied by FACTOR, and every scaled dual divided by it, so λ = ρ·u stands."
  (set-exchange-rho! ex (* (exchange-rho ex) factor))
  (for-each (lambda (k) (hash-set! (exchange-us ex) k (/ (hash-ref (exchange-us ex) k) factor)))
            (exchange-keys ex)))

(define* (exchange-balance! ex prim dual #:key (ratio 10.0))
  "rho-balance on the residuals PRIM and DUAL, and the rescale it answers.
   → the factor, or #f."
  (let ((factor (rho-balance prim dual #:ratio ratio)))
    (and factor (begin (exchange-rescale! ex factor) factor))))

;; ── Anderson acceleration ────────────────────────────────────────────────────
;; The ADMM step, run over a link's state [z us ur] (or over every link's,
;; end to end), is a fixed-point map G. Anderson's extrapolation over the last
;; few residuals leaps the slow modes plain ADMM crawls through — measured, the
;; two-commune economy takes 414 plain rounds and 33 accelerated; a four-scope
;; chain 998 and 35. The arithmetic is shared by the monolith's rounds
;; (solve-decomposed), the coordinator over oracles (solve-consensus) and each
;; link's master in the coordinator-free solve (federation/async).

(define (vdot a b)
  (let ((s 0.0) (n (vector-length a)))
    (do ((i 0 (+ i 1))) ((= i n) s) (set! s (+ s (* (vector-ref a i) (vector-ref b i)))))))


(define (admm-vsub a b) (let ((r (make-vector (vector-length a)))) (do ((i 0 (+ i 1))) ((= i (vector-length a)) r) (vector-set! r i (- (vector-ref a i) (vector-ref b i))))))
(define (admm-vnorm a) (sqrt (vdot a a)))
(define (admm-gsolve M rhs m)                      ; m×m Gaussian elim w/ partial pivot; M=list of row-lists
  (let ((A (list->vector (map (lambda (r b) (let ((row (make-vector (+ m 1)))) (do ((j 0 (+ j 1))) ((= j m)) (vector-set! row j (list-ref r j))) (vector-set! row m b) row)) M rhs))))
    (do ((c 0 (+ c 1))) ((= c m))
      (let ((piv c)) (do ((r (+ c 1) (+ r 1))) ((= r m)) (when (> (abs (vector-ref (vector-ref A r) c)) (abs (vector-ref (vector-ref A piv) c))) (set! piv r)))
        (let ((tmp (vector-ref A c))) (vector-set! A c (vector-ref A piv)) (vector-set! A piv tmp))
        (let ((d (vector-ref (vector-ref A c) c)))
          (when (> (abs d) 1e-300)
            (do ((r (+ c 1) (+ r 1))) ((= r m))
              (let ((f (/ (vector-ref (vector-ref A r) c) d)))
                (do ((j c (+ j 1))) ((> j m)) (vector-set! (vector-ref A r) j (- (vector-ref (vector-ref A r) j) (* f (vector-ref (vector-ref A c) j)))))))))))
    (let ((x (make-vector m 0.0)))
      (do ((c (- m 1) (- c 1))) ((< c 0) x)
        (let ((s (vector-ref (vector-ref A c) m)))
          (do ((j (+ c 1) (+ j 1))) ((= j m)) (set! s (- s (* (vector-ref (vector-ref A c) j) (vector-ref x j)))))
          (let ((d (vector-ref (vector-ref A c) c))) (vector-set! x c (if (> (abs d) 1e-300) (/ s d) 0.0))))))))
;; one Anderson step over the history: given the fixed-point iterate g = G(v0)
;; and residual f = g − v0, append to the (chronological) histories, and return
;; (values v-next histg histf) — v-next is the extrapolated state to write back
;; (g itself when the history is too short to extrapolate)
(define* (admm-anderson-step g f histg histf mmax #:key (trust 10.0) (scale #f))
  (let* ((histg (append histg (list g))) (histf (append histf (list f)))
         (histg (if (> (length histg) (+ mmax 1)) (cdr histg) histg))
         (histf (if (> (length histf) (+ mmax 1)) (cdr histf) histf))
         (m (- (length histg) 1)))
    (if (< m 1)
        (values g histg histf)
        (let* ((gv (list->vector histg)) (fv (list->vector histf))
               (dF (map (lambda (j) (admm-vsub (vector-ref fv (+ j 1)) (vector-ref fv j))) (iota m)))
               (dG (map (lambda (j) (admm-vsub (vector-ref gv (+ j 1)) (vector-ref gv j))) (iota m)))
               (tr  (/ (fold (lambda (a s) (+ s (vdot a a))) 0.0 dF) (max 1 m)))
               (M  (map (lambda (a) (map (lambda (b) (+ (vdot a b) (if (eq? a b) (* 1e-8 (+ tr 1e-30)) 0.0))) dF)) dF))
               (rhs (map (lambda (a) (vdot a f)) dF))
               (gam (vector->list (admm-gsolve M rhs m)))
               (vn  (vector-copy g)) (L3 (vector-length g)))
          (for-each (lambda (dg gj) (do ((i 0 (+ i 1))) ((= i L3)) (vector-set! vn i (- (vector-ref vn i) (* gj (vector-ref dg i)))))) dG gam)
          ;; a trust region: the leap may be TRUST times the SCALE of the state
          ;; it leaves and no more — the size of its flows when the caller says
          ;; (a scaled dual is a flow's worth of pull, in the flows' units),
          ;; else of the whole state. Where the history is nearly degenerate the
          ;; least-squares mixes with huge coefficients and lands the state a
          ;; million times beyond anything it has been (a pull of 1e10 on a
          ;; link that carries what it should); such a step is refused, and the
          ;; history begun again. Measured against the flows, a pull cannot
          ;; inflate the scale it is measured against and run away by leaps each
          ;; within bounds of the last.
          (if (> (admm-vnorm (admm-vsub vn g))
                 (* trust (+ (or scale (admm-vnorm g)) (admm-vnorm (admm-vsub g f)) 1e-9)))
              (values g '() '())
              (values vn histg histf))))))

;; ── the exchange's accelerator ───────────────────────────────────────────────
;; What every loop keeps beside the exchange: the history Anderson extrapolates
;; from, and the last residual norm a growing residual is measured against.
;; `begin!` before the goods are stepped, `end!` after: the exchange then holds
;; the extrapolation — or the step itself, when the residual has grown by
;; RESTART (the history begins again), when the leap is beyond TRUST times the
;; flows or lands a scaled dual beyond BOX times them (refused, the history
;; begun again), when the BUDGET of leaps is spent, or always when OFF.
;;
;; The BUDGET is what makes every run EVENTUALLY PLAIN: an accelerator takes
;; at most that many leaps in its life — a restart of the history does not
;; give them back, and a master that restarts resumes at the count it kept —
;; so from some step on the exchange holds the step itself, every time. With
;; ρ rescaled at most a fixed number of times, the tail of any run is the
;; plain iteration of one averaged operator, whose residual tends to nothing
;; (docs/formal/solver-certificate, AveragedIteration:
;; `eventually_plain_residual_tendsto_zero`). The budget is far beyond what a
;; run takes (tens of leaps), so it changes no run that settles.
(define *leap-budget* 1000)

(define* (make-exchange-accelerator ex #:key (mmax 8) (restart 1.25) (trust 10.0) (box 10.0) (on #t)
                                    (budget *leap-budget*))
  "→ a procedure: (acc 'begin!); (acc 'end!) → the residual norm; (acc 'reset!);
   (acc 'leaps) → the leaps taken so far; (acc 'leaps! n) → that count set, as
   a restart resumes it."
  (let ((histg '()) (histf '()) (prevf +inf.0) (v0 #f) (leaps 0))
    (define (forget!) (set! histg '()) (set! histf '()))
    (lambda (msg . args)
      (case msg
        ((begin!) (set! v0 (exchange->vector ex)))
        ((reset!) (forget!) (set! prevf +inf.0))
        ((leaps) leaps)
        ((leaps!) (set! leaps (car args)) leaps)
        ((end!)
         (let* ((g (exchange->vector ex)) (f (admm-vsub g v0))
                (fnorm (admm-vnorm f)) (grew? (> fnorm (* restart prevf)))
                (scale (exchange-flow-scale ex)))
           (set! prevf fnorm)
           (cond ((not on) fnorm)
                 ((>= leaps budget) fnorm)             ; spent: the step itself, from here on
                 (grew? (forget!) fnorm)
                 (else
                  (call-with-values (lambda () (admm-anderson-step g f histg histf mmax #:trust trust #:scale scale))
                    (lambda (vn hg hf)
                      (if (exchange-vector-within? ex vn (* box scale))
                          (begin (set! histg hg) (set! histf hf)
                                 (unless (eq? vn g) (set! leaps (+ 1 leaps)))   ; the step itself is no leap
                                 (exchange-load! ex vn))
                          (forget!))
                      fnorm))))))
        (else (error "exchange-accelerator: unknown message" msg))))))

;; ── balancing ρ ──────────────────────────────────────────────────────────────
;; The residual-balancing rule (Boyd et al. 2011, §3.4.1): ρ doubles when the
;; primal residual is RATIO times the dual, halves when the dual is RATIO times
;; the primal. → the factor, or #f. The caller rescales the duals with it
;; (exchange-rescale!), so λ = ρ·u stands.
(define* (rho-balance prim dual #:key (ratio 10.0))
  (cond ((> prim (* ratio dual)) 2.0)
        ((> dual (* ratio prim)) 0.5)
        (else #f)))

;; ── what is supplied, shared out ─────────────────────────────────────────────
;; Once every participant of a good has made its exact local solve, what is
;; supplied is what there is: a participant that supplies keeps its flow, and
;; those that draw keep theirs, cut back pro rata when together they draw more
;; than is supplied. One that draws alone is then held to exactly what the
;; others supply. Which participant supplies is read off its flow. The
;; monolith's clamp, the coordinator's caps and each peer master's allocation
;; are this one rule.
(define (allocate-caps ys)
  "YS the signed flows, one per participant → the signed flow each is held to."
  (let* ((supply (fold + 0.0 (map (lambda (y) (if (> y 0.0) y 0.0)) ys)))
         (draw (fold + 0.0 (map (lambda (y) (if (< y 0.0) (- y) 0.0)) ys)))
         (scale (if (> draw (+ supply 1e-12)) (/ supply draw) 1.0)))
    (map (lambda (y) (if (< y 0.0) (* scale y) y)) ys)))

;; ── the rounds ───────────────────────────────────────────────────────────────
;; The ADMM as rounds a coordinator conducts, over the goods of one exchange:
;; hand every scope the centres it solves against, take its flows, step every
;; good, extrapolate, stop when the goods balance AND the demand met has
;; stopped climbing. The monolith's rounds (solve-decomposed, every scope in
;; one process) and the coordinator over oracles (solve-consensus, every
;; scope a message away) are this one loop with different ROUND!s, so their
;; counts are the same by construction.
;;
;; The stop is a SLOPE, not a level. A small imbalance says the scopes agree
;; on what crosses, not that the allocation is good, and the two come apart
;; on a long-diameter cover: a 16-scope chain reaches consensus at round 58
;; and 97.1% met, and stays there however high the cap. Requiring met > 99
;; grinds every round under scarcity, where the optimum is below 100. So the
;; loop keeps going while met still climbs, and stops once it has flattened
;; for MET-STALL consecutive balanced rounds (tests/solve/test-decomposed-optimality.scm).
;;
;; A scope that misses a round (ROUND! answers #f for it) contributes its last
;; reply, the ADMM under bounded staleness: a good any of whose scopes sat
;; the round out holds still, since its pull would otherwise integrate a
;; residual read off a reply that is no longer current; the round restarts
;; the acceleration and cannot end the solve; a scope silent for more than
;; MAX-STALE rounds in a row raises (Zhang & Kwok 2014 for the guarantee's
;; reach).
(define* (exchange-rounds ex tables round! #:key (alpha 1.6) (accel #t) (mmax 8) (iters 120)
                          (tol 1e-4) (met-eps 0.05) (met-stall 3) (max-stale 5))
  "TABLES: per scope, the goods it shares (good …). ROUND!: (round! centres)
   with CENTRES per scope ((good . c) …) → per scope ((flows . ((good . y) …))
   (met . %)), each flow signed, or #f in the place of a scope that missed the
   round. → (values replies met rounds stale-rounds residuals): the last
   round's replies with each absent one made up, the mean met, the rounds
   run, how many had a scope missing, and good → the last round's imbalance."
  (define S (length tables))
  (define parts (make-hash-table))                ; good → the scopes that share it, scope order
  (let lp ((ts tables) (s 0))
    (unless (null? ts)
      (for-each (lambda (k)
                  (let ((ps (hash-ref parts k '())))
                    (when (memv s ps) (error "exchange-rounds: a scope holds one good twice" k))
                    (hash-set! parts k (append ps (list s)))))
                (car ts))
      (lp (cdr ts) (+ s 1))))
  (define (pos-of s k) (list-index (lambda (p) (= p s)) (hash-ref parts k)))
  (define (centres-of s)
    (map (lambda (k) (cons k (exchange-centre ex k (pos-of s k)))) (list-ref tables s)))
  (define (flow-of reply k) (let ((a (assoc k (cdr (assq 'flows reply))))) (if a (exact->inexact (cdr a)) 0.0)))
  (define (signed-flows replies k)
    (map (lambda (p) (flow-of (list-ref replies p) k)) (hash-ref parts k)))
  (define last-reply (make-vector S #f))
  (define silent (make-vector S 0))
  (define (settle raw)                            ; each absent reply made up from the scope's last, or its centres
    (map (lambda (r s)
           (cond (r (vector-set! last-reply s r) (vector-set! silent s 0) r)
                 (else
                  (let ((m (+ 1 (vector-ref silent s))))
                    (when (> m max-stale) (error "exchange-rounds: a scope stayed silent" s max-stale))
                    (vector-set! silent s m)
                    (or (vector-ref last-reply s)
                        `((flows . ,(map (lambda (k) (cons k (exchange-flow ex k (pos-of s k))))
                                         (list-ref tables s)))
                          (met . 0.0)))))))
         raw (iota S)))
  (define acc (make-exchange-accelerator ex #:mmax mmax #:on accel))
  (define residuals (make-hash-table))
  (let loop ((it 0) (bestmet -1.0) (stall 0) (stale-rounds 0))
    (acc 'begin!)
    (let* ((raw (round! (map centres-of (iota S))))
           (fresh (list->vector (map (lambda (r) (and r #t)) raw)))
           (stale? (not (every values raw)))
           (replies (settle raw))
           (maxres 0.0) (p2 0.0) (d2 0.0))
      (for-each
       (lambda (k)
         (when (every (lambda (p) (vector-ref fresh p)) (hash-ref parts k))
           (call-with-values (lambda () (exchange-step! ex k (signed-flows replies k) alpha))
             (lambda (imbalance prim dual)
               ;; the rounds' own residual pair: the imbalance, and the agreed flows'
               ;; mean-square movement — one coordinate's, for a link
               (set! p2 (+ p2 (* imbalance imbalance)))
               (set! d2 (+ d2 (/ (* dual dual) (* (exchange-rho ex) (exchange-rho ex) (length (hash-ref parts k))))))
               (hash-set! residuals k imbalance)
               (set! maxres (max maxres (abs imbalance)))))))
       (exchange-keys ex))
      (unless accel                               ; baseline: adaptive ρ (frozen under AA, to keep G stationary)
        (exchange-balance! ex (sqrt p2) (* (exchange-rho ex) (sqrt d2))))
      (when stale? (acc 'reset!))
      (acc 'end!)
      (let* ((met (/ (fold (lambda (r a) (+ a (cdr (assq 'met r)))) 0.0 replies) (max 1 S)))
             (improved? (> met (+ bestmet met-eps)))
             (best* (max met bestmet))
             (stall* (if improved? 0 (+ stall 1)))
             (stale-rounds* (if stale? (+ stale-rounds 1) stale-rounds)))
        (if (or (>= it (- iters 1))
                (and (not stale?) (< maxres tol) (>= stall* met-stall)))
            (values replies met (+ it 1) stale-rounds* residuals)
            (loop (+ it 1) best* stall* stale-rounds*))))))
