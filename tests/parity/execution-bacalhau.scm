;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/execution-bacalhau.scm — ring-3 compute ↔ Bacalhau parity.
;;; The contract: a job envelope's spec becomes an orchestrator job — PUT
;;; /api/v1/orchestrator/jobs with the Job body. Invariant leg pins the
;;; wire; live leg submits to a real Bacalhau node.

(use-modules (localchimera test harness)
             (localchimera test parity)
             (localchimera delegates)
             (srfi srfi-1))

(let ((w (bacalhau-job-wire '(("Engine" . "wasm") ("Publisher" . "estuary")))))
  (check "bacalhau wire is PUT /api/v1/orchestrator/jobs with the Job body"
         (and (equal? (cdr (assoc "method" w)) "PUT")
              (equal? (cdr (assoc "path" w)) "/api/v1/orchestrator/jobs")
              (equal? (cdr (assoc "content-type" w)) "application/json")
              (and (assoc "Job" (cdr (assoc "body" w))) #t)) #t))

(parity-live-delegate "LOCALCHIMERA_BACALHAU_URL"
  "bacalhau accepts a job submission"
  (lambda (t) (make-bacalhau-delegate t))
  (lambda (d) (d '(("Engine" . "wasm") ("Publisher" . "estuary"))))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
