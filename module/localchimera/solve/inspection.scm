;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; solve/inspection.scm — inspection for a LIVE scope: the conformance edges a plan
;;; leans on, made into freshness stocks the plan must keep, and the loads it
;;; routes through them, read back off the solve.
;;;
;;; docs/legal/inspection-in-plan.md, slices 1–2, proved the mechanism in
;;; tests: a conformance edge — a body still holding a skill, an oven still in
;;; spec — is a claim that DRIFTS; its verification freshness `Verif|<edge>` is a
;;; storable stock that relying on the edge WEARS (a `consume` on every recipe
;;; that leans on it) and that an inspection `work` recipe RESTORES (a `produce`,
;;; costing a verifier's hours). The Cond|durable wear→maintenance twin, keyed to
;;; a claim instead of a bearing. Slice 4 closed the credential loop for SKILLS
;;; only, off the solved work. This file is what a live scope was missing:
;;;
;;;   scope-inspection   the builder — from a scope's own recipes, every edge it
;;;                      relies on becomes a freshness stock + an inspect recipe,
;;;                      so the plan SCHEDULES the verifier's hours in the solve
;;;                      (the twin of scope-consumption for the reproduction of
;;;                      labour-power);
;;;   commitment-loads   the reader — the hours the solved plan routes through
;;;                      each edge, skills (work) AND means (a durable's Svc| draw),
;;;                      one fold, feeding conformance-recert-schedule for both.
;;;
;;; Plain defines, primitive-loaded by live.scm beside catalogues/subsistence.scm.
;;; Every number the barrier needs is governed: the steepness comes from
;;; conformance-catalogue.scm; wear/restore/initial freshness are the scope's own
;;; declaration, defaulted here as unit rates.

;; ── the edges a plan leans on ────────────────────────────────────────────────
;; Read off the scope's recipe flows, once: a `work` flow names a SKILL edge, a
;; `use` flow names a MEANS edge (an instrument whose conformance the process
;; assumes). ((kind . spec) …), each spec once.
(define-module (localchimera solve inspection)
  #:use-module ((localchimera utils units) #:select (%effort-unit))
  #:use-module ((localchimera vf facts located) #:select (cell lg))
  #:use-module ((localchimera vf formulas flows) #:select (row-figure))
  #:use-module (localchimera vf formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera vf aggregation fold-node) #:select (sum-by-key))
  #:use-module (localchimera vf schemas)
  #:use-module (ice-9 format)
  #:export (reliance-edges verif-spec verif-spec? scope-inspection commitment-loads))

(define (reliance-edges flows)
  (delete-duplicates
   (filter-map (lambda (f)
                 (let ((spec (recipe-flow-resource-conforms-to f)))
                   (and (string? spec)
                        (case (recipe-flow-action f)
                          ((work) (cons 'skill spec))
                          ((use)  (cons 'means spec))
                          (else #f)))))
               flows)))

;; the freshness stock's spec for an edge — a Verif| good, storable, one per edge
(define (verif-spec spec) (string-append "Verif|" spec))
(define (verif-spec? s) (and (string? s) (string-prefix? "Verif|" s)))

;; ── the builder ──────────────────────────────────────────────────────────────
;; Everything a live solve needs to carry inspection, from the scope's own recipes:
;;   procs      one `inspect~<spec>` process per edge
;;   flows      per relying process a `consume` of Verif|<spec> (wear per run), and
;;              per inspect process a `work` of the verifier skill + a `produce` of
;;              Verif|<spec> (restore per run)
;;   resources  the starting freshness — Verif|<spec> on hand at each place, the
;;              credential as last verified (0 ⇒ nothing is trusted until checked)
;;   storable   the Verif| specs — freshness carries forward, like a condition
;;   bands      the confidence margin, per Verif| good at every cell: a reproduction
;;              BAND floor with a margin — hard at 0 (nothing relies on an unverified
;;              edge), at ease at quantile_alpha of `margin` runs of freshness above
;;              it, defended at the governed steepness. `held`, not a log barrier: a
;;              freshness stock is a LEVEL, and a log barrier on a level over-makes
;;              by w/κ (test-shape-by-side) — the verifier would spend every hour
;;              making freshness nobody draws. The band is what a floor means.
;; Returned as one alist so a caller appends each part to its own list; a scope
;; with no edges gets empty parts and an unchanged solve.
(define* (scope-inspection procs flows places periods
                           #:key (verifier "auditor") (wear 1.0) (restore 1.0) (fresh 0.0)
                                 (margin 1.0) (alpha 0.5) (steepness 0.5)
                                 (edges (reliance-edges flows)))
  (define (relies-on? f spec)                     ; does this flow lean on the edge?
    (and (equal? (recipe-flow-resource-conforms-to f) spec)
         (memq (recipe-flow-action f) effort-actions)))
  (define (relying-procs spec)                    ; the processes that lean on it
    (delete-duplicates
     (filter-map (lambda (f) (and (relies-on? f spec) (recipe-flow-recipe-input-of f))) flows)))
  (let ((iprocs '()) (iflows '()) (ires '()))
    (for-each
     (lambda (e)
       (let* ((spec (cdr e)) (v (verif-spec spec)) (rid (string-append "inspect~" spec)))
         ;; wear: every relying process consumes freshness per run
         (for-each (lambda (pid)
                     (set! iflows (cons (make-recipe-flow #:id (string-append pid "<" v) #:action 'consume #:resource-conforms-to v
                                          #:resource-quantity (make-measure wear "unit") #:recipe-input-of pid)
                                        iflows)))
                   (relying-procs spec))
         ;; restore: one inspect recipe — the verifier's hours → freshness, no product
         (set! iprocs (cons (make-recipe-process #:id rid #:name (string-append "inspect " spec)
                                                 #:sequence-group 0) iprocs))
         (set! iflows (cons (make-recipe-flow #:id (string-append rid "-w") #:action 'work #:resource-conforms-to verifier
                                              #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of rid)
                            iflows))
         (set! iflows (cons (make-recipe-flow #:id (string-append rid ">" v) #:action 'produce #:resource-conforms-to v
                                              #:resource-quantity (make-measure restore "unit") #:recipe-output-of rid #:is-primary #t)
                            iflows))
         ;; the credential as it stands: freshness on hand at each place
         (when (> fresh 0.0)
           (for-each (lambda (place)
                       (set! ires (cons (make-economic-resource #:id (string-append v "@" place) #:conforms-to v #:classified-as '()
                                          #:accounting-quantity (make-measure fresh "unit") #:onhand-quantity (make-measure fresh "unit") #:current-location place)
                                        ires)))
                     places))))
     edges)
    `((edges . ,edges)
      (procs . ,(reverse iprocs))
      (flows . ,(reverse iflows))
      (resources . ,(reverse ires))
      (storable . ,(map (lambda (e) (verif-spec (cdr e))) edges))
      (bands . ,(append-map
                 (lambda (e)
                   (append-map (lambda (place)
                                 (map (lambda (t)
                                        (list (lg (verif-spec (cdr e)) (cell place t))
                                              (list 0.0 margin alpha) #f steepness))
                                      periods))
                               places))
                 edges)))))

;; ── the reader ───────────────────────────────────────────────────────────────
;; The load a solved plan routes through each conformance edge — ((edge . hours) …)
;; — the input conformance-recert-schedule wants. Skills: the effort of the `work`
;; commitments, by skill. Means: a durable in use is a per-period service draw, a
;; `consume` of Svc|<spec> among the material commitments, by spec. One fold, both
;; edges; sorted so the schedule is stable.
(define (commitment-loads coms mat)
  ;; a keyed sum — the federation fold's own monoid (sum-by-key), so a
  ;; cross-scope reliance aggregate is the same cells, combined once more
  (define (cell k q) (and (string? k) (number? q) (> q 0.0) (cons k q)))
  (let ((cells
         (append
          (filter-map (lambda (wc)
                        (let ((eq* (commitment-effort-quantity wc)))
                          (cell (commitment-resource-conforms-to wc)
                                (and eq* (measure-has-numerical-value eq*)))))
                      coms)
          (filter-map (lambda (mc)
                        (let ((spec (commitment-resource-conforms-to mc)))
                          (and (memq (commitment-action mc) occupying-actions)   ; a means in use, under its own specification
                               (string? spec)
                               (cell spec (row-figure mc)))))   ; its hours (effortQuantity)
                      mat))))
    (sort (sum-by-key '() cells) (lambda (a b) (string<? (car a) (car b))))))
