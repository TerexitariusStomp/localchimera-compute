;;; module/playnet/gateway/monero-boot.scm — resolve wallet cap + spawn reconciler
;;;
;;; The wallet and policy actors run in a SEPARATE process
;;; (server/wallet-service.scm). This module resolves the sturdyref
;;; that wallet-service.scm wrote to /var/lib/playnet/wallet-sref.txt,
;;; giving the gateway a capability-attenuated reference to the policy
;;; actor. Then it spawns the fleet reconciler wired to that cap.
;;;
;;; The gateway process CANNOT reach the raw ^monero-wallet — the
;;; sturdyref names the policy's wire facet ((playnet monero policy-wire)),
;;; which answers the spend and read methods (transfer, reserve-budget,
;;; get-balance, get-address, get-outgoing, stats, the invoice and
;;; swap-deposit brackets) and nothing else. sweep-all, unguarded transfer
;;; and the policy's rewiring methods are unreachable. The gateway wraps the
;;; enlivened facet in a ^wallet-policy-client, so its callers speak the
;;; policy's own vocabulary.

(define-module (playnet gateway monero-boot)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins ocapn ids)
  #:use-module (goblins ocapn captp)
  #:use-module (goblins utils hashmap)
  #:use-module (goblins persistence-store syrup)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (playnet monero policy-wire)
  #:use-module (playnet fleet sporestack)
  #:use-module (playnet fleet paths)
  #:use-module (playnet fleet sporestack-provider)
  #:use-module (playnet fleet vpsbg)
  #:use-module (playnet fleet swap)
  #:use-module (playnet fleet provider)
  #:use-module (playnet fleet reconciler)
  #:use-module (playnet fleet cdn-front)
  #:export (boot-monero-actors!))

(define* (boot-monero-actors! gateway-vat ocapn-vat mycapn
                              #:key
                              data-dir
                              deploy-dir
                              ssh-key-file
                              persistence-registry
                              (log! format))
  "Resolve the wallet-service's sturdyref and spawn the fleet
reconciler. Returns two values: (policy-cap reconciler).

POLICY-CAP is a ^wallet-policy-client over the live OCapN reference
to the policy's wire facet in the wallet-service process — or #f if the sturdyref file is
missing (wallet-service not running).

RECONCILER is the ^fleet-reconciler actor — restored from
<data-dir>/fleet-reconciler.syrup if present, otherwise spawned
fresh — wired to POLICY-CAP via its rewire method. #f if no
providers are configured.

PERSISTENCE-REGISTRY is the gateway's shared registry for cross-
vat sturdyref resolution. Required when reconciler is enabled.

GATEWAY-VAT is used to spawn the XMR→BTC swapper. The reconciler
itself runs in its own dedicated persistent vat (created by
spawn-persistent-vat)."

  (let* ((sref-path (string-append data-dir "/wallet-sref.txt"))
         ;; Shared with the reconciler, which writes this same file when a
         ;; token rotation confirms — so it is asked for by provider name
         ;; rather than spelled out a second time here.
         (token-file (provider-token-file "sporestack" data-dir))
         (desired-fleet (string-append deploy-dir "/desired-fleet.scm"))
         (hosts-file (string-append deploy-dir "/hosts.scm"))
         (reconciler-sref-path
          (string-append data-dir "/reconciler-sref.txt")))

    ;; ── Resolve wallet policy sturdyref ───────────────────────────
    ;; The wallet process takes a fresh identity every time it starts and
    ;; rewrites the sturdyref file, so the file is the announcement and its
    ;; mtime the generation. `current-remote` is asked on every call: it
    ;; enlivens once per generation and hands back that ref (a promise, at
    ;; first). A wallet that restarts on its own — a respawn, a reboot — is
    ;; followed with no restart of the gateway.
    (define resolved-mtime #f)
    (define resolved-remote #f)

    (define (current-remote)
      (let ((mtime (and (file-exists? sref-path)
                        (stat:mtime (stat sref-path)))))
        (cond
         ((not mtime)
          (set! resolved-mtime #f)
          (set! resolved-remote #f))
         ((not (eqv? mtime resolved-mtime))
          (let* ((uri (string-trim-both
                       (call-with-input-file sref-path get-string-all)))
                 (sref (string->ocapn-id uri)))
            ;; The URI is a spend capability — the log names the file, never it.
            (log! "  [monero-boot] resolving wallet sturdyref from ~a~%" sref-path)
            (set! resolved-remote (<- mycapn 'enliven sref))
            (set! resolved-mtime mtime))))
        resolved-remote))

    ;; A host with a wallet service has SREF-PATH as a symlink into the
    ;; wallet's run directory (the wallet-service activation makes it), and
    ;; the link dangles until the running wallet announces itself. The link's
    ;; own existence is what says "this host has a wallet": the cap is made
    ;; then, whichever of the two services wins the race at boot, and a call
    ;; placed before the wallet is up is a broken promise its caller retries.
    (define wallet-configured?
      (or (file-exists? sref-path)
          (and (false-if-exception (lstat sref-path)) #t)))

    (define policy-cap
      (if wallet-configured?
          ;; The client speaks the policy's own vocabulary over the wallet
          ;; process's wire facet, so the callers below address it as they
          ;; would the policy.
          (let ((cap (with-vat gateway-vat
                       (spawn ^wallet-policy-client current-remote))))
            (log! "  [monero-boot] wallet policy cap resolved~%")
            cap)
          (begin
            (log! "  [monero-boot] ~a not found — wallet cap unavailable~%" sref-path)
            (log! "  [monero-boot] is wallet-service running?~%")
            #f)))

    ;; ── Build provider registry ──────────────────────────────────
    ;; Write the SPORESTACK_TOKEN env var to a 0600 file for per-tick
    ;; reads (reduced memory exposure).
    (let ((token-env (or (getenv "SPORESTACK_TOKEN") "")))
      (unless (string=? token-env "")
        (call-with-output-file token-file
          (lambda (port) (display token-env port)))
        (chmod token-file #o600)))

    (define provider-registry
      (let ((reg '()))
        ;; SporeStack: if token file exists, register the provider
        (when (file-exists? token-file)
          (let* ((token (string-trim-both
                         (call-with-input-file token-file get-string-all)))
                 (creds (make-sporestack-creds sporestack-default-endpoint token)))
            (set! reg (cons (cons "sporestack" (make-sporestack-provider creds))
                            reg))
            (log! "  [monero-boot] provider registered: sporestack~%")))

        ;; VPSBG: registered when the box holds its API key.
        (let ((vpsbg-key (or (getenv "VPSBG_API_KEY") "")))
          (unless (string=? vpsbg-key "")
            (catch #t
              (lambda ()
                (let ((creds (make-vpsbg-creds vpsbg-default-endpoint vpsbg-key)))
                  (set! reg (cons (cons "vpsbg" (make-vpsbg-provider creds)) reg))
                  (log! "  [monero-boot] provider registered: vpsbg~%")))
              (lambda (key . args)
                (log! "  [monero-boot] vpsbg provider unavailable: ~a ~a~%" key args)))))

        reg))

    ;; ── XMR→BTC swapper ────────────────────────────────────────────
    (define the-swapper
      (if policy-cap
          (with-vat gateway-vat
            (let* ((api-key (or (getenv "CHANGENOW_API_KEY") ""))
                    ;; Each swap it creates is written down here before any
                   ;; XMR moves, so one whose answer was lost — a restart,
                   ;; a broken promise — is recalled, never made twice.
                   (s (spawn ^xmr-btc-swapper policy-cap api-key
                             (string-append data-dir "/swaps"))))
              (log! "  [monero-boot] XMR→BTC swapper spawned (ChangeNow~a)~%"
                    (if (string-null? api-key) " no key" " keyed"))
              s))
          (begin
            (log! "  [monero-boot] no policy cap — swapper disabled~%")
            #f)))

    ;; ── Fleet reconciler (persistent vat) ─────────────────────────
    ;; Restored from <data-dir>/fleet-reconciler.syrup if present,
    ;; otherwise spawn-fn runs once and the resulting actor is the seed.
    ;; Caps (policy, providers, swapper) are NOT in the portrait — they
    ;; carry credentials. We inject them via the actor's `rewire` method
    ;; immediately after spawn, regardless of fresh-vs-restored.
    (define ssh-key-pub
      (if (and ssh-key-file (file-exists? ssh-key-file))
          (string-trim-both
           (call-with-input-file ssh-key-file get-string-all))
          ""))

    (define (spawn-reconciler-fresh)
      ;; Only invoked the first time the gateway boots with no syrup
      ;; file. Caps are #f/'() — rewired below for both fresh + restored.
      (spawn ^fleet-reconciler
             #f '() #f
             ssh-key-pub
             desired-fleet
             hosts-file
             (hashmap)
             0
             300
             #f))                    ; token-rotation (idle)

    (define-values (reconciler-vat reconciler)
      (cond
       ((not (pair? provider-registry))
        (log! "  [monero-boot] no providers configured — reconciler disabled~%")
        (values #f #f))
       (else
        (spawn-persistent-vat
         fleet-reconciler-env
         spawn-reconciler-fresh
         (make-syrup-store
          (string-append data-dir "/fleet-reconciler.syrup"))
         #:name "fleet-reconciler"
         #:persistence-registry persistence-registry))))

    (when reconciler
      (log! "  [monero-boot] reconciler vat spawned (~a providers, swapper ~a, ssh key ~a, syrup=~a/fleet-reconciler.syrup)~%"
            (length provider-registry)
            (if the-swapper "active" "disabled")
            (if (string-null? ssh-key-pub) "MISSING" "found")
            data-dir)
      ;; Inject caps via rewire — works for both fresh and restored.
      ;; Passing #f for logger keeps the default stderr logger.
      (with-vat reconciler-vat
        ($ reconciler 'rewire policy-cap provider-registry the-swapper #f)
        ;; A restored reconciler holds the key it was first spawned with.
        (unless (string-null? ssh-key-pub)
          ($ reconciler 'set-ssh-key ssh-key-pub))))

    ;; A recorded host that asks for it is put behind this box's CDN
    ;; (/etc/playnet/cdn.conf); the zones made are on record in the data dir.
    (set-host-fronting!
     (make-host-fronting (string-append data-dir "/cdn-zones.scm")
                         #:log! log!))

    ;; ── Mint a sturdyref for the reconciler ───────────────────────
    ;; fleet-bridge (and any out-of-process tool) enlivens this sref
    ;; instead of poking the gateway REPL socket. Replaces the
    ;; brittle text-protocol eval-on-gateway! loop.
    (when reconciler
      (with-vat ocapn-vat
        (on (<- mycapn 'register reconciler 'websocket)
            (lambda (sref)
              (let ((uri (ocapn-id->string sref)))
                (call-with-output-file reconciler-sref-path
                  (lambda (port) (display uri port) (newline port)))
                (chmod reconciler-sref-path #o644)
                (log! "  [monero-boot] reconciler sturdyref written to ~a~%"
                      reconciler-sref-path))))))

    (values policy-cap reconciler)))
