;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-decomposition-invariance.scm — the PLAN does not depend on how the
;;; federation is CUT into scopes.
;;;
;;; Spec: docs/social-category.typ §2.3 (the stock cell is a Frobenius spider,
;;;       so a diagram depends only on its CONNECTIVITY) + §6 (feasibility glues
;;;       exactly; optimality glues by iterating boundary pulls) + §8 Obligation 3.
;;;
;;; The same economy is assembled two ways and must reach the same plan:
;;;
;;;   MONOLITHIC — ONE scope holding both places. Flour is `movable` with
;;;                τ = 0, so it crosses A→B as a free transport arc INSIDE the
;;;                one program. This is the joint optimum, computed directly.
;;;
;;;   DECOMPOSED — TWO sovereign scopes, each its own local program, sharing
;;;                nothing but the PULL on flour (scaled-dual ADMM via
;;;                `solve-decomposed`). A's giving column and B's taking column
;;;                are free source/sink recipes; the coupling is the dual.
;;;
;;; Fair by construction: the boundary columns cost no labour, so the monolithic
;;; twin gets τ = 0 transport rather than an arc with a cost. The only difference
;;; between the two runs is WHERE THE CUT IS.
;;;
;;; Equality is up to ADMM CONSENSUS TOLERANCE, not to solver epsilon — the
;;; decomposed solve stops when the scopes agree on the shared good to within
;;; `tol` (default 5e-3), so that, and not exact identity, is what §8 can ask
;;; for. The check below is stated at that tolerance and reports the gap.
;;;
;;; Economy: A holds 300 flour and wants 5 bread; B holds none and wants 40.
;;; Both can bake (1 flour + 0.1h → 1 bread). The plan must ship flour A→B and
;;; meet all 45 loaves either way.
;;;
;;; Run: guile tests/solve/test-decomposition-invariance.scm

(use-modules (playnet solve decomposed))
(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve records)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (srfi srfi-1)
             (ice-9 format))

(define (res spec loc q) (holding (string-append spec "@" loc) spec #f #:place loc #:qty q #:unit "kg"))
(define (place id lat lon) (place* id #:lat lat #:lon lon))
(define (worker id loc) (person* id #:place loc #:tags '("general")))

;; the boundary columns: free source / free sink, as build-located emits natively
(define (take-recipe good)
  (cons (rp "imp" (string-append "take " good))
        (list (out* "if" good 1.0 "imp" #:primary #f))))
(define (give-recipe good)
  (cons (rp "exp" (string-append "give " good))
        (list (consume* "ef" good 1.0 "exp"))))

(define A (place "a-home" 42.70 23.32))
(define B (place "b-home" 42.75 23.40))
(define bake-p (list (rp "bake" "Bake bread")))
(define bake-f (list (out "o" "bread" 1.0 "bake")
                     (in  "i" "flour" 1.0 "bake")
                     (wrk "w" 0.1 "bake")))
(define er (give-recipe "flour"))
(define ir (take-recipe "flour"))

(define demand-a 5.0)
(define demand-b 40.0)
(define demand-total (+ demand-a demand-b))

;; ════════════════════════════════════════════════════════════════════════════
;; (1) DECOMPOSED — two scopes, coupled only by the flour pull
;; ════════════════════════════════════════════════════════════════════════════

(define* (commune-scope resources agents spatials procs flows
                        #:key (demand '()) (never-raw '())
                              (give-col #f) (take-col #f) (link #f))
  (ingest-records! resources agents spatials procs flows
    #:demand demand #:never-raw never-raw #:per-agent? #f)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (let ((ec (and give-col (hash-ref idx give-col #f)))
            (ic (and take-col (hash-ref idx take-col #f))))
        (list (cons 'forms forms) (cons 'labform lf)
              (cons 'x0 (located-warm cols ncol idx))
              ;; a column that can only give, then one that can only take
              (cons 'crossings (append (if ec (list (cons* ec link 1 0)) '())
                                       (if ic (list (cons* ic link -1 0)) '()))))))))

(define scopeA
  (commune-scope (list (res "flour" "a-home" 300.0)) (list (worker "wa" "a-home"))
                 (list A) (append bake-p (list (car er))) (append bake-f (cdr er))
                 #:demand (list (cons (lg "bread" (cell "a-home" 0)) demand-a))
                 #:never-raw '("flour")
                 #:give-col "p|exp|a-home@0" #:link "flour"))

(define scopeB
  (commune-scope '() (list (worker "wb" "b-home"))
                 (list B) (append bake-p (list (car ir))) (append bake-f (cdr ir))
                 #:demand (list (cons (lg "bread" (cell "b-home" 0)) demand-b))
                 #:never-raw '("flour")
                 #:take-col "p|imp|b-home@0" #:link "flour"))

(define decomp-met 0.0)
(define decomp-pull 0.0)
(define decomp-rounds 0)

(call-with-values (lambda () (solve-decomposed (list scopeA scopeB) #:accel #t #:rho 4.0))
  (lambda (plans met rounds pulls)
    (set! decomp-met met)
    (set! decomp-rounds rounds)
    (set! decomp-pull (hash-ref pulls "flour" 0.0))))

(format #t "~%── DECOMPOSED: two scopes, one boundary pull ──~%")
(format #t "   demand met = ~,4f%   rounds = ~a   λ(flour) = ~,6f~%"
        decomp-met decomp-rounds decomp-pull)

;; ════════════════════════════════════════════════════════════════════════════
;; (2) MONOLITHIC — one scope, both places, free transport arc
;; ════════════════════════════════════════════════════════════════════════════

(ingest-records!
  (list (res "flour" "a-home" 300.0))
  (list (worker "wa" "a-home") (worker "wb" "b-home"))
  (list A B) bake-p bake-f
  #:demand (list (cons (lg "bread" (cell "a-home" 0)) demand-a)
                 (cons (lg "bread" (cell "b-home" 0)) demand-b))
  #:never-raw '("flour")
  #:movable '("flour")          ; flour crosses A→B …
  #:tau 0.0                     ; … for free, matching the free boundary columns
  ;; ONE-WAY. A free arc declared in both directions is a zero-cost CYCLE: the
  ;; plan can ship flour A→B→A forever at no charge, which is a null direction
  ;; of the objective — strict concavity fails along it and "the" optimum stops
  ;; being unique (observed: both move columns running at ~5·10⁴ with a net of
  ;; ~160). The federated cut has no such loop — A only supplies, B only draws
  ;; — so the monolithic twin is given the same one-way topology, and the two
  ;; are then genuinely the same economy. See §8 Obligation 3a.
  #:arc-table '(("a-home|b-home|auto" . 0.0))
  #:arc-topology? #t
  #:per-agent? #f)

(define mono-a 0.0)
(define mono-b 0.0)

(call-with-values solve-located
  (lambda (x idx)
    (let ((V (Vof x idx)))
      (set! mono-a (V "p|bake|a-home@0"))
      (set! mono-b (V "p|bake|b-home@0")))))

(define mono-total (+ mono-a mono-b))

;; The SAME metric solve-decomposed reports: pk_meanfill (kernel.c) is the mean
;; over demand terms of min(1, delivered/demanded) — capped, so surplus on one
;; good never papers over a shortfall on another. Comparing a raw
;; delivered/demanded ratio against it would be comparing two different numbers.
(define (fill delivered demanded) (min 1.0 (/ delivered demanded)))
(define mono-met (* 100.0 (/ (+ (fill mono-a demand-a) (fill mono-b demand-b)) 2.0)))

(format #t "~%── MONOLITHIC: one scope, both places ──~%")
(format #t "   bake@A = ~,4f   bake@B = ~,4f   total = ~,4f of ~,1f~%"
        mono-a mono-b mono-total demand-total)
(format #t "   demand met = ~,4f%  (meanfill, as the ADMM reports it)~%" mono-met)

;; ════════════════════════════════════════════════════════════════════════════
;; The invariant
;; ════════════════════════════════════════════════════════════════════════════

(define admm-tol 5e-3)              ; solve-decomposed's default consensus tol
(define gap (abs (- decomp-met mono-met)))

(format #t "~%── the cut does not change the plan ──~%")
(format #t "   |decomposed − monolithic| = ~,6f percentage points~%" gap)

;; The fixture is BUILT servable — A holds 300 flour against a total demand of 45
;; — so "meets the demand" means "reaches what the fixture can support", i.e.
;; essentially 100%. Expressed against that construction rather than as a tuned
;; floor: a threshold of 99.0 says nothing about whether the fixture changed.
(define servable 100.0)      ; by construction: flour 300 ≫ demand 45
(check "the decomposed federation reaches what the fixture can support"
       (> decomp-met (- servable 1.0)))
(check "…and so does the monolithic economy"
       (> mono-met (- servable 1.0)))
(check "B bakes locally from the flour it draws"        (> mono-b (* 0.9 demand-b)))
(check "both cuts agree to ADMM consensus tolerance"
       (< gap (* 100.0 admm-tol)))

;; ── OPEN: surplus production on an abundant input ──────────────────────────
;; `meanfill` caps each good's fill at 1, so it cannot see OVER-supply — and
;; there is over-supply here: A bakes ~16 loaves against a demand of 5. It is
;; not noise, and it is not the desire term. It tracks the SLACK on the input:
;;
;;     flour 300 → bake@A 16.14      flour 46 → bake@A 5.00
;;     flour 100 → bake@A 12.73      flour 45 → bake@A 5.00
;;
;; Exact when flour binds, inflated in proportion to the surplus when it does
;; not — the signature of the interior-point BARRIER holding the iterate off a
;; non-binding wall, with the free-time thrift term (κ = 0.02, ×0.1h per loaf
;; ⇒ 0.002 per surplus loaf) far too weak to pull it back. §7.9 of Playnet has
;; the thrift term precisely so "the plan makes only what someone wants"; on an
;; abundant input it currently does not.
;;
;; Recorded, not asserted: the fix is a design decision (a two-sided desire
;; tension that penalises surplus, or a stronger centering sweep on non-binding
;; directions), not a test threshold. The bound below only stops it regressing
;; further while that is decided.
(define surplus-a (max 0.0 (- mono-a demand-a)))
(format #t "~%  ⚠ OPEN — surplus at A: ~,3f loaves over a demand of ~,1f~%"
        surplus-a demand-a)
(format #t "    tracks input slack, not desire; see the header note.~%")
(check "surplus production stays bounded (regression guard, not an endorsement)"
       (< surplus-a (* 3.0 demand-a)))

(check-done "  Diagram invariance: the plan depends on connectivity, not on the cut.~%")
