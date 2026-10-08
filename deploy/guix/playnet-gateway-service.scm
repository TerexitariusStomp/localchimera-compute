;;; deploy/guix/playnet-gateway-service.scm — Shepherd service for the OCapN gateway
;;;
;;; Runs the playnet OCapN gateway from the Guix package (immutable store).
;;; Replaces playnet-relay-service.scm.  Provides capability-secure access
;;; to signup, transcription, presence, terminal, and messaging via
;;; OCapN CapTP over WebSocket and Reticulum.
;;;
;;; Usage in machines.scm:
;;;   (service playnet-gateway-service-type
;;;            (playnet-gateway-configuration
;;;             (package playnet)
;;;             (port 9090)))

(define-module (playnet-gateway-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages crypto) ; libsodium — dlopen'd by playnet/keri/signify.scm
  #:use-module (gnu packages gnupg)  ; libgcrypt — dlopen'd by playnet/push/crypto.scm
  #:use-module (blake3)              ; libblake3 — dlopen'd by playnet/keri/blake3.scm
  ;; corpus-guile-native.md phase 4 (hybrid corpus search, entirely in
  ;; Guile): onnxruntime is dynamic-linked by playnet/ai/onnx-embed.scm
  ;; (an absolute ONNXRUNTIME_LIB, not a bare-name search — see that
  ;; module's own comment on why); guile-sqlite3 is a Guile MODULE
  ;; (playnet/gateway/corpus-service.scm's `(sqlite3)`), so it needs both
  ;; its .scm and its .go on the load paths below, the same as guile-next
  ;; itself does via GUILE_LOAD_PATH/GUILE_LOAD_COMPILED_PATH.
  #:use-module (gnu packages machine-learning) ; onnxruntime
  #:use-module (gnu packages guile)            ; guile-sqlite3
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-gateway-configuration
            playnet-gateway-configuration?
            playnet-gateway-configuration-package
            playnet-gateway-configuration-port
            playnet-gateway-configuration-user
            playnet-gateway-configuration-group
            playnet-gateway-configuration-data-dir
            playnet-gateway-configuration-reticulum?
            playnet-gateway-configuration-vault-key-file
            playnet-gateway-configuration-keria-bran-file
            playnet-gateway-configuration-secret-environment-files
            playnet-gateway-configuration-environment
            playnet-gateway-configuration-supplementary-groups
            playnet-gateway-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <playnet-gateway-configuration>
  playnet-gateway-configuration make-playnet-gateway-configuration
  playnet-gateway-configuration?
  ;; The playnet Guix package (provides bin/playnet-gateway)
  (package  playnet-gateway-configuration-package)
  ;; WebSocket listen port
  (port     playnet-gateway-configuration-port     (default 9090))
  ;; User to run as
  (user     playnet-gateway-configuration-user     (default "playnet"))
  ;; Primary group of the gateway process. Shepherd's exec-command applies
  ;; #:supplementary-groups only together with a #:group, and a process
  ;; started with a #:user alone keeps shepherd's own gid 0 — so the group
  ;; is always named.
  (group    playnet-gateway-configuration-group    (default "users"))
  ;; Persistent data directory (designator key, sturdyref, etc.)
  (data-dir playnet-gateway-configuration-data-dir (default "/var/lib/playnet"))
  ;; Enable Reticulum netlayer (requires reticulum-bridge service)
  (reticulum? playnet-gateway-configuration-reticulum? (default #f))
  ;; File containing PLAYNET_VAULT_KEY (64-char hex). Materialized at
  ;; activation from secrets.scm.age (mode 0400, owned by playnet).
  ;; When missing, the gateway boots in synthetic mode — UC mints
  ;; unsigned and brans are not encrypted at rest.
  (vault-key-file playnet-gateway-configuration-vault-key-file
                  (default "/run/secrets/playnet-vault-key"))
  ;; File containing KERIA_BRAN (21-char CESR passcode). Materialized at
  ;; activation from secrets.scm.age (mode 0400, owned by playnet) —
  ;; same treatment as vault-key-file, not the store-embedded `environment`
  ;; alist below: this passcode derives the signing keys for the whole
  ;; witness-pool-facing KERI identity, so it never enters the Guix store,
  ;; process table, or shepherd .go cache. When missing, the gateway boots
  ;; with the KERIA client tier off (see gateway.scm's `unless bran` log line).
  (keria-bran-file playnet-gateway-configuration-keria-bran-file
                    (default "/run/secrets/keria-bran"))
  ;; Variables whose values are read from files at process start: an alist
  ;; of (VAR . file). The files are materialized by os.scm's
  ;; install-runtime-secrets, so the values stay out of the store, and the
  ;; deployment names them — the LLM key pool (API_KEYS), and the hosting
  ;; credentials the provider config lists under `fleet-credentials` — so
  ;; which credentials a box holds is a fact of that box. A present,
  ;; non-empty file is the value and replaces any entry of the same name in
  ;; `environment`; a missing or empty file leaves `environment` standing.
  (secret-environment-files
   playnet-gateway-configuration-secret-environment-files
   (default '(("API_KEYS" . "/run/secrets/api-keys"))))
  ;; Environment variables (alist of string . string pairs)
  (environment playnet-gateway-configuration-environment (default '()))
  ;; Extra groups for the gateway process. The wallet's sturdyref is
  ;; readable through the service group, never world-readable, so the
  ;; gateway holds that group here.
  (supplementary-groups playnet-gateway-configuration-supplementary-groups
                        (default '())))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (playnet-gateway-shepherd-service config)
  (let ((package        (playnet-gateway-configuration-package config))
        (port           (playnet-gateway-configuration-port config))
        (user           (playnet-gateway-configuration-user config))
        (group          (playnet-gateway-configuration-group config))
        (extra-groups   (playnet-gateway-configuration-supplementary-groups config))
        (secret-env-files (playnet-gateway-configuration-secret-environment-files config))
        (data-dir       (playnet-gateway-configuration-data-dir config))
        (reticulum?     (playnet-gateway-configuration-reticulum? config))
        (vault-key-file (playnet-gateway-configuration-vault-key-file config))
        (keria-bran-file (playnet-gateway-configuration-keria-bran-file config))
        (env            (playnet-gateway-configuration-environment config)))
    (list
     (shepherd-service
      (provision '(playnet-gateway))
      (documentation "playnet OCapN gateway — capability-secure communication hub")
      (requirement (if reticulum?
                       '(networking user-processes reticulum-bridge)
                       '(networking user-processes)))
      (start
       ;; Run from mutable checkout so hot-reload works without rebuild.
       ;; Falls back to the Guix store package if the checkout is missing.
       ;;
       ;; (lambda args (apply … args)): shepherd evaluates this gexp
       ;; ONCE at conf load — without the wrapper the environment list
       ;; (witness manifest, vault key) is baked into the constructor
       ;; closure at BOOT and `herd restart` never re-reads the files.
       ;; The wrapper rebuilds the constructor on every start.
       #~(lambda args
           (apply
            (let* ((mutable-dir "/home/playnet/playnet-repo")
                (store-dir   (string-append #$package "/share/playnet"))
                (base        (if (file-exists? (string-append mutable-dir "/server"))
                                 mutable-dir store-dir))
                (torsocks    #$(file-append (@ (gnu packages tor) torsocks)
                                            "/bin/torsocks"))
                (guile       #$(file-append (@ (gnu packages guile) guile-next)
                                            "/bin/guile")))
           ;; Run under torsocks: all outgoing TCP routes through Tor.
           ;; torsocks DENIES outbound localhost by default (EPERM on
           ;; connect) — that blocks the gateway from reaching its LOCAL
           ;; witness pool (127.0.0.1:5642+) and KERIA, so live-KERI mints
           ;; fail and scopes fall back to synthetic. TORSOCKS_CONF_FILE
           ;; (below) sets AllowOutboundLocalhost 1 to permit those while
           ;; still routing external TCP through Tor.
           (make-forkexec-constructor
            (list torsocks guile
                  "--no-auto-compile"
                  "-L" (string-append base "/module")
                  "-L" (string-append base "/deploy")
                  "-s" (string-append base "/server/gateway.scm")
                  ;; Bind localhost only: nginx proxies /ws → 127.0.0.1:9090
                  ;; and that's the only consumer. Defense-in-depth on top
                  ;; of the iptables :9090 DROP rule.
                  "--host" "127.0.0.1"
                  "--port" #$(number->string port)
                  #$@(if reticulum? '("--reticulum") '()))
            #:user #$user
            #:group #$group
            #:supplementary-groups '#$extra-groups
            #:directory base
            #:environment-variables
            (append
             (list (string-append "HOME=" #$data-dir)
                   (string-append "PLAYNET_DATA_DIR=" #$data-dir)
                   ;; Let the gateway accept inbound WebSocket connections
                   ;; on :9090 while still routing outbound TCP through Tor.
                   ;; Without this torsocks raises EPERM from listen(2), the
                   ;; WS server never binds, nginx /ws → 9090 returns
                   ;; "connection refused", and the browser falls through
                   ;; all gateway entries with `Operation not permitted`.
                   "TORSOCKS_ALLOW_INBOUND=1"
                   ;; make-forkexec-constructor's #:environment-variables
                   ;; REPLACES the process environment wholesale — with no
                   ;; PATH, any bare-command subprocess the gateway shells
                   ;; out to (mosquitto_sub/_pub, via facts-sync.scm's
                   ;; mqtt-subscribe) fails execvp with "No such file or
                   ;; directory", found live when facts-sync's
                   ;; subscription thread first ran here.
                   "PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin"
                   ;; Permit outbound localhost so the gateway can reach the
                   ;; local witness pool + KERIA (torsocks denies it by
                   ;; default → EPERM → silent synthetic minting). External
                   ;; TCP still routes through Tor (TorPort 9050).
                   (string-append
                    "TORSOCKS_CONF_FILE="
                    #$(plain-file "playnet-gateway-torsocks.conf"
                                  "TorAddress 127.0.0.1\nTorPort 9050\nAllowInbound 1\nAllowOutboundLocalhost 1\n"))
                   ;; guile-sqlite3 (playnet/gateway/corpus-service.scm's
                   ;; `(sqlite3)`) needs its own .scm AND .go on these two
                   ;; paths — a Guix package's guile module is not visible
                   ;; to the interpreter just because the package is an
                   ;; input; it has to be added the same way guile-next's
                   ;; own site directories already are, one level up.
                   (string-append "GUILE_LOAD_PATH="
                    "/run/current-system/profile/share/guile/site/3.0:"
                    #$(file-append guile-sqlite3 "/share/guile/site/3.0") ":"
                    base "/module")
                   (string-append "GUILE_LOAD_COMPILED_PATH="
                    "/run/current-system/profile/lib/guile/3.0/site-ccache:"
                    #$(file-append guile-sqlite3 "/lib/guile/3.0/site-ccache"))
                   ;; playnet/keri/{signify,blake3}.scm dlopen libsodium.so
                   ;; and libblake3.so at load time; without LD_LIBRARY_PATH
                   ;; the gateway falls back to the synthetic KERI backend
                   ;; (UC mints unsigned, no KEL anchoring). Use the build-
                   ;; time store path so the value is captured in the
                   ;; shepherd .go file.
                   ;; playnet/push/crypto.scm (Web Push AES-GCM/ECDH)
                   ;; dlopens libgcrypt.so the same way — without it the
                   ;; whole gateway fails at module load, not soft-degrade.
                   (string-append "LD_LIBRARY_PATH="
                                  #$(file-append libsodium "/lib") ":"
                                  #$(file-append blake3 "/lib") ":"
                                  #$(file-append libgcrypt "/lib"))
                   ;; corpus-guile-native.md phase 3: onnx-embed.scm's
                   ;; %default-lib-path is a hardcoded, checkout-specific
                   ;; store hash — it goes stale on every onnxruntime
                   ;; rebuild. ONNXRUNTIME_LIB set here, from THIS build's
                   ;; own #$(file-append …), is always correct: Guix
                   ;; recomputes it whenever the service itself rebuilds,
                   ;; the same way LD_LIBRARY_PATH above never goes stale
                   ;; for libsodium/blake3/libgcrypt either.
                   (string-append "ONNXRUNTIME_LIB="
                                  #$(file-append onnxruntime "/lib/libonnxruntime.so"))
                   ;; phase 4's gateway door (corpus-service.scm) needs
                   ;; ONE anchor for docs/corpus/ — see that module's own
                   ;; comment on why a derived (current-filename-based)
                   ;; path was tried and rejected as unreliable. `base` is
                   ;; already this same repo checkout (#:directory below
                   ;; sets the process's cwd to it too), so this is
                   ;; belt-and-suspenders explicit rather than relying on
                   ;; corpus-service.scm's own (getcwd) fallback alone.
                   (string-append "PLAYNET_CORPUS_DIR=" base "/docs/corpus")
                   ;; The laws every scope stands under: a folder of rule-packs
                   ;; (legal-registry.scm `load-rule-packs`, *.sexp in name
                   ;; order), read into each new scope root's ^legal-registry
                   ;; (scope-root.scm spawn-scope-root #:law-packs, handed by
                   ;; the gateway) and folded into every solve. Under DATA-DIR, not the
                   ;; checkout: packs are steward-curated state that outlives
                   ;; a redeploy and never enters the store. An absent or
                   ;; empty folder ⇒ no rules ⇒ the solve is byte-identical.
                   (string-append "PLAYNET_LAW_PACKS=" #$data-dir "/law"))
             ;; Read PLAYNET_VAULT_KEY from /run/secrets at start time so
             ;; the hex value never enters the Guix store, process table,
             ;; or shepherd .go cache. Soft-degrade: if the file isn't
             ;; provisioned, the var is unset and host-vault-key signals
             ;; the synthetic fallback (UC mints unsigned).
             (if (file-exists? #$vault-key-file)
                 (list (string-append
                        "PLAYNET_VAULT_KEY="
                        (call-with-input-file #$vault-key-file
                          (@ (ice-9 rdelim) read-line))))
                 '())
             ;; KERIA_BRAN read from /run/secrets at start time, same
             ;; reasoning as PLAYNET_VAULT_KEY above: the passcode never
             ;; enters the Guix store, process table, or shepherd .go
             ;; cache. Soft-degrade: file missing → var unset → gateway.scm
             ;; logs the tier OFF and continues local-durable.
             (if (file-exists? #$keria-bran-file)
                 (list (string-append
                        "KERIA_BRAN="
                        (call-with-input-file #$keria-bran-file
                          (@ (ice-9 rdelim) read-line))))
                 '())
             ;; Witnessing (same-box pool for now; separate infra later).
             ;; The keria activation dumps "<name> <port> <aid>" lines to
             ;; witness-aids — AIDs are box-specific (fresh salts at first
             ;; deploy) so they are read at START, never baked in. First
             ;; three witnesses, toad 2: scope AIDs mint witnessed (the
             ;; Scheme receiptor collects receipts at inception and the
             ;; served OOBI carries them past resolver escrow). Soft-
             ;; degrade: no manifest → vars unset → witnessless minting.
             (let ((manifest "/var/lib/playnet/keria/witness-aids"))
               (if (file-exists? manifest)
                   (let* ((lines (call-with-input-file manifest
                                   (lambda (p)
                                     (let loop ((acc '()))
                                       (let ((l ((@ (ice-9 rdelim) read-line) p)))
                                         (if (eof-object? l)
                                             (reverse acc)
                                             (loop (cons l acc))))))))
                          (picked (if (> (length lines) 3)
                                      (list-head lines 3)
                                      lines))
                          (fields (map (lambda (l) (string-split l #\space))
                                       picked)))
                     (if (null? fields)
                         '()
                         (list
                          (string-append
                           "PLAYNET_WITNESS_AIDS="
                           ((@ (srfi srfi-13) string-join) (map caddr fields) ","))
                          (string-append
                           "PLAYNET_WITNESS_OOBIS="
                           ((@ (srfi srfi-13) string-join)
                            (map (lambda (f)
                                   (string-append "http://127.0.0.1:" (cadr f)
                                                  "/oobi/" (caddr f)
                                                  "/controller"))
                                 fields)
                            ","))
                          "PLAYNET_WITNESS_TOAD=2")))
                   '()))
             ;; secret-environment-files, read at start time — same reasoning
             ;; as PLAYNET_VAULT_KEY above.
             (let* ((secret-line
                     (lambda (file)
                       (and (file-exists? file)
                            (let ((line (call-with-input-file file
                                          (@ (ice-9 rdelim) read-line))))
                              (and (string? line)
                                   (not (string-null? line))
                                   line)))))
                    (from-files
                     (filter cdr
                             (map (lambda (kv)
                                    (cons (car kv) (secret-line (cdr kv))))
                                  '#$secret-env-files))))
               (append
                (map (lambda (kv) (string-append (car kv) "=" (cdr kv)))
                     from-files)
                (filter (lambda (kv)
                          (not ((@ (srfi srfi-1) any) (lambda (f)
                                      (string-prefix? (string-append (car f) "=") kv))
                                    from-files)))
                        (list #$@(map (lambda (kv)
                                        #~(string-append #$(car kv) "=" #$(cdr kv)))
                                      env))))))
            #:log-file "/var/log/playnet-gateway.log"))
            args)))
      (stop #~(make-kill-destructor))
      ;; A boot that cannot succeed stops instead of looping. Shepherd's default
      ;; (5 respawns in 7 s) never tripped on this service's ~2.5 s crash cycle:
      ;; one bad commit respawned the gateway ~1,700 times an hour all night, each
      ;; respawn restarting `networking` and forking loggers, until a forked child
      ;; deadlocked and held the init's service queue. Five crashes inside a
      ;; minute disable it, and five seconds between respawns keeps even that
      ;; burst small.
      (respawn? #t)
      (respawn-limit #~'(5 . 60))
      (respawn-delay 5)))))

(define (playnet-gateway-activation config)
  "Create the persistent data directory for the gateway, and the law folder
   PLAYNET_LAW_PACKS names inside it, so a steward drops rule-packs into a
   folder that already exists and is already the service user's."
  (let ((data-dir (playnet-gateway-configuration-data-dir config))
        (user     (playnet-gateway-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (for-each (lambda (d)
                      (mkdir-p d)
                      (chown d (passwd:uid pw) (passwd:gid pw)))
                    (list #$data-dir (string-append #$data-dir "/law")))))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define playnet-gateway-service-type
  (service-type
   (name 'playnet-gateway)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-gateway-shepherd-service)
          (service-extension activation-service-type
                             playnet-gateway-activation)))
   (description "Run the playnet OCapN gateway as a Shepherd service.")))
