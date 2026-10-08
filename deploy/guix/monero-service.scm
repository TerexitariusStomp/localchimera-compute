;;; deploy/guix/monero-service.scm — Guix/Shepherd service for monero-wallet-rpc
;;;
;;; Runs monero-wallet-rpc as a native Shepherd service, pointed at a
;;; *remote* Monero daemon. We deliberately do NOT run monerod on the
;;; playnet server: zero blockchain storage, zero chain-sync load.
;;;
;;; Trust tradeoff: the remote daemon sees our view-key scan traffic
;;; (addresses we're watching, rough traffic patterns). The daemon
;;; cannot steal funds — spend keys stay on our box — but it sees
;;; metadata. If that becomes unacceptable, run a pruned monerod
;;; locally and flip DAEMON-ADDRESS to 127.0.0.1:18081; no other
;;; changes needed.
;;;
;;; Secrets threading (matches keria-service.scm pattern):
;;;
;;;   deploy/secrets.scm  (gitignored)
;;;     (setenv "MONERO_WALLET_PASSWORD" "<wallet file passphrase>")
;;;     (setenv "MONERO_RPC_PASSWORD"    "<localhost RPC password>")
;;;
;;;   At deploy time, machines.scm loads secrets.scm via primitive-load,
;;;   we capture the env vars with getenv, write them into 0600
;;;   password files inside /var/lib/playnet/monero/ during activation,
;;;   and pass --password-file / --rpc-login to keep the values off the
;;;   command line (ps-visible) and out of the Guix store.
;;;
;;; One-time bootstrap (cannot be scripted — needs entropy + seed):
;;;
;;;   sudo -u playnet monero-wallet-cli \
;;;        --generate-new-wallet /var/lib/playnet/monero/playnet.wallet \
;;;        --daemon-address plowsof3t5hogddwabaeiyrno25efmzfxyro2vligremt7sxpsclfaid.onion:18089 \
;;;        --mnemonic-language English
;;;
;;;   Write down the 25-word seed OFFLINE. Set the passphrase to the
;;;   value of MONERO_WALLET_PASSWORD in secrets.scm.
;;;
;;;   After that, `guix deploy` brings up monero-wallet-rpc automatically.
;;;
;;; Usage in machines.scm:
;;;
;;;   (use-modules (monero-service))
;;;   (service monero-service-type
;;;            (monero-configuration
;;;             (data-dir "/var/lib/playnet/monero")
;;;             (user "playnet")))
;;;
;;; Check after deploy:   herd status monero-wallet-rpc
;;;                       herd log    monero-wallet-rpc
;;;
;;; Capability-secured access: a ^monero-wallet Goblins actor
;;; (module/playnet/monero/wallet.scm) wraps this RPC endpoint; external
;;; callers go through a wrapping service actor that only exposes
;;; read/create-address methods. Spend methods (transfer, sweep_all)
;;; are reachable only from the operator REPL.

(define-module (monero-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages finance)      ; monero package
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (monero-configuration
            monero-configuration?
            monero-configuration-data-dir
            monero-configuration-wallet-file
            monero-configuration-rpc-port
            monero-configuration-rpc-user
            monero-configuration-daemon-address
            monero-configuration-user
            monero-service-type))

;;; ── Configuration ───────────────────────────────────────────────────────

(define-record-type* <monero-configuration>
  monero-configuration make-monero-configuration
  monero-configuration?
  ;; Package providing monero-wallet-rpc.
  (package          monero-configuration-package
                    (default monero))
  ;; Persistent wallet state dir. Holds the wallet file (created once
  ;; out-of-band), wallet cache, password files, and the poller state.
  (data-dir         monero-configuration-data-dir
                    (default "/var/lib/playnet/monero"))
  ;; Wallet file path — created once via monero-wallet-cli; see header.
  (wallet-file      monero-configuration-wallet-file
                    (default "/var/lib/playnet/monero/playnet.wallet"))
  ;; Chain height the seed-restore scans from: the wallet's birth height,
  ;; with a margin below it. 0 scans the whole chain since 2014 — days
  ;; over Tor, with the wallet's RPC port closed until it ends — so a
  ;; deploy names the height of the wallet it restores. An existing wallet
  ;; carries its own (`set refresh-from-block-height` in monero-wallet-cli).
  (restore-height   monero-configuration-restore-height
                    (default 0))
  ;; Loopback RPC port. monero-wallet-rpc default is 18082.
  (rpc-port         monero-configuration-rpc-port
                    (default 18082))
  ;; RPC user name paired with MONERO_RPC_PASSWORD in --rpc-login.
  (rpc-user         monero-configuration-rpc-user
                    (default "playnet"))
  ;; Group granted read access to rpc-login.txt (mode 0640), for a
  ;; wallet client that runs as a different user than this service.
  ;; #f keeps the file 0600 and owner-only.
  (rpc-login-group  monero-configuration-rpc-login-group
                    (default #f))
  ;; Remote Monero daemon (host:port), reached through Tor. The default is
  ;; plowsof's onion — a Tor seed node in Monero's own source
  ;; (src/p2p/net_node.inl) and on Feather Wallet's curated list. An onion
  ;; address is its operator's key, so there is no exit node in the path
  ;; and no hostname to hijack. Overridable per-deploy.
  (daemon-address   monero-configuration-daemon-address
                    (default "plowsof3t5hogddwabaeiyrno25efmzfxyro2vligremt7sxpsclfaid.onion:18089"))
  ;; #t passes --trusted-daemon, which Monero reserves for a daemon the
  ;; operator runs themselves. A third party's node is untrusted: the
  ;; wallet keeps its extra checks and tells the node less.
  (trusted-daemon?  monero-configuration-trusted-daemon?
                    (default #f))
  ;; User to run as. Must already exist in machines.scm user list.
  (user             monero-configuration-user
                    (default "playnet")))

;;; ── Shepherd service ────────────────────────────────────────────────────

(define (monero-shepherd-service config)
  (let* ((package        (monero-configuration-package config))
         (data-dir       (monero-configuration-data-dir config))
         (wallet-file    (monero-configuration-wallet-file config))
         (rpc-port       (monero-configuration-rpc-port config))
         (rpc-user       (monero-configuration-rpc-user config))
         (daemon-address (monero-configuration-daemon-address config))
         (trusted?       (monero-configuration-trusted-daemon? config))
         (user           (monero-configuration-user config))
         (wallet-rpc     (file-append package "/bin/monero-wallet-rpc"))
         ;; Activation writes both secrets to password files inside
         ;; data-dir; here we name them relative to data-dir.
         (wallet-pw-file (string-append data-dir "/wallet-password.txt"))
         (rpc-login-file (string-append data-dir "/rpc-login.txt"))
         ;; What monero-wallet-rpc reads its RPC login from; rewritten at
         ;; every start from rpc-login-file.
         (rpc-conf-file  (string-append data-dir "/wallet-rpc.conf")))
    (list
     (shepherd-service
      (documentation "monero-wallet-rpc — JSON-RPC wallet backend (remote daemon)")
      (provision '(monero-wallet-rpc))
      (requirement '(networking user-processes))
      (start
       ;; (lambda args (apply … args)): shepherd evaluates a `start` slot
       ;; ONCE at conf load, so anything read here would be the value of
       ;; that moment for every later `herd restart`. The wrapper runs at
       ;; each start, as shepherd (root), before the fork.
       ;;
       ;; The RPC login goes to monero-wallet-rpc through a 0600 config
       ;; file it reads itself, written here from rpc-login.txt — so the
       ;; password is on nobody's command line (`ps` shows every local user
       ;; an argument list), and a rotated password takes effect at the
       ;; next restart.
       (with-imported-modules '((ice-9 rdelim))
        #~(lambda args
            (use-modules (ice-9 rdelim))
            (let* ((conf  #$rpc-conf-file)
                   (login (call-with-input-file #$rpc-login-file
                            (lambda (port)
                              (let ((line (read-line port)))
                                (if (eof-object? line) "" line)))))
                   (pw    (getpwnam #$user)))
              ;; Made empty and 0600 first, filled after: the login never
              ;; sits in a file with wider permissions, even for an instant.
              (call-with-output-file conf (lambda (port) #t))
              (chmod conf #o600)
              (chown conf (passwd:uid pw) (passwd:gid pw))
              (call-with-output-file conf
                (lambda (port)
                  (format port "rpc-login=~a:~a~%" #$rpc-user login))))
            (apply
             (make-forkexec-constructor
              (append
               (list #$wallet-rpc
                     "--wallet-file"   #$wallet-file
                     "--password-file" #$wallet-pw-file
                     "--rpc-bind-ip"   "127.0.0.1"
                     "--rpc-bind-port" #$(number->string rpc-port)
                     "--config-file"   #$rpc-conf-file
                     "--daemon-address" #$daemon-address
                     ;; Route the daemon connection through Tor: the remote
                     ;; node never sees the server's IP.
                     "--proxy" "127.0.0.1:9050"
                     ;; Required when --proxy is set with a non-.onion daemon:
                     ;; monero-wallet-rpc demands explicit SSL cert override.
                     "--daemon-ssl-allow-any-cert"
                     "--log-level" "1"
                     "--non-interactive")
               (if #$trusted? (list "--trusted-daemon") '()))
              #:user #$user
              #:group "users"
              #:directory #$data-dir
              #:environment-variables
              (list (string-append "HOME=" #$data-dir))
              #:log-file "/var/log/playnet/monero-wallet-rpc.log")
             args))))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Activation ──────────────────────────────────────────────────────────
;;;
;;; - mkdir-p data-dir + chown playnet
;;; - write wallet-password.txt (0600, playnet-owned) from
;;;   MONERO_WALLET_PASSWORD captured at deploy time
;;; - write rpc-login.txt    (0600, playnet-owned) from MONERO_RPC_PASSWORD
;;; - if MONERO_WALLET_SEED is set AND the wallet file does not exist,
;;;   materialize it from the seed via `monero-wallet-cli --generate-from-json`
;;;   in --offline mode. This closes the cold-start loop: wipe the server,
;;;   `guix deploy`, and the same wallet (same addresses, same balance
;;;   after chain rescan) comes back from a single root secret in secrets.scm.
;;; - ensure /var/log/playnet exists
;;;
;;; MONERO_WALLET_PASSWORD / MONERO_RPC_PASSWORD exported at reconfigure time
;;; are written; unset, the files keep their content (os.scm's
;;; install-runtime-secrets fills them from the encrypted blob). Only a box
;;; with neither source gets empty files, and the service fails to start
;;; there — intentional, the operator populates secrets.scm. If MONERO_WALLET_SEED is
;;; unset, seed-restore is skipped entirely and the operator is expected to
;;; run monero-wallet-cli manually once (see the header bootstrap section).

(define (monero-activation config)
  (let* ((package        (monero-configuration-package config))
         (data-dir       (monero-configuration-data-dir config))
         (wallet-file    (monero-configuration-wallet-file config))
         (user           (monero-configuration-user config))
         (wallet-pw      (or (getenv "MONERO_WALLET_PASSWORD") ""))
         (rpc-pw         (or (getenv "MONERO_RPC_PASSWORD") ""))
         (rpc-group      (monero-configuration-rpc-login-group config))
         (restore-height (monero-configuration-restore-height config))
         (seed           (or (getenv "MONERO_WALLET_SEED") ""))
         (wallet-cli     (file-append package "/bin/monero-wallet-cli")))
    #~(begin
        (use-modules (guix build utils)
                     (ice-9 format))

        ;; Minimal JSON string escaping for the three fields we pass to
        ;; --generate-from-json. We don't pull in guile-json here because
        ;; activation runs with a stock guile and we want zero extra deps.
        (define (json-escape s)
          (let loop ((chars (string->list s)) (acc '()))
            (if (null? chars)
                (list->string (reverse acc))
                (let ((c (car chars)))
                  (cond
                   ((char=? c #\") (loop (cdr chars) (cons #\" (cons #\\ acc))))
                   ((char=? c #\\) (loop (cdr chars) (cons #\\ (cons #\\ acc))))
                   ((char=? c #\newline) (loop (cdr chars) (cons #\n (cons #\\ acc))))
                   ((char=? c #\tab)     (loop (cdr chars) (cons #\t (cons #\\ acc))))
                   (else (loop (cdr chars) (cons c acc))))))))

        (let* ((pw      (getpwnam #$user))
               (uid     (passwd:uid pw))
               (gid     (passwd:gid pw))
               (wpath   (string-append #$data-dir "/wallet-password.txt"))
               (rpath   (string-append #$data-dir "/rpc-login.txt"))
               (genjson (string-append #$data-dir "/.wallet-gen.json")))

          (mkdir-p #$data-dir)
          (chown #$data-dir uid gid)
          (mkdir-p "/var/log/playnet")

          ;; A password exported at reconfigure time is written; an unset
          ;; one leaves the file as it stands (the box's encrypted secrets
          ;; blob is what normally fills it — see install-runtime-secrets
          ;; in os.scm). A file that has never existed is created empty,
          ;; so a box with neither source fails at service start, visibly.
          (define (write-password path value)
            (when (or (not (string-null? value))
                      (not (file-exists? path)))
              (call-with-output-file path
                (lambda (port) (display value port)))))

          ;; Wallet password file (unlocks the wallet file itself).
          (write-password wpath #$wallet-pw)
          (chmod wpath #o600)
          (chown wpath uid gid)

          ;; RPC login password file (username is hard-coded in the
          ;; --rpc-login arg; this file holds only the password).
          (write-password rpath #$rpc-pw)
          (let ((rpc-group #$rpc-group))
            (if rpc-group
                (begin
                  (chown rpath uid (group:gid (getgrnam rpc-group)))
                  (chmod rpath #o640))
                (begin
                  (chown rpath uid gid)
                  (chmod rpath #o600))))

          ;; ── Seed-restore ──────────────────────────────────────────
          ;; Only materialize the wallet if:
          ;;   - the seed env var was set at deploy time, AND
          ;;   - the wallet file does not already exist
          ;; Otherwise leave the filesystem alone — we don't overwrite
          ;; an existing wallet, and we don't try to materialize without
          ;; a seed.
          (unless (or (string-null? #$seed)
                      (file-exists? #$wallet-file))
            (format #t "monero: restoring wallet from MONERO_WALLET_SEED at ~a~%"
                    #$wallet-file)

            ;; Write the one-shot JSON file. It contains the seed in
            ;; plaintext — we delete it right after wallet-cli finishes.
            (call-with-output-file genjson
              (lambda (port)
                (format port
                        "{\"version\":1,\"filename\":\"~a\",\"scan_from_height\":~a,\"password\":\"~a\",\"seed\":\"~a\"}"
                        (json-escape #$wallet-file)
                        #$restore-height
                        (json-escape #$wallet-pw)
                        (json-escape #$seed))))
            (chmod genjson #o600)
            (chown genjson uid gid)

            ;; monero-wallet-cli needs a HOME for its history/cache — point
            ;; it at data-dir so stray files land under playnet's control.
            (setenv "HOME" #$data-dir)

            (let ((status
                   (system* #$wallet-cli
                            "--generate-from-json" genjson
                            "--offline"
                            "--log-file" "/var/log/playnet/monero-wallet-cli.log"
                            "--log-level" "1"
                            "--command" "exit")))
              (if (zero? status)
                  (format #t "monero: wallet materialized successfully~%")
                  (format (current-error-port)
                          "monero: monero-wallet-cli exited with status ~a — see /var/log/playnet/monero-wallet-cli.log~%"
                          status)))

            ;; Scrub the seed JSON regardless of exit status.
            (when (file-exists? genjson) (delete-file genjson))

            ;; Chown the resulting wallet files to playnet. monero-wallet-cli
            ;; creates up to three artifacts: <file>, <file>.keys, and
            ;; <file>.address.txt. Only the .keys file is sensitive (it holds
            ;; the encrypted private keys), but we lock all three down.
            (for-each (lambda (f)
                        (when (file-exists? f)
                          (chmod f #o600)
                          (chown f uid gid)))
                      (list #$wallet-file
                            (string-append #$wallet-file ".keys")
                            (string-append #$wallet-file ".address.txt"))))))))

;;; ── Service type ────────────────────────────────────────────────────────

(define monero-service-type
  (service-type
   (name 'monero-wallet-rpc)
   (description
    "monero-wallet-rpc running against a remote Monero daemon. Wallet
passphrase and RPC password live in 0600 files under data-dir, sourced
from secrets.scm at deploy time. The wallet file itself must be created
once out-of-band with monero-wallet-cli — see the header of
monero-service.scm for the exact command.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             monero-shepherd-service)
          (service-extension activation-service-type
                             monero-activation)))
   (default-value (monero-configuration))))
