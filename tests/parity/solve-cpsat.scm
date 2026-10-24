;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/solve-cpsat.scm — solve ↔ OR-Tools CP-SAT parity.
;;; The contract: a planning problem ships as a CP-SAT model proto over
;;; /solve; the upstream answers a status + assignment. Invariant leg
;;; pins the wire; live leg reads a real solver verdict.

(use-modules (localchimera test harness)
             (localchimera test parity)
             (localchimera delegates)
             (srfi srfi-1))

;; a two-variable fixture: maximize x+y subject to x+2y ≤ 4
(define fixture-model
  '(("variables" . (("x" . (("domain" . (0 4))))
                    ("y" . (("domain" . (0 4))))))
    ("constraints" . ((("linear" . (("vars" . ("x" "y"))
                                    ("coeffs" . (1 2))
                                    ("domain" . (-inf 4)))))))
    ("objective" . (("maximize" . (("vars" . ("x" "y"))
                                   ("coeffs" . (1 1))))))))

(let ((w (cpsat-wire fixture-model)))
  (check "cpsat wire carries the model proto"
         (equal? (cdr (assoc "model" w)) fixture-model) #t))

(parity-live-delegate "LOCALCHIMERA_CPSAT_URL"
  "cp-sat sidecar answers a fixture solve"
  (lambda (t) (make-cpsat-delegate t))
  (lambda (d) (d fixture-model))
  (lambda (a) (pair? a)))

(test-summary!)
