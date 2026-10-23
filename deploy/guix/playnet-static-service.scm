;;; deploy/guix/playnet-static-service.scm — Shepherd service for the static/OOBI HTTP server
;;;
;;; Runs server/serve-static.scm, which owns ALL HTTP routing on the
;;; origin: static SPA serving, MIME types, SPA index fallback,
;;; security headers, KERI OOBI / .well-known/keri / .well-known/did
;;; endpoints, hidden-file deny, asset cache hints.
;;;
;;; Thin-nginx model:
;;;   nginx (443/80, TLS + CDN allowlist + rate limit + default 444)
;;;     → proxy_pass / → this service (127.0.0.1:8080)
;;;     → proxy_pass /ws → playnet-gateway (127.0.0.1:9090)
;;;
;;; The only consumer of :8080 is nginx; bind localhost only.
;;;
;;; Usage in machines.scm:
;;;   (service playnet-static-service-type
;;;            (playnet-static-configuration
;;;             (package playnet)
;;;             (port 8080)))

(define-module (playnet-static-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-static-configuration
            playnet-static-configuration?
            playnet-static-configuration-package
            playnet-static-configuration-port
            playnet-static-configuration-user
            playnet-static-configuration-work-dir
            playnet-static-configuration-oobi-dir
            playnet-static-configuration-map-dir
            playnet-static-configuration-operator
            playnet-static-configuration-clearnet-ws
            playnet-static-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <playnet-static-configuration>
  playnet-static-configuration make-playnet-static-configuration
  playnet-static-configuration?
  (package   playnet-static-configuration-package)
  (port      playnet-static-configuration-port      (default 8080))
  (user      playnet-static-configuration-user      (default "playnet"))
  ;; Directory of static assets (node.html, day-boot.wasm, etc.). Defaults
  ;; to the mutable checkout's browser/ so `rad pull` propagates.
  (work-dir  playnet-static-configuration-work-dir
             (default "/home/playnet/playnet-repo/browser"))
  ;; ^oobi-host on-disk store. Same directory the gateway writes to.
  (oobi-dir  playnet-static-configuration-oobi-dir
             (default "/var/lib/playnet/oobi-host"))
  ;; The basemap's PMTiles archives (one per region, cut by
  ;; `MAP_DIR=… make map-tiles` on the box, like the Valhalla atlas).
  ;; Absolute, under the runtime state, rather than serve-static's default
  ;; relative `data/map` — which resolves against whatever directory the
  ;; service happens to exec in.
  (map-dir playnet-static-configuration-map-dir
           (default "/var/lib/playnet/map"))
  ;; Who runs this gateway, as (NAME . VALUE) environment pairs —
  ;; PLAYNET_OPERATOR_NAME, _CONTACT, … (deploy/os.scm builds them from the
  ;; provider config's `operator`). serve-static answers /operator.json and
  ;; /.well-known/security.txt from them; none set, the notices stay visibly
  ;; unfilled.
  (operator playnet-static-configuration-operator
            (default '()))
  ;; The clearnet face this gateway advertises in /entry-points.json, e.g.
  ;; "wss://example.org/ws" — #f advertises none. There is no default: the
  ;; server never falls back to another deployment's address (deploy/os.scm
  ;; derives it from the provider config's clearnet-domain).
  (clearnet-ws playnet-static-configuration-clearnet-ws
               (default #f)))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (playnet-static-shepherd-service config)
  (let ((package    (playnet-static-configuration-package config))
        (port       (playnet-static-configuration-port config))
        (user       (playnet-static-configuration-user config))
        (work-dir   (playnet-static-configuration-work-dir config))
        (oobi-dir   (playnet-static-configuration-oobi-dir config))
        (map-dir    (playnet-static-configuration-map-dir config))
        (operator   (playnet-static-configuration-operator config))
        (clearnet-ws (playnet-static-configuration-clearnet-ws config)))
    (list
     (shepherd-service
      (provision '(playnet-static))
      (documentation "playnet origin HTTP server — SPA + KERI OOBI routes")
      (requirement '(networking user-processes))
      (start
       #~(let* ((mutable-dir "/home/playnet/playnet-repo")
                (store-dir   (string-append #$package "/share/playnet"))
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
                  ;; (gateway uses HOME=/var/lib/playnet so its
                  ;; playnet-state-dir is /var/lib/playnet). serve-static
                  ;; reads snapshot files (federation-status.scm,
                  ;; peer-status.scm, pending-grants.scm) written by the
                  ;; gateway — without this var, playnet-state-dir falls
                  ;; back to $HOME/.local/state/playnet (under /home/
                  ;; playnet) and every snapshot read returns #f, which
                  ;; turns each observability endpoint into a permanent
                  ;; "not yet booted" response.
                  "PLAYNET_STATE_DIR=/var/lib/playnet"
                  (string-append "PLAYNET_MAP_DIR=" #$map-dir)
                  #$@(map (lambda (kv) (string-append (car kv) "=" (cdr kv)))
                          operator)
                  #$@(if clearnet-ws
                         #~(#$(string-append "PLAYNET_CLEARNET_WS=" clearnet-ws))
                         #~())
                  (string-append "GUILE_LOAD_PATH="
                                 "/run/current-system/profile/share/guile/site/3.0:"
                                 base "/module:"
                                 base)
                  (string-append "GUILE_LOAD_COMPILED_PATH="
                                 "/run/current-system/profile/lib/guile/3.0/site-ccache"))
            #:log-file "/var/log/playnet/static.log")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (playnet-static-activation config)
  "Ensure the OOBI and map directories exist and are owned by the runtime
user."
  (let ((oobi-dir   (playnet-static-configuration-oobi-dir config))
        (map-dir    (playnet-static-configuration-map-dir config))
        (user       (playnet-static-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (for-each (lambda (dir)
                      (mkdir-p dir)
                      (chown dir (passwd:uid pw) (passwd:gid pw)))
                    (list #$oobi-dir #$map-dir))))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define playnet-static-service-type
  (service-type
   (name 'playnet-static)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-static-shepherd-service)
          (service-extension activation-service-type
                             playnet-static-activation)))
   (description "Run server/serve-static.scm as a Shepherd service.")))
