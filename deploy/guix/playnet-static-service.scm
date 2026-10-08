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
            playnet-static-configuration-tile-cache-dir
            playnet-static-configuration-tiles-tor?
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
  ;; Directory of SPA assets (index.html, repl.wasm, etc.). Defaults
  ;; to the mutable checkout's browser/ so `rad pull` propagates.
  (work-dir  playnet-static-configuration-work-dir
             (default "/home/playnet/playnet-repo/browser"))
  ;; ^oobi-host on-disk store. Same directory the gateway writes to.
  (oobi-dir  playnet-static-configuration-oobi-dir
             (default "/var/lib/playnet/oobi-host"))
  ;; Fetch-through cache for the /tiles basemap proxy. Absolute, and
  ;; alongside the rest of the runtime state under /var/lib/playnet,
  ;; rather than serve-static's default relative `data/tile-cache` —
  ;; which resolves against whatever directory the service happens to
  ;; exec in, and lands accumulated cache inside the checkout that every
  ;; push rsyncs.
  (tile-cache-dir playnet-static-configuration-tile-cache-dir
                  (default "/var/lib/playnet/tile-cache"))
  ;; Route upstream tile fetches through Tor. This box resolves no
  ;; clearnet DNS, so a direct fetch fails at name resolution; torsocks
  ;; carries both the lookup and the request, and keeps the origin's
  ;; address away from the tile upstream while it does.
  (tiles-tor? playnet-static-configuration-tiles-tor?
              (default #t))
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
        (tile-cache (playnet-static-configuration-tile-cache-dir config))
        (tiles-tor? (playnet-static-configuration-tiles-tor? config))
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
                  ;; The /tiles proxy fetches a cold tile by exec'ing curl,
                  ;; under torsocks when PLAYNET_TILES_TOR is set, and
                  ;; open-pipe* resolves both names on PATH. This list is
                  ;; the child's whole environment — with no PATH entry
                  ;; execvp falls back to a default that holds neither
                  ;; binary, and every cold tile answers 404.
                  (string-append
                   "PATH="
                   #$(file-append (@ (gnu packages curl) curl) "/bin") ":"
                   #$(file-append (@ (gnu packages tor) torsocks) "/bin"))
                  ;; That curl reaches an https upstream, and a store curl
                  ;; carries no CA bundle of its own — it reads one from the
                  ;; environment, which a login shell would normally supply.
                  ;; Absent these it rejects every tile with "server
                  ;; certificate verification failed. CAfile: none".
                  "SSL_CERT_DIR=/etc/ssl/certs"
                  "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
                  (string-append "PLAYNET_TILE_CACHE=" #$tile-cache)
                  #$@(if tiles-tor? #~("PLAYNET_TILES_TOR=1") #~())
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
            #:log-file "/var/log/playnet-static.log")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (playnet-static-activation config)
  "Ensure the OOBI and tile-cache directories exist and are owned by the
runtime user."
  (let ((oobi-dir   (playnet-static-configuration-oobi-dir config))
        (tile-cache (playnet-static-configuration-tile-cache-dir config))
        (user       (playnet-static-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (for-each (lambda (dir)
                      (mkdir-p dir)
                      (chown dir (passwd:uid pw) (passwd:gid pw)))
                    (list #$oobi-dir #$tile-cache))))))

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
