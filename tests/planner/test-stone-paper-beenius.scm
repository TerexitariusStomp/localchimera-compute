;;; test-stone-paper-beenius.scm — the two new library recipes seed and chain
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/planner/test-stone-paper-beenius.scm
;;;
;;; Both recipes are about a loop, so both are checked at the loop: stone paper's
;;; trim regrind re-enters compounding, and Beenius's recovered wax re-enters as
;;; the very block the build draws on.

(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes store) (playnet knowledge recipes beenius-wax) (playnet knowledge recipes stone-paper) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet doors service))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(display "\n── Setup: stone paper + Beenius infinity wax ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Recipe Library Test"))
    store))

;; flow readers come from the planner (knowledge/recipes/store.scm) — process-inputs /
;; process-outputs / find-flow. What stays local is this file's own question:
;; how much of a spec a flow carries.
(define (has-spec? fs spec) (and (find-flow fs spec) #t))
(define (qty fs spec action)
  (and=> (find-flow fs spec #:action action)
         (lambda (f) (measure-has-numerical-value (recipe-flow-resource-quantity f)))))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-stone-paper-specs rs)
    (seed-stone-paper-recipe rs)
    (seed-stone-paper-reclaim-recipe rs)
    (seed-stone-paper-bio-recipe rs)
    (seed-stone-paper-compost-recipe rs)
    (seed-beenius-journey rs)

    (display "\n── Stone paper ──\n")
    (check-pred "stone paper seeds as a 5-step chain"
                (= 5 (length ($ rs 'get-process-chain "recipe-stone-paper"))))
    (check-pred "primary output is stone paper"
                (string=? "spec-stone-paper"
                          (recipe-primary-output ($ rs 'get-recipe "recipe-stone-paper"))))
    (check-pred "the mineral is the bulk of the compound (800 kg CaCO₃ : 130 kg HDPE)"
                (and (= 800 (qty (process-inputs rs "rp-sp-compound") "spec-sp-caco3-powder" 'consume))
                     (= 130 (qty (process-inputs rs "rp-sp-compound") "spec-sp-hdpe" 'consume))))
    (check-pred "no process water and no bleach anywhere in the chain"
                (not (any (lambda (pid)
                            (any (lambda (f)
                                   (member (recipe-flow-resource-conforms-to f)
                                           '("spec-water" "spec-sp-water" "spec-sp-bleach")))
                                 (process-inputs rs pid)))
                          '("rp-sp-crush" "rp-sp-grind" "rp-sp-compound"
                            "rp-sp-extrude" "rp-sp-finish"))))
    (check-pred "edge trim from finishing is granulated back into compounder feed"
                (and (has-spec? (process-outputs rs "rp-sp-finish") "spec-sp-trim")
                     (has-spec? (process-inputs rs "rp-sp-trim-grind") "spec-sp-trim")
                     (has-spec? (process-outputs rs "rp-sp-trim-grind") "spec-sp-regrind")
                     (has-spec? (process-inputs rs "rp-sp-compound") "spec-sp-regrind")))
    (check-pred "used sheet reclaims onto that same regrind spec"
                (and (has-spec? (process-inputs rs "rp-sp-reclaim") "spec-stone-paper")
                     (has-spec? (process-outputs rs "rp-sp-reclaim") "spec-sp-regrind")))
    (check-pred "the reclamation recipe orders as a 2-step chain"
                (= 2 (length ($ rs 'get-process-chain "recipe-stone-paper-reclaim"))))

    (display "\n── Stone paper, bio grade ──\n")
    (check-pred "the bio grade is a 5-step chain onto its own sheet spec"
                (and (= 5 (length ($ rs 'get-process-chain "recipe-stone-paper-bio")))
                     (string=? "spec-stone-paper-bio"
                               (recipe-primary-output ($ rs 'get-recipe "recipe-stone-paper-bio")))))
    (check-pred "grades share the mineral half: crush and grind are the SAME processes"
                (let ((hdpe (recipe-recipe-processes ($ rs 'get-recipe "recipe-stone-paper")))
                      (bio  (recipe-recipe-processes ($ rs 'get-recipe "recipe-stone-paper-bio"))))
                  (and (equal? (list-head hdpe 2) '("rp-sp-crush" "rp-sp-grind"))
                       (equal? (list-head bio  2) '("rp-sp-crush" "rp-sp-grind")))))
    (check-pred "the fork is a ratio, at the compounder: 65 / 33 / 2"
                (and (= 650 (qty (process-inputs rs "rp-spb-compound") "spec-sp-caco3-powder" 'consume))
                     (= 330 (qty (process-inputs rs "rp-spb-compound") "spec-sp-biopolymer" 'consume))
                     (= 20  (qty (process-inputs rs "rp-spb-compound") "spec-sp-additive" 'consume))))
    (check-pred "the binder slot takes whatever polyester a region can get"
                (resource-specification-substitutable
                  ($ rs 'get-resource-spec "spec-sp-biopolymer")))
    (check-pred "the bio grade draws NO regrind — it is chosen out of a compounder's reach"
                (not (has-spec? (process-inputs rs "rp-spb-compound") "spec-sp-regrind")))
    (check-pred "both grades run on the same compounder, extruder, stretcher, converter"
                (every (lambda (pair)
                         (has-spec? (process-inputs rs (car pair)) (cdr pair)))
                       '(("rp-spb-compound" . "spec-sp-compounder")
                         ("rp-spb-extrude"  . "spec-sp-extruder")
                         ("rp-spb-extrude"  . "spec-sp-stretcher")
                         ("rp-spb-finish"   . "spec-sp-converter"))))
    (check-pred "composting hands back the 650 kg that was mineral all along"
                (and (has-spec? (process-inputs rs "rp-sp-compost") "spec-stone-paper-bio")
                     (= 650 (qty (process-outputs rs "rp-sp-compost") "spec-sp-mineral-residue" 'produce))))
    (check-pred "the two end-of-lives are RIVALS: each takes one grade, onto its own output"
                (and (has-spec? (process-inputs rs "rp-sp-reclaim") "spec-stone-paper")
                     (not (has-spec? (process-inputs rs "rp-sp-reclaim") "spec-stone-paper-bio"))
                     (has-spec? (process-inputs rs "rp-sp-compost") "spec-stone-paper-bio")
                     (not (has-spec? (process-inputs rs "rp-sp-compost") "spec-stone-paper"))))
    (check-pred "bio trim windrows down the same path its sheet does"
                (and (has-spec? (process-outputs rs "rp-spb-finish") "spec-sp-bio-trim")
                     (has-spec? (process-inputs rs "rp-spb-trim-compost") "spec-sp-bio-trim")
                     (has-spec? (process-outputs rs "rp-spb-trim-compost") "spec-sp-mineral-residue")))

    (display "\n── Beenius infinity wax ──\n")
    (check-pred "the wax arm seeds as a 5-step chain"
                (= 5 (length ($ rs 'get-process-chain "recipe-beenius-wax"))))
    (check-pred "the Berlin blend weighs 500 + 30 + 20 + 60 = 610 g into the block"
                (and (= 500 (qty (process-inputs rs "rp-bn-blend") "spec-bn-beeswax" 'consume))
                     (= 30  (qty (process-inputs rs "rp-bn-melt-base") "spec-bn-lanolin" 'consume))
                     (= 20  (qty (process-inputs rs "rp-bn-melt-base") "spec-bn-colophony" 'consume))
                     (= 60  (qty (process-inputs rs "rp-bn-kaolin") "spec-bn-kaolin" 'consume))
                     (= 610 (qty (process-outputs rs "rp-bn-cast") "spec-bn-wax-block" 'produce))))
    ;; The build CONSUMES both, and the structure embodies them: while it stands the
    ;; wax is IN it, not beside it. Read as merely occupied, the wax never entered —
    ;; and the element ledger said so, solving the structure to 0.0000 carbon while
    ;; 580 g of 73%-carbon wax came out of it, the whole seven-process loop reducing
    ;; to one contradiction. Coming apart again is rp-bn-recover, and the cycle is
    ;; the two processes together.
    (check-pred "building CONSUMES block and sticks — the structure embodies them"
                (and (= 610 (qty (process-inputs rs "rp-bn-build") "spec-bn-wax-block" 'consume))
                     (= 1   (qty (process-inputs rs "rp-bn-build") "spec-bn-stick-set" 'consume))))
    (check-pred "build and recovery are separate recipes over the same specs"
                (and (= 1 (length ($ rs 'get-process-chain "recipe-beenius-kit")))
                     (= 1 (length ($ rs 'get-process-chain "recipe-beenius-recover")))))
    (check-pred "disassembly returns the sticks whole and the wax as recovered"
                (and (has-spec? (process-outputs rs "rp-bn-recover") "spec-bn-stick-set")
                     (= 580 (qty (process-outputs rs "rp-bn-recover") "spec-bn-recovered-wax" 'produce))))
    ;; 610 g in against 580 g out, with the difference NAMED — a loss is an output or
    ;; it is matter the books cannot follow. It is the same 30 g the remelt buys back
    ;; as virgin beeswax, which is why the loop closes.
    (check-pred "…and names the 30 g handling loss rather than dropping it"
                (= 30 (qty (process-outputs rs "rp-bn-recover")
                           "spec-bn-wax-handling-loss" 'produce)))
    (check-pred "the remelt closes the loop onto the same block spec"
                (and (= 580 (qty (process-inputs rs "rp-bn-remelt") "spec-bn-recovered-wax" 'consume))
                     (= 610 (qty (process-outputs rs "rp-bn-remelt") "spec-bn-wax-block" 'produce))))
    (check-pred "a second block costs 30 g of virgin beeswax, not 500"
                (= 30 (qty (process-inputs rs "rp-bn-remelt") "spec-bn-beeswax" 'consume)))
    (check-pred "every ingredient is marked substitutable for a local stand-in"
                (every (lambda (id)
                         (resource-specification-substitutable ($ rs 'get-resource-spec id)))
                       '("spec-bn-beeswax" "spec-bn-lanolin"
                         "spec-bn-colophony" "spec-bn-kaolin")))))

(test-summary!)
