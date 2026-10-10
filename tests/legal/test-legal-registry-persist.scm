;;; test-legal-registry-persist.scm — the ^legal-registry persists to DISK.
;;;
;;; Because a guard is now a serializable DATA FORM (not a closure), a rule
;;; round-trips through write/read. This proves the registry persists like
;;; tension-registry's symbol tags: portrait → a file → a fresh restore →
;;; the same legal posture (the possibility-tension survives a cold restart).
;;;
;;; Run: guile -L module tests/legal/test-legal-registry-persist.scm

(use-modules (playnet test harness) (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal registry))            ; the fold + the guard DSL + serialization
(use-modules (playnet legal registry-actor))      ; ^legal-registry + restore-legal-registry

(define tmpfile "/tmp/legal-registry-portrait.scm")

(define out
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let ((reg (spawn ^legal-registry (list (lr-rule-banland) (lr-rule-permit)))))
        (let ((sexp ($ reg 'portrait)))
          ;; the portrait is PLAIN DATA — write it to disk …
          (call-with-output-file tmpfile (lambda (p) (write sexp p)))
          ;; … and read it back as a fresh process would, then restore.
          (let* ((from-disk (call-with-input-file tmpfile read))
                 (revived   (restore-legal-registry from-disk)))
            (list (string? (with-output-to-string (lambda () (write sexp))))  ; portrait is writeable
                  (equal? sexp from-disk)                                     ; round-trips through the disk
                  ($ reg     'forbids? (ctx-at "banland"))                    ; original forbids
                  ($ revived 'forbids? (ctx-at "banland"))                    ; restored-from-DISK still forbids
                  ($ revived 'forbids? (ctx-at "permitland"))                 ; … and a permit is still not a ban
                  ($ revived 'labels))))))))

(display "\n── The ^legal-registry persists to disk (serializable guard DSL) ──\n")
(format #t "  portrait written + read back from ~a\n" tmpfile)
(format #t "  restored laws: ~a\n" (list-ref out 5))
(check-pred "portrait is plain writeable data"              (list-ref out 0))
(check-pred "it round-trips through write→disk→read"        (list-ref out 1))
(check-pred "the live registry forbids at banland"          (list-ref out 2))
(check-pred "the DISK-restored registry STILL forbids"      (list-ref out 3))
(check-pred "a permit is not a ban (restored)"              (not (list-ref out 4)))

(display "\n")
(test-summary!)
