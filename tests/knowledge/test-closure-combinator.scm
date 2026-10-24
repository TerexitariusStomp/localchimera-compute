;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-closure-combinator.scm — the two table-driven closures, one door.
;;;
;;; Nutrients (a private good, produce flows) and elements (a shared coefficient
;;; table, no flow) look like two different mechanisms; both are `closure-rows`
;;; read two ways. This proves the equivalence directly — closure-rows against
;;; nutrient-content and against the bare element default reproduce exactly what
;;; each closure already returns — and then proves a THIRD domain (an invented
;;; "warmth" floor, nobody's table before this file) stands up on the identical
;;; two calls: state a table, ask closure-rows for the rows, closure-flows for
;;; the flows. Nothing else changes underneath it.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/knowledge/test-closure-combinator.scm

(use-modules (srfi srfi-1) (ice-9 format))
(let ((self (find file-exists? (filter string? (cons (false-if-exception (current-filename)) (command-line))))))
  (when self (add-to-load-path (string-append (dirname self) "/../../module"))))
(use-modules (localchimera vf schemas) (srfi srfi-1) (localchimera knowledge catalogues substances))

(define checks '())
(define (check label ok) (set! checks (cons (cons label ok) checks))
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))

(format #t "~%── closure-rows reproduces the nutrient closure exactly ──~%")
(check "closure-rows #:content nutrient-content = nutrient-content, for grain"
       (equal? (closure-rows "grain" 2 #:content nutrient-content) (nutrient-content "grain" 2)))
(check "…and for a food with no table entry, both are empty"
       (equal? (closure-rows "no-such-food" 1 #:content nutrient-content) '()))

(format #t "~%── closure-rows reproduces the element closure exactly (its own defaults) ──~%")
(check "closure-rows with no #:content = substance-content, elements' own defaults"
       (equal? (closure-rows "grain" 2) (substance-content "grain" 2)))

(format #t "~%── a third domain, invented here, stands on the identical two calls ──~%")
;; WARMTH: a shelter floor's table-driven closure, nobody's before this file —
;; the same shape as *food-nutrition*, a different substance entirely.
(define *shelter-warmth*
  '(("insulated-room" . (("warmth" . 4.0))) ("open-shelter" . (("warmth" . 1.0)))))
(define (warmth-content form qty)
  (substance-content form qty #:contains *shelter-warmth* #:tracked '("warmth")))
(check "a form's rows, off its own table, via the shared primitive"
       (equal? (closure-rows "insulated-room" 3 #:content warmth-content) '(("warmth" . 12.0))))

;; the flow shape: a claimed dwelling's own "occupy" process reduces it to warmth —
;; the same two-line pattern `eat` uses for nutrients, `name` swapped for a
;; shelter-goods convention instead of a nutrient one.
(define (occupy pid form)
  (let ((rid (string-append "occupy~" form "~" pid)))
    (closure-flows rid (closure-rows form 1 #:content warmth-content)
                    #:name (lambda (row) (string-append row "|" pid)))))
(define occupied (occupy "ada" "insulated-room"))
(check "one produce flow, the warmth row, located to the occupant"
       (and (= (length occupied) 1)
            (equal? (recipe-flow-resource-conforms-to (car occupied)) "warmth|ada")
            (= (measure-has-numerical-value (recipe-flow-resource-quantity (car occupied))) 4.0)))
(check "the flow's own process is the occupy recipe just built, RID's default"
       (equal? (recipe-flow-recipe-output-of (car occupied)) "occupy~insulated-room~ada"))

(format #t "~%── closure-flows' PROCESS override reproduces expand-nutrient-flows' own attachment ──~%")
;; the OTHER flow shape — riding on an existing produce flow instead of a new
;; process — is expand-nutrient-flows' own use; exercised end to end there
;; already, checked here only for the override itself.
(check "an explicit #:process wins over RID's own default"
       (equal? (recipe-flow-recipe-output-of
                (car (closure-flows "r1" '(("x" . 1.0)) #:process "some-other-process")))
               "some-other-process"))

(define ok (every cdr checks))
(format #t "~%  ~a two closures, one combinator — and a third domain costs no new mechanism~%~%"
        (if ok "✓" "✗"))
(exit (if ok 0 1))
