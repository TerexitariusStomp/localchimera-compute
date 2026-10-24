;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/localchimera-static-service.scm — Shepherd service for the static/OOBI HTTP server
;;;
;;; Runs server/serve-static.scm, which owns ALL HTTP routing on the
;;; origin: static SPA serving, MIME types, SPA index fallback,
;;; security headers, KERI OOBI / .well-known/keri / .well-known/did
;;; endpoints, hidden-file deny, asset cache hints.
;;;
;;; Thin-nginx model:
;;;   nginx (443/80, TLS + CDN allowlist + rate limit + default 444)
;;;     → proxy_pass / → this service (127.0.0.1:8080)
;;;     → proxy_pass /ws → localchimera-gateway (127.0.0.1:9090)
;;;
;;; The only consumer of :8080 is nginx; bind localhost only.
;;;
;;; Usage in machines.scm:
;;;   (service localchimera-static-service-type
;;;            (localchimera-static-configuration
;;;             (package localchimera)
;;;             (port 8080)))

(define-module (localchimera-static-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (localchimera-static-configuration
            localchimera-static-configuration?
            localchimera-static-configuration-package
            localchimera-static-configuration-port
            localchimera-static-configuration-user
            localchimera-static-configuration-work-dir
            localchimera-static-configuration-oobi-dir
            localchimera-static-configuration-map-dir
            localchimera-static-configuration-operator
            localchimera-static-configuration-clearnet-ws
            localchimera-static-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <localchimera-static-configuration>
  localchimera-static-configuration make-localchimera-static-configuration
  localchimera-static-configuration?
  (package   localchimera-static-configuration-package)
  (port      localchimera-static-configuration-port      (default 8080))
  (user      localchimera-static-configuration-user      (default "localchimera"))
  ;; Directory of static assets (node.html, day-boot.wasm, etc.). Defaults
  ;; to the mutable checkout's browser/ so `rad pull` propagates.
  (work-dir  localchimera-static-configuration-work-dir
             (default "/home/localchimera/localchimera-repo/browser"))
  ;; ^oobi-host on-disk store. Same directory the gateway writes to.
  (oobi-dir  localchimera-static-configuration-oobi-dir
             (default "/var/lib/localchimera/oobi-host"))
  ;; The basemap's PMTiles archives (one per region, cut by
  ;; `MAP_DIR=… make map-tiles` on the box, like the Valhalla atlas).
  ;; Absolute, under the runtime state, rather than serve-static's default
  ;; relative `data/map` — which resolves against whatever directory the
  ;; service happens to exec in.
  (map-dir localchimera-static-configuration-map-dir
           (default "/var/lib/localchimera/map"))
  ;; Who runs this gateway, as (NAME . VALUE) environment pairs —
  ;; LOCALCHIMERA_OPERATOR_NAME, _CONTACT, … (deploy/os.scm builds them from the
  ;; provider config's `operator`). serve-static answers /operator.json and
  ;; /.well-known/security.txt from them; none set, the notices stay visibly
  ;; unfilled.
  (operator localchimera-static-configuration-operator
            (default '()))
  ;; The clearnet face this gateway advertises in /entry-points.json, e.g.
  ;; "wss://example.org/ws" — #f advertises none. There is no default: the
  ;; server never falls back to another deployment's address (deploy/os.scm
  ;; derives it from the provider config's clearnet-domain).
  (clearnet-ws localchimera-static-configuration-clearnet-ws
               (default #f)))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (localchimera-static-shepherd-service config)
  (let ((package    (localchimera-static-configuration-package config))
        (port       (localchimera-static-configuration-port config))
        (user       (localchimera-static-configuration-user config))
        (work-dir   (localchimera-static-configuration-work-dir config))
        (oobi-dir   (localchimera-static-configuration-oobi-dir config))
        (map-dir    (localchimera-static-configuration-map-dir config))
        (operator   (localchimera-static-configuration-operator config))
        (clearnet-ws (localchimera-static-configuration-clearnet-ws config)))
    (list
     (shepherd-service
      (provision '(localchimera-static))
      (documentation "localchimera origin HTTP server — SPA + KERI OOBI routes")
      (requirement '(networking user-processes))
      (start
       #~(let* ((mutable-dir "/home/localchimera/localchimera-repo")
                (store-dir   (string-append #$package "/share/localchimera"))
                (base        (if (file-exists? (string-append mutable-dir "/server"))
                                 mutable-dir store-dir))
                (guile       #$(file-append (@ (gnu packages guile) guile-next)
                                            "/bin/guile")))
           (make-forkexec-constructor
            (list guile
                  "--no-auto-compile"
                  "-L" (string-append base "/module")
                  "-L" (string-append base ".")
                  "-c" (string-append
                        "((@ (server serve-static) run-static-server) "
                        " #:work-dir \"" #$work-dir "\""
                        " #:oobi-dir \"" #$oobi-dir "\""
                        " #:port " #$(number->string port) ")"))
            #:user #$user
            #:directory base
            #:environment-variables
            (list (string-append "HOME=/home/" #$user)
                  ;; Must agree with the gateway's data-path resolution
                  ;; (gateway uses HOME=/var/lib/localchimera so its
                  ;; localchimera-state-dir is /var/lib/localchimera). serve-static
                  ;; reads snapshot files (federation-status.scm,
                  ;; peer-status.scm, pending-grants.scm) written by the
                  ;; gateway — without this var, localchimera-state-dir falls
                  ;; back to $HOME/.local/state/localchimera (under /home/
                  ;; localchimera) and every snapshot read returns #f, which
                  ;; turns each observability endpoint into a permanent
                  ;; "not yet booted" response.
                  "LOCALCHIMERA_STATE_DIR=/var/lib/localchimera"
                  (string-append "LOCALCHIMERA_MAP_DIR=" #$map-dir)
                  #$@(map (lambda (kv) (string-append (car kv) "=" (cdr kv)))
                          operator)
                  #$@(if clearnet-ws
                         #~(#$(string-append "LOCALCHIMERA_CLEARNET_WS=" clearnet-ws))
                         #~())
                  (string-append "GUILE_LOAD_PATH="
                                 "/run/current-system/profile/share/guile/site/3.0:"
                                 base "/module:"
                                 base)
                  (string-append "GUILE_LOAD_COMPILED_PATH="
                                 "/run/current-system/profile/lib/guile/3.0/site-ccache"))
            #:log-file "/var/log/localchimera/static.log")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (localchimera-static-activation config)
  "Ensure the OOBI and map directories exist and are owned by the runtime
user."
  (let ((oobi-dir   (localchimera-static-configuration-oobi-dir config))
        (map-dir    (localchimera-static-configuration-map-dir config))
        (user       (localchimera-static-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (for-each (lambda (dir)
                      (mkdir-p dir)
                      (chown dir (passwd:uid pw) (passwd:gid pw)))
                    (list #$oobi-dir #$map-dir))))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define localchimera-static-service-type
  (service-type
   (name 'localchimera-static)
   (extensions
    (list (service-extension shepherd-root-service-type
                             localchimera-static-shepherd-service)
          (service-extension activation-service-type
                             localchimera-static-activation)))
   (description "Run server/serve-static.scm as a Shepherd service.")))
