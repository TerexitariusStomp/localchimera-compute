;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-snlt-order-invariance.scm — SNLT is an INFIMUM over the recipe graph,
;;; so it is a property of the TECHNOLOGY and of nothing else.
;;;
;;; Spec: docs/social-category.typ §4 "Value is a distance" + §8 Obligation 4.
;;;   ℓ̂(A) = ℛ̂(I, A), the least labour reaching A from nothing. Two consequences
;;;   are tested here:
;;;     • the triangle inequality — ℛ̂(A,B) + ℛ̂(B,C) ≥ ℛ̂(A,C), i.e. "you may
;;;       always go via the intermediate", so a good never prices below its
;;;       inputs plus the labour added on top;
;;;     • order-independence — the value depends on the recipe graph, not on
;;;       the order specs are visited in, hence not on what they are NAMED.
;;;
;;; The regression: `build-sne-index/actor` used to fold over
;;; `all-resource-specs` reading input values out of a partially-built index
;;; (absent ⇒ 0). `all-resource-specs` returns `hashmap-values`, whose order
;;; comes from the hash of the spec ID — so bread priced at 2h or 3h depending
;;; on whether "flour" happened to hash before "bread". Both implementations
;;; (sne.scm and rollup.scm) are checked, and checked against each other.
;;;
;;; Fixture (same technology in every case, only the names change):
;;;     raw --(mill: 1h)--> mid --(bake: 2h)--> top
;;;   correct: sne(raw)=0 (no recipe), sne(mid)=1, sne(top)=3.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/scope/test-snlt-order-invariance.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet algorithms rollup) (playnet algorithms sne) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 format))

(define (approx= a b) (< (abs (- a b)) 1e-9))

;;; ── the fixture, parameterised by the three spec names ──────────────────────
;;; Returns (values sne-index recipe-store fold-order), inside a vat turn.

(define (with-chain raw mid top proc)
  "Build raw→mid→top (1h mill, 2h bake) under the given spec NAMES, then call
   PROC with (sne-index recipe-store fold-order)."
  (let ((store (make-memory-store)))
    (call-with-values
      (lambda () (spawn-persistent-vat scope-root-env
                   (lambda () (spawn-scope-root "snlt-order")) store))
      (lambda (vat scope)
        (with-vat vat
          (let ((rs ($ scope 'recipe-store)))
            (for-each
              (lambda (id)
                ($ rs 'add-resource-spec
                   (make-resource-specification #:id id #:name id #:default-unit-of-resource "u")))
              (list raw mid top))
            (for-each
              (lambda (pid)
                ($ rs 'add-process-spec
                   (make-process-specification #:id (string-append "ps-" pid) #:name pid))
                ($ rs 'add-recipe-process
                   (make-recipe-process #:id pid #:name pid #:process-conforms-to (string-append "ps-" pid)
                                        #:has-duration (make-duration 1 %effort-unit))))
              '("rp-mill" "rp-bake"))
            ($ rs 'add-recipe (make-recipe #:id "r-mill" #:name "mill" #:primary-output mid
                                           #:recipe-processes '("rp-mill") #:recipe-exchanges '()))
            ($ rs 'add-recipe (make-recipe #:id "r-bake" #:name "bake" #:primary-output top
                                           #:recipe-processes '("rp-bake") #:recipe-exchanges '()))
            (define (fl id action spec qty inp outp)
              ($ rs 'add-recipe-flow
                 (make-recipe-flow #:id id #:action action #:resource-conforms-to spec
                                   #:resource-quantity (and qty (make-measure qty "u"))
                                   #:recipe-input-of inp #:recipe-output-of outp)))
            (define (wk id h inp)
              ($ rs 'add-recipe-flow
                 (make-recipe-flow #:id id #:action 'work #:effort-quantity (make-measure h %effort-unit)
                                   #:recipe-input-of inp)))
            ;; mill: consume 1 raw + 1h work -> produce 1 mid
            (fl "f1" 'consume raw 1.0 "rp-mill" #f) (wk "f2" 1.0 "rp-mill")
            (fl "f3" 'produce mid 1.0 #f "rp-mill")
            ;; bake: consume 1 mid + 2h work -> produce 1 top
            (fl "f4" 'consume mid 1.0 "rp-bake" #f) (wk "f5" 2.0 "rp-bake")
            (fl "f6" 'produce top 1.0 #f "rp-bake")
            (proc (build-sne-index/actor rs) rs
                  (map resource-specification-id ($ rs 'all-resource-specs)))))))))

;;; ── the naming schemes: same technology, different hash order ───────────────
;;; Chosen so that BOTH fold orders occur — before the fix, the first three
;;; priced `top` at 2.0 (the embodied hour dropped) and the last two at 3.0.

(define naming-schemes
  '(("wheat" "flour" "bread")
    ("aaa"   "mmm"   "zzz")
    ("zzz"   "mmm"   "aaa")
    ("r1"    "m1"    "t1")
    ("input" "middle" "output")))

(display "\n── SNLT: an infimum over the recipe graph, not over the spec names ──\n")

(define observed-tops '())

(for-each
  (lambda (names)
    (let ((raw (car names)) (mid (cadr names)) (top (caddr names)))
      (with-chain raw mid top
        (lambda (idx rs order)
          (let ((s-raw (hashmap-ref idx raw 'missing))
                (s-mid (hashmap-ref idx mid 'missing))
                (s-top (hashmap-ref idx top 'missing)))
            (set! observed-tops (cons s-top observed-tops))
            (format #t "\n  names ~a → fold order ~a\n" names order)
            (check (format #f "sne(~a) = 0 — a raw with no recipe" raw)
                         (approx= s-raw 0))
            (check (format #f "sne(~a) = 1 — one hour of milling" mid)
                         (approx= s-mid 1.0))
            (check (format #f "sne(~a) = 3 — 2h baking + 1h embodied" top)
                         (approx= s-top 3.0))
            ;; the triangle inequality, directly
            (check "triangle: sne(top) ≥ sne(mid) + 2h added"
                         (>= (+ s-top 1e-9) (+ s-mid 2.0)))
            ;; and the two implementations must agree
            (let ((c-mid (crystallized-snlt-for-spec rs mid))
                  (c-top (crystallized-snlt-for-spec rs top)))
              (check "rollup.scm agrees with sne.scm on the intermediate"
                           (approx= c-mid s-mid))
              (check "rollup.scm agrees with sne.scm on the final good"
                           (approx= c-top s-top))))))))
  naming-schemes)

(display "\n── the invariant, stated once over all namings ──\n")
(check "every naming scheme yields the SAME labour content"
             (every (lambda (v) (approx= v (car observed-tops))) observed-tops))

;;; ── cycles must terminate at the direct measure, not spin ──────────────────
;;; corn sown to grow corn: the graph has a loop, and the infimum still exists.

(display "\n── a cyclic recipe graph bottoms out ──\n")

(define corn-direct-hours 4.0)   ; the `grow` recipe's work flow, below

(define (with-cycle proc)
  (let ((store (make-memory-store)))
    (call-with-values
      (lambda () (spawn-persistent-vat scope-root-env
                   (lambda () (spawn-scope-root "snlt-cycle")) store))
      (lambda (vat scope)
        (with-vat vat
          (let ((rs ($ scope 'recipe-store)))
            ($ rs 'add-resource-spec
               (make-resource-specification #:id "corn" #:name "corn"
                                            #:default-unit-of-resource "kg"))
            ($ rs 'add-process-spec
               (make-process-specification #:id "ps-grow" #:name "grow"))
            ($ rs 'add-recipe-process
               (make-recipe-process #:id "rp-grow" #:name "grow" #:process-conforms-to "ps-grow"
                                    #:has-duration (make-duration 1 %effort-unit)))
            ($ rs 'add-recipe (make-recipe #:id "r-grow" #:name "grow" #:primary-output "corn"
                                           #:recipe-processes '("rp-grow") #:recipe-exchanges '()))
            ;; consume 0.2 corn (seed) + 4h work -> produce 1 corn
            ($ rs 'add-recipe-flow
               (make-recipe-flow #:id "g1" #:action 'consume #:resource-conforms-to "corn"
                                 #:resource-quantity (make-measure 0.2 "kg")
                                 #:recipe-input-of "rp-grow"))
            ($ rs 'add-recipe-flow
               (make-recipe-flow #:id "g2" #:action 'work #:effort-quantity (make-measure corn-direct-hours %effort-unit)
                                 #:recipe-input-of "rp-grow"))
            ($ rs 'add-recipe-flow
               (make-recipe-flow #:id "g3" #:action 'produce #:resource-conforms-to "corn"
                                 #:resource-quantity (make-measure 1.0 "kg")
                                 #:recipe-output-of "rp-grow"))
            (proc (build-sne-index/actor rs) rs)))))))

(with-cycle
  (lambda (idx rs)
    (let ((v (hashmap-ref idx "corn" 'missing)))
      (format #t "  sne(corn) = ~a  (direct 4h; seed bottoms out, no spin)\n" v)
      ;; 4.0 is the fixture's own direct work (the `grow` recipe's work flow), not
      ;; a threshold — named so the two cannot drift apart.
      (check "a cyclic graph terminates with a finite value"
                   (and (number? v) (not (= v +inf.0)) (>= v corn-direct-hours)))
      (check "the cycle bottoms out at the direct measure, not below"
                   (>= (+ v 1e-9) corn-direct-hours)))))

(test-summary!)
