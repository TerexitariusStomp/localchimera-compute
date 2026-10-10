;;; solve/voice-field.scm — producer voice over the plan, as a fold: the spec's law
;;; for how the people who do the work re-weigh HOW it is done.
;;;
;;; docs/planning/voice/voice-follows-work.md ("The bound", "Centred on the
;;; good"), voice-over-the-plan.md ("The field"), voice-in-lean.md ("The
;;; objects" — the names here are those, so VoiceField.lean cites these lines):
;;;
;;;   h p π      = a person's validated hours in a part's cell
;;;   share p π  = h p π / Σ_q h q π                          (Emphasis.share)
;;;   push π     = Σ_p a p π · share p π                       |push| ≤ 1
;;;   raw j      = Σ_{π covers j} push π
;;;   stance j   = clamp(raw j − Σ_g into(j,g)·λ_g, −1, 1)     centred on the good
;;;   warp w j   = w j · (1 − τ · stance j)                     0 ≤ τ < 1
;;;
;;; a p π are a person's SIGNED portions, held hour by hour: over the parts
;;; covering any one of their hours, |portions| sum to at most one — so each
;;; hour speaks at most once, a rotator speaks on six parts with a full hand on
;;; each, and the voice a person spends, in hours, is at most the hours they
;;; worked. λ solves one small system, goods by goods, so that at the worked
;;; mix every good's felt hours equal its clock hours: a push shared by every
;;; way of a good cancels (that is a statement about WHAT, and its home is the
;;; consumer hand); what is left says HOW.
;;;
;;; ONE READER carries the hours everywhere: HOURS-OF : part [owner] → validated
;;; hours in the part's cell, everyone's when no owner is named. The scope fold
;;; (pools/voice-fold.scm) builds it once from the observer's one hours
;;; fold; the hand, the pushes, the reference and the engine all read it.
;;;
;;; The field is read BEFORE the solve and is plain data: one extra labform
;;; entry per work column, −τ·stance_j·ℓ_j hours (κ is applied by the solver,
;;; as to every labform entry), so the objective's one linear term becomes
;;; κ·ℓ_j·(1 − τ·s_j). No tension kind, no wall, no person reaches the engine:
;;; the fold hands it ((part . push) …) and the reader, nothing else, and the
;;; engine keeps no arithmetic of its own — `voice-labform` and `voice-report`
;;; are its two calls.
;;;
;;; This module is the arithmetic and nothing else: no store, no engine, no
;;; actor. The sibling of solve/emphasis.scm — that one is the consumer's law
;;; (one voice per owner, an unsigned simplex); this is the producer's (a
;;; voice per part, a signed hand held hour by hour). Two laws, two modules.

(define-module (playnet solve voice-field)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet vf facts parts)
  #:export (hand-portions stance-masses pushes-of
            raw-on-columns worked-of-columns into-matrix lambda-of centred-stances
            clamp warp field-delta merge-by-index
            voice-labform voice-marginal voice-report))

(define (clamp x) (max -1.0 (min 1.0 x)))
(define (warp w s tau) (* w (- 1.0 (* tau s))))

;; keys in order of first appearance — the rule every fold here shares
;; (vf/aggregation/fold-node.scm sum-by-key), so a solve reads stable keys
(define (group-by key rows)
  (let ((h (make-hash-table)) (order '()))
    (for-each (lambda (r)
                (let ((k (key r)))
                  (unless (hash-ref h k #f) (set! order (cons k order)))
                  (hash-set! h k (cons r (hash-ref h k '())))))
              rows)
    (map (lambda (k) (cons k (reverse (hash-ref h k)))) (reverse order))))

;; ── the hand, held hour by hour ─────────────────────────────────────────────
(define (hand-portions rows cells-of)
  "ROWS ((owner part raw) …), RAW the owner's signed statement on PART in
   [−1, 1]. CELLS-OF : owner → the terms of each cell of their validated hours.
   Returns the rows with each owner's raws rescaled by max(1, D), D = the
   largest, over their cells, of Σ |raw| over the parts covering that cell —
   so over the parts any one hour falls in, |portions| sum to at most one, and
   an owner whose statements already respect the bound is left exactly as
   written (voice-in-lean theorem 6 `hand_signed_rescale`; 6′
   `rotation_costs_nothing`: hours that share no part are scaled apart)."
  (append-map
   (lambda (own)
     (let* ((rows (cdr own))
            (D (fold (lambda (cell d)
                       (max d (fold (lambda (r a) (if (covers? (cadr r) cell) (+ a (abs (caddr r))) a)) 0.0 rows)))
                     0.0 (cells-of (car own))))
            (k (max 1.0 D)))
       (map (lambda (r) (list (car r) (cadr r) (/ (caddr r) k))) rows)))
   (group-by car rows)))

;; ── shares, masses, pushes ──────────────────────────────────────────────────
(define (stance-masses rows hours-of)
  "ROWS ((owner part portion) …) → ((owner part mass) …), mass = portion ·
   h(owner, part). The sibling of emphasis-masses: the voice differs part by part."
  (filter-map (lambda (r)
                (let ((h (hours-of (cadr r) (car r))))
                  (and (number? h) (> h 0.0) (number? (caddr r))
                       (list (car r) (cadr r) (* (caddr r) h)))))
              rows))

(define (pushes-of masses hours-of)
  "((part . push) …), push = Σ masses on the part / the part's hours over
   everyone, clamped. |push| ≤ 1 whenever every |portion| ≤ 1 (theorem 2
   `abs_push_le_one`); a part with no hours pushes nothing (theorem 8
   `no_carried_hours`)."
  (filter-map (lambda (grp)
                (let* ((π (cadr (cadr grp))) (t (hours-of π)))
                  (and (number? t) (> t 0.0)
                       (cons π (clamp (/ (fold (lambda (m a) (+ a (caddr m))) 0.0 (cdr grp)) t))))))
              (group-by (lambda (m) (part->string (cadr m))) masses)))

;; ── the field over columns ──────────────────────────────────────────────────
(define (raw-on-columns pushes terms-vec)
  "vector, raw_j = Σ over the parts covering column j of their push — a SUM,
   not a mean: a faint stance on a broad part adds its faint amount and does
   not halve a strong one on a narrow part (5′ `mean_dilutes`, refused)."
  (let* ((n (vector-length terms-vec)) (v (make-vector n 0.0)))
    (for-each (lambda (pp)
                (let ((ix (compile-part (car pp) terms-vec)))
                  (unless (eq? ix 'nothing)
                    (for-each (lambda (j) (vector-set! v j (+ (vector-ref v j) (cdr pp)))) ix))))
              pushes)
    v))

(define (worked-of-columns terms-vec hours-of)
  "vector, the validated hours worked on each column's own cell — the cell's
   origin rung, read through HOURS-OF."
  (list->vector (map (lambda (t) (let ((h (hours-of (terms->part t)))) (if (number? h) h 0.0)))
                     (vector->list terms-vec))))

(define (primary-output terms)
  (let ((d (assq-ref terms 'delivers)))
    (and (pair? d) (car (fold (lambda (kv best) (if (> (cdr kv) (cdr best)) kv best)) (car d) (cdr d))))))

(define (into-matrix terms-vec worked wanted)
  "vector, into_j = ((good . fraction) …): where column j's hours go, followed
   downstream through what consumes its primary output, at the worked mix.
   The rollup convention: a joint process's whole labour goes to its primary
   output (algorithms/rollup.scm). A column whose output reaches no wanted
   good — nothing consumes it here, or its chain leaves the plan — is read
   against its own output alone, so it is centred on itself and moves nothing
   (open item 14: a good none of whose hours are worked has no row)."
  (let* ((n (vector-length terms-vec))
         (wanted? (lambda (g) (and (member g wanted) #t)))
         (consumers (make-hash-table))        ; spec → ((j . weight) …)
         (memo (make-vector n #f)))
    (do ((j 0 (+ j 1))) ((= j n))
      (for-each (lambda (kv)
                  (let ((w (* (vector-ref worked j) (cdr kv))))
                    (when (> w 0.0)
                      (hash-set! consumers (car kv) (cons (cons j w) (hash-ref consumers (car kv) '()))))))
                (or (assq-ref (vector-ref terms-vec j) 'consumes) '())))
    (define (add-into! acc g f)
      (let ((cell (assoc g acc)))
        (if cell (begin (set-cdr! cell (+ (cdr cell) f)) acc) (cons (cons g f) acc))))
    (define (into j visiting)
      (or (vector-ref memo j)
          (let* ((p (primary-output (vector-ref terms-vec j)))
                 (r (cond ((not p) '())
                          ((wanted? p) (list (cons p 1.0)))
                          ((memq j visiting) '())
                          (else
                           (let* ((cs (hash-ref consumers p '()))
                                  (W (fold + 0.0 (map cdr cs))))
                             (if (<= W 0.0)
                                 (list (cons p 1.0))
                                 (let ((acc '()))
                                   (for-each (lambda (kw)
                                               (for-each (lambda (gf) (set! acc (add-into! acc (car gf) (* (/ (cdr kw) W) (cdr gf)))))
                                                         (into (car kw) (cons j visiting))))
                                             cs)
                                   (let ((tot (fold + 0.0 (map cdr acc))))
                                     (if (> tot 0.0) acc (list (cons p 1.0)))))))))))
            (vector-set! memo j r)
            r)))
    (do ((j 0 (+ j 1))) ((= j n)) (into j '()))
    memo))

(define (solve-normal M b)
  "Gaussian elimination with partial pivoting on a small dense system; a
   pivot below tolerance leaves its unknown at zero (the least-norm choice
   among the solutions — λ need not be unique, the projection is)."
  (let* ((n (vector-length b)) (A (list->vector (map vector-copy (vector->list M)))) (x (make-vector n 0.0))
         (rhs (vector-copy b)) (piv-col (make-vector n #f)) (row 0))
    (do ((c 0 (+ c 1))) ((or (= c n) (= row n)))
      (let ((best row))
        (do ((r (+ row 1) (+ r 1))) ((= r n))
          (when (> (abs (vector-ref (vector-ref A r) c)) (abs (vector-ref (vector-ref A best) c))) (set! best r)))
        (when (> (abs (vector-ref (vector-ref A best) c)) 1e-12)
          (let ((tmp (vector-ref A row)) (tb (vector-ref rhs row)))
            (vector-set! A row (vector-ref A best)) (vector-set! A best tmp)
            (vector-set! rhs row (vector-ref rhs best)) (vector-set! rhs best tb))
          (let ((p (vector-ref (vector-ref A row) c)))
            (do ((r 0 (+ r 1))) ((= r n))
              (unless (= r row)
                (let ((f (/ (vector-ref (vector-ref A r) c) p)))
                  (unless (= f 0.0)
                    (do ((k c (+ k 1))) ((= k n))
                      (vector-set! (vector-ref A r) k (- (vector-ref (vector-ref A r) k) (* f (vector-ref (vector-ref A row) k)))))
                    (vector-set! rhs r (- (vector-ref rhs r) (* f (vector-ref rhs row)))))))))
          (vector-set! piv-col row c)
          (set! row (+ row 1)))))
    (do ((r 0 (+ r 1))) ((= r row))
      (let ((c (vector-ref piv-col r)))
        (vector-set! x c (/ (vector-ref rhs r) (vector-ref (vector-ref A r) c)))))
    x))

(define (lambda-of raw worked into)
  "((good . λ) …): the numbers that leave each good's felt hours, at the worked
   mix, equal to its clock hours — Σ_j worked_j·into(j,g)·(raw_j − Σ_g' into(j,g')·λ_g') = 0
   for every good g. One small symmetric system, goods by goods."
  (let* ((goods (delete-duplicates (append-map (lambda (a) (map car a)) (vector->list into))))
         (m (length goods)) (gi (make-hash-table)))
    (let loop ((gs goods) (i 0)) (unless (null? gs) (hash-set! gi (car gs) i) (loop (cdr gs) (+ i 1))))
    (if (= m 0) '()
        (let ((M (list->vector (map (lambda (_) (make-vector m 0.0)) goods))) (b (make-vector m 0.0)))
          (do ((j 0 (+ j 1))) ((= j (vector-length into)))
            (let ((w (vector-ref worked j)) (a (vector-ref into j)))
              (when (> w 0.0)
                (for-each (lambda (gf)
                            (let ((g (hash-ref gi (car gf))))
                              (vector-set! b g (+ (vector-ref b g) (* w (cdr gf) (vector-ref raw j))))
                              (for-each (lambda (gf2)
                                          (let ((g2 (hash-ref gi (car gf2))))
                                            (vector-set! (vector-ref M g) g2
                                                         (+ (vector-ref (vector-ref M g) g2) (* w (cdr gf) (cdr gf2))))))
                                        a)))
                          a))))
          (let ((x (solve-normal M b)))
            (map (lambda (g) (cons g (vector-ref x (hash-ref gi g)))) goods))))))

(define (centred-stances raw into lam)
  "vector, stance_j = clamp(raw_j − Σ_g into(j,g)·λ_g, −1, 1)."
  (let* ((n (vector-length raw)) (s (make-vector n 0.0)))
    (do ((j 0 (+ j 1))) ((= j n) s)
      (vector-set! s j (clamp (- (vector-ref raw j)
                                 (fold (lambda (gf a) (+ a (* (cdr gf) (or (assoc-ref lam (car gf)) 0.0))))
                                       0.0 (vector-ref into j))))))))

(define* (field-delta terms-vec ell pushes hours-of wanted #:key (tau 0.0) (stances-out #f))
  "The labform entries the field adds: ((j . −τ·stance_j·ℓ_j) …) over the
   columns with a stance and labour content, ELL a vector of hours per unit
   of each column. Empty when τ = 0 or nothing pushes — the identity, so every
   suite reads today's numbers. STANCES-OUT, when a box (a one-element list),
   receives the stance vector for the report."
  (if (or (<= tau 0.0) (null? pushes))
      '()
      (let* ((raw (raw-on-columns pushes terms-vec))
             (worked (worked-of-columns terms-vec hours-of))
             (into (into-matrix terms-vec worked wanted))
             (lam (lambda-of raw worked into))
             (s (centred-stances raw into lam)))
        (when (pair? stances-out) (set-car! stances-out s))
        (let loop ((j (- (vector-length s) 1)) (acc '()))
          (if (< j 0) acc
              (let ((sj (vector-ref s j)) (l (vector-ref ell j)))
                (loop (- j 1)
                      (if (and (not (= sj 0.0)) (> l 0.0))
                          (cons (cons j (- (* tau sj l))) acc)
                          acc))))))))

(define (merge-by-index delta labform)
  "LABFORM with DELTA's entries folded in: one entry per column index, so every
   backend sees one coefficient however many statements met on a column."
  (if (null? delta) labform
      (let ((h (make-hash-table)))
        (for-each (lambda (ic) (hash-set! h (car ic) (+ (hash-ref h (car ic) 0.0) (cdr ic)))) delta)
        (append (filter-map (lambda (ic)
                              (let ((d (hash-ref h (car ic) #f)))
                                (if d (begin (hash-remove! h (car ic)) (cons (car ic) (+ (cdr ic) d))) ic)))
                            labform)
                (hash-map->list cons h)))))

;; ── the engine's two calls ──────────────────────────────────────────────────
(define* (voice-labform labform terms-vec ell pushes hours-of wanted #:key (tau 0.0))
  "LABFORM with the field folded in, and the stance vector the assembly read
   (#f when no field stood): (values labform stances). τ = 0 or no pushes
   returns LABFORM itself — the identical list."
  (let* ((box (list #f))
         (delta (field-delta terms-vec ell pushes hours-of wanted #:tau tau #:stances-out box)))
    (values (merge-by-index delta labform) (car box))))

(define* (voice-marginal parts terms-vec ell x tau #:key (say (lambda (π) #f)))
  "((part . price) …), the marginal price of each part's voice at the standing
   solve: ∂Z/∂s = −τ·Σ_{j ∈ part} ℓ_j·x_j hours — exact by the envelope theorem,
   additive across parts, free of extra solves (voice-in-lean theorem 20). A
   part covering nothing is dropped and said."
  (map (lambda (pi)
         (cons (car pi)
               (- (* tau (fold (lambda (j a) (+ a (* (vector-ref ell j) (vector-ref x j)))) 0.0 (cdr pi))))))
       (compile-parts parts terms-vec #:say say)))

(define (voice-report stances keys terms-vec ell x pushes tau)
  "The field as it stood for a solve, for the plan's report: τ, each column's
   stance by key, and the marginal price of every part that spoke. Empty when
   no field stood."
  (if (and (> tau 0.0) (vector? stances))
      `((voice . ((tau . ,tau)
                  (stances . ,(filter-map (lambda (j) (let ((sj (vector-ref stances j)))
                                                        (and (not (= sj 0.0)) (cons (vector-ref keys j) sj))))
                                          (iota (vector-length keys))))
                  (parts . ,(map (lambda (pp) (cons (part->string (car pp)) (cdr pp)))
                                 (voice-marginal (map car pushes) terms-vec ell x tau))))))
      '()))
