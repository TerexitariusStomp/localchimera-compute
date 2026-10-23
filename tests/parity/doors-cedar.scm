;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/doors-cedar.scm — domain-door authz ↔ cedar-agent parity.
;;; The contract: a door's "may I" is an authorization quad — POST
;;; /authorization with principal/action/resource/entities. Invariant leg
;;; pins the wire; live leg asks a real cedar-agent.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(let ((w (cedar-request "User::\"alice\"" "Action::\"lend\""
                        "Lane::\"gpu\"" '())))
  (check "cedar wire is POST /authorization with the quad"
         (and (equal? (cdr (assoc "method" w)) "POST")
              (equal? (cdr (assoc "path" w)) "/authorization")
              (let ((b (cdr (assoc "body" w))))
                (and (equal? (cdr (assoc "principal" b)) "User::\"alice\"")
                     (equal? (cdr (assoc "action" b)) "Action::\"lend\"")
                     (equal? (cdr (assoc "resource" b)) "Lane::\"gpu\""))))
         #t))

(parity-live-delegate "PLAYNET_CEDAR_URL"
  "cedar-agent answers an authorization quad"
  (lambda (t) (make-cedar-delegate t))
  (lambda (d) (d "User::\"alice\"" "Action::\"lend\"" "Lane::\"gpu\"" '()))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
