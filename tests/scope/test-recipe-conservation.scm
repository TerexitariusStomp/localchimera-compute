;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-recipe-conservation.scm — the keystone invariant, over the real recipes.
;;;
;;; `check-conservation` (knowledge/catalogues/substances.scm) is described in its own source
;;; as "the keystone invariant": every tracked ELEMENT an internal transformation
;;; consumes must reappear in its outputs. Molecules form and break freely — CO₂'s
;;; carbon is the fuel's carbon — and a loss is not an exemption but a named output,
;;; so a lossy recipe balances by routing its loss somewhere explicit. That is the
;;; whole point: matter cannot silently vanish, and the rift has to be WRITTEN.
;;;
;;; It was exported and unit-tested against hand-written flow lists, and never run
;;; over the recipes in the store. A check nobody applies is a silence, not a green —
;;; the same failure `test-use-unit-lint` had when it guarded one live spec. This is
;;; the sweep.
;;;
;;; ── why DECLARED composition, and not derived ────────────────────────────────
;;; `derive-contains` and `check-conservation` read the SAME residual: derive
;;; ATTRIBUTES consumed−produced to the primary product, check FLAGS it. So a
;;; recipe checked against its own derived composition balances by construction —
;;; the residual has already been defined as the product's content, and the test
;;; would be circular.
;;;
;;; The non-circular question is against DECLARED composition (`*contains*`), where
;;; the two sides are stated independently: a recipe drawing 100 kg of nitrogen and
;;; producing something whose declared composition holds 70 has lost 30 that nobody
;;; wrote down, and that is a finding about the recipe rather than a definition of
;;; its output.
;;;
;;; ── what is exempt, and why ──────────────────────────────────────────────────
;;; A BOUNDARY process crosses the system edge: fixation and extraction bring matter
;;; in, emission lets it out. Conservation is a claim about an INTERNAL
;;; transformation, so a process with substance on only one side is not judged — it
;;; is where the accounting starts or stops, and the rift is measured by the drift of
;;; the environment stocks it touches, not by this check.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module tests/scope/test-recipe-conservation.scm

(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet knowledge catalogues substances))
(use-modules (goblins) (srfi srfi-1) (srfi srfi-13) (ice-9 format))
(use-modules ((playnet knowledge dsl vf-lint) #:select (recipe-seeders)))

;;; EVERY seeder knowledge/recipes/ exports, DISCOVERED rather than listed. A hand-written
;;; list is a second place to keep true, and it was wrong: it named 43 and matched 27,
;;; so half the recipe tree went unswept — and `spec-sp-regrind` read as "never
;;; produced" only because `seed-stone-paper-reclaim-recipe` was missing from it, which
;;; would have had this file authoring a composition for a spec a recipe already
;;; derives. The tree is the registry (tools/test/run-scm-tests.sh keeps the same rule for
;;; test files: "a test can never rot by being forgotten").
;;;
;;; A seeder wanting something other than a recipe store (a scope, an observer, more
;;; arguments) refuses the call and is skipped: this is a sweep, and the count it
;;; reports is what it reached. A seed module that fails to load is another
;;; matter, and that fails here by name: skipped in silence, its recipes would
;;; leave the sweep and read as a list gone stale.
(define-values (%seeder-table %unloaded) (recipe-seeders))
(define %seeders (map car %seeder-table))
(check "every seed module of knowledge/recipes/ loads" %unloaded '())

(define vat (spawn-vat #:name "recipe-conservation"))
(define root (with-vat vat (spawn-scope-root "conservation")))
(define rs (with-vat vat ($ root 'recipe-store)))

(define ran
  (with-vat vat
    (filter-map
     (lambda (p)
       (false-if-exception (begin ((cdr p) rs) (car p))))
     %seeder-table)))
(format #t "\n── ~a of ~a recipe seeders ran ──\n" (length ran) (length %seeders))

;;; A process's substance flows, in `check-conservation`'s own shape.
(define (substance-flows io) (balance-flows io #:basis? #f))

(define processes
  (with-vat vat
    (append-map
     (lambda (r)
       (map (lambda (rp)
              (let ((io ($ rs 'flows-for-process (recipe-process-id rp))))
                (cons (recipe-process-id rp)
                      (substance-flows (append (car io) (cdr io))))))
            ($ rs 'get-process-chain (recipe-id r))))
     ($ rs 'all-recipes))))

(define internal
  (filter (lambda (p) (and (pair? (cdr p)) (not (boundary-process? (cdr p))))) processes))

;;; A CONSISTENCY CHECK asks the second of the two questions in catalogues/substances.scm: which
;;; declared rows are live CLAIMS. It is not handed derived values, because a derived
;;; composition is defined AS the residual being tested — feeding it back makes the
;;; check circular and it passes by construction. So derivable specs are UNKNOWNS the
;;; system solves for, and the claims are the declared rows about everything else.
(define derivable
  (delete-duplicates
   (filter-map (lambda (f) (and (eq? 'produce (flow-action f)) (flow-spec f)))
               (append-map cdr internal))))
(define live-contains (composition-claims *contains* derivable))
(define superseded (composition-superseded *contains* derivable))

(define report (composition-system internal #:contains live-contains))
(define determined (assq-ref report 'determined))
(define free (assq-ref report 'free))
(define contradictions (assq-ref report 'contradictions))

(format #t "  ~a processes · ~a internal transformations solved together\n"
        (length processes) (length internal))
(format #t "  ~a composition values FORCED by the recipes · ~a left free\n"
        (length determined) (length free))
(for-each
 (lambda (c)
   (format #t "  CONTRADICTION on ~a~a: residual ~,4f — inconsistent set ~a\n"
           (assq-ref c 'element)
           (let ((sp (assq-ref c 'spec))) (if sp (format #f " (~a would have to hold ~,4f)" sp (assq-ref c 'value)) ""))
           (assq-ref c 'residual)
           (string-join (assq-ref c 'processes) ", ")))
 contradictions)

(check-pred "the recipes and the declared compositions are consistent together"
            (null? contradictions))

;;; COVERAGE IS PART OF THE VERDICT, and now it is exact rather than heuristic: the
;;; rank says which compositions the recipes FORCE and which are free. A sweep that
;;; determined nothing would pass and mean nothing — the failure this file ends.
(check-pred "…and the system actually determined some compositions"
            (> (length determined) 0))

;;; ── the four verdicts, exercised ─────────────────────────────────────────────
;;; A check that cannot fire is a silence. These are the shapes it is for, and the
;;; last two are why a global solve needs a certificate at all.
(define (nitrogen procs) (composition-system procs #:tracked '("N")))
(define (blame r) (map (lambda (c) (assq-ref c 'processes)) (assq-ref r 'contradictions)))

(define p-good (list "p-good" (bare-flow 'consume "soil-n" 2.6) (bare-flow 'produce "food" 100.0)))
(define p-bad  (list "p-bad"  (bare-flow 'consume "soil-n" 5.0) (bare-flow 'produce "food" 100.0)))
(define p-mkX  (list "p-mkX"  (bare-flow 'consume "soil-n" 5.0) (bare-flow 'produce "X" 100.0)))
(define p-useX (list "p-useX" (bare-flow 'consume "X" 100.0)    (bare-flow 'produce "food" 100.0)))

(check-pred "a balanced transformation raises nothing"
            (null? (assq-ref (nitrogen (list p-good)) 'contradictions)))
(check-pred "an unbalanced one is reported, and blamed alone"
            (equal? '(("p-bad")) (blame (nitrogen (list p-bad)))))
(check-pred "…and an innocent process beside it is not implicated"
            (equal? '(("p-bad")) (blame (nitrogen (list p-good p-bad)))))

;;; UNDER-DETERMINED: one recipe defining an unstated product cannot contradict
;;; anything, and the system says so by determining it rather than passing quietly.
(check-pred "a spec only one recipe makes is DETERMINED, not checked"
            (let ((r (nitrogen (list p-mkX))))
              (and (null? (assq-ref r 'contradictions))
                   (equal? '(("X" "N" 0.05)) (assq-ref r 'determined)))))

;;; THE CERTIFICATE'S REASON FOR EXISTING: neither of these is wrong on its own —
;;; the first merely defines X — and together they contradict the declared food row.
;;; A per-recipe check finds nothing here; a global solve without a certificate would
;;; blame everything. The inconsistent set names exactly the two.
(check-pred "a JOINT inconsistency names both recipes and neither alone"
            (equal? '(("p-mkX" "p-useX")) (blame (nitrogen (list p-mkX p-useX)))))
(check-pred "…still exactly those two when an unrelated process is present"
            (member '("p-mkX" "p-useX") (blame (nitrogen (list p-mkX p-useX p-good)))))

;;; A composition the system can only satisfy by going NEGATIVE is a contradiction
;;; about the world rather than about the matrix — and the finding names the spec that
;;; was made to absorb it.
(check-pred "a value forced negative is reported against its own spec"
            ;; outputs carry MORE nitrogen than the draw, so the only unknown left
            ;; has to hold a negative amount for the algebra to close
            (let* ((r (nitrogen (list (list "p-sink" (bare-flow 'consume "soil-n" 1.0)
                                            (bare-flow 'produce "food" 100.0) (bare-flow 'produce "W" 50.0)))))
                   (c (assq-ref r 'contradictions)))
              (and (pair? c) (equal? "W" (assq-ref (car c) 'spec))
                   (< (assq-ref (car c) 'value) 0))))



;;; ════════════════════════════════════════════════════════════════════════════
;;; THE RIFT AS A PULL — the environment stocks, felt before they are gone
;;; ════════════════════════════════════════════════════════════════════════════
;;; Planetary drift is already a barrier: eco-catalogue.scm carries the nitrogen and
;;; phosphorus fluxes as per-period fragilities and co2 as a budget coupled to warming
;;; and ocean acidification. A LOCAL stock had a plain bar instead — soil nitrogen at a
;;; farm could be drawn to its last kilogram, because a bar is only felt when reached.
;;;
;;; `environment-stock-frag` names which stocks deserve the fragility treatment, in
;;; the `(spec . weight)` shape `#:stock-frag` and `migrated->stock-frag` already
;;; speak. It adds no channel: the good's own `≥ 0` balance is carried at a fixed
;;; governance weight instead of the swept one, and the wall/level parity that makes
;;; that sound is proven in test-representation-parity.scm.
(display "\n── the rift as a pull ──\n")

(define scope-specs '("soil-n" "soil-p" "soil-k" "carrot" "crop-runoff" "co2" "spec-biomass"))
(define rift-frag (environment-stock-frag scope-specs))

(check-pred "the environment stocks are selected, and only those"
            (equal? '("co2" "crop-runoff" "soil-k" "soil-n" "soil-p")
                    (sort (map car rift-frag) string<?)))
(check-pred "…a product is not an environment stock — carrots cycle freely"
            (not (assoc "carrot" rift-frag)))
(check-pred "…nor is a feedstock the economy holds"
            (not (assoc "spec-biomass" rift-frag)))
(check-pred "each carries a weight, so the balance is felt rather than merely hit"
            (every (lambda (p) (> (cdr p) 0.0)) rift-frag))
(check-pred "the default matches the planetary biogeochemical boundaries (5.0)"
            (= 5.0 %environment-frag-weight))
(check-pred "…and a scope may say otherwise — it is a governance number"
            (equal? '(("soil-n" . 9.0)) (environment-stock-frag '("soil-n") #:weight 9.0)))

;;; ── COMPLETENESS is the precondition for element closure ─────────────────────
;;; Closure reads an unstated composition as ZERO, so a spec that really carries an
;;; element while saying nothing makes its consumers look as though they conjure
;;; matter — the constraint would refuse a good recipe. `composition-gaps` is that
;;; list, and it must be empty before closure can be trusted in a live scope.
(display "\n── the identities are complete ──\n")

;;; The debt is DATA and lives with the data (`*composition-unstated*`, catalogues/substances.scm).
;;; What a test does with it is GUARD it — failing when the sweep and the list disagree
;;; in either direction, so a newly-authored substance turns red and a newly-composed one
;;; does not quietly stay on the list.
(let* ((gaps (composition-gaps processes))
       (new  (filter (lambda (g) (not (member g *composition-unstated*))) gaps))
       (stale (filter (lambda (u) (not (member u gaps))) *composition-unstated*)))
  (for-each (lambda (g) (format #t "  outstanding: ~a carries no stated composition\n" g))
            (sort gaps string<?))
  (check-pred "every spec with an unstated composition is a KNOWN gap, named"
              (null? new))
  (check-pred "…and nothing on the list has quietly gained one"
              (null? stale))
  ;; the two halves partition the declared table: every row is a claim or superseded
  (check-pred "…and every declared row is either a live claim or a named fallback"
              (= (length *contains*) (+ (length live-contains) (length superseded)))))
(check-pred "the planetary fluxes carry their identity — they ARE the atom"
            (and (composition-known? "nitrogen") (composition-known? "phosphorus")))
(check-pred "…while a driven STATE carries none: °C and Ω are not substances"
            (and (not (composition-known? "warming"))
                 (not (composition-known? "ocean-acidification"))))

(test-summary!)
