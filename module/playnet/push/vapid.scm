;;; module/playnet/push/vapid.scm — VAPID key persistence
;;;
;;; Generates a P-256 key pair on first boot and persists it to disk.
;;; The public key travels to the browser over OCapN (lobby method),
;;; not via a separate HTTP endpoint.

(define-module (playnet push vapid)
  #:use-module (gcrypt pk-crypto)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:use-module (playnet push crypto)
  #:export (load-or-generate-vapid-key!))

(define (load-or-generate-vapid-key! data-dir)
  "Load VAPID key from DATA-DIR, or generate and persist a new one.
   Returns the gcrypt canonical-sexp keypair."
  (let ((path (string-append data-dir "/vapid-key.scm")))
    (if (file-exists? path)
        (let ((key (string->canonical-sexp
                    (call-with-input-file path get-string-all))))
          (format (current-error-port)
                  "  [vapid] loaded key from ~a~%" path)
          key)
        (let ((key (generate-vapid-keypair)))
          (call-with-output-file path
            (lambda (port)
              (put-string port (canonical-sexp->string key))
              (newline port)))
          (format (current-error-port)
                  "  [vapid] generated new key at ~a~%" path)
          key))))
