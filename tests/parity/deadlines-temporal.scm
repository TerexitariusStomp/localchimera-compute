;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/deadlines-temporal.scm — deadline timers ↔ Temporal parity.
;;; The contract: the 72h challenge / 4d review / 7d closure clocks are
;;; durable timers — workflow start + signal wires. Invariant leg pins
;;; the wires; live leg starts a real workflow over the HTTP bridge.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(let ((w (temporal-start-wire "dispute-d1" "dispute-deadline"
                              "machine-doors" '(72))))
  (check "temporal start wire posts the workflow to /workflows/<id>"
         (and (equal? (cdr (assoc "method" w)) "POST")
              (equal? (cdr (assoc "path" w)) "/workflows/dispute-d1")
              (let ((b (cdr (assoc "body" w))))
                (and (equal? (cdr (assoc "workflowType" b)) "dispute-deadline")
                     (equal? (cdr (assoc "taskQueue" b)) "machine-doors"))))
         #t))

(let ((w (temporal-signal-wire "dispute-d1" "receipt-landed"
                               '(("claim" . "c1")))))
  (check "temporal signal wire posts to /workflows/<id>/signal/<name>"
         (equal? (cdr (assoc "path" w))
                 "/workflows/dispute-d1/signal/receipt-landed") #t))

(parity-live-delegate "PLAYNET_TEMPORAL_URL"
  "temporal starts a workflow"
  (lambda (t) (make-temporal-delegate t))
  (lambda (d) (d (temporal-start-wire "parity-wf-1" "noop" "parity" '())))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
