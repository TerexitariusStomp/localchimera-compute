;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/server-1/shepherd-init.scm — user-shepherd service definitions
;;;
;;; Loaded by the systemd user unit (shepherd.service). Lives in the user
;;; session; no privilege drops, no root-owned paths. State and logs under
;;; $HOME/.local/state/localchimera/.
;;;
;;; Services invoke their binaries through `guix shell -L deploy/guix -m
;;; <manifest>.scm -- <cmd>`. We don't pre-materialize a merged profile via
;;; `guix package -p` because python-keri + python-keria propagate
;;; conflicting python-marshmallow versions; guix shell resolves the
;;; collision at exec time but guix package refuses. install.sh warms the
;;; substitute cache so first start isn't slow.

(use-modules (shepherd service)
             (ice-9 match))

(define %home  (getenv "HOME"))
(define %repo  (string-append %home "/localchimera"))
(define %state (string-append %home "/.local/state/localchimera"))
(define %log   (string-append %state "/log"))

(define %guix     (string-append %home "/.config/guix/current/bin/guix"))
(define %radicle  (string-append %home "/.guix-profile/bin/radicle-node"))
(define %load-path (string-append %repo "/deploy/guix"))
(define %keri-mfst (string-append %repo "/deploy/manifests/keri-test-manifest.scm"))
(define %gw-mfst   (string-append %repo "/deploy/server-1/gateway-manifest.scm"))

(define (logfile name)
  (string-append %log "/" (symbol->string name) ".log"))

(define %xdg-runtime
  (or (getenv "XDG_RUNTIME_DIR")
      (string-append "/run/user/" (number->string (getuid)))))

(define %base-env
  (list (string-append "HOME=" %home)
        (string-append "XDG_RUNTIME_DIR=" %xdg-runtime)
        (string-append "PATH=" %home "/.guix-profile/bin:"
                               %home "/.config/guix/current/bin:/usr/bin:/bin")
        "LANG=en_US.UTF-8"
        "PYTHONUNBUFFERED=1"
        "PYTHONDONTWRITEBYTECODE=1"))

;; KERI tooling (kli witness, keria) walks $HOME/.keri/{ks,db,...} to find
;; the keystore + KEL. We provisioned those under $STATE/keria/.keri/ via
;; install.sh, so override HOME for KERI services. Anything not KERI keeps
;; HOME=/home/localchimera so guix shell, ssh-agent, etc. behave normally.
(define %keri-env
  (cons (string-append "HOME=" %state "/keria")
        (filter (lambda (s) (not (string-prefix? "HOME=" s))) %base-env)))

(define (in-shell manifest . args)
  "Build argv that invokes ARGS inside `guix shell -m MANIFEST`."
  (append (list %guix "shell" "-L" %load-path "-m" manifest "--") args))

;;; ── Witness pool ────────────────────────────────────────────────────────────
;; Six independent witness services with real per-witness keystores +
;; AIDs, mirroring deploy/guix/keria-service.scm. install.sh runs
;; `kli init` + `kli incept --alias N` once per witness on first deploy;
;; salts and AIDs persist at $STATE/keria/.keri/{ks,db}/<name>/. Stable
;; AIDs across restarts means clients holding our OOBI keep working.

;; Each witness needs distinct TCP + HTTP ports. Same scheme as keripy's
;; `kli witness demo`: TCP 5632–5637 paired with HTTP 5642–5647. Passing
;; the same port for both fails the second bind with "Address already in
;; use" — that's the source of the upstream service-type's silent failure
;; mode (it binds only one port and lets the second crash the process).
(define %witnesses
  '(("wan" 5632 5642)
    ("wil" 5633 5643)
    ("wes" 5634 5644)
    ("wit" 5635 5645)
    ("wub" 5636 5646)
    ("wyz" 5637 5647)))

(define (witness-symbol name)
  (string->symbol (string-append "keri-witness-" name)))

(define (witness-service name tcp-port http-port)
  (let ((sym (witness-symbol name)))
    (service
     (list sym)
     #:documentation
     (string-append "KERI witness " name
                    " (tcp " (number->string tcp-port)
                    " / http " (number->string http-port) ")")
     #:requirement '()
     #:respawn? #t
     #:start (apply make-forkexec-constructor
               (in-shell %keri-mfst
                         "kli" "witness" "start"
                         "--name"  name
                         "--alias" name
                         "-T" (number->string tcp-port)
                         "-H" (number->string http-port))
               #:environment-variables
               (cons (string-append "KERI_WITNESS_DIR=" %state "/witnesses")
                     %keri-env)
               #:directory (string-append %state "/keria")
               #:log-file (logfile sym)
               '())
     #:stop (make-kill-destructor))))

;;; ── Services ────────────────────────────────────────────────────────────────

(define radicle-node-svc
  (service
   '(radicle-node)
   #:documentation "Radicle P2P seed (native Tor proxy)"
   #:requirement '()
   #:respawn? #t
   #:start (make-forkexec-constructor
            (list %radicle "--listen" "0.0.0.0:8776" "--force")
            #:environment-variables
            (cons (string-append "RAD_HOME=" %home "/.radicle") %base-env)
            #:directory %home
            #:log-file (logfile 'radicle-node))
   #:stop (make-kill-destructor)))

(define keria-svc
  (service
   '(keria)
   #:documentation "KERIA cloud agent (admin 3901, http 3902, boot 3903)"
   #:requirement (map (lambda (e) (witness-symbol (car e))) %witnesses)
   #:respawn? #t
   #:start (apply make-forkexec-constructor
             (in-shell %keri-mfst
                       "keria" "start"
                       "--config-dir" (string-append %state "/keria/config")
                       "--config-file" "keria.json"
                       "--admin-http-port" "3901"
                       "--http"            "3902"
                       "--boot"            "3903")
             #:environment-variables
             (append (list (string-append "KERI_HOME=" %state "/keria")
                           (string-append "KERIA_PASSCODE="
                                          (or (getenv "KERIA_PASSCODE") "")))
                     %keri-env)
             #:directory (string-append %state "/keria")
             #:log-file (logfile 'keria)
             '())
   #:stop (make-kill-destructor)))

(define gateway-svc
  (service
   '(localchimera-gateway)
   #:documentation "localchimera OCapN gateway — WebSocket on 9090"
   #:requirement '(keria)
   #:respawn? #t
   #:start (apply make-forkexec-constructor
             (in-shell %gw-mfst
                       "torsocks" "guile" "--no-auto-compile"
                       "-L" (string-append %repo "/module")
                       "-s" (string-append %repo "/server/gateway.scm")
                       "--port" "9090")
             #:environment-variables
             (append
              (list (string-append "LOCALCHIMERA_DATA_DIR=" %state "/gateway")
                    "KERIA_AGENT_URL=http://localhost:3901"
                    "KERIA_BOOT_URL=http://localhost:3902"
                    ;; torsocks blocks listen() unless told the process needs
                    ;; to accept inbound connections. Gateway listens on
                    ;; 0.0.0.0:9090, so this is required.
                    "TORSOCKS_ALLOW_INBOUND=1"
                    (string-append "GUILE_LOAD_PATH=" %repo "/module"))
              %base-env)
             #:directory %repo
             #:log-file (logfile 'localchimera-gateway)
             '())
   #:stop (make-kill-destructor)))

(define static-svc
  (service
   '(localchimera-static)
   #:documentation "Static HTTP server for browser REPL (port 8080)"
   #:requirement '()
   #:respawn? #t
   #:start (apply make-forkexec-constructor
             (in-shell %gw-mfst
                       "guile" "--no-auto-compile"
                       "-L" %repo "-L" (string-append %repo "/module")
                       "-c"
                       (string-append
                        "((@ (server serve-static) run-static-server) "
                        "  #:work-dir \"" %repo "/browser\""
                        "  #:oobi-dir \"" %repo "/data/oobi-host\""
                        "  #:port 8080)"))
             #:environment-variables %base-env
             #:directory %repo
             #:log-file (logfile 'localchimera-static)
             '())
   #:stop (make-kill-destructor)))

;;; ── Register + start ────────────────────────────────────────────────────────

(register-services
 (append (map (match-lambda ((n t h) (witness-service n t h))) %witnesses)
         (list radicle-node-svc
               keria-svc
               gateway-svc
               static-svc)))

(for-each start-in-the-background
          (append (map (lambda (e) (witness-symbol (car e))) %witnesses)
                  '(radicle-node keria localchimera-gateway localchimera-static)))
