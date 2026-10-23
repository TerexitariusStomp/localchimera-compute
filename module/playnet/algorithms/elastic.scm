;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; algorithms/elastic.scm — the credit identity's arithmetic over cells.
;;;
;;; A scope's account store states its own credit CELLS (account.scm
;;; credit-cells): keyed sums with no person visible above their own scope
;;; except by the aid the claim needs. This module is everything computed
;;; from cells and nothing that reads a store: the monoid that adds two
;;; scopes' cells, the elastic equations (contribution by ability,
;;; citizenship, the claim capacity, the drawable balance), and the two
;;; published facts they stand on (social free time). The account store
;;; reads it to validate a claim; the credit fold reads it for every
;;; cross-scope answer; so a walk over roots and a standing node compute
;;; one arithmetic on one shape.

(define-module (playnet algorithms elastic)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf aggregation fold-node)
  #:use-module (playnet algorithms free-time)
  #:export (credit-combine credit-monoid cell-ref credit-node? credit-cells
            %sum-kind %citizens %holders credit-context entitlement-pool svc-at gross-at
            ability-contribution ability-norm
            contribution-claim citizenship-share
            total-claim-capacity effective-balance social-free-time-of social-free-time-for
            consumer-voices-of current-social-free-time set-social-free-time!))


;; The federation's current social free time f = 1 − Λ/(N·T), Λ the hours the
;; landed plans place and N·T the time their people have: the UC total of the
;; free-time fold (pools/free-time-fold.scm), published when it moves
;; (set-social-free-time!), and by the live planner's standing plan when it
;; stands alone (scope/live.scm). A question — a what-if, the bills — states
;; nothing. Drawable credit and consumer voice read it BY DEFAULT, so the
;; citizenship dividend flows automatically wherever a plan has landed. 0 until
;; the first plan (or in tests), which reduces exactly to contribution by
;; ability. The federation's, as credit is: every credit read goes over the whole
;; roster (doors/service.scm credit-roots), so one f is the right f for all of
;; them. One cell behind a setter (not a parameter) so every vat/thread sees
;; the latest published value, and the module stays declarative: no importer
;; can inline an initial value out of a cell it reads through
;; current-social-free-time.
(define %social-free-time (vector 0))
(define (current-social-free-time) (vector-ref %social-free-time 0))
(define (set-social-free-time! f)
  (vector-set! %social-free-time 0 (max 0 (min 1 (or (and (number? f) f) 0)))))


(define (credit-combine a b)
  (fold (lambda (cell acc)
          (let* ((key (car cell)) (kind (car key))
                 (hit (assoc key acc)))
            (if (not hit) (append acc (list cell))
                (let ((v (case kind
                           ((unmet citizen) (max (cdr hit) (cdr cell)))
                           ((ccf)           (min (cdr hit) (cdr cell)))
                           (else            (+   (cdr hit) (cdr cell))))))
                  (map (lambda (c) (if (equal? (car c) key) (cons key v) c)) acc)))))
        a b))
(define credit-monoid (make-monoid '() credit-combine))

(define (cell-ref cells key)
  (let ((p (assoc key cells))) (if p (cdr p) 0)))

;; ── this scope's OWN cells ──────────────────────────────────────────────────

;; ── either end of the one fold ───────────────────────────────────────────────
;; SOURCE is the standing ^credit-pool node (its total, kept up the tree) or a
;; LIST of scope roots, each root's account store stating its own cells,
;; folded here by the same monoid. Both answer from the same cells.
(define (credit-node? x) (not (or (null? x) (pair? x))))
(define (credit-cells source)
  (if (credit-node? source)
      ($ source 'cells)
      (fold (lambda (root acc) (credit-combine acc ($ ($ root 'account-store) 'credit-cells))) '() source)))

(define (%sum-kind cells kind)
  (fold (lambda (c acc) (if (eq? (caar c) kind) (+ acc (cdr c)) acc)) 0 cells))
(define (%citizens cells)
  (filter-map (lambda (c) (and (eq? (caar c) 'citizen) (cdar c))) cells))

(define (svc-at cells level)
  (if level (cell-ref cells (cons 'svc-at level)) (cell-ref cells '(svc . *))))
(define (gross-at cells aid level)
  (if level (cell-ref cells (cons 'gross-at (cons aid level))) (cell-ref cells (cons 'gross aid))))

;; ── contribution BY ABILITY ─────────────────────────────────────────────────
;; "From each according to ability": what a person gives is read against what
;; they could give. Their capacity a_p (the attested contribution-capacity
;; factor, a fact about their TIME — the same fact the plan's labour fairness
;; reads as fractional utilisation) scales their validated hours to the hours
;; a full capacity would have given: r_p = L_p / a_p. A half-capacity person
;; who worked all of their half has given everything, and is read so. A
;; person who can give nothing (a_p = 0) has given all they could: their r is
;; the standard — the mean r of those who can — and where nobody can, one, an
;; equal share. The pool is then distributed by r alone; no welfare fund is
;; carved from it and no supplement is added beside it, because the solidarity
;; is in the measure. Needs never enter here at all: they are met from the
;; commons before any distribution (the eat recipe, live.scm).
;;
;; READ ON CITIZENS ONLY. r is defined for a witnessed person (a `citizen`
;; cell — personhood is one per human, the ceremony's word) and the norm sums
;; over them; a key that is no citizen contributes nothing and draws nothing,
;; so a second key of the same person — at capacity zero, with no hours —
;; reads no standard share and splitting hours across keys gains nothing
;; (Incentives.lean split_no_gain's additivity, held here by construction).
(define (%ccf-of cells aid)
  (let ((p (assoc (cons 'ccf aid) cells))) (if p (cdr p) 1)))
(define* (ability-contribution cells aid #:optional level)
  "r_p — AID's validated hours at LEVEL, scaled to full capacity; 0 for a
   key that is no citizen."
  (let ((citizens (%citizens cells)))
    (if (not (member aid citizens)) 0
        (let ((a (%ccf-of cells aid)) (g (gross-at cells aid level)))
          (cond ((> a 0) (/ g a))
                (else (let ((able (filter (lambda (h) (> (%ccf-of cells h) 0)) citizens)))
                        (if (null? able) 1
                            (/ (fold (lambda (h acc) (+ acc (/ (gross-at cells h level) (%ccf-of cells h)))) 0 able)
                               (length able))))))))))
(define* (ability-norm cells #:optional level)
  "Σ_p r_p over every citizen — what the pool is distributed by."
  (fold (lambda (h acc) (+ acc (ability-contribution cells h level))) 0 (%citizens cells)))

(define (entitlement-pool cells)
  "The labour-hours the citizens' shares are shares OF: the claimable pool as it
   stands plus every hour already claimed out of it. A claim moves value from
   the pool to the claimant's own holdings and leaves the whole it was drawn
   from where it was, so what a person may still draw is their share of that
   whole less their own claims, and Σ drawable credit is the pool as it stands."
  (+ (cell-ref cells '(pool . *)) (%sum-kind cells 'claimed)))

(define* (credit-context cells #:optional level)
  "(entitlement-pool ability-norm) — the two numbers the distribution stands on."
  (list (entitlement-pool cells) (ability-norm cells level)))

(define* (contribution-claim cells aid #:optional level)
  "AID's share of the entitlement pool by ability: pool · r_p / Σ r. A LEVEL (a
   recognizing scope-id) reads the stratified cells; #f the universal."
  (let ((norm (ability-norm cells level)))
    (if (= 0 norm) 0 (* (entitlement-pool cells) (/ (ability-contribution cells aid level) norm)))))

(define (citizenship-share cells aid f)
  (let ((g (max 0 (min 1 f))) (aids (%citizens cells)))
    (if (or (<= g 0) (null? aids) (not (member aid aids))) 0
        (/ (* (entitlement-pool cells) g) (length aids)))))

(define* (total-claim-capacity cells aid f #:optional level)
  "Contribution by ability + CITIZENSHIP. Social free time F carves the pool
   two ways: contribution is the share of pool·(1−F); citizenship the equal
   share of pool·F. The two always sum to the entitlement pool."
  (let ((g (max 0 (min 1 f))))
    (+ (* (- 1 g) (contribution-claim cells aid level))
       (citizenship-share cells aid g))))
(define* (effective-balance cells aid f #:optional level)
  "Drawable credit: total claim capacity less what AID has claimed so far."
  (max 0 (- (total-claim-capacity cells aid f level) (cell-ref cells (cons 'claimed aid)))))
(define (social-free-time-of cells per-citizen-hours)
  "The REALIZED reading of social free time: 1 − L/(N·T), L the validated
   labour the cells hold, N the citizens, T PER-CITIZEN-HOURS; 0 when N·T ≤ 0
   or labour fills it. This is not the f that governs: credit and voice read the
   plan's own f (`current-social-free-time`, published by each solve from the
   hours the plan places), and this reading stands only where a caller passes
   a horizon (`social-free-time-for`)."
  (free-time-fraction (svc-at cells #f) (* (length (%citizens cells)) per-citizen-hours)))
(define (%holders cells)             ; every account holder, person or not
  (filter-map (lambda (c) (and (eq? (caar c) 'gross) (cdar c))) cells))

(define* (social-free-time-for cells per-citizen-hours)
  "Social free time f for CELLS: the horizon's reading (`social-free-time-of`)
   when PER-CITIZEN-HOURS is given, else the live value the plan last published."
  (if per-citizen-hours (social-free-time-of cells per-citizen-hours) (current-social-free-time)))

(define* (consumer-voices-of cells f #:optional level)
  "The consumer voice of every holder in CELLS at social free time F:
   ((aid . v_p) …), each holder's total claim capacity over the total across
   holders (§The credit identity). Σ = 1 by construction, and '() while no
   capacity stands (an empty pool), where the share is undefined. The one law
   a federation scope's credit fold and a household's own members both read;
   what has been claimed leaves capacity, and so voice, where it was
   (glossary, Drawdown)."
  (let* ((held  (map (lambda (a) (cons a (total-claim-capacity cells a f level))) (%holders cells)))
         (total (fold (lambda (h acc) (+ acc (cdr h))) 0 held)))
    (if (> total 0) (map (lambda (h) (cons (car h) (/ (cdr h) total))) held) '())))
