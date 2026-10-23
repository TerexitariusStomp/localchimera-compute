;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-mimir-recipe.scm — Mímir co-facilitation recipe smoke test
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/scope/test-mimir-recipe.scm

(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes mimir) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet knowledge catalogues substances))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(display "\n── Setup: Mímir ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Mimir Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-mimir-specs rs)
    (seed-mimir-recipes rs)

    (check-pred "engagement recipe seeded as 7-step chain"
                (= 7 (length ($ rs 'get-process-chain "recipe-mimir-engagement"))))
    (check-pred "instrument recipe seeded as 1-step chain"
                (= 1 (length ($ rs 'get-process-chain "recipe-mimir-instrument"))))
    (check-pred "closing recipe seeded as 1-step chain"
                (= 1 (length ($ rs 'get-process-chain "recipe-mimir-closing"))))

    (check-pred "engagement primary output is the audited hand-back"
                (string=? "spec:mimir-handback"
                          (recipe-primary-output
                            ($ rs 'get-recipe "recipe-mimir-engagement"))))
    (check-pred "instrument primary output is the instrument"
                (string=? "spec:mimir-instrument"
                          (recipe-primary-output
                            ($ rs 'get-recipe "recipe-mimir-instrument"))))
    (check-pred "closing primary output is the closing report"
                (string=? "spec:mimir-closing-report"
                          (recipe-primary-output
                            ($ rs 'get-recipe "recipe-mimir-closing"))))))

;;; ── gates: each stage consumes the AUDITED prior stage, not the draft ───────
(display "\n── Loop gating (consume-of-audited-output) ──\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (io ($ rs 'flows-for-process "rp-mimir-design"))
         (inputs (car io))
         (gate (find (lambda (f) (equal? "spec:mimir-predesign" (recipe-flow-resource-conforms-to f))) inputs)))
    (check-pred "design gates on the AUDITED pre-design (not the draft)"
                (and gate (eq? 'consume (recipe-flow-action gate))))))

;;; ── the delivery gate draws no facilitator hours ─────────────────────────────
(display "\n── Gate steps are use-only (no human work) ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (for-each
      (lambda (pid)
        (let* ((io ($ rs 'flows-for-process pid))
               (inputs (car io))
               (work-flow (find (lambda (f) (eq? 'work (recipe-flow-action f))) inputs)))
          (check-pred (string-append pid ": no work flow")
                      (not work-flow))))
      '("rp-mimir-gate-predesign" "rp-mimir-gate-design" "rp-mimir-gate-sequence"))))

;;; ── instrument shares design's sequence-group (parallel tier, no gate) ──────
(display "\n── Instrument runs alongside design, not gated after it ──\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (design (find (lambda (rp) (equal? "rp-mimir-design" (recipe-process-id rp)))
                       ($ rs 'get-process-chain "recipe-mimir-engagement")))
         (instrument (find (lambda (rp) (equal? "rp-mimir-instrument" (recipe-process-id rp)))
                           ($ rs 'get-process-chain "recipe-mimir-engagement")))
         (io ($ rs 'flows-for-process "rp-mimir-instrument"))
         (inputs (car io)))
    (check-pred "instrument present in the engagement chain"
                (and design instrument))
    (check "instrument shares design's sequence-group"
           (recipe-process-sequence-group instrument)
           (recipe-process-sequence-group design))
    (check-pred "instrument has no consume gate"
                (not (find (lambda (f) (eq? 'consume (recipe-flow-action f))) inputs)))))

;;; ── every spec is declared non-matter (no composition gap) ──────────────────
(display "\n── Composition: Mímir specs are all declared non-matter ──\n")

(define mimir-spec-ids
  '("spec:mimir-facilitator-h" "spec:mimir-agent"
    "spec:mimir-predesign-draft" "spec:mimir-predesign"
    "spec:mimir-session-design-draft" "spec:mimir-session-design"
    "spec:mimir-agenda-draft" "spec:mimir-handback"
    "spec:mimir-instrument" "spec:mimir-closing-report"))

(for-each
  (lambda (id)
    (check-pred (string-append "composition known for " id)
                (composition-known? id *contains*)))
  mimir-spec-ids)

(test-summary!)
