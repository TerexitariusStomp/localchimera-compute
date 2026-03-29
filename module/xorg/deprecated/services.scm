;;; module/playnet/services.scm — Service and deployment capabilities for playnet
;;;
;;; Minimal, cap-correct public API:
;;;   ^service-cap          — full service capability for a named Shepherd service
;;;   make-service-cap      — convenience constructor
;;;   attenuate-service-cap — structural restriction to subset of actions
;;;   ^deploy-cap           — deployment capability pre-bound to one config file
;;;   make-deploy-cap       — convenience constructor
;;;
;;; Possession IS authorization. No ACL lists, no registries.

(define-module (playnet services)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs io ports)
  #:export (^service-cap
            make-service-cap
            ^attenuated-service-cap
            attenuate-service-cap
            ^deploy-cap
            make-deploy-cap))

;;; ── ^service-cap ────────────────────────────────────────────────────────────

(define (^service-cap bcom service-name)
  "Full capability for a named Shepherd service.
   TODO Shepherd×Goblins: replace herd subprocess with direct actor reference."
  (define (herd action)
    (system* "herd" (symbol->string action) service-name))
  (define (herd-output action)
    (let* ((port (open-input-pipe
                  (string-append "herd " (symbol->string action)
                                 " " service-name " 2>&1")))
           (out  (read-string port)))
      (close-pipe port)
      out))
  (methods
   [(start)   (herd 'start)]
   [(stop)    (herd 'stop)]
   [(restart) (herd 'restart)]
   [(status)  (herd-output 'status)]
   [(name)    service-name]))

(define (make-service-cap vat service-name)
  "Spawn a full ^service-cap in VAT for service-name."
  (with-vat vat (spawn ^service-cap service-name)))

;;; ── ^attenuated-service-cap ─────────────────────────────────────────────────

(define (^attenuated-service-cap bcom base-cap allowed-set)
  "Structurally attenuated service cap — only messages in allowed-set work.
   Attempting any other action is an error."
  (lambda (msg . args)
    (if (memv msg allowed-set)
        (apply $ base-cap msg args)
        (error "This capability does not include" msg))))

(define (attenuate-service-cap vat base-cap . allowed)
  "Structural attenuation — only allowed actions exist on this capability.
   Example: (attenuate-service-cap vat nginx-cap 'start 'status)"
  (with-vat vat (spawn ^attenuated-service-cap base-cap allowed)))

;;; ── file-sha256-str ─────────────────────────────────────────────────────────

(define (file-sha256-str path)
  "Content fingerprint for path. Uses gcrypt sha256 if available, else mtime:size."
  (let* ((port (open-input-file path))
         (data (get-bytevector-all port)))
    (close-port port)
    (catch #t
      (lambda ()
        (let ((sha256 (@@ (gcrypt hash) sha256))
              (bv->hex (@@ (gcrypt hash) bytevector->hex-string)))
          (bv->hex (sha256 data))))
      (lambda _
        (let ((st (stat path)))
          (string-append (number->string (stat:mtime st))
                         ":" (number->string (stat:size st))))))))

;;; ── ^deploy-cap ─────────────────────────────────────────────────────────────

(define (^deploy-cap bcom config-path fingerprint)
  "Deployment capability pre-bound to exactly one config file.
   Possession IS authorization. Content-verified at deploy time.
   TODO Shepherd×Goblins: replace subprocess with Guix actor reference."
  (methods
   [(deploy)
    (if (equal? (file-sha256-str config-path) fingerprint)
        (system* "guix" "deploy" config-path)
        (error "Config modified since authorization — re-create this capability"
               config-path))]
   [(config) config-path]))

(define (make-deploy-cap vat config-path)
  "Create a deployment capability for exactly config-path.
   Hashes the file now; verifies at deploy time."
  (with-vat vat (spawn ^deploy-cap config-path (file-sha256-str config-path))))
