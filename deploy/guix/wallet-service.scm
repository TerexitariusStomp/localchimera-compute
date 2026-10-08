;;; deploy/guix/wallet-service.scm — Shepherd service for the isolated wallet
;;;
;;; Runs server/wallet-service.scm as a separate process from the gateway.
;;; The wallet process exposes only the ^wallet-policy actor via OCapN
;;; WebSocket on localhost:9092. The gateway resolves the sturdyref at
;;; /var/lib/playnet/wallet-sref.txt to get a capability-attenuated
;;; reference — no raw wallet methods reachable.
;;;
;;; Must start AFTER monero-wallet-rpc (which provides the local JSON-RPC)
;;; and BEFORE the playnet-gateway (which needs the sturdyref file).
;;;
;;; Usage:
;;;   (use-modules (wallet-service))
;;;   (service wallet-service-type)

(define-module (wallet-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages guile)
  #:use-module (gnu system privilege)
  #:use-module (gnu system file-systems)
  #:use-module (gnu build linux-container)
  #:use-module (guix gexp)
  #:use-module (guix least-authority)
  #:use-module (guix records)
  #:export (wallet-configuration
            wallet-configuration?
            wallet-service-type))

(define-record-type* <wallet-configuration>
  wallet-configuration make-wallet-configuration
  wallet-configuration?
  (user        wallet-configuration-user
               (default "playnet-wallet"))
  ;; 9092: the gateway's HTTP API door holds loopback :9091.
  (port        wallet-configuration-port
               (default 9092))
  (script      wallet-configuration-script
               (default "/home/playnet/playnet-repo/server/wallet-service.scm"))
  (module-path wallet-configuration-module-path
               (default "/home/playnet/playnet-repo/module"))
  (data-dir    wallet-configuration-data-dir
               (default "/var/lib/playnet"))
  ;; Primary group of the wallet process. rpc-login.txt is group-readable
  ;; to it (monero-configuration's rpc-login-group) and the gateway holds
  ;; it as a supplementary group to read the sturdyref.
  (group       wallet-configuration-group
               (default "playnet-svc"))
  ;; The wallet's own run directory: wallet-sref.txt (0640) and
  ;; wallet-repl.sock (0600). <data-dir>/wallet-sref.txt is a symlink
  ;; into it, so the gateway's path stays what it always was.
  (run-dir     wallet-configuration-run-dir
               (default "/var/run/playnet-wallet"))
  ;; Spend policy as a Scheme datum in the format produced by
  ;; `serialize-policy` from (playnet monero policy):
  ;;   (policy <monthly-xmr> <default-cap-xmr>
  ;;           ((payee <name> <addr> <max> <note>) ...)
  ;;           <note>)
  ;; Written to <data-dir>/wallet-policy.scm on activation. If #f,
  ;; no file is written and wallet-service falls back to zero budget.
  (spend-policy wallet-configuration-spend-policy
                (default #f)))

(define (wallet-shepherd-service config)
  (let ((user        (wallet-configuration-user config))
        (port        (wallet-configuration-port config))
        (script      (wallet-configuration-script config))
        (module-path (wallet-configuration-module-path config))
        (data-dir    (wallet-configuration-data-dir config))
        (group       (wallet-configuration-group config))
        (run-dir     (wallet-configuration-run-dir config))
        (policy?     (and (wallet-configuration-spend-policy config) #t)))
    (list
     (shepherd-service
      (provision '(playnet-wallet))
      (documentation
       "Isolated Monero wallet + spend policy process. Exposes the
policy actor via OCapN WebSocket on localhost. The gateway resolves
the sturdyref to get a capability-attenuated reference.")
      ;; Must start after monero-wallet-rpc (provides localhost JSON-RPC).
      ;; No local monerod — wallet-rpc connects to a remote node via Tor.
      (requirement '(networking monero-wallet-rpc))
      (start #~(make-forkexec-constructor
                ;; Wrap in least-authority-wrapper: the wallet process
                ;; runs in its own mount + PID namespace, seeing ONLY
                ;; the directories it needs. A compromised wallet can't
                ;; read gateway files, SSH keys, MQTT passwords, or
                ;; anything outside its namespace jail.
                ;; Per Guix cookbook — least-authority-wrapper uses
                ;; Linux namespaces for lightweight sandboxing.
                (list #$(least-authority-wrapper
                         (file-append guile-3.0 "/bin/guile")
                         #:name "wallet-service"
                         #:mappings
                         (append
                          ;; Spend policy (read-only, a single file). Mapped
                          ;; only when a policy is declared: a bind mount of
                          ;; an absent source fails the whole container, and
                          ;; with no policy the script is zero-budget anyway.
                          (if policy?
                              (list (file-system-mapping
                                     (source (string-append data-dir "/wallet-policy.scm"))
                                     (target (string-append data-dir "/wallet-policy.scm"))))
                              '())
                          (list
                               ;; The RPC login (read-only, a single file) is
                               ;; all the wallet client reads from the monero
                               ;; directory; the wallet keys stay outside the
                               ;; jail entirely.
                               (file-system-mapping
                                (source (string-append data-dir "/monero/rpc-login.txt"))
                                (target (string-append data-dir "/monero/rpc-login.txt")))
                               ;; The wallet's own run directory (read-write):
                               ;; the sturdyref handoff and the REPL socket.
                               ;; Its own, so the jail holds no path to the
                               ;; gateway's sockets in /var/run/playnet.
                               (file-system-mapping
                                (source run-dir)
                                (target run-dir)
                                (writable? #t))
                               ;; Code (read-only)
                               (file-system-mapping
                                (source module-path)
                                (target module-path))
                               ;; The script itself lives outside module-path
                               ;; (server/, not module/) — without this mapping
                               ;; `guile -s script` fails ENOENT inside the
                               ;; container even though the file exists on
                               ;; the host (confirmed 2026-09-16: wallet-service
                               ;; crash-looped on "No such file or directory"
                               ;; for a script that `ls` showed present).
                               (file-system-mapping
                                (source (dirname script))
                                (target (dirname script)))
                               ;; The whole store (read-only). The profile's
                               ;; guile site dirs below are symlink farms into
                               ;; the store items of fibers, goblins, etc.; the
                               ;; wrapper itself mounts only guile's own
                               ;; closure, so those links dangle without this
                               ;; ("no code for module (fibers)"). The store is
                               ;; world-readable and holds no secrets.
                               (file-system-mapping
                                (source "/gnu/store")
                                (target "/gnu/store"))
                               ;; Guile libraries (read-only)
                               (file-system-mapping
                                (source "/run/current-system/profile/share/guile")
                                (target "/run/current-system/profile/share/guile"))
                               (file-system-mapping
                                (source "/run/current-system/profile/lib/guile")
                                (target "/run/current-system/profile/lib/guile"))))
                         ;; The wrapper clears the environment down to a
                         ;; short default list; the variables set below
                         ;; reach guile only when named here.
                         #:preserved-environment-variables
                         (append '("GUILE_LOAD_PATH"
                                   "GUILE_LOAD_COMPILED_PATH"
                                   "PLAYNET_DATA_DIR"
                                   "PLAYNET_WALLET_RUN_DIR")
                                 %default-preserved-environment-variables)
                         ;; Keep network namespace (wallet needs localhost)
                         #:namespaces (delq 'net %namespaces))
                      "--no-auto-compile"
                      "-L" #$module-path
                      "-s" #$script
                      "--port" #$(number->string port))
                #:user #$user
                ;; The service group is how the gateway reads the
                ;; sturdyref and how this process reads rpc-login.txt.
                #:group #$group
                #:log-file "/var/log/playnet/wallet-service.log"
                #:environment-variables
                (list (string-append "GUILE_LOAD_PATH="
                                     "/run/current-system/profile/share/guile/site/3.0:"
                                     #$module-path)
                      (string-append "GUILE_LOAD_COMPILED_PATH="
                                     "/run/current-system/profile/lib/guile/3.0/site-ccache")
                      (string-append "PLAYNET_DATA_DIR=" #$data-dir)
                      (string-append "PLAYNET_WALLET_RUN_DIR=" #$run-dir)
                      "HOME=/home/playnet")))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

(define (wallet-activation config)
  "Create the wallet's run directory and the <data-dir>/wallet-sref.txt
link into it, and write the spend-policy datum to
<data-dir>/wallet-policy.scm for wallet-service.scm to load at startup.
With spend-policy #f the policy file is left alone and wallet-service
runs zero-budget."
  (let ((data-dir (wallet-configuration-data-dir config))
        (policy   (wallet-configuration-spend-policy config))
        (user     (wallet-configuration-user config))
        (group    (wallet-configuration-group config))
        (run-dir  (wallet-configuration-run-dir config)))
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-dir)

        ;; Run directory: owned by the wallet user, traversable by the
        ;; service group only. The sturdyref inside is a spend capability,
        ;; so nothing here is world-readable.
        (mkdir-p #$run-dir)
        (chown #$run-dir
               (passwd:uid (getpwnam #$user))
               (group:gid (getgrnam #$group)))
        (chmod #$run-dir #o750)

        ;; <data-dir>/wallet-sref.txt → <run-dir>/wallet-sref.txt. While the
        ;; wallet has yet to write it the link dangles, which the gateway's
        ;; file-exists? reads as "wallet cap unavailable".
        (let ((link   (string-append #$data-dir "/wallet-sref.txt"))
              (target (string-append #$run-dir "/wallet-sref.txt")))
          (unless (and (false-if-exception
                        (eq? 'symlink (stat:type (lstat link))))
                       (string=? (readlink link) target))
            (false-if-exception (delete-file link))
            (symlink target link)))

        #$@(if policy
               (list
                #~(let ((path (string-append #$data-dir "/wallet-policy.scm")))
                    (call-with-output-file path
                      (lambda (port)
                        (write '#$policy port)
                        (newline port)))
                    (chmod path #o644)))
               '()))))

(define wallet-service-type
  (service-type
   (name 'playnet-wallet)
   (description
    "Isolated Monero wallet process. Exposes ^wallet-policy via OCapN
WebSocket on localhost:9092. The gateway resolves the sturdyref at
/var/lib/playnet/wallet-sref.txt for capability-attenuated access.
Raw wallet methods (sweep-all, unguarded transfer) are reachable only
from the wallet process's own REPL socket at
/var/run/playnet-wallet/wallet-repl.sock (0600).

The spend-policy field declares the Monero budget envelope (monthly
cap, per-tx cap, allowlist) in machines.scm. Written to
<data-dir>/wallet-policy.scm on activation. If #f, the wallet starts
with a zero-budget fail-closed policy — every transfer errors.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             wallet-shepherd-service)
          (service-extension activation-service-type
                             wallet-activation)))
   (default-value (wallet-configuration))))
