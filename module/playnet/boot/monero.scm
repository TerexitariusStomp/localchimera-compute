;;; module/playnet/boot/monero.scm — the wallet's policy cap and what rides on it: the fleet reconciler, the claimable external assets, donations, payouts, top-ups.
;;;
;;; The wallet and policy actors live in a SEPARATE process
;;; (wallet-service.scm on port 9092). boot-monero-actors! resolves the
;;; sturdyref and spawns the reconciler. The gateway has NO raw wallet
;;; reference — only the policy cap.

(define-module (playnet boot monero)
  #:use-module ((playnet boot site) #:select (data-path log!))
  #:use-module ((playnet gateway monero-boot) #:select (boot-monero-actors!))
  #:use-module ((playnet monero payout) #:select (start-payout-runner!))
  #:use-module ((playnet monero poller) #:select (start-donation-watch!))
  #:use-module ((playnet monero specs) #:select (bootstrap-external-asset! bootstrap-monero-resource!))
  #:use-module ((playnet monero topup) #:select (set-topup-amounts! start-topup!))
  #:use-module ((playnet utils common) #:select (env-flag?))
  #:use-module ((playnet utils paths) #:select (playnet-data-dir))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (boot-monero!))

(define* (boot-monero! #:key gateway-vat ocapn-vat mycapn planner-vat planner-service meeting-scope
                       fc-key store key-pool registry)
  "(values spend-policy fleet-reconciler), the policy cap #f without a wallet
service. The XMR and EUR specs stand on MEETING-SCOPE's claimable rail; the
donation watch, the payout runner (opt-in) and the AI account top-up tick
in GATEWAY-VAT."
  (define-values (spend-policy fleet-reconciler)
    (boot-monero-actors!
     gateway-vat ocapn-vat mycapn
     #:data-dir (playnet-data-dir)
     #:deploy-dir (or (getenv "PLAYNET_DEPLOY_DIR")
                      "/home/playnet/playnet-repo/deploy")
     ;; The account's home, where ssh itself looks — the service's
     ;; HOME is its data dir.
     #:ssh-key-file (or (getenv "PLAYNET_FLEET_SSH_PUBKEY")
                        (string-append
                         (passwd:dir (getpwuid (getuid)))
                         "/.ssh/id_ed25519.pub"))
     #:persistence-registry registry
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
                           (data-path "monero-donations.state")
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
    (start-payout-runner! gateway-vat planner-service spend-policy fc-key store
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
                  (data-path "topups")
                  #:interval-seconds 300 #:log! log!)
    (log! "  [gateway] account top-up on (5 min tick)~%"))
  (values spend-policy fleet-reconciler))
