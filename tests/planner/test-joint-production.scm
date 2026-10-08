;;; test-joint-production.scm — one labour cost, several outputs.
;;;
;;; Spec: docs/social-category.typ §4 (sub-additivity is where joint production
;;;       lives: ℓ̂(A ⊗ B) ≤ ℓ̂(A) + ℓ̂(B), and the slack IS the by-product) +
;;;       §8 Obligation 5; docs/planning/solve/planner-open-questions.md §3, option (3).
;;;
;;; A recipe that yields wool AND mutton has ONE cost and two outputs. Charging
;;; the whole of it to a declared primary output leaves the co-product riding
;;; free; charging the whole of it to EACH counts the labour twice. Neither is
;;; the labour actually congealed in a fleece.
;;;
;;; `crystallized-snlt-for-spec` now finds producers by NET OUTPUT and splits a
;;; multi-output recipe's gross effort by RELATIVE STANDALONE SNLT — each output's
;;; share in proportion to (qty × what it would cost to make on its own).
;;;
;;; The two properties that matter:
;;;   CONSERVATION — the shares sum back to the joint total. No labour created,
;;;                  none destroyed.
;;;   NO REGRESSION — a recipe with a single net output prices EXACTLY as before,
;;;                  so this is a strict extension and only joint recipes move.
;;;
;;; Fixture:
;;;   shear:    1 sheep + 2h        → 3 wool                 (standalone wool)
;;;   butcher:  1 sheep + 6h        → 10 mutton              (standalone mutton)
;;;   raise:    1 lamb  + `joint-hours`  → `wool-qty` wool + `mutton-qty` mutton
;;;             — cheaper than shearing and butchering separately (8h), which is
;;;               exactly what makes the bundle sub-additive: the slack is the by-product.
;;;   bake:     1 flour + 2h        → 1 bread                (single-output control)
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-joint-production.scm

(use-modules (playnet test harness))
(use-modules (playnet planner algorithms rollup) (playnet planner algorithms rollup common) (playnet planner algorithms rollup relative-snlt) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 format))

;; the joint recipe, named once and referred to thereafter
(define joint-hours 6.0)     ; work in `raise`
(define wool-qty    3.0)     ; wool it yields
(define mutton-qty 10.0)     ; mutton it yields

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 1e-9)))
    (< (abs (- a b)) tol)))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "joint-production")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))

    (define (spec id unit)
      ($ rs 'add-resource-spec
         (make-resource-specification #:id id #:name id #:default-unit-of-resource unit)))
    (for-each (lambda (s) (spec (car s) (cdr s)))
              '(("sheep" . "each") ("lamb" . "each") ("wool" . "kg")
                ("mutton" . "kg")  ("flour" . "kg")  ("bread" . "loaf")))

    (define (proc pid)
      ($ rs 'add-process-spec
         (make-process-specification #:id (string-append "ps-" pid) #:name pid))
      ($ rs 'add-recipe-process
         (make-recipe-process #:id pid #:name pid #:process-conforms-to (string-append "ps-" pid)
                              #:has-duration (make-duration 1 "hour"))))
    (for-each proc '("rp-shear" "rp-butcher" "rp-raise" "rp-bake"))

    (define (fl id action spec qty unit inp outp)
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id id #:action action #:resource-conforms-to spec
                           #:resource-quantity (and qty (make-measure qty unit))
                           #:recipe-input-of inp #:recipe-output-of outp)))
    (define (wk id h inp)
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id id #:action 'work #:effort-quantity (make-measure h "hour")
                           #:recipe-input-of inp)))

    ;; standalone wool: 1 sheep + 2h → 3 wool
    (fl "s1" 'consume "sheep" 1.0 "each" "rp-shear" #f) (wk "s2" 2.0 "rp-shear")
    (fl "s3" 'produce "wool" 3.0 "kg" #f "rp-shear")
    ;; standalone mutton: 1 sheep + 6h → 10 mutton
    (fl "b1" 'consume "sheep" 1.0 "each" "rp-butcher" #f) (wk "b2" 6.0 "rp-butcher")
    (fl "b3" 'produce "mutton" 10.0 "kg" #f "rp-butcher")
    ;; JOINT: 1 lamb + joint-hours → wool-qty wool + mutton-qty mutton
    (fl "r1" 'consume "lamb" 1.0 "each" "rp-raise" #f) (wk "r2" joint-hours "rp-raise")
    (fl "r3" 'produce "wool" wool-qty "kg" #f "rp-raise")
    (fl "r4" 'produce "mutton" mutton-qty "kg" #f "rp-raise")
    ;; single-output control: 1 flour + 2h → 1 bread
    (fl "k1" 'consume "flour" 1.0 "kg" "rp-bake" #f) (wk "k2" 2.0 "rp-bake")
    (fl "k3" 'produce "bread" 1.0 "loaf" #f "rp-bake")

    ($ rs 'add-recipe (make-recipe #:id "r-shear"   #:name "shear" #:primary-output "wool"  
                                   #:recipe-processes '("rp-shear")   #:recipe-exchanges '()))
    ($ rs 'add-recipe (make-recipe #:id "r-butcher" #:name "butcher" #:primary-output "mutton"
                                   #:recipe-processes '("rp-butcher") #:recipe-exchanges '()))
    ($ rs 'add-recipe (make-recipe #:id "r-raise"   #:name "raise" #:primary-output "wool"  
                                   #:recipe-processes '("rp-raise")   #:recipe-exchanges '()))
    ($ rs 'add-recipe (make-recipe #:id "r-bake"    #:name "bake" #:primary-output "bread" 
                                   #:recipe-processes '("rp-bake")    #:recipe-exchanges '()))

    ;; ── the joint recipe is seen as joint ────────────────────────────────────
    (display "\n── the joint recipe delivers two goods ──\n")
    (let ((nout (recipe-net-outputs rs "r-raise")))
      (format #t "  net outputs of `raise`: ~a\n" nout)
      (check "the joint recipe has two net outputs" (= (length nout) 2))
      (check "wool is one of them"   (assoc "wool" nout))
      (check "mutton is the other"   (assoc "mutton" nout)))

    ;; ── conservation: the split sums to the joint total ──────────────────────
    (display "\n── the split conserves the joint labour ──\n")
    (let* ((split (rollup-relative-snlt rs "r-raise"))
           (E     (assq-ref split 'total-effort))
           (outs  (assq-ref split 'outputs))
           (sum-e (fold (lambda (o a) (+ a (assq-ref o 'effort))) 0.0 outs)))
      (format #t "  gross effort E = ~,4f h\n" E)
      (for-each (lambda (o)
                  (format #t "    ~8a qty ~5,1f  effort ~7,4f h  → ~,4f h/unit  (anchored: ~a)\n"
                          (assq-ref o 'spec) (assq-ref o 'qty) (assq-ref o 'effort)
                          (assq-ref o 'snlt) (assq-ref o 'anchored?)))
                outs)
      (check "Σ shares = the joint total — no labour created or destroyed"
             (approx= sum-e E 1e-6))
      (check "every share is non-negative"
             (every (lambda (o) (>= (assq-ref o 'effort) 0.0)) outs))
      (check "both co-products found a standalone anchor"
             (every (lambda (o) (assq-ref o 'anchored?)) outs)))

    ;; ── neither co-product rides free, neither carries the whole ─────────────
    (display "\n── neither rides free, neither carries the whole ──\n")
    (let ((w (crystallized-snlt-for-spec rs "wool"))
          (m (crystallized-snlt-for-spec rs "mutton")))
      (format #t "  cryst(wool)   = ~,4f h/kg\n" w)
      (format #t "  cryst(mutton) = ~,4f h/kg\n" m)
      (check "wool is priceable"   (and (number? w) (< w +inf.0)))
      (check "mutton is priceable — it does not ride free"
             (and (number? m) (< m +inf.0) (> m 0.0)))
      ;; Against the FIXTURE's own numbers, not copies of them. A literal here is
      ;; the recipe written down a second time, and the two drift — this comment
      ;; said "the WHOLE 20h" long after the fixture had moved to 6.
      (check "wool is not charged the whole joint cost"
             (< (* wool-qty w) joint-hours))
      (check "mutton is not charged the whole joint cost"
             (< (* mutton-qty m) joint-hours)))

    ;; ── sub-additivity: the bundle costs less than the parts ─────────────────
    ;; ℓ̂(wool ⊗ mutton) ≤ ℓ̂(wool) + ℓ̂(mutton), and the SLACK is the by-product.
    (display "\n── sub-additivity: joint beats separate ──\n")
    (let* ((wool-alone   (standalone-snlt-for-spec rs "wool"   #:exclude "r-raise"))
           (mutton-alone (standalone-snlt-for-spec rs "mutton" #:exclude "r-raise"))
           (separate (+ (* wool-qty wool-alone) (* mutton-qty mutton-alone)))
           (joint    (recipe-gross-effort rs "r-raise")))
      (format #t "  3 wool + 10 mutton, made separately: ~,4f h\n" separate)
      (format #t "  the same bundle, made jointly:       ~,4f h\n" joint)
      (format #t "  slack (the by-product):              ~,4f h\n" (- separate joint))
      (check "the joint bundle costs no more than the parts" (<= joint (+ separate 1e-9)))
      (check "and strictly less — there IS a by-product here" (< joint separate)))

    ;; ── NO REGRESSION: single-output recipes price exactly as before ─────────
    ;; The split hands a sole net output the whole effort, which is what dividing
    ;; by its quantity already did. Checked against the arithmetic directly.
    (display "\n── single-output recipes are untouched ──\n")
    (let ((bread (crystallized-snlt-for-spec rs "bread"))
          (flour (crystallized-snlt-for-spec rs "flour")))
      (format #t "  cryst(flour) = ~a   cryst(bread) = ~,4f\n" flour bread)
      ;; flour has no recipe ⇒ unpriceable ⇒ contributes 0; bread = its own 2h
      (check "bread prices at its direct 2h — unchanged by the joint machinery"
             (approx= bread 2.0 1e-9))
      (check "a spec with no recipe is +inf, not 0" (= flour +inf.0)))

    ;; ── the unpriceable-input convention ────────────────────────────────────
    ;; `lamb` is a raw: no recipe produces it, so as an OUTPUT it is +inf.0
    ;; (unreachable) and as an INPUT it must contribute NOTHING. The joint recipe
    ;; above consumes exactly such a raw. If the convention leaked — if +inf.0
    ;; multiplied through recipe-gross-effort instead of being read as 0 — the
    ;; whole recipe would price +inf.0, the joint route would drop out of the min
    ;; in crystallized-snlt-for-spec, and BOTH co-products would fall back to
    ;; their standalone prices with the by-product riding free. That failure is
    ;; invisible from the outside: it looks exactly like the split not being
    ;; wired at all. These checks are what tell the two apart.
    (display "\n── a raw input contributes nothing, and does not poison the recipe ──\n")
    (let ((lamb  (crystallized-snlt-for-spec rs "lamb"))
          (gross (recipe-gross-effort rs "r-raise"))
          (w     (crystallized-snlt-for-spec rs "wool"))
          (m     (crystallized-snlt-for-spec rs "mutton")))
      (format #t "  cryst(lamb)  = ~a   ← a raw, unreachable as an output\n" lamb)
      (format #t "  gross(raise) = ~,4f h  ← finite despite consuming it\n" gross)
      (check "a raw is +inf.0 as an OUTPUT — unreachable is a real answer"
             (= lamb +inf.0))
      (check "…and contributes 0 as an INPUT: the recipe stays finite"
             (and (< gross +inf.0) (approx= gross 6.0 1e-9)))
      ;; the observable consequence: the joint route survives the min
      (check "the joint route is not silently dropped — wool beats its standalone"
             (< w (/ (recipe-gross-effort rs "r-shear") 3.0)))
      (check "the joint route is not silently dropped — mutton beats its standalone"
             (< m (/ (recipe-gross-effort rs "r-butcher") 10.0))))

    ;; ── still an infimum: the cheapest route wins ────────────────────────────
    (display "\n── the cheapest producer still wins ──\n")
    (let ((w (crystallized-snlt-for-spec rs "wool"))
          (shear-route (/ (recipe-gross-effort rs "r-shear") 3.0)))
      (format #t "  wool via shear (standalone): ~,4f h/kg\n" shear-route)
      (format #t "  wool as priced:              ~,4f h/kg\n" w)
      (check "wool prices at the MINIMUM over its producers"
             (<= w (+ shear-route 1e-9))))))

(test-summary!)
