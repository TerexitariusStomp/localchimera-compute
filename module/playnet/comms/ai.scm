;;; comms/ai.scm — Stage 3: the fenced AI restyle, wired live to the gateway.
;;;
;;; Design: docs/planning/faces/communications-recipes.md §3 (the determinism line).
;;;
;;; The deterministic core (comms/plan.scm) renders a factual, citable SKELETON. This
;;; is the ONLY place AI enters the comms pipeline, and it does one thing:
;;; restyle a skeleton into a channel's voice. It never invents — every result
;;; is passed through entails-skeleton? (comms/plan.scm), so a restyle that adds a
;;; number or drops the citation is REJECTED and the dry skeleton is returned
;;; unchanged. The skeleton is always a valid post; the AI can only improve tone.
;;;
;;; `complete` is a (prompt → text) completer — exactly the shape llm-completer
;;; (playnet ai llm) returns over a key-pool. Bind it to a TEE model and the
;;; restyle is verifiably attested (§5). In a test, pass a plain lambda.
;;;
;;; Assumes comms/plan.scm is already loaded (entails-skeleton?, plan->comm-intents,
;;; render-skeleton). AI-free comms/plan.scm stays AI-free; this file holds the seam.

(define-module (playnet comms ai)
  #:use-module (playnet comms plan)
  #:use-module (playnet ai conform)
  #:use-module (ice-9 format)
  #:export (comms-restyle-system-prompt restyle-skeleton plan->posts
            comms-live-completer))

(use-modules (srfi srfi-1) (ice-9 format))

(define comms-restyle-system-prompt
  (string-append
   "You restyle a factual community post for one social channel. Rewrite it in a "
   "warm, natural voice that fits the channel. Hard rules: preserve EVERY number "
   "exactly; keep the [cite:...] token exactly as given; add NO fact, number, "
   "name, or claim that is not already in the message. Output only the restyled "
   "post, nothing else."))

(define* (restyle-skeleton complete skeleton #:key (channel "general")
                           (retries %conform-default-retries))
  "Stage 3: a FENCED AI restyle of SKELETON for CHANNEL. COMPLETE is a
   (prompt → text) completer (llm-completer over the key-pool/gateway in
   production, a lambda in tests). One door, (playnet ai conform): a restyle
   that breaks the fence is asked again with the broken fact named, RETRIES
   times; then the dry skeleton ships — so a fabricated fact never does."
  (conform complete (string-append "Channel: " channel "\n\nMessage:\n" skeleton)
           #:read  (lambda (raw) (and (string? raw) raw))
           #:check (lambda (candidate) (skeleton-fence-reason skeleton candidate))
           #:floor (lambda (_) skeleton)     ; fence tripped (or the gateway failed)
           #:retries retries))

(define* (plan->posts complete intents sat-states #:key (channel "general"))
  "The whole LIVE pipeline in one call: Stage 0→2 (comms/plan.scm) folds the plan into
   citable skeletons, then Stage 3 restyles each through COMPLETE, fenced. →
   a list of channel-ready posts, one per under-satisfied intent, every one of
   which provably entails its skeleton. No fact can enter that was not in the plan."
  (map (lambda (sk) (restyle-skeleton complete sk #:channel channel))
       (plan->skeletons intents sat-states)))

;; ─── LIVE binding : the real TEE completer over a spawned key-pool ──────────
;; Run inside the key-pool's vat. Needs (playnet ai llm) in scope for
;; llm-completer. Example:
;;
;;   (use-modules (playnet ai llm))
;;   (with-vat vat
;;     (let ((complete (llm-completer pool
;;                        #:system comms-restyle-system-prompt
;;                        #:model  "TEE/gpt-oss-120b"
;;                        #:verify? #t)))          ; TEE-attested restyle
;;       (plan->posts complete intents sats #:channel "mastodon")))
;;
;; comms-live-completer packages that binding so a caller only supplies the pool.
(define* (comms-live-completer llm-completer pool
                               #:key (model "TEE/gpt-oss-120b") (verify? #t))
  "Build the live (prompt → text) restyle completer over POOL. LLM-COMPLETER is
   passed in (the (playnet ai llm) export) so this file needs no AI import. The
   default model is a nano-gpt TEE model, so restyles are attested."
  (llm-completer pool #:system comms-restyle-system-prompt
                 #:model model #:verify? verify?))
