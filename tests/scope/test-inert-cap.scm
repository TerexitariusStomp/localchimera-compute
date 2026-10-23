;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-inert-cap.scm — a limit that names nothing says so.
;;;
;;; A cap is a limit on a good. One spelt for a good no recipe touches limits
;;; nothing: the plan runs in full, and a ban nobody is under reads exactly like
;;; no ban at all. The engine names such caps as it takes them in (ingest-located!:
;;; "[cap] …" on stderr, and `inert-caps` as data), read against the RECIPES — a working ban
;;; prunes its own consumers, and that is the cap doing its job, not an inert one.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/scope/test-inert-cap.scm

(use-modules (playnet test harness)
             (srfi srfi-11)
             (playnet scope live)
             (playnet test planner bread)
             ((playnet solve engine) #:select (inert-caps))
             (goblins) (goblins vat))

(define (solve caps)
  "→ (met . the caps the engine found inert)"
  (let ((vat (spawn-vat #:name "inert-cap")))
    (with-vat vat
      (let-values (((scope ps als) (spawn-bread-scope)))
        (let ((r (plan-scope->alist scope #:demand '(("bread#town@0" . 4.0))
                                    #:reproduce? #f #:eco-caps caps #:backend 'native-c)))
          (cons (assq-ref r 'met) (inert-caps)))))))
(define (named? r) (pair? (cdr r)))

(display "\n── a ban on a good the recipes use: it binds, and nothing is said ──\n")
(define real (solve '(("soil#town@0" . 0.0))))
(check "no soil, no bread" (< (car real) 0.01))
(check "…and the cap is not called inert for pruning its own consumers" (not (named? real)))

(display "\n── the same ban, misspelt: it binds nothing, and is named ──\n")
(define typo (solve '(("soyl#town@0" . 0.0))))
(check "the plan runs in full" (> (car typo) 0.9))
(check "…and the cap is named as limiting nothing" (named? typo))
(check "…by its own key" (equal? '("soyl#town@0") (cdr typo)))

(display "\n── no caps: nothing to say ──\n")
(check "silence" (not (named? (solve '()))))

(test-summary!)
