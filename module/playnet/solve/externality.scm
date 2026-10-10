;;; solve/externality.scm — what an ask displaces in the rest of the plan.
;;;
;;; One pattern, scope-free: withdraw a demand, re-solve, difference what the
;;; others are granted. family.scm proved it at the smallest scope (the purse:
;;; one good, euros); this module is the pattern with the scope injected, plus
;;; the marginal reader that needs no re-solve at all — the standing solve's
;;; own duals. Kept decoupled the provenance-trace way: it imports NO solver;
;;; the solve, the grant reading, and the pulls arrive as arguments, so it
;;; works against family-split, a live scope's plan, or a federated solve
;;; unchanged, and is testable with fakes.
;;;
;;; TRACTABILITY CONTRACT. The externality of a row is computed only in the
;;; scope that owns the row; wider scopes read aggregates, never persons
;;; (economy/demand-fold.scm strips the AID at every fold, so above the
;;; owning scope the row does not even exist). Within a scope:
;;;   compute  `withdrawal-displacement` is one warm re-solve per row read — linear
;;;            in rows, embarrassingly parallel; `marginal-displacement` is free.
;;;   memory   O(1) per row: each counterfactual result is consumed to one
;;;            number HERE and dropped — nothing retains a counterfactual
;;;            plan, so the display's footprint is scalars beside the rows.
;;; The two agree for asks small against their purse (the envelope theorem);
;;; read the big asks exactly, the long tail marginally.
;;;
;;; This module is stage 0 of the truth-telling design path — the instrument
;;; every later mechanism (kind ratification, the voice stock, audits, the
;;; folds' pulls) is calibrated from: docs/planning/identity/truth-telling.md.
;;;
;;; "Externality" is the literature's word, kept so the theorems stay
;;; checkable — the number itself is decision-information for the one margin
;;; its person controls, and it does not partition: leave-one-out reads
;;; overlap, and scarcity is reciprocal (it takes two wants to make a purse
;;; bind). The verbs are relational — "displaces", "moved" — for the citizen
;;; and in the code alike: a displacement is measured and shown, and nobody
;;; is charged it.

(define-module (playnet solve externality)
  #:use-module (srfi srfi-1)
  #:export (paired-difference withdrawal-displacement voice-displacement marginal-displacement
            marginal-rows note-solve moved-summary))

;;; ── the one difference ─────────────────────────────────────────────────────
;;; docs/planning/voice/weights-and-books.md §5: a plan is read back as the
;;; difference of two solves of ONE program under two settings. A bill (a tier
;;; held / nothing held: engine `bills-fold`), regret (pinned / unpinned:
;;; offers.scm `accept-regret`), what voice displaces (the field on / at zero:
;;; the planner's `voice-displacement` door), what a withdrawal frees
;;; (`withdrawal-displacement`) — each is a setting of this one operator, and each
;;; is written through it. SOLVE-AT : setting → result, with the floor and the warm start
;;; captured in the caller's closure so both solves stop at one settled floor;
;;; READ : result → number. Nothing here retains a counterfactual plan.
(define* (paired-difference solve-at read a b #:key (minus -))
  "(read (solve-at A)) − (read (solve-at B)). MINUS is the difference on what
   READ returns: `-` on a number (hours, euros, met need), a row-wise net on
   a bill (engine `bill-net`) — the one operator, whatever the reading."
  (minus (read (solve-at a)) (read (solve-at b))))

(define (voice-displacement solve-at read tau)
  "What voice displaces, as a total: the program with the field at TAU against
   the same program with the field at zero, read by READ (hours added, draws
   added on each wall, met need lost or gained — the caller's reading). The
   planner's `voice-displacement` door reads it beside the marginal the solve's own
   alist carries (solve/voice-field.scm `voice-report`); the two agree for small τ."
  (paired-difference solve-at read tau 0.0))

(define (withdrawal-displacement solve granted base rows keep? owner)
  "What the rows KEEP? rejects displace in the others: the value GRANTED to what
   OWNER does not own, in the counterfactual solve of ROWS without them,
   minus the same read of BASE. SOLVE : rows → result; GRANTED : result ×
   owner → number (family.scm's euros-to-others is the one-good case; a
   dual-valued read is the many-good case). By convexity a withdrawal only
   frees resources, so the displacement is ≥ 0 up to solver noise."
  (paired-difference (lambda (setting) (if (eq? setting 'without) (solve (filter keep? rows)) base))
                (lambda (r) (granted r owner))
                'without 'base))

(define (marginal-displacement pull-of quantities)
  "An ask read at the standing solve's duals: Σ pull(g)·q(g) over
   QUANTITIES ((good . qty) …), skipping goods the plan holds no pull for.
   PULL-OF : good → dual | #f (provenance-trace's `make-pull-of` fits).
   The free reader — no re-solve; exact in the small-ask limit."
  (fold + 0.0
        (filter-map (lambda (gq)
                      (let ((p (pull-of (car gq))))
                        (and p (* p (cdr gq)))))
                    quantities)))

;;; ── the instrument's memory: the burn-meter ────────────────────────────────
;;; One solve's display persisted beside the next's accumulates the empirical
;;; distribution of externalities per scope — the data that sizes a voice
;;; budget before any charge exists, and the scope's measured VCG bill: what
;;; dominant-strategy truthfulness would cost, read rather than theorized
;;; (truth-telling.md, stage 0 and the burn-meter). Pure folds over alists,
;;; like the readers above: the caller owns where a history lives.

(define (marginal-rows asks pull-of)
  "One solve's display rows over ASKS ((spec . qty) …):
     (((spec . s) (qty . q) (mu . μ) (moved . μ·q)) …)
   — each ask at the solve's own duals, the asks the plan holds no pull for
   skipped (a spec no recipe touched has nothing to displace)."
  (filter-map (lambda (sq)
                (let ((mu (pull-of (car sq))))
                  (and mu
                       `((spec . ,(car sq)) (qty . ,(exact->inexact (cdr sq)))
                         (mu . ,mu) (moved . ,(* mu (cdr sq)))))))
              asks))

(define* (note-solve history rows #:key (at #f) (keep 64))
  "HISTORY (newest first) with one solve's ROWS prepended as
     ((at . AT) (total . Σ moved) (rows . ROWS))
   and bounded to the newest KEEP solves — a display kept is a distribution
   grown, and the bound keeps it plan metadata rather than a ledger."
  (let ((snap `((at . ,at)
                (total . ,(fold + 0.0 (map (lambda (r) (assq-ref r 'moved)) rows)))
                (rows . ,rows))))
    (list-head (cons snap history) (min keep (+ 1 (length history))))))

(define (moved-summary history)
  "The accumulated distribution, read for display and for sizing:
     ((solves . N) (mean-total . t̄)
      (specs . (((spec . s) (solves . n) (mean-moved . m̄) (last-mu . μ)) …)))
   Per spec: how often it was read, the mean of what it moved, and the
   newest dual — the number an honest week is sized against."
  (let ((per (make-hash-table)))
    (for-each
     (lambda (snap)
       (for-each (lambda (r)
                   (let* ((s (assq-ref r 'spec))
                          (e (hash-ref per s '(0 0.0 #f))))   ; (n Σmoved last-μ)
                     (hash-set! per s (list (+ 1 (car e))
                                            (+ (cadr e) (assq-ref r 'moved))
                                            (or (caddr e) (assq-ref r 'mu))))))
                 (assq-ref snap 'rows)))
     history)                                    ; newest first ⇒ first μ seen is the last solve's
    `((solves . ,(length history))
      (mean-total . ,(if (null? history) 0.0
                         (/ (fold + 0.0 (map (lambda (s) (assq-ref s 'total)) history))
                            (length history))))
      (specs . ,(hash-map->list
                 (lambda (s e)
                   `((spec . ,s) (solves . ,(car e))
                     (mean-moved . ,(/ (cadr e) (car e)))
                     (last-mu . ,(caddr e))))
                 per)))))
