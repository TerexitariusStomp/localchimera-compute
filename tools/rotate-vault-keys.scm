#!/usr/bin/env -S guile --no-auto-compile -L module
!#
;;; tools/rotate-vault-keys.scm — re-encrypt every scope's bran.vault
;;; under a new PLAYNET_VAULT_KEY.
;;;
;;; Usage:
;;;   PLAYNET_STATE_DIR=/path/to/state \
;;;   PLAYNET_VAULT_KEY_OLD=<64-hex>    \
;;;   PLAYNET_VAULT_KEY_NEW=<64-hex>    \
;;;     guile --no-auto-compile -L module tools/rotate-vault-keys.scm
;;;
;;; For each scope under <state>/scopes/<aid>/, if a `bran.vault` file
;;; exists, decrypt under OLD, re-encrypt under NEW, write atomically
;;; (temp + rename). Failures on any single scope abort the run with
;;; the partial set rolled back from the temp file. Already-rotated
;;; vaults (decryptable under NEW) are left untouched (idempotent).

(use-modules (playnet keys bran-custody) (playnet utils paths)
             (playnet keri signify)         ;; install crypto backend
             ((playnet utils hex) #:select (bv->hex hex->bv))
             (rnrs bytevectors)
             (ice-9 ftw)
             (ice-9 format)
             (srfi srfi-1))

(define (env-or-die name)
  (or (getenv name)
      (begin (format (current-error-port)
                     "rotate-vault-keys: ~a not set~%" name)
             (exit 2))))

(define old-hex (env-or-die "PLAYNET_VAULT_KEY_OLD"))
(define new-hex (env-or-die "PLAYNET_VAULT_KEY_NEW"))

(unless (= 64 (string-length old-hex))
  (format (current-error-port) "OLD key must be 64 hex chars~%") (exit 2))
(unless (= 64 (string-length new-hex))
  (format (current-error-port) "NEW key must be 64 hex chars~%") (exit 2))
(when (string=? old-hex new-hex)
  (format (current-error-port) "OLD and NEW keys are identical — no-op~%")
  (exit 0))

(define old-bv (hex->bv old-hex))
(define new-bv (hex->bv new-hex))

(define state-root (string-append (playnet-state-dir) "/scopes"))

(unless (file-exists? state-root)
  (format #t "no state at ~a — nothing to rotate~%" state-root)
  (exit 0))

(define (vault-paths-under-state)
  (filter-map
   (lambda (entry)
     (and (not (member entry '("." "..")))
          (let ((vp (string-append state-root "/" entry "/bran.vault")))
            (and (file-exists? vp) (cons entry vp)))))
   (or (scandir state-root) '())))

(define (atomic-rotate-one! aid path)
  "Decrypt PATH under old-bv, re-encrypt under new-bv, write to a
   sibling temp file, then rename atomically. Idempotent: if the file
   already decrypts under NEW, leave it alone."
  (let ((bran
         (catch #t
           (lambda () (read-vault-bran path #:key-bv old-bv))
           (lambda _ #f))))
    (cond
     ((not bran)
      ;; Maybe already rotated: try NEW.
      (let ((b2 (catch #t
                  (lambda () (read-vault-bran path #:key-bv new-bv))
                  (lambda _ #f))))
        (cond
         (b2  (format #t "  ~a — already on NEW, skip~%" aid))
         (else (error "neither OLD nor NEW key opens vault" aid path)))))
     (else
      (let ((tmp (string-append path ".tmp")))
        (write-vault-bran! bran tmp #:key-bv new-bv)
        (rename-file tmp path)
        (format #t "  ~a — rotated~%" aid))))))

(format #t "rotating vault keys under ~a~%" state-root)
(let ((entries (vault-paths-under-state)))
  (cond
   ((null? entries) (format #t "no bran.vault files found~%"))
   (else
    (for-each (lambda (pair)
                (atomic-rotate-one! (car pair) (cdr pair)))
              entries)
    (format #t "done — ~a vault file(s) processed~%" (length entries)))))
