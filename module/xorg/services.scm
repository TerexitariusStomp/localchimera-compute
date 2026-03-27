;;; module/xorg/services.scm — Service and deployer capability actors for xorg
;;;
;;; Defines Goblins actor interfaces for controlling Shepherd services
;;; and running guix deploy. The backing is subprocess calls today;
;;; when Shepherd×Goblins lands, the interfaces stay the same and only
;;; the backing swaps.
;;;
;;; All actors use define-actor / methods from (goblins actor-lib methods).

(define-module (xorg services)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:export (^service-capability
            ^service-registry
            ^system-deployer
            make-subprocess-service-control
            make-subprocess-deployer))

;;; ── ^service-capability ────────────────────────────────────────────────────
;;;
;;; Wraps control of a single named service.
;;;
;;; TODO Shepherd×Goblins: replace control-proc with a direct Goblins actor
;;; reference to the Shepherd service actor. The methods stay identical;
;;; only the backing changes from subprocess to ($ shepherd-service-actor 'start).

(define (^service-capability bcom service-name control-proc)
  "Capability actor wrapping a single service.
   service-name: string, e.g. \"nginx\"
   control-proc: (lambda (action service-name) ...) where action is
                 one of 'start 'stop 'status 'restart"
  (methods
   [(start)   (control-proc 'start   service-name)]
   [(stop)    (control-proc 'stop    service-name)]
   [(restart) (control-proc 'restart service-name)]
   [(status)  (control-proc 'status  service-name)]
   [(name)    service-name]))

;;; ── make-subprocess-service-control ────────────────────────────────────────
;;;
;;; Returns a control-proc that calls herd via subprocess.
;;; Safe: can only call herd, nothing else.

(define (make-subprocess-service-control)
  "Returns a control-proc suitable for ^service-capability.
   Calls (system* \"herd\" action service-name) and returns the exit code,
   or for 'status reads the output."
  (lambda (action service-name)
    (let ((action-str (symbol->string action)))
      (if (eq? action 'status)
          ;; For status, capture output
          (let* ((port (open-input-pipe
                        (string-append "herd " action-str " " service-name
                                       " 2>&1")))
                 (output (let loop ((lines '()))
                           (let ((line (read-line port)))
                             (if (eof-object? line)
                                 (string-join (reverse lines) "\n")
                                 (loop (cons line lines)))))))
            (close-pipe port)
            output)
          ;; For start/stop/restart, just run and return exit code
          (system* "herd" action-str service-name)))))

;;; ── ^service-registry ──────────────────────────────────────────────────────
;;;
;;; Holds multiple named service capabilities. The host org uses this to
;;; manage all services and grant sub-capabilities to tenant orgs.
;;;
;;; TODO Shepherd×Goblins: this becomes a thin wrapper over the Shepherd
;;; service registry actor, auto-populating from the running system.

(define (^service-registry bcom services-alist)
  "Registry of named service capabilities.
   services-alist: ((name . ^service-capability-ref) ...)"
  (methods
   [(get name)
    (let ((pair (assoc name services-alist)))
      (if pair (cdr pair) #f))]
   [(names)
    (map car services-alist)]
   [(add name cap)
    (bcom (^service-registry bcom
                             (cons (cons name cap) services-alist)))]))

;;; ── ^system-deployer ───────────────────────────────────────────────────────
;;;
;;; Capability to run guix deploy with pre-authorized configs.
;;; The org pre-approves config files by identity (path for now, hash later);
;;; the deployer enforces that only authorized configs can be deployed.
;;;
;;; TODO Shepherd×Goblins: replace deploy-proc with a direct Guix actor
;;; reference. The deployer becomes a Goblins message:
;;; ($ guix-deploy-actor 'deploy machines-file)

(define (^system-deployer bcom authorized-configs deploy-proc)
  "Capability to deploy one of a set of authorized OS configs.
   authorized-configs: list of ((identity . description) ...) pairs
                       where identity is a file path (TODO: use sha256 hash)
   deploy-proc: (lambda (machines-file) ...)"
  (methods
   [(deploy machines-file)
    ;; TODO: replace path identity with file-sha256 hash check
    (let ((entry (assoc machines-file authorized-configs)))
      (if entry
          (deploy-proc machines-file)
          (error "machines-file not in authorized set" machines-file)))]
   [(authorize identity description)
    (bcom (^system-deployer bcom
                            (cons (cons identity description)
                                  authorized-configs)
                            deploy-proc))]
   [(authorized) authorized-configs]))

;;; ── make-subprocess-deployer ───────────────────────────────────────────────

(define (make-subprocess-deployer)
  "Returns a deploy-proc that calls (system* \"guix\" \"deploy\" machines-file).
   Suitable for passing to ^system-deployer."
  (lambda (machines-file)
    (let ((exit-code (system* "guix" "deploy" machines-file)))
      (unless (zero? exit-code)
        (error "guix deploy failed with exit code" exit-code))
      exit-code)))
