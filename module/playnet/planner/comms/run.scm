;;; comms/run.scm — the live pipeline, composing every stage end to end.
;;;
;;; Ties the built pieces into one run: Stage 0 (under-satisfied intents) → Stage 1
;;; (rank by dual × recruitable) → Stage 2 (skeleton) → Stage 3 (fenced restyle) →
;;; human gate → publish. Transport- and model-agnostic by seams:
;;;   complete : (prompt → text)  — the gateway completer (llm-completer); #f ⇒ dry skeleton
;;;   dual-of  : (intent-id → number) — the solver's shadow prices; #f ⇒ unranked
;;;   publish  : (text → result)  — the wrapped adapter (mastodon/dry-run); #f ⇒ compose only
;;;   approve? : (text → bool)     — the human gate; defaults to REFUSE (fail-closed)
;;;
;;; Nothing goes live unless a real `complete`, a real `publish`, and an approving
;;; `approve?` are all supplied — each defaults to the safe path.
;;;
;;; Load AFTER comms/plan.scm + comms/ai.scm.

(define-module (playnet planner comms run)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner observation states)
  #:use-module (playnet planner comms plan)
  #:use-module (playnet planner comms ai)
  #:use-module (goblins)
  #:export (comms-pipeline run-comms-campaign))

(use-modules (srfi srfi-1))

;; one intent's journey: Stage 2 skeleton, then the fenced Stage-3 restyle.
(define* (comms-pipeline intent sat #:key complete (channel "general"))
  (let ((sk (render-skeleton intent sat)))
    (if complete (restyle-skeleton complete sk #:channel channel) sk)))

;; the whole campaign, as a list of per-post records.
(define* (run-comms-campaign intents sat-states
                             #:key complete dual-of publish
                                   (approve? (lambda (_) #f)) (channel "general") (limit 100))
  "Stage 0→publish. Ranks the under-satisfied intents (by dual × recruitable when
   DUAL-OF is given), renders + restyles each, gates, and publishes the approved.
   → ((intent-id . record) …), where record is one of:
     ((composed . text))                     — no publish adapter (compose only)
     ((held . #t) (text . text))             — the gate refused (fail-closed default)
     ((published . result) (text . text))    — approved and sent"
  (let* ((short   (plan->comm-intents intents sat-states))
         (ordered (if dual-of (map car (rank-comm-intents short dual-of)) short))
         (chosen  (if (and limit (> (length ordered) limit)) (list-head ordered limit) ordered))
         (sat-of  (lambda (i) (find (lambda (s) (equal? (satisfaction-state-intent-id s)
                                                        (intent-id i))) sat-states))))
    (map (lambda (intent)
           (let* ((sat  (sat-of intent))
                  (text (comms-pipeline intent sat #:complete complete #:channel channel))
                  (rec  (cond ((not publish)   `((composed . ,text)))
                              ((approve? text) `((published . ,(publish text)) (text . ,text)))
                              (else            `((held . #t) (text . ,text))))))
             (cons (intent-id intent) rec)))
         chosen)))

;; ─── LIVE wiring : how to source the seams in production ────────────────────
;; complete — the TEE-attested gateway completer (comms/ai.scm):
;;   (use-modules (playnet ai llm))
;;   (define complete (comms-live-completer llm-completer pool))   ; nano-gpt TEE
;; dual-of  — from a located solve (comms/metabolism.scm):
;;   (call-with-values comms-solve
;;     (lambda (x t cols idx report) (comms-dual-of report)))       ; keyed by good; adapt to intent-id
;; publish  — the wrapped goblins adapter, run in its vat:
;;   (define tok (with-vat vat (spawn-mastodon instance token)))     ; sovereign channel
;;   (define (publish text) (with-vat vat (publish-with-gate tok text #:approve? human-approved?)))
;; approve? — a human reviewing in a test account before anything is real.
