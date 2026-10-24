;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-personhood-policy.scm — the ecosystem's word on recognition, read bare.
;;;
;;; With no row the defaults stand, an explicit value wins, and effective-k
;;; clamps the quorum to who could sign. The writer half — a governor's gov-cap
;;; setting the row on a commune's plan-store — is
;;; tests/doors/test-personhood-policy.scm.

(use-modules (localchimera test harness)
             (localchimera keri first-person personhood-policy))

(display "\n── defaults, then an explicit value ──\n")
(check "k defaults to 2"        (personhood-policy #f 'enrollment-k) 2)
(check "witness cap defaults"   (personhood-policy #f 'witness-cap) 10)
(check "an explicit value wins" (personhood-policy #f 'enrollment-k 3) 3)

(display "\n── effective-k clamps to the verified population ──\n")
(check "nobody recognised → one witness"      (effective-k 2 0) 1)
(check "one recognised → one witness"          (effective-k 2 1) 1)
(check "two recognised → the policy's two"     (effective-k 2 2) 2)
(check "many recognised → still the policy's"  (effective-k 2 40) 2)

(test-summary!)
