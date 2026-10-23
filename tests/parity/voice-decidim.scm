;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/voice-decidim.scm — ballots ↔ Decidim parity.
;;; The contract: a cast ballot is a GraphQL mutation on /api. Invariant
;;; leg pins the document envelope; live leg posts to a real component.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(define fixture-mutation "mutation { castBallot(input:{ballotId:1,option:\"yes\"}) { id } }")
(define fixture-vars '(("ballotId" . 1)))

(let ((w (decidim-ballot-wire fixture-mutation fixture-vars)))
  (check "decidim wire is a GraphQL document on /api"
         (and (equal? (cdr (assoc "path" w)) "/api")
              (equal? (cdr (assoc "body" w))
                      `(("query" . ,fixture-mutation)
                        ("variables" . ,fixture-vars)))) #t))

(parity-live-delegate "PLAYNET_DECIDIM_URL"
  "decidim answers the ballot mutation"
  (lambda (t) (make-decidim-delegate t))
  (lambda (d) (d fixture-mutation fixture-vars))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
