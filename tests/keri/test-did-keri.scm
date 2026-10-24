;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-did-keri.scm — did:keri helpers + serve-static route.

(use-modules (localchimera test harness)
             (localchimera keri did)
             (ice-9 format))

(define %aid "DNUlpJGAE--lBKM2QVuwHlN3YsaewouoNTNIiOJPifJ4")
(define %did "did:keri:DNUlpJGAE--lBKM2QVuwHlN3YsaewouoNTNIiOJPifJ4")

(format #t "~%=== did:keri helpers ===~%")

(check "aid->did-keri prepends prefix"
       (string=? %did (aid->did-keri %aid)))
(check "did-keri->aid strips prefix"
       (string=? %aid (did-keri->aid %did)))
(check "did-keri? recognises a valid DID"
       (did-keri? %did))
(check "did-keri? rejects plain AID"
       (not (did-keri? %aid)))
(check "did-keri? rejects non-string"
       (not (did-keri? 42)))
(check "round-trip: aid → did → aid"
       (string=? %aid (did-keri->aid (aid->did-keri %aid))))

(test-summary!)
