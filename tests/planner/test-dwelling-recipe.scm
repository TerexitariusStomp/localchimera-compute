;;; test-dwelling-recipe.scm — the shelter recipe: shape, units, and the claims
;;; the housing rails hang on.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/planner/test-dwelling-recipe.scm

(use-modules (playnet test harness))
(use-modules (playnet planner knowledge recipes dwelling) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet planner doors service))
(use-modules (playnet planner knowledge catalogues substances))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(display "\n── Setup: dwelling ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Dwelling Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-dwelling-specs rs)
    (seed-dwelling-recipe rs)

    ;; ── chain shape ─────────────────────────────────────────────────────────
    (check-pred "shelter recipe seeded as a single-step chain"
                (= 1 (length ($ rs 'get-process-chain "recipe-shelter"))))
    (check-pred "primary output is the shelter service"
                (string=? "spec-shelter"
                          (recipe-primary-output ($ rs 'get-recipe "recipe-shelter"))))

    ;; ── the process states its length (a night: the untimed-use anchor) ─────
    (let ((rp ($ rs 'get-recipe-process "rp-shelter-night")))
      (check-pred "rp-shelter-night states has-duration"
                  (and rp (recipe-process-has-duration rp)))
      (check-pred "…of 8 hours — a night, atomic, never run-spanning at day bands"
                  (let ((d (recipe-process-has-duration rp)))
                    (and (= 8 (duration-has-numerical-value d))
                         (string=? "hours" (duration-has-unit d))))))

    ;; ── the use flow carries BOTH quantities (the two-ovens rule) ───────────
    (let ((bed ($ rs 'get-recipe-flow "rf-shelter-bed")))
      (check-pred "bed use: resource-quantity = 1 each (the count engaged)"
                  (let ((m (recipe-flow-resource-quantity bed)))
                    (and m (= 1 (measure-has-numerical-value m))
                         (string=? "each" (measure-has-unit m)))))
      (check-pred "bed use: effort-quantity = 8 hours (how long it is held)"
                  (let ((m (recipe-flow-effort-quantity bed)))
                    (and m (= 8 (measure-has-numerical-value m))))))

    ;; ── the draw and the capacity are denominated the same way ──────────────
    ;; spec-bed is "each"; the use draw's count is "each": the use-unit-lint
    ;; invariant, held locally where this recipe declares both sides.
    (check-pred "spec-bed capacity unit = the use draw's unit"
                (string=? (resource-specification-default-unit-of-resource
                            ($ rs 'get-resource-spec "spec-bed"))
                          (measure-has-unit
                            (recipe-flow-resource-quantity
                              ($ rs 'get-recipe-flow "rf-shelter-bed")))))

    ;; ── the container claim: cite, non-rival, and the dwelling stays put ────
    (let ((cite ($ rs 'get-recipe-flow "rf-shelter-dwelling")))
      (check-pred "the dwelling is cited, not used — three beds, one flat"
                  (and cite (eq? 'cite (recipe-flow-action cite)))))
    (check-pred "spec-dwelling is keep-in-place (use-in-place made structural)"
                (resource-spec-keep-in-place?
                  ($ rs 'get-resource-spec "spec-dwelling")))

    ;; ── the output is a service: delivered, never inventoried ───────────────
    (let ((out ($ rs 'get-recipe-flow "rf-shelter-out")))
      (check-pred "shelter leaves as deliver-service (unstorable by action)"
                  (and out (eq? 'deliver-service (recipe-flow-action out))))
      (check-pred "…denominated in person-nights, and primary"
                  (and (string=? "person-nights"
                                 (measure-has-unit (recipe-flow-resource-quantity out)))
                       (recipe-flow-is-primary out))))

    ;; ── no work flow: living-in is not labour ───────────────────────────────
    ;; The labour of housing is its reproduction — household.scm and
    ;; the repair recipe — not a flow on the night itself.
    (check-pred "rp-shelter-night has no work flow"
                (not (find (lambda (fid)
                             (eq? 'work (recipe-flow-action ($ rs 'get-recipe-flow fid))))
                           '("rf-shelter-bed" "rf-shelter-dwelling" "rf-shelter-out"))))))

;; ── conservation: shelter is a state, and the ledger says so ────────────────
;; Empty *contains* rows, stated rather than left silent — the same declaration
;; the housework states carry. Nothing here may fall into the unstated debt list.
(display "\n── conservation: shelter is not matter, and it is DECLARED so ──\n")
(for-each
 (lambda (id)
   (check-pred (string-append id " carries an empty composition row (declared non-matter)")
               (and (assoc id *contains*)
                    (null? (assoc-ref *contains* id))))
   (check-pred (string-append id " is not in *composition-unstated* (no silent debt)")
               (not (member id *composition-unstated*))))
 '("spec-shelter" "spec-bed" "spec-dwelling"))

(test-summary!)
