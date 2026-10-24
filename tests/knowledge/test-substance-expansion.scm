;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-substance-expansion.scm — a food recipe's nutrients enter the solve.
;;;
;;; expand-nutrient-flows (catalogues/substances.scm) turns a food PRODUCT flow into its induced
;;; nutrient flows via the SAME `contains` closure the rift wire uses — so a recipe
;;; that just makes `grain` also produces grain's energy/protein/iron INTO THE SOLVE,
;;; and a reproduction floor on a nutrient binds to the food production that carries
;;; it. Tested in the MODULE world (as the live gateway loads it) — mixing the
;;; primitive-loaded engine here would clash record types, which is exactly why the
;;; expansion lives module-side alongside plan-scope.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/knowledge/test-substance-expansion.scm

(use-modules (srfi srfi-1) (ice-9 format))
(let ((self (find file-exists? (filter string? (cons (false-if-exception (current-filename)) (command-line))))))
  (when self (add-to-load-path (string-append (dirname self) "/../../module"))))
(use-modules (localchimera vf schemas) (srfi srfi-1) (localchimera knowledge catalogues substances)
             (localchimera knowledge dsl shorthand))

;; a plain grow recipe — makes 2 kg of grain, nothing about nutrients written by hand
(define base
  (list (out* "g1" "grain" 2.0 "grow-grain")
        (wk* "g2" "skill-grow" 0.6 "grow-grain")))
(define expanded (expand-nutrient-flows base))
(define (produced-of spec)
  (fold (lambda (f a) (if (and (eq? (recipe-flow-action f) 'produce)
                               (equal? (recipe-flow-resource-conforms-to f) spec))
                          (+ a (measure-has-numerical-value (recipe-flow-resource-quantity f))) a))
        0 expanded))
(define induced (filter (lambda (f) (and (eq? (recipe-flow-action f) 'produce)
                                         (member (recipe-flow-resource-conforms-to f) *nutrient-ids*))) expanded))
(define works (filter (lambda (f) (eq? (recipe-flow-action f) 'work)) expanded))

(format #t "~%── grow 2 kg grain → the solve now also sees grain's nutrients ──~%")
(format #t "  grain preserved: ~a kg · induced nutrient flows: ~a~%" (produced-of "grain") (length induced))
(format #t "  energy ~a kcal · protein ~a g · iron ~a mg  (= 2 kg × content)~%"
        (produced-of "energy") (produced-of "protein") (produced-of "iron"))
(format #t "  all attached to the grow-grain process: ~a · work flow untouched: ~a~%"
        (every (lambda (f) (equal? (recipe-flow-recipe-output-of f) "grow-grain")) induced) (length works))

(let* ((c1 (= (produced-of "grain") 2.0))           ; the original product flow preserved
       ;; 2 kg × grain's own row — read off the composition table (the USDA
       ;; slice, knowledge/food-sources.scm), never typed here
       (per-kg (lambda (nut) (assoc-ref (nutrient-content "grain" 1) nut)))
       (c2 (< (abs (- (produced-of "energy") (* 2 (per-kg "energy")))) 1e-6))
       (c3 (< (abs (- (produced-of "protein") (* 2 (per-kg "protein")))) 1e-6))
       (c4 (< (abs (- (produced-of "iron") (* 2 (per-kg "iron")))) 1e-6))
       (c5 (= (length works) 1))                    ; the work flow is not a product → not expanded
       (c6 (every (lambda (f) (equal? (recipe-flow-recipe-output-of f) "grow-grain")) induced))
       (ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  [~a] the original grain product flow is preserved~%" (if c1 "✓" "✗"))
  (format #t "  [~a] grain's ENERGY enters the solve (2 kg × the table's row, via `contains`)~%" (if c2 "✓" "✗"))
  (format #t "  [~a] protein and iron too, at the table's figures~%" (if (and c3 c4) "✓" "✗"))
  (format #t "  [~a] only PRODUCT flows expand (the work flow is untouched)~%" (if c5 "✓" "✗"))
  (format #t "  [~a] induced flows attach to the producing process~%" (if c6 "✓" "✗"))
  (format #t "~%  ~a a food recipe carries its nutrients into the solve — the same `contains` as the rift~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
