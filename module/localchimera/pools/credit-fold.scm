;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/credit-fold.scm — ^credit-pool: the federation fold, over credit.
;;;
;;; Universal credit is federation-wide by design: your labour anywhere earns
;;; a share of the claimable stock everywhere (account.scm §Global
;;; aggregation). The elastic math there sums a caller-supplied FLAT list of
;;; scope-roots with synchronous calls — the shape refederation breaks and a
;;; remote root cannot answer. This is the same math as a fold: each scope
;;; contributes its OWN cells, the tree sums them keyed, and every global-*
;;; read becomes a read of the standing total.
;;;
;;; It is `^fold-node` (vf/aggregation/fold-node.scm) with credit's three pieces:
;;;
;;;   monoid   keyed sums — (kind . aid) per citizen, (kind . *) per scalar
;;;   writes   credit-changed: re-derive this scope's own cells from its
;;;            account-store + observer (credit changes rarely next to needs,
;;;            so the full re-read is the whole write path — means-fold's rule)
;;;   reads    the elastic equations, over the total
;;;
;;; Cells: (gross . aid) validated social labour · (claimed . aid) ·
;;; (ccf . aid) capacity met · (unmet . aid) = 1−ccf · (citizen . aid) = 1 ·
;;; (pool . *) embodied labour in the claimable pool · (svc . *) total social
;;; svc. Ratios are READS, never cells — ratios do not add.
;;;
;;; What crosses a boundary here is keyed by citizen: credit is the one
;;; aggregate whose reads ask "this person's share", so identity rides up as
;;; labour's roster does (fold-node.scm's per-fold disclosure rule).
;;;
;;; Semantics are account.scm's, with the Phase-2 multi-counting DECIDED
;;; (credit-combine below): labour and claims add across scopes; a person's
;;; capacity need is one fact, taken at its greatest assessment; a citizen
;;; counts once. Everything else about the equations is verbatim.

(define-module (localchimera pools credit-fold)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (localchimera vf aggregation fold-node)
  #:use-module (localchimera algorithms elastic)
  #:re-export (credit-monoid cell-ref credit-node? credit-cells)   ; elastic.scm's, read through here too
  #:export (scope-own-credit ^credit-pool
            credit-reads credit-writes wire-credit-node!
            scope-subtree-credit
            ;; THE WALK IS THE FOLD: every cross-scope read takes a credit node
            ;; or a list of scope roots and reads the same cells either way
            global-total-social-svc global-embodied-labor-in-pool global-sum-met-capacity
            global-sum-unmet-capacity global-citizen-gross global-citizen-claimed
            global-citizen-unmet global-elastic-context
            global-contribution-claim global-citizen-ability global-ability-norm global-citizen-count
            global-citizenship-share global-social-free-time global-total-claim-capacity
            global-effective-balance voice-share consumer-voice consumer-voices
            ))

;; The combine decides, per KIND, what a citizen present in N scopes means:
;;   gross, claimed, pool, svc  ADD — labour anywhere earns everywhere, a
;;                               claim anywhere draws on the same credit
;;   ccf, unmet                 are ONE fact about ONE person, assessed per
;;                               commune: the federation takes the person's
;;                               GREATEST assessed need (max unmet, min ccf)
;;                               — a capacity is not multiplied by being seen
;;                               from several places, and the reading errs
;;                               toward the assessment that found it
;;   citizen                    one, however many scopes hold an account
;; This is the Phase-2 multi-counting (account.scm) decided: a monoid whose
;; combine is keyed by what the cell IS. Associative and commutative per
;; kind (sum, max, min, max), so the tree may fold in any order.
(define (scope-own-credit scope-root)
  "This scope's OWN cells: what its account store states (account.scm
   credit-cells) — the one place the person is read."
  ($ ($ scope-root 'account-store) 'credit-cells))

(define credit-reads
  `((cells          . ,(lambda (t) t))
    (context        . ,(lambda (t) (credit-context t)))
    (pool           . ,(lambda (t) (cell-ref t '(pool . *))))
    (sum-met        . ,(lambda (t) (%sum-kind t 'ccf)))
    (sum-unmet      . ,(lambda (t) (%sum-kind t 'unmet)))
    ;; a LEVEL (a recognizing scope-id) reads the stratified cell; #f the universal
    (citizen-gross  . ,(lambda (t aid . lv)
                         (if (and (pair? lv) (car lv))
                             (cell-ref t (cons 'gross-at (cons aid (car lv))))
                             (cell-ref t (cons 'gross aid)))))
    (citizen-claimed . ,(lambda (t aid) (cell-ref t (cons 'claimed aid))))
    (citizen-unmet  . ,(lambda (t aid) (cell-ref t (cons 'unmet aid))))
    (citizen-count  . ,(lambda (t) (length (%citizens t))))
    (citizens       . ,(lambda (t) (%citizens t)))
    (citizenship-share . ,(lambda (t aid . f)
                            (citizenship-share t aid (if (pair? f) (car f) 0))))
    (total-social-svc . ,(lambda (t . lv)
                           (if (and (pair? lv) (car lv))
                               (cell-ref t (cons 'svc-at (car lv)))
                               (cell-ref t '(svc . *)))))
    (voice-share    . ,(lambda (t aid . lv)
                         (let* ((l (and (pair? lv) (car lv)))
                                (svc (if l (cell-ref t (cons 'svc-at l)) (cell-ref t '(svc . *))))
                                (g   (if l (cell-ref t (cons 'gross-at (cons aid l)))
                                         (cell-ref t (cons 'gross aid)))))
                           (if (= 0 svc) 0 (/ g svc)))))
    (contribution-claim . ,(lambda (t aid . lv) (contribution-claim t aid (and (pair? lv) (car lv)))))
    (citizen-ability . ,(lambda (t aid . lv) (ability-contribution t aid (and (pair? lv) (car lv)))))   ; r_p: hours given, scaled to full capacity
    (ability-norm    . ,(lambda (t . lv) (ability-norm t (and (pair? lv) (car lv)))))                    ; Σ r — what the pool is distributed by
    (total-claim-capacity . ,(lambda (t aid . f)
                               (total-claim-capacity t aid (if (pair? f) (car f) 0))))
    (effective-balance . ,(lambda (t aid . f)
                            (effective-balance t aid (if (pair? f) (car f) 0))))))

(define credit-writes
  `((credit-changed . ,(lambda (own scope-root) (scope-own-credit scope-root)))))

(define ^credit-pool
  (fold-aggregate credit-monoid credit-reads credit-writes #:prefix "credit"))

;; ── the pull: the same fold, as its definition ──────────────────────────────
(define (scope-subtree-credit scope)
  (fold-tree-total credit-monoid scope scope-own-credit))

;; ── THE WALK IS THE FOLD ────────────────────────────────────────────────────
;; Every cross-scope read takes SOURCE as either end of the one fold: the
;; standing ^credit-pool node (its total, kept up the tree) or a LIST of
;; scope roots, folded here by the same monoid over the same own-function.
;; Both answer from the same cells, so the walk is the node's definition
;; and a level reads the stratified cells either way.
(define* (global-total-social-svc src #:optional level) (svc-at (credit-cells src) level))
(define (global-embodied-labor-in-pool src) (cell-ref (credit-cells src) '(pool . *)))
(define (global-sum-met-capacity src) (%sum-kind (credit-cells src) 'ccf))
(define (global-sum-unmet-capacity src) (%sum-kind (credit-cells src) 'unmet))
(define* (global-citizen-gross aid src #:optional level) (gross-at (credit-cells src) aid level))
(define (global-citizen-claimed aid src) (cell-ref (credit-cells src) (cons 'claimed aid)))
(define (global-citizen-unmet aid src) (cell-ref (credit-cells src) (cons 'unmet aid)))
(define* (global-elastic-context src #:optional level)
  "(pool total-svc ability-norm); LEVEL stratifies the labour side."
  (let ((t (credit-cells src)))
    (list (entitlement-pool t) (svc-at t level) (ability-norm t level))))
(define* (global-contribution-claim aid src #:optional level) (contribution-claim (credit-cells src) aid level))
(define* (global-citizen-ability aid src #:optional level) (ability-contribution (credit-cells src) aid level))
(define* (global-ability-norm src #:optional level) (ability-norm (credit-cells src) level))
(define (global-citizen-count src)
  "Distinct citizens — witnessed persons holding accounts (person-aid?)."
  (length (%citizens (credit-cells src))))
(define* (global-citizenship-share aid src #:optional (f 0)) (citizenship-share (credit-cells src) aid f))
(define (global-social-free-time src per-citizen-hours) (social-free-time-of (credit-cells src) per-citizen-hours))
(define* (global-total-claim-capacity aid src #:optional level (f (current-social-free-time)))
  (total-claim-capacity (credit-cells src) aid f level))
(define* (global-effective-balance aid src #:optional level (f (current-social-free-time)))
  (effective-balance (credit-cells src) aid f level))

(define* (voice-share aid src #:optional level)
  "Dimensionless governance voice share = citizen_gross / total_svc:
   (hours-on scope owner) / (hours-on scope) through the observer's one
   reader of validated hours on a part (`hours-on`, the scope as the widest
   part), carried up the credit fold's stratified cells. The voice fold reads
   the same `hours-on` for every narrower part, so the standing that weighs
   a ballot and the push that bends a solve are one number read at two
   grains. PURE labor proportion: non-workers have zero voice; consumption
   leaves voice unchanged (voice ∝ work, consumption ∝ need). LEVEL
   stratifies by federation plan-confirmation; #f is universal."
  (let* ((t (credit-cells src)) (total (svc-at t level)))
    (if (= 0 total) 0 (/ (gross-at t aid level) total))))

(define* (consumer-voice aid src #:optional level per-citizen-hours)
  "Dimensionless CONSUMER voice — the citizen's share of the individually
   claimable pool: their total claim capacity over the total across every
   account holder (contribution by ability + citizenship, solidarity carried
   in the ability), so it sums to one. Drawdown does not enter: a claim lowers
   what the citizen may still draw (`effective-balance`) and leaves their voice
   where their work, capacity and citizenship put it (§The credit identity;
   glossary, Drawdown). #f when the claimable pool is empty — the share is
   undefined, and a caller shows the qualitative voice instead of 0%. A person
   who holds no account has no claim capacity here: #f."
  (assoc-ref (consumer-voices src level per-citizen-hours) aid))

(define* (consumer-voices src #:optional level per-citizen-hours)
  "Every holder's consumer voice (`consumer-voice`) off ONE reading of SRC:
   ((aid . share) …) summing to one, or '() while the claimable pool is empty.
   A reader that asks for many citizens (every need in a fold names one) takes
   this once and looks them up, instead of re-summing the holders per citizen."
  (let ((t (credit-cells src)))
    (consumer-voices-of t (social-free-time-for t per-citizen-hours) level)))

;; ── wiring ──────────────────────────────────────────────────────────────────
(define* (wire-credit-node! scope-root node #:key (parent #f) (scope-id #f))
  "Seed OWN from the scope's stores, refold on every event the observer
   records and every account mutation (both additive listener doors), hand
   the TOTAL to PARENT keyed by SCOPE-ID.

   The refold is an EVENTUAL send: a listener fires inside the store's own
   turn, before its bcom lands, and a near call back into that store would
   read the state it is about to leave. Next turn, the store answers new."
  (let ((refold (lambda args (<-np node 'credit-changed scope-root))))
    ($ ($ scope-root 'observer) 'add-event-listener refold)
    ($ ($ scope-root 'account-store) 'add-change-listener refold))
  ($ node 'credit-changed scope-root)
  (wire-fold-parent! node parent scope-id))
