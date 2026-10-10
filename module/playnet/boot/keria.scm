;;; module/playnet/boot/keria.scm — the KERIA client tier: the agent, its schemas, the peers, the witness publisher.
;;;
;;; What the gateway does with a KERIA agent when KERIA_BRAN names one: boot
;;; or reconnect the agent with a bounded retry, register the controller AID,
;;; resolve every catalogued schema and every peer OOBI, spawn the
;;; http-witness-publisher into the default witnesses, install the IPEX
;;; handlers. Without a bran the tier is off, said once on the log, and the
;;; credential store below is local-durable. The IPEX poller and the
;;; peer-status writer are fibers, so they start once the scheduler runs.

(define-module (playnet boot keria)
  #:use-module ((playnet boot site) #:select (data-path log! oobi-auto-mirror? scopes-durable?))
  #:use-module ((playnet keri bridge) #:select (keri-boot! keri-connected? keri-list-contacts keri-peer-status
                                                keri-set-urls!))
  #:use-module ((playnet keri credentials) #:select (acdc-ensure-schemas-resolved!))
  #:use-module ((playnet keri inception) #:select (gateway-controller-init!))
  #:use-module ((playnet keys http-witness-publisher) #:select (spawn-http-witness-publisher))
  #:use-module ((playnet federation keria-notifications) #:select (install-default-handlers! start-notification-poller!))
  #:use-module ((playnet keys peers) #:select (known-uc-aid resolve-peer-oobis!))
  #:use-module ((playnet utils common) #:select (env-int))
  #:use-module ((playnet utils paths) #:select (default-scope-witnesses))
  #:use-module (fibers)
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (connect-keria! start-ipex-poller! start-peer-status-writer!))

(define (connect-keria!)
  "Connect to KERIA when KERIA_BRAN is set. Runs BEFORE fibers: the connect
is synchronous HTTP with a sleeping retry, which must not hold a scheduler
thread."
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
          (when (and (scopes-durable?) (oobi-auto-mirror?))
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
      (log! "  [gateway] KERIA client tier OFF (no KERIA_BRAN) — acdc-store local-durable; IPEX poller + witness replication + KERIA-governor checks inert~%"))))

(define (start-ipex-poller!)
  "The IPEX notification poller, a fiber: only once the scheduler runs, and
only when the connect above succeeded."
  ;; start-notification-poller! calls spawn-fiber, which needs a live
  ;; fibers scheduler — the KERIA connect block runs BEFORE run-fibers
  ;; starts one, so calling it there threw "No scheduler current" on every
  ;; boot with KERIA_BRAN set. keri-connected? reflects whether the
  ;; synchronous connect block actually succeeded.
  (when (keri-connected?)
    (start-notification-poller!)
    (log! "  [gateway] notification poller started~%")))

;; ── Peer-status snapshot for /peer-status.json ─────────────────
;; Periodic ticker queries KERIA via the bridge helpers
;; (keri-list-contacts → keri-peer-status per AID) and writes a
;; snapshot to disk. serve-static (no libsodium / no signify
;; creds in its env) reads the file and renders JSON. This is
;; the operator's answer to capability #8: "why aren't grants
;; from peer X landing?" — without any keripy fork.
(define (start-peer-status-writer!)
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
        %peer-status-tick-sec))
