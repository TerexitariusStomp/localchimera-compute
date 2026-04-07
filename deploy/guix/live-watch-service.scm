;;; deploy/guix/live-watch-service.scm — Shepherd service that runs
;;; tools/live-watch.sh against the playnet dev checkout.
;;;
;;; Companion to (weave-dev-service): once `herd start weave-dev` has
;;; the dev wasm bundle running and the REPL relay listening on 37146,
;;; `herd start live-watch` starts an inotify loop that pushes saved
;;; Scheme files into the running browser tab. No editor required —
;;; works for any tool that performs an atomic write (Emacs, Vim, VS
;;; Code, Helix, sshfs-mounted laptop editors, …).
;;;
;;; Manual lifecycle:
;;;
;;;   sudo herd start weave-dev      # 1. dev wasm + REPL relay
;;;   sudo herd start live-watch     # 2. inotify loop
;;;   # … live-hack from any editor that touches files under
;;;   #     /home/playnet/dev-checkout/module/ …
;;;   sudo herd stop  live-watch
;;;   sudo herd stop  weave-dev
;;;
;;; auto-start? #f and respawn? #f for the same reason as
;;; weave-dev-service: this is an opt-in dev tool. Logs to
;;; /var/log/live-watch.log.

(define-module (live-watch-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages linux) ; inotify-tools
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (live-watch-configuration
            live-watch-configuration?
            live-watch-configuration-checkout
            live-watch-configuration-watch-paths
            live-watch-configuration-user
            live-watch-configuration-repl-host
            live-watch-configuration-repl-port
            live-watch-service-type))

;;; ── Configuration record ─────────────────────────────────────────────────────

(define-record-type* <live-watch-configuration>
  live-watch-configuration make-live-watch-configuration
  live-watch-configuration?
  ;; Where the writable dev checkout lives. tools/live-watch.sh and
  ;; tools/live-reload.scm both come from this checkout.
  (checkout    live-watch-configuration-checkout
               (default "/home/playnet/dev-checkout"))
  ;; Subpaths under CHECKOUT to watch. Each must be a directory.
  (watch-paths live-watch-configuration-watch-paths
               (default '("module")))
  (user        live-watch-configuration-user      (default "playnet"))
  (repl-host   live-watch-configuration-repl-host (default "127.0.0.1"))
  (repl-port   live-watch-configuration-repl-port (default 37146)))

;;; ── Shepherd service ─────────────────────────────────────────────────────────

(define (live-watch-shepherd-service config)
  (let ((checkout    (live-watch-configuration-checkout config))
        (watch-paths (live-watch-configuration-watch-paths config))
        (user        (live-watch-configuration-user config))
        (host        (live-watch-configuration-repl-host config))
        (port        (live-watch-configuration-repl-port config)))
    (list
     (shepherd-service
      (provision '(live-watch))
      (documentation
       "Live-reload Scheme files into a running Hoot REPL relay (manual start)")
      (requirement '(networking user-processes))
      (auto-start? #f)
      (start
       #~(make-forkexec-constructor
          ;; Run via bash so $PATH expansion works inside the script.
          (cons*
           #$(file-append bash "/bin/bash")
           (string-append #$checkout "/tools/live-watch.sh")
           (map (lambda (sub)
                  (string-append #$checkout "/" sub))
                '#$watch-paths))
          #:user #$user
          #:directory #$checkout
          #:environment-variables
          (list (string-append "HOME=/home/" #$user)
                ;; The script needs inotifywait and guile in PATH.
                ;; /run/current-system/profile is where the system
                ;; profile (with guile-3.0 + inotify-tools) is mounted.
                "PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin"
                (string-append "PLAYNET_REPL_HOST=" #$host)
                (string-append "PLAYNET_REPL_PORT=" #$(number->string port)))
          #:log-file "/var/log/live-watch.log"))
      (stop #~(make-kill-destructor))
      (respawn? #f)))))

(define live-watch-service-type
  (service-type
   (name 'live-watch)
   (extensions
    (list (service-extension shepherd-root-service-type
                             live-watch-shepherd-service)))
   (description
    "Watch the playnet dev checkout for Scheme file saves and push the
new definitions into the running Hoot REPL relay. Manual start; pairs
with weave-dev-service.")))
