;;; attractor-regret.scm — possibility-tension near a tipping attractor.
;;;
;;; Spec: docs/playnet.typ §"Possibility-tensions and their fragility
;;;       profiles", §"Shared budgets and possibility-tension".
;;;
;;; Minimax regret over a named, finite list of tipping attractors: a
;;; domain-agnostic *possibility-tension*. As a system's state nears a
;;; tipping point its regret rises — the *pull* away from the edge — and
;;; near the limit it out-pulls every desire. The smoothed regret is the
;;; gradient (the pull) that harmony subtracts as a hard tension.
;;;
;;; This module is the *core essence* extracted from (playnet climateSOS).
;;; climateSOS originally bundled three things:
;;;   1. a generic vocabulary of named attractors + pressure tokens + a
;;;      product-of-coefficients regret score (this file);
;;;   2. a specific catalogue of 17 climate/biosphere/transition attractors
;;;      (Appendix C — stays in climateSOS.scm);
;;;   3. an economic/transition-system scheduler over queues, fabrics,
;;;      identity tokens, and worker transitions (also stays in
;;;      climateSOS.scm, where the domain vocabulary fits).
;;;
;;; This file is layer 1. The planner consumes it as a measure: given a
;;; set of <attractor>s and a set of <pressure>s, it returns a single
;;; number summarising the worst-case permanent loss the federation is
;;; currently exposed to. That number, smoothed into a gradient, is the
;;; possibility-pull that harmony subtracts as a hard tension — one field
;;; (see docs/playnet.typ §"Shared budgets and possibility-tension").
;;;
;;; Nothing here mentions climate, biosphere, fossil, energy, or labour.
;;; Those names live in climateSOS.scm and in any future catalogue
;;; modules (e.g. biodiversity-attractors, financial-attractors,
;;; epidemiological-attractors, …) that instantiate this primitive.

(define-module (playnet deprecated planner algorithms attractor-regret)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (;; records
            <attractor> make-attractor attractor?
            attractor-name attractor-watched-targets
            attractor-affected-targets
            attractor-threshold
            attractor-likelihood attractor-consequence
            attractor-coupling attractor-irreversibility
            attractor-confidence attractor-notes

            <pressure> make-pressure pressure?
            pressure-name pressure-target
            pressure-weight pressure-confidence

            ;; primitive measures on one attractor
            accumulated-pressure
            pressure-ratio
            tipped?
            pressure-factor
            regret-score

            ;; minimax-regret measures over a set
            minimax-regret
            soft-minimax-regret
            regret-ranking

            ;; feedback-loop propagation
            cascade-augmented-pressures
            cascade-trace

            ;; pluggable severity combinators
            multiplicative-severity-combinator
            additive-severity-combinator
            geometric-mean-severity-combinator
            max-severity-combinator

            ;; tunable defaults — rebindable via parameterize or
            ;; overridable per-call via keyword args
            *default-severity-combinator*
            *default-pressure-factor-cap*
            *default-soft-minimax-beta*
            *default-cascade-radiation-strength*
            *default-cascade-max-rounds*))


;; ═══════════════════════════════════════════════════════════════════════
;; RECORDS
;; ═══════════════════════════════════════════════════════════════════════

;;; <attractor> — a named basin in state-space the federation can fall
;;; into and from which it cannot return by relaxation alone.
;;;
;;; Fields:
;;;   name             : an identifier (any value comparable by equal?)
;;;   watched-targets  : list of target identifiers; pressures landing on
;;;                      any of these accumulate against this attractor
;;;                      (the *inputs* — what raises this basin's pressure)
;;;   affected-targets : list of target identifiers this attractor stresses
;;;                      *when it tips* — the outputs of the feedback edge.
;;;                      Empty list = no downstream radiation (a sink in
;;;                      the cascade graph). See cascade-augmented-pressures.
;;;   threshold        : accumulated pressure at which the attractor tips
;;;                      (must be > 0)
;;;   likelihood       : prior probability of tipping in the relevant
;;;                      horizon, conditional on saturated pressure (0..1)
;;;   consequence      : severity if it tips, in normalised units (0..1+)
;;;   coupling         : multiplier for downstream impact on affected
;;;                      targets when this one tips (≥ 1.0 typical).
;;;                      Plays a dual role: (a) severity multiplier in
;;;                      regret-score, (b) radiation weight per emitted
;;;                      synthetic pressure during cascade propagation.
;;;   irreversibility  : how permanent the post-tip regime is (0..1)
;;;   confidence       : epistemic weight on the above coefficients (0..1)
;;;   notes            : free-form annotation, opaque to the algorithm
;;;
;;; watched-targets and affected-targets together form a directed bipartite
;;; graph (attractors ↔ targets). Cycles in this graph express feedback
;;; loops: A's affected-target is a watched-target of B, B's affected-target
;;; is a watched-target of A. cascade-augmented-pressures iterates over
;;; this graph to fixed point.

(define-record-type <attractor>
  (%make-attractor name watched-targets affected-targets threshold
                   likelihood consequence coupling
                   irreversibility confidence notes)
  attractor?
  (name             attractor-name)
  (watched-targets  attractor-watched-targets)
  (affected-targets attractor-affected-targets)
  (threshold        attractor-threshold)
  (likelihood       attractor-likelihood)
  (consequence      attractor-consequence)
  (coupling         attractor-coupling)
  (irreversibility  attractor-irreversibility)
  (confidence       attractor-confidence)
  (notes            attractor-notes))

(define* (make-attractor name watched-targets threshold
                         #:key
                         (affected-targets '())
                         (likelihood 1.0)
                         (consequence 1.0)
                         (coupling 1.0)
                         (irreversibility 1.0)
                         (confidence 1.0)
                         (notes ""))
  (when (<= threshold 0)
    (error "make-attractor: threshold must be positive" name threshold))
  (%make-attractor name watched-targets affected-targets threshold
                   likelihood consequence coupling
                   irreversibility confidence notes))

;;; <pressure> — a unit of stress landing on a target. Multiple
;;; pressures can share a target; they sum (after confidence weighting)
;;; into the attractor's accumulated pressure.
;;;
;;;   name       : identifier (any equal?-able value)
;;;   target     : the target identifier this pressure lands on
;;;   weight     : magnitude in pressure units
;;;   confidence : epistemic weight on this particular measurement (0..1)

(define-record-type <pressure>
  (%make-pressure name target weight confidence)
  pressure?
  (name        pressure-name)
  (target      pressure-target)
  (weight      pressure-weight)
  (confidence  pressure-confidence))

(define* (make-pressure name target weight #:optional (confidence 1.0))
  (%make-pressure name target weight confidence))


;; ═══════════════════════════════════════════════════════════════════════
;; PRIMITIVE MEASURES ON ONE ATTRACTOR
;; ═══════════════════════════════════════════════════════════════════════

(define (target-matches? p a)
  (let loop ((targets (attractor-watched-targets a)))
    (cond ((null? targets) #f)
          ((equal? (car targets) (pressure-target p)) #t)
          (else (loop (cdr targets))))))

;;; Σ over pressures landing on any watched target, each scaled by its
;;; own confidence. Returns a non-negative number.
(define (accumulated-pressure a pressures)
  (fold (lambda (p acc)
          (if (target-matches? p a)
              (+ acc (* (pressure-weight p) (pressure-confidence p)))
              acc))
        0
        pressures))

;;; Pressure expressed as a fraction of the attractor's tipping threshold.
;;; 0.0 = no pressure; 1.0 = exactly at threshold; > 1.0 = tipped.
(define (pressure-ratio a pressures)
  (/ (accumulated-pressure a pressures) (attractor-threshold a)))

(define (tipped? a pressures)
  (>= (pressure-ratio a pressures) 1.0))

;;; ─── Modeling commitment 1: pressure-factor cap ──────────────────────
;;;
;;; pressure-factor — saturating contribution of current pressure to
;;; regret. Without a cap, a single hugely-overshot attractor can
;;; arbitrarily dominate the catalogue and prevent the planner from
;;; attending to anything else. With a cap, "how bad is the basin"
;;; (irreversibility, consequence) is allowed to compete with "how close
;;; are we" (pressure-ratio). The numeric default 1.5 is climateSOS
;;; Appendix-C folklore; treat it as a tunable knob, not a constant.
;;;
;;; Pass #f to disable saturation (uncapped).
;;; Pass a positive number to set a custom cap.
(define *default-pressure-factor-cap* 1.5)

(define* (pressure-factor a pressures
                          #:key (cap *default-pressure-factor-cap*))
  (let ((r (pressure-ratio a pressures)))
    (if cap (min cap r) r)))

;;; ─── Modeling commitment 2: severity combinator ──────────────────────
;;;
;;; A severity-combinator is a procedure of six numbers — the five
;;; static severity coefficients plus pressure-factor — returning the
;;; scalar regret score for an attractor:
;;;
;;;   (combinator likelihood consequence coupling
;;;               irreversibility confidence pressure-factor) → number
;;;
;;; This is the swap point if you want a different aggregation than
;;; "everything multiplies." Four pre-built combinators are provided
;;; below; users can supply their own.
;;;
;;; The product form (multiplicative) is what commons.typ §"Reading
;;; Harmony 3 As Minimax Regret" commits to and what Appendix C uses.
;;; The alternatives are exported so the planner can experiment without
;;; editing the module.

(define (multiplicative-severity-combinator
         likelihood consequence coupling irreversibility confidence
         pressure-factor)
  "Product of all six coefficients. The Appendix-C / commons.typ default."
  (* likelihood consequence coupling irreversibility confidence
     pressure-factor))

(define (additive-severity-combinator
         likelihood consequence coupling irreversibility confidence
         pressure-factor)
  "Mean of the six coefficients. Mild — no coefficient can zero out the
score. Useful when you trust each dimension's measurement weakly and
want to avoid one near-zero coefficient dominating."
  (/ (+ likelihood consequence coupling irreversibility confidence
        pressure-factor)
     6))

(define (geometric-mean-severity-combinator
         likelihood consequence coupling irreversibility confidence
         pressure-factor)
  "Sixth root of the product. Compromise between multiplicative and
additive: zeros propagate (any 0 → 0) but the score grows more slowly
than the bare product."
  (expt (* likelihood consequence coupling irreversibility confidence
           pressure-factor)
        (/ 1 6)))

(define (max-severity-combinator
         likelihood consequence coupling irreversibility confidence
         pressure-factor)
  "Maximum of the six coefficients. Worst-coordinate framing — one
extreme dimension defines the regret regardless of how mild the others
are. Useful when any single dimension being severe is sufficient cause
for alarm."
  (max likelihood consequence coupling irreversibility confidence
       pressure-factor))

(define *default-severity-combinator* multiplicative-severity-combinator)

;;; regret-score — apply the chosen severity-combinator to the
;;; attractor's coefficients + current pressure-factor. This is R_k
;;; from commons.typ §"Reading Harmony 3 As Minimax Regret."
;;;
;;; Decision-theoretic reading: expected magnitude of permanent loss if
;;; we keep operating in a regime that holds this attractor's pressure
;;; near its threshold.
(define* (regret-score a pressures
                       #:key
                       (combinator *default-severity-combinator*)
                       (pressure-factor-cap *default-pressure-factor-cap*))
  (combinator (attractor-likelihood      a)
              (attractor-consequence     a)
              (attractor-coupling        a)
              (attractor-irreversibility a)
              (attractor-confidence      a)
              (pressure-factor a pressures #:cap pressure-factor-cap)))


;; ═══════════════════════════════════════════════════════════════════════
;; MINIMAX-REGRET MEASURES OVER A SET
;; ═══════════════════════════════════════════════════════════════════════

;;; minimax-regret — hard maximum. Returns (values R* worst), where
;;; R* is the largest regret-score in the catalogue and worst is the
;;; <attractor> achieving it. On an empty catalogue returns (values 0 #f).
;;;
;;; Use this for diagnostics and for ranking displays. It is
;;; non-differentiable, so the planner's gradient evaluator should
;;; instead consult soft-minimax-regret.
(define* (minimax-regret attractors pressures
                         #:key
                         (combinator *default-severity-combinator*)
                         (pressure-factor-cap *default-pressure-factor-cap*))
  (let loop ((as attractors) (best-r 0) (best-a #f))
    (cond
     ((null? as) (values best-r best-a))
     (else
      (let ((r (regret-score (car as) pressures
                             #:combinator combinator
                             #:pressure-factor-cap pressure-factor-cap)))
        (if (> r best-r)
            (loop (cdr as) r (car as))
            (loop (cdr as) best-r best-a)))))))

;;; ─── Modeling commitment 3: soft-minimax sharpness β ─────────────────
;;;
;;; *default-soft-minimax-beta* — sharpness of the soft-max surrogate.
;;; Larger β concentrates weight more tightly on the worst attractor
;;; (closer to hard max, sharper gradient transitions); smaller β
;;; spreads concern across the catalogue (smoother but blunter). β=0
;;; degenerates to the arithmetic mean of regret scores; β→∞ approaches
;;; the hard max. The numeric default 8.0 is a middle setting; the
;;; right value depends on how peaked the planner wants its gradient to
;;; be around the currently-worst basin.
(define *default-soft-minimax-beta* 8.0)

;;; soft-minimax-regret — log-sum-exp surrogate for max_k R_k.
;;;
;;;   R̃ = (1/β) · log Σ_k exp(β · R_k)
;;;
;;; This is smooth and differentiable everywhere, agrees with the hard
;;; max within O(log n / β), and reduces to it as β → ∞. This is the
;;; quantity H_eco's gradient is implicitly computing when ecological-bus
;;; priority weights are sourced from regret-score (commons.typ §"One
;;; Shared Scoreboard"). Exposed here as a standalone measure so the
;;; planner can read it without committing to the bowl-irreversible
;;; shape of H_eco — e.g. for triage dashboards or for plans where the
;;; ecological category has not yet been instantiated as buses.
(define* (soft-minimax-regret attractors pressures
                              #:key
                              (beta *default-soft-minimax-beta*)
                              (combinator *default-severity-combinator*)
                              (pressure-factor-cap *default-pressure-factor-cap*))
  (let ((score-of (lambda (a)
                    (regret-score a pressures
                                  #:combinator combinator
                                  #:pressure-factor-cap pressure-factor-cap))))
    (cond
     ((null? attractors) 0)
     ((<= beta 0)
      ;; β=0 degenerates to the arithmetic mean.
      (let ((rs (map score-of attractors)))
        (/ (apply + rs) (length rs))))
     (else
      ;; Numerically stable log-sum-exp.
      (let* ((rs   (map score-of attractors))
             (m    (apply max rs))
             (sumE (apply + (map (lambda (r) (exp (* beta (- r m)))) rs))))
        (+ m (/ (log sumE) beta)))))))

;;; regret-ranking — full sorted catalogue, descending by regret-score.
;;; Each row: (regret-score accumulated-pressure pressure-ratio tipped?
;;; attractor). The planner uses this to populate diagnostics; the
;;; minimax measure above is what feeds the harmony gradient.
(define* (regret-ranking attractors pressures
                         #:key
                         (limit #f)
                         (combinator *default-severity-combinator*)
                         (pressure-factor-cap *default-pressure-factor-cap*))
  (let* ((rows (map (lambda (a)
                      (list (regret-score a pressures
                                          #:combinator combinator
                                          #:pressure-factor-cap pressure-factor-cap)
                            (accumulated-pressure a pressures)
                            (pressure-ratio a pressures)
                            (tipped? a pressures)
                            a))
                    attractors))
         (sorted (sort rows (lambda (x y) (> (car x) (car y))))))
    (if limit
        (take sorted (min limit (length sorted)))
        sorted)))


;; ═══════════════════════════════════════════════════════════════════════
;; CASCADE PROPAGATION — feedback loops between attractors
;; ═══════════════════════════════════════════════════════════════════════
;;
;; A static pressure list captures "what stress is currently on each
;; target." But once an attractor tips, the post-tip regime *radiates
;; additional stress* to the basin's affected-targets — that is what
;; turns a list of independent attractors into a coupled dynamical
;; system with feedback loops.
;;
;; The propagation is iterative:
;;
;;   round 0: compute which attractors are tipped under base pressures
;;   round n: for each newly-tipped attractor, emit synthetic pressures
;;            onto its affected-targets (weight = coupling × radiation-
;;            strength); re-check tipping; repeat until fixed point or
;;            max-rounds reached.
;;
;; Cycles in the (watched ↔ affected) graph express feedback loops:
;; A→B→A means tipping A raises B's pressure, which can tip B, which
;; raises A's pressure further. Whether this converges to a stable
;; "more attractors tipped" state or oscillates is a property of the
;; coupling weights and thresholds; fixed-point iteration with
;; max-rounds guards against pathological cases.

;;; ─── Modeling commitment 4: cascade radiation strength ───────────────
;;;
;;; When a tipped attractor radiates stress to its affected-targets, the
;;; weight of each emitted synthetic pressure is `coupling ×
;;; radiation-strength`. Higher radiation-strength makes cascades more
;;; aggressive (a single tip is more likely to chain). Default 1.0
;;; treats coupling as the full downstream weight.
(define *default-cascade-radiation-strength* 1.0)

;;; ─── Modeling commitment 5: cascade iteration bound ──────────────────
;;;
;;; Hard upper bound on propagation rounds, in case the coupling graph
;;; never reaches a fixed point. With monotone propagation (synthetic
;;; pressures only added, never removed) and finitely many attractors,
;;; fixed point is reached in at most N rounds where N = #attractors,
;;; so this is a safety net. Default 64 is generous for any
;;; realistically-sized catalogue.
(define *default-cascade-max-rounds* 64)

;;; cascade-augmented-pressures — propagate feedback loops to fixed
;;; point. Returns the augmented pressure list (base + synthetic).
;;; The planner feeds this into minimax-regret / soft-minimax-regret to
;;; get a cascade-aware measure.
;;;
;;; Synthetic pressures are tagged with name 'cascade-radiation so they
;;; are distinguishable from base measurements; their confidence is
;;; inherited from the tipping attractor's confidence coefficient
;;; (a low-confidence tipping radiates a low-confidence cascade).
(define* (cascade-augmented-pressures attractors base-pressures
                                       #:key
                                       (radiation-strength
                                        *default-cascade-radiation-strength*)
                                       (max-rounds
                                        *default-cascade-max-rounds*))
  (let loop ((pressures base-pressures)
             (already-tipped '())
             (rounds 0))
    (let* ((now-tipped
            (filter (lambda (a) (tipped? a pressures)) attractors))
           (newly-tipped
            (filter (lambda (a)
                      (not (memq a already-tipped)))
                    now-tipped)))
      (cond
       ((null? newly-tipped) pressures)
       ((>= rounds max-rounds)
        ;; Safety bound reached; return what we have. A real planner
        ;; should warn here, but the module stays silent — this is a
        ;; pure function.
        pressures)
       (else
        (let ((new-synth
               (append-map
                (lambda (a)
                  (let ((w (* (attractor-coupling a) radiation-strength))
                        (conf (attractor-confidence a)))
                    (map (lambda (target)
                           (make-pressure 'cascade-radiation target w conf))
                         (attractor-affected-targets a))))
                newly-tipped)))
          (loop (append pressures new-synth)
                (append already-tipped newly-tipped)
                (+ rounds 1))))))))

;;; cascade-trace — diagnostic variant. Returns a list of rounds, each
;;; a list of attractor names that newly tipped in that round. Useful
;;; for explaining "why is regret so high" to a human reader.
(define* (cascade-trace attractors base-pressures
                        #:key
                        (radiation-strength
                         *default-cascade-radiation-strength*)
                        (max-rounds
                         *default-cascade-max-rounds*))
  (let loop ((pressures base-pressures)
             (already-tipped '())
             (rounds 0)
             (trace '()))
    (let* ((now-tipped
            (filter (lambda (a) (tipped? a pressures)) attractors))
           (newly-tipped
            (filter (lambda (a) (not (memq a already-tipped)))
                    now-tipped)))
      (cond
       ((or (null? newly-tipped) (>= rounds max-rounds))
        (reverse trace))
       (else
        (let ((new-synth
               (append-map
                (lambda (a)
                  (let ((w (* (attractor-coupling a) radiation-strength))
                        (conf (attractor-confidence a)))
                    (map (lambda (target)
                           (make-pressure 'cascade-radiation target w conf))
                         (attractor-affected-targets a))))
                newly-tipped)))
          (loop (append pressures new-synth)
                (append already-tipped newly-tipped)
                (+ rounds 1)
                (cons (map attractor-name newly-tipped) trace))))))))
