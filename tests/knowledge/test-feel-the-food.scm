;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-feel-the-food.scm — the sensory check, costed; and what the
;;; Chargenvermutung actually assumes.
;;;
;;; Design: `knowledge/feel-the-food.scm`, from the Verbraucherzentrale Berlin's
;;; Leitfaden §8 (vendored at docs/reference/berlin-food/). The inspection model
;;; itself is not new — `vf/formulas/cadence.scm` has carried a*, T* and the
;;; reliance D = φH since the INSPECTION arc, and `conformance-catalogue.scm`
;;; states that one profile "serves skills, instruments, and BATCHES alike".
;;; Batches were the third subject nobody had pointed it at.
;;;
;;; What this proves — stated as what it is, after an earlier draft overclaimed:
;;;   1. a* SATURATES on food. For sight/touch/smell that is the CORRECT answer
;;;      and matches the guide (check every unit, nothing is consumed). For taste
;;;      it is no guidance at all, which is where a sample size arises.
;;;   2. the statutory rule is the ρ = 1 corner. It is a CLAIM THAT ρ = 1, not a
;;;      sample size — and `unpresumed-units` reproduces it by construction, not
;;;      by derivation. The earlier assertion "it agrees by deriving one sample"
;;;      was false and is corrected here.
;;;   3. the direction that needs no invented numbers is the converse:
;;;      `sample->implied-rho` reads any proposed sample back as the homogeneity
;;;      claim it makes. That works on the statute, on a steward's rule, on
;;;      anyone's — without this file asserting which ρ is true.
;;;
;;; Run: guile -L module tests/knowledge/test-feel-the-food.scm

(use-modules (localchimera test harness) (localchimera knowledge recipes store) (localchimera knowledge worlds feel-the-food) (localchimera vf schemas) (srfi srfi-1)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

;;; ─── 1. the statutory rule, as written ───────────────────────────────────
(display "\n── Chargenvermutung, the rule as written ──\n")
(for-each (lambda (n)
            (format #t "  ~4d units → open ~a\n" n (chargenvermutung-sample n)))
          '(1 10 11 100))

(check-pred "at or below 10 units nothing is destroyed to certify anything"
            (and (= 0 (chargenvermutung-sample 10)) (= 0 (chargenvermutung-sample 1))))
(check-pred "above 10, exactly one is opened — whatever n is"
            (and (= 1 (chargenvermutung-sample 11)) (= 1 (chargenvermutung-sample 100000))))
(check-pred "one spoiled sample condemns the batch — the Vermutung itself"
            (chargenvermutung-condemns? #t))
(check-pred "a sound sample does not"
            (not (chargenvermutung-condemns? #f)))

;;; ─── 2. the raw a* saturates : it was built for a non-destructive check ──
(display "\n── the raw a*, pointed at a batch ──\n")
(for-each (lambda (c)
            (format #t "  ~8a n=12 → ~,3f   n=100 → ~,3f\n" c
                    (feel-the-food-rate 12 c) (feel-the-food-rate 100 c)))
          '(high medium low))

(check-pred "a* clamps at 1 for every perishability class"
            (every (lambda (c) (feel-the-food-saturates? 100 c)) '(high medium low)))
(check-pred "which is CORRECT for the senses that consume nothing — look, smell"
            (and (not (sense-destructive? 'sight)) (not (sense-destructive? 'smell))))
(check-pred "and no guidance for the one that does — taste"
            (sense-destructive? 'taste))
(check-pred "so a* contributes nothing to the sample size; ρ alone sets it"
            (= (feel-the-food-sample 100 'high 1.0 'mixed-rescue)
               (feel-the-food-sample 100 'low  1.0 'mixed-rescue)))

;;; ─── 3. the presumption IS the rule ──────────────────────────────────────
;;; Set ρ = 1 — a batch is one object wearing n lids — and the model reproduces
;;; the statute exactly, at every size and every perishability.
(display "\n── ρ = 1 (sealed lot): the count coincides with the statute ──\n")
(define sealed
  (append-map (lambda (n)
                (map (lambda (c) (feel-the-food-verdict n c 1.0 'sealed-lot))
                     '(high medium low)))
              '(12 100 1000)))
(for-each (lambda (v)
            (format #t "  n=~4d ~8a → statutory taste ~a · at ρ=~,2f taste ~a\n"
                    (assq-ref v 'units) (assq-ref v 'class)
                    (assq-ref v 'statutory-taste) (assq-ref v 'at-rho)
                    (assq-ref v 'taste-samples)))
          sealed)

(check-pred "at ρ = 1 the count matches the statute, at every size and class"
            (every (lambda (v) (= (assq-ref v 'statutory-taste)
                                  (assq-ref v 'taste-samples))) sealed))
;; …and it matches BY CONSTRUCTION. ⌈(1−1)·n + 1⌉ = 1 for every n. This is not a
;; derivation of the rule and must not be read as one; it is the rule's own
;; assumption, counted. Asserted here so the tautology is on the record.
(check-pred "the match is definitional — ρ = 1 gives 1 for any n, by arithmetic"
            (every (lambda (n) (= 1 (unpresumed-units n 1.0))) '(2 12 100 1000 100000)))

;;; ─── 4. drop the presumption and the rule stops holding ──────────────────
(display "\n── the same 100 jars, assembled differently ──\n")
(define kinds '(sealed-lot one-shop mixed-rescue unknown))
(define bykind (map (lambda (k) (feel-the-food-verdict 100 'high 1.0 k)) kinds))
(for-each (lambda (v)
            (format #t "  ~12a ρ=~,2f → taste ~3d of 100 · that sample asserts ρ=~,2f\n"
                    (assq-ref v 'batch-kind) (assq-ref v 'at-rho)
                    (assq-ref v 'taste-samples) (assq-ref v 'our-sample-asserts-rho)))
          bykind)

(check-pred "taste sample rises monotonically as the presumption weakens"
            (let ((ds (map (lambda (v) (assq-ref v 'taste-samples)) bykind)))
              (every (lambda (a b) (<= a b)) (drop-right ds 1) (cdr ds))))
;; the converse reading — no claim about which ρ is right, only what each
;; proposal asserts. This is the direction that survives our numbers being wrong.
(check-pred "the statute's one-of-n asserts ρ = 1, whatever n is"
            (every (lambda (n) (= 1.0 (sample->implied-rho n 1))) '(12 100 1000)))
(check-pred "tasting 5 of 100 asserts a high but not total presumption"
            (let ((r (sample->implied-rho 100 5))) (and (> r 0.9) (< r 1.0))))
(check-pred "tasting every unit asserts no presumption at all"
            (= 0.0 (sample->implied-rho 100 100)))
(check-pred "our ρ round-trips through the count and back"
            (let ((v (find (lambda (v) (eq? 'mixed-rescue (assq-ref v 'batch-kind))) bykind)))
              (< (abs (- (assq-ref v 'at-rho) (assq-ref v 'our-sample-asserts-rho))) 0.02)))

;;; ─── 5. the check is a PROCESS, and the sample is a yield loss ───────────
(define vat (spawn-vat))
(define seeded
  (with-vat vat
    (map (lambda (n)
           (let ((rs (empty-recipe-store)))
             (cons n (seed-feel-the-food! rs #:batch (exact->inexact n) #:class 'medium
                                          #:sample (chargenvermutung-sample n)))))
         '(12 100 1000))))

(display "\n── the check as a process: the sample is eaten ──\n")
(for-each (lambda (kv)
            (format #t "  batch ~4d → sample ~a · ~,3f h · yield ~,4f\n"
                    (car kv) (assq-ref (cdr kv) 'sample)
                    (assq-ref (cdr kv) 'hours) (assq-ref (cdr kv) 'yield)))
          seeded)

(check-pred "the yield loss is exactly the units eaten to certify the rest"
            (every (lambda (kv)
                     (let ((n (car kv)) (r (cdr kv)))
                       (< (abs (- (assq-ref r 'yield)
                                  (exact->inexact (/ (- n (assq-ref r 'sample)) n))))
                          1e-9)))
                   seeded))
(check-pred "certainty gets cheaper per unit as the batch grows — the bulk incentive"
            (let ((ys (map (lambda (kv) (assq-ref (cdr kv) 'yield)) seeded)))
              (every (lambda (a b) (< a b)) (drop-right ys 1) (cdr ys))))
(check-pred "the labour is the checks, not the batch"
            (= (assq-ref (cdr (assoc 12 seeded)) 'hours)
               (assq-ref (cdr (assoc 1000 seeded)) 'hours)))

;;; ─── 6. perishability comes off the good's own classifier ────────────────
(define greens
  (make-resource-specification #:id "spec-leafy" #:name "Leafy Greens"
    #:resource-classified-as '("vf:food-class:produce" "vf:temp-class:chilled" "vf:perishability:high")
    #:default-unit-of-resource "kg"))
(define pantry
  (make-resource-specification #:id "spec-dry" #:name "Dry Pantry"
    #:resource-classified-as '("vf:food-class:dry" "vf:perishability:low") #:default-unit-of-resource "kg"))
(define untagged
  (make-resource-specification #:id "spec-x" #:name "Something" #:resource-classified-as '("food")
                               #:default-unit-of-resource "kg"))

(display "\n── κ read off the good, not passed in ──\n")
(format #t "  leafy greens → ~a · dry pantry → ~a · untagged → ~a\n"
        (spec-perishability greens) (spec-perishability pantry)
        (spec-perishability untagged))

(check-pred "the cold-chain classifier already carries the drift"
            (and (eq? 'high (spec-perishability greens))
                 (eq? 'low  (spec-perishability pantry))))
(check-pred "an untagged good defaults to the middle, not the cheapest"
            (eq? 'medium (spec-perishability untagged)))
(check-pred "taste is the destructive sense; looking and smelling are not"
            (and (sense-destructive? 'taste)
                 (not (sense-destructive? 'sight))
                 (not (sense-destructive? 'smell))))
(check-pred "the Leitfaden's criteria are carried per sense"
            (memq 'schimmel (sense-criteria 'sight)))

(display "\n")
(test-summary!)
