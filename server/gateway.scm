#!/usr/bin/env -S guile
!#
;;; server/gateway.scm — OCapN gateway for playnet
;;;
;;; Replaces relay.scm.  Spawns a Goblins mycapn listening on
;;; WebSocket (always) and Reticulum (optional, when configured).
;;; Registers a ^lobby actor, and prints the sturdyref URI.
;;; Browser and mesh clients enliven this sturdyref to get
;;; capability-secured access to all services.
;;;
;;; Usage:
;;;   guile -L module server/gateway.scm [--port PORT] [--reticulum]
;;;
;;; Environment:
;;;   API_KEYS      — comma-separated API keys (fallback: OPENROUTER_KEYS)
;;;   API_PROVIDER  — provider name: nano-gpt, openrouter, openai, or generic (default: nano-gpt)
;;;   PLAYNET_DATA_DIR — persistent state dir (default /var/lib/playnet)
;;;   RETICULUM_BRIDGE_SOCKET — path to reticulum-bridge control socket
;;;                             (enables Reticulum netlayer; overrides default path)
;;;   KERIA_BRAN    — 21-char CESR passcode for KERIA agent (required for KERI auth)
;;;   KERIA_AGENT_URL — KERIA agent API URL (default: http://localhost:3901)
;;;   KERIA_BOOT_URL  — KERIA boot URL (default: http://localhost:3903)

;; A sturdyref is this PROCESS's: its swiss-num is minted at register time,
;; near the end of boot, and dies with the process. Until then the file on
;; disk names the previous process, and entry-points.json would hand every
;; fresh tab a dead address. So it goes FIRST — before the module graph
;; below loads, which takes the better part of a minute on the box: a page
;; reconnecting in that window (found live 2026-09-23) read the old address
;; back and enlivened on it. Absent, serve-static answers 503 "not yet
;; written" and the page asks again on each reconnect (day-boot.js
;; discoverGateway) until this boot has written its own. Core bindings
;; only: nothing is loaded yet.
(let ((dir (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet")))
  (for-each (lambda (f)
              (false-if-exception (delete-file (string-append dir "/" f))))
            '("gateway-sref.txt" "gateway-ret-sref.txt")))

(use-modules (fibers)
             (fibers conditions)
             (fibers operations)
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (goblins utils hashmap)
             (ice-9 format)
             (ice-9 exceptions)          ; exception-message: the boot-failure report below
             (ice-9 match)
             (ice-9 receive)
             (ice-9 textual-ports)
             (ice-9 rdelim)              ; read-line (mosquitto pw-file read below)
             (ice-9 threads)
             ((srfi srfi-1) #:select (partition))
             (playnet gateway lobby)
             (playnet gateway federate)
             ((playnet planner federation wire) #:select (signer-of signer-aid))
             ((playnet governance sturdyref-credential) #:select (spec-goods))
             ((playnet planner vf schemas) #:select (resource-specification-default-unit-of-resource))
             ((playnet planner federation host) #:select (read-kept keep! berth-swiss! berth-sturdyref wire-handshake))
             ((playnet gateway http-door-server) #:select (start-http-door!))
             ((playnet identity devices)
              #:select (device-registry-dir device-keys-at))
             ((playnet keri citizen-sig) #:select (aid-signer-keys-resolver make-keri-identity))
             ((rnrs bytevectors) #:select (make-bytevector))
             ((playnet gateway mesh-mailbox)
              #:select (mesh-mailbox-spawn-from-dir mesh-delivery-stream!))
             (goblins persistence-store syrup)
             (playnet gateway presence)
             (playnet gateway services)
             (playnet gateway terminal)
             (playnet gateway mailbox)
             (playnet keri bridge)
             ((playnet keri credentials) #:select (acdc-ensure-schemas-resolved!))
             (playnet keri inception)
             (playnet governance keri federation-peers)
             ((playnet keri recovery) #:select (register-reconnect-hook!))
             (playnet governance keri notifications)
             (playnet ai key-pool)
             (playnet interface backends scope)
             (playnet interface org-stub)
             ;; what the gateway's code uses of (playnet planner), by the module that defines it
             (playnet keri acdc)
             (playnet planner knowledge recipes bay-area-commune-seed)
             (playnet planner knowledge recipes berlin-commune-seed)
             (playnet planner knowledge recipes berlin-festival-seed)
             (playnet planner knowledge recipes bread-commune-seed)
             (playnet planner knowledge recipes farm-commune-seed)
             (playnet planner knowledge recipes federation-demo)
             (playnet planner scope earth)
             (playnet planner scope root)
             ((srfi srfi-1) #:select (any delete-duplicates find))
             (srfi srfi-11)
             ((playnet planner observation facts-sync)   ; host snapshots → live-registry
              #:select (start-host-facts-sync!))
             ((playnet planner dev priorities) #:select (issues->facts))
             ((playnet planner dev plan) #:select (seed-dev-scope! read-dev-people))
             ;; book-issue-done!/booked? reach the REPL environment below
             ;; unqualified (this script runs in (guile-user), like every
             ;; use-module here) — tools/dev-loop-close.scm's own repl-eval
             ;; calls them directly against the live dev-commune
             ((playnet planner dev ledger) #:select (book-issue-done! booked?))
             ((playnet planner dev rad-issues) #:select (rad-issue-pairs))
             ((playnet mqtt publish) #:select (mqtt-password-file))
             (playnet planner doors service)
             (playnet planner folksonomy actor)
             ((playnet planner folksonomy graph) #:select (make-folksonomy))
             (playnet planner folksonomy seed)
             ((playnet planner folksonomy pins) #:select (^pins make-pins))
             ;; …and of (playnet governance)
             (playnet governance acdc-bridge)
             (playnet governance attestation-ceremony)
             (playnet governance auditor)
             (playnet governance credentials)
             (playnet governance debts)
             (playnet identity enrollment)
             (playnet governance http-witness-publisher)
             (playnet identity oobi-host-mirror)
             (playnet governance paths)
             (playnet governance recipe-standing)
             (playnet governance recovery)
             (playnet governance scope)
             (playnet governance service)
             (playnet governance socialization)
             (playnet keri acdc)
             (playnet keri acdc-store)
             (playnet openvtc credentials)
             (playnet openvtc first-person)
             ;; The REPL prelude: an operator evaluates in (guile-user) over the REPL socket
             ;; (see "Gateway-internal REPL" below), where everything this script imports is
             ;; bound. The two umbrellas make the whole planner and governance surface
             ;; available there unqualified. The code above states its own imports and
             ;; compiles without them; they are here for the operator, not for the code.
             (playnet planner)
             (playnet governance)
             (playnet governance scope-recovery)
             (playnet governance scope-graph)
             (playnet governance pending-grants)
             ((playnet governance pending-recompositions)
              #:select (current-pending-recompositions
                        spawn-pending-recompositions))
             ((playnet utils common) #:select (env-int env-flag?))
             ((playnet governance keri scope-exchange) #:select (current-pending-grants))
             ((playnet governance keri ipex-policy) #:select (current-credential-finder
                                                   current-credential-finder-by-said))
             (playnet governance universal-commune)
             (playnet governance uc-curator)
             (playnet governance remote-scope-poller)
             (playnet governance witness-relay)
             (playnet governance keri-backend live)
             (playnet identity seat)
             (playnet identity oobi-host)
             ;; Push notifications (Web Push / VAPID)
             (playnet push vapid)
             ((playnet push crypto) #:select (vapid-public-key-bytes))
             ((playnet push adapter) #:select (^push-subscription-store ^push-adapter))
             ((playnet keri cesr) #:select (b64url-encode))
             ;; Browser notification transport
             ((playnet interface adapters browser)
              #:select (^browser-adapter))
             ((playnet notify registry) #:select (notification-formatter))
             ((playnet notify recipient)
              #:select (^recipient-registry recipient-table->datum datum->recipient-table))
             ((playnet notify rendered) #:select (rendered-notification))
             ((playnet interface adapters email) #:select (^email-adapter email-transport?))
             ((playnet identity contact-points) #:select (make-contact-point-desk))
             ((playnet notify router) #:select (^notify-router))
             ;; Monero + fleet provisioning
             (playnet gateway monero-boot)
             ;; external assets on the claimable rail (specs + acquisition
             ;; recipes) + the balance-info accessors for the one-shot seed
             (playnet monero specs)
             (playnet monero payout)
             ((playnet monero poller) #:select (start-donation-watch!))
             ((playnet monero topup) #:select (start-topup! set-topup-amounts!))
             (system repl server))

;;; ── Configuration ──────────────────────────────────────────────────────────

(define %data-dir
  (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet"))

;; The laws every scope born here starts under: a folder of rule-packs
;; (legal-registry.scm `load-rule-packs`), read into each new root's
;; ^legal-registry at spawn and persisted with it. Unset ⇒ no law.
(define %law-packs (getenv "PLAYNET_LAW_PACKS"))

(define (data-path filename)
  (string-append %data-dir "/" filename))

;; Ensure data directory exists early (syrup stores need it at creation time).
(catch #t
  (lambda () (mkdir %data-dir))
  (lambda args #f))

(define (log! fmt . args)
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

;;; ── Designator key persistence ─────────────────────────────────────────────
;;;
;;; The designator key determines the server's OCapN identity.
;;; It must survive restarts so sturdyrefs remain stable.

(define (load-or-generate-designator-key!)
  "Load the designator key from disk, or generate and save a new one."
  (let ((path (data-path "designator-key.scm")))
    (if (file-exists? path)
        (let ((data (call-with-input-file path read)))
          (log!
                  "  [gateway] loaded designator key from ~a~%" path)
          (data->private-key data))
        ;; Generate new key
        (let ((key (generate-key-pair)))
          (call-with-output-file path
            (lambda (port)
              (write (private-key->data key) port)
              (newline port)))
          (log!
                  "  [gateway] generated new designator key at ~a~%" path)
          key))))

;;; ── Parse arguments ────────────────────────────────────────────────────────

(define (parse-args args)
  "Parse command-line arguments.  Returns (values host port reticulum?)."
  (let loop ((args (cdr args))  ;; skip program name
             (host "0.0.0.0")
             (port 9090)
             (reticulum? #f))
    (match args
      (() (values host port reticulum?))
      (("--host" h . rest)
       (loop rest h port reticulum?))
      (("--port" p . rest)
       (loop rest host (string->number p) reticulum?))
      (("--reticulum" . rest)
       (loop rest host port #t))
      ((p . rest)
       (let ((n (string->number p)))
         (if n (loop rest host n reticulum?) (loop rest host port reticulum?)))))))

;;; ── Main ───────────────────────────────────────────────────────────────────

(define (main args)
  (define-values (ws-host ws-port reticulum-flag?) (parse-args args))

  ;; Reseed the PRNG from the platform: label codes and event ids draw from it,
  ;; and an unseeded state repeats the same draws after every restart.
  (set! *random-state* (random-state-from-platform))

  ;; Reticulum is enabled if --reticulum flag was passed OR if
  ;; RETICULUM_BRIDGE_SOCKET environment variable is set.
  (define reticulum-enabled?
    (or reticulum-flag? (getenv "RETICULUM_BRIDGE_SOCKET")))

  (define reticulum-control-path
    (or (getenv "RETICULUM_BRIDGE_SOCKET")
        "/var/run/reticulum-bridge.sock"))

  ;; Conditionally load the Reticulum netlayer module at runtime.
  ;; use-modules is a top-level macro, so we resolve dynamically.
  (define ^reticulum-netlayer
    (if reticulum-enabled?
        (begin
          (resolve-module '(goblins ocapn netlayer reticulum))
          (module-ref (resolve-interface '(goblins ocapn netlayer reticulum))
                      '^reticulum-netlayer))
        #f))

  (let ()

    ;; ── VAPID key for Web Push ──────────────────────────────────────────
    (define %vapid-key (load-or-generate-vapid-key! %data-dir))

    ;; Restored scope alist, captured in the KERIA-connect block below
    ;; and consumed when we wire the UC + curator further down. Lifted
    ;; here so the scope-graph hydration + UC bootstrap can reach it
    ;; from the gateway-vat block.
    (define %restored-scopes '())

    ;; Founders: PLAYNET_FOUNDERS env (comma-sep) + /var/lib/playnet/
    ;; founders.txt (one AID per line). They are seeded founder PHCs AND
    ;; act as the bootstrap governors (so they can verify newcomers) —
    ;; write founders.txt + restart to ACTIVATE First-Person; no reconfigure.
    (define %founders
      (let ((env (map string-trim-both
                      (string-split (or (getenv "PLAYNET_FOUNDERS") "") #\,)))
            (file (let ((ff (data-path "founders.txt")))
                    (if (file-exists? ff)
                        (catch #t
                          (lambda ()
                            (call-with-input-file ff
                              (lambda (port)
                                (let rd ((acc '()))
                                  (let ((l (read-line port)))
                                    (if (eof-object? l) (reverse acc)
                                        (rd (cons (string-trim-both l) acc))))))))
                          (lambda _ '()))
                        '()))))
        (filter (lambda (a) (and (string? a) (> (string-length a) 0)))
                (append env file))))

    ;; ── Connect to KERIA (if configured) ────────────────────────────────
    (let ((bran       (getenv "KERIA_BRAN"))
          (agent-url  (or (getenv "KERIA_AGENT_URL") "http://localhost:3901"))
          ;; NOT 3902 — that's KERIA's --http port (unauthenticated agent
          ;; HTTP API for OOBI resolution). /boot lives on --boot (3903);
          ;; see deploy/guix/keria-service.scm's keria-configuration.
          (boot-url   (or (getenv "KERIA_BOOT_URL")  "http://localhost:3903")))
      (when bran
        (keri-set-urls! agent-url boot-url)   ; bridge's public setter (the *keria-*-url* globals live there, not here)
        (catch #t
          (lambda ()
            ;; Bounded retry: KERIA (Python) can take several seconds to bind
            ;; its ports after its shepherd service forks — make-forkexec-
            ;; constructor marks it "started" at fork, not at listen — and the
            ;; gateway service does not `requirement` keria. So a single
            ;; keri-connect! can lose the boot race, leaving *signify-ctx* #f,
            ;; so gov-acdc-store falls back from the KERIA-backed (witnessed,
            ;; replicated) store to the local durable-dir store — still durable
            ;; (credentials survive restart on disk), just not replicated. This
            ;; retry protects that replicated tier when KERIA_BRAN is wired.
            ;; Retry with backoff; re-raise the
            ;; last error so the outer catch still logs + falls back to memory.
            (let ((max-attempts (or (string->number (or (getenv "KERIA_CONNECT_ATTEMPTS") "")) 12))
                  (backoff-sec  (or (string->number (or (getenv "KERIA_CONNECT_BACKOFF_SEC") "")) 3)))
              (let retry ((attempt 1))
                (catch #t
                  ;; keri-boot!, not keri-connect!: connect only PROBES for
                  ;; an already-booted agent and swallows its own failure
                  ;; (returns '() instead of throwing), so this retry loop
                  ;; never actually saw a failed probe — every restart
                  ;; logged "KERIA connected" whether or not the agent
                  ;; existed. keri-boot! self-heals: first-ever boot
                  ;; enrolls the agent, every boot after gets KERIA's 409
                  ;; (already exists) and treats it as success, connecting
                  ;; exactly like keri-connect! would have. That's what
                  ;; makes this reproducible across a first boot AND every
                  ;; restart/reboot after — not just whichever ran first.
                  (lambda () (keri-boot! "playnet-gateway" bran))
                  (lambda (key . args)
                    (cond
                      ((< attempt max-attempts)
                       (log! "  [gateway] KERIA connect ~a/~a failed (~a); retry in ~as~%"
                             attempt max-attempts key backoff-sec)
                       (usleep (* backoff-sec 1000000))
                       (retry (+ attempt 1)))
                      (else (apply throw key args)))))))
            (log! "  [gateway] KERIA connected (~a)~%" agent-url)
            (let ((controller-prefix (gateway-controller-init!)))
              (if controller-prefix
                  (log! "  [gateway] controller AID: ~a~%" controller-prefix)
                  (log! "  [gateway] controller AID registration failed — see [gateway-controller] log line above~%")))
            ;; Resolve every catalogued ACDC schema on the agent before
            ;; anything issues against it — KERIA rejects an acdc-issue
            ;; whose schema SAID it cannot resolve. PLAYNET_SCHEMA_SERVER
            ;; points at the static server, which serves the same catalog
            ;; at /oobi/{said}; unset logs-and-skips inside.
            (acdc-ensure-schemas-resolved!)
            ;; Phase 6: resolve peer-gateway OOBIs so cross-gateway
            ;; IPEX recipients (UC, remote federations) land in our
            ;; local kevers. KERIA refuses to send a grant if the
            ;; recipient AID isn't kev-known. PLAYNET_PEERS is
            ;; comma-separated OOBI URLs; PLAYNET_UC_AID names the
            ;; Universal Commune we federate with. Both default to
            ;; #f → Phase-6 push is a no-op (standalone gateway).
            (let ((n (resolve-peer-oobis!)))
              (when (> n 0)
                (log! "  [gateway] resolved ~a peer OOBI(s)~%" n)))
            (when (known-uc-aid)
              (log! "  [gateway] federating with UC: ~a~%" (known-uc-aid)))
            ;; ^http-witness-publisher: cross-internet push to URLs
            ;; configured via KERI_WITNESS_PUSH_URLS. Spawned now (no
            ;; oobi-host dependency); the oobi-host-mirror is added
            ;; later, after signup-vat spawns ^oobi-host. Together
            ;; they form the default-scope-witnesses list every
            ;; durable scope picks up automatically.
            (when (and (getenv "PLAYNET_SCOPES_DURABLE")
                       (not (string=? (or (getenv "PLAYNET_OOBI_AUTO_MIRROR") "1")
                                      "0")))
              (catch #t
                (lambda ()
                  (let* ((pub-vat (spawn-vat #:name "witness-publisher"))
                         (http-pub (with-vat pub-vat
                                     (spawn-http-witness-publisher))))
                    (default-scope-witnesses (list http-pub))
                    (log! "  [gateway] ^http-witness-publisher in default witnesses~%")))
                (lambda (key . args)
                  (log! "  [gateway] http-publisher wiring error: ~a ~a~%"
                        key args))))
            (install-default-handlers!))
          (lambda (key . args)
            (log! "  [gateway] KERIA connect failed: ~a ~a~%" key args))))
      ;; The tier's OFF state, said out loud: silence here cost an hour of
      ;; archaeology to establish that prod's keri-connected:false was chosen
      ;; (no KERIA_BRAN in the deploy env), not an outage. Everything below
      ;; still works — the acdc-store is local-durable, live-KERI mints are
      ;; client-side — what stays inert is witness-pool replication of
      ;; credentials, the notification poller (IPEX), and the KERIA-governor
      ;; arm of the governance service.
      (unless bran
        (log! "  [gateway] KERIA client tier OFF (no KERIA_BRAN) — acdc-store local-durable; IPEX poller + witness replication + KERIA-governor checks inert~%")))


    ;; ── Persistence registry (shared across all persistent vats) ──────
    ;; Spawned fresh each start — not itself persisted.  Enables
    ;; far-ref resolution across local vats on rehydration.
    (define persistence-vat (spawn-vat #:name "persistence"))
    (define persistence-registry
      (with-vat persistence-vat
        (spawn ^persistence-registry)))

    ;; ── Spawn service vats + actors ─────────────────────────────────────

    (define signup-store (make-syrup-store (data-path "signup.syrup")))
    (define-values (signup-vat signup-agent)
      (spawn-persistent-vat
        signup-agent-env
        (lambda () (spawn ^signup-agent (hashmap) (hashmap)))
        signup-store
        #:name "signup"
        #:persistence-registry persistence-registry))

    (define pool-vat (spawn-vat #:name "key-pool"))
    (define key-pool
      (let ((keys-env (or (getenv "API_KEYS")
                          (getenv "OPENROUTER_KEYS")
                          ""))
            (provider-name (or (getenv "API_PROVIDER") "nano-gpt")))
        (if (string=? keys-env "")
            (begin
              (log! "  [gateway] No API_KEYS — transcription disabled~%")
              #f)
            (let* ((provider (case (string->symbol provider-name)
                               ((openrouter) (openrouter-provider))
                               ((openai)     (openai-provider))
                               ((nano-gpt)   (nano-gpt-provider))
                               ((generic)    (generic-provider
                                              (or (getenv "API_BASE_URL")
                                                  (error "API_PROVIDER=generic requires API_BASE_URL"))))
                               (else (error "unknown API_PROVIDER" provider-name))))
                   (pool (make-key-pool pool-vat keys-env #:provider provider)))
              (log! "  [gateway] key-pool loaded (~a) — transcription enabled~%"
                    provider-name)
              pool))))

    ;; Start key-pool health monitor
    (when key-pool
      (start-key-pool-monitor pool-vat key-pool))

    ;; ── Run under fibers (required by WebSocket netlayer) ───────────────

    (run-fibers
     (lambda ()
      ;; The boot fiber is the one path to the registration at the very end
      ;; of this body — the sturdyref every browser tab connects to. When it
      ;; dies part-way, the vats it already spawned keep the process alive,
      ;; shepherd reports "running", and the sturdyref file on disk still
      ;; names the PREVIOUS process: a gateway that answers nothing, for as
      ;; long as it stands. Found live 2026-09-23: an ENOSPC on one log
      ;; write killed the fiber three seconds before register, and every
      ;; fresh tab looped on "no object registered with swiss-num" for
      ;; hours. So a boot that dies leaves with a non-zero status: shepherd
      ;; respawns it, and a respawn that dies the same way is a failure the
      ;; box reports instead of one it hides. Said on stderr, since a log
      ;; write may be exactly what failed.
      (with-exception-handler
       (lambda (e)
         (false-if-exception
          (let ((p (current-error-port)))
            (format p "~%  [gateway] BOOT FAILED — leaving so shepherd respawns: ~a~%"
                    (with-exception-handler
                     (lambda (_) (object->string e))
                     (lambda ()
                       (if (exception-with-message? e)
                           (string-append (exception-message e) " "
                                          (object->string (exception-irritants e)))
                           (object->string e)))
                     #:unwind? #t))
            (force-output p)))
         (primitive-exit 3))
       (lambda ()
       ;; start-notification-poller! calls spawn-fiber, which needs a live
       ;; fibers scheduler — the KERIA connect block above runs BEFORE
       ;; run-fibers starts one, so calling it there threw "No scheduler
       ;; current" on every boot with KERIA_BRAN set (never exercised
       ;; before the bran existed). keri-connected? reflects whether the
       ;; synchronous connect block above actually succeeded.
       (when (keri-connected?)
         (start-notification-poller!)
         (log! "  [gateway] notification poller started~%"))

       (define designator-key (load-or-generate-designator-key!))

       ;; OCapN vat + netlayer
       (define ocapn-vat (spawn-vat #:name "ocapn"))

       (define ws-netlayer
         (with-vat ocapn-vat
           (spawn ^websocket-netlayer
                  #:host ws-host
                  #:port ws-port
                  #:encrypted? #f
                  #:designator-key designator-key
                  #:max-peers 64)))

       (define mycapn
         (with-vat ocapn-vat
           (spawn-mycapn ws-netlayer)))

       ;; Gateway actors' vat — defined BEFORE the reticulum block
       ;; below, which spawns the mesh mailbox into it (internal
       ;; defines are letrec*: a forward reference here is a boot
       ;; crash, but only when --reticulum is on).
       (define gateway-vat (spawn-vat #:name "gateway"))

       ;; Optionally spawn and install Reticulum netlayer.
       ;;
       ;; SOFT-DEGRADE, never crash: spawning the netlayer connects to
       ;; the bridge control socket immediately, and a down /
       ;; just-respawned / wrong-perms bridge used to abort the whole
       ;; gateway boot — shepherd then crash-looped it until an
       ;; operator fixed the socket (observed 2026-06-06: a bridge
       ;; restart recreated its socket 0755 → gateway looped on
       ;; connect EPERM, /ws down throughout). Now: boot without mesh,
       ;; retry in a background fiber, wire everything on success.
       ;; #f until the netlayer is wired; the lobby mesh-registration
       ;; further down reads it (immediate path), and the retry fiber
       ;; calls register-lobby-on-mesh! itself (deferred path).
       (define ret-netlayer #f)

       (define (try-spawn-reticulum-netlayer)
         (catch #t
           (lambda ()
             (with-vat ocapn-vat
               (spawn ^reticulum-netlayer
                      #:control-path reticulum-control-path)))
           (lambda (key . args)
             (log! "  [gateway] reticulum bridge unreachable (~a ~s) — mesh off, will retry~%"
                   key args)
             #f)))

       (define (wire-reticulum! nl)
         (set! ret-netlayer nl)
         (with-vat ocapn-vat
           (<- mycapn 'install-netlayer ret-netlayer))
         ;; Wire the relay-announce path: ^lobby-session verifies a
         ;; browser persona's pre-signed announce against its
         ;; KEL-anchored pubkey, then forwards it here (announce-raw!
         ;; → bridge ANNOUNCE_RAW → mesh broadcast).
         (current-mesh-announcer ret-netlayer)
         ;; Mesh mailbox: ciphertext custody for deliveries to offline
         ;; personas (LXMF step 3). A dedicated SUBSCRIBE connection to
         ;; the bridge streams DELIVERY lines into the mailbox; sessions
         ;; drain their own destinations (derived from the KEL anchor).
         (let ((mesh-mailbox
                (let ((dir (string-append %data-dir "/mesh-mailbox")))
                  (unless (file-exists? dir) (mkdir dir))
                  (with-vat gateway-vat
                    (mesh-mailbox-spawn-from-dir dir)))))
           (current-mesh-mailbox mesh-mailbox)
           ;; Delivery stream with reconnect: the stream returns/raises
           ;; whenever the bridge restarts; without the retry loop
           ;; deliveries silently stopped until a gateway restart.
           ;; A REAL THREAD, not a fiber: mesh-delivery-stream! does
           ;; blocking IO (connect + read-line on a plain port), which
           ;; inside spawn-fiber can wedge a fibers scheduler thread —
           ;; observed stalling the boot before sturdyref registration
           ;; in the mesh e2e harness.
           (call-with-new-thread
            (lambda ()
              (let retry ()
                (catch #t
                  (lambda ()
                    (mesh-delivery-stream!
                     reticulum-control-path
                     (lambda (dest payload)
                       (with-vat gateway-vat
                         (<- mesh-mailbox 'store! dest payload)))))
                  (lambda (key . args)
                    (log! "  [gateway] mesh delivery stream ended: ~a ~s — reconnecting in 5s~%"
                          key args)))
                (sleep 5)
                (retry))))
           (log! "  [gateway] mesh-mailbox + delivery stream wired~%"))
         (log! "  [gateway] Reticulum netlayer installed (control: ~a)~%"
               reticulum-control-path))

       (when reticulum-enabled?
         (let ((nl (try-spawn-reticulum-netlayer)))
           (if nl
               (wire-reticulum! nl)
               (spawn-fiber
                (lambda ()
                  (let loop ()
                    (sleep 10)
                    (let ((nl (try-spawn-reticulum-netlayer)))
                      (if nl
                          (begin
                            (wire-reticulum! nl)
                            ;; Boot has long since passed the lobby
                            ;; block by now (first retry is t+10s);
                            ;; register it on the mesh ourselves since
                            ;; the boot-time `(when ret-netlayer …)`
                            ;; saw #f. catch: belt for the freak case
                            ;; the lobby isn't up yet — next gateway
                            ;; restart would still converge.
                            (catch #t
                              (lambda () (register-lobby-on-mesh!))
                              (lambda (key . args)
                                (log! "  [gateway] deferred lobby mesh registration failed: ~a ~s~%"
                                      key args))))
                          (loop)))))))))

       ;; ── Planner vat + scope + seed (Phase 2: memory store) ──────────
       ;; ^planner-service lives inside planner-vat alongside the stores
       ;; so its methods have synchronous near-call access. The lobby
       ;; (in gateway-vat) holds a reference; the OCapN wire is the only
       ;; cross-vat boundary.
       ;; ── EARTH: the planetary economic root ───────────────────────────────
       ;; The persisted root of the planner-vat is `earth` — a registry of every
       ;; commune's economic scope-root (module/playnet/planner/scope/earth.scm). Each
       ;; commune is a durable bundle UNDER earth, so ALL of them survive reboot
       ;; with their OWN state; and the ^planner-service reads THIS SAME registry —
       ;; one source of truth, no shadow scopes-hm. We root at earth DIRECTLY (no
       ;; meeting-scope, no migration); if planner.syrup is an older, incompatible
       ;; graph, we start clean (self-heal) — deliberate, there is no legacy
       ;; economic state to preserve.
       (define %founding-key "founding-commune")
       (define planner-store-path (data-path "planner.syrup"))
       (define (spawn-earth-vat)
         (spawn-persistent-vat earth-env (lambda () (spawn-earth))
                               (make-syrup-store planner-store-path)
                               #:persistence-registry persistence-registry))
       (define-values (planner-vat earth)
         (let ((first (catch #t (lambda () (call-with-values spawn-earth-vat list))
                        (lambda _ #f))))
           (if (and first
                    (with-vat (car first)
                      (catch #t (lambda () (equal? ($ (cadr first) 'name) "earth")) (lambda _ #f))))
               (values (car first) (cadr first))
               (begin
                 (log! "  [gateway] planner.syrup is not an earth graph — starting clean~%")
                 (false-if-exception (delete-file planner-store-path))
                 (call-with-values spawn-earth-vat values)))))
       ;; The founding commune "Playnet". On RESTART its AID is on disk, so we key it in
       ;; earth by that AID directly; on a TRUE first boot the AID isn't minted yet, so it
       ;; starts under %founding-key and is rekeyed to its AID once minted (below) — the
       ;; roster is always keyed by real scope-aids. `meeting-scope` stays the name the
       ;; rest of the boot uses; it now simply comes FROM earth.
       (define %fc-aid-file (data-path "founding-commune-aid.txt"))
       (define %fc-aid-early
         (catch #t (lambda () (and (file-exists? %fc-aid-file)
                                   (let ((s (call-with-input-file %fc-aid-file
                                              (lambda (p) (string-trim-both (read-line p))))))
                                     (and (string? s) (not (string=? s "")) s))))
           (lambda _ #f)))
       (define %fc-key (or %fc-aid-early %founding-key))
       (define meeting-scope
         (with-vat planner-vat ($ earth 'ensure-commune! %fc-key "Playnet" %law-packs)))
       ;; Rehydrated scope-roots need their (unserializable) plan→observer callbacks
       ;; re-wired: spawn-scope-root does it on CREATION, but a restored bundle didn't.
       (with-vat planner-vat
         (for-each (lambda (ac)
                     (catch #t (lambda () ($ (cdr ac) 'rewire-callbacks)) (lambda _ #f)))
                   ($ earth 'all-communes)))

       ;; The machines read themselves into the plan: every host's retained
       ;; five-minute snapshot (tools/host-facts.scm --publish on os.scm's
       ;; mcron timer → playnet/facts/host/<hostname>) syncs into the
       ;; founding commune's live-registry, so plan-scope's solves read each
       ;; machine's reservation-aware free capacity (#:live-avail). Which
       ;; scope stewards the machines is a governed choice; the founding
       ;; commune holds it today. Starts only where the gateway mosquitto
       ;; credential exists (the box writes it at activation) — a dev laptop
       ;; without a broker skips with one line instead of a retry loop.
       (if (file-exists? (mqtt-password-file "gateway"))
           (start-host-facts-sync! planner-vat (lambda () meeting-scope))
           (format #t "[host-facts-sync] no gateway mosquitto credential — host snapshot sync off~%"))

       ;; A scope's home vat by kind: governance roots (UC, federations) live
       ;; in gateway-vat; economic communes in planner-vat. Restore AND the
       ;; monitors must use the scope's own vat — a $ on a ref from another
       ;; vat throws "Not in the same vat: ^scope".
       (define (vat-for-scope-kind kind)
         (if (memq kind '(federation universal-commune)) gateway-vat planner-vat))

       ;; ── Restore durable scopes into their CORRECT vats ──────────────
       ;; restore-scope! spawns a ^scope, so it must run in a vat turn (else
       ;; "No current syscaller") — AND each scope must restore into the vat
       ;; where it is USED: governance roots (UC, federations) → gateway-vat;
       ;; economic communes → planner-vat, re-linked to their scope-root
       ;; (meeting-scope). A single vat caused "Not in the same vat: ^scope".
       ;; Populating %restored-scopes here lets the UC + founding commune
       ;; RESTORE their persisted AIDs instead of re-minting a new one every
       ;; boot. NOT gated on KERIA_BRAN (restore uses the live backend itself).
       (when (and (getenv "PLAYNET_SCOPES_DURABLE")
                  (not (string=? (getenv "PLAYNET_SCOPES_DURABLE") "0")))
         (catch #t
           (lambda ()
             ;; Restorable here means the bran vault is on disk: this loop
             ;; passes no share-store and no custodians, so a dir without a
             ;; vault can only ever fail with "no vault, custodians, or
             ;; share-store" — once per dir, every boot. Vault-less dirs are
             ;; either SYNTHETIC scopes (no bran was ever minted; they
             ;; re-create deterministically below, so skipping IS their
             ;; restore path) or the remnants of live mints that died before
             ;; their bran persisted (spawn-scope sweeps its own now, but
             ;; older ones linger). One summary line, not a page of noise.
             (define-values (restorable vaultless)
               (partition (lambda (aid) (file-exists? (scope-vault-path aid)))
                          (list-known-scopes)))
             (when (pair? vaultless)
               (log! "  [gateway] ~a scope dir(s) carry no bran vault — synthetic scopes re-mint below; failed-mint remnants can be cleared with rm -r ~a/scopes/<aid>~%"
                     (length vaultless) (playnet-state-dir)))
             (set! %restored-scopes
               (let loop ((aids restorable) (acc '()))
                 (if (null? aids)
                     (reverse acc)
                     (let* ((aid  (car aids))
                            (kind (or (read-scope-kind aid) 'commune))
                            (entry
                             (catch #t
                               (lambda ()
                                 (cons aid
                                       (with-vat (vat-for-scope-kind kind)
                                         (if (memq kind '(federation universal-commune))
                                             (restore-scope! aid #:kind kind
                                                             #:keri-backend (live-keri-backend))
                                             ;; a commune re-links to its OWN economic root under
                                             ;; earth (keyed by aid), durably restored with its own
                                             ;; state; falls back to meeting-scope (the founding
                                             ;; commune) for any scope earth doesn't yet carry.
                                             (restore-scope! aid #:kind kind
                                                             #:scope-root-ref (or ($ earth 'commune aid) meeting-scope)
                                                             #:keri-backend (live-keri-backend))))))
                               (lambda (key . args)
                                 (log! "  [scope-recovery] failed to restore ~a: ~a ~a~%"
                                       aid key args)
                                 #f))))
                       (loop (cdr aids) (if entry (cons entry acc) acc))))))
             (log! "  [gateway] restored ~a durable scope(s)~%"
                   (length %restored-scopes)))
           (lambda (key . args)
             (log! "  [gateway] scope-restore error: ~a ~a~%" key args))))

       ;; ── Replay governance state from ACDCs into the restored scopes ──
       ;; restore-scope! (above) only rebuilds a ^scope's identity (KEL +
       ;; ACDC store + keypair) — a fresh commune/federation actor still
       ;; comes back with empty `excluded`/`members`/`lineage`, even
       ;; though the ACDCs proving exclusions, CCF assessments, and
       ;; federation memberships are sitting right there in the
       ;; just-restored acdc-store. (playnet governance recovery) exists
       ;; precisely for this — replaying non-revoked ACDCs back into live
       ;; actor state — and is exercised by tests/governance/test-recovery.scm,
       ;; but wasn't called from anywhere in the boot path until now. Runs
       ;; as a second pass (not inside the loop above) because federation
       ;; recovery needs every commune ref already restored to resolve
       ;; commune-id → live ref.
       (unless (null? %restored-scopes)
         (let ((communes-by-id
                (let loop ((entries %restored-scopes) (acc (hashmap)))
                  (if (null? entries)
                      acc
                      (let ((aid (car (car entries))))
                        (loop (cdr entries)
                              (if (eq? (or (read-scope-kind aid) 'commune) 'commune)
                                  (hashmap-set acc aid (cdr (car entries)))
                                  acc)))))))
           (for-each
            (lambda (entry)
              (let* ((aid       (car entry))
                     (scope-ref (cdr entry))
                     (kind      (or (read-scope-kind aid) 'commune)))
                (catch #t
                  (lambda ()
                    (with-vat (vat-for-scope-kind kind)
                      (let ((store ($ scope-ref 'acdc-store)))
                        (when store
                          (case kind
                            ((commune)
                             (recover-commune-state scope-ref store))
                            ((federation universal-commune)
                             (recover-federation-state scope-ref store communes-by-id)))
                          (recover-lineage scope-ref store)
                          ;; Ballots: rebuild this scope's OWN ballots index
                          ;; from its snapshot + stance ACDCs, so a ballot that
                          ;; predates the restart is findable by get-ballot /
                          ;; close-ballot again.
                          ;;
                          ;; Safe at boot only because ^ballot's verifier now
                          ;; accepts KERI-signed stances, which verify against
                          ;; a self-certifying AID and need no registry entry.
                          ;; The sealer registry is necessarily EMPTY at boot
                          ;; (no citizen has reconnected, and Goblins sealers
                          ;; can't be reconstructed anyway), so under the old
                          ;; registry-only verifier this would have produced
                          ;; ballots nobody could cast on.
                          (let ((sr ($ scope-ref 'scope-root)))
                            (when sr
                              (recover-ballots-into-scope!
                               scope-ref store ($ sr 'ballot-store) (hashmap))))))))
                  (lambda (key . args)
                    (log! "  [scope-recovery] state-replay failed for ~a (~a): ~a ~a~%"
                          aid kind key args)))))
            %restored-scopes)
           (log! "  [gateway] replayed governance state for ~a restored scope(s)~%"
                 (length %restored-scopes))))

       ;; ── ACDC credential store ──────────────────────────────────────
       ;; When KERIA is connected, use the KERIA-backed store so
       ;; credentials persist via the witness pool. Otherwise fall back
       ;; to in-memory (credentials lost on restart but tests work).
       ;; Defined BEFORE the planner-service so the socialization plug can
       ;; fold each commune's live grants into its solves (see #:plan-fn below).
       (define gov-acdc-store
         (with-vat planner-vat
           (if (keri-connected?)
               (let ((proc (module-ref
                             (resolve-interface
                               '(playnet governance keria-store))
                             'spawn-keria-acdc-store)))
                 (proc (gateway-controller-aid-name)))
               ;; No KERIA client → DURABLE local-disk store, NOT pure memory.
               ;; ^acdc-store's #:durable-dir writes every credential through
               ;; to disk and replays them on startup (survives process death)
               ;; — the same mechanism scope-recovery / oobi-host / mesh-mailbox
               ;; already use. Without this, the whole ACDC credential graph
               ;; (personhood, delegations, stances, work/skill attestations)
               ;; was wiped on every gateway restart. The KERIA-backed tier
               ;; above adds witness-pool replication + cross-node verifiability
               ;; on top; this tier stops the restart-wipe with zero new infra.
               (spawn-acdc-store #:durable-dir (data-path "acdc")))))

       (log! "  [gateway] acdc-store: ~a~%"
              (if (keri-connected?) "KERIA-backed" "durable (local disk)"))

       ;; Demo seed only in dev (PLAYNET_SEED_DEMO=1). Production starts
       ;; CLEAN: the planner holds no scope here; the founding "Playnet"
       ;; commune is created under the UC below and registered by its real
       ;; scope-aid (add-scope!), so the dial's scope-list shows a real
       ;; commune, never the "org:meeting" demo string.
       (define %seed-demo? (env-flag? "PLAYNET_SEED_DEMO"))
       (define planner-service
         (with-vat planner-vat
           ;; PLAYNET_SEED_FED=granary|table seeds the founding commune as one
           ;; member of the flour federation (federation-demo.scm), opt-in:
           ;; what a gateway on the wire plans over in a two-gateway run.
           ;; Seeded once per state dir (the once-guard reads the durable
           ;; observer); defensive, because a demo seed must never be able
           ;; to abort the gateway boot.
           (let ((fed (getenv "PLAYNET_SEED_FED")))
             (when (and fed (not (string=? fed "")))
               (catch #t
                 (lambda ()
                   (when (null? ($ ($ meeting-scope 'observer) 'all-resources))
                     (seed-fed-commune! meeting-scope "fed" (string-append "commune-" fed)
                                        (string-append (string-upcase (substring fed 0 1)) (substring fed 1))
                                        (string-append "venue-" fed) 42.70 23.32
                                        (if (string=? fed "granary") 300.0 0.0))
                     (log! "  [gateway] founding commune seeded as the federation's ~a~%" fed)))
                 (lambda (k . a) (log! "  [gateway] federation seed skipped: ~a ~a~%" k a)))))
           (spawn ^planner-service
                  (hashmap)               ; local scopes-hm unused in prod — earth is the roster
                  plain-plan-fn           ; the plain solve; governance enters as readers below
                  earth                   ; ONE source of truth: the planner reads earth
                  ;; GOVERNANCE AS READERS (planner/doors/service.scm header): each
                  ;; a fact derived off the stores, handed as a reader, never
                  ;; imported. socialized-readers: the custody view, the
                  ;; demand fold (#:scope-of hands back the service's
                  ;; standing ^demand-node), the span gate's mappings (read
                  ;; at each solve: whose place a place is, what a resource
                  ;; is, who holds its rights, the UC's aid), the stamp and
                  ;; the live pool. Then the debts, the barbell's standing,
                  ;; the steward gate and the plan-part rail.
                  (append
                   (socialized-readers
                    gov-acdc-store
                    #:scope-of (lambda (aid) (and (string? aid) (standing-demand-node-of aid)))
                    #:voice-source standing-credit-uc
                    #:consent-of (lambda ()
                                   (list #:place-scope-of scope-of-place
                                         #:spec-of spec-of-resource
                                         #:rights-of (lambda (rid) (title-rights-of gov-acdc-store rid (known-uc-aid)))
                                         #:uc-aid (known-uc-aid))))
                   (let ((knows-reading
                          ;; how an owner knows a person: their synced contact
                          ;; book (the lobby's per-AID file) and signed vouches
                          (make-knows gov-acdc-store
                            #:contacts-of (lambda (aid)
                                            (let ((f (contacts-file-for aid)))
                                              (if (file-exists? f)
                                                  (call-with-input-file f read)
                                                  '()))))))
                   (list
                    (cons 'debts open-debts-alist)
                    (cons 'owed debts-owed-in-xmr)
                    (cons 'settle settle-debts!)
                    (cons 'standing
                          (lambda (root aid)
                            (catch #t
                              (lambda ()
                                ;; ONE record per recipe: the solve reads its curves,
                                ;; the face (recipes.ts) its rows, yield and runs
                                (scope-standing root
                                  #:observed (contrary-observations-of gov-acdc-store aid)
                                  ;; a scope's regime claim on a recipe's domain licenses its statistics
                                  #:regime-of (lambda (rid) (live-regime-of gov-acdc-store rid))))
                              (lambda (k . a)
                                (log! "  [gateway] standing read skipped for ~a: ~a ~a~%" aid k a)
                                #f))))
                    ;; the steward gate: an owner's `eligible` rule on a custody
                    ;; grant — who may be assigned to work drawing on the means
                    ;; they lent — read off the grant and the owner's synced
                    ;; contact book (the lobby's per-AID file), asked by the
                    ;; planner at the doors where a person is chosen
                    (cons 'steward (make-may-steward gov-acdc-store #:knows knows-reading))
                    ;; the same reading for a slot's own rule: how its owner
                    ;; knows the other side, asked by match-slots
                    (cons 'knows knows-reading)
                    (cons 'hands (lambda (sid) (plan-part-hands-of gov-acdc-store sid)))
                    (cons 'observed (lambda (sid) (contrary-readings-of gov-acdc-store sid)))))))))

       (log! "  [gateway] planner-service ready (demo-seed: ~a)~%" %seed-demo?)

       ;; arc-time priors: re-price the scope's located places when the
       ;; routing engine's tileset has drifted from the prior file's stamp.
       ;; Strictly best-effort — engine down / no located places / module
       ;; absent all leave the planner on its geometric fallback (parity).
       (catch #t
         (lambda ()
           (let ((refresh (module-ref (resolve-interface '(playnet planner scope live))
                                      'refresh-scope-priors!)))
             (log! "  [gateway] arc-time priors: ~a~%"
                   (with-vat planner-vat (refresh meeting-scope)))))
         (lambda (k . args)
           (log! "  [gateway] arc-time priors: skipped (~a)~%" k)))

       ;; ── Turn ON the credential substrate for the meeting commune ───
       ;; The gateway builds its scope via spawn-scope-root, which bypasses
       ;; the governance spawn-scope path that auto-installs credentialing,
       ;; so wire it explicitly: planner events on this scope now mint the
       ;; work / skill / intent / commitment / claim ACDCs into gov-acdc-store
       ;; (the in-memory or KERIA-backed store above). Runs in planner-vat,
       ;; where the scope's observer + plan-store live.
       ;;
       ;; On a first boot the founding commune's ^scope is minted further down
       ;; and its own spawn-scope re-installs these hooks with a signer. On
       ;; every RESTART that mint is skipped (the AID is already on disk), so
       ;; this wiring is the one that stands — and without a signer here, each
       ;; work / claim / intent / commitment ACDC the live gateway records
       ;; issues with `signature: #f`. The restored ^scope holds the key, so
       ;; pass it: cred-signed-by-scope routes through its sign-said and the
       ;; keypair stays in the actor.
       ;;
       ;; The issuer travels with the signer. A verifier checks the signature
       ;; against the issuer AID, so a record signed by the founding commune
       ;; must name the founding commune as issuer — signing under one AID
       ;; while issuing under another fails to bind, which is worse than not
       ;; signing at all.
       ;;
       ;; That issuer is the founding commune's AID, the one earth keys the
       ;; commune by and the same AID the founder PHC below issues under.
       ;; `gateway-controller-aid-name` is this gateway's OWN local KERIA
       ;; identity, not an AID anything can verify a commune's authority
       ;; against, and it stands here only for the boot where no commune
       ;; AID exists yet.
       (with-vat planner-vat
         (let* ((fc-scope (and %fc-aid-early
                               (assoc-ref %restored-scopes %fc-aid-early)))
                (issuer   (or %fc-aid-early (gateway-controller-aid-name))))
           (install-credentialing! meeting-scope gov-acdc-store issuer
                                   #:signer fc-scope)
           (log! "  [gateway] credentialing: meeting commune wired to acdc-store \
(issuer ~a, ~a)~%"
                 issuer (if fc-scope "signed" "unsigned — no restored scope key"))))

       ;; ── Reconcile the planner with the durable ACDC record ─────────
       ;; The economic state is persisted twice, independently, on local
       ;; disk: the planner scope-root via planner.syrup (native portrait,
       ;; restored above by spawn-persistent-vat) and gov-acdc-store via
       ;; #:durable-dir. The portrait is the primary and is complete on an
       ;; ordinary restart, so this reconcile is then an idempotent no-op —
       ;; recover-economic-state skips every commitment / intent / work-event
       ;; already present (by id — see governance/recovery.scm). Its real job
       ;; is the disaster case: if planner.syrup was lost or corrupted while
       ;; the durable acdc-store survived, it rebuilds the planner from the
       ;; credential record. No gate — idempotency makes it correct on every
       ;; boot. (It no longer depends on a KERIA-backed store; the durable-dir
       ;; fallback persists the ACDCs just as well, locally.)
       (catch #t
         (lambda ()
           (with-vat planner-vat
             (recover-economic-state meeting-scope gov-acdc-store))
           (log! "  [gateway] planner reconciled with durable ACDC record~%"))
         (lambda (key . args)
           (log! "  [gateway] economic-state reconcile skipped: ~a ~a~%" key args)))

       ;; First-Person: install the portable personhood gate on the planner.
       ;; Provisional AIDs (no live PHC in any ecosystem) may browse but not
       ;; consume — claim / willing / journey return 'needs-personhood.
       (with-vat planner-vat
         (<- planner-service 'set-personhood-checker!
             ;; fail OPEN until the commune has any person — a fresh commune
             ;; with no PHCs can vouch no one in, so gating would deadlock.
             ;; Once bootstrapped, only verified persons pass.
             (lambda (aid)
               (or (not (personhood-bootstrapped? gov-acdc-store))
                   (holds-any-live-phc? gov-acdc-store aid)))))
       (log! "  [gateway] First-Person personhood gate installed~%")

       ;; The WITNESS DOOR: the k-of-n work-witness ceremony, driven from the
       ;; browser through the planner service — which stays oblivious to
       ;; governance, the same injection the personhood gate uses. A scope
       ;; credentialed by install-credentialing! resolves its own store; the
       ;; gateway's shared store stands in for the rest. At quorum the
       ;; single-signer provenance credential STRENGTHENS in place to its
       ;; witnessed, multisig form.
       (with-vat planner-vat
         (<- planner-service 'set-witness-door!
             (make-federated-witness-door
              #:store-of (lambda (scope-aid)
                           (or (scope-acdc-store scope-aid) gov-acdc-store))
              ;; a co-signature that leaves for another gateway carries the
              ;; witness's bundle — their personhood and key log — so the
              ;; origin can check a signature from someone it never saw
              #:bundle-of (lambda (aid)
                            (let ((r ($ governance-svc 'fp-my-vouches aid)))
                              (and (pair? r) (eq? 'ok (car r))
                                   (string? (cdr r)) (not (string-null? (cdr r)))
                                   (cdr r)))))))
       ;; ── being recognised: the ask's rails beyond the inbox ──────────
       ;; An enrollment ask is told to every recognised person through the
       ;; notify-router — their bound channels, the people who already vouch
       ;; for the candidate first — and the inbox says whether the reader
       ;; already vouches. Both read the gateway's credential store; the
       ;; announcer runs inside the planner vat (where ceremonies spawn), so
       ;; the store read is near and the router call crosses async.
       (current-vouch-reader
        (lambda (reader subject)
          (pair? (vrc-groups-of gov-acdc-store reader subject))))
       (current-enroll-announcer
        (lambda (ctx)
          (let* ((cand  (assq-ref ctx 'worker))
                 (people (delete-duplicates
                          (filter (lambda (a) (not (equal? a cand)))
                                  (map cred-holder
                                       (filter phc-live?
                                               ($ gov-acdc-store 'by-schema
                                                  *schema-playnet-personhood*))))))
                 (first (filter (lambda (a) (pair? (vrc-groups-of gov-acdc-store a cand))) people))
                 (rest  (filter (lambda (a) (not (member a first))) people)))
            (<-np notify-router 'notify-scope (append first rest)
                  `((kind . enroll-ask)
                    (said . ,(or (assq-ref ctx 'said) ""))
                    (candidate . ,cand)
                    (scope . ,(assq-ref ctx 'scope)))))))
       ;; …and the pull half: every peer's published requests and attests,
       ;; on the same cadence-and-trust shape the /scopes federation rides.
       ;; A REAL THREAD (blocking HTTP), landing inside the planner vat,
       ;; where the ceremonies live.
       (let ((peers (parse-peers-env)))
         (when (pair? peers)
           (call-with-new-thread
            (lambda ()
              (let loop ()
                (for-each
                 (lambda (peer)
                   (catch #t
                     (lambda ()
                       (let ((r (poll-peer-witness! peer
                                  #:in-vat (lambda (th) (with-vat planner-vat (th)))
                                  ;; a remote witness's bundle is presented before
                                  ;; their signature lands (governance present-bundle)
                                  #:present (lambda (witness bundle)
                                              ($ governance-svc 'present-bundle witness bundle)))))
                         (when (getenv "PLAYNET_WITNESS_POLL_DEBUG")
                           (log! "  [gateway] witness poll ~a → ~a~%" peer r)))
                       ;; a PEER is the operator's word that another graph is
                       ;; ours to recognise: its Universal Commune joins the
                       ;; roots this gateway honours (multi-root
                       ;; cross-recognition), learned on this same tick
                       (let ((uc (peer-universal-commune-aid peer)))
                         (when uc (recognise-root! uc))))
                     (lambda (key . args)
                       (log! "  [gateway] witness poll ~a failed: ~a ~a~%"
                             peer key args))))
                 peers)
                ;; PLAYNET_WITNESS_POLL_SECS: the harness runs two gateways
                ;; and cannot wait half a minute per hop
                (sleep (or (string->number (or (getenv "PLAYNET_WITNESS_POLL_SECS") "")) 30))
                (loop))))
           (log! "  [gateway] witness relay polling ~a peer(s): ~a~%" (length peers) peers)))
       (log! "  [gateway] work-witness door installed (federated via witness relay)~%")

       ;; ── Pending-grants queue (durable scope-side retry) ────────────
       ;; Holds outbound scope-AID-signed IPEX grants that failed
       ;; delivery (KERIA was momentarily unreachable, OOBI not yet
       ;; resolved, etc.). Persisted to disk so a gateway restart
       ;; mid-outage doesn't drop deliveries on the floor. The drain
       ;; fiber below replays entries every 60s and on KERIA-reconnect.
       (define pending-grants-vat (spawn-vat #:name "pending-grants"))
       ;; Same PLAYNET_DATA_DIR convention as every other gateway-owned
       ;; file (this was the one straggler in the XDG state dir). A queue
       ;; persisted at the old location migrates in once — retry entries
       ;; must survive the path change the same way they survive restarts.
       (define pending-grants-file (data-path "pending-grants.scm"))
       (let ((old (string-append (playnet-state-dir) "/pending-grants.scm")))
         (when (and (file-exists? old) (not (file-exists? pending-grants-file)))
           (catch #t
             (lambda ()
               (copy-file old pending-grants-file)
               (delete-file old)
               (log! "  [gateway] pending-grants queue migrated from ~a~%" old))
             (lambda (k . a)
               (log! "  [gateway] pending-grants migration failed: ~a ~a~%" k a)))))
       (define pending-grants-ref
         (with-vat pending-grants-vat
           (spawn-pending-grants #:persist-file pending-grants-file)))
       (current-pending-grants pending-grants-ref)
       (log! "  [gateway] pending-grants: ~a entries restored from ~a~%"
              (with-vat pending-grants-vat ($ pending-grants-ref 'count))
              pending-grants-file)

       ;; ── Credential finders for inbound /exn/ipex/{apply,agree} ─────
       ;; Both finders search the same stores in the same order — the
       ;; gateway's governance store first, then every scope's store via
       ;; the scope graph — and differ only in what they ask of each
       ;; store. ONE walk, two lookups. Graph reads enter the graph's own
       ;; vat (in-graph-vat); the refs it returns are commune scopes
       ;; living in planner-vat, read there. #f (nothing found, or any
       ;; store unreachable) means spurn/refuse — refusal is the default.
       (define (find-in-credential-stores lookup)
         ;; lookup: acdc-store ref → cred | #f, called inside planner-vat
         (catch #t
           (lambda ()
             (or (with-vat planner-vat (lookup gov-acdc-store))
                 (let ((g (current-scope-graph)))
                   (and g
                        (any (lambda (aid)
                               (let ((ref (in-graph-vat
                                           (lambda () ($ g 'find-ref aid)))))
                                 (and ref
                                      (let ((store (with-vat planner-vat
                                                     ($ ref 'acdc-store))))
                                        (and store
                                             (with-vat planner-vat
                                               (lookup store)))))))
                             (in-graph-vat (lambda () ($ g 'all-aids))))))))
           (lambda _ #f)))

       ;; apply-side: "a non-revoked credential matching SCHEMA where
       ;; REQUESTER could plausibly be the holder" (first hit, FIFO
       ;; by-schema order). agree-side: the exact credential by SAID —
       ;; the grant must produce what the apply-side offered, and a
       ;; locally-issued governance credential is not in KERIA's
       ;; registry to export.
       (current-credential-finder
        (lambda (schema requester)
          (find-in-credential-stores
           (lambda (store)
             (find (lambda (c)
                     (and (not (cred-revoked? c))
                          (or (equal? requester (cred-holder c))
                              (not (cred-holder c)))))
                   ($ store 'by-schema schema))))))
       (current-credential-finder-by-said
        (lambda (cred-said)
          (find-in-credential-stores (lambda (store) ($ store 'get cred-said)))))
       (log! "  [gateway] credential-finder wired for inbound apply + agree~%")

       ;; Single drain entry point — called by the periodic fiber AND
       ;; by the post-reconnect hook so a KERIA outage is followed by
       ;; an immediate retry pass instead of waiting up to 60s. The
       ;; unified ^pending-grants queue covers BOTH scope-AID-signed
       ;; grants (enqueued by scope-deliver-grant!) and umbrella-AID-
       ;; signed grants (enqueued by ^keria-acdc-store's %try-grant)
       ;; — one drain call, one persistence layer.
       (define (drain-all-pending!)
         (catch #t
           (lambda ()
             (let ((result (with-vat pending-grants-vat
                             ($ pending-grants-ref 'drain!))))
               (when (and (pair? result) (> (car result) 0))
                 (log! "  [gateway] drained ~a pending-grants (~a still pending)~%"
                       (car result) (cdr result)))))
           (lambda (key . args)
             (log! "  [gateway] drain error: ~a ~a~%" key args))))

       ;; Periodic drain: catches steady-state deferred deliveries.
       (spawn-fiber
        (lambda ()
          (let loop () (sleep 60) (drain-all-pending!) (loop))))

       ;; Reconnect-edge drain: when KERIA recovers from an outage,
       ;; retry queued deliveries immediately rather than waiting for
       ;; the next periodic tick.
       (register-reconnect-hook! drain-all-pending!)

       ;; ── Audit + custody scheduling ─────────────────────────────────
       ;; Wires the already-existing ^federation-auditor (one per
       ;; federation/UC scope) and ^custody-half-life-watcher (one per
       ;; scope of any kind) into periodic-fire fibers. Auditor emits
       ;; audit-pass / incoherence-alert ACDCs into the federation's
       ;; own acdc-store — Phase 6 IPEX push then propagates them to
       ;; peers. Watcher emits reversion-attestation on expired
       ;; custody-attestation credentials.
       (define %audit-interval-sec
         (env-int "PLAYNET_AUDIT_INTERVAL_SEC" 3600))    ; 1h default
       (define %custody-tick-sec
         (env-int "PLAYNET_CUSTODY_TICK_SEC"   21600))   ; 6h default

       (define (spawn-audit-fiber! actor-ref method interval-sec label vat)
         "Generic: tick ACTOR-REF.METHOD every INTERVAL-SEC in VAT (the
          monitored actor's vat). Logs each fire so audit cycles are
          visible; catches per-tick errors so one bad cycle doesn't kill
          the fiber."
         (spawn-fiber
          (lambda ()
            (let loop ()
              (sleep interval-sec)
              (catch #t
                (lambda ()
                  (let ((result (with-vat vat
                                  ($ actor-ref method))))
                    (log! "  [gateway] ~a tick: ~a~%" label result)))
                (lambda (key . args)
                  (log! "  [gateway] ~a tick error: ~a ~a~%"
                        label key args)))
              (loop)))))

       (define %auditors '())       ; alist aid → auditor-ref
       (define %watchers '())       ; alist aid → watcher-ref


       (define (wire-scope-monitors! scope-aid scope-ref scope-kind)
         "Spawn auditor (for federation/UC kinds) + custody-watcher
          (for any kind that issues custody-attestation creds) and the
          fibers that tick them. Idempotent per scope-aid; second call
          is a no-op."
         (define monitor-vat (vat-for-scope-kind scope-kind))
         (unless (assoc scope-aid %auditors)
           (when (memq scope-kind '(federation universal-commune))
             (let ((auditor (with-vat monitor-vat
                              (spawn-federation-auditor scope-ref))))
               (set! %auditors (cons (cons scope-aid auditor) %auditors))
               (spawn-audit-fiber! auditor 'audit! %audit-interval-sec
                                   (format #f "auditor[~a]"
                                           (substring scope-aid 0
                                             (min 12 (string-length scope-aid))))
                                   monitor-vat))))
         (unless (assoc scope-aid %watchers)
           ;; Default custodian on expiry: the scope itself (resources
           ;; revert to scope custody). Operators can override later.
           (let ((watcher (with-vat monitor-vat
                            (spawn-custody-half-life-watcher
                             scope-ref
                             (lambda (_spec) scope-aid)))))
             (set! %watchers (cons (cons scope-aid watcher) %watchers))
             (spawn-audit-fiber! watcher 'tick! %custody-tick-sec
                                 (format #f "custody[~a]"
                                         (substring scope-aid 0
                                           (min 12 (string-length scope-aid))))
                                 monitor-vat))))

       ;; Wire every restored scope. Future scopes spawned at runtime
       ;; pick up monitors on next gateway restart.
       (for-each
        (lambda (entry)
          (let* ((aid  (car entry))
                 (ref  (cdr entry))
                 (kind (or (read-scope-kind aid) 'commune)))
            (wire-scope-monitors! aid ref kind)))
        %restored-scopes)

       (log! "  [gateway] scheduled ~a auditor(s), ~a custody-watcher(s)~%"
             (length %auditors) (length %watchers))

       ;; Every federation this gateway holds answers for itself on the wire
       ;; (gateway/federate.scm `serve-federation!`): a desk that hands a
       ;; member the spec — the credentials that stand, signed under the
       ;; federation's AID — and the fold its members tell, each at a
       ;; sturdyref that stands across restarts. The desk's sturdyref is kept
       ;; at federation-desk/<aid>/sref.txt, what a commune names beside the
       ;; federation's AID in its federation.scm.
       (for-each
        (lambda (entry)
          (let* ((aid (car entry)) (ref (cdr entry))
                 (kind (or (read-scope-kind aid) 'commune)))
            (when (eq? kind 'federation)
              (catch #t
                (lambda ()
                  (with-vat (vat-for-scope-kind kind)
                    (when ($ ref 'has-keypair?)
                      (let ((dir (data-path (string-append "federation-desk/" aid))))
                        (on (serve-federation! ref (scope-signer aid ref) mycapn ws-netlayer dir)
                            (lambda (served)
                              (keep! (string-append dir "/sref.txt") (assq-ref served 'sturdyref))
                              (log! "  [gateway] federation ~a answers at ~a~%"
                                    aid (assq-ref served 'sturdyref))))))))
                (lambda (k . a)
                  (log! "  [gateway] federation desk for ~a failed: ~a ~a~%" aid k a))))))
        %restored-scopes)

       ;; ── Peer-status snapshot for /peer-status.json ─────────────────
       ;; Periodic ticker queries KERIA via the bridge helpers
       ;; (keri-list-contacts → keri-peer-status per AID) and writes a
       ;; snapshot to disk. serve-static (no libsodium / no signify
       ;; creds in its env) reads the file and renders JSON. This is
       ;; the operator's answer to capability #8: "why aren't grants
       ;; from peer X landing?" — without any keripy fork.
       (define %peer-status-tick-sec
         (env-int "PLAYNET_PEER_STATUS_TICK_SEC" 60))

       (define (write-peer-status-snapshot!)
         (let* ((contacts (catch #t
                            (lambda () (keri-list-contacts))
                            (lambda _ '())))
                (entries
                 (map (lambda (c)
                        (let* ((aid (or (assoc-ref c "id")
                                        (assoc-ref c "aid") ""))
                               (alias (or (assoc-ref c "alias") ""))
                               (status (catch #t
                                         (lambda () (keri-peer-status aid))
                                         (lambda _ '()))))
                          `((aid . ,aid)
                            (alias . ,alias)
                            (resolved? . ,(or (assoc-ref status 'resolved?) #f))
                            (pending-ops . ,(or (assoc-ref status 'pending-ops) 0))
                            (oobi-known? . ,(or (assoc-ref status 'oobi-known?) #f)))))
                      (if (list? contacts) contacts '())))
                (file (data-path "peer-status.scm")))
           (call-with-output-file file
             (lambda (port)
               (write `((updated . ,(current-time))
                        (peers . ,entries))
                      port)
               (newline port)))))

       (spawn-fiber
        (lambda ()
          (let loop ()
            (catch #t write-peer-status-snapshot!
              (lambda (key . args)
                (log! "  [gateway] peer-status snapshot error: ~a ~a~%" key args)))
            (sleep %peer-status-tick-sec)
            (loop))))
       (log! "  [gateway] peer-status writer running (every ~as)~%"
             %peer-status-tick-sec)

       ;; ── the plan tick: schedules keep up with the clock ────────────────
       ;; The solve path itself runs on no timer, so this fiber asks the
       ;; planner service, every %plan-tick-sec, to re-solve what has fallen
       ;; behind (resolve-stale!): caches older than the tick, and scopes
       ;; with standing needs that have never solved — which also warms a
       ;; fresh gateway's snapshots before anyone opens the orb. The first
       ;; tick waits a full interval so boot settles. 0 turns it off.
       (define %plan-tick-sec (env-int "PLAYNET_PLAN_TICK_SEC" 900))
       (when (> %plan-tick-sec 0)
         (spawn-fiber
          (lambda ()
            (let loop ()
              (sleep %plan-tick-sec)
              (catch #t
                (lambda ()
                  ;; ONE scope per vat turn, a breath between turns: a whole
                  ;; sweep held in one turn starves every queued
                  ;; scope-snapshot read behind the solves (a signed-in dial
                  ;; then shows no plan at all). SEEN is the sweep's own
                  ;; memory — each pass visits a scope at most once.
                  (let sweep ((seen '()))
                    (let* ((t0  (current-time))
                           (sid (with-vat planner-vat
                                  ($ planner-service 'resolve-one-stale!
                                     %plan-tick-sec seen))))
                      ;; each scope's own solve time, on the clock: the
                      ;; number the vat was held for (every read queues
                      ;; behind it), which is what a cadence question needs
                      (when sid
                        (log! "  [gateway] plan tick: ~a re-solved in ~as (~a)~%"
                              sid (- (current-time) t0)
                              (strftime "%H:%M:%S" (localtime (current-time)))))
                      (if sid (begin (sleep 1) (sweep (cons sid seen)))
                          (when (pair? seen)
                            (log! "  [gateway] plan tick: re-solved ~a scope(s)~%"
                                  (length seen)))))))
                (lambda (k . a)
                  (log! "  [gateway] plan tick error: ~a ~a~%" k a)))
              (loop))))
         (log! "  [gateway] plan tick running (every ~as, one scope per turn)~%" %plan-tick-sec))

       ;; ── Federation-status snapshot for /federation-status.json ─────
       ;; Boot timestamp + summary written to disk so serve-static (in
       ;; its own process, no libsodium deps) can render the health
       ;; endpoint without calling back into the gateway vat.
       (catch #t
         (lambda ()
           (let ((status-file (data-path "federation-status.scm")))
             (call-with-output-file status-file
               (lambda (port)
                 (write
                  `((boot-time . ,(current-time))
                    (peers . ,(length (parse-csv-env "PLAYNET_PEERS")))
                    ;; the UPWARD parent (PLAYNET_UC_AID) — the UC another
                    ;; gateway's federations push membership to. Empty on the
                    ;; UC's own gateway, which is correct and used to read as
                    ;; "no UC": the LOCAL UC rides the JSON as `local-uc`,
                    ;; joined in by serve-static from universal-commune-aid.txt.
                    (federation-parent-uc . ,(or (known-uc-aid) #f))
                    (keri-connected? . ,(catch #t
                                          (lambda () (keri-connected?))
                                          (lambda _ #f)))
                    (auditors . ,(length %auditors))
                    (custody-watchers . ,(length %watchers)))
                  port)
                 (newline port)))))
         (lambda (key . args)
           (log! "  [gateway] federation-status write error: ~a ~a~%"
                 key args)))

       ;; ── Governance service ─────────────────────────────────────────
       ;; Lives in planner-vat (same vat as scope-root and ballot-store).
       ;; Credentials are checked against the live KERIA via the
       ;; (playnet keri inception) predicates. If KERIA isn't connected,
       ;; the predicates return #f and the service rejects writes — open
       ;; reads (get-tally, list-proposals) still work.
       (define governance-svc
         (with-vat planner-vat
           (let ((bs ($ meeting-scope 'ballot-store)))
             (spawn-governance-service
              ;; the federation universe for voice and credit is the STANDING
              ;; credit fold's UC root — every scope that crosses add-scope!,
              ;; summed keyed by citizen, refolded by its writers — where a
              ;; list of one founding scope stood. account.scm's global reads
              ;; take either end (credit-node?), so voice-share, the voice
              ;; snapshot and claim validation read the whole commons at once.
              ($ planner-service 'credit-uc) bs
              ;; founders are the bootstrap governors (can verify newcomers,
              ;; fan-out-capped). PLAYNET_TEST_OPEN_GOVERNANCE is a TEST-ONLY
              ;; affordance (never set in production): it makes any
              ;; authenticated AID a governor so an e2e can open a ballot to
              ;; then exercise the real signed cast + verify path (see
              ;; tests/ux/cast-ux.mjs). It gates only ballot open/close,
              ;; never the cast signature check.
              #:governor?  (let ((open-gov? (and (getenv "PLAYNET_TEST_OPEN_GOVERNANCE")
                                                 (not (string=? (getenv "PLAYNET_TEST_OPEN_GOVERNANCE") "0")))))
                             (lambda (aid) (or open-gov?
                                               (member aid %founders))))
              ;; scope-of: the commune named by an act → its ^scope, through
              ;; the scope graph (gateway-vat; the refs it holds live here in
              ;; planner-vat, so one lookup crosses a vat and every call on
              ;; the scope is near). Read lazily — the graph is hydrated
              ;; further down — and cached per AID; a commune the graph does
              ;; not hold answers #f and the act degrades as with no key.
              ;; scope-root-of: a commune's planner root, for per-scope voice
              ;; (voice-in) — planner-service lives in this vat, so the read is near
              #:scope-root-of
              (lambda (sid) (false-if-exception ($ planner-service 'scope-root-ref sid)))
              #:scope-of
              (let ((cache (make-hash-table)))
                (lambda (aid)
                  (or (hash-ref cache aid #f)
                      (let* ((g (current-scope-graph))
                             (ref (and g (catch #t
                                           (lambda () (in-graph-vat (lambda () ($ g 'find-ref aid))))
                                           (lambda _ #f))))
                             ;; called from inside a vat turn, the graph hop
                             ;; answers a PROMISE, not a ref — only a ref that
                             ;; answers a near call is one the doors can use
                             (live (and ref
                                        (false-if-exception
                                         (equal? aid ($ ref 'scope-aid)))
                                        ref)))
                        (when live (hash-set! cache aid live))
                        live))))
              ;; a carried KEY LOG lands here: verified as signup witnesses a
              ;; log (signup-agent verify-carried-kel), written straight into
              ;; the oobi-host dir both key resolvers read — so the voucher's
              ;; signature on a presented bundle verifies at once, from the
              ;; planner vat, with no actor in the way. kel-of is the read
              ;; twin: the log this gateway holds for an AID, wire-shaped,
              ;; for the bundle a person carries away.
              #:kel-landing
              (let ((oobi-dir (string-append %data-dir "/oobi-host")))
                (lambda (aid icp sigs rots)
                  (call-with-values
                      (lambda () (verify-carried-kel aid icp sigs rots
                                                     (read-oobi-entry-from-dir oobi-dir aid)))
                    (lambda (v entry)
                      (if (eq? v #t)
                          (begin (oobi-write-entry-to-dir! oobi-dir entry) #t)
                          v)))))
              #:kel-of
              (let ((oobi-dir (string-append %data-dir "/oobi-host")))
                (lambda (aid)
                  (let ((e (read-oobi-entry-from-dir oobi-dir aid)))
                    (and e
                         `(("icp" . ,(assq-ref e 'icp))
                           ("sigs" . ,(assq-ref e 'sigs))
                           ("rotations"
                            . ,(list->vector
                                (map (lambda (r) `(("rot" . ,(car r)) ("sigs" . ,(cdr r))))
                                     (or (assq-ref e 'rotations) '())))))))))
              ;; home-scope arrives LATER: the founding commune's ^scope is
              ;; minted/restored further down, and it — not meeting-scope,
              ;; which is a scope-root with no keys — is what signs
              ;; fp-grant/fp-vouch/ceremony credentials via sign-said.
              ;; set-home-scope! below, once fc-scope exists.
              #:acdc-store gov-acdc-store))))

       (log! "  [gateway] governance service ready~%")
       ;; the roots this gateway honours, as a growing set: its own UC, and
       ;; every peer's — one word to the governance service each time
       (define %fp-roots '())
       (define %fc-aid-live #f)          ; the founding commune's AID, once minted or restored
       (define (recognise-root! aid)
         (when (and (string? aid) (not (member aid %fp-roots)))
           (set! %fp-roots (cons aid %fp-roots))
           (with-vat planner-vat
             ($ governance-svc 'set-fp-root! (if (null? (cdr %fp-roots)) (car %fp-roots) %fp-roots)))
           (log! "  [gateway] FP roots: ~a~%" (length %fp-roots))))

       ;; ── Telegram backend (scope-handler exported via OCapN) ─────────
       ;; Spawns a ^scope-handler off meeting-scope so chat surfaces
       ;; Spawns a ^scope-handler off meeting-scope. The sink receives
       ;; all planner alerts via ^tee-alert-store — we pass it to
       ;; ^presence so alerts flow to the browser when a user connects.
       ;; Switch formatter from scope-alert (text) to notification
       ;; (serialized alist) so the browser adapter can extract
       ;; structured fields (type, title, body, tag).
       ;; push-store must precede push-adapter (it reads it) — keep the
       ;; subscription store defined before the adapter that spawns over it.
       (define push-store
         (with-vat gateway-vat
           (spawn ^push-subscription-store '())))

       (define push-adapter
         (with-vat gateway-vat
           (spawn ^push-adapter %vapid-key push-store)))

       (define (push-doorbell rendered)
         "Ring the doorbell — send a Web Push preview when alerts queue
          offline. The sink hands us a rendered notification (see
          notification-formatter); the push adapter puts it on the wire."
         (<-np push-adapter 'deliver #f rendered))

       (define-values (telegram-backend alert-sink)
         (with-vat planner-vat
           (let-values (((handler sink) (make-scope-handler meeting-scope
                                                            (spawn ^org-stub))))
             ;; The ONE render point for this channel: event alist -> a
             ;; rendered `terse' notification. Every downstream adapter
             ;; (browser transport + push doorbell) is dumb from here on.
             ($ sink 'set-formatter (notification-formatter 'terse))
             ($ sink 'set-doorbell push-doorbell)
             (values handler sink))))

       (log! "  [gateway] telegram-backend + alert-sink spawned~%")

       (define browser-adapter
         (with-vat gateway-vat (spawn ^browser-adapter)))

       (define presence-actor
         (with-vat gateway-vat
           (spawn ^presence (hashmap) alert-sink browser-adapter)))

       ;; ── Unified notification router (docs/notifications/UNIFIED-ROUTER.md)
       ;; The AID-keyed recipient registry (seeded by the lobby SESSION's
       ;; AID-aware announce/register-push) and the router over it. The
       ;; router renders per-channel and delivers via the dumb adapters.
       ;; The registry's durable channels (the addresses people confirmed)
       ;; are kept in one file: read at boot, written each time one is bound
       ;; or withdrawn. Withdrawing a channel rewrites the file without it.
       (define recipients-file (data-path "recipients.scm"))
       (define (keep-recipients! durable-table)
         (let ((tmp (string-append recipients-file ".tmp")))
           (call-with-output-file tmp
             (lambda (p) (write (recipient-table->datum durable-table) p) (newline p)))
           (rename-file tmp recipients-file)))
       (define recipient-registry
         (with-vat gateway-vat
           (spawn ^recipient-registry
                  (datum->recipient-table
                   (catch #t
                     (lambda () (if (file-exists? recipients-file)
                                    (call-with-input-file recipients-file read)
                                    '()))
                     (lambda _ '())))
                  keep-recipients!)))

       ;; Email is a channel of this commune when a mail handed to the adapter
       ;; goes somewhere: a relay the box names (PLAYNET_SMTP_HOST, with its
       ;; account's password to hand), a sendmail on the path, or
       ;; PLAYNET_MAIL_DIR (interface/adapters/email.scm).
       (define email-adapter
         (and (email-transport?) (with-vat gateway-vat (spawn ^email-adapter))))

       (define notify-router
         (with-vat gateway-vat
           (spawn ^notify-router recipient-registry
                  `((browser . ,browser-adapter)
                    (push    . ,push-adapter)
                    ,@(if email-adapter `((email . ,email-adapter)) '()))
                  '()
                  alert-sink)))   ; legacy sink = fallback for unbound recipients

       ;; The desk a presented contact point waits at while its code travels
       ;; to the address itself (identity/contact-points.scm). Its channels
       ;; are the durable kinds this commune delivers on.
       (define contact-desk
         (make-contact-point-desk
          (if email-adapter
              `((email . ,(lambda (ctx title body)
                            (<-np email-adapter 'deliver ctx
                                  (rendered-notification 'info title body "confirm-contact-point")))))
              '())))
       (log! "  [gateway] contact points: delivers on ~a~%" (contact-desk 'delivers))

       ;; Wire IPEX notification callback → router (per-recipient) → dumb
       ;; adapters. Events carry a 'recipient AID (the local user the event
       ;; is for); we route to that AID's bound channels. Events WITHOUT a
       ;; recipient (or before a session has seeded a browser binding) fall
       ;; back to the legacy presence → sink → browser path so nothing is
       ;; dropped during the browser-side cutover.
       (set-notification-callback!
        (lambda (event-alist)
          (let ((recipient (assq-ref event-alist 'recipient)))
            (if recipient
                ;; Per-recipient: router delivers to that AID's channels,
                ;; or falls back to the legacy sink if it has none bound.
                (<-np notify-router 'notify recipient event-alist)
                ;; No recipient AID on the event → legacy broadcast path.
                (<-np presence-actor 'notify-event event-alist)))))

       (define mailbox-store (make-syrup-store (data-path "mailbox.syrup")))
       (define-values (mailbox-vat mailbox-mgr)
         (spawn-persistent-vat
           mailbox-env
           (lambda () (spawn ^mailbox-manager (hashmap)))
           mailbox-store
           #:name "mailbox"
           #:persistence-registry persistence-registry))

       (define ai-svc
         (with-vat gateway-vat
           (spawn ^ai-service pool-vat key-pool)))

       ;; Corpus search (docs/planning/faces/corpus-guile-native.md phase 4) needs
       ;; guile-sqlite3 + onnxruntime — NOT yet in every deployment's own
       ;; manifest (a deploy/*.scm decision left to whoever runs this box,
       ;; not made here). Resolved defensively, so a box without them still
       ;; boots the whole gateway; the door in ^lobby already answers
       ;; "not configured" when corpus-svc is #f, the same shape as
       ;; ^ai-service's own no-keys? degrading to "" rather than refusing
       ;; to start.
       (define corpus-svc
         (catch #t
           (lambda ()
             (let ((m (resolve-module '(playnet gateway corpus-service) #:ensure #f)))
               (and m (with-vat gateway-vat (spawn (module-ref m '^corpus-service))))))
           (lambda (key . args)
             (log! "  [gateway] corpus search unavailable on this box (needs guile-sqlite3 + onnxruntime): ~a ~a~%" key args)
             #f)))

       (define terminal-svc
         (with-vat gateway-vat
           (spawn ^terminal-service signup-vat signup-agent gateway-vat)))

       ;; ── Wallet cap (from wallet-service) + fleet reconciler ───────
       ;; The wallet and policy actors live in a SEPARATE process
       ;; (wallet-service.scm on port 9092). boot-monero-actors!
       ;; resolves the sturdyref and spawns the reconciler.
       ;; Returns two values: (policy-cap reconciler).
       ;; The gateway has NO raw wallet reference — only the policy cap.
       (define-values (spend-policy fleet-reconciler)
         (boot-monero-actors!
          gateway-vat ocapn-vat mycapn
          #:data-dir %data-dir
          #:deploy-dir (or (getenv "PLAYNET_DEPLOY_DIR")
                           "/home/playnet/playnet-repo/deploy")
          ;; The account's home, where ssh itself looks — the service's
          ;; HOME is its data dir.
          #:ssh-key-file (or (getenv "PLAYNET_FLEET_SSH_PUBKEY")
                             (string-append
                              (passwd:dir (getpwuid (getuid)))
                              "/.ssh/id_ed25519.pub"))
          #:persistence-registry persistence-registry
          #:log! log!))

       ;; ── External assets on the individual-claimable rail ──────────
       ;; playnet.typ §Credits and external liquidity: XMR and fiat enter
       ;; the commons as ordinary resource specs priced by an ACQUISITION
       ;; recipe (crystallized SNLT = the labour the federation spends to
       ;; obtain one unit); citizens claim them against earned credit,
       ;; strictly one-directionally — the same claim path as bread.
       ;; The donation watch below keeps the XMR pool at the wallet's
       ;; unlocked balance.
       (define xmr-live-resource
         (catch #t
           (lambda ()
             (with-vat planner-vat
               (let ((live (bootstrap-monero-resource! meeting-scope)))
                 (bootstrap-external-asset! meeting-scope
                   #:spec-id "spec-eur" #:name "Euros" #:unit "EUR"
                   #:note "Euros — external fiat, claimable at the labour-cost of acquisition."
                   #:categories '("external/fiat")
                   ;; 20 h per €1000 (playnet.typ's worked example) = 0.02 h/EUR.
                   ;; INEXACT on purpose: this duration is persisted in the
                   ;; planner scope-root portrait, and syrup cannot encode an
                   ;; exact rational (1/50) — it raises "Unsupported Syrup type"
                   ;; and aborts the whole snapshot. Every other recipe duration
                   ;; is already a flonum (make-duration 0.25/0.5/… "hours").
                   #:acquisition-hours (exact->inexact 1/50))
                 live)))
           (lambda (key . args)
             (log! "  [gateway] external-asset bootstrap failed: ~a ~a~%" key args)
             #f)))
       (when xmr-live-resource
         (log! "  [gateway] external assets claimable: spec-xmr (20 h/XMR), spec-eur (0.02 h/EUR)~%"))
       ;; ── donation watch: the wallet's balance and what came in ────────
       ;; Every minute the XMR pool takes the wallet's unlocked balance, and
       ;; each new confirmed incoming transfer is recorded once as a donation
       ;; event (monero/poller.scm). A wallet that is down, or up later than
       ;; the gateway, is a logged tick and the next one asks again.
       (when (and xmr-live-resource spend-policy)
         (start-donation-watch! gateway-vat spend-policy meeting-scope
                                xmr-live-resource
                                (string-append %data-dir "/monero-donations.state")
                                #:interval-seconds 60 #:log! log!)
         (log! "  [gateway] donation watch on (1 min tick)~%"))

       ;; ── payout runner: members' "send N XMR to ⟨address⟩" intents ──
       ;; Every two minutes, each due payout in the commons scope goes
       ;; through the policy's invoice bracket and settles as a VF transfer
       ;; out of the member's claim (monero/payout.scm). Needs the policy
       ;; cap; without a wallet-service the intents simply wait.
       ;;
       ;; This is the one of the three XMR mechanisms that sends money to
       ;; someone other than the operator's own infrastructure — the
       ;; money-transmission / custody question docs/legal/operator.md §10 row 3
       ;; leaves open. Donation watch and the AI top-up below are the
       ;; operator receiving and spending its own funds and start with the
       ;; wallet regardless; this one is opt-in, default OFF, independent of
       ;; whether a wallet is live at all — set PLAYNET_PAYOUTS_ENABLED to a
       ;; value other than "0" once row 3 is actually settled.
       (when (and xmr-live-resource spend-policy (env-flag? "PLAYNET_PAYOUTS_ENABLED"))
         (start-payout-runner! gateway-vat planner-service spend-policy %fc-key gov-acdc-store
                               #:interval-seconds 120 #:log! log!)
         (log! "  [gateway] payout runner on (2 min tick)~%"))

       ;; ── top-up: the wallet keeps the AI accounts funded ─────────────
       ;; Every five minutes each key in the pool is asked what its account
       ;; holds; one under the floor gets a fresh deposit from the provider,
       ;; paid through the policy's invoice bracket (monero/topup.scm). The
       ;; address is the provider's answer of the moment, never kept.
       ;; TOPUP_FLOOR_USD / TOPUP_USD set the floor and the top-up.
       (when (and key-pool spend-policy)
         (let ((floor (string->number (or (getenv "TOPUP_FLOOR_USD") "")))
               (usd   (string->number (or (getenv "TOPUP_USD") ""))))
           (when (and floor usd) (set-topup-amounts! floor usd)))
         (start-topup! gateway-vat key-pool spend-policy
                       (string-append %data-dir "/topups")
                       #:interval-seconds 300 #:log! log!)
         (log! "  [gateway] account top-up on (5 min tick)~%"))

       ;; ── ^oobi-host (browser-resident-Signify ICP store) ─────────
       ;; Lives in gateway-vat so ^lobby's keri-authenticate handler
       ;; can call ($ oobi-host 'current-key …) synchronously when
       ;; resolving post-rotation signing keys. signup-agent (in
       ;; signup-vat) writes via async `(<- oobi-host 'put! …)`, so
       ;; the cross-vat boundary stays on the write path only.
       ;; Persistence is via a directory under %data-dir; on restart
       ;; oobi-host-spawn-from-dir replays the stored entries.
       (define oobi-host
         (let ((oobi-dir (string-append %data-dir "/oobi-host")))
           (unless (file-exists? oobi-dir) (mkdir oobi-dir))
           ;; The witness ceremony verifies a citizen's co-signature in the
           ;; PLANNER vat, where the oobi-host actor is unreachable — a
           ;; browser AID (E-prefix) resolves its current signing key through
           ;; the durable dir instead: a pure file read, callable mid-turn.
           (current-aid-key-resolver
            (lambda (aid) (oobi-current-key-from-dir oobi-dir aid)))
           ;; The keys that sign AS an AID, for every SAID/nonce verification
           ;; anywhere (citizen-sig verify-bytes-under-aid): its current KEL
           ;; key, and the device keys its root had authorized at the
           ;; statement's time (AT; #f = now) — both pure file reads,
           ;; vat-free. docs/planning/identity/device-keys.md.
           (device-registry-dir %data-dir)
           (aid-signer-keys-resolver
            (lambda (aid at)
              (let ((cur (oobi-current-key-from-dir oobi-dir aid)))
                (append (if (string? cur) (list cur) '())
                        (device-keys-at aid (or at (current-time)))))))
           (with-vat gateway-vat
             (oobi-host-spawn-from-dir oobi-dir))))

       ;; §4.6 / §4.1: Wire the oobi-host-mirror into the default
       ;; witness list so durable scopes auto-publish their KEL events
       ;; into /oobi/{aid}. Combined with the http-witness-publisher
       ;; spawned earlier, every durable scope gets local OOBI serving
       ;; AND cross-internet push for free. Opt-out via
       ;; PLAYNET_OOBI_AUTO_MIRROR=0.
       (when (and (getenv "PLAYNET_SCOPES_DURABLE")
                  (not (string=? (or (getenv "PLAYNET_OOBI_AUTO_MIRROR") "1")
                                 "0")))
         (catch #t
           (lambda ()
             (let ((oobi-mirror
                    (with-vat signup-vat
                      (spawn-oobi-host-mirror oobi-host))))
               (default-scope-witnesses
                 (cons oobi-mirror (default-scope-witnesses)))
               (log! "  [gateway] ^oobi-host-mirror added to default witnesses~%")
               ;; Every durable scope restored ABOVE (%restored-scopes) was
               ;; spawned before this mirror existed, so its default #:witnesses
               ;; was '() — the founding commune and the UC among them, restored
               ;; on every boot since before the mirror was ever added. Witness
               ;; each one now, the same door a newly-minted scope gets for
               ;; free: the mirror asks for nothing back, and a scope already
               ;; holding it as a subscriber (a boot after this fix) no-ops.
               (let ((n 0))
                 (for-each
                  (lambda (entry)
                    (catch #t
                      (lambda ()
                        (let* ((aid  (car entry))
                               (kind (or (read-scope-kind aid) 'commune)))
                          ;; Both the fetch AND the witness! call are `$`
                          ;; (same-vat sends) against the scope's own vat —
                          ;; the first version of this fix ran only the
                          ;; fetch inside with-vat and threw "No current
                          ;; syscaller" on witness! the moment it ran on
                          ;; the plain boot thread instead.
                          (with-vat (vat-for-scope-kind kind)
                            (let ((store ($ (cdr entry) 'kel-store)))
                              (when store
                                ($ store 'witness! oobi-mirror)
                                (set! n (+ n 1)))))))
                      (lambda (key . args)
                        (log! "  [gateway] witness-catchup error for ~a: ~a ~a~%"
                              (car entry) key args))))
                  %restored-scopes)
                 (when (> n 0)
                   (log! "  [gateway] ^oobi-host-mirror caught up on ~a restored scope(s)~%" n)))))
           (lambda (key . args)
             (log! "  [gateway] oobi-host-mirror error: ~a ~a~%" key args))))

       ;; ── Universal Commune + scope-graph + curator ──────────────────
       ;; The UC is the planning-time root above all federation roots.
       ;; Its members are *derived* from the orphan set of the current
       ;; scope-graph — no enrollment, no manual roster. The curator
       ;; reconciles the UC's membership against the graph on a
       ;; periodic tick.
       ;;
       ;; Boot sequence:
       ;;   1. Spawn ^scope-graph in gateway-vat; hydrate from the
       ;;      scopes recovered earlier (parents derived from each
       ;;      scope's federation-membership ACDCs).
       ;;   2. Set the (current-scope-graph) parameter so future
       ;;      admit-commune / remove-commune / spawn-scope calls
       ;;      fire reactive note-* hooks into it.
       ;;   3. Discover the UC: find-universal-commune-aid scans the
       ;;      on-disk kind files. If found, pluck the existing ref
       ;;      from %restored-scopes; else mint a fresh UC.
       ;;   4. Persist the UC AID to /var/lib/playnet/universal-commune-aid.txt
       ;;      for serve-static's /universal-commune.json endpoint.
       ;;   5. Mint a gov-cap and spawn ^uc-curator with its periodic
       ;;      tick thread.
       (define scope-graph #f)
       (define universal-commune-ref #f)
       (define uc-curator-ref #f)
       (when (and (getenv "PLAYNET_SCOPES_DURABLE")
                  (not (string=? (getenv "PLAYNET_SCOPES_DURABLE") "0")))
         (catch #t
           (lambda ()
             (set! scope-graph
                   (with-vat gateway-vat (spawn ^scope-graph)))
             ;; Hydrate the graph from disk: each restored scope's kind and
             ;; the parents its own membership credentials name. The edges
             ;; are read in the scope's own vat (a $ on its acdc-store from
             ;; another vat throws) before the graph's turn, so the tree
             ;; stands from the first turn after a restart exactly as the
             ;; admit-commune hooks built it before; the reparent sink below
             ;; replays these edges into the planner's aggregation tree.
             (define (restored-parents aid kind scope-ref)
               (catch #t
                 (lambda ()
                   (with-vat (vat-for-scope-kind kind)
                     (let ((store ($ scope-ref 'acdc-store)))
                       (if store
                           (delete-duplicates
                            (map car (federation-memberships-of-holder store aid)))
                           '()))))
                 (lambda (key . args)
                   (log! "  [scope-graph] parents of ~a unread (~a ~a); it hangs under the UC~%"
                         aid key args)
                   '())))
             (let ((parents-of
                    (map (lambda (entry)
                           (let* ((aid (car entry)) (kind (or (read-scope-kind aid) 'commune)))
                             (list aid kind (restored-parents aid kind (cdr entry)) (cdr entry))))
                         %restored-scopes)))
               (with-vat gateway-vat
                 (for-each
                  (lambda (row)
                    ;; #:ref keeps find-ref answering across restarts — the
                    ;; demand fold (socialized-plan-fn #:scope-of) and the
                    ;; IPEX grant handler both look restored scopes up here,
                    ;; and a hydration that records only the kind silently
                    ;; turns the fold off until the next fresh mint.
                    ($ scope-graph 'note-spawn (car row) (cadr row) (caddr row)
                       #:ref (cadddr row)))
                  parents-of))
               (log! "  [gateway] scope-graph hydrated: ~a scope(s), ~a with parents~%"
                     (length parents-of)
                     (length (filter (lambda (row) (pair? (caddr row))) parents-of))))
             ;; Bind the parameter for the rest of the process. New
             ;; scopes spawned after this point notify the graph via
             ;; the hooks in scope.scm.
             (current-scope-graph scope-graph)
             ;; …and the vat it lives in, so any thread can reach it through
             ;; the one door scope-graph.scm already provides (in-graph-vat).
             (current-graph-vat gateway-vat)
             ;; The aggregation tree follows the credential graph: every
             ;; membership edge the ACDC-backed note-* hooks record fires
             ;; the reparent sink, and the planner's move-scope! carries the
             ;; scope's folds and descents to the new parent (or the UC when
             ;; the parent set empties, or names a scope the planner does
             ;; not aggregate). A scope admitted into several federations
             ;; aggregates under ONE of them, chosen by aggregating-parent
             ;; (scope-graph.scm: the smallest AID), so every boot and every
             ;; edge order projects the same tree. Installing the sink
             ;; replays the hydrated edges through it. Fire-and-forget across
             ;; the vat boundary — the projection is idempotent and the next
             ;; edge corrects it.
             (with-vat gateway-vat
               ($ scope-graph 'set-on-reparent
                  (lambda (child parents)
                    (<-np planner-service 'move-scope! child
                          (aggregating-parent parents)))))
             ;; …and the recomposition-orchestration registry the
             ;; ratification post-admit hook fires into (task #43). The
             ;; hook reaches it through in-graph-vat, so it lives in the
             ;; graph's vat; the boot cell makes it readable from the
             ;; poll fiber the hook runs on.
             (current-pending-recompositions
              (with-vat gateway-vat (spawn-pending-recompositions)))
             ;; Discover/mint UC, mint curator gov-cap, write AID file,
             ;; spawn curator — all inside one with-vat turn so the $
             ;; calls have a syscaller (per the goblins gotcha:
             ;; "No current syscaller" raised by $ outside a vat).
             ;;
             ;; KERIA-aware AID minting: when keri-connect! succeeded
             ;; earlier (KERIA_BRAN was set + agent reachable), pass
             ;; the live keri-backend so the UC mints a REAL AID with
             ;; a real KEL. Otherwise fall back to the synthetic AID
             ;; the test path uses (E_universal_commune) so the rest
             ;; of the boot can still proceed in unconfigured envs.
             ;; Detection: try (live-keri-backend); if KERIA's not
             ;; up, the actual create-scope-aid call throws — caught
             ;; by the outer catch block and logged.
             (let* ((uc-aid-on-disk (find-universal-commune-aid))
                    (existing-ref   (and uc-aid-on-disk
                                         (assoc-ref %restored-scopes
                                                    uc-aid-on-disk))))
               (with-vat gateway-vat
                 (set! universal-commune-ref
                       (catch #t
                         (lambda ()
                           (spawn-universal-commune
                            #:scope-graph  scope-graph
                            #:existing-ref existing-ref
                            #:durable?     #t
                            #:keri-backend (live-keri-backend)))
                         (lambda (key . args)
                           (log! "  [gateway] live-keri-backend UC mint \
failed (~a ~a); falling back to synthetic~%" key args)
                           (spawn-universal-commune
                            #:scope-graph  scope-graph
                            #:existing-ref existing-ref
                            #:durable?     #t))))
                 (let ((uc-aid ($ universal-commune-ref 'scope-aid)))
                   (log! "  [gateway] universal-commune: ~a (~a)~%"
                         uc-aid (if existing-ref 'restored 'minted))
                   ;; Write the AID file that /universal-commune.json reads.
                   (let ((aid-file (data-path "universal-commune-aid.txt")))
                     (catch #t
                       (lambda ()
                         (call-with-output-file (string-append aid-file ".tmp")
                           (lambda (p) (display uc-aid p) (newline p)))
                         (rename-file (string-append aid-file ".tmp") aid-file)
                         (log! "  [gateway] wrote ~a~%" aid-file))
                       (lambda (key . args)
                         (log! "  [gateway] write UC aid-file failed: ~a ~a~%"
                               key args)))))
                 ;; Mint curator gov-cap (in-vat) + spawn curator.
                 (let ((gov-cap ($ universal-commune-ref
                                   'mint-gov-cap 'uc-curator)))
                   (set! uc-curator-ref
                         (spawn-uc-curator universal-commune-ref
                                           scope-graph
                                           gov-cap
                                           #:start-ticker? #t
                                           #:vat gateway-vat))
                   (log! "  [gateway] ^uc-curator running (interval ~as)~%"
                         (uc-curator-default-interval-sec)))))
             ;; ── Founding commune "Playnet" under the UC ──
             ;; The dial PLANS here (economic substrate = the scope-root); the
             ;; UC is the governance root above. Created in PLANNER-VAT — where
             ;; the economic root lives, so spawn-scope's $-access to it works.
             ;; Discover-or-mint + persist the AID, then register the root with
             ;; the planner BY scope-aid so scope-list shows a real commune,
             ;; never org:meeting. The uc-curator admits it to the UC via the
             ;; scope-graph hook spawn-scope fires (current-scope-graph is set).
             (let* ((fc-file (data-path "founding-commune-aid.txt"))
                    (fc-aid-on-disk
                     (catch #t
                       (lambda ()
                         (and (file-exists? fc-file)
                              (let ((s (call-with-input-file fc-file
                                         (lambda (p) (string-trim-both (read-line p))))))
                                (and (string? s) (not (string=? s "")) s))))
                       (lambda _ #f)))
                    (fc-existing (and fc-aid-on-disk
                                      (assoc-ref %restored-scopes fc-aid-on-disk))))
               (with-vat planner-vat
                 (let* ((minted
                         (and (not fc-existing)
                              (catch #t
                                (lambda ()
                                  (spawn-scope "Playnet" #:kind 'commune
                                               #:scope-root-ref meeting-scope
                                               #:durable? #t
                                               #:keri-backend (live-keri-backend)))
                                (lambda (k . a)
                                  (log! "  [gateway] founding commune live-keri mint \
failed (~a ~a); synthetic~%" k a)
                                  (catch #t
                                    (lambda ()
                                      (spawn-scope "Playnet" #:kind 'commune
                                                   #:scope-root-ref meeting-scope
                                                   #:durable? #t))
                                    (lambda (k2 . a2)
                                      (log! "  [gateway] founding commune mint failed: ~a ~a~%" k2 a2)
                                      #f))))))
                        (fc-aid (or fc-aid-on-disk (and minted ($ minted 'scope-aid)))))
                   (if (not fc-aid)
                       (log! "  [gateway] founding commune unavailable; dial has no scope~%")
                       (begin
                         (log! "  [gateway] founding commune Playnet: ~a (~a)~%"
                               fc-aid (if fc-existing 'restored 'minted))
                         (when minted
                           (catch #t
                             (lambda ()
                               (call-with-output-file (string-append fc-file ".tmp")
                                 (lambda (p) (display fc-aid p) (newline p)))
                               (rename-file (string-append fc-file ".tmp") fc-file))
                             (lambda (k . a)
                               (log! "  [gateway] write founding-commune aid-file failed: ~a ~a~%" k a))))
                         ;; key the founding commune in earth by its real AID (rekeys the
                         ;; first-boot %founding-key placeholder; a no-op on restart, where
                         ;; %fc-key already IS the aid). The planner reads earth for the
                         ;; roster, and add-scope! is the fold door: crossing it stands up
                         ;; the founding commune's labour/demand/means/folksonomy nodes and
                         ;; descent leaves like every other scope's (earth's add-commune!
                         ;; is an idempotent re-key underneath).
                         ($ earth 'rekey-commune! %fc-key fc-aid)
                         ;; the solve queue lands on this vat: from here on every
                         ;; solve runs on a thread of its own and the vat serves
                         ;; every read while it runs (service.scm plan-fn*)
                         ($ planner-service 'set-solve-vat! planner-vat)
                         ($ planner-service 'add-scope! fc-aid meeting-scope)
                         (log! "  [gateway] dial scope -> Playnet (~a)~%" fc-aid)
                         ;; the founding commune's ^scope is the governance
                         ;; service's home: its sign-said is what stamps
                         ;; fp-grant/fp-vouch/ceremony credentials.
                         (let ((fc-scope (or minted fc-existing)))
                           (when fc-scope
                             ($ governance-svc 'set-home-scope! fc-scope)
                             (log! "  [gateway] governance home-scope -> founding commune~%")))
                         ;; the commune on the wire (gateway/federate.scm): a
                         ;; peer of the federated solve, when the data directory
                         ;; holds federation.scm — the commune's demand, and the
                         ;; federation it answers to: `federation` its AID with
                         ;; `desk` the sturdyref it answers at (the spec is asked
                         ;; of the federation itself), `federation` alone for one
                         ;; this gateway holds (its store answers), or the spec
                         ;; written out (issuer, goods, roster, credentials, tell)
                         (let* ((fc-scope (or minted fc-existing))
                                (spec (read-kept (data-path "federation.scm")))
                                (state-dir (data-path "federation"))
                                (say (lambda (m) (log! "  [gateway] federation ~a~%" m))))
                           ;; who signs on the wire: the scope, through its own
                           ;; key; PLAYNET_FED_SEED (a byte) stands in for a scope
                           ;; without one — the synthetic backend, a dev run
                           (define signer
                             (delay
                               (cond ((and fc-scope ($ fc-scope 'has-keypair?)) (scope-signer fc-aid fc-scope))
                                     ((getenv "PLAYNET_FED_SEED")
                                      => (lambda (b)
                                           (log! "  [gateway] federation peer signs under a DEV identity (PLAYNET_FED_SEED)~%")
                                           (make-keri-identity (make-bytevector 32 (string->number b)))))
                                     (else (error "the founding commune has no key to sign on the wire with")))))
                           (define (federation-signer) (force signer))
                           ;; the founding commune's berth: its peer's sturdyref
                           ;; stands from the first boot, before any spec, kept
                           ;; with the AID it speaks under — what a federation
                           ;; admits it with
                           (on (berth-sturdyref ws-netlayer (berth-swiss! state-dir))
                               (lambda (s)
                                 (let ((aid (false-if-exception (signer-aid (signer-of (federation-signer))))))
                                   (keep! (data-path "federation-sref.txt") (list s aid))
                                   (log! "  [gateway] federation berth at ~a, speaking as ~a (handshake ~a)~%"
                                         s aid (wire-handshake)))))
                           ;; the goods that cross for this commune, by the AID it
                           ;; speaks under: the one the federation admitted
                           (define (record-of from)
                             (let ((rec ($ planner-service 'scope-record fc-aid
                                          (spec-goods from (signer-aid (signer-of (federation-signer))))
                                          (assq-ref spec 'demand))))
                               (unless (eq? (car rec) 'ok) (error "scope-record" (cdr rec)))
                               (cdr rec)))
                           ;; what this commune deals in, read off its records
                           (define (census)
                             (let ((c ($ planner-service 'census fc-aid (assq-ref spec 'demand))))
                               (and (eq? (car c) 'ok) (cdr c))))
                           ;; the unit a good crosses in: its specification's own, off the commune's
                           ;; recipe store
                           (define (crossing-unit good)
                             (or (false-if-exception
                                  (let* ((root ($ planner-service 'scope-root-ref fc-aid))
                                         (sp ($ ($ root 'recipe-store) 'get-resource-spec good)))
                                    (and sp (resource-specification-default-unit-of-resource sp))))
                                 "kg"))
                           (define (failed k . a) (log! "  [gateway] federation peer failed: ~a ~a~%" k a))
                           (define (boot! spec)
                             (catch #t
                               (lambda ()
                                 (on (federation-boot! record-of (federation-signer) mycapn ws-netlayer
                                                       state-dir spec #:log say
                                                       #:census (census)
                                                       ;; a crossing that settles leaves its record in
                                                       ;; this gateway's store, signed through the scope
                                                       #:custody (list (cons 'store gov-acdc-store)
                                                                       (cons 'scope (and fc-scope ($ fc-scope 'has-keypair?) fc-scope))
                                                                       (cons 'unit-of crossing-unit)))
                                     (lambda (fed)
                                       (on (assq-ref fed 'sturdyref)
                                           (lambda (s) (log! "  [gateway] federation peer at ~a~%" s)))
                                       (on (assq-ref fed 'joined)
                                           (lambda (joined)
                                             (log! "  [gateway] federation peer started, ~a of ~a ends joined~%"
                                                   (length joined) (length (assq-ref fed 'ends))))))
                                     #:catch (lambda (e) (failed 'boot e))))
                               failed))
                           (when (and fc-scope spec)
                             (let ((fed-aid (assq-ref spec 'federation)) (g (current-scope-graph)))
                               (if (and fed-aid g (not (assq-ref spec 'desk)))
                                   ;; a federation in this graph: the census is told to
                                   ;; its scope directly, and its spec read off its store
                                   (let ((fed-ref (<- g 'find-ref fed-aid)))
                                     (on (if (census)
                                             (<- fed-ref 'accept-census
                                                 (census-credential (federation-signer) fed-aid (census) (told-at-now)
                                                                    #:units (map (lambda (g) (cons g (crossing-unit g))) (census))))
                                             #t)
                                         (lambda (_)
                                           (on (<- fed-ref 'federation-spec)
                                               (lambda (from-store) (boot! (append spec from-store)))
                                               #:catch (lambda (e) (log! "  [gateway] federation ~a answers no spec: ~a~%" fed-aid e))))
                                         #:catch (lambda (e) (log! "  [gateway] federation ~a takes no census: ~a~%" fed-aid e))))
                                   (boot! spec)))))
                         (set! %fc-aid-live fc-aid)
                         ;; every open enrollment ask comes back from its
                         ;; record — with the vouches already gathered — now
                         ;; that the scope that signs its outcome stands
                         (let ((back (cdr ($ governance-svc 'fp-rehydrate!))))
                           (when (pair? back)
                             (log! "  [gateway] ~a enrollment ask(s) restored~%" (length back))))
                         ;; operator bootstrap: PLAYNET_FOUNDERS=aid1,aid2 each
                         ;; receive a founder PHC in this commune, starting the
                         ;; trust graph + activating the personhood gate.
                         (for-each
                          (lambda (faid)
                            ;; idempotent: one founder PHC per AID, not a new one
                            ;; (fresh timestamp → fresh SAID) on every boot.
                            (when (and (> (string-length faid) 0)
                                       (not (holds-any-live-phc? gov-acdc-store faid)))
                              (catch #t
                                (lambda ()
                                  ;; The founder PHC is the root of the trust
                                  ;; graph and the credential the personhood
                                  ;; gate reads, so it carries the founding
                                  ;; commune's signature. The scope signs it
                                  ;; through its own sign-said — the key stays
                                  ;; in the actor, and the issuer here IS
                                  ;; fc-aid, so the signature binds. The
                                  ;; signature is added after the SAID is
                                  ;; computed, so the idempotency above still
                                  ;; sees one PHC per founder.
                                  (let ((fc-scope (or minted fc-existing)))
                                    ($ gov-acdc-store 'issue
                                       (cred-signed-by-scope
                                        (make-personhood-credential
                                         fc-aid faid (current-time)
                                         #:enrollment-evidence-digest "founder")
                                        fc-scope))
                                    (log! "  [gateway] seeded founder PHC: ~a (~a)~%"
                                          faid
                                          (if fc-scope "signed" "unsigned — no scope key"))))
                                (lambda (k . a)
                                  (log! "  [gateway] founder seed failed (~a): ~a ~a~%"
                                        faid k a)))))
                          %founders))))
                 ;; ── Berlin/Brandenburg commune under the UC — a REAL ecoregional scope ──
                 ;; A live commune placed in the registered "berlin" bioregion (live.scm
                 ;; boot-loads the shed), so its plan inherits the region's real drought
                 ;; futures + water/soil limits by containment — no per-commune wiring.
                 ;; Seeded UNCONDITIONALLY (not demo-gated) so it is live in prod. Synthetic
                 ;; deterministic AID (E_commune_Berlin) → idempotent across boots; the
                 ;; uc-curator auto-adopts it via the scope-graph orphan hook spawn-scope
                 ;; fires (current-scope-graph is set). This is the exact founding-commune
                 ;; path (spawn-scope-root + spawn-scope + seed + add-scope!), with a real
                 ;; ecoregion seeded into its stores.
                 ;; DURABILITY: the scope-root re-seeds deterministically each boot (same
                 ;; AID, same farm), so Berlin reliably returns identical across reboots;
                 ;; and socialization GRANTS to it are durable independently — a custody
                 ;; ACDC in the durable gov-acdc-store keyed by this stable AID, so a
                 ;; re-seed re-discovers them (test-berlin-live-scope's sibling checks).
                 ;; The scope-root NAME drives the dial's commune-switcher label; the AID
                 ;; stays the clean deterministic E_commune_Berlin (no slash).
                 (catch #t
                   (lambda ()
                     (let* ((broot ($ earth 'ensure-commune! "E_commune_Berlin" "Berlin/Brandenburg" %law-packs))  ; durable under earth
                            (bc    (spawn-scope "Berlin" #:kind 'commune #:scope-root-ref broot))
                            (b-aid ($ bc 'scope-aid)))
                       ;; seed the farm ONCE — a restored/durable root already carries it
                       (when (null? ($ ($ broot 'observer) 'all-resources))
                         (seed-berlin-commune! broot))
                       ;; the farm's land and water reach tomorrow: the hold
                       ;; door, idempotent — a durable root seeded before
                       ;; holds existed gains them on this boot
                       (seed-farm-holds! broot "berlin-commune-farm")
                       ;; …and the FOOD FESTIVAL arm (its own once-guard). Its
                       ;; crowd terms carry a rolling window, so the arm also
                       ;; registers on the planner tick's re-stand door: the
                       ;; day the window ages out, the next resolve-stale!
                       ;; re-lays it and the solve behind it rolls the
                       ;; schedule forward.
                       ($ planner-service 're-stand!
                          (lambda () (seed-berlin-festival-arm! broot)))
                       ;; the twelve Bezirke's pits, growing as gardening WORK the
                       ;; willingness rail runs over, and the crowd's standing
                       ;; terms — a floor held in every branch + the want above
                       (seed-berlin-festival-arm! broot)
                       ;; the festival's futures: the shed's weather crossed
                       ;; with the districts' own shade rides the "berlin"
                       ;; bioregion, so the commune inherits it by containment.
                       ;; Permission is a wall, not a future: the crowd's floor
                       ;; is a right held against ANY ONE district lost
                       ;; (`against:1`, the budgeted wall), which is what
                       ;; spreads the planting across the districts
                       (attach-festival-futures!)
                       ;; key earth by the real governance AID (a no-op when the synthetic
                       ;; AID matches; corrects earth if it ever drifts). The planner reads
                       ;; earth — this is the sole registration.
                       ($ earth 'rekey-commune! "E_commune_Berlin" b-aid)
                       (log! "  [gateway] Berlin/Brandenburg commune under UC: ~a~%" b-aid)))
                   (lambda (k . a)
                     (log! "  [gateway] Berlin commune seed failed: ~a ~a~%" k a)))
                 ;; ── Bay Area subscopes: SF + Oakland market-garden communes under earth ──
                 ;; Durable communes placed in the registered "bay-area" bioregion (each
                 ;; city ⊂ bay-area), so they inherit California's Mediterranean drought
                 ;; futures + its EXTREME water limit by containment. Same durable path as
                 ;; Berlin: earth-held root, seeded once, deterministic AID. Nested scopes.
                 (for-each
                  (lambda (spec)
                    (catch #t
                      (lambda ()
                        (let* ((aid    (list-ref spec 0)) (spawn-nm (list-ref spec 1))
                               (nm     (list-ref spec 2)) (city (list-ref spec 3))
                               (place  (list-ref spec 4))
                               (broot  ($ earth 'ensure-commune! aid nm %law-packs))              ; durable under earth
                               (sc     (spawn-scope spawn-nm #:kind 'commune #:scope-root-ref broot))
                               (sc-aid ($ sc 'scope-aid)))
                          (when (null? ($ ($ broot 'observer) 'all-resources))         ; seed once
                            (seed-bay-area-commune! broot #:place place #:city city #:city-name nm))
                          (seed-farm-holds! broot place)   ; durable roots gain their holds
                          ($ earth 'rekey-commune! aid sc-aid)   ; earth keyed by the real AID
                          (log! "  [gateway] Bay Area commune ~a under UC: ~a~%" nm sc-aid)))
                      (lambda (k . a)
                        (log! "  [gateway] Bay Area commune seed failed: ~a ~a~%" k a))))
                  (list (list "E_commune_SF"      "SF"      "San Francisco" "san-francisco" "sf-garden")
                        (list "E_commune_Oakland" "Oakland" "Oakland"       "oakland"       "oak-garden")))
                 ;; ── playnet development, as a commune under earth ──────────────
                 ;; Real, not demo-gated, same durable path as Berlin/Bay Area:
                 ;; a synthetic deterministic AID, earth-held, one persistence
                 ;; graph (earth.scm's own "no per-commune store files").
                 ;; Deliberately stops at ensure-commune! — no spawn-scope /
                 ;; rekey-commune! / seed-farm-holds! the way Berlin/Bay Area
                 ;; continue: this is internal tooling, not a KERI-governed
                 ;; community, and Berlin/Bay Area's own synthetic-AID
                 ;; precedent already establishes a commune needs neither a
                 ;; minted governance scope-aid nor network reachability to
                 ;; be real and planned-over (a future addition, never a
                 ;; blocker — see the dev-commune plan's own out-of-scope
                 ;; note). An open Radicle issue is a want, its `area:` a skill
                 ;; (knowledge/skills/dev-skills.scm), the scope's people
                 ;; docs/dev-scope.sexp states — module/playnet/planner/
                 ;; bridge/dev-plan.scm's own plan-dev-week runs over exactly
                 ;; this commune, reached by tools/{dev-plan,dev-signal-cycle,
                 ;; dev-loop-close}.scm through the REPL socket below (so a
                 ;; booked hour lands as a REAL VF event this gateway's own
                 ;; account.scm/skill-law.scm already read — the whole point).
                 ;;
                 ;; `rad`/network I/O at boot, wrapped: a Radicle-unreachable
                 ;; boot never blocks the gateway. The tools' own runs reseed
                 ;; on their own schedule regardless — this is only so the
                 ;; commune is not EMPTY between them.
                 (catch #t
                   (lambda ()
                     (let* ((droot ($ earth 'ensure-commune! "E_commune_devwork" "playnet development" %law-packs)))
                       (when (null? ($ ($ droot 'observer) 'all-resources))
                         (let ((facts  (false-if-exception (issues->facts (rad-issue-pairs))))
                               (people (read-dev-people (or (getenv "DEV_SCOPE_PATH") "docs/dev-scope.sexp"))))
                           (seed-dev-scope! droot (or facts '()) people)))
                       (module-define! (resolve-module '(guile-user)) 'dev-commune droot)
                       (log! "  [gateway] playnet development commune under earth: E_commune_devwork~%")))
                   (lambda (k . a)
                     (log! "  [gateway] dev commune seed failed: ~a ~a~%" k a)))
                 ;; Demo-only 2nd commune so the dial's commune switcher is
                 ;; exercisable in dev; prod registers real UC-subtree communes
                 ;; the same way (spawn-scope + add-scope!). It plans over the
                 ;; bread town — the grow→mill→bake economy the live planner
                 ;; suites share ((playnet test planner bread)), seeded off the
                 ;; same record lists by seed-bread-commune!, so what the suite
                 ;; proves is what the switcher lands on.
                 (when %seed-demo?
                   (catch #t
                     (lambda ()
                       (let* ((root2 (spawn-scope-root "Bread town" #:law-packs %law-packs))
                              (c2    (spawn-scope "Bread town" #:kind 'commune
                                                  #:scope-root-ref root2))
                              (c2-aid ($ c2 'scope-aid)))
                         (seed-bread-commune! root2)
                         ($ planner-service 'add-scope! c2-aid root2)
                         (log! "  [gateway] demo 2nd commune Bread town: ~a~%" c2-aid)))
                     (lambda (k . a)
                       (log! "  [gateway] demo 2nd commune failed: ~a ~a~%" k a))))))
             ;; First-Person: the UC subtree's commune AIDs are the issuers
             ;; whose PHCs we honour when a holder PRESENTS one from another
             ;; gateway (slice-2 trust anchor).
             ;; A counter's picture, attached to the contest of their count, is
             ;; held only for the ballot's life: when it settles, it is let go.
             (with-vat planner-vat
               ($ governance-svc 'set-contest-settled!
                  release-contest-evidence!))
             (with-vat planner-vat
               (let ((aids (map (lambda (s) (assq-ref s 'id))
                                ($ planner-service 'scope-list))))
                 ($ governance-svc 'set-fp-trusted-issuers! aids)
                 (log! "  [gateway] FP trusted issuers: ~a commune(s)~%"
                       (length aids))))
             ;; First-Person: the Universal Commune is the trust-registry
             ;; ROOT — an ecosystem is a legitimate PHC issuer iff it chains
             ;; to it (holds a live authorized-issuer credential). The
             ;; whitelist above stays as a fallback for pre-root flows.
             ;; the UC this gateway minted or restored IS the one it federates
             ;; with — unless the operator named another (PLAYNET_UC_AID)
             (when (and universal-commune-ref (not (known-uc-aid)))
               (set-known-uc-aid! (with-vat gateway-vat ($ universal-commune-ref 'scope-aid))))
             (when (known-uc-aid)
               (recognise-root! (known-uc-aid))
               (log! "  [gateway] FP trust-registry root = UC ~a~%"
                     (known-uc-aid)))
             ;; the root's blessing of its founding commune — the
             ;; authorized-issuer credential a personhood issued here chains
             ;; through, held in the store every presentation reads, signed
             ;; by the UC's own key. Once: a standing live blessing stands.
             (when (and universal-commune-ref %fc-aid-live)
               (catch #t
                 (lambda ()
                   (let* ((uc-aid (known-uc-aid))
                          (fc-aid %fc-aid-live)
                          (standing
                           (with-vat planner-vat
                             (find (lambda (c) (and (equal? uc-aid (cred-issuer c))
                                                    (equal? fc-aid (cred-holder c))
                                                    (cred-live? c)))
                                   ($ gov-acdc-store 'by-schema *schema-playnet-authorized-issuer*)))))
                     (unless standing
                       (let* ((aic (make-authorized-issuer-credential uc-aid fc-aid (current-time)))
                              (sig (with-vat gateway-vat
                                     ($ universal-commune-ref 'sign-said (cred-said aic)))))
                         (with-vat planner-vat
                           ($ gov-acdc-store 'issue (cred-with-signature aic sig)))
                         (log! "  [gateway] UC blesses the founding commune as an issuer~%")))))
                 (lambda (k . a)
                   (log! "  [gateway] founding-commune blessing skipped: ~a ~a~%" k a))))
             ;; Retire the flat whitelist once the live root chain is
             ;; populated: PLAYNET_FP_STRICT_ROOT=1 makes trust derive ONLY
             ;; from chaining to root (see deployment.md Step 6).
             (when (member (getenv "PLAYNET_FP_STRICT_ROOT") '("1" "true" "yes"))
               (with-vat planner-vat
                 ($ governance-svc 'set-fp-strict-root! #t))
               (log! "  [gateway] FP strict-root ON — whitelist retired~%"))

             ;; Cross-gateway scope ingest: ^remote-scope-poller fetches
             ;; /scopes from each PLAYNET_PEERS gateway and feeds new
             ;; scope-graph entries. With peers empty the actor still
             ;; spawns but no-ops on tick — safe default.
             (let ((peers (parse-peers-env))
                   ;; In planner-vat (with governance-svc) so the governance
                   ;; surface can read `pending` synchronously; the poller's
                   ;; callback records into it across the vat via <-np.
                   (uc-merge-proposals (with-vat planner-vat
                                         (spawn-uc-merge-proposals))))
               ;; Surface UC merge proposals in the governance panel
               ;; (scope-formation decisions).
               (with-vat planner-vat
                 ($ governance-svc 'set-uc-proposals! uc-merge-proposals))
               (with-vat gateway-vat
                 (spawn-remote-scope-poller
                  scope-graph
                  #:peers peers
                  #:start-ticker? #t
                  ;; One-UC-as-gravity: when a peer reports its own Universal
                  ;; Commune, reconcile toward unity BY CONSENT — RECORD a
                  ;; merge proposal on a genuine collision (drained + ratified
                  ;; by UC governance → merge-bottom-up!), no-op if it's
                  ;; identical or already lineally unified with ours.
                  #:on-peer-uc
                  (lambda (peer-uc-aid)
                    ;; a PEER is the operator's word that another graph is
                    ;; ours to recognise: its Universal Commune joins the
                    ;; roots this gateway honours — multi-root
                    ;; cross-recognition, so a personhood chaining to a
                    ;; peer's root is a person here, and a bundle carrying
                    ;; that root's blessing is checkable here
                    (recognise-root! peer-uc-aid)
                    (when universal-commune-ref
                      (let* ((my-uc  (known-uc-aid))
                             (store  ($ universal-commune-ref 'acdc-store))
                             (action (uc-reconcile-action store my-uc peer-uc-aid)))
                        (when (eq? (car action) 'propose-merge)
                          ;; cross-vat: fire-and-forget (dedup is in the registry)
                          (<-np uc-merge-proposals 'propose my-uc peer-uc-aid)
                          (log! "  [gateway] UC collision: peer ~a ≠ ours ~a — merge proposed for ratification~%"
                                peer-uc-aid my-uc)))))
                  #:vat gateway-vat))
               (log! "  [gateway] ^remote-scope-poller running (~a peer(s))~%"
                     (length peers))))
           (lambda (key . args)
             (log! "  [gateway] UC bootstrap failed: ~a ~a~%" key args)))

         ;; The demand fold reads the service's STANDING nodes now
         ;; (standing-demand-node-of, wired at add-scope!) — exact on every
         ;; declared need, no sweep, nothing one tick behind. The scope graph
         ;; remains the governance truth; a solve for an aid outside the
         ;; planner roster never reached plan-fn anyway (with-scope refuses
         ;; first), so nothing here mirrors it any more.
         )

       (define vapid-pub-b64
         (b64url-encode (vapid-public-key-bytes %vapid-key)))

       ;; ── Folksonomy aggregator ───────────────────────────────────────
       ;; The service's UC folksonomy root — the fifth fold through the
       ;; add-scope! door, so per-scope nodes stand under it and move-scope!
       ;; carries taxonomy like every other aggregate. The lobby's
       ;; `sync-taxonomy` contributes each AID's published cut here and
       ;; `template` answers the commons' spine (using is voting).
       (define folksonomy-actor
         (with-vat planner-vat ($ planner-service 'folksonomy-uc)))
       ;; a restart empties the fold; the stored cuts refill it at once
       (with-vat gateway-vat (seed-taxonomy-docs! folksonomy-actor))

       ;; Seed the folksonomy with a first cut from the scope's own
       ;; classifications (folksonomy/seed.scm): specs' resource-classified-as
       ;; → flat terms + edges, contributed as the commons' starting spine.
       (with-vat planner-vat (seed-folksonomy! folksonomy-actor meeting-scope))
       ;; the pin book beside it: citizens' SHARED map lists, folded the same
       ;; way (folksonomy/pins.scm) — one book for the commons
       (define pins-actor
         (with-vat planner-vat (spawn ^pins (make-pins) '() "uc")))
       ;; a restart empties the fold; the stored books refill it at once
       (with-vat gateway-vat (seed-pins! pins-actor))

       ;; The servers a call finds its peers through: PLAYNET_ICE_URLS
       ;; (comma-separated; set it empty for none), else the lobby's default.
       ;; The browser asks the lobby's `ice-servers` door and holds no list.
       (define ice-list
         (ice-servers-from-urls (or (getenv "PLAYNET_ICE_URLS") %default-ice-urls)))

       (define lobby
         (with-vat gateway-vat
           (spawn ^lobby signup-agent ai-svc
                  presence-actor terminal-svc mailbox-mgr
                  planner-service spend-policy governance-svc
                  oobi-host gov-acdc-store
                  push-store vapid-pub-b64
                  folksonomy-actor recipient-registry
                  corpus-svc pins-actor
                  ice-list contact-desk)))

       ;; ── Direct Goblins signal: publisher → reconciler (NOT WIRED) ────
       ;; Intended: the planner's signal-publisher would call the fleet-
       ;; reconciler directly for spec-infra-* deficit signals, skipping
       ;; MQTT entirely (the money flow deficit signal → XMR spend → VM
       ;; provisioning, purely within the capability model).
       ;;
       ;; Never built: ^scope has no `signal-publisher` method, and
       ;; nothing anywhere spawns a (playnet planner bridge signal-
       ;; publisher) actor to attach one — verified by repo-wide grep,
       ;; 2026-08-19. This whole feature's real trigger path is
       ;; server/fleet-bridge.scm, a separate process that subscribes to
       ;; MQTT `playnet/signals/deficit/#` and pokes the reconciler over
       ;; a sturdyref — that path is independent of this block and
       ;; unaffected by it being unimplemented. Left un-attempted rather
       ;; than a call that can only ever throw: this used to print a full
       ;; Goblins backtrace on every single boot for a feature that
       ;; cannot exist yet.
       ;;
       ;; To finish this: give ^scope a signal-publisher accessor
       ;; returning a real (spawn ^signal-publisher publish-fn scope-id)
       ;; instance, spawned wherever meeting-scope's publish-fn is first
       ;; defined.

       ;; ── Gateway-internal REPL ───────────────────────────────────
       ;; Exposes gateway-local bindings (fleet-reconciler, gateway-vat,
       ;; spend-policy) so operators can reach them via repl-eval.
       (let ((gu (resolve-module '(guile-user))))
         (module-define! gu 'gateway-vat      gateway-vat)
         (module-define! gu 'fleet-reconciler  fleet-reconciler)
         ;; NO monero-wallet binding — that's the whole point of
         ;; process isolation. Only spend-policy (the OCapN cap) is here.
         (module-define! gu 'spend-policy      spend-policy)
         (module-define! gu 'lobby             lobby)
         (module-define! gu 'planner-service   planner-service)
         (module-define! gu 'meeting-scope     meeting-scope)
         ;; dev-commune lives here too — bound earlier, at registration
         ;; (module-define! ... 'dev-commune droot), alongside
         ;; planner-vat itself: every $ call on dev-commune from the REPL
         ;; needs (with-vat planner-vat ...), same as every other
         ;; economic commune above.
         (module-define! gu 'planner-vat       planner-vat))

       (let* ((repl-sock-dir (or (and=> (getenv "XDG_RUNTIME_DIR")
                                        (lambda (d) (string-append d "/playnet")))
                                 "/var/run/playnet"))
              (gateway-repl-sock (string-append repl-sock-dir "/gateway-repl.sock")))
         ;; Ensure the parent dir exists. On the host this is created
         ;; by tmpfiles; in containers we have to make it ourselves.
         (let loop ((path repl-sock-dir))
           (unless (file-exists? path)
             (loop (dirname path))
             (catch #t (lambda () (mkdir path)) (lambda _ #f))))
         (when (file-exists? gateway-repl-sock)
           (delete-file gateway-repl-sock))
         ;; Bind synchronously, lock down, then hand off to a serving
         ;; thread. The previous order raced: chmod could run before
         ;; the new thread had finished creating the socket file.
         (let ((sock (make-unix-domain-server-socket #:path gateway-repl-sock)))
           (chmod gateway-repl-sock #o600)
           (call-with-new-thread (lambda () (run-server sock))))
         (log! "  [gateway] REPL listening on ~a (mode 0600)~%" gateway-repl-sock))

       ;; Register lobby with OCapN — get sturdyref
       (with-vat ocapn-vat
         (on (<- mycapn 'register lobby 'websocket)
             (lambda (sref)
               (let ((uri (ocapn-id->string sref)))
                 (log!
                         "~%  playnet OCapN gateway on ws://~a:~a~%"
                         ws-host ws-port)
                 (log!
                         "  sturdyref: ~a~%~%" uri)
                 ;; Write to file for browser / other clients
                 (catch #t
                   (lambda ()
                     (call-with-output-file (data-path "gateway-sref.txt")
                       (lambda (p) (display uri p) (newline p))))
                   (lambda args
                     (log!
                             "  warning: could not write sref file: ~a~%"
                             args)))))))

       ;; The HTTP door (module/playnet/gateway/http-door.scm): the same doors
       ;; over POST /api/<object>/<name>, signed by an enrolled device key,
       ;; on loopback — nginx proxies the three /api/ prefixes here. A
       ;; person's HTTP session is the device-tier ^lobby-session
       ;; keri-authenticate-device would spawn, kept warm per person.
       (start-http-door!
        #:port (string->number (or (getenv "PLAYNET_API_PORT") "9091"))
        #:lobby lobby
        #:vat gateway-vat
        #:log log!
        #:spawn-session
        (lambda (person-aid)
          (spawn ^lobby-session person-aid
                 terminal-svc mailbox-mgr governance-svc signup-agent
                 oobi-host gov-acdc-store folksonomy-actor presence-actor
                 push-store recipient-registry planner-service
                 'device pins-actor #f #f contact-desk)))

       ;; Register telegram-backend with OCapN — bridge enlivens this sref
       (with-vat ocapn-vat
         (on (<- mycapn 'register telegram-backend 'websocket)
             (lambda (sref)
               (let ((uri (ocapn-id->string sref)))
                 (log! "  telegram-backend sturdyref: ~a~%" uri)
                 (catch #t
                   (lambda ()
                     (call-with-output-file (data-path "telegram-backend-sref.txt")
                       (lambda (p) (display uri p) (newline p))))
                   (lambda args
                     (log! "  warning: could not write telegram-backend sref: ~a~%"
                           args)))))))

       ;; Register lobby with Reticulum transport when enabled.
       ;; Named so the netlayer retry fiber can perform it too when the
       ;; bridge only becomes reachable after boot (soft-degrade path).
       (define (register-lobby-on-mesh!)
         (with-vat ocapn-vat
           (on (<- mycapn 'register lobby 'reticulum)
               (lambda (ret-sref)
                 (let* ((ret-uri (ocapn-id->string ret-sref))
                        ;; Extract destination hash from ocapn://<hash>.reticulum/...
                        ;; string-split on #\/ gives ("ocapn:" "" "<hash>.reticulum" ...)
                        (dest-hash
                         (let ((authority (caddr (string-split ret-uri #\/))))
                           (car (string-split authority #\.)))))
                   (log! "  reticulum sturdyref: ~a~%" ret-uri)
                   (log! "  reticulum destination hash: ~a~%~%" dest-hash)
                   ;; Write reticulum sref alongside websocket one
                   (catch #t
                     (lambda ()
                       (call-with-output-file (data-path "gateway-ret-sref.txt")
                         (lambda (p) (display ret-uri p) (newline p))))
                     (lambda args
                       (log! "  warning: could not write reticulum sref file: ~a~%"
                             args))))))))

       ;; Immediate path: netlayer was wired during boot, register now.
       ;; (Deferred path: the retry fiber calls register-lobby-on-mesh!
       ;; itself once the bridge becomes reachable.)
       (when ret-netlayer
         (register-lobby-on-mesh!))

       ;; Hold open
       (perform-operation (wait-operation (make-condition))))
       #:unwind? #t)))))

(main (command-line))
