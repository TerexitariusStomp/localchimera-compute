;;; module/playnet/test/keri-integration.scm — shared bring-up for the live
;;; KERIA integration suites.
;;;
;;; The integration tests (test-real-keria, test-keri-backend-live,
;;; test-keria-issuance, test-witness-receipts) all run against the same
;;; KERIA + witnesses that tests/keri/integration/run-integration.sh spins
;;; up, and all read the same KERIA_* env contract that harness establishes.
;;; This module is the single source for that contract so the default
;;; ports / passcode live in one place.
;;;
;;; (test-real-keria keeps its own pass-on-no-raise `check-call` on
;;; purpose — that's a different contract from the strict truthy-return
;;; `check-call` shared here, not duplication.)

(define-module (playnet test keri-integration)
  #:use-module (playnet test harness)
  #:use-module (playnet keri bridge)
  #:use-module (ice-9 format)
  #:export (env-or
            keri-integration-bring-up!
            check-call))

(define (env-or name default)
  "getenv NAME, falling back to DEFAULT when the variable is unset."
  (or (getenv name) default))

(define (keri-integration-bring-up!)
  "Read the KERIA_* env vars run-integration.sh exports (with the harness
   defaults), point the bridge at them via `keri-set-urls!`, and return
   (values admin-url boot-url passcode)."
  (let ((admin (env-or "KERIA_ADMIN_URL" "http://127.0.0.1:3901"))
        (boot  (env-or "KERIA_BOOT_URL"  "http://127.0.0.1:3903"))
        (pass  (env-or "KERIA_PASSCODE"  "testpasscode21charsXX")))
    (keri-set-urls! admin boot)
    (values admin boot pass)))

(define (check-call label thunk)
  "Strict live-suite check: pass iff THUNK returns truthy without raising;
   print the error/return shape on failure but keep the suite going."
  (check label
         (catch #t
           (lambda ()
             (let ((r (thunk)))
               (unless r (format #t "  → returned #f~%"))
               (and r #t)))
           (lambda (key . args)
             (format #t "  → raised: ~a ~a~%" key args)
             #f))))
