;;; deploy/guix/weave-service.scm — Shepherd service for the Weave HTTP server
;;;
;;; Usage in machines.scm:
;;;   (use-modules (weave-service))
;;;   (service weave-service-type
;;;            (weave-configuration
;;;             (package %playnet-package)
;;;             (port 8081)
;;;             (livekit-host "https://livekit.your-domain.com")
;;;             (livekit-ws-host "wss://livekit.your-domain.com")))

(define-module (weave-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (weave-configuration
            weave-configuration?
            weave-configuration-package
            weave-configuration-port
            weave-configuration-livekit-host
            weave-configuration-livekit-ws-host
            weave-configuration-environment
            weave-service-type))

;;; ── Configuration record ─────────────────────────────────────────────────────

(define-record-type* <weave-configuration>
  weave-configuration make-weave-configuration
  weave-configuration?
  (package         weave-configuration-package)
  (port            weave-configuration-port           (default 8081))
  (livekit-host    weave-configuration-livekit-host    (default "http://localhost:7880"))
  (livekit-ws-host weave-configuration-livekit-ws-host (default "ws://localhost:7880"))
  (user            weave-configuration-user            (default "playnet"))
  ;; Additional environment variables as alist of ("KEY" . "value")
  (environment     weave-configuration-environment     (default '())))

;;; ── Shepherd service ─────────────────────────────────────────────────────────

(define (weave-shepherd-service config)
  (let ((pkg      (weave-configuration-package config))
        (port     (weave-configuration-port config))
        (lk-host  (weave-configuration-livekit-host config))
        (lk-ws    (weave-configuration-livekit-ws-host config))
        (user     (weave-configuration-user config))
        (env      (weave-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(weave))
      (documentation "Weave HTTP server — meeting rooms, token API, browser assets")
      (requirement '(networking user-processes))
      (start
       #~(make-forkexec-constructor
          (list #$(file-append (@ (gnu packages guile) guile-3.0) "/bin/guile")
                "--no-auto-compile"
                "-L" (string-append #$pkg "/share/playnet/module")
                "-s" (string-append #$pkg "/share/playnet/server/weave.scm")
                #$(number->string port))
          #:user #$user
          #:directory (string-append #$pkg "/share/playnet")
          #:environment-variables
          (append
           (list (string-append "WEAVE_PORT="         #$(number->string port))
                 (string-append "LIVEKIT_HOST="        #$lk-host)
                 (string-append "LIVEKIT_WS_HOST="     #$lk-ws)
                 (string-append "HOME=/var/lib/"       #$user)
                 (string-append "GUILE_LOAD_PATH="
                                #$pkg "/share/playnet/module:"
                                "/run/current-system/profile/share/guile/site/3.0")
                 (string-append "GUILE_LOAD_COMPILED_PATH="
                                "/run/current-system/profile/lib/guile/3.0/site-ccache"))
           (list #$@(map (lambda (kv)
                           #~(string-append #$(car kv) "=" #$(cdr kv)))
                         env)))
          #:log-file "/var/log/weave.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define weave-service-type
  (service-type
   (name 'weave)
   (extensions
    (list (service-extension shepherd-root-service-type
                             weave-shepherd-service)))
   (description "Run the Weave HTTP server as a Shepherd service.")))
