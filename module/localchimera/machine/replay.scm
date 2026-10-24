;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/machine/replay.scm — the prover side of the receipt.
;;;
;;; A receipt is a claim; replay is the check. The registry remembers what
;;; the lender said happened; this module decides what happens when a
;;; challenger asks the question again — per the dispute model, PoI replay
;;; is authoritative: a wrong result re-run under the same repro spec is the
;;; evidence, not anybody's word.
;;;
;;; WHAT IS HERE (real, testable):
;;;   • replay-job — the verdict logic, executor-injected. Given the job's
;;;     envelope, the receipt's repro spec, and the output hash the receipt
;;;     claims, answer (reproduced . #t|#f) or a named failure.
;;;   • Mode semantics —
;;;       'exact:        replay must produce the same bytes. Deterministic
;;;                      images (wasm with pinned host fns) replay for free.
;;;       'deterministic: replay under the spec's pinned seed + decoding +
;;;                      engine-version; the seeded output's hash compares.
;;;       'none:         the job never promised replay — the receipt is
;;;                      evidence only, and 'unverifiable is NOT a verdict
;;;                      against the lender; disputes go to review.
;;;   • %replay-unavailable — the fail-closed default executor. Mirrors
;;;     ai/tee-attestation.scm's %quote-unverified: the seam exists, the
;;;     executor arrives injected (wasmCloud/Wasimoff), and nothing
;;;     silently "reproduces" in the meantime.
;;;
;;; Verdicts: 'reproduced | 'mismatch | 'unverifiable | 'no-executor.
;;; A challenge record pairs the verdict with the receipt digest, the
;;; claimed output hash, and the counter-hash the replay produced —
;;; the same fields the dispute path carries.

(define-module (localchimera machine replay)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (localchimera machine envelope)
  #:use-module (localchimera machine receipt)
  #:export (replay-job replay-verdict
            %replay-unavailable
            make-challenge
            challenge-receipt-digest challenge-reproduced
            challenge-attestation-hash challenge-counter-hash))


;;; ── the executor seam ───────────────────────────────────────────────────
;;; (executor envelope repro-spec) → output-hash string, or raises.
;;; The real executors live where the work can run — a wasmCloud host, a
;;; browser worker — not in this module. Default refuses loudly.

(define (%replay-unavailable envelope repro-spec)
  (error "replay: no executor injected for this job"
         (job-envelope-image envelope)))


;;; ── the verdict ─────────────────────────────────────────────────────────
;;; replay-job returns a tagged answer:
;;;   (ok <reproduced?> <counter-hash>)   — replay ran; compare spoke
;;;   (error <reason-string>)             — executor raised, or mode 'none

(define* (replay-job envelope repro-spec expected-hash
                     #:key (executor %replay-unavailable))
  "Re-execute ENVELOPE under REPRO-SPEC and compare to EXPECTED-HASH."
  (let ((mode (repro-spec-mode repro-spec)))
    (cond
     ((eq? mode 'none)
      (list 'error "replay: job's repro mode is 'none — evidence only"))
     ((memq mode '(exact deterministic))
      (catch #t
        (lambda ()
          (let ((counter (executor envelope repro-spec)))
            (list 'ok (equal? counter expected-hash) counter)))
        (lambda (k . a)
          (list 'error (format #f "replay: executor failed: ~a" a)))))
     (else (list 'error "replay: not a repro mode")))))

(define (replay-verdict result)
  "Name the replay-job answer: 'reproduced | 'mismatch | 'unverifiable | 'no-executor."
  (match result
    (('ok #t _hash) 'reproduced)
    (('ok #f _hash) 'mismatch)
    (('error (? string? m))
     (if (string-contains m "no executor injected")
         'no-executor
         'unverifiable))
    (_ 'unverifiable)))


;;; ── the challenge record ────────────────────────────────────────────────
;;; What a challenge carries, per the dispute model: the receipt's digest,
;;; whether the replay reproduced it, the attestation hash (the output hash
;;; the receipt claimed), and the counter-hash the replay produced. On a
;;; 'none job or a missing executor, counter-hash is #f — the field names
;;; the absence rather than inventing one.

(define-record-type <challenge>
  (%make-challenge receipt-digest reproduced attestation-hash counter-hash)
  challenge?
  (receipt-digest    challenge-receipt-digest)   ; string — what was claimed
  (reproduced        challenge-reproduced)       ; #t | #f | 'unverifiable
  (attestation-hash  challenge-attestation-hash) ; string — outputHash claimed
  (counter-hash      challenge-counter-hash))    ; string | #f — replay's hash

(define* (make-challenge #:key receipt-digest reproduced attestation-hash
                         counter-hash)
  (%make-challenge receipt-digest reproduced attestation-hash counter-hash))
