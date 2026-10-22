;;; deploy/os.scm — operating-system value, source of truth
;;;
;;; The entire operating-system declaration + every helper it needs
;;; (provider lookup, nginx locations, packages, users, services,
;;; …) lives in this file. The final top-level expression is
;;; `%guix-x86`, so the file evaluates to an <operating-system>
;;; record. That makes two flows work from one source:
;;;
;;;   guix system reconfigure  …  deploy/os.scm        (server-side)
;;;   guix deploy             …  deploy/machines.scm  (laptop-side)
;;;
;;; machines.scm `primitive-load`s this file, which both makes
;;; `%guix-x86` available to wrap in <machine> AND keeps every helper
;;; (e.g. %provider, provider-ref, %fleet-machines deps) in scope.
;;;
;;; Why split? `guix system reconfigure` and `guix deploy` each
;;; add their own provenance-service-type instance. If os.scm
;;; unwrapped from a <machine> built by machines.scm,
;;; `operating-system-with-provenance` already ran once →
;;; reconfigure ran it again → two `provenance` files in the
;;; system-builder → "symlink: File exists" at the last step.
;;; Owning the plain OS in os.scm keeps each tool adding exactly
;;; one. See git log of this file for the failure mode.

(use-modules (gnu machine)
             (gnu machine ssh)
             (gnu packages admin)
             (gnu packages bash)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages tls)        ; guile-gnutls (for DDNS updater)
             (gnu packages linux)   ; inotify-tools
             (srfi srfi-13)         ; string-prefix? — %playnet-rid-bare
             (sev-kernel)               ; linux-libre-sev — AMD SEV-SNP guest kernel
             (gnu packages finance)      ; monero (monerod, monero-wallet-rpc)
             (gnu packages golang-crypto) ; age, age-plugin-yubikey
             (gnu packages tor)             ; torsocks (torify wrapper for Tor SOCKS5)
             (gnu packages golang-web)     ; lyrebird (obfs4 Tor pluggable transport)
             (gnu services vpn)           ; wireguard-service-type
             (gnu packages security-token) ; libfido2 (YubiKey udev rules)
             (gnu packages messaging)
             (gnu packages mail)            ; msmtp — hands the commune's mail to its relay
             (gnu packages rsync)
             (gnu packages curl)            ; curl — operator HTTP checks (torsocks-wrapped)
             (gnu packages base)            ; gnu-make — CI wasm rebuild (`make browser/repl.wasm`)
             (gnu packages commencement)    ; gcc-toolchain — planner kernel build (`make -C module/playnet/solve/kernel`)
             (gnu packages rust-apps)       ; radicle
             (gnu packages version-control)
             (gnu packages ssh)
             (playnet-hoot) ; guile-hoot/playnet — Hoot 0.9.0 + upstream number->string fixes
             (opencode)  ; agentic coding CLI for dev-bridge (pinned prebuilt binary)
             (playnet-keys) ; single source of truth for operator/CI pubkeys
             (rns-bridge)
             (radicle-service)
             (radicle-httpd-service)
             (radicle-http-api-service)
             (radicle-ci-broker-service)
             (reticulum-service)
             (keria-service)
             (monero-service)
             (wallet-service)
             (fleet-reconciler-service)
             (fleet-keeper-service)
             (deploy-runner-service)
             (backup-service)            ; playnet-backup-service-type
              (gnu services base)
              (gnu services admin)       ; log-rotation-service-type
              (gnu services mcron)        ; required by backup-service-type
             (gnu services networking)  ;; also provides tor-service-type
             (gnu services shepherd)
             (gnu services ssh)
             (gnu services web)
             (gnu system linux-initrd)
             (gnu)
             (guix gexp)
             (playnet-gateway-service)
             (playnet-static-service)
             (playnet-valhalla-service)
              (live-watch-service))

(define %this-dir
  (dirname (or (current-filename)
               (canonicalize-path "deploy/machines.scm"))))

;; Load local secrets if available (API keys, passcodes, tokens).
;; Evaluated at deploy time only — never enters the Guix store.
;; See deploy/guix/secrets.scm.example for the template.
(let ((secrets (string-append %this-dir "/secrets.scm")))
  (when (file-exists? secrets)
    (primitive-load secrets)))

;; Load provider-specific hardware config (IP, disk layout, bootloader).
;; Provider configs are gitignored — they contain server IPs.
;; Set PLAYNET_PROVIDER before deploying:
;;   PLAYNET_PROVIDER=deploy/providers/iceland.scm bash deploy/scripts/reconfigure.sh
(define %provider
  (let ((provider-file (getenv "PLAYNET_PROVIDER")))
    (unless provider-file
      (error "Set PLAYNET_PROVIDER to a provider config file, e.g.:\n  export PLAYNET_PROVIDER=deploy/providers/iceland.scm"))
    (primitive-load provider-file)))

(define (provider-ref key)
  "Look up KEY in the provider config alist."
  (assq-ref %provider key))

;; Hosting credentials this box's fleet holds, as the names they carry in
;; secrets.scm. The provider config lists them (`fleet-credentials`), so the
;; tracked tree stays the same for every deployment. Each becomes a
;; /run/secrets file the gateway reads into its environment at start.
(define %fleet-credential-vars
  (or (provider-ref 'fleet-credentials) '()))

(define (%secret-file-for var)
  "VAR's runtime file: FOO_API_KEY → /run/secrets/foo-api-key."
  (string-append "/run/secrets/"
                 (string-map (lambda (c) (if (char=? c #\_) #\- c))
                             (string-downcase var))))

;; The relay this box hands its mail to: the provider config's `mail` alist
;; (host, port, user, from), or #f for a box that sends none. msmtp logs in to
;; the relay on its submission port and the relay delivers; the account's
;; password is SMTP_PASSWORD in secrets.scm, decrypted to
;; /run/secrets/smtp-password. With a relay named, the gateway offers email
;; as a channel a person may be notified on (interface/adapters/email.scm).
;; A `mail` that names no host, or whose host, user or sender is not text, is
;; refused here, as the system is evaluated: the gateway's environment is
;; built from these, and a value that is not a string stops it at start.
(define %mail
  (let ((mail (provider-ref 'mail)))
    (when mail
      (unless (string? (assq-ref mail 'host))
        (error "provider config: (mail …) names its relay: (host . \"smtp.example.org\")"))
      (for-each (lambda (key)
                  (let ((v (assq-ref mail key)))
                    (unless (or (not v) (string? v))
                      (error "provider config: (mail …) field is text" key v))))
                '(user from))
      (let ((port (assq-ref mail 'port)))
        (unless (or (not port) (number? port) (string? port))
          (error "provider config: (mail …) port is a number" port))))
    mail))
;; Who runs this gateway: the provider config's `operator` alist — name,
;; contact, abuse, privacy, security, jurisdiction, address, supervisory,
;; representative, source, docs, every one optional text (see deploy/providers/example.scm).
;; They become PLAYNET_OPERATOR_<KEY> in the static server's environment, which
;; answers /operator.json (the notices) and /.well-known/security.txt from
;; them. A value that is not text is refused here, as the system is evaluated.
(define %operator-keys
  ;; the same fields as %operator-fields in module/playnet/utils/operator.scm
  ;; (tests/server/test-operator-endpoint.scm holds the two together)
  '(name contact abuse privacy security jurisdiction address supervisory representative
    source docs))
(define (%operator-environment)
  (let ((op (or (provider-ref 'operator) '())))
    (for-each (lambda (kv)
                (unless (memq (car kv) %operator-keys)
                  (error "provider config: (operator …) has an unknown field" (car kv)))
                (unless (string? (cdr kv))
                  (error "provider config: (operator …) field is text" (car kv) (cdr kv))))
              op)
    (map (lambda (kv)
           (cons (string-append "PLAYNET_OPERATOR_" (string-upcase (symbol->string (car kv))))
                 (cdr kv)))
         op)))
(define %smtp-password-file "/run/secrets/smtp-password")
(define (%mail-environment)
  "The gateway's environment for the relay, as (NAME . VALUE) pairs."
  (if (not %mail)
      '()
      (let ((ref (lambda (key) (assq-ref %mail key))))
        `(("PLAYNET_SMTP_HOST" . ,(ref 'host))
          ("PLAYNET_SMTP_PORT" . ,(let ((p (or (ref 'port) 587)))
                                    (if (number? p) (number->string p) p)))
          ,@(if (ref 'user)
                `(("PLAYNET_SMTP_USER" . ,(ref 'user))
                  ("PLAYNET_SMTP_PASSWORD_FILE" . ,%smtp-password-file))
                '())
          ,@(if (ref 'from) `(("SMTP_FROM" . ,(ref 'from))) '())))))

;; Radicle project ID for this deployment. The radicle-ci hook clones
;; from this RID and watches for ref-update events. Set after `rad init`.
;; Falls back to the provider config's `radicle-rid` so multiple
;; deployments can share secrets.scm but pin different projects.
(define %playnet-rid
  (or (getenv "PLAYNET_RID")
      (provider-ref 'radicle-rid)
      (error "Set PLAYNET_RID env var or add (radicle-rid . \"rad:...\") to your provider config")))

;; git URL paths (…/<rid>.git/…) want the bare id — Radicle's own "rad:"
;; scheme prefix isn't part of the git-smart-HTTP convention.
(define %playnet-rid-bare
  (if (string-prefix? "rad:" %playnet-rid)
      (substring %playnet-rid 4)
      %playnet-rid))

;; Satellite repos the core pins (deploy/satellites.scm): each gets the same
;; git-smart-HTTP mirror route as the core, at /<rid-bare>.git, and the
;; node's seed-rids-all below is derived from the same list, so a pin with a
;; rid is both the route and the seed. Bare ids, no "rad:" prefix.
(define %playnet-satellite-rids-bare
  ;; Read from deploy/satellites.scm — the one place a satellite is named.
  ;; A pin without a rid (not on Radicle yet) has no route and no seed.
  (let* ((pins-file (string-append %this-dir "/satellites.scm"))
         (pins (call-with-input-file pins-file
                 (lambda (p)
                   (let loop ((form (read p)) (last #f))
                     (if (eof-object? form)
                         (eval last (current-module))
                         (loop (read p) form)))))))
    ;; core bindings only: os.scm imports srfi-13 alone, and reconfigure
    ;; forces this without srfi-1 in scope (the append-map lesson)
    (filter (lambda (x) x)
            (map (lambda (pin)
                   (let ((rid (assq-ref pin 'rid)))
                     (and rid (if (string-prefix? "rad:" rid) (substring rid 4) rid))))
                 pins))))

;; The mirror locations for the core and every satellite, in one list.
(define (%playnet-all-git-mirror-locations)
  ;; (apply append (map …)) rather than append-map: os.scm's imports carry
  ;; srfi-13 only, and `guix system reconfigure` forces this thunk without
  ;; srfi-1 in scope (machines.scm imports it after the load, which is why
  ;; laptop `guix deploy` would not have shown the failure).
  (apply append (map %playnet-git-mirror-locations
                     (cons %playnet-rid-bare %playnet-satellite-rids-bare))))

;; Optional clearnet domain — #f means onion-only (no nginx HTTPS).
;; When set, origin uses a self-signed cert (the CDN pulls with SSL
;; verification disabled). No Let's Encrypt, no CT log exposure.
(define %clearnet-domain (provider-ref 'clearnet-domain))

;; CDN edge IP ranges — only these IPs reach the origin on 443.
;; All other traffic hits a default_server that returns 444 (silent drop).
;; Per docs/deploy/CLEARNET-FACES.md §Architecture. The ranges are the ones
;; the deployment's CDN publishes, stated in the provider config:
;;   (cdn-edge-ips . ("1.2.3.0/24" "2001:db8::/48"))
(define %cdn-edge-ips
  (let ((ips (or (provider-ref 'cdn-edge-ips) '())))
    (when (and %clearnet-domain (null? ips))
      (error "clearnet-domain is set: add (cdn-edge-ips . (...)) to the provider config — the origin admits the CDN's edges and nobody else"))
    ips))

;; This deployment's CDN account, from the provider config's `cdn` entry:
;;   (cdn . ((adapter . "NAME")            ; (playnet fleet cdn NAME)
;;           (credential . "VAR")          ; its name in secrets.scm
;;           (zone . "ID")
;;           (origin . "https://example.org")))
;; The key is decrypted to %cdn-key-file; the rest is written to
;; /etc/playnet/cdn.conf, which deploy/scripts/cdn.scm and the fleet read.
(define %cdn (provider-ref 'cdn))
(define %cdn-key-file "/run/secrets/cdn-api-key")

;; ── HTTP-context directives (single source of truth) ─────────────────────
;; limit_req_zone / limit_conn_zone MUST live in the http{} context, not
;; in a server block. Wired in via nginx-configuration's `extra-content`
;; below (see the (service nginx-service-type ...) instance).
;;
;; Zones (one definition, referenced from multiple locations):
;;   playnet_req   — per-client request rate (50 req/s sustained, burst
;;                   tuned per-location). Covers /oobi, /.well-known/keri, /ws.
;;   playnet_conn  — per-client concurrent connections (32). Coarse DoS guard.
;;
;; The limit key is $playnet_client, not $binary_remote_addr. On the
;; clearnet face every request arrives from a CDN edge IP, so
;; $binary_remote_addr is the same handful of addresses for the entire
;; world: one shared token bucket for all visitors. A single cold page
;; load is ~60 requests (app.html pulls the whole app/*.js module graph
;; in one go), so the shared bucket drains on the first visitor and the
;; rest of that load — vendor/noble/*.js among them — comes back 503 with
;; an HTML error body, which the browser rejects as a disallowed MIME
;; type for a module import.
;;
;; $playnet_client resolves to the forwarded client address when the
;; connection comes from a CDN edge, and to the peer address otherwise.
;; X-Forwarded-For is honoured only for peers in %cdn-edge-ips — the
;; same allowlist that gates :443 — so a direct or onion client cannot
;; mint itself a fresh bucket by setting the header. (ngx_http_realip_module
;; is absent from this nginx build; geo + map are always compiled in and
;; take the CIDRs verbatim.)
;;
;; The onion face keys on 127.0.0.1 for every Tor visitor — the hidden
;; service hands nginx a loopback peer and no forwarded address exists to
;; recover the real one. Onion traffic therefore shares one bucket by
;; construction; the rate/burst below are sized so several concurrent cold
;; loads fit inside it.
;;
;; Rate-limit story across the codebase:
;;   - Client side (handling upstream 429): ai/key-pool.scm classifies
;;     'rate-limited, fleet/vpsbg.scm retries with backoff.
;;   - Server side (this): nginx limit_req at the edge.
;; A single zone name keeps things uniform — extend by adding more
;; `limit_req zone=playnet_req burst=…;` references, not new zones.
;;
;; The exception, and the reason it IS one: both limiter modules keep their
;; STATE per (zone, key) and share it across every location naming that zone;
;; only the threshold is per-directive. So a location asking for a smaller
;; number out of a shared zone does not get a smaller private budget — it
;; becomes the first thing refused once anyone's ordinary traffic has filled
;; the shared bucket. A surface that must be limited SEPARATELY therefore
;; needs a zone of its own, and `playnet_feedback` is the one such surface:
;; anonymous, unauthenticated writes, which are exactly what must not be able
;; to spend the app's budget, and exactly what must not be starved by it.
;; This matters most on the onion face, where $playnet_client collapses every
;; Tor visitor onto one key — a per-connection cap out of the shared zone
;; would go permanently closed once a handful of dials were open.
(define %playnet-nginx-http-content
  (string-append
   "geo $playnet_from_cdn {\n"
   "    default 0;\n"
   (string-join (map (lambda (cidr)
                       (string-append "    " cidr " 1;"))
                     %cdn-edge-ips)
                "\n" 'suffix)
   "}\n"
   "map $playnet_from_cdn $playnet_fwd {\n"
   "    0 \"\";\n"
   "    1 $http_x_forwarded_for;\n"
   "}\n"
   ;; The forwarded value is a hop list ("visitor, proxy, …") whenever more
   ;; than one proxy stood in the way; the visitor is its FIRST address, so
   ;; that is the key — the whole string would make every distinct path
   ;; through the edges a distinct bucket for one visitor, and none for
   ;; two visitors behind one path.
   "map $playnet_fwd $playnet_client {\n"
   "    \"\"                        $binary_remote_addr;\n"
   "    ~^\\s*(?<playnet_hop>[^,\\s]+)  $playnet_hop;\n"
   "    default                   $playnet_fwd;\n"
   "}\n"
   "limit_req_zone $playnet_client zone=playnet_req:10m rate=50r/s;\n"
   "limit_conn_zone $playnet_client zone=playnet_conn:10m;\n"
   ;; Anonymous feedback writes, budgeted apart from the app (see above).
   ;; A person types feedback at human speed, so a slow sustained rate with
   ;; a small burst is generous for the real use and cheap for a flood.
   "limit_req_zone $playnet_client zone=playnet_feedback:1m rate=6r/m;\n"
   ;; Reports of unlawful or harmful content: a pool of their own and so a
   ;; zone of their own, for the same reason — a flood of feedback must not
   ;; close the door a person uses to report a child at risk, nor the reverse.
   "limit_req_zone $playnet_client zone=playnet_report:1m rate=6r/m;\n"))

;; Shared nginx locations — used by both the onion (port 80) and
;; clearnet (port 443) server blocks.
;;
;; Thin-nginx model: nginx owns TLS, the CDN IP allowlist, the
;; default-server 444 tarpit, rate limiting, and proxies *everything
;; else* to serve-static.scm (port 8080) or the OCapN gateway (9090).
;; Application-level concerns — MIME types, SPA index fallback,
;; security headers, Cache-Control on KERI routes, hidden-file deny,
;; static-asset cache hints — live in server/serve-static.scm.
;;
;; Adding a new HTTP route used to require: edit serve-static + edit
;; nginx + `guix system reconfigure`. Now it's just edit serve-static
;; and restart the playnet-gateway service. Faster inner loop, single
;; source of truth.
(define %playnet-locations
  (list
   ;; WebSocket → OCapN gateway. Separate from the catch-all because
   ;; nginx WebSocket upgrade requires its own Upgrade/Connection
   ;; header dance.
   ;; The HTTP door (module/playnet/doors/http.scm): POST
   ;; /api/{lobby,session,planner}/<name>, signed by an enrolled device key,
   ;; answered by the gateway process on loopback :9091. Prefix matches, so
   ;; /api/docs/, /api/openapi.json, /api/mcp-tools.json stay static files
   ;; and /api/v1 stays the Radicle http-api below. /api/mcp is the same
   ;; doors as MCP tools (module/playnet/doors/mcp.scm), JSON-RPC.
   (nginx-location-configuration
    (uri "= /api/mcp")
    (body '("proxy_pass http://127.0.0.1:9091;"
            "proxy_set_header Host $host;"
            "proxy_read_timeout 30;"
            "limit_req zone=playnet_req burst=20 nodelay;")))
   (nginx-location-configuration
    (uri "^~ /api/lobby/")
    (body '("proxy_pass http://127.0.0.1:9091;"
            "proxy_set_header Host $host;"
            "proxy_read_timeout 30;"
            "limit_req zone=playnet_req burst=20 nodelay;")))
   (nginx-location-configuration
    (uri "^~ /api/session/")
    (body '("proxy_pass http://127.0.0.1:9091;"
            "proxy_set_header Host $host;"
            "proxy_read_timeout 30;"
            "limit_req zone=playnet_req burst=20 nodelay;")))
   (nginx-location-configuration
    (uri "^~ /api/planner/")
    (body '("proxy_pass http://127.0.0.1:9091;"
            "proxy_set_header Host $host;"
            "proxy_read_timeout 30;"
            "limit_req zone=playnet_req burst=20 nodelay;")))
   (nginx-location-configuration
    (uri "/ws")
    (body '("proxy_pass http://127.0.0.1:9090;"
            "proxy_http_version 1.1;"
            "proxy_set_header Upgrade $http_upgrade;"
            "proxy_set_header Connection \"upgrade\";"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 3600;"
            "client_max_body_size 2m;"
            ;; WebSocket upgrade itself is one request — burst absorbs
            ;; reconnect storms.
            "limit_req zone=playnet_req burst=10 nodelay;"
            "limit_conn playnet_conn 32;")))
   ;; Radicle HTTP API → the write fork (radicle-http-api, :8089). Backs the
   ;; Radicle Explorer (served at /radicle/) and the Planning Boards (/boards/):
   ;; repo/issue/patch reads for everyone, session-gated writes for operators
   ;; (sessions require the node key). Separate location so the boards' larger
   ;; JSON bodies and longer reads don't inherit the SPA limits below.
   ;;
   ;; EXACT-match the API root: the interface's getNodeInfo() probes
   ;; `/api/v1` (no trailing slash) for the node welcome/version. The fork
   ;; serves that at `/api/v1` but 404s `/api/v1/`; and the prefix location
   ;; below (defined WITH a trailing slash) doesn't match bare `/api/v1`, so
   ;; nginx 301-redirects it to `/api/v1/` → the fork 404 → the Explorer's
   ;; "Could not load this view". Route bare `/api/v1` straight to the fork's
   ;; `/api/v1` so the probe succeeds.
   (nginx-location-configuration
    (uri "= /api/v1")
    (body '("proxy_pass http://127.0.0.1:8089/api/v1;"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 120;"
            "limit_req zone=playnet_req burst=40 nodelay;"
            "limit_conn playnet_conn 32;")))
   (nginx-location-configuration
    (uri "/api/v1/")
    (body '("proxy_pass http://127.0.0.1:8089;"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 120;"
            "client_max_body_size 8m;"
            "limit_req zone=playnet_req burst=40 nodelay;"
            "limit_conn playnet_conn 32;")))
   ;; Raw repo content (the Explorer loads README images + raw blobs from
   ;; the seed's `/raw/<rid>/<sha>/<path>`). The fork serves this at :8089;
   ;; without this route it falls through to serve-static, which 404s slowly
   ;; (≈60s) → nginx 504 on every README image.
   (nginx-location-configuration
    (uri "/raw/")
    (body '("proxy_pass http://127.0.0.1:8089;"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 120;"
            "limit_req zone=playnet_req burst=40 nodelay;"
            "limit_conn playnet_conn 32;")))
   ;; Planning Boards SPA (/boards/) — serve directly from disk with a
   ;; try_files fallback to the Nuxt index. Routing it through serve-static
   ;; hangs Guile's web server on the board iframe URL
   ;; (/boards/<seed:port>/<long-rid>): a parser pathology on that path
   ;; shape that hangs BEFORE the request reaches our handler (proven by
   ;; instrumentation — serve-static-file is never called). nginx's static
   ;; serving is deterministic and reads the playnet-repo tree directly
   ;; (dirs 0711/0775, files 0644 — readable by the nginx worker). The Nuxt
   ;; app reads the real route from window.location client-side.
   (nginx-location-configuration
    (uri "/boards/")
    (body (list "root /home/playnet/playnet-repo/browser;"
                "try_files $uri $uri/ /boards/index.html;"
                "add_header X-Frame-Options SAMEORIGIN;")))
   ;; The anonymous feedback pool (tier 1 of the issue flow): no account, no
   ;; signature, so the edge is where cost is imposed. It draws on its OWN
   ;; zone, `playnet_feedback` — the app's zone is shared state, so spending
   ;; from it here would let ordinary page loads close this endpoint (and on
   ;; the onion face, where all visitors share one key, close it for good).
   ;; The body cap matches the handler's own 256 KB, so an oversized
   ;; screenshot is refused at the edge rather than carried into the Guile
   ;; server to be rejected there. No limit_conn: a POST is not long-lived,
   ;; and the only conn zone is the shared one.
   (nginx-location-configuration
    (uri "= /feedback")
    (body '("proxy_pass http://127.0.0.1:8080;"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 60;"
            "client_max_body_size 256k;"
            ;; ~6/min sustained, 12 in hand — a person sending feedback
            ;; never notices; a script does immediately
            "limit_req zone=playnet_feedback burst=12 nodelay;")))
   ;; Reports (terms §7.2): the same shape as feedback, its own zone and its
   ;; own, smaller body cap — a report is text only (the handler's 16 KB).
   (nginx-location-configuration
    (uri "= /report")
    (body '("proxy_pass http://127.0.0.1:8080;"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 60;"
            "client_max_body_size 16k;"
            "limit_req zone=playnet_report burst=12 nodelay;")))
   ;; Everything else → serve-static.scm. The Guile server owns
   ;; routing, SPA fallback, MIME types, Cache-Control on KERI
   ;; endpoints, security headers — see server/serve-static.scm.
   (nginx-location-configuration
    (uri "/")
    (body '("proxy_pass http://127.0.0.1:8080;"
            "proxy_set_header Host $host;"
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            "proxy_read_timeout 60;"
            ;; The whole app comes through here. app.html imports the
            ;; app/*.js module graph plus vendor/noble/*.js in one
            ;; parallel fan-out — ~60 requests inside a second, before
            ;; any of them can drain the bucket at the sustained rate.
            ;; The burst holds a few such cold loads at once (the onion
            ;; face shares one bucket across all Tor visitors); anything
            ;; sustained past that is what limit_conn is for.
            ;;
            ;; limit_conn counts CONNECTIONS, and the CDN edge carries a
            ;; visitor's fan-out to the origin over parallel HTTP/1.1
            ;; connections — the ~60 of a cold load all at once, which a
            ;; cap of 32 refused: the first page load after every deploy's
            ;; purge (a cold edge) got 503s on half its modules and the
            ;; dynamic import failed; the next load, off a warm edge, was
            ;; fine (2026-09-23, nginx error.log "limiting connections by
            ;; zone playnet_conn"). 160 holds two cold loads from one
            ;; visitor with room; the request rate above is the guard
            ;; against anything sustained.
            "limit_req zone=playnet_req burst=300 nodelay;"
            "limit_conn playnet_conn 160;")))))

;; Onion-ONLY git-smart-HTTP mirror of this repo, for `guix pull`/`guix
;; deploy` to fetch the `playnet` channel without depending on a third-party
;; Radicle↔git gateway. The prior third-party gateway (deploy/channels.scm's
;; playnet channel URL, historically) went stale: this node's own connection
;; to it never came up (`rad node status` shows it as "attempted", not
;; connected), and every other public gateway checked served the same
;; unrelated, unreachable-from-here commit — not a staleness problem, an
;; absent one.
;;
;; radicle-http-api (already running, already backing the Explorer's
;; /api/v1 and /raw/) speaks ordinary git-smart-HTTP for the repos it seeds,
;; confirmed directly: `GET /<rid>.git/info/refs?service=git-upload-pack`
;; returns the real refs. These two locations expose exactly that — nothing
;; the fork might also route under `.git/` (a receive-pack push endpoint,
;; if one exists) is reachable, because each is an EXACT match on one path,
;; not a prefix. Read-only, by construction, not by trust in the backend.
;;
;; Kept OUT of %playnet-locations (the shared list) and appended to each
;; server block explicitly instead — onion always, clearnet only where a
;; domain is configured — so which faces carry it stays a decision made
;; here, not a side effect of sharing a list. No new identifying
;; information either way: the RID this exposes is already public in the
;; committed channels.scm and already served (read-only) by the existing
;; /api/v1 and /raw/ routes, on these same server blocks.
(define (%playnet-git-mirror-locations rid-bare)
  (list
   (nginx-location-configuration
    (uri (string-append "= /" rid-bare ".git/info/refs"))
    (body '("proxy_pass http://127.0.0.1:8089;"
            "proxy_set_header Host $host;"
            "proxy_read_timeout 60;"
            "limit_req zone=playnet_req burst=10 nodelay;"
            "limit_conn playnet_conn 8;")))
   (nginx-location-configuration
    (uri (string-append "= /" rid-bare ".git/git-upload-pack"))
    (body '("proxy_pass http://127.0.0.1:8089;"
            "proxy_set_header Host $host;"
            "proxy_set_header Content-Type $content_type;"
            "proxy_read_timeout 120;"
            "client_max_body_size 4m;"
            "limit_req zone=playnet_req burst=10 nodelay;"
            "limit_conn playnet_conn 8;")))))

;; nginx-level raw-content. Kept minimal: the security headers /
;; cache-control / hidden-file deny moved into serve-static.scm where
;; they apply uniformly to all routes. What stays here is anything
;; that nginx must enforce *before* hitting the upstream.
(define %playnet-security-headers '())

;; Load the playnet package from guix.scm (provides bin/meta-org-relay)
(define %playnet-package
  (load (string-append %this-dir "/../guix.scm")))

;; Three SSH key roles for least-privilege access control:
;;
;;   operator — interactive SSH + REPL access on the playnet user.
;;              Lives on the operator's personal machine.
;;   deploy   — used exclusively by `guix deploy`. Can push system
;;              configs but not access the REPL or wallet.
;;              Generate: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_deploy
;;   ci       — automated deploy from CI/CD. Same access as deploy.
;;
;; TODO: generate a dedicated deploy key and paste its pubkey into
;; %deploy-ssh-public-key. Until then, the operator key is used for
;; both roles (less secure but functional).

;; Operator + CI pubkeys come from (playnet-keys) — SSOT lives in
;; deploy/guix/playnet-keys.scm so the ISO and production OS can't drift.
;; %operator-ssh-public-key and %ci-ssh-public-key are re-exported by the
;; import above; the bindings below stay only to localize names for the
;; existing call sites without renaming them.
(define %deploy-ssh-public-key %operator-ssh-public-key)

;; Backward compat alias (referenced elsewhere)
(define %admin-ssh-public-key %operator-ssh-public-key)

;; Dynamic users: list of (username . ssh-pubkey) pairs.
;; Managed by provision-user.scm — do not edit users.scm by hand.

(define %dynamic-users
  (primitive-load
   (string-append %this-dir "/users.scm")))

(define %dynamic-user-names (map car %dynamic-users))

;; Dynamic DNS updater (Cookbook §3.5) — keeps a backup domain in sync
;; with the server's public IP.  Generic: works with any DDNS provider
;; that exposes an HTTP update endpoint.
;;
;; Usage:
;;   (make-ddns-job "myhost"
;;     "https://duckdns.org/update?domains=myhost&token=~a&ip="
;;     "/etc/ddns/myhost.token")
;;
;; The URL template must contain a single ~a for the token.
;; Leaving ip= empty lets the provider auto-detect the public IP.
;;
;; Common providers:
;;   DuckDNS:  "https://www.duckdns.org/update?domains=DOMAIN&token=~a&ip="
;;   FreeDNS:  "https://freedns.afraid.org/dynamic/update.php?~a"
;;   Dynu:     "https://api.dynu.com/nic/update?hostname=DOMAIN&password=~a"
;;
;; Setup:
;;   1. Register a subdomain with your chosen provider
;;   2. Create the token file (readable by nobody)
;;   3. Uncomment the mcron service in the services list
(define* (make-ddns-job name url-template token-file
                        #:key (interval 5))
  ;; :04 of every INTERVAL minutes — see the mcron block: one job per minute.
  #~(job '(next-minute (range 4 60 #$interval))
         #$(program-file
            (string-append "ddns-update-" name)
            (with-extensions (list guile-gnutls)
              #~(begin
                  (use-modules (ice-9 textual-ports)
                               (web client))
                  (let* ((token (string-trim-both
                                 (call-with-input-file #$token-file
                                   get-string-all)))
                         (url (format #f #$url-template token)))
                    (http-get url)))))
         #$(string-append "ddns-update-" name)
         #:user "nobody"))

;; Helper script for synchronous REPL eval from the command line.
(define %repl-eval-script
  (local-file "scripts/repl-eval"))

;; Emacs init.el for the playnet user — deployed via activation service.
;; Source of truth lives in deploy/scripts/init.el so it can be edited
;; with proper elisp tooling instead of being embedded as an escaped
;; string. The activation service copies it into ~playnet/.emacs.d/.
(define %emacs-init-el
  (local-file "scripts/init.el"))

(define %guix-x86
  (operating-system
    (host-name (or (provider-ref 'host-name) "playnet"))
    (timezone "Etc/UTC")
    (bootloader (provider-ref 'bootloader))
    (kernel linux-libre-sev)
    (initrd-modules (append
                     (provider-ref 'initrd-modules)
                     %base-initrd-modules))
    ;; /var/log/playnet on tmpfs: service logs live in RAM only, so a
    ;; powered-off disk seizure yields nothing operationally interesting
    ;; (system logs in /var/log/* still hit disk; only the playnet-
    ;; specific service logs are volatile). 256M: when this filled at 64M
    ;; (2026-09-06 22:00) the hourly rotation's zstd hit ENOSPC, shepherd's
    ;; control socket wedged behind it, and the box went down an OOM spiral
    ;; from queued `herd status` calls — a full log tmpfs costs far more than
    ;; the RAM it holds. Services rotate themselves via shepherd as logs grow.
    (file-systems (append (provider-ref 'file-systems)
                         (list (file-system
                                 (mount-point "/var/log/playnet")
                                 (device "tmpfs")
                                 (type "tmpfs")
                                 (flags '(no-suid no-dev))
                                 (options "size=256M,mode=0750")
                                 (check? #f)
                                 (create-mount-point? #t)))
                         %base-file-systems))

    ;; The 4 GiB swap file the image shipped with (mkswap'd, never enabled):
    ;; headroom that turns a memory spike into slowness instead of the OOM
    ;; killer taking services one by one (2026-09-07, the 7.4 GB box with no
    ;; swap: 138 kills over 14 hours, sshd among them).
    (swap-devices (list (swap-space (target "/.swap"))))

    ;; Static accounts:
    ;; Static users:
    ;;   deploy          — system administration, guix deploy
    ;;   playnet         — gateway + REPL + planner (main service user)
    ;;   playnet-wallet  — wallet-service (isolated, owns wallet files)
    ;;   playnet-mqtt    — Mosquitto broker (owns MQTT data)
    ;; All service-isolation users share the playnet-svc group for
    ;; minimal cross-service access (e.g., REPL socket group-readable).
    ;; Dynamic accounts (from users.scm, managed by provision-user.scm):
    ;;   priya, … — provisioned users with their own SSH keys
    ;; They get their own group, separate from playnet's "users" group:
    ;; playnet owns and executes /home/playnet/playnet-repo as group
    ;; "users", so a guest sharing that gid would inherit group-write
    ;; access to the live checkout the moment any file in that tree
    ;; drifted group-writable (a lax rsync umask, a stray chmod -R).
    ;; "playnet-guests" has no write access to anything playnet owns.
    (groups (cons* (user-group (name "playnet-svc") (system? #t))
                   (user-group (name "playnet-guests"))
                   %base-groups))
    (users (append
            (list
             (user-account
              (name "deploy")
              (group "users")
              (supplementary-groups '("wheel" "plugdev"))
              (home-directory "/home/deploy")
              (shell (file-append bash "/bin/bash")))
             (user-account
              (name "playnet")
              (group "users")
              (supplementary-groups '("playnet-svc" "plugdev"))
              (home-directory "/home/playnet")
              (shell (file-append bash "/bin/bash")))
             ;; Wallet-service: isolated from the gateway process.
             ;; Owns /var/lib/playnet/monero/ files. No shell access.
             (user-account
              (name "playnet-wallet")
              (group "playnet-svc")
              (system? #t)
              (home-directory "/var/lib/playnet/wallet")
              (shell (file-append bash "/sbin/nologin")))
             ;; Mosquitto broker: owns MQTT data only.
             (user-account
              (name "playnet-mqtt")
              (group "playnet-svc")
              (system? #t)
              (home-directory "/var/lib/playnet/mosquitto")
              (shell (file-append bash "/sbin/nologin"))))
            ;; All users from users.scm (sapient-os + any provisioned accounts).
            ;; Group "playnet-guests", not "users" — see note above the
            ;; groups list.
            (map (lambda (entry)
                   (user-account
                    (name (car entry))
                    (group "playnet-guests")
                    (home-directory (string-append "/home/" (car entry)))
                    (shell (file-append bash "/bin/bash"))))
                 %dynamic-users)
            %base-user-accounts))

    (sudoers-file
     (plain-file "sudoers"
       (string-append
        "root ALL=(ALL) ALL\n"
        "%wheel ALL=(ALL) ALL\n"
        "deploy ALL=(ALL) NOPASSWD: ALL\n"
        ;; No general "su - <user>" grant for playnet: nothing in the
        ;; codebase currently spawns login shells as provisioned guest
        ;; users, so there's no reason to hold that capability open.
        ;; If a relay-spawns-a-shell feature is ever built, add it back
        ;; scoped to an explicit list drawn from %dynamic-user-names —
        ;; never a "*" wildcard, and never root/deploy/playnet as a target.
        ;;
        ;; Allow radicle-ci-hook (running as playnet) to restart the
        ;; services it owns after a rad push that touches their code.
        ;; Scoped to specific services + the herd binary path so it
        ;; cannot become a general root escalation.
        "playnet ALL=(ALL) NOPASSWD: "
        "/run/current-system/profile/bin/herd restart playnet-gateway, "
        ;; playnet-static loads server/serve-static.scm once at exec and
        ;; holds it for the life of the process: an rsync that lands new
        ;; routes leaves the running server answering with the route table
        ;; it booted with. A route added after the last restart falls
        ;; through to the SPA fallback, so /tiles/osm/… returns app.html
        ;; and the map draws markers over empty ground.
        "/run/current-system/profile/bin/herd restart playnet-static, "
        "/run/current-system/profile/bin/herd restart dev-bridge, "
        "/run/current-system/profile/bin/herd restart playnet-matrix-bridge, "
        "/run/current-system/profile/bin/herd restart playnet-telegram-bridge\n")))

    (packages
     (append
      (list guile-goblins
            guile-fibers
            guile-websocket            ; required by (hoot web-server) /repl proxy
            guile-hoot/playnet         ; provides `hoot` CLI + libs
            inotify-tools              ; live-watch shepherd service depends on inotifywait
            emacs-no-x
            emacs-geiser
            emacs-geiser-guile
            emacs-geiser-hoot          ; M-x connect-to-hoot — Hoot Geiser flavour
            emacs-smartparens
            emacs-rainbow-delimiters
            emacs-claude-code-ide
            htop
            git
            opencode                   ; dev-bridge's agent CLI (AGENT_CLI=opencode)
            mosquitto
            guile-mqtt
            guile-json-4
            guile-zlib                 ; serve-static's PMTiles reader (the basemap's archives)
            radicle
            rsync
            curl                       ; operator HTTP checks
            msmtp                      ; the gateway's mail, handed to the provider config's relay
            gnu-make                   ; CI wasm rebuild — build_browser_wasm runs `make`
            gcc-toolchain              ; planner's compiled kernel (native-c backend): the
                                        ; .so is gitignored, built locally, and nothing else
                                        ; on this host provides a C compiler to build it with
                                        ; — without this, kern-available? is false and every
                                        ; solve path but qc-free/sparse OSQP errors outright
            ;; Security: age encryption + YubiKey hardware key support
            age
            age-plugin-yubikey
            ;; Tor pluggable transport: obfs4 makes Tor traffic look like
            ;; random noise to ISPs/firewalls. Without this, the ISP can
            ;; see "this server uses Tor" even if they can't see what for.
            ;; lyrebird is the successor to obfs4proxy, maintained by Tor Project.
            lyrebird
            ;; torsocks: LD_PRELOAD wrapper that routes all TCP through Tor.
            ;; The gateway/wallet Shepherd services run under torsocks so
            ;; Guile's (web client) calls to swap APIs go through Tor
            ;; without needing SOCKS5 support in Guile itself.
            torsocks)
      %base-packages))

    (services
     (append
      ;; Networking — static IF the provider declared a `host-ip`,
      ;; otherwise fall back to dhcpcd. The provider hands out floating /32
      ;; addresses with a linknet gateway (172.16.0.1) outside the host's
      ;; subnet, so dhcpcd alone produces APIPA-only state and ssh-daemon
      ;; ends up unreachable. The static branch handles that correctly.
      ;;
      ;; static-networking-service-type in current Guix only provisions
      ;; per-interface names ('networking-eth0' etc.), but ssh-daemon's
      ;; requirement is the generic 'networking — hence the shim
      ;; shepherd-service that aliases the two so dependencies resolve.
      (if (provider-ref 'host-ip)
          (let ((ip      (provider-ref 'host-ip))
                (gateway (or (provider-ref 'host-gateway) "172.16.0.1"))
                (dns     (or (provider-ref 'name-servers) '("1.1.1.1" "9.9.9.9")))
                (iface   (or (provider-ref 'interface) "eth0")))
            ;; Custom static-networking shepherd-service using `ip(8)` —
            ;; idempotent (uses `addr replace` / `route replace`) and tolerant
            ;; of re-invocation. The stock static-networking-service-type calls
            ;; netlink primitives directly and throws &netlink-response-error 17
            ;; (EEXIST) on any re-run, which permanently fails the service and
            ;; breaks every dependent (ssh-daemon, playnet-gateway, etc.) until
            ;; the next reboot. We provide 'networking ourselves so dependents
            ;; resolve normally; also write /etc/resolv.conf at start.
            (list
             (simple-service 'static-networking
                             shepherd-root-service-type
                             (list (shepherd-service
                                    (provision '(networking))
                                    (requirement '(udev))
                                    (one-shot? #t)
                                    (documentation
                                     "Idempotent static networking for provider-style /32 + linknet gateway.")
                                    (start
                                     #~(lambda _
                                         (let* ((ip-bin (string-append #$iproute "/sbin/ip"))
                                                (run (lambda args
                                                       (zero?
                                                        (apply system* ip-bin args)))))
                                           ;; Address: replace is idempotent
                                           (run "link" "set" #$iface "up")
                                           (run "addr" "replace"
                                                (string-append #$ip "/32")
                                                "dev" #$iface)
                                           ;; Host route to gateway (scope link)
                                           (run "route" "replace"
                                                #$gateway "dev" #$iface
                                                "scope" "link")
                                           ;; Default route via gateway
                                           (run "route" "replace" "default"
                                                "via" #$gateway "dev" #$iface)
                                           ;; resolv.conf — write atomically
                                           (call-with-output-file "/etc/resolv.conf.tmp"
                                             (lambda (port)
                                               (for-each (lambda (ns)
                                                           (display "nameserver " port)
                                                           (display ns port)
                                                           (newline port))
                                                         '#$dns)))
                                           (rename-file "/etc/resolv.conf.tmp"
                                                        "/etc/resolv.conf")
                                           #t)))
                                    (stop
                                     #~(lambda _
                                         (let ((ip-bin (string-append #$iproute "/sbin/ip")))
                                           (system* ip-bin "addr" "flush" "dev" #$iface)
                                           #f))))))))
          (list (service dhcpcd-service-type)))
      (list
      ;; SSH — key-only, no passwords
      (service openssh-service-type
               (openssh-configuration
                (openssh openssh-sans-x)
                (permit-root-login 'prohibit-password)
                (password-authentication? #f)
                ;; Keep connections alive during long guix deploy operations
                ;; (substitute downloads can idle the channel for 15+ minutes)
                (extra-content "ClientAliveInterval 5\nClientAliveCountMax 60")
                (authorized-keys
                 `(;; Root: operator + CI (emergency access only)
                   ("root"    ,(plain-file "root-key"      %operator-ssh-public-key))
                   ("root"    ,(plain-file "ci-root-key"   %ci-ssh-public-key))
                   ;; Deploy: deploy key + CI key (guix deploy only)
                   ("deploy"  ,(plain-file "deploy-key"    %deploy-ssh-public-key))
                   ("deploy"  ,(plain-file "ci-deploy-key" %ci-ssh-public-key))
                   ;; Playnet: operator key only (interactive REPL, live hacking)
                   ("playnet" ,(plain-file "playnet-key"   %operator-ssh-public-key))
                   ;; Dynamic users — each gets their own registered public key
                   ,@(map (lambda (entry)
                            (list (car entry)
                                  (plain-file (string-append (car entry) "-key")
                                              (cdr entry))))
                          %dynamic-users)))))

       ;; Static SPA + WebSocket gateway — self-hosted.
       ;; Serves browser/ from mutable checkout. Radicle CI syncs on push.
       ;;
       ;; Two entry paths, one content source:
       ;;   Port 80  — Tor onion traffic (TLS at the hidden service layer)
       ;;   Port 443 — CDN clearnet face (self-signed cert, CDN IP allowlist)
       ;; Unknown Host / direct IP access returns 444 (silent drop).
       ;; Explicit nginx base config — overrides the default-value so we
       ;; can set http-context directives (limit_req_zone). The
       ;; `simple-service 'playnet-web` below only contributes
       ;; server-blocks (per nginx-service-type's extend at
       ;; gnu/services/web.scm:996), which it appends to this base.
       (service nginx-service-type
                (nginx-configuration
                 (extra-content %playnet-nginx-http-content)))

       ;; Shared locations and headers defined in %playnet-locations /
       ;; %playnet-security-headers — no duplication.
       (simple-service 'playnet-web
                       nginx-service-type
                       (append
                        ;; Onion server — always active, serves .onion traffic.
                        ;; Carries the git-mirror locations too — reachable
                        ;; over Tor via ordinary git (verified: a real
                        ;; `git ls-remote` through this exact route, over
                        ;; Tor, returned the right commit). `guix pull`
                        ;; itself can't use this route (see the clearnet
                        ;; block below for why) but nothing else about the
                        ;; mirror is onion-specific, so it stays exposed
                        ;; here too.
                        (list
                         (nginx-server-configuration
                          (server-name '("_"))
                          (listen '("80"))
                          (root "/home/playnet/playnet-repo/browser")
                          (locations (append %playnet-locations
                                             (%playnet-all-git-mirror-locations)))
                          (raw-content %playnet-security-headers)))
                        ;; Clearnet face — only when a domain is configured.
                        (if %clearnet-domain
                            (list
                             ;; Default server for :443 only: reject direct IP /
                             ;; unknown Host with 444. Port 80 must NOT carry a
                             ;; default_server here, otherwise it overrides the
                             ;; catch-all 'server_name "_"' onion block above
                             ;; and the .onion starts returning 444 too.
                             (nginx-server-configuration
                              (server-name '("nonexistent.default"))
                              (listen '("443 ssl default_server"))
                              (ssl-certificate "/var/lib/playnet/tls/playnet-origin.pem")
                              (ssl-certificate-key "/var/lib/playnet/tls/playnet-origin.key")
                              (raw-content '("return 444;")))
                             ;; Clearnet domain server: CDN-edge-only allowlist,
                             ;; self-signed cert, same content as onion.
                             ;; repl.<domain> rides the same block: the CDN
                             ;; forwards the original Host (AddHostHeader),
                             ;; serve-static routes by it — the dial answers
                             ;; the apex, the repl answers its subdomain.
                             ;;
                             ;; Carries the git-mirror locations too, alongside
                             ;; the onion: `guix pull`'s git implementation
                             ;; (libgit2) resolves hostnames via ordinary DNS
                             ;; before any proxy is even consulted, so a bare
                             ;; .onion URL can never work for it — confirmed
                             ;; directly (a getaddrinfo-shaped failure, not a
                             ;; connection one). This exposes nothing the
                             ;; clearnet face doesn't already: the RID is
                             ;; public in the committed channels.scm and
                             ;; already served read-only via /api/v1 and
                             ;; /raw/, on this exact same server block.
                             ;; deploy/scripts/cdn.scm's
                             ;; NO_CACHE_PATHS carries the matching entry — a
                             ;; CDN-cached info/refs would serve a stale ref
                             ;; set after every push, the same failure mode
                             ;; that script already exists to prevent for
                             ;; /api/*.
                             (nginx-server-configuration
                              (server-name (list %clearnet-domain
                                                 (string-append "repl." %clearnet-domain)))
                              (listen '("443 ssl"))
                              (ssl-certificate "/var/lib/playnet/tls/playnet-origin.pem")
                              (ssl-certificate-key "/var/lib/playnet/tls/playnet-origin.key")
                              (root "/home/playnet/playnet-repo/browser")
                              (locations (append %playnet-locations
                                                 (%playnet-all-git-mirror-locations)))
                              (raw-content
                               (append
                                (map (lambda (ip) (string-append "allow " ip ";"))
                                     %cdn-edge-ips)
                                '("deny all;")
                                %playnet-security-headers))))
                            '())))

      ) ;; end of unconditional services list

      ;; Self-signed TLS certificate for origin — only when a clearnet
      ;; domain is configured. The CDN terminates TLS at the edge with its
      ;; own cert; the origin cert is only seen by the CDN's pull zone (with
      ;; "disable SSL verification" enabled). Avoids Let's Encrypt / CT logs
      ;; leaking the origin IP. Per docs/deploy/CLEARNET-FACES.md §Architecture.
      (if %clearnet-domain
           (list
                         (simple-service 'origin-tls-cert
                            activation-service-type
                            #~(begin
                                (use-modules (guix build utils))
                                (mkdir-p "/var/lib/playnet/tls")
                                (chmod "/var/lib/playnet/tls" #o700)
                                (unless (file-exists? "/var/lib/playnet/tls/playnet-origin.pem")
                                  (system*
                                   #$(file-append openssl "/bin/openssl")
                                   "req" "-x509" "-newkey" "rsa:2048"
                                   "-days" "3650" "-nodes"
                                   "-keyout" "/var/lib/playnet/tls/playnet-origin.key"
                                   "-out" "/var/lib/playnet/tls/playnet-origin.pem"
                                   "-subj" (string-append "/CN="
                                                           #$(or %clearnet-domain "origin")))))))
           '())

      (list

      ;; Tor hidden service — .onion address eliminates DNS entirely.
      ;; The .onion hostname is auto-generated on first start and persists
      ;; in /var/lib/tor/hidden-services/playnet/hostname.
      ;; No domain registrar, no DNS, no Certificate Transparency logs.
      (service tor-service-type
               (tor-configuration
                (config-file
                 ;; Custom torrc: enable obfs4 pluggable transport so Tor
                 ;; traffic looks like random noise to the ISP/firewall.
                 ;; Without this, the ISP sees "this server uses Tor" even
                 ;; though they can't see what for. With obfs4, all they
                 ;; see is encrypted traffic to an unknown IP.
                 ;;
                 ;; BRIDGES (obfs4). When the provider blocks direct
                 ;; connections to Tor RELAY ORPorts, Tor bootstraps (it can
                 ;; still fetch the directory consensus) but can never build
                 ;; the rendezvous circuits an onion service needs — so the
                 ;; box's .onion stops publishing and stops resolving any
                 ;; other onion, while clearnet is unaffected. obfs4 bridges
                 ;; route Tor's egress through relays whose IPs the provider
                 ;; hasn't blocked and whose traffic looks like noise, which
                 ;; restores onion circuits.
                 ;;
                 ;; Bridge lines are SECRET — a committed bridge is a scraped,
                 ;; then blocked, bridge. So they live in the per-box provider
                 ;; config (deploy/providers/<box>.scm, gitignored), never
                 ;; here. Add, in that alist:
                 ;;   (tor-bridges
                 ;;    (list
                 ;;     "obfs4 IP:PORT FINGERPRINT cert=… iat-mode=0"
                 ;;     "obfs4 IP:PORT FINGERPRINT cert=… iat-mode=0"))
                 ;; Obtain fresh lines from https://bridges.torproject.org
                 ;; (Advanced → obfs4), or email bridges@torproject.org with
                 ;; "get transport obfs4" in the body. Two or three is plenty.
                 ;; Present ⇒ UseBridges 1 and the Bridge lines are emitted;
                 ;; absent ⇒ the torrc is byte-identical to before, so a box
                 ;; on an unfiltered provider is unchanged.
                 ;;
                 ;; mixed-text-file lets us interleave string literals with
                 ;; (file-append …) store-path references; plain-file can't
                 ;; because it expects a literal string. It is a procedure, so
                 ;; `apply` extends its argument list with the bridge lines.
                 (apply
                  mixed-text-file "torrc"
                  (append
                   (list
                    "SocksPort 9050\n"
                    ;; HTTP CONNECT proxy on 9080 — used by guix-daemon
                    ;; (substitute downloads via http-proxy) and any other
                    ;; service that needs HTTP-proxy semantics rather than
                    ;; SOCKS5. Loopback only; not exposed to clearnet.
                    "HTTPTunnelPort 127.0.0.1:9080\n"
                    "ClientTransportPlugin obfs4 exec "
                    (file-append lyrebird "/bin/lyrebird") "\n")
                   (let ((bridges (or (provider-ref 'tor-bridges) '())))
                     (if (null? bridges)
                         '()
                         (cons "UseBridges 1\n"
                               (map (lambda (b) (string-append "Bridge " b "\n"))
                                    bridges)))))))
                (hidden-services
                 (list (tor-onion-service-configuration
                        (name "playnet")
                        (mapping '((80 "127.0.0.1:80")
                                   (443 "127.0.0.1:443")
                                   (8776 "127.0.0.1:8776"))))  ; Radicle P2P
                       ;; Operator SSH, on its OWN onion: the public site's
                       ;; address says nothing about where sshd answers. An
                       ;; onion connection arrives over `lo`, which the
                       ;; firewall accepts first — so it meets neither the
                       ;; 6-per-minute limit on new clearnet :22 connections
                       ;; nor the bot flood competing for those six, and it
                       ;; crosses no exit node. The hostname is generated on
                       ;; first start: /var/lib/tor/hidden-services/ssh/hostname.
                       ;; Clearnet :22 stays as it was, the way back in if Tor
                       ;; is ever the thing that is down.
                       (tor-onion-service-configuration
                        (name "ssh")
                        (mapping '((22 "127.0.0.1:22"))))))))

      ;; Publish THIS box's own onion into gateway-onion.txt so serve-static
      ;; advertises the Tor gateway face in /entry-points.json. Fully
      ;; reproducible + per-box: the address is auto-derived from the box's own
      ;; hidden-service hostname (which tor generates on first boot), never
      ;; hardcoded. serve-static reads the file at request time and trims it;
      ;; absent → the onion face is simply omitted. Runs as root because the
      ;; tor hidden-service dir isn't readable by the playnet user.
      (simple-service 'publish-gateway-onion
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(publish-gateway-onion))
                             (requirement '(tor))
                             (one-shot? #t)
                             (documentation
                              "Copy the box's Tor onion hostname into /var/lib/playnet/gateway-onion.txt.")
                             (start
                              #~(lambda _
                                  (let ((src "/var/lib/tor/hidden-services/playnet/hostname")
                                        (dst "/var/lib/playnet/gateway-onion.txt"))
                                    ;; tor writes the hostname a moment after it
                                    ;; starts; poll briefly (bounded) for it.
                                    (let loop ((n 0))
                                      (cond
                                       ((file-exists? src)
                                        (copy-file src dst)
                                        (chmod dst #o644)
                                        #t)
                                       ((< n 30) (sleep 2) (loop (+ n 1)))
                                       ;; not ready — non-fatal; serve-static
                                       ;; omits the onion until the next boot.
                                       (else #t))))))
                             (respawn? #f))))

      ;; Dynamic DNS (Cookbook §3.5) — backup domain independent of
      ;; primary registrar.  Provides a secondary entry point.
      ;; ENABLE AFTER registering with a DDNS provider:
      ;;
      ;; (service mcron-service-type
      ;;          (mcron-configuration
      ;;           (jobs (list (make-ddns-job "playnet"
      ;;                        "https://www.duckdns.org/update?domains=playnet&token=~a&ip="
      ;;                        "/etc/ddns/playnet.token")))))

      ;; KERIA cloud agent + witness pool — self-sovereign identity for playnet
      ;; Users own their keys; this server facilitates but never holds authority.
      ;;
      ;; Witness pool is read from the provider config so different fleet
      ;; hosts can run disjoint subsets (geo-distribution); falls back to
      ;; the canonical 6-witness pool. See docs/governance/GOVERNANCE-CEREMONIES.md
      ;; §2.4-§2.5 for growth and distribution patterns.
      (service keria-service-type
               (let ((base (keria-configuration
                            (data-dir "/var/lib/playnet/keria")
                            (config   "/var/lib/playnet/keria/config/keria.json")
                            (user     "playnet")))
                     (provider-witnesses (provider-ref 'witnesses)))
                 (if provider-witnesses
                     (keria-configuration (inherit base)
                                          (witnesses provider-witnesses))
                     base)))

      ;; OCapN gateway — capability-secure communication over WebSocket + Reticulum
      (service playnet-gateway-service-type
               (playnet-gateway-configuration
                (package %playnet-package)
                (port 9090)
                (reticulum? #t)
                ;; Reads the wallet's sturdyref through the service group.
                (supplementary-groups '("playnet-svc"))
                (secret-environment-files
                 (map (lambda (var) (cons var (%secret-file-for var)))
                      (cons "API_KEYS" %fleet-credential-vars)))
                (environment
                 `(("API_KEYS" . ,(or (getenv "API_KEYS")
                                      (getenv "OPENROUTER_KEYS") ""))
                   ;; KERIA client tier: agent API on the admin port (3901,
                   ;; matches bridge.scm's default), boot API on 3903 — NOT
                   ;; 3902 (that's --http, KERIA's unauthenticated agent
                   ;; HTTP API for OOBI resolution). gateway.scm's built-in
                   ;; default of 3902 for KERIA_BOOT_URL predates this box's
                   ;; keria-configuration and was never exercised (bran was
                   ;; always unset); set explicitly here to route /boot at
                   ;; the port KERIA actually serves it on.
                   ("KERIA_AGENT_URL" . "http://localhost:3901")
                   ("KERIA_BOOT_URL"  . "http://localhost:3903")
                   ;; Schema OOBIs are self-hosted: serve-static.scm serves
                   ;; the ACDC schema catalog at /oobi/{said} on port 8080,
                   ;; and KERIA (same box) resolves them from there at
                   ;; gateway boot via acdc-ensure-schemas-resolved!.
                   ("PLAYNET_SCHEMA_SERVER" . "http://localhost:8080")
                   ;; Enable the durable-scope code path: scope KELs
                   ;; persist across restarts AND auto-publish into
                   ;; ^oobi-host so /oobi/{scope-aid} serves real bytes
                   ;; through serve-static.scm. Gated in gateway.scm
                   ;; around lines 167-189 and 413-425.
                   ;;
                   ;; Without these set, scopes are in-memory only and
                   ;; nothing populates the OOBI host — every
                   ;; /oobi/{aid} request 404s. With them set, the
                   ;; canonical "playnet" identity becomes a durable
                   ;; scope whose AID is the seed contact in the
                   ;; browser's contacts tab; the witness pool stays
                   ;; in its KERI-intended role (receipting KELs,
                   ;; not being the public face). See
                   ;; docs/governance/persistence-operations.md.
                   ("PLAYNET_SCOPES_DURABLE"  . "1")
                   ("PLAYNET_OOBI_AUTO_MIRROR" . "1")
                   ;; GDPR deferral, not a capability gap: a real signup binds a
                   ;; real name/email to an AID (identity/seat.scm member
                   ;; record), which is the one place Articles 5(1)(e)/9/13/17/
                   ;; 30/32/35 and Chapter V all activate at once — see
                   ;; docs/legal/gdpr-analysis.md. Closed here until
                   ;; that plan's consent/erasure/portability work (also in that
                   ;; doc) is far enough along to carry the obligation. Checked
                   ;; in doors/lobby.scm's real-signup-enabled?; gates the
                   ;; doors declared `#:feature account-creation` in
                   ;; doors/protocol.scm and nothing else.
                   ;; tools/dev/dev.sh does not set this — local dev keeps signing up
                   ;; real AIDs as it always has, which is the developer's own
                   ;; test data, not a third party's.
                   ("PLAYNET_DISABLE_REAL_SIGNUP" . "1")
                   ;; The photo read (docs/observation/capture.md §9). The vision
                   ;; model is an enclave slug (TEE/…) that reads images, named in
                   ;; the provider's own config; unset, the see door answers
                   ;; empty and the capture sheet takes the figure from the
                   ;; person. The allotment is the unplanned reads a person gets
                   ;; a week (a count the plan asked for draws on the plan).
                   ("API_VISION_MODEL" . ,(or (getenv "API_VISION_MODEL") ""))
                   ("PLAYNET_PHOTO_ALLOTMENT" . ,(or (getenv "PLAYNET_PHOTO_ALLOTMENT") "21"))
                   ;; The mail relay (the provider config's `mail`): with it
                   ;; the gateway offers email as a channel and sends through
                   ;; msmtp, under the same torsocks as the gateway itself.
                   ,@(%mail-environment)
                   ;; Who runs this gateway (the provider config's `operator`):
                   ;; the push subject and the mail sender fall back to it.
                   ,@(%operator-environment)))))

      ;; Origin HTTP — serve-static.scm owns ALL HTTP routing on the
      ;; origin (SPA + KERI OOBI + DID + security headers + MIME +
      ;; SPA index fallback). nginx proxies / → 8080 and adds TLS,
      ;; CDN allowlist, rate limits, default-server 444. See
      ;; %playnet-locations comment for the thin-nginx rationale.
      (service playnet-static-service-type
               (playnet-static-configuration
                (package %playnet-package)
                (port 8080)
                (operator (%operator-environment))
                ;; this deployment's own clearnet face, from its own domain —
                ;; never another's; no clearnet-domain, none advertised
                (clearnet-ws (and %clearnet-domain
                                  (string-append "wss://" %clearnet-domain "/ws")))))

      ;; Self-hosted Valhalla routing engine — Tier-1, offline, no IP leak.
      ;; Binds tcp://127.0.0.1:8002 (loopback only). serve-static (:8080)
      ;; reaches it server-to-server via the same-origin /route proxy
      ;; (server/serve-static.scm handle-route → POST :8002/route); nginx
      ;; never proxies here, the browser never touches it directly. Engine
      ;; down → serve-static relays "{}" and the map straight-lines, so a
      ;; missing/rebuilding tileset degrades gracefully. The engine tree is
      ;; built out-of-band under /home/playnet/playnet-repo/.valhalla/ (see
      ;; tools/dev/valhalla-local.sh: `make routing-data`); this service only
      ;; supervises the already-built valhalla_service binary. Not yet built
      ;; on a host → the service respawn-loops harmlessly until the atlas
      ;; (SF + Berlin tiles) is present, and /route degrades meanwhile.
      (service playnet-valhalla-service-type
               (playnet-valhalla-configuration
                (work-dir "/home/playnet/playnet-repo")
                (threads 2)
                (user "playnet")))

      ;; (Bridges to external chat networks and the headless QGIS worker
      ;; lived here; the compute-only repo carries none of them — see the
      ;; playnet archive for the matrix/telegram/qgis service modules.)

      ;; Dev REPL — Guile on a Unix socket, runs as playnet user.
      ;; Connect with: M-x geiser-connect-local RET guile RET /var/run/playnet/repl.sock
      ;; Manual start only: herd start playnet-repl
      (simple-service 'playnet-repl
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(playnet-repl))
                             (documentation "Guile REPL for live hacking via Geiser")
                             (requirement '(networking user-processes))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append guile-3.0 "/bin/guile")
                                             "-L" "/home/playnet/playnet-repo/module"
                                             "-c"
                                             "(use-modules (system repl server)) (run-server (make-unix-domain-server-socket #:path \"/var/run/playnet/repl.sock\"))")
                                       #:user "playnet"
                                       #:group "users"
                                       #:log-file "/var/log/playnet/repl.log"
                                       #:environment-variables
                                       (list (string-append "GUILE_LOAD_PATH="
                                              "/run/current-system/profile/share/guile/site/3.0:"
                                              "/home/playnet/playnet-repo/module")
                                             (string-append "GUILE_LOAD_COMPILED_PATH="
                                              "/run/current-system/profile/lib/guile/3.0/site-ccache")
                                             "HOME=/home/playnet")))
                             (stop #~(lambda (pid)
                                      ((make-kill-destructor) pid)
                                      (when (file-exists? "/var/run/playnet/repl.sock")
                                        (delete-file "/var/run/playnet/repl.sock"))
                                      #f))
                             (respawn? #f)
                             (auto-start? #f))))

      ;; Live-watch — inotify loop that pushes saved Scheme files into
      ;; the running Hoot REPL relay. Manual start; pairs with
      ;; serve-dev. Watches /home/playnet/dev-checkout/module/.
      ;;   sudo herd start live-watch
      ;; See deploy/guix/live-watch-service.scm.
      (service live-watch-service-type
               (live-watch-configuration))

      ;; Mosquitto MQTT broker — localhost only, password-authenticated.
      ;; Without auth, any local user can inject fake deficit signals
      ;; and trigger XMR spend + VM provisioning. The password file is
      ;; generated by mosquitto_passwd at activation time from
      ;; MOSQUITTO_PASSWORD in secrets.scm.
      ;; Mosquitto MQTT broker — localhost-only, password-authenticated.
      ;; The acl + passwd files are seeded at activation (~line 1003) from
      ;; MOSQUITTO_PASSWORD in secrets.scm. Per-service users get
      ;; topic-restricted permissions so a compromised dev-bridge can read
      ;; deficits but cannot publish fake fleet-changed signals.
      (simple-service 'mosquitto
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(mosquitto))
                             (documentation "MQTT broker for VF event bridge (authenticated)")
                             (requirement '(networking))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append mosquitto "/sbin/mosquitto")
                                             "-c" #$(plain-file "mosquitto.conf"
                                                     (string-append
                                                      "listener 1883 127.0.0.1\n"
                                                      "allow_anonymous false\n"
                                                      "password_file /var/lib/playnet/mosquitto/passwd\n"
                                                      "acl_file /var/lib/playnet/mosquitto/acl\n"
                                                      "log_dest stderr\n")))
                                       ;; Run as playnet — owns the passwd/acl files
                                       ;; from activation. Avoids the default
                                       ;; drop-privs-to-nonexistent-'mosquitto'-user
                                       ;; warning that mosquitto 2.x emits.
                                       #:user "playnet"
                                       #:log-file "/var/log/mosquitto.log"))
                             (stop #~(make-kill-destructor))
                             (respawn? #t))))

      ;; Dev bridge — MQTT subscriber that launches Claude Code on deficit signals.
      ;; (The dev-bridge one-shot lived here — it ran server/dev-bridge.scm,
      ;; which the compute-only repo does not carry; see the playnet archive.)

      ;; Radicle P2P seed node — decentralized git hosting.
      ;; Listens on 0.0.0.0:8776 so the Tor hidden-service mapping
      ;; (.onion:8776 → 127.0.0.1:8776, declared in tor-service above) can
      ;; reach the node; the iptables tor-or-die policy still blocks 8776
      ;; from the clearnet. Outbound traffic uses Radicle's native Full
      ;; Proxy Mode (node.proxy + node.onion.mode=forward), wired up by the
      ;; radicle-configure one-shot after first `rad auth`.
      ;;
      ;; After first deploy:
      ;;   sudo -u playnet HOME=/var/lib/playnet/radicle rad auth
      ;;   sudo herd start radicle-configure
      (service radicle-service-type
               (radicle-configuration
                (data-dir "/var/lib/playnet/radicle")
                (listen "0.0.0.0:8776")
                (user "playnet")
                ;; Public, network-wide gossiped name: project only.
                (alias "playnet-seed")
                ;; Seed playnet with scope=all so commit objects fetch
                ;; from any peer (not only the 3 delegates). Closes the
                ;; sigref-arrives-but-objects-don't gap that silently
                ;; broke auto-deploy.
                ;; The satellites the core pins seed the same way; the
                ;; list is derived, so a RID added for its mirror route is
                ;; seeded on the same reconfigure.
                (seed-rids-all
                 (cons %playnet-rid
                       (map (lambda (bare) (string-append "rad:" bare))
                            %playnet-satellite-rids-bare)))))

      ;; Radicle HTTP daemon (OFFICIAL, read-only) — HTTP/JSON gateway over the
      ;; node storage. Localhost:8088. Reserved for a future *modern* Radicle
      ;; Explorer (its apiVersion differs from the boards stack's fork below);
      ;; not on the boards critical path. The "playnet" alias shortens URLs.
      (service radicle-httpd-service-type
               (radicle-httpd-configuration
                (data-dir "/var/lib/playnet/radicle")
                (listen "127.0.0.1:8088")
                (user "playnet")
                (aliases (list (cons "playnet" %playnet-rid)))))

      ;; Radicle HTTP API (cytechmobile WRITE fork) — the Planning Boards
      ;; backend: read + session-gated write (card moves = issue-label COB
      ;; writes the official httpd refuses). apiVersion 1.0.0, matched to the
      ;; maninak interface we serve at /radicle/. Localhost:8089; nginx routes
      ;; /api/v1/ here. Needs RAD_PASSPHRASE (signs COB writes) — same
      ;; passphrase-file as radicle-node. COB compat with our 1.7.1 node was
      ;; empirically verified (label round-trip). See radicle-http-api-service.scm.
      (service radicle-http-api-service-type
               (radicle-http-api-configuration
                (data-dir "/var/lib/playnet/radicle")
                (listen "127.0.0.1:8089")
                (user "playnet")))

      ;; Radicle CI — watches radicle-node events for ref updates, triggers
      ;; deploy/reload.  Runs in parallel with GitHub Actions during transition.
      ;; Manual start: sudo herd start radicle-ci
      ;; Requires: PLAYNET_RID env var set to the Radicle project ID after rad init.
      (simple-service 'radicle-ci
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(radicle-ci))
                             (documentation "Radicle CI — deploy/reload on ref updates")
                             (requirement '(networking radicle-node))
                             (start #~(make-forkexec-constructor
                                       (list #$(file-append bash "/bin/bash")
                                             "/home/playnet/playnet-repo/deploy/scripts/radicle-ci-hook.sh")
                                       #:user "playnet"
                                       #:group "users"
                                       #:log-file "/var/log/playnet/radicle-ci.log"
                                       #:environment-variables
                                       (list "HOME=/var/lib/playnet/radicle"
                                             "RAD_HOME=/var/lib/playnet/radicle/.radicle"
                                             "DEPLOY_DIR=/home/playnet/playnet-repo"
                                             (string-append "PLAYNET_RID=" #$%playnet-rid)
                                             ;; Shell patch-CI OFF by default: the
                                             ;; native radicle-ci-broker service
                                             ;; (below) is the CI engine now; this
                                             ;; hook keeps doing DEPLOY only. The
                                             ;; flag file /var/lib/playnet/patch-ci-enabled
                                             ;; still force-enables the shell CI as a
                                             ;; fallback if the broker is ever stopped.
                                             "PATCH_CI_ENABLE=0"
                                             (string-append "PATH="
                                              "/run/current-system/profile/bin:"
                                              "/run/current-system/profile/sbin"))))
                             (stop #~(make-kill-destructor))
                             (respawn? #t))))

      ;; SSH agent holding the node's signing key, for radicle-ci-broker's job-
      ;; COB signer (its own config has no key-file field — confirmed by
      ;; dumping it — it needs SSH_AUTH_SOCK). See
      ;; radicle-ci-broker-service.scm's own comment for the 2026-09-16
      ;; incident this exists to fix: the broker had failed every single run
      ;; since at least 2026-09-14, including real merges to canonical main.
      (simple-service 'radicle-ci-broker-ssh-agent
                      shepherd-root-service-type
                      (list (radicle-ci-broker-ssh-agent-shepherd-service)))

      ;; Native Radicle CI broker (cib) — the canonical CI engine. Watches the
      ;; node's events and runs the native adapter on each repo carrying
      ;; .radicle/native.yaml (default-branch + patch create/update). Consumes
      ;; the SAME .radicle/native.yaml the shell hook did, so this supersedes the
      ;; shell patch-CI (which is now DEPLOY-only, PATCH_CI_ENABLE=0 above).
      (simple-service 'radicle-ci-broker
                      shepherd-root-service-type
                      (list (radicle-ci-broker-shepherd-service)))

      ;; Reticulum mesh networking — Rust OCapN bridge (embeds RNS node).
      ;; Enables Goblins actors over LoRa, serial, TCP, I2P, packet radio.
      (service reticulum-bridge-service-type)

      ;; Fleet reconciler bridge — subscribes to spec-infra-* deficit
      ;; signals on MQTT and pokes the ^fleet-reconciler actor in the
      ;; gateway to provision new SporeStack VPS hosts paid in Monero.
      ;; See server/fleet-bridge.scm for the bridge logic.
      (service fleet-reconciler-service-type)

      ;; Fleet keeper — carries a host the reconciler recorded to a running
      ;; encrypted system (desired `#:bootstrap-mode 'auto`), and sends each
      ;; fleet host its disk passphrase whenever it waits in its initrd.
      (service fleet-keeper-service-type)

      ;; Deploy runner — auto-deploys when the fleet reconciler updates
      ;; hosts.scm. Runs as the `deploy` user (needs SSH access).
      ;; Manual start only — enable after verifying fleet provisioning:
      ;;   herd start deploy-runner
      (service deploy-runner-service-type)

      ;; Periodic store hygiene. The box has no auto-gc, so /gnu/store
      ;; grew unbounded until a reconfigure tripped a 100%-full disk
      ;; (2026-06-27). Two jobs, deliberately split by blast radius:
      ;;
      ;;   - WEEKLY `guix gc -F 25G` — collects only UNREFERENCED store
      ;;     paths (failed-build downloads, superseded packages between
      ;;     reconfigures). Never deletes generations, never touches the
      ;;     bootloader: rollback is fully preserved. This is the safe,
      ;;     frequent reclaim of the fast-growing cruft.
      ;;
      ;;   - MONTHLY `guix system delete-generations 1m` then gc — prunes
      ;;     only SYSTEM GENERATIONS older than one month; the last
      ;;     month's generations are KEPT, so rollback to recent good
      ;;     systems stays available. Plain gc can't reclaim
      ;;     generation-pinned closures (generations are GC roots), and
      ;;     those were what actually filled the disk. delete-generations
      ;;     rebuilds grub.cfg + reinstalls the (removable-EFI) bootloader
      ;;     and needs no network; do not reboot mid-job.
      ;;
      ;; This is also the single explicit mcron instance that
      ;; playnet-backup-service-type extends (see backup-service.scm);
      ;; its job composes into the jobs list below.
      ;;
      ;; EVERY JOB ON THIS BOX STARTS IN ITS OWN MINUTE (residue mod 5).
      ;; mcron 1.2.2 dies when two jobs start in the same minute: its
      ;; select loop reaches port->fdes on the job port that has already
      ;; closed ("Wrong type argument … #<closed: file>", base.scm:459) —
      ;; 28 respawns in three days found 2026-09-23, every one at a minute
      ;; where the every-2-minutes Radicle cache job and the every-5-minutes
      ;; host-facts job started together, and the weekly gc below never
      ;; once ran. mcron 1.2.3 (what the pinned channel now carries — the
      ;; next reconfigure installs it) removes closed ports before that
      ;; select (base.scm:386). The residues make the crash unreachable
      ;; either way: cache :00/:05 (radicle-http-api-service.scm),
      ;; host-facts :02/:07, everything else at :03 or :04 of its hour —
      ;; each job here runs in seconds, so distinct start minutes are
      ;; distinct lifetimes.
      (service mcron-service-type
               (mcron-configuration
                (jobs
                 (list #~(job "3 4 * * 0"
                              "/run/current-system/profile/bin/guix gc -F 25G")
                       #~(job "33 4 1 * *"
                              "/run/current-system/profile/bin/guix system delete-generations 1m; /run/current-system/profile/bin/guix gc -F 25G")
                       ;; the host reads itself every five minutes: running
                       ;; services + kernel capacity → a retained snapshot on
                       ;; playnet/facts/host/<hostname>, so any subscriber
                       ;; (a scope syncing its live-registry, a dashboard)
                       ;; gets the freshest reading on connect. System mcron
                       ;; jobs run as root (same as the gc/delete-generations
                       ;; jobs above, no su) — NOT dropped to playnet: `herd
                       ;; status` needs to reach /var/run/shepherd/socket,
                       ;; and that directory is root-only (drwx------) by
                       ;; design, since herd can also control services, not
                       ;; only read them. A non-root probe silently degrades
                       ;; to an empty service list rather than failing —
                       ;; found live the hard way (this exact drift) before
                       ;; being switched to root here. mqtt-password-file
                       ;; "host-facts" still resolves fine as root (root
                       ;; reads any file regardless of ownership).
                       ;;
                       ;; GUILE_LOAD_PATH is exported explicitly because
                       ;; mcron runs a job's command via a plain shell, not
                       ;; a login shell — root's interactive ssh sessions
                       ;; pick it up from ~/.bash_profile, but a bare `sh -c`
                       ;; job never sources that, and host-facts.scm
                       ;; transitively needs goblins (via store-utils.scm)
                       ;; the same way playnet-gateway-service.scm and
                       ;; dev-bridge's shepherd definitions already
                       ;; explicitly set it rather than relying on any
                       ;; ambient profile. Found live: the job's very first
                       ;; automatic run threw "no code for module (goblins
                       ;; utils hashmap)" before this export was added.
                       ;;
                       ;; One instance at a time, bounded: the job ends in a
                       ;; `herd status`, and on 2026-09-06 that call hung
                       ;; (shepherd's control socket wedged after a log
                       ;; rotation hit a full /var/log/playnet) — every five
                       ;; minutes another mcron→guile→herd chain joined the
                       ;; queue, 80 chains and 4 GB later the box was in an
                       ;; OOM spiral. flock refuses a second instance while
                       ;; one is still waiting; timeout ends any instance at
                       ;; four minutes, under the five-minute period. The
                       ;; schedule runs at :02 rather than :00 so it never
                       ;; coincides with shepherd's hourly log rotation.
                       #~(job "2-59/5 * * * *"
                              "export GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0; cd /home/playnet/playnet-repo && /run/current-system/profile/bin/flock -n /run/host-facts.lock /run/current-system/profile/bin/timeout 240 /run/current-system/profile/bin/guile --no-auto-compile -L module tools/dev/host-facts.scm --publish >> /var/log/playnet/host-facts.log 2>&1")
                       ;; Weekly OpenVTC parity check, Sundays 07:00 UTC
                       ;; (docs/planning/identity/openvtc-parity.md). The check
                       ;; (tools/lint/openvtc-parity-check.sh) is a deterministic
                       ;; git diff; tools/lint/openvtc-parity-narrate.scm wraps it
                       ;; and, best-effort, asks our own key-pool / nano-gpt
                       ;; stack to summarize the flagged commits. The keys are
                       ;; read at run time from /run/secrets/api-keys — the
                       ;; file install-runtime-secrets materializes and the
                       ;; gateway reads — so they stay out of the store; with
                       ;; no file the narration step prints the raw report.
                       #~(job "3 7 * * 0"
                              #$(string-append
                                 "export GUILE_LOAD_PATH=/run/current-system/profile/share/guile/site/3.0; "
                                 "export API_KEYS=\"$(cat /run/secrets/api-keys 2>/dev/null)\"; "
                                 "cd /home/playnet/playnet-repo && "
                                 "/run/current-system/profile/bin/flock -n /run/openvtc-parity.lock "
                                 "/run/current-system/profile/bin/timeout 300 "
                                 "/run/current-system/profile/bin/guile --no-auto-compile -L module "
                                 "tools/lint/openvtc-parity-narrate.scm >> /var/log/playnet/openvtc-parity.log 2>&1"))))))

      ;; Daily encrypted backup of the at-risk persistent state
      ;; (KERIA witness keystores, Tor onion key, SporeStack token,
      ;; Goblins vat snapshots). Snapshots land at
      ;; /var/lib/playnet/backups/state-<ISO>.tar.age and, if
      ;; PLAYNET_BACKUP_RID is set in the environment at deploy time,
      ;; are also pushed to a sister Radicle peer. Restore via
      ;; deploy/scripts/backup-restore.sh.
      (service playnet-backup-service-type
               (playnet-backup-configuration
                (backup-rid (or (getenv "PLAYNET_BACKUP_RID") ""))))

      ;; Per-host liveness heartbeat — publishes
      ;; playnet/signals/liveness/<host-id> every 30s. The fleet-bridge
      ;; subscribes to all of these and tells the reconciler which
      ;; providers have gone fully silent so 'auto' selection routes
      ;; around them. The actual loop lives in
      ;; deploy/scripts/playnet-liveness.sh (rsync'd into place by
      ;; reconfigure.sh).
      (simple-service 'playnet-liveness
                      shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(playnet-liveness))
                             (documentation "MQTT liveness heartbeat publisher")
                             (requirement '(networking mosquitto))
                             (start
                              #~(make-forkexec-constructor
                                 (list #$(file-append bash "/bin/bash")
                                       "/home/playnet/playnet-repo/deploy/scripts/playnet-liveness.sh")
                                 #:user "playnet"
                                 #:group "users"
                                 #:log-file "/var/log/playnet/liveness.log"
                                 #:environment-variables
                                 (list (string-append "PATH="
                                        "/run/current-system/profile/bin:"
                                        "/run/current-system/profile/sbin"))))
                             (stop #~(make-kill-destructor))
                             (respawn? #t))))

      ;; WireGuard VPN — encrypted point-to-point tunnels between fleet
      ;; hosts. Faster than Tor for server-to-server OCapN traffic.
      ;; Fleet hosts connect via their .onion addresses so the WireGuard
      ;; endpoint itself is anonymized. Keys are generated per-host
      ;; during bootstrap-debian.sh and stored in secrets.scm.
      ;;
      ;; Uncomment when fleet hosts are provisioned:
      ;; (service wireguard-service-type
      ;;   (wireguard-configuration
      ;;     (addresses '("10.0.0.1/24"))
      ;;     (private-key "/etc/wireguard/private.key")
      ;;     (peers
      ;;       (list (wireguard-peer
      ;;               (name "fleet-dev-1")
      ;;               (public-key "FLEET_HOST_PUBKEY_HERE")
      ;;               (allowed-ips '("10.0.0.2/32"))
      ;;               (endpoint "FLEET_ONION.onion:51820"))))))

      ;; YubiKey / FIDO2 security key udev rules. Required for
      ;; age-plugin-yubikey to communicate with the hardware key
      ;; for secrets decryption. The playnet and deploy users need
      ;; to be in the "plugdev" group to access the USB device.
      ;; Per Guix cookbook §3.4: "Using security keys".
      (udev-rules-service 'fido2 libfido2 #:groups '("plugdev"))

      ;; Declarative firewall — internal-only ports are blocked from
      ;; external access. nginx proxies the gateway WS via /ws on 443.
      ;; Replaces the fragile activation-block iptables calls.
      (service iptables-service-type
               (iptables-configuration
                (ipv4-rules
                 (plain-file
                  "iptables.rules"
                  (string-append
                   ;; Tor-or-die egress. The default OUTPUT policy is DROP
                   ;; so any process whose traffic *isn't* routed through
                   ;; loopback (i.e. through torsocks → 127.0.0.1:9050) is
                   ;; silently blackholed instead of leaking. Only the `tor`
                   ;; user is allowed to make non-localhost connections —
                   ;; that's by definition the one process whose outbound
                   ;; flows constitute Tor itself.
                   "*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
# ── INPUT ────────────────────────────────────────────────────────
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# SSH (deploy + operator access). Rate-limit NEW connections to
# 6/min with burst of 3 — defense-in-depth on top of key-only auth.
# Drops the syn flood / brute-force attempts before they reach sshd.
-A INPUT -p tcp --dport 22 --syn -m conntrack --ctstate NEW -m limit --limit 6/min --limit-burst 3 -j ACCEPT
-A INPUT -p tcp --dport 22 --syn -m conntrack --ctstate NEW -j DROP
-A INPUT -p tcp --dport 22 -j ACCEPT
# Port 80: ONION traffic only. The Tor hidden-service maps 80 →
# 127.0.0.1:80, which arrives over `lo` and is already accepted
# above. Blocking external :80 prevents IP-scanning from
# fingerprinting this host as the playnet origin by fetching the
# same content the .onion serves.
-A INPUT -p tcp --dport 80 -j DROP
# Port 443: CDN-edge ONLY. nginx already returns 444 for
# unknown Host, but that still completes a TCP handshake and TLS
# negotiation — enough for an attacker to fingerprint by
# self-signed cert. The per-CIDR ACCEPTs below are spliced in from
# %cdn-edge-ips so the TCP handshake itself fails for direct
# probes. Update %cdn-edge-ips when the CDN rotates ranges.
"
                   (apply string-append
                          (map (lambda (cidr)
                                 (string-append
                                  "-A INPUT -p tcp -s " cidr
                                  " --dport 443 -j ACCEPT\n"))
                               ;; IPv4 only — iptables can't match v6 CIDRs.
                               ;; v6 ranges from %cdn-edge-ips belong in
                               ;; ip6tables-rules when we wire IPv6 (TODO).
                               (filter (lambda (s)
                                         (not (string-index s #\:)))
                                       %cdn-edge-ips)))
                   "-A INPUT -p tcp --dport 443 -j DROP
# KERI witnesses (public, KEL durability). Range covers the canonical
# 6-witness pool (5642-5647) plus headroom for §2.4 same-host growth
# (up to 58 additional witnesses on 5648-5699 before the rule needs
# extending). Federation-member witnesses operated on hosts NOT
# managed by this machines.scm govern their own firewall — see
# docs/governance/FEDERATION-WITNESSES.md.
-A INPUT -p tcp --dport 5642:5699 -j ACCEPT
# Block internal-only ports from external access
-A INPUT -p tcp --dport 9090 -j DROP
-A INPUT -p tcp --dport 9091 -j DROP
-A INPUT -p tcp --dport 9092 -j DROP
-A INPUT -p tcp --dport 18081 -j DROP
-A INPUT -p tcp --dport 18082 -j DROP
-A INPUT -p tcp --dport 1883 -j DROP
-A INPUT -p tcp --dport 3901:3903 -j DROP
# ── OUTPUT (egress) ──────────────────────────────────────────────
# Loopback covers every torsocks-wrapped service (they connect to
# 127.0.0.1:9050) and every internal RPC (Mosquitto, Monero RPC,
# KERIA, gateway WS).
-A OUTPUT -o lo -j ACCEPT
# Reply traffic for accepted inbound connections.
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Tor itself — the only process allowed to talk to the wider net.
-A OUTPUT -m owner --uid-owner tor -j ACCEPT
# Everything else: silent drop. Any service that 'forgets' torsocks
# fails closed instead of leaking the host's IP.
COMMIT
")))))

      ;; Monero wallet RPC — connects to a remote Monero node through Tor.
      ;; No local monerod needed (saves ~80GB disk + hours of sync).
      ;; The node is an onion service, so the path has no exit node and
      ;; the node never sees the server's IP: it can see WHEN the wallet
      ;; syncs and what it broadcasts, not WHO is asking.
      ;;
      ;; daemon-address: plowsof's onion — a Tor seed node in Monero's own
      ;; source (net_node.inl) and on Feather Wallet's curated list.
      ;; Verified from this box 2026-09-19 with seven other onions of
      ;; independent operators, all at one chain height. The fallback, a
      ;; different operator (Rucknium, Monero Research Lab):
      ;;   rucknium757bokwv3ss35ftgc3gzb7hgbvvglbg3hisp7tsj2fkd2nyd.onion:18081
      ;; trusted-daemon? #f: --trusted-daemon is for a daemon we run.
      (service monero-service-type
               (monero-configuration
                (data-dir       "/var/lib/playnet/monero")
                (daemon-address "plowsof3t5hogddwabaeiyrno25efmzfxyro2vligremt7sxpsclfaid.onion:18089")
                (trusted-daemon? #f)
                ;; This wallet was created 2026-09-16 (tip ≈ 3,763,800);
                ;; a rotation sets this to the new wallet's birth height.
                (restore-height 3760000)
                (user           "playnet")
                ;; The wallet service runs as playnet-wallet and reads
                ;; rpc-login.txt through the service group.
                (rpc-login-group "playnet-svc")))

      ;; Isolated wallet process — runs ^monero-wallet + ^wallet-policy
      ;; in a separate process from the gateway. Exposes only the policy
      ;; actor via OCapN WebSocket on localhost:9092. Gateway resolves the
      ;; sturdyref at /var/lib/playnet/wallet-sref.txt — no raw wallet
      ;; methods reachable from the gateway process.
      ;;
      ;; spend-policy is a Scheme datum in the format produced by
      ;; (serialize-policy) from (playnet monero policy). The activation
      ;; writes it to /var/lib/playnet/wallet-policy.scm; wallet-service
      ;; reads it at startup. Starts with an empty allowlist — the fleet
      ;; reconciler adds per-invoice entries via authorize-invoice before
      ;; each transfer, so direct XMR provider payments work without
      ;; pre-declared addresses.
      (service wallet-service-type
               (wallet-configuration
                (spend-policy
                 '(policy
                    5        ; monthly budget: 5 XMR
                    2        ; default per-tx cap: 2 XMR
                    ()       ; allowlist: populated at runtime by reconciler
                    "playnet production budget"))))

       ;; (The SMS-wall one-shot lived here; it rode the sms module the
       ;; compute-only repo does not carry — see the playnet archive.)

       ;; Activation: materialize /run/secrets/* from the encrypted
      ;; secrets blob (deploy/secrets.scm.age, baked into the system
      ;; via local-file). Runs on every activation — covers both
      ;; reconfigure AND boot, so services that read /run/secrets/*
      ;; survive reboots with zero operator action.
      ;;
      ;; One-time operator bootstrap per host:
      ;;   scp deploy/.age-key.txt root@HOST:/var/lib/playnet/.age-key.txt
      ;;   ssh root@HOST chmod 400 /var/lib/playnet/.age-key.txt
      ;; That's it — the key never enters the Guix store; the
      ;; encrypted blob does (and is encrypted-at-rest), so a leaked
      ;; system gen alone reveals nothing without the key.
      ;;
      ;; Mapping: each entry in %map is
      ;;   (ENV_VAR_NAME file mode group-or-#f)
      ;; The activation extracts each ENV_VAR's value from the
      ;; decrypted setenv-style file and writes it, owner playnet. Add
      ;; entries here when a service needs a secret at run time.
      ;;
      ;; The Monero pair lands where monero-wallet-rpc and the wallet
      ;; service read it, and API_KEYS where the gateway reads it at
      ;; start — so a reconfigure carries PLAYNET_PROVIDER and nothing
      ;; secret, and every secret comes from the blob. rpc-login.txt is
      ;; group-readable to playnet-svc for the wallet service (the same
      ;; mode monero-configuration's rpc-login-group keeps). The wallet
      ;; SEED stays out of this map on purpose: it is a cold-start input
      ;; (MONERO_WALLET_SEED exported once, when no wallet file exists)
      ;; and has no business resting decrypted on a running box.
      (simple-service 'install-runtime-secrets
                      activation-service-type
                      (let ((secrets-blob (local-file "secrets.scm.age"))
                            (age-bin (file-append age "/bin/age")))
                        #~(begin
                            (use-modules (guix build utils)
                                         (ice-9 popen)
                                         (ice-9 regex)
                                         (ice-9 textual-ports))
                            (define %map
                              ;; (env-var file mode group-or-#f)
                              `(#$@(map (lambda (var)
                                          `(,var ,(%secret-file-for var) #o400 #f))
                                        %fleet-credential-vars)
                                #$@(if %cdn
                                       `((,(assq-ref %cdn 'credential) ,%cdn-key-file #o400 #f))
                                       '())
                                #$@(if (and %mail (assq-ref %mail 'user))
                                       `(("SMTP_PASSWORD" ,%smtp-password-file #o400 #f))
                                       '())
                                ("RAD_PASSPHRASE"    "/run/secrets/rad-passphrase"      #o400 #f)
                                ("PLAYNET_VAULT_KEY" "/run/secrets/playnet-vault-key"   #o400 #f)
                                ("KERIA_BRAN"        "/run/secrets/keria-bran"          #o400 #f)
                                ("API_KEYS"          "/run/secrets/api-keys"            #o400 #f)
                                ("MONERO_WALLET_PASSWORD"
                                 "/var/lib/playnet/monero/wallet-password.txt"          #o600 #f)
                                ("MONERO_RPC_PASSWORD"
                                 "/var/lib/playnet/monero/rpc-login.txt"                #o640 "playnet-svc")))
                            (define age-key "/var/lib/playnet/.age-key.txt")
                            (define run-dir "/run/secrets")
                            (define (log* fmt . args)
                              (apply format #t (string-append "[secrets] " fmt "~%") args))
                            (cond
                             ((not (file-exists? age-key))
                              (log* "~a missing — operator-bootstrap needed (scp it once, mode 400); skipping" age-key))
                             (else
                              (mkdir-p run-dir)
                              (chmod run-dir #o755)
                              (let* ((cmd  (string-append #$age-bin " -d -i "
                                                          age-key " " #$secrets-blob))
                                     (port (open-input-pipe cmd))
                                     (text (get-string-all port))
                                     (st   (close-pipe port)))
                                (cond
                                 ((not (zero? st))
                                  (log* "age decryption failed (status ~a) — secrets not refreshed" st))
                                 (else
                                  (for-each
                                   (lambda (entry)
                                     (let* ((var   (car entry))
                                            (path  (cadr entry))
                                            (mode  (caddr entry))
                                            (group (cadddr entry))
                                            ;; Match (setenv "VAR" "VALUE") tolerantly:
                                            ;; allow any non-quote chars in VALUE
                                            ;; (Monero seed has spaces, etc.).
                                            ;; var names are [A-Z_]+ — no regex
                                            ;; metachars, so no escaping needed.
                                            (rx   (make-regexp
                                                   (string-append
                                                    "\\(setenv \""
                                                    var
                                                    "\" \"([^\"]*)\"\\)")))
                                            (m    (regexp-exec rx text))
                                            (pw   (getpwnam "playnet")))
                                       (cond
                                        ((not m)
                                         (log* "~a not found in decrypted secrets — skipping ~a"
                                               var path))
                                        (else
                                         (let ((val (match:substring m 1)))
                                           (mkdir-p (dirname path))
                                           (call-with-output-file path
                                             (lambda (p) (put-string p val)))
                                           (chmod path mode)
                                           (chown path (passwd:uid pw)
                                                  (if group
                                                      (group:gid (getgrnam group))
                                                      (passwd:gid pw)))
                                           (log* "wrote ~a (~a bytes, mode ~a, owner playnet~a)"
                                                 path (string-length val)
                                                 (number->string mode 8)
                                                 (if group (string-append ":" group) "")))))))
                                   %map)))))))))

      ;; Activation: set up playnet user environment.
      ;; Uses mkdir-p because on first deploy, user-homes may not have
      ;; created the home directory yet when activation runs.
      (simple-service 'playnet-setup
                      activation-service-type
                      #~(begin
                          (use-modules (guix build utils)
                                       (ice-9 ftw)       ; scandir (for the seeded check)
                                       (ice-9 format))
                          (let ((pw (getpwnam "playnet")))
                            ;; Home directory (mkdir-p may create it before user-homes).
                            ;; 0711 lets other service users (deploy-runner,
                            ;; reconciler, liveness, etc.) traverse into
                            ;; /home/playnet/playnet-repo for shared source
                            ;; without being able to list playnet's HOME.
                            ;; Default user-account home mode is 0700 which
                            ;; breaks every service that runs as a different
                            ;; user and references a path inside this tree.
                            (mkdir-p "/home/playnet")
                            (chown "/home/playnet" (passwd:uid pw) (passwd:gid pw))
                            (chmod "/home/playnet" #o711)
                            ;; The fleet's provisioning key: the public half is
                            ;; handed to each host the reconciler launches, the
                            ;; private half is how the deploy runner reaches it.
                            ;; Made once, on the box, and kept across
                            ;; reconfigures and reboots; it never leaves.
                            (let* ((ssh-dir "/home/playnet/.ssh")
                                   (key (string-append ssh-dir "/id_ed25519")))
                              (mkdir-p ssh-dir)
                              (chown ssh-dir (passwd:uid pw) (passwd:gid pw))
                              (chmod ssh-dir #o700)
                              (unless (file-exists? key)
                                (system* #$(file-append openssh-sans-x "/bin/ssh-keygen")
                                         "-q" "-t" "ed25519" "-N" ""
                                         "-C" "playnet-fleet" "-f" key)
                                (for-each (lambda (f)
                                            (when (file-exists? f)
                                              (chown f (passwd:uid pw) (passwd:gid pw))))
                                          (list key (string-append key ".pub")))))
                            ;; Socket directory for REPL (playnet-writable, on tmpfs)
                            (let ((run-dir "/var/run/playnet"))
                              (mkdir-p run-dir)
                              (chown run-dir (passwd:uid pw) (passwd:gid pw)))
                            ;; Identity tags for the playnet-liveness
                            ;; heartbeat publisher. Both values come
                            ;; straight from the provider config and
                            ;; are rewritten on every reconfigure —
                            ;; declarative end-to-end.
                            (let ((id-dir "/etc/playnet"))
                              (mkdir-p id-dir)
                              (call-with-output-file
                                  (string-append id-dir "/host-id")
                                (lambda (p)
                                  (display #$(or (provider-ref 'host-name)
                                                 "playnet") p)))
                              (call-with-output-file
                                  (string-append id-dir "/provider-tag")
                                (lambda (p)
                                  (display #$(or (provider-ref 'provider-tag)
                                                 "unknown") p)))
                              (chmod (string-append id-dir "/host-id") #o644)
                              (chmod (string-append id-dir "/provider-tag") #o644)
                              ;; The deployment's CDN, for deploy/scripts/cdn.scm
                              ;; and the fleet. A box without one has no file.
                              (let ((conf (string-append id-dir "/cdn.conf")))
                                (if '#$%cdn
                                    (begin
                                      (call-with-output-file conf
                                        (lambda (p)
                                          (write '#$(and %cdn
                                                         `((adapter . ,(assq-ref %cdn 'adapter))
                                                           (zone . ,(assq-ref %cdn 'zone))
                                                           (origin . ,(assq-ref %cdn 'origin))
                                                           (key-file . ,%cdn-key-file)))
                                                 p)))
                                      (chmod conf #o644))
                                    (when (file-exists? conf)
                                      (delete-file conf)))))
                            ;; Mosquitto auth — password file + ACL
                            ;; Only the playnet user's processes can
                            ;; publish signals (fleet, planner, dev-bridge).
                            (let ((mqtt-dir "/var/lib/playnet/mosquitto")
                                  (mqtt-pw  #$(or (getenv "MOSQUITTO_PASSWORD") "playnet-mqtt")))
                              (mkdir-p mqtt-dir)
                              (chown mqtt-dir (passwd:uid pw) (passwd:gid pw))
                              ;; Per-service MQTT users + topic-restricted ACLs.
                              ;; Each service gets its own MQTT username + password
                              ;; + specific topic permissions. A compromised dev-bridge
                              ;; can read deficit signals but CANNOT publish
                              ;; fleet-changed or trigger auto-deploy.
                              (call-with-output-file
                                  (string-append mqtt-dir "/acl")
                                (lambda (port)
                                  ;; publisher: planner signal-publisher writes all signals
                                  (format port "user publisher~%")
                                  (format port "topic write playnet/signals/#~%")
                                  (format port "~%")
                                  ;; dev-bridge: reads deficit + liveness signals,
                                  ;; writes ONLY its own narrow alert topic — never
                                  ;; playnet/signals/# (that stays publisher-only,
                                  ;; so a compromised dev-bridge still cannot
                                  ;; trigger fleet-changed or auto-deploy)
                                  (format port "user dev-bridge~%")
                                  (format port "topic read playnet/signals/deficit/#~%")
                                  (format port "topic read playnet/signals/liveness/#~%")
                                  (format port "topic write playnet/alerts/dev-bridge~%")
                                  (format port "~%")
                                  ;; reconciler: writes fleet-changed only
                                  (format port "user reconciler~%")
                                  (format port "topic write playnet/signals/fleet-changed~%")
                                  (format port "~%")
                                  ;; deploy-runner: reads fleet-changed only
                                  (format port "user deploy-runner~%")
                                  (format port "topic read playnet/signals/fleet-changed~%")
                                  (format port "~%")
                                  ;; liveness: writes its own host's heartbeat only
                                  (format port "user liveness~%")
                                  (format port "topic write playnet/signals/liveness/#~%")
                                  (format port "~%")
                                  ;; host-facts: writes the host's retained
                                  ;; capacity/placement snapshot only
                                  ;; (tools/dev/host-facts.scm --publish, on the
                                  ;; mcron timer below)
                                  (format port "user host-facts~%")
                                  (format port "topic write playnet/facts/host/#~%")
                                  (format port "~%")
                                  ;; gateway: reads the retained host snapshots
                                  ;; into the founding commune's live-registry
                                  ;; (facts-sync.scm) — read-only on the wire
                                  (format port "user gateway~%")
                                  (format port "topic read playnet/facts/#~%")))
                              ;; Generate separate password files per MQTT user.
                              ;; Each service reads its own password file (0600).
                              (let ((passwd-file (string-append mqtt-dir "/passwd"))
                                    (mpw (lambda (name)
                                           (string-append mqtt-pw "-" name))))
                                ;; Combined hashed password file for Mosquitto.
                                ;; REGENERATED EVERY ACTIVATION, in lockstep with
                                ;; the plaintext pw-<user>.txt files just below —
                                ;; a real bug lived here: this used to run only
                                ;; `unless (file-exists? passwd-file)`, so the
                                ;; FIRST activation's hash was frozen forever
                                ;; while the plaintext files kept being rewritten
                                ;; on every later reconfigure from whatever
                                ;; MOSQUITTO_PASSWORD the operator's shell
                                ;; happened to have exported that time (or the
                                ;; "playnet-mqtt" fallback when it didn't) — any
                                ;; reconfigure after the first with a different
                                ;; env silently drifted the plaintext files away
                                ;; from what mosquitto actually authenticates
                                ;; against, and every MQTT-publishing service
                                ;; (dev-bridge, fleet-bridge, tools/dev-signal-
                                ;; cycle.scm, tools/dev/dev-loop-close.scm) failed
                                ;; auth with no clue why. mosquitto_passwd -b -c
                                ;; is deterministic given the same input, so
                                ;; running it every activation is exactly as
                                ;; declarative as the plaintext files beside it
                                ;; already were — self-healing, not a new risk.
                                ;; Start from no file: mosquitto_passwd runs
                                ;; here as root and warns ("owner is not
                                ;; root … future versions will refuse") on
                                ;; every call against the broker-owned file
                                ;; the previous activation left. A fresh
                                ;; file is root's until the chown below
                                ;; hands it to the broker's user.
                                (when (file-exists? passwd-file)
                                  (delete-file passwd-file))
                                (system* #$(file-append mosquitto "/bin/mosquitto_passwd")
                                         "-b" "-c" passwd-file
                                         "publisher" (mpw "publisher"))
                                (for-each
                                 (lambda (user)
                                   (system* #$(file-append mosquitto "/bin/mosquitto_passwd")
                                            "-b" passwd-file
                                            user (mpw user)))
                                 '("dev-bridge" "reconciler" "deploy-runner" "liveness" "host-facts" "gateway"))
                                (chmod passwd-file #o600)
                                (chown passwd-file (passwd:uid pw) (passwd:gid pw))
                                ;; Per-service plaintext password files
                                (for-each
                                 (lambda (user)
                                   (let ((f (string-append mqtt-dir "/pw-" user ".txt")))
                                     (call-with-output-file f
                                       (lambda (port) (display (mpw user) port)))
                                     (chmod f #o600)
                                     (chown f (passwd:uid pw) (passwd:gid pw))))
                                 '("publisher" "dev-bridge" "reconciler" "deploy-runner" "liveness" "host-facts" "gateway"))))
                            ;; Firewall moved to iptables-service-type (declarative).
                            ;; See the (service iptables-service-type ...) block below.
                            ;; Emacs config
                            (let* ((emacs-dir "/home/playnet/.emacs.d")
                                   (init-target (string-append emacs-dir "/init.el")))
                              (mkdir-p emacs-dir)
                              (when (file-exists? init-target)
                                (delete-file init-target))
                              (copy-file #$%emacs-init-el init-target)
                              (chown init-target (passwd:uid pw) (passwd:gid pw))
                              (chown emacs-dir (passwd:uid pw) (passwd:gid pw)))
                            ;; Helper scripts
                            (let* ((bin-dir "/home/playnet/bin")
                                   (repl-eval (string-append bin-dir "/repl-eval")))
                              (mkdir-p bin-dir)
                              (when (file-exists? repl-eval)
                                (delete-file repl-eval))
                              (copy-file #$%repl-eval-script repl-eval)
                              (chmod repl-eval #o755)
                              (chown repl-eval (passwd:uid pw) (passwd:gid pw))
                              (chown bin-dir (passwd:uid pw) (passwd:gid pw)))
                            ;; Mutable checkout for hot-reload (git pull, no rebuild).
                            ;; The hot-reload workflow rsyncs module/, server/,
                            ;; planner/ directly into this directory. On a fresh
                            ;; install the directory is empty, so services that
                            ;; reference files inside it (radicle-ci-hook.sh,
                            ;; server/fleet-bridge.scm, server/dev-bridge.scm,
                            ;; deploy/scripts/playnet-liveness.sh, etc.) crash
                            ;; with ENOENT. Seed it from the immutable Guix
                            ;; package's share/playnet tree so every service
                            ;; has a working starting point; operators can
                            ;; still rsync over it for live hacking.
                            (let* ((repo-dir "/home/playnet/playnet-repo")
                                   (seed-src (string-append
                                              #$%playnet-package
                                              "/share/playnet"))
                                   (sentinel (string-append
                                              repo-dir "/.playnet-seeded")))
                              ;; If it's an old immutable symlink, remove it
                              (when (and (file-exists? repo-dir)
                                         (symbolic-link? repo-dir))
                                (delete-file repo-dir))
                              (unless (file-exists? repo-dir)
                                (mkdir-p repo-dir)
                                (chown repo-dir (passwd:uid pw) (passwd:gid pw)))
                              ;; Seed once: if sentinel is missing AND the
                              ;; repo is empty (operator hasn't rsynced
                              ;; anything yet), copy the package source in.
                              ;; The sentinel protects against re-seeding on
                              ;; every reconfigure once the operator starts
                              ;; hot-reloading their own changes.
                              (unless (file-exists? sentinel)
                                (when (or (not (file-exists?
                                                (string-append repo-dir
                                                               "/server")))
                                          (null? (scandir repo-dir
                                                          (lambda (n)
                                                            (not (member n
                                                                         '("." ".."
                                                                           ".playnet-seeded")))))))
                                  (copy-recursively seed-src repo-dir
                                                    #:keep-mtime? #t)
                                  (system* "chown" "-R"
                                           (string-append
                                            (number->string (passwd:uid pw))
                                            ":"
                                            (number->string (passwd:gid pw)))
                                           repo-dir)
                                  (call-with-output-file sentinel
                                    (lambda (p) (display "seeded\n" p)))
                                  (chown sentinel (passwd:uid pw)
                                         (passwd:gid pw)))))
                            ;; Dev checkout symlink. Preferred target: the
                            ;; agent's own rad clone (a REAL git repo with a
                            ;; `rad` remote — created once per box with
                            ;; `rad clone` as playnet; dev-bridge's workflow
                            ;; needs git fetch/branch/push, which the rsync'd
                            ;; playnet-repo cannot do). Falls back to the
                            ;; rsync target so a box without the clone still
                            ;; has a readable checkout for prompts/paths.
                            (let* ((dev-dir "/home/playnet/dev-checkout")
                                   (agent   "/home/playnet/agent-checkout")
                                   (target  (if (file-exists? agent)
                                                agent
                                                "/home/playnet/playnet-repo")))
                              (when (and (file-exists? dev-dir)
                                         (not (symbolic-link? dev-dir)))
                                ;; Old git clone — remove it
                                (system* "rm" "-rf" dev-dir))
                              ;; re-point a symlink whose target is stale
                              (when (and (symbolic-link? dev-dir)
                                         (not (string=? (readlink dev-dir) target)))
                                (delete-file dev-dir))
                              (unless (or (symbolic-link? dev-dir)
                                          (file-exists? dev-dir))
                                (symlink target dev-dir))))))

      ;; Activation: set up dynamic user home directories.
      ;; For each user in users.scm: ensure home exists, correct ownership,
      ;; and symlink to packaged code.
      (simple-service 'dynamic-user-setup
                      activation-service-type
                      #~(begin
                          (use-modules (guix build utils))
                          (for-each
                           (lambda (username)
                             (let* ((home     (string-append "/home/" username))
                                    (repo-dir (string-append home "/playnet-repo"))
                                    (bin-dir  (string-append home "/bin"))
                                    (pw       (false-if-exception (getpwnam username))))
                               (when pw
                                 ;; Home dir
                                 (mkdir-p home)
                                 (chown home (passwd:uid pw) (passwd:gid pw))
                                 ;; ~/bin
                                 (mkdir-p bin-dir)
                                 (chown bin-dir (passwd:uid pw) (passwd:gid pw))
                                 ;; Shared mutable checkout (symlink to playnet's copy)
                                 (when (and (file-exists? repo-dir)
                                            (symbolic-link? repo-dir))
                                   (delete-file repo-dir))
                                 (unless (file-exists? repo-dir)
                                   (symlink "/home/playnet/playnet-repo" repo-dir)))))
                           '#$%dynamic-user-names)))

       ) ;; end of services list

      ;; Substitute servers — clearnet for speed. The Tor onion path
      ;; (4zwzi66…onion) was the original choice for unlinkability of
      ;; download patterns, but in practice the onion server is slow /
      ;; flaky enough to hang `guix deploy` for 30+ minutes. Use the
      ;; clearnet Guix servers; download patterns are de-anonymising
      ;; only to the substitute server operator (an upstream we're
      ;; already trusting for binary integrity via signing keys).
      (modify-services %base-services
        ;; Hourly rotation of every shepherd-logged service, as the tmpfs
        ;; comment above and the privacy notice (§2.1, product.scm's
        ;; log-rotation fact) state. Guix's default calendar is Sunday
        ;; 22:00 — the 2026-09-06 ENOSPC was that rotation, a week of logs
        ;; zstd'd at once; an hour's worth at a time keeps the 256M tmpfs
        ;; far from full now that the gateway and valhalla log there too.
        (log-rotation-service-type config =>
          (log-rotation-configuration
           (inherit config)
           (calendar-event #~(calendar-event #:minutes '(0)))))
        (guix-service-type config =>
          (guix-configuration
           (inherit config)
           (substitute-urls
            '("https://bordeaux.guix.gnu.org"
              "https://ci.guix.gnu.org"))
           ;; Route substitute downloads through Tor's HTTP CONNECT
           ;; proxy. Without this, guix-daemon's substituter does
           ;; plain DNS + clearnet HTTPS, which fails on this host
           ;; because outbound port 53 / 80 / 443 are firewall-locked
           ;; (only CDN edge IPs in, Tor out). The proxy port is
           ;; declared in the torrc above (HTTPTunnelPort 9080).
           ;; Cascading benefit: `guix pull` and `guix system
           ;; reconfigure` from the server itself now work, which
           ;; unlocks the small-closure path in deploy/os.scm.
           (http-proxy "http://127.0.0.1:9080")
           (authorized-keys
            (cons* (local-file "/etc/guix/signing-key.pub")
                   ;; Operator build/dev machine — authorized to `guix copy`
                   ;; pre-built closures to this box (the tor-only box can't
                   ;; compile large Rust trees like the CI broker, so we build
                   ;; on a clearnet Guix machine and copy). Public key material;
                   ;; a new operator swaps in their own build machine's key
                   ;; (the contents of /etc/guix/signing-key.pub on that box).
                   (plain-file "operator-build-guix.pub"
                    "(public-key (ecc (curve Ed25519) (q #D8998AAB89348D5ED2D1B134EB9E4BAE1F5F0B1499462C101146898473109EAB#)))")
                   (guix-configuration-authorized-keys config))))))))))

;;; ── File-as-value: `guix system reconfigure deploy/os.scm`
;;; reads the last top-level expression as the operating-system.
%guix-x86
