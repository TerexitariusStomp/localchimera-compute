;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-work-done-id.scm — the id of the event that confirms a commitment done is one function.
;;;
;;; record-work-done, record-flow-done and the dev ledger's guards each name the event
;;; confirming a commitment: `ev-<cid>`, and `ev-<cid>.<k>` for the k-th confirmation of the
;;; same commitment. Written once (vf/formulas/flows.scm), so a guard that checks whether an
;;; event stands names the very id the door will write.
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/vf/test-work-done-id.scm

(use-modules (localchimera test harness)
             ((localchimera vf formulas flows) #:select (work-done-event-id)))

(check "the first confirmation is ev-<cid>" (work-done-event-id "c1") "ev-c1")
(check "…and so is k = 0" (work-done-event-id "c1" 0) "ev-c1")
(check "the k-th confirmation of the same commitment is numbered" (work-done-event-id "c1" 2) "ev-c1.2")

(test-summary!)
