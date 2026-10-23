;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-plan-proposal-name.scm — a rising plan's proposal is named for its plan, and the name reads back.
;;;
;;; The leaf publishes its work as a proposal named `plan:<plan-id>` (federation/plan-bundle.scm);
;;; the scopes' deployment table and the UC's matching read the plan id back off the name. One
;;; pair of functions writes and reads it, so neither spells the prefix.
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/federation/test-plan-proposal-name.scm

(use-modules (playnet test harness)
             ((playnet federation plan-bundle) #:select (plan-proposal-name plan-proposal-plan-id)))

(check "a rising plan's proposal carries its plan id in its name" (plan-proposal-name "plan-7") "plan:plan-7")
(check "…and the plan id reads back off the name" (plan-proposal-plan-id (plan-proposal-name "plan-7")) "plan-7")
(check "a name that is not a rising plan's reads as none" (map plan-proposal-plan-id (list "offer:ana:p@w" "plan:" #f "plan")) '(#f #f #f #f))

(test-summary!)
