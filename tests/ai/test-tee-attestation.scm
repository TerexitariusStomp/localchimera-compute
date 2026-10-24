;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-tee-attestation.scm — the vendor-rooting orchestration + enclave pinning.
;;;
;;; The vendor QUOTE parser (Intel DCAP / NVIDIA NRAS) is an injected seam that
;;; needs a real sample payload to build; here we inject a STUB quote verifier and
;;; test the logic ABOVE it honestly: presence, report_data binds the signing key,
;;; measurement allowlist, and the fail-closed default. Plus the pinning state
;;; machine (TOFU + substitution detection), which is pure and fully testable now.
;;;
;;; Run: guile -L module tests/ai/test-tee-attestation.scm

(use-modules (localchimera test harness)
             (localchimera ai tee-attestation)
             (srfi srfi-1) (ice-9 format))

;;; a fake Intel attestation JSON (string-keyed, as json-string->scm yields).
(define ADDR "0xENCLAVEKEY0000000000000000000000000000aa")
(define* (att #:optional (addr ADDR))
  `(("intel_quote" . "deadbeef-quote") ("signing_address" . ,addr) ("nonce" . "N")))

;; a stub vendor verifier: pretend the quote parsed, and bind the address into
;; report_data (as a real enclave would) with a given measurement.
(define* (stub-quote #:key (measurement "MRTD-AAA") (bind ADDR))
  (lambda (payload)
    `((measurement . ,measurement)
      (report-data . ,(string-append "00" (substring bind 2) "00")))))  ; embeds the address

;;; ─── 1. fail-closed by default (no real verifier wired) ────────────────────
(display "\n── with no vendor verifier, rooting fails closed ──\n")
(let ((v (verify-attestation (att))))              ; verify-quote defaults to %quote-unverified
  (check "default (unwired) vendor quote → ok=#f" (assq-ref v 'ok) #f)
  (check "…with an honest reason" (assq-ref v 'reason) "vendor-quote-verifier-not-wired"))

;;; ─── 2. a verifying quote whose report_data commits the key → rooted ───────
(display "\n── a quote that verifies and binds the signing key roots ──\n")
(let ((v (verify-attestation (att) #:verify-quote (stub-quote))))
  (format #t "  verdict: ~s\n" v)
  (check "verified quote + bound key → ok" (assq-ref v 'ok) #t)
  (check "…kind detected as intel-tdx" (assq-ref v 'kind) 'intel-tdx)
  (check "…measurement surfaced" (assq-ref v 'measurement) "MRTD-AAA"))

;;; ─── 3. quote verifies but report_data does NOT commit the key → reject ────
(display "\n── a quote whose report_data omits the signing key is rejected ──\n")
(let ((v (verify-attestation (att) #:verify-quote (stub-quote #:bind "0xSOMEOTHERKEY"))))
  (check "unbound key → ok=#f" (assq-ref v 'ok) #f)
  (check-pred "…reason names the missing binding"
              (string-contains (assq-ref v 'reason) "does not commit")))

;;; ─── 4. measurement not in the trusted allowlist → reject ──────────────────
(display "\n── an untrusted enclave measurement is rejected ──\n")
(let ((v (verify-attestation (att) #:verify-quote (stub-quote #:measurement "MRTD-EVIL")
                             #:trusted-measurements '("MRTD-AAA" "MRTD-BBB"))))
  (check "measurement not in allowlist → ok=#f" (assq-ref v 'ok) #f)
  (check-pred "…reason names the measurement"
              (string-contains (assq-ref v 'reason) "measurement")))

;;; ─── 5. measurement IN the allowlist → rooted ──────────────────────────────
(display "\n── a trusted measurement passes ──\n")
(let ((v (verify-attestation (att) #:verify-quote (stub-quote #:measurement "MRTD-BBB")
                             #:trusted-measurements '("MRTD-AAA" "MRTD-BBB"))))
  (check "trusted measurement → ok" (assq-ref v 'ok) #t))

;;; ─── 6. missing attestation payload → reject ───────────────────────────────
(display "\n── an attestation with no quote payload is rejected ──\n")
(let ((v (verify-attestation `(("signing_address" . ,ADDR)) #:verify-quote (stub-quote))))
  (check "no payload → ok=#f" (assq-ref v 'ok) #f)
  (check-pred "…reason names the missing payload"
              (string-contains (assq-ref v 'reason) "missing payload")))

;;; ─── 7. enclave-identity pinning : TOFU + substitution detection ───────────
(display "\n── pinning: first-seen is unpinned, then stable, then swaps are caught ──\n")
(check "an empty store reports a model as unpinned"
       (pins-check empty-pins "TEE/gpt-oss-120b" ADDR "MRTD-AAA") 'unpinned)
(define pins1 (pins-add empty-pins "TEE/gpt-oss-120b" ADDR "MRTD-AAA"))
(check "after pinning, the same identity is 'ok"
       (pins-check pins1 "TEE/gpt-oss-120b" ADDR "MRTD-AAA") 'ok)
(check "a SWAPPED signing key is caught as 'address-changed"
       (pins-check pins1 "TEE/gpt-oss-120b" "0xDIFFERENTKEY" "MRTD-AAA") 'address-changed)
(check "a SWAPPED measurement is caught as 'measurement-changed"
       (pins-check pins1 "TEE/gpt-oss-120b" ADDR "MRTD-ZZZ") 'measurement-changed)
(check "a different model is independently unpinned"
       (pins-check pins1 "TEE/deepseek-v3.2" ADDR "MRTD-AAA") 'unpinned)

;;; ─── 8. pins round-trip on disk (same s-expr idiom as the legal registry) ──
(define pin-file (string-append (or (getenv "TMPDIR") "/tmp") "/enclave-pins-"
                                (number->string (getpid)) ".sexp"))
(save-enclave-pins pin-file pins1)
(define reloaded (load-enclave-pins pin-file))
(display "\n── enclave pins persist + reload ──\n")
(check "reloaded pins still recognise the pinned identity"
       (pins-check reloaded "TEE/gpt-oss-120b" ADDR "MRTD-AAA") 'ok)
(delete-file pin-file)

(display "\n")
(test-summary!)
