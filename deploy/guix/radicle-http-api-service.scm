;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/radicle-http-api-service.scm — Guix package + Shepherd service
;;; for radicle-http-api, the cytechmobile community fork of radicle-httpd
;;; that RESTORES the write (Create/Update/Delete) endpoints upstream removed.
;;;
;;; WHY a second daemon (we already have radicle-httpd, read-only):
;;;   Radicle Planning Boards persist board state AS ISSUE LABELS
;;;   ("RPB:column:<name>", "RPB:priority:<n>"). Moving a card is therefore a
;;;   COB *write*, which the official radicle-httpd refuses by design. This
;;;   fork keeps those endpoints (PATCH /api/v1/projects/:rid/issues/:id with
;;;   an `issue::Action::Label`). Upstream calls it "not part of the Radicle
;;;   core stack … a community project"; we treat it accordingly and keep its
;;;   write surface OFF the public read path (the read-only radicle-httpd
;;;   fronts Explorer browsing; this fork is the boards' write backend).
;;;
;;; COMPAT NOTE (radicle 0.13.0 base vs our heartwood-1.7.1 node):
;;;   Source-level evidence (heartwood 1.7.1): COB manifest format Version = 1
;;;   (unchanged since radicle 0.x), issue COB type "xyz.radicle.issue" stable,
;;;   no RepositoryVersion gate → the 0.13.0 fork reads/writes the same COB
;;;   format. The live PATCH-label round-trip is validated at deploy time.
;;;
;;; AUTH / SIGNING:
;;;   Write endpoints are session-gated: a client POSTs /api/v1/sessions, then
;;;   PUTs a signature over "{sessionId}:{pk}" made with the NODE key. The
;;;   daemon itself loads the node profile to verify/sign, so it needs the
;;;   keystore decrypted → RAD_PASSPHRASE (same passphrase-file mechanism as
;;;   radicle-service.scm). Only a holder of the node key can open a write
;;;   session — i.e. writes are operator-gated, not open to the public.
;;;
;;; Built from source via cargo-build-system; deps vendored through
;;; rust-crates.scm (populated by `guix import -i … crate -f Cargo.lock
;;; radicle-http-api`). Source is the pinned upstream commit fetched from the
;;; GitHub mirror.

(define-module (radicle-http-api-service)
  #:use-module (gnu services)
  #:use-module (gnu services mcron)
  #:use-module (gnu services shepherd)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages version-control)      ;libgit2
  #:use-module (gnu packages sqlite)               ;sqlite
  #:use-module (gnu packages tls)                  ;openssl
  #:use-module (gnu packages compression)          ;zlib
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages rust-apps)             ;the stock `rad` CLI, for cache bootstrap
  #:use-module (rust-crates)
  #:export (radicle-http-api
            radicle-http-api-configuration
            radicle-http-api-configuration?
            radicle-http-api-service-type))

;;; ── Package (built from source) ─────────────────────────────────────────────

(define-public radicle-http-api
  (package
    (name "radicle-http-api")
    (version "1.2.1")                       ;upstream Cargo.toml version
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/cytechmobile/radicle-http-api/archive/"
             "01d54137e63a4f3106548630040f613e9b73cd2e.tar.gz"))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "1kzwaac94jd33057gi0li95mgqjg2k1rq2dixpdmd5gygiglbr2w"))))
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #f
      ;; Tests want a live node / fixtures and network; skip in the sandbox.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          ;; build.rs falls back to `git describe` when RADICLE_VERSION is
          ;; unset — there is no .git in the build sandbox, so pin it here.
          (add-after 'unpack 'setenv
            (lambda _
              (setenv "RADICLE_VERSION" #$version)
              (setenv "LIBGIT2_NO_VENDOR" "1")
              (setenv "HOME" (getcwd))
              (setenv "TMPDIR" "/tmp")))
          ;; Fix the binary-file panic: the commit/diff response builders feed
          ;; the radicle `diff` straight into `json!{…}`. For a commit that
          ;; touches a binary file (a PDF, image, wasm…) the diff's hunk bytes
          ;; are not valid UTF-8, so serde_json returns Err and `json!`'s
          ;; internal `to_value(…).unwrap()` PANICS the worker thread → the
          ;; client gets a 502 and the Radicle Explorer cannot load the commit.
          ;; Serialize the diff with a fallback to a VALID-but-empty diff object
          ;; — matching the Explorer's schema {files, stats}, NOT null (the
          ;; interface's zod schema requires an object and rejects null) — so
          ;; the commit loads even when its binary diff can't be rendered.
          (add-after 'unpack 'fix-binary-diff-panic
            (lambda _
              (substitute* "src/api/v1/projects.rs"
                (("\"diff\": diff,")
                 (string-append
                  "\"diff\": serde_json::to_value(&diff).unwrap_or_else(|_| "
                  "serde_json::json!({\"files\": [], \"stats\": "
                  "{\"filesChanged\": 0, \"insertions\": 0, \"deletions\": 0}})),"))))))))
    (inputs
     (cons* libgit2-1.8 sqlite openssl zlib
            (cargo-inputs 'radicle-http-api #:module '(rust-crates))))
    (native-inputs (list pkg-config))
    (home-page "https://github.com/cytechmobile/radicle-http-api")
    (synopsis "Write-capable community fork of the Radicle HTTP API")
    (description
     "@command{radicle-http-api} is the cytechmobile community fork of
@command{radicle-httpd} that retains the Create/Update/Delete HTTP endpoints
the upstream project removed.  It exposes a write-capable HTTP/JSON API over a
@command{radicle-node}'s storage so machine-to-machine integrations and web
applications --- notably Radicle Planning Boards --- can mutate project state
(issues, patches, labels).  Writes are session-authenticated against the node
key.  This is explicitly a community project, not part of the Radicle core
stack.")
    (license (list license:expat license:asl2.0))))

;;; ── Configuration ───────────────────────────────────────────────────────────

(define-record-type* <radicle-http-api-configuration>
  radicle-http-api-configuration make-radicle-http-api-configuration
  radicle-http-api-configuration?
  (package   radicle-http-api-configuration-package
             (default radicle-http-api))
  ;; The shared radicle-node data-dir — this fork reads its keys and git
  ;; storage (refs/cobs/*, the actual COB objects) from here, via the
  ;; symlinks radicle-http-api-activation sets up. It does NOT run with
  ;; HOME set to this path (see private-home below).
  (data-dir  radicle-http-api-configuration-data-dir
             (default "/var/lib/localchimera/radicle"))
  ;; The daemon's OWN HOME. Deliberately NOT the same directory as
  ;; radicle-node/radicle-httpd's data-dir: this fork is vendored from a
  ;; "radicle 0.13.0 base" (see the module header COMPAT NOTE), while
  ;; radicle-node/radicle-httpd track 1.8.0/0.24.0. The COB *manifest*
  ;; format was verified compatible across that gap, but the SQLite COB
  ;; *cache* (cobs/cache.db) is separately schema-versioned
  ;; ("Migrating COBs cache.. / Migration ... complete (version=N)",
  ;; logged by radicle-node at every start) and that was never checked.
  ;; Running both builds against the same cache.db is what silently
  ;; wedged issue/patch caching for the localchimera repo for over two months
  ;; (2026-09-15 incident: cache.db held 0 issues despite continuous
  ;; successful fetches) — no crash, no error logged, just a cache that
  ;; stopped accepting writes.
  ;;
  ;; radicle-http-api-activation symlinks in keys, storage, config.json
  ;; AND node/ (routing table, seeding policy, notifications — read
  ;; mostly, and this fork opening it live-caused two separate 500s
  ;; the day this landed, both "unable to open database file" against
  ;; a node/ this fork itself never populates: first the pinned-projects
  ;; listing needs node/policies.db, then node/node.db too). Only
  ;; cobs/ (the actual corruption source above) and httpd/ (this fork's
  ;; own session store) stay private. Sharing node/ re-admits some of
  ;; the cross-version-write risk this isolation exists to remove — it's
  ;; a deliberate, narrower trade than sharing cobs/ back, made because
  ;; two live endpoints demonstrably need it and neither is the COB
  ;; cache; watch for further "unable to open database file" reports if
  ;; some other file under node/ turns out to matter too.
  (private-home radicle-http-api-configuration-private-home
             (default "/var/lib/localchimera/radicle-http-api-home"))
  ;; Localhost only; nginx + serve-static front it. 8089 — distinct from the
  ;; read-only radicle-httpd (8088) and serve-static (8080).
  (listen    radicle-http-api-configuration-listen
             (default "127.0.0.1:8089"))
  (user      radicle-http-api-configuration-user
             (default "localchimera"))
  ;; Same 0400 passphrase-file mechanism as radicle-service.scm: the write
  ;; fork must decrypt the node keystore to sign COB writes / verify sessions.
  (passphrase-file radicle-http-api-configuration-passphrase-file
             (default "/run/secrets/rad-passphrase")))

;;; ── Shepherd service ────────────────────────────────────────────────────────

(define (radicle-http-api-shepherd-service config)
  (let ((package         (radicle-http-api-configuration-package config))
        (private-home    (radicle-http-api-configuration-private-home config))
        (listen          (radicle-http-api-configuration-listen config))
        (user            (radicle-http-api-configuration-user config))
        (passphrase-file (radicle-http-api-configuration-passphrase-file config)))
    (list
     (shepherd-service
      (provision '(radicle-http-api))
      (documentation "Radicle write-capable HTTP API (Planning Boards backend)")
      (requirement '(networking user-processes radicle-node))
      ;; The start gexp reads the passphrase file with get-string-all: the
      ;; module has to be in shepherd's own module list, since a use-modules
      ;; inside the lambda only binds once some earlier service start has
      ;; happened to load it — at first boot none has, and the service
      ;; "failed to start: Unbound variable: get-string-all" (2026-09-07).
      (modules (cons* '(ice-9 textual-ports) '(srfi srfi-1) %default-modules))
      ;; Read the keystore passphrase at start time (see radicle-service.scm
      ;; for the RAD_PASSPHRASE present-but-empty gotcha — omit the var when
      ;; the file is absent/empty rather than setting it to "").
      (start
       #~(lambda _
           (define (read-trimmed path)
             (and (file-exists? path)
                  (let ((s (call-with-input-file path get-string-all)))
                    (and (string? s)
                         (let ((t (string-trim-both s)))
                           (and (not (string-null? t)) t))))))
           (let* ((pp  (read-trimmed #$passphrase-file))
                  (env (cons* (string-append "HOME=" #$private-home)
                              "PATH=/run/current-system/profile/bin"
                              (if pp
                                  (list (string-append "RAD_PASSPHRASE=" pp))
                                  '()))))
             ((make-forkexec-constructor
               (list #$(file-append package "/bin/radicle-http-api")
                     "--listen" #$listen)
               #:user #$user
               #:group "users"
               #:directory #$private-home
               #:environment-variables env
               #:log-file "/var/log/localchimera/radicle-http-api.log")))))
      (stop #~(make-kill-destructor #:grace-period 5))
      (respawn? #t)))))

(define (radicle-http-api-activation config)
  (let ((shared-home  (radicle-http-api-configuration-data-dir config))
        (private-home (radicle-http-api-configuration-private-home config))
        (user         (radicle-http-api-configuration-user config)))
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p "/var/log/localchimera")
        ;; Give this fork its own $HOME, sharing keys, storage,
        ;; config.json and node/ with the radicle-node/radicle-httpd
        ;; data-dir, but never cobs/cache.db or this fork's own httpd
        ;; sessions.db. See the private-home field comment above for why
        ;; node/ is shared despite the isolation this exists for.
        (let* ((private-radicle (string-append #$private-home "/.radicle"))
               (shared-radicle  (string-append #$shared-home "/.radicle"))
               (pw              (getpwnam #$user))
               ;; `file-exists?` follows symlinks, so it reads #f for a
               ;; dangling one (e.g. "keys" before the first `rad auth`
               ;; on the shared side) — re-running activation would
               ;; then retry `symlink` on a path that's already a
               ;; (dangling) directory entry and crash with EEXIST.
               ;; `lstat` sees the link itself, dangling or not.
               (link-entry-exists?
                (lambda (path)
                  (catch 'system-error
                    (lambda () (lstat path) #t)
                    (lambda _ #f)))))
          (mkdir-p private-radicle)
          (for-each
           (lambda (name)
             (let ((link   (string-append private-radicle "/" name))
                   (target (string-append shared-radicle "/" name)))
               (unless (link-entry-exists? link)
                 (symlink target link))))
           '("keys" "storage" "config.json" "node"))
          (chown #$private-home (passwd:uid pw) (passwd:gid pw))
          (chown private-radicle (passwd:uid pw) (passwd:gid pw))
          ;; `radicle-http-api` itself opens cobs/cache.db without the
          ;; SQLite CREATE flag — on a brand-new private-home it fails
          ;; with "unable to open database file" (code 14) rather than
          ;; creating one (confirmed live, 2026-09-15: the service 500'd
          ;; on every request until this ran by hand). The stock `rad`
          ;; CLI's own cache-open path does create+migrate on demand;
          ;; `rad cob migrate` alone is enough to trigger that — no need
          ;; for `rad issue cache` first. It's a schema-only operation
          ;; (confirmed: <1s, and a no-op "already up to date" when
          ;; re-run), not a per-repo data scan, so it's safe and fast to
          ;; run on every activation regardless of how many repos this
          ;; node seeds.
          (system* "/run/current-system/profile/bin/su"
                    "-s" "/bin/sh" #$user "-c"
                    (string-append "HOME=" #$private-home
                                   " PATH=/run/current-system/profile/bin "
                                   #$(file-append radicle "/bin/rad")
                                   " cob migrate"))))))

;;; ── Keeping the private COB cache fresh ─────────────────────────────────────

;; The private cobs/cache.db (see private-home above) has exactly one
;; writer of its own: this fork, on the writes it makes itself. Patches and
;; issues that arrive any other way (a contributor's patch fetched by the
;; node, a `rad patch` from the CLI, a CI job COB) never reach it —
;; radicle-node feeds only the node's OWN cache. Left alone it served
;; four-day-old data: after 2026-09-16 the public board listed two 4-month-old
;; patches while node storage held twelve.
;;
;; `rad {patch,issue} cache --storage` rebuilds a cache from the COBs in
;; storage. It must run inside a repository (the checkout), as the service
;; user, with HOME on the private home so it writes THIS cache.db. Stock
;; `rad` does the writing, the same binary the activation already uses to
;; create/migrate the file. flock keeps a slow run from stacking; timeout
;; ends one before the next tick.
(define (radicle-http-api-cache-refresh-jobs config)
  (let ((private-home (radicle-http-api-configuration-private-home config))
        (data-dir     (radicle-http-api-configuration-data-dir config))
        (user         (radicle-http-api-configuration-user config)))
    (list
     ;; :00 and :05 of every hour — every five minutes, on the minute
     ;; residue no other job on the box uses (deploy/os.scm, the mcron
     ;; block: two jobs starting in one minute crash mcron 1.2.2). The
     ;; board is a public read of the issue list; five minutes is fresh.
     #~(job "*/5 * * * *"
            (let ((rad-cache
                   (lambda (kind)
                     (string-append
                      "su -s /bin/sh " #$user " -c 'HOME=" #$private-home
                      " PATH=/run/current-system/profile/bin "
                      #$(file-append radicle "/bin/rad") " " kind
                      " cache --storage --no-announce'"))))
              (string-append
               "cd " #$data-dir "/checkout && "
               "/run/current-system/profile/bin/flock -n /run/radicle-http-api-cache.lock "
               "/run/current-system/profile/bin/timeout 100 sh -c \""
               (rad-cache "patch") " && " (rad-cache "issue")
               "\" > /dev/null 2>> /var/log/localchimera/radicle-http-api-cache.log"))))))

;;; ── Service type ────────────────────────────────────────────────────────────

(define radicle-http-api-service-type
  (service-type
   (name 'radicle-http-api)
   (description
    "Radicle write-capable HTTP API (cytechmobile fork). Session-gated
Create/Update/Delete over the node storage; the write backend for Radicle
Planning Boards. Kept separate from the read-only radicle-httpd that fronts
public Explorer browsing.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             radicle-http-api-shepherd-service)
          (service-extension activation-service-type
                             radicle-http-api-activation)
          (service-extension mcron-service-type
                             radicle-http-api-cache-refresh-jobs)))
   (default-value (radicle-http-api-configuration))))
