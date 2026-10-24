;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/radicle-httpd-service.scm — Guix package + Shepherd service
;;; for radicle-httpd, the Radicle HTTP daemon.
;;;
;;; radicle-httpd is a read-only HTTP/JSON gateway over a radicle-node's
;;; storage: it exposes repos, issues, patches and COBs over HTTP so web
;;; front-ends (Radicle Explorer, Planning Boards) can read/write them.
;;; It is the backend tier the boards stack needs; our radicle-service.scm
;;; only runs the P2P node (rad / radicle-node / git-remote-rad), which has
;;; no HTTP face.
;;;
;;; PACKAGING NOTE (milestone-1 tradeoff, chosen deliberately):
;;;   The current httpd line (0.24.0) is NOT on crates.io (upstream stopped
;;;   publishing there at 0.10.0, which is too old to read a heartwood-1.7.x
;;;   node's storage) and ships no source tarball — only signed, static-musl
;;;   prebuilt binaries + git source on the Radicle network. So this package
;;;   wraps the upstream signed static-musl binary, pinned by hash. It is a
;;;   binary blob in our otherwise source-built channel; the integrity anchor
;;;   is the pinned Guix hash (the upstream .sha256 matched on download, and
;;;   the artifact carries an ssh-ed25519 .sig from the radicle release key).
;;;   Hardening path: build 0.24.0 from git source (commit bd3b660b) once the
;;;   radicle-* workspace crates are resolvable as Guix inputs.
;;;
;;; The binary is statically linked (musl), so there is nothing to patchelf
;;; and no runtime inputs — we just install it into the store.
;;;
;;; Storage access: httpd reads $HOME/.radicle, so HOME points at the SAME
;;; data-dir as radicle-service.scm (default /var/lib/localchimera/radicle) and it
;;; runs as the same user. It only reads; it never mutates node state.
;;;
;;; Usage in machines.scm:
;;;   (service radicle-httpd-service-type
;;;            (radicle-httpd-configuration
;;;             (data-dir "/var/lib/localchimera/radicle")
;;;             (listen "127.0.0.1:8088")
;;;             (user "localchimera")))

(define-module (radicle-httpd-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages compression)         ;xz (for unpack)
  #:export (radicle-httpd
            radicle-httpd-configuration
            radicle-httpd-configuration?
            radicle-httpd-service-type))

;;; ── Package (signed prebuilt static-musl binary) ────────────────────────────

(define-public radicle-httpd
  (package
    (name "radicle-httpd")
    (version "0.24.0")
    (source
     (origin
       (method url-fetch)
       ;; files.radicle.xyz 302-redirects to files.radicle.dev; url-fetch
       ;; follows it. The on-disk .sha256 next to this artifact upstream is
       ;; 44a06292177f98fb3323df901d3b73db3106bbae90287e2d817d17539798b674
       ;; (verified on download); the base32 below is the Guix flat hash.
       (uri (string-append
             "https://files.radicle.xyz/releases/radicle-httpd/" version
             "/radicle-httpd-" version "-x86_64-unknown-linux-musl.tar.xz"))
       (file-name (string-append name "-" version ".tar.xz"))
       (sha256
        (base32 "0x5nk2bm65vxh4npwa4hmsxhccfvfcxiv46z4crzp63z2y965824"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((xz   (string-append #+xz "/bin/xz"))
                 (tar  (string-append #+(@ (gnu packages base) tar) "/bin/tar"))
                 (out  #$output)
                 (top  (string-append
                        "radicle-httpd-" #$version
                        "-x86_64-unknown-linux-musl")))
            (setenv "PATH" (string-append #+xz "/bin:"
                                          #+(@ (gnu packages base) tar) "/bin"))
            (invoke tar "xf" #$source)
            ;; Static musl ELF — no interpreter to patch, no runpath.
            (install-file (string-append top "/bin/radicle-httpd")
                          (string-append out "/bin"))
            (let ((man1 (string-append out "/share/man/man1")))
              (mkdir-p man1)
              (install-file (string-append top "/man/man1/radicle-httpd.1")
                            man1))
            #t))))
    (home-page "https://radicle.xyz/")
    (synopsis "Radicle HTTP daemon (read-only HTTP/JSON gateway over a node)")
    (description
     "@command{radicle-httpd} is the Radicle HTTP daemon: a background process
that acts as a read-only gateway between the Radicle protocol and HTTP.  It has
direct read access to a @command{radicle-node}'s storage and database and
exposes that data --- repositories, issues, patches, and other collaborative
objects --- over an HTTP JSON API consumed by web front-ends such as Radicle
Explorer and Radicle Planning Boards.

This package installs the upstream signed, statically-linked (musl) release
binary pinned by hash; see the module header for the source-build hardening
path.")
    (license (list license:expat license:asl2.0))))

;;; ── Configuration ───────────────────────────────────────────────────────────

(define-record-type* <radicle-httpd-configuration>
  radicle-httpd-configuration make-radicle-httpd-configuration
  radicle-httpd-configuration?
  (package   radicle-httpd-configuration-package
             (default radicle-httpd))
  ;; HOME for the daemon — it reads $HOME/.radicle. MUST match the node's
  ;; data-dir (radicle-service.scm default) so it serves the same storage.
  (data-dir  radicle-httpd-configuration-data-dir
             (default "/var/lib/localchimera/radicle"))
  ;; Bind localhost only: nginx (clearnet/onion) and serve-static front it.
  ;; Port 8088 — NOT 8080 (serve-static owns 8080).
  (listen    radicle-httpd-configuration-listen
             (default "127.0.0.1:8088"))
  (user      radicle-httpd-configuration-user
             (default "localchimera"))
  ;; Optional (alias . "rad:…") pairs → repeated --alias flags, to shorten
  ;; clone URLs (e.g. ("localchimera" . "rad:z…") → /localchimera.git).
  (aliases   radicle-httpd-configuration-aliases
             (default '())))

;;; ── Shepherd service ────────────────────────────────────────────────────────

(define (radicle-httpd-shepherd-service config)
  (let ((package  (radicle-httpd-configuration-package config))
        (data-dir (radicle-httpd-configuration-data-dir config))
        (listen   (radicle-httpd-configuration-listen config))
        (user     (radicle-httpd-configuration-user config))
        (aliases  (radicle-httpd-configuration-aliases config)))
    (list
     (shepherd-service
      (provision '(radicle-httpd))
      (documentation "Radicle HTTP daemon — read-only HTTP/JSON gateway over the node storage")
      ;; Needs the node's storage to exist; radicle-node creates/owns it.
      (requirement '(networking user-processes radicle-node))
      (start
       #~(make-forkexec-constructor
          (append
           (list #$(file-append package "/bin/radicle-httpd")
                 "--listen" #$listen)
           ;; Flatten the alias pairs into repeated `--alias <a> <rid>`.
           (append-map
            (lambda (pair)
              (list "--alias" (car pair) (cdr pair)))
            '#$aliases))
          #:user #$user
          #:group "users"
          #:directory #$data-dir
          #:environment-variables
          (list (string-append "HOME=" #$data-dir)
                ;; Static musl binary; minimal env. PATH only for any
                ;; git subprocess it may shell out to.
                "PATH=/run/current-system/profile/bin")
          #:log-file "/var/log/localchimera/radicle-httpd.log"))
      (stop #~(make-kill-destructor #:grace-period 5))
      (respawn? #t)))))

;;; ── Activation (ensure log dir) ─────────────────────────────────────────────

(define (radicle-httpd-activation config)
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p "/var/log/localchimera")))

;;; ── Service type ────────────────────────────────────────────────────────────

(define radicle-httpd-service-type
  (service-type
   (name 'radicle-httpd)
   (description
    "Radicle HTTP daemon. Exposes a read-only HTTP/JSON API over a
radicle-node's storage so web front-ends (Radicle Explorer, Planning Boards)
can browse repos, issues and patches.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             radicle-httpd-shepherd-service)
          (service-extension activation-service-type
                             radicle-httpd-activation)))
   (default-value (radicle-httpd-configuration))))
