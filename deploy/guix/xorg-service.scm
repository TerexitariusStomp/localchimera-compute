;;; deploy/guix/xorg-service.scm — Guix service type for xorg org processes
;;;
;;; Defines xorg-service-type: a Shepherd service that runs a Guile process
;;; hosting one or more xorg actors.
;;;
;;; Each org runs as a separate Shepherd service for isolation.
;;; Communication between orgs uses OCapN over Unix domain sockets
;;; (Goblins 0.16.0+).
;;;
;;; TODO Shepherd×Goblins: when Shepherd is ported to Goblins, replace the
;;; forkexec constructor with a direct Goblins actor spawn within the
;;; Shepherd vat. The service will be a Goblins actor addressable over OCapN.
;;; At that point, ^service-capability in module/xorg/services.scm can
;;; reference the Shepherd actor directly instead of calling herd.

(define-module (xorg-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)   ;; for guile-goblins
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (xorg-configuration
            xorg-configuration?
            xorg-configuration-name
            xorg-configuration-entry-point
            xorg-configuration-socket-path
            xorg-configuration-user
            xorg-configuration-environment
            xorg-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <xorg-configuration>
  xorg-configuration make-xorg-configuration
  xorg-configuration?
  ;; Name of this org instance (used as shepherd service name)
  (name         xorg-configuration-name)
  ;; Path to the org entry-point script (a .scm file)
  (entry-point  xorg-configuration-entry-point)
  ;; Unix socket path for OCapN communication
  (socket-path  xorg-configuration-socket-path
                (default #f))
  ;; User to run as
  (user         xorg-configuration-user
                (default "xorg"))
  ;; Environment variables to pass (alist of string . string pairs)
  (environment  xorg-configuration-environment
                (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (xorg-shepherd-service config)
  "Generate a Shepherd service from an xorg-configuration record."
  (let* ((name        (xorg-configuration-name config))
         (entry       (xorg-configuration-entry-point config))
         (socket      (xorg-configuration-socket-path config))
         (user        (xorg-configuration-user config))
         (env         (xorg-configuration-environment config))
         (service-sym (string->symbol (string-append "xorg-" name))))
    (list
     (shepherd-service
      (provision (list service-sym))
      (documentation
       (string-append "xorg org instance: " name))
      (requirement '(networking user-processes))
      (start
       #~(make-forkexec-constructor
          (list #$(file-append guile-3.0 "/bin/guile") #$entry)
          #:user #$user
          #:environment-variables
          (append
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env))
           #$(if socket
                 #~(list (string-append "XORG_SOCKET=" #$socket))
                 #~'()))
          #:log-file #$(string-append "/var/log/xorg-" name ".log")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Accounts ──────────────────────────────────────────────────────────────
;;;
;;; The xorg service creates its own system user/group so it doesn't need
;;; to be defined separately in the operating-system (users ...) field.

(define (xorg-accounts config)
  "Create accounts for the user specified in CONFIG."
  (let ((user (xorg-configuration-user config)))
    (list (user-account
           (name user)
           (group "users")
           (system? #t)
           (home-directory (string-append "/var/lib/" user))
           (shell (file-append bash "/bin/bash"))))))

;;; ── Service type ───────────────────────────────────────────────────────────
;;;
;;; Usage in a Guix system declaration:
;;;
;;;   (service xorg-service-type
;;;            (xorg-configuration
;;;             (name "host")
;;;             (entry-point "/etc/xorg/host-entry.scm")
;;;             (socket-path "/run/xorg/host.sock")
;;;             (environment '(("OPENROUTER_API_KEY" . "sk-or-...")))))
;;;
;;; Multiple instances: use modify-services or append multiple
;;; (service xorg-service-type ...) entries, each with a unique name.

(define xorg-service-type
  (service-type
   (name 'xorg)
   (extensions
    (list (service-extension shepherd-root-service-type
                             xorg-shepherd-service)
          (service-extension account-service-type
                             xorg-accounts)))
   (description "Run an xorg org instance as a Shepherd service.")))
