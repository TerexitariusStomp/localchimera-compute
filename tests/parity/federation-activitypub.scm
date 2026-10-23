;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/federation-activitypub.scm — federation ↔ ActivityPub.
;;; The contract: a federated act is a signed activity POST to the
;;; actor's outbox. Invariant leg pins the activity shape; live leg
;;; reaches a real outbox.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(define fixture-activity
  (ap-activity "Create" "https://playnet.earth/actors/commune"
               '(("type" . "Note") ("content" . "hello"))
               '("https://www.w3.org/ns/activitystreams#Public")))

(check "the activity is a type/actor/object/to quad"
       (and (equal? (cdr (assoc "type" fixture-activity)) "Create")
            (assoc "actor" fixture-activity)
            (assoc "object" fixture-activity)
            (assoc "to" fixture-activity)
            #t) #t)

(parity-live-delegate "PLAYNET_AP_URL"
  "an outbox accepts the activity"
  (lambda (t) (make-ap-delegate "/actors/commune/outbox" t))
  (lambda (d) (d fixture-activity))
  (lambda (a) (pair? a)))

(test-summary!)
