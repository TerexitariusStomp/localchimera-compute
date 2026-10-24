;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; propagate.scm — the cascade behind mutual coupling: p = e_k + C·p.
;;;
;;; A tree climbs (vf/aggregation/containment.scm: one direction, no cycles). A
;;; federation reconciles across a boundary (federation/wire.scm: ADMM, an
;;; iterative consensus over an open-ended nonlinear problem). Neither fits
;;; the case this module is for: a small, dense set of agents *within one
;;; solve* whose influence on each other can run BOTH ways — k stresses j and
;;; j stresses k back. That is a linear fixed point, not a walk and not a
;;; negotiation: p = e_k + C·p, solved by the Neumann series (I−C)^{-1}, C the
;;; coupling (agent → alist of (other-agent . coefficient)).
;;;
;;; First read: the ecological cascade (engine.scm's `*eco-couple*` — a
;;; frag-capped agent's effective pressure is its own draw plus every other
;;; agent's draw, weighted by how strongly it stresses this one). Extracted
;;; 2026-09-15 so further couplings — nutrient bioavailability
;;; (knowledge/nutrient-interaction.scm), skill cross-training
;;; (knowledge/skill-interaction.scm) — read through the identical
;;; combinator instead of a second hand-written fixed point. See
;;; docs/planning/solve/propagator.md for the shape and what comes after these.
;;;
;;; INTERACTIONS->COUPLING and EXPAND-COUPLE are the two authoring steps every
;;; caller of PROPAGATE needs and would otherwise write twice: a DRAFT table
;;; of (k j coefficient source) rows over bare agent names, turned into the
;;; hash PROPAGATE reads, and — for agents that are per-cell as well as
;;; per-kind (a nutrient, a skill; unlike a bare eco agent like "co2") —
;;; expanded across whatever concrete located suffixes a solve carries.

(define-module (localchimera vf formulas propagate)
  #:use-module (srfi srfi-1)
  #:export (propagate-agents propagate interactions->coupling expand-couple
            effective-values))

;; every agent named on either side of a coupling edge — the set PROPAGATE
;; walks. Pass this once per solve/table; it is the same set for every K.
(define (propagate-agents coupling)
  (delete-duplicates
   (append-map (lambda (kv) (cons (car kv) (map car (cdr kv))))
               (hash-map->list cons coupling))))

(define (%couple coupling k j) (or (assoc-ref (hash-ref coupling k '()) j) 0.0))

;; row K of (I−C)^{-1} over AGENTS: r_0 = e_k, r_{n+1} = e_k + r_n·C, to a
;; fixed point (200-iteration cap; converges whenever the coupling's spectral
;; radius is < 1 — a coupling of PROPORTIONS, never a coupling that could
;; amplify without bound).
(define (%b-row coupling agents k)
  (let loop ((r (map (lambda (a) (if (string=? a k) 1.0 0.0)) agents)) (it 0))
    (let ((rn (map (lambda (j) (+ (if (string=? j k) 1.0 0.0)
                                  (apply + (map (lambda (a rm) (* rm (%couple coupling a j))) agents r))))
                   agents)))
      (if (or (> it 200) (< (apply + (map (lambda (a b) (abs (- a b))) r rn)) 1e-12)) rn (loop rn (+ it 1))))))

;; the cascade Σ_j B[k][j]·draw-of(j) — K's effective pressure given any
;; draw-source, propagated through COUPLING. Identity when K names no coupled
;; agent (draw-of k) — the uncoupled case costs nothing extra, so a caller may
;; register a coupling for only the specs that need one.
(define (propagate coupling agents k draw-of)
  (if (member k agents)
      (append-map (lambda (j bkj) (if (= bkj 0.0) '()
                                      (map (lambda (p) (cons (car p) (* bkj (cdr p)))) (draw-of j))))
                  agents (%b-row coupling agents k))
      (draw-of k)))

;; INTERACTIONS (k j coefficient source) … over bare agent names → a coupling
;; hash k -> ((j . coefficient) …), the shape PROPAGATE and PROPAGATE-AGENTS
;; read. Multiple rows for the same k accumulate.
(define (interactions->coupling interactions)
  (let ((h (make-hash-table)))
    (for-each (lambda (e) (hash-set! h (car e) (cons (cons (cadr e) (caddr e)) (hash-ref h (car e) '()))))
              interactions)
    h))

;; INTERACTIONS over bare agent names, SUFFIXES the located goods a solve
;; actually carries ("ada#kitchen@0", "cook@bakery@0" — whatever a caller's
;; own cells look like) → concrete (k|suffix j|suffix coefficient) triples,
;; ready for an engine coupling keyword. An agent that is per-kind only (a
;; bare eco spec like "co2") needs no expansion at all — pass it straight to
;; INTERACTIONS->COUPLING instead. One that is per-cell too — a nutrient, a
;; skill — cannot be authored bare, because "iron|ada#kitchen@0" and
;; "iron|bo#kitchen@0" (or "skill-cook#bakery@0" and "skill-cook#cafe@1")
;; name different agents entirely; this is the one expansion step every such
;; domain needs, done once here rather than once per domain.
(define (expand-couple interactions suffixes)
  (append-map (lambda (suffix)
                (map (lambda (e) (list (string-append (car e) "|" suffix)
                                       (string-append (cadr e) "|" suffix)
                                       (caddr e)))
                     interactions))
              suffixes))

;; RAW: ((agent . amount) …) → the same shape, each amount replaced by its
;; EFFECTIVE (propagated) one — the pure-arithmetic reading of INTERACTIONS,
;; no solve, no columns. Every contribution collapses to the one dummy key
;; 'val on purpose (this sums a scalar; PROPAGATE's own callers merge many LP
;; columns under their real keys instead). An agent named in RAW but absent
;; from INTERACTIONS — nothing reads or feeds it — passes through unchanged.
;; catalogues/nutrient-interaction.scm's effective-nutrients and catalogues/skill-interaction.scm's
;; effective-skill-supply are this function under their own domain's name;
;; a third coupling's pure-math check is this function too, not a new one.
(define* (effective-values raw #:key (interactions '()))
  (let* ((coupling (interactions->coupling interactions))
         (agents (propagate-agents coupling))
         (draw-of (lambda (n) (let ((a (assoc n raw))) (if a (list (cons 'val (cdr a))) '())))))
    (map (lambda (e)
           (cons (car e)
                 (if (member (car e) agents)
                     (fold (lambda (p acc) (+ acc (cdr p))) 0.0
                           (propagate coupling agents (car e) draw-of))
                     (cdr e))))
         raw)))
