;;; deploy/guix/radicle-service.scm — Guix service for Radicle seed node
;;;
;;; Provides two Shepherd services:
;;;   radicle-node      — P2P git collaboration node (always-online seed)
;;;   radicle-configure — one-shot that wires Tor settings + the local
;;;                       .onion hostname into ~/.radicle/config.json
;;;                       (Full Proxy Mode: proxy=127.0.0.1:9050,
;;;                       onion.mode=forward), then restarts the node.
;;;
;;; Radicle stores state in $HOME/.radicle/ so HOME is set to data-dir.
;;; After first deploy, run `rad auth` as the service user to create an
;;; identity, then `herd start radicle-configure`.
;;;
;;; radicle-node's start action also ensures radicle-httpd and
;;; radicle-http-api (deploy/guix/radicle-httpd-service.scm,
;;; radicle-http-api-service.scm) are running, on every boot, restart and
;;; crash-respawn — see the comment at the end of its start gexp for why.
;;;
;;; Usage in a Guix system declaration:
;;;
;;;   (service radicle-service-type
;;;            (radicle-configuration
;;;             (data-dir "/var/lib/playnet/radicle")
;;;             (user "playnet")))

(define-module (radicle-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages rust-apps)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (radicle-configuration
            radicle-configuration-seed-rids-all
            radicle-service-type))

;;; ── Configuration ──────────────────────────────────────────────────────────

(define-record-type* <radicle-configuration>
  radicle-configuration make-radicle-configuration
  radicle-configuration?
  (package   radicle-configuration-package
             (default radicle))
  (data-dir  radicle-configuration-data-dir
             (default "/var/lib/playnet/radicle"))
  (listen    radicle-configuration-listen
             (default "0.0.0.0:8776"))
  (onion-hostname-file radicle-configuration-onion-hostname-file
             (default "/var/lib/tor/hidden-services/playnet/hostname"))
  (tor-socks radicle-configuration-tor-socks
             (default "127.0.0.1:9050"))
  (user      radicle-configuration-user
             (default "playnet"))
  ;; Node alias — gossiped to every peer in the node announcement and
  ;; shown next to the DID in `rad node status` / delegate listings
  ;; network-wide. It is public metadata, so it names the project only:
  ;; hosting provider, region and machine role stay out of it. Asserted
  ;; by radicle-configure on every reconfigure so a hand-set alias from
  ;; `rad auth` can't linger.
  (alias     radicle-configuration-alias
             (default "playnet-seed"))
  ;; Path to a 0400-mode file containing the rad keystore passphrase.
  ;; Read at SERVICE START time, not deploy time, so:
  ;;   1. operators don't need RAD_PASSPHRASE in env on every reconfigure
  ;;   2. rotating the passphrase doesn't require a system rebuild
  ;;   3. the passphrase never enters the Guix store / channels.scm
  ;; If the file is absent or empty, the service starts without
  ;; RAD_PASSPHRASE — fine for unencrypted keystores, will crash-loop
  ;; for encrypted ones (with a clear log message).
  (passphrase-file radicle-configuration-passphrase-file
             (default "/run/secrets/rad-passphrase"))
  ;; List of RIDs (strings like "rad:z27df...") to seed with scope=all
  ;; so the node fetches refs from any peer (not only delegates). The
  ;; default per-repo scope is "followed", which silently breaks
  ;; auto-deploy: sigrefs gossip in, but git objects never fetch
  ;; (we hit this — pushes propagated to the sigref but the actual
  ;; commit objects required a manual `rad sync --fetch --seed <NID>`
  ;; until this knob was set). radicle-configure runs
  ;; `rad seed <RID> --scope all --no-fetch` for each entry, idempotent.
  (seed-rids-all radicle-configuration-seed-rids-all
                 (default '())))

;;; ── Shepherd service ───────────────────────────────────────────────────────

(define (radicle-shepherd-service config)
  (let ((package          (radicle-configuration-package config))
        (data-dir         (radicle-configuration-data-dir config))
        (listen           (radicle-configuration-listen config))
        (hostname-file    (radicle-configuration-onion-hostname-file config))
        (tor-socks        (radicle-configuration-tor-socks config))
        (user             (radicle-configuration-user config))
        (alias            (radicle-configuration-alias config))
        (passphrase-file  (radicle-configuration-passphrase-file config))
        (seed-rids-all    (radicle-configuration-seed-rids-all config)))
    (list
     ;; ── Node ──────────────────────────────────────────────────────────────
     ;; No torsocks wrapper: Radicle has native per-address-type Tor support
     ;; (node.proxy + node.onion.mode), wired up by radicle-configure below.
     ;; The iptables tor-or-die OUTPUT policy still confines leaks.
     (shepherd-service
      (provision '(radicle-node))
      (documentation "Radicle P2P seed node for decentralized git collaboration")
      (requirement '(networking user-processes tor))
      ;; Read passphrase at start time, not deploy time. Survives
      ;; reconfigures without operator env, and rotating the passphrase
      ;; is just a file edit + herd restart (no system rebuild).
      ;;
      ;; RAD_PASSPHRASE semantics gotcha that bit us before:
      ;;   - missing/empty env var  → rad treats key as unencrypted
      ;;   - var present, value ""  → rad tries empty-passphrase decrypt
      ;; So when the file is absent or empty, we MUST omit the var
      ;; (not set it to "") — otherwise unencrypted keys crash with
      ;; "private key is already decrypted". When the file exists with
      ;; content, inject the trimmed value as RAD_PASSPHRASE.
      (start
       #~(lambda _
           (use-modules (ice-9 textual-ports)
                        (srfi srfi-1))
           (define (read-trimmed path)
             (and (file-exists? path)
                  (let ((s (call-with-input-file path (module-ref (resolve-interface '(ice-9 textual-ports)) 'get-string-all))))
                    (and (string? s)
                         (let ((trimmed (string-trim-both s)))
                           (and (not (string-null? trimmed)) trimmed))))))
           (let* ((pp  (read-trimmed #$passphrase-file))
                  ;; PATH is load-bearing: serving a fetch spawns
                  ;; `git upload-pack` via execvp, and with PATH unset
                  ;; the libc fallback (/bin:/usr/bin) has no git on
                  ;; Guix — every inbound clone dies with "connection
                  ;; reset" at the fetch handshake (os error 2 in the
                  ;; node log). The node's own outbound fetches use
                  ;; gitoxide and mask the gap.
                  (env (cons* (string-append "HOME=" #$data-dir)
                              "PATH=/run/current-system/profile/bin"
                              (if pp
                                  (list (string-append "RAD_PASSPHRASE=" pp))
                                  '()))))
             (let ((pid ((make-forkexec-constructor
                          (list #$(file-append package "/bin/radicle-node")
                                "--listen" #$listen
                                "--force")
                          #:user #$user
                          #:group "users"
                          #:directory #$data-dir
                          #:environment-variables env
                          #:log-file "/var/log/playnet/radicle-node.log"))))
               ;; radicle-httpd, radicle-http-api AND radicle-ci (the
               ;; CI/backstop loop, os.scm's `simple-service 'radicle-ci`)
               ;; all `(requirement '(radicle-node))` or equivalent, which
               ;; only gets Shepherd to order their FIRST start after this
               ;; one — it does not restart them when radicle-node
               ;; restarts. Shepherd stops dependents when a requirement
               ;; stops (cascade-stop) but never restarts them afterward:
               ;; an open, unfixed upstream limitation (Guix bug #23170,
               ;; "Shepherd doesn't restart previously running dependent
               ;; services"), not a config mistake here. Every path that
               ;; brings this service up — boot, an operator restart, a
               ;; crash respawn, or radicle-configure's own background
               ;; restart below — hit this gap and left radicle-http-api
               ;; stopped until someone noticed and ran `herd start` by
               ;; hand (2026-07-21, 2026-09-13, 2026-09-15) — and, missed
               ;; the first time this list was written, left radicle-ci
               ;; (the periodic-fetch/canonical-cosign backstop) stopped
               ;; and SILENT for ~14 hours the same way (2026-09-15/16):
               ;; no error, just nothing syncing until noticed by hand.
               ;; `herd start` on an already-running service is a no-op,
               ;; so firing it unconditionally here is safe on every
               ;; path, including plain boot. Backgrounded with a short
               ;; delay for the same reason radicle-configure's restart
               ;; below is backgrounded: this runs inside shepherd's own
               ;; start handler, and shepherd needs to finish marking
               ;; radicle-node 'running' before it will act on a
               ;; dependent's start request.
               (system "(sleep 2; /run/current-system/profile/bin/herd start radicle-httpd; /run/current-system/profile/bin/herd start radicle-http-api; /run/current-system/profile/bin/herd start radicle-ci) &")
               pid))))
      ;; SIGTERM with a 5s grace period before SIGKILL — explicit so
      ;; that radicle-node hanging on shutdown can't queue
      ;; `herd restart` calls indefinitely (the bug that piled up 5
      ;; zombie restart processes, one running 2+ days).
      (stop #~(make-kill-destructor #:grace-period 5))
      (respawn? #t))

     ;; ── Configure (one-shot) ──────────────────────────────────────────────
     ;; Wires Tor settings + the locally-generated .onion hostname into
     ;; ~/.radicle/config.json via `rad config set`, then restarts the node.
     ;; Idempotent.  Skips quietly if `rad auth` hasn't been run yet.
     (shepherd-service
      (provision '(radicle-configure))
      (documentation "Wire Tor + .onion into Radicle config (Full Proxy Mode)")
      (requirement '(radicle-node))
      (one-shot? #t)
      (start
       #~(lambda _
           (use-modules (ice-9 textual-ports)
                        (ice-9 rdelim))
           (let* ((rad      #$(file-append package "/bin/rad"))
                  (cfg-path (string-append #$data-dir "/.radicle/config.json"))
                  (onion    (and (file-exists? #$hostname-file)
                                 (string-trim-right
                                  (call-with-input-file #$hostname-file
                                    (module-ref (resolve-interface '(ice-9 textual-ports)) 'get-string-all))))))
             (cond
              ((not (file-exists? cfg-path))
               (format #t "radicle-configure: ~a missing — run `rad auth` first.~%"
                       cfg-path)
               #t)
              ((not onion)
               (format #t "radicle-configure: ~a missing — Tor onion not ready.~%"
                       #$hostname-file)
               #f)
              (else
               (let* ((ext  (string-append onion ":8776"))
                      (json (lambda (s) (string-append "[\"" s "\"]")))
                      ;; Run `rad` as the service user so HOME-relative
                      ;; config.json edits happen with correct ownership
                      ;; and don't inherit Shepherd's (root) environment.
                      (run  (lambda (key val)
                              (system*
                               "/run/current-system/profile/bin/su"
                               "-s" "/bin/sh" #$user "-c"
                               (string-append
                                "HOME=" #$data-dir
                                " PATH=/run/current-system/profile/bin "
                                rad " config set " key " "
                                "'" val "'")))))
                 ;; Alias travels with every node announcement, so it
                 ;; carries only the project name — see the `alias`
                 ;; field comment.
                 (run "node.alias"                  #$alias)
                 (run "node.proxy"                  #$tor-socks)
                 (run "node.onion.mode"             "forward")
                 (run "node.listen"                 (json #$listen))
                 (run "node.externalAddresses"      (json ext))
                 ;; Default MUST be "block": a project seed node should
                 ;; only store the RIDs it explicitly seeds (below), not
                 ;; the entire Radicle network. With "allow" the node
                 ;; replicated every repo it gossiped about — 7488 repos /
                 ;; 54 GB — which filled the origin disk and broke
                 ;; large-asset serving via nginx proxy_temp (ENOSPC →
                 ;; truncated responses → a 502 at the CDN edge). Per-repo scope=all
                 ;; on our own RID (the for-each below) is the right knob
                 ;; for auto-deploy fetch; the global default is not.
                 (run "node.seedingPolicy.default"  "block")
                 ;; Per-repo: bump scope to "all" so the node fetches
                 ;; git objects from any peer announcing a sigref, not
                 ;; just delegates. Without this, scope defaults to
                 ;; "followed" → sigrefs gossip in but commit objects
                 ;; never auto-fetch (we hit this; every push needed
                 ;; manual `rad sync --fetch --seed <NID>`).
                 (for-each
                  (lambda (rid)
                    (system*
                     "/run/current-system/profile/bin/su"
                     "-s" "/bin/sh" #$user "-c"
                     (string-append
                      "HOME=" #$data-dir
                      " PATH=/run/current-system/profile/bin "
                      rad " seed " rid " --scope all --no-fetch")))
                  '#$seed-rids-all)
                 ;; The Explorer at /radicle/ asks this node for its pinned
                 ;; repositories (`?show=pinned` → web.pinned.repositories).
                 ;; Every repo the node seeds is pinned: the core and its
                 ;; satellites (deploy/satellites.scm), one list. `rad config
                 ;; set` takes a scalar only and `push` appends without
                 ;; deduplicating, so each rid is removed then pushed —
                 ;; idempotent across reconfigures.
                 (for-each
                  (lambda (rid)
                    (for-each
                     (lambda (verb)
                       (system*
                        "/run/current-system/profile/bin/su"
                        "-s" "/bin/sh" #$user "-c"
                        (string-append
                         "HOME=" #$data-dir
                         " PATH=/run/current-system/profile/bin "
                         rad " config " verb " web.pinned.repositories " rid
                         " >/dev/null 2>&1")))
                     '("remove" "push")))
                  '#$seed-rids-all)
                 (format #t "radicle-configure: advertising ~a~%" ext)
                 ;; Fire-and-forget the herd restart in a backgrounded
                 ;; subshell. The previous synchronous `system*` blocked
                 ;; here until radicle-node fully restarted — and when
                 ;; the node crash-looped (e.g. encrypted keystore + no
                 ;; passphrase), every reconfigure piled another stuck
                 ;; `herd restart` on the queue (we had a 2-day-old
                 ;; zombie holding the shepherd lock). Backgrounding
                 ;; lets activation complete; shepherd's own respawn
                 ;; logic handles the restart asynchronously.
                 (system "/run/current-system/profile/bin/herd restart radicle-node &")
                 #t))))))
      (respawn? #f)))))

;;; ── Activation ─────────────────────────────────────────────────────────────
;; The user account is declared in machines.scm.  This just ensures the
;; data directory and log directory exist with correct ownership.

(define (radicle-activation config)
  (let ((data-dir (radicle-configuration-data-dir config))
        (user     (radicle-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((pw (getpwnam #$user)))
          (mkdir-p #$data-dir)
          (chown #$data-dir (passwd:uid pw) (passwd:gid pw))
          (mkdir-p "/var/log/playnet")))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define radicle-service-type
  (service-type
   (name 'radicle-node)
   (description
    "Radicle P2P seed node. Acts as an always-online peer for decentralized
git collaboration, replacing centralized hosting (GitHub).")
   (extensions
    (list (service-extension shepherd-root-service-type
                             radicle-shepherd-service)
          (service-extension activation-service-type
                             radicle-activation)))
   (default-value (radicle-configuration))))
