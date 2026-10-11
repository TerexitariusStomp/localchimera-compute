;;; test-humisoil-recipe.scm — HumiSoil 3-step recipe smoke test
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/doors/test-humisoil-recipe.scm

(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes humisoil) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet doors service) (playnet doors plan-wire))
(use-modules (playnet knowledge catalogues substances))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(display "\n── Setup: HumiSoil ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "HumiSoil Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (seed-humisoil-specs rs)
    (seed-humisoil-recipe rs)

    (check-pred "humisoil recipe seeded as 3-step chain"
                (= 3 (length ($ rs 'get-process-chain "recipe-humisoil"))))

    (check-pred "humisoil primary output is HumiSoil spec"
                (string=? "spec-humisoil"
                          (recipe-primary-output
                            ($ rs 'get-recipe "recipe-humisoil"))))))

;;; ── composition DERIVES through the 3-step chain (no typed HumiSoil row) ─────
;; Only the biomass feedstock is authored (catalogues/substances.scm). prepped → windrow →
;; HumiSoil all derive, the matter wire chaining the fixpoint. The keystone: the
;; carbon (and N/P/K) in the finished HumiSoil EQUALS what entered as biomass —
;; the recipe loses water, not nutrients (its own "near-zero emissions" claim),
;; so the loop closes. 1000 kg biomass × 0.25 C = 250 kg C, ending in HumiSoil.
(define (~= a b) (and a b (< (abs (- a b)) 1e-3)))
(define humisoil-solve
  `((material .
     (((action . consume) (conforms-to . "spec-biomass")  (quantity . 1000) (output-of . #f)          (input-of . "rp-prep"))
      ((action . produce) (conforms-to . "spec-humisoil") (quantity . 1200) (output-of . "rp-ferment") (input-of . #f))))))
(define hw (with-vat vat (matter-results->wire scope humisoil-solve)))
(define hlinks (assq-ref hw 'links))
(define (hlink from to) (find (lambda (l) (and (equal? (assq-ref l 'from) from)
                                              (equal? (assq-ref l 'to) to))) hlinks))
(define (lel l e) (and l (or (assq-ref (assq-ref l 'flows) e) 0)))

(display "\n── HumiSoil composition derives through the chain (carbon loop closes) ──\n")
(check-pred "wire produced" (and hw #t))
(check-pred "carbon in HumiSoil = carbon in biomass (1000×0.25 = 250 kg), conserved"
            (~= (lel (hlink "rp-ferment" "res:spec-humisoil") 'C) 250))
(check-pred "nitrogen likewise conserved into HumiSoil (1000×0.010 = 10 kg)"
            (~= (lel (hlink "rp-ferment" "res:spec-humisoil") 'N) 10))
(check-pred "phosphorus conserved into HumiSoil (1000×0.002 = 2 kg)"
            (~= (lel (hlink "rp-ferment" "res:spec-humisoil") 'P) 2))
(check-pred "potassium conserved into HumiSoil (1000×0.006 = 6 kg)"
            (~= (lel (hlink "rp-ferment" "res:spec-humisoil") 'K) 6))

(test-summary!)
