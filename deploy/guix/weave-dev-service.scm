;;; deploy/guix/weave-dev-service.scm — Shepherd service for the Weave dev
;;; (live hacking) HTTP+REPL server.
;;;
;;; Companion to (weave-service); together they let the same Hetzner host
;;; serve both:
;;;
;;;   • the production Weave UI on port 8081 (the public weave-service), and
;;;   • a parallel "live hacking" instance on a loopback-only port that runs
;;;     the -g2 dev wasm bundle and the Hoot REPL relay.
;;;
;;; The dev service is intentionally:
;;;
;;;   • Loopback only      — there is no auth on the REPL relay; the only
;;;                          way to reach it from off-host is an SSH tunnel.
;;;   • Manual start       — auto-start? #f. The operator runs
;;;                            herd start weave-dev
;;;                          when they want to live-hack and stops it
;;;                          afterwards. Keeps the dev wasm out of the way
;;;                          of normal traffic.
;;;   • Independent state  — runs in its own vat (see server/weave-dev.scm),
;;;                          so dev rooms/meetings are *not* visible to the
;;;                          prod service and vice versa.
;;;
;;; A typical session from a developer laptop:
;;;
;;;   ssh playnet@playnet.host -L 8082:127.0.0.1:8082 \
;;;                            -L 37146:127.0.0.1:37146 \
;;;     'sudo herd start weave-dev'
;;;   # then, locally:
;;;   M-x geiser-hoot RET 127.0.0.1 RET 37146 RET
;;;   # browse to http://localhost:8082/weave.html in your browser
;;;
;;; Usage in machines.scm:
;;;   (use-modules (weave-dev-service))
;;;   (service weave-dev-service-type
;;;            (weave-dev-configuration
;;;             (package %playnet-package)))

(define-module (weave-dev-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages guile)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (weave-dev-configuration
            weave-dev-configuration?
            weave-dev-configuration-package
            weave-dev-configuration-port
            weave-dev-configuration-repl-port
            weave-dev-configuration-user
            weave-dev-configuration-environment
            weave-dev-service-type))

;;; ── Configuration record ─────────────────────────────────────────────────────

(define-record-type* <weave-dev-configuration>
  weave-dev-configuration make-weave-dev-configuration
  weave-dev-configuration?
  (package      weave-dev-configuration-package)
  (port         weave-dev-configuration-port      (default 8082))
  (repl-port    weave-dev-configuration-repl-port (default 37146))
  ;; Run as the live-hacking user, not the hardened playnet system user,
  ;; so the running session shares its home with the human operator.
  (user         weave-dev-configuration-user      (default "playnet"))
  (environment  weave-dev-configuration-environment (default '())))

;;; ── Shepherd service ─────────────────────────────────────────────────────────

(define (weave-dev-shepherd-service config)
  (let ((pkg       (weave-dev-configuration-package config))
        (port      (weave-dev-configuration-port config))
        (repl-port (weave-dev-configuration-repl-port config))
        (user      (weave-dev-configuration-user config))
        (env       (weave-dev-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(weave-dev))
      (documentation
       "Weave dev (live hacking) — HTTP on a loopback port + Hoot REPL relay")
      (requirement '(networking user-processes))
      (auto-start? #f) ;; manual-start: `herd start weave-dev`
      (start
       #~(make-forkexec-constructor
          (list #$(file-append guile-3.0 "/bin/guile")
                "--no-auto-compile"
                "-L" (string-append #$pkg "/share/playnet/module")
                "-s" (string-append #$pkg "/share/playnet/server/weave-dev.scm"))
          #:user #$user
          #:directory (string-append #$pkg "/share/playnet")
          #:environment-variables
          (append
           (list (string-append "WEAVE_DEV_PORT="      #$(number->string port))
                 (string-append "WEAVE_DEV_REPL_PORT=" #$(number->string repl-port))
                 (string-append "HOME=/home/" #$user)
                 ;; Pull in fibers/websocket/hoot from the system profile so
                 ;; (hoot web-server) can be loaded.
                 (string-append "GUILE_LOAD_PATH="
                                #$pkg "/share/playnet/module:"
                                "/run/current-system/profile/share/guile/site/3.0")
                 (string-append "GUILE_LOAD_COMPILED_PATH="
                                "/run/current-system/profile/lib/guile/3.0/site-ccache"))
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env)))
          #:log-file "/var/log/weave-dev.log"))
      (stop #~(make-kill-destructor))
      ;; Don't respawn — manual lifecycle. If the dev wasm crashes the
      ;; operator wants to know, not silently restart.
      (respawn? #f)))))

(define weave-dev-service-type
  (service-type
   (name 'weave-dev)
   (extensions
    (list (service-extension shepherd-root-service-type
                             weave-dev-shepherd-service)))
   (description
    "Run server/weave-dev.scm as a manual-start Shepherd service. Provides
the live-hacking HTTP server (loopback) and Hoot REPL relay listener for
Geiser.")))
