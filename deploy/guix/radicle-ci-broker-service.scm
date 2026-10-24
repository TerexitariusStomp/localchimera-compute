;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/radicle-ci-broker-service.scm — Shepherd service for the
;;; full-native Radicle CI broker (cib) + native adapter.
;;;
;;; cib watches the local radicle-node's event stream and, per the config
;;; below, runs the native CI adapter for matching changes. The adapter runs
;;; the repo's .radicle/native.yaml steps — the SAME contract the shell patch
;;; CI already uses, so this is a drop-in upgrade to the canonical Radicle CI.
;;;
;;; Config schema is from the crate's doc/userguide.md. The adapter binary path
;;; and the two YAML configs are spliced from the store at build time, so the
;;; whole thing is reproducible from this repo.

(define-module (radicle-ci-broker-service)
  #:use-module (radicle-ci-broker)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:export (radicle-ci-broker-shepherd-service
            radicle-ci-broker-ssh-agent-shepherd-service))

;; Our seed node's ID — the broker only acts on events from this node.
(define %localchimera-node-id
  "z6MkhQDgcmqB3koEasUZe3U7hVQM4QjQdTYn2ZQHJ9xSSh93")

;; Native adapter config (state dir for HTML/JSON reports, log, report base URL).
;;
;; The log does NOT go in /var/log/localchimera, which is `drwxr-x--- root root`. The
;; broker's own log can live there because shepherd opens `#:log-file` as root
;; before dropping to the localchimera user; the adapter is a CHILD the broker spawns
;; as localchimera, so it must open its own log and cannot — not even into a subdir,
;; since mode 750 denies localchimera the traverse. It exits 2 before emitting its
;; first protocol message, which the broker reports only as
;;
;;     no first response message
;;     failed to run adapter ... wait status ExitStatus(unix_wait_status(512))
;;
;; and the actual cause (`failed to open log file ... Permission denied`) is
;; visible only by running the adapter by hand. So the log lives beside the
;; state the adapter already owns, in a directory this service creates and
;; chowns. Separate from ci-reports because that one is published under
;; base_url, and a log is not a report.
(define %native-ci-config
  (plain-file "native-ci.yaml"
              (string-append
               "state: /var/lib/localchimera/ci-reports\n"
               "log: /var/lib/localchimera/ci-logs/native-ci.log\n"
               "base_url: https://localchimera.earth/ci/\n")))

;; Broker config: one `native` adapter, triggered on this node's default-branch
;; updates and patch create/update, only for repos carrying .radicle/native.yaml.
(define %ci-broker-config
  (mixed-text-file
   "ci-broker.yaml"
   "db: /var/lib/localchimera/radicle/ci-broker.db\n"
   "report_dir: /var/lib/localchimera/ci-reports\n"
   "queue_len_interval: 1min\n"
   "adapters:\n"
   "  native:\n"
   "    command: " (file-append radicle-native-ci "/bin/radicle-native-ci") "\n"
   "    env:\n"
   "      RADICLE_NATIVE_CI: " %native-ci-config "\n"
   "      PATH: /run/current-system/profile/bin:/var/lib/localchimera/radicle/.radicle/bin\n"
   "    sensitive_env: {}\n"
   "triggers:\n"
   "  - adapter: native\n"
   "    filters:\n"
   "    - !And\n"
   "      - !HasFile \".radicle/native.yaml\"\n"
   "      - !Node " %localchimera-node-id "\n"
   "      - !Or\n"
   "        - !DefaultBranch\n"
   "        - !PatchCreated\n"
   "        - !PatchUpdated\n"))

;; ── SSH agent for cib's job-COB signer ──────────────────────────────────────
;; cib signs job-COB writes over an actual ssh-agent PROTOCOL connection —
;; confirmed by dumping its full derived config (`cib --config … config`):
;; there is no key-file/passphrase field anywhere in the schema, only this
;; crate's ssh-agent-client dependency, which needs SSH_AUTH_SOCK pointing at
;; a live agent holding the node's signing key. Without one, every run failed
;; identically:
;;   error: Signer(AgentConnection { source: EnvVar { var: "SSH_AUTH_SOCK",
;;   source: NotPresent } })
;; (found 2026-09-16, via direct SSH investigation on the box — the broker had
;; failed every trigger since at least 2026-09-14, including real merges to
;; canonical main by a delegate, and had crashed to a stop shortly after its
;; last restart attempt that day.)
;;
;; This starts a dedicated, long-lived ssh-agent bound to a fixed socket and
;; loads it with the SAME node key radicle-node itself decrypts (same
;; 0400 passphrase-file mechanism as radicle-http-api-service.scm — read
;; fresh at start time, never baked into the store, which is world-readable).
;;
;; ssh-agent daemonizes and detaches by default, which shepherd can't
;; supervise; -D keeps it in the foreground, but then nothing else can run
;; ssh-add against it from the same process. So the start script backgrounds
;; the foreground agent itself (`… -D &`), adds the key once the socket
;; exists, then `wait`s on the agent — the wait keeps THIS script (shepherd's
;; tracked pid) alive exactly as long as the agent lives, and the TERM trap
;; forwards shepherd's stop signal to the actual agent process.
(define %ci-broker-ssh-agent-sock
  "/var/lib/localchimera/radicle/ci-broker-agent.sock")

(define %ci-broker-ssh-agent-askpass
  (program-file
   "radicle-ci-broker-askpass"
   #~(begin
       (use-modules (ice-9 textual-ports))
       (display (string-trim-right
                 (call-with-input-file "/run/secrets/rad-passphrase" get-string-all))))))

(define %ci-broker-ssh-agent-script
  (mixed-text-file
   "radicle-ci-broker-ssh-agent-start.sh"
   "#!/bin/sh\n"
   "set -e\n"
   "SOCK=" %ci-broker-ssh-agent-sock "\n"
   "rm -f \"$SOCK\"\n"
   "AGENT_PID=\n"
   "trap '[ -n \"$AGENT_PID\" ] && kill \"$AGENT_PID\" 2>/dev/null' TERM INT\n"
   "ssh-agent -a \"$SOCK\" -D &\n"
   "AGENT_PID=$!\n"
   "i=0\n"
   "while [ ! -S \"$SOCK\" ] && [ \"$i\" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done\n"
   "SSH_AUTH_SOCK=\"$SOCK\" SSH_ASKPASS=" %ci-broker-ssh-agent-askpass
   " SSH_ASKPASS_REQUIRE=force setsid ssh-add "
   "/var/lib/localchimera/radicle/.radicle/keys/radicle < /dev/null\n"
   "wait \"$AGENT_PID\"\n"))

(define (radicle-ci-broker-ssh-agent-shepherd-service)
  "Return the shepherd-service running a dedicated ssh-agent, pre-loaded with
the node's signing key, that radicle-ci-broker's own service (below) points
SSH_AUTH_SOCK at — see the module comment above for the incident this fixes."
  (shepherd-service
   (provision '(radicle-ci-broker-ssh-agent))
   (requirement '(networking user-processes))
   (documentation "SSH agent holding the node signing key, for cib's job-COB signer.")
   (start
    #~(make-forkexec-constructor
       (list "/run/current-system/profile/bin/sh" #$%ci-broker-ssh-agent-script)
       #:user "localchimera"
       #:group "users"
       #:log-file "/var/log/localchimera/ci-broker-ssh-agent.log"
       #:environment-variables
       (list "PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin")))
   (stop #~(make-kill-destructor))
   (respawn? #t)))

;; ── WAIT FOR THE NODE, IN THE CHILD ─────────────────────────────────────────
;; `(requirement '(radicle-node))` is satisfied the moment shepherd calls the
;; node STARTED, which is before the node has created its control socket. cib
;; treats a missing or refusing socket as unrecoverable and exits at once, so
;; with `respawn? #t` it burned shepherd's respawn limiter in under a second and
;; shepherd disabled it — at boot on 2026-07-20, after which the broker was dead
;; for 24 days while every deploy quietly fell through to the mcron backstop.
;; Nothing watched for it: a DISABLED service is not a failing one, and the
;; deploys still landed, just late.
;;
;; So the service waits for the socket to exist before exec'ing cib. The wait
;; lives in a wrapper the child runs, NOT in the start gexp: that body runs
;; inside shepherd itself, and a sleep loop there would stall every other
;; service's start for as long as it waited.
;;
;; It also re-arms. The wrapper waits again on every respawn, so a node restart
;; later in the machine's life costs the broker a pause rather than the limiter.
;;
;; The socket path is written as a LITERAL rather than spliced from a Scheme
;; variable: `#$` lowers an object into the store, and a bare string is not a
;; lowerable object, so `#$some-path-string` is a &gexp-input-error rather than
;; the substitution it looks like.
(define (%ci-broker-wrapper)
  (program-file
   "radicle-ci-broker-start"
   #~(begin
       (let wait ((n 0))
         (unless (or (file-exists? "/var/lib/localchimera/radicle/.radicle/node/control.sock")
                     (>= n 180))
           (sleep 1)
           (wait (+ n 1))))
       (apply execl #$(file-append radicle-ci-broker "/bin/cib") "cib"
              (list "--log-level" "info"
                    "--config" #$%ci-broker-config
                    "process-events")))))

(define (radicle-ci-broker-shepherd-service)
  "Return the shepherd-service running `cib process-events`. Requires the
radicle-node (whose events it consumes). Runs as the localchimera user with the same
RAD_HOME as the node, and waits for that node's control socket before starting
— see %ci-broker-wrapper."
  (shepherd-service
   (provision '(radicle-ci-broker))
   (requirement '(networking radicle-node radicle-ci-broker-ssh-agent))
   (documentation "Radicle CI broker — native CI on branches/patches")
   (start
    #~(begin
        ;; Report, log + DB dirs must exist and be writable by localchimera — the
        ;; adapter runs as that user and opens both itself.
        (for-each (lambda (d)
                    (unless (file-exists? d) (mkdir d))
                    (chown d (passwd:uid (getpwnam "localchimera")) (group:gid (getgrnam "users"))))
                  '("/var/lib/localchimera/ci-reports"
                    "/var/lib/localchimera/ci-logs"))
        (make-forkexec-constructor
         (list #$(%ci-broker-wrapper))
         #:user "localchimera"
         #:group "users"
         #:log-file "/var/log/localchimera/ci-broker.log"
         #:environment-variables
         (list "HOME=/var/lib/localchimera/radicle"
               "RAD_HOME=/var/lib/localchimera/radicle/.radicle"
               ;; The signer needs a live agent — see the ssh-agent service
               ;; above (its own module comment has the incident this fixes).
               ;; Literal, not spliced from %ci-broker-ssh-agent-sock — same
               ;; reason as the control-socket path below: a bare string is
               ;; not a lowerable gexp object.
               "SSH_AUTH_SOCK=/var/lib/localchimera/radicle/ci-broker-agent.sock"
               "PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin"))))
   (stop #~(make-kill-destructor))
   (respawn? #t)))
