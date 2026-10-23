;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/notify-ntfy.scm — notify ↔ ntfy parity.
;;; The contract: a rendered notification's text lands as the POST body
;;; at /<topic>. Invariant leg pins the wire; live leg publishes.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (playnet notify rendered)
             (srfi srfi-1))

(define r (rendered-notification 'info "Hello" "the body text" "tag-1"))

(let ((w (ntfy-wire "commune-alerts" (rendered->text r) "Hello" 3)))
  (check "ntfy wire is POST /<topic> with the rendered text as body"
         (and (equal? (cdr (assoc "method" w)) "POST")
              (equal? (cdr (assoc "path" w)) "/commune-alerts")
              (equal? (cdr (assoc "body" w)) "Hello\n\nthe body text")) #t))

(parity-live-delegate "PLAYNET_NTFY_URL"
  "ntfy publishes a rendered notification"
  (lambda (t) (make-ntfy-delegate t))
  (lambda (d) (d "parity-test" (rendered->text r)))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
