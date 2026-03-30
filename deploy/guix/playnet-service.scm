;;; deploy/guix/playnet-service.scm — Guix service type for playnet org processes
;;;
;;; Defines playnet-service-type: a Shepherd service that runs a Guile process
;;; hosting one or more playnet actors.
;;;
;;; Each org runs as a separate Shepherd service for isolation.
;;; Communication between orgs uses OCapN over Unix domain sockets
;;; (Goblins 0.16.0+).
;;;
;;; TODO Shepherd×Goblins: when Shepherd is ported to Goblins, replace the
;;; forkexec constructor with a direct Goblins actor spawn within the
;;; Shepherd vat. The service will be a Goblins actor addressable over OCapN.
;;; At that point, ^service-capability in module/playnet/services.scm can
;;; reference the Shepherd actor directly instead of calling herd.

(define-module (playnet-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages guile-xyz)   ;; for guile-goblins
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-configuration
            playnet-configuration?
            playnet-configuration-name
            playnet-configuration-entry-point
            playnet-configuration-socket-path
            playnet-configuration-user
            playnet-configuration-environment
            playnet-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <playnet-configuration>
  playnet-configuration make-playnet-configuration
  playnet-configuration?
  ;; Name of this org instance (used as shepherd service name)
  (name         playnet-configuration-name)
  ;; Path to the org entry-point script (a .scm file)
  (entry-point  playnet-configuration-entry-point)
  ;; Unix socket path for OCapN communication
  (socket-path  playnet-configuration-socket-path
                (default #f))
  ;; User to run as
  (user         playnet-configuration-user
                (default "playnet"))
  ;; Environment variables to pass (alist of string . string pairs)
  (environment  playnet-configuration-environment
                (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (playnet-shepherd-service config)
  "Generate a Shepherd service from an playnet-configuration record."
  (let* ((name        (playnet-configuration-name config))
         (entry       (playnet-configuration-entry-point config))
         (socket      (playnet-configuration-socket-path config))
         (user        (playnet-configuration-user config))
         (env         (playnet-configuration-environment config))
         (service-sym (string->symbol (string-append "playnet-" name))))
    (list
     (shepherd-service
      (provision (list service-sym))
      (documentation
       (string-append "playnet org instance: " name))
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
                 #~(list (string-append "PLAYNET_SOCKET=" #$socket))
                 #~'()))
          #:log-file #$(string-append "/var/log/playnet-" name ".log")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Accounts ──────────────────────────────────────────────────────────────
;;;
;;; The playnet service creates its own system user/group so it doesn't need
;;; to be defined separately in the operating-system (users ...) field.

(define (playnet-accounts config)
  "Create accounts for the user specified in CONFIG."
  (let ((user (playnet-configuration-user config)))
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
;;;   (service playnet-service-type
;;;            (playnet-configuration
;;;             (name "host")
;;;             (entry-point "/etc/playnet/host-entry.scm")
;;;             (socket-path "/run/playnet/host.sock")
;;;             (environment '(("OPENROUTER_API_KEY" . "sk-or-...")))))
;;;
;;; Multiple instances: use modify-services or append multiple
;;; (service playnet-service-type ...) entries, each with a unique name.

(define playnet-service-type
  (service-type
   (name 'playnet)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-shepherd-service)
          (service-extension account-service-type
                             playnet-accounts)))
   (description "Run an playnet org instance as a Shepherd service.")))
