;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; mimir.scm — Mímir AI co-facilitation recipe
;;;
;;; Mímir (github.com/Valley-of-the-Commons/mimir) is a system-prompt agent that
;;; assists a human facilitator in pre-designing and designing group processes.
;;; It is forbidden by design from running a session or deciding anything — it
;;; "signals, does not decide" (its own doctrine's words: "señala, no decide"):
;;; every output returns the decision to the human (README.md:17;
;;; HABILIDADES.md §10, §14).
;;;
;;; Stated here as a labour recipe, in the register of `meeting.scm`: the
;;; deliverables are countable documents, the inputs are a facilitator's hours
;;; and an AI co-facilitator's use, and none of it is matter (see the
;;; `spec:mimir-*` EMPTY rows in catalogues/substances.scm).
;;;
;;; The delivery gate (HABILIDADES.md §10 — runs before the facilitator sees
;;; ANYTHING, its own text: "corre antes de que el facilitador vea nada") is
;;; not a final step: it gates every hand-back. So the chain draws a `-draft`
;;; spec per stage, and a `rp-mimir-gate-*` process turns each draft into the
;;; audited artifact the next stage (or the facilitator) actually receives —
;;; the same shape three times, not one big step at the end:
;;;
;;;   rp-mimir-predesign      — Loop A: contracting, purpose, voice map,
;;;                             five-area diagnosis, stop rule (HABILIDADES.md §1)
;;;   rp-mimir-gate-predesign — audits the pre-design draft
;;;   rp-mimir-design         — Loop B: session design, gated on the AUDITED
;;;                             pre-design, never the draft (HABILIDADES.md §2)
;;;   rp-mimir-instrument     — instrument construction (HABILIDADES.md §5):
;;;                             shares Loop B's sequence-group. Nothing in the
;;;                             doctrine gates it on a closed design — it can
;;;                             be drafted alongside it, not only after — and
;;;                             it stays independently invocable as its own
;;;                             recipe.
;;;   rp-mimir-gate-design    — audits the session-design draft
;;;   rp-mimir-sequence       — sequence/rhythm check, gated on the AUDITED
;;;                             design, mandatory before an agenda is fixed
;;;                             (HABILIDADES.md §3)
;;;   rp-mimir-gate-sequence  — audits the agenda draft into the round's
;;;                             hand-back
;;; plus one recipe for a capability that doesn't sit on that spine:
;;;   rp-mimir-closing        — session-closing protocol, runs only at case
;;;                             close, gated on a delivered hand-back
;;;                             (HABILIDADES.md §12)
;;;
;;; A `gate-*` process draws no facilitator hours — the AI audits its own
;;; output before the human ever sees it, so it is `use`-only.
;;;
;;; Every step is COUNTABLE, in the sense `meeting.scm` gives that word: a
;;; pre-design interrogated by half is not half a pre-design, it is no
;;; pre-design — hence `mimir-whole-acts`.

(define-module (localchimera knowledge recipes mimir)
  #:use-module ((localchimera utils units) #:select (%count-unit %effort-unit))
  #:use-module (localchimera vf schemas)
  #:use-module (goblins)
  #:export (mimir-whole-acts seed-mimir-specs seed-mimir-recipes))

(define mimir-whole-acts
  '("rp-mimir-predesign" "rp-mimir-gate-predesign"
    "rp-mimir-design" "rp-mimir-instrument" "rp-mimir-gate-design"
    "rp-mimir-sequence" "rp-mimir-gate-sequence"
    "rp-mimir-closing"))

;; A `work` flow for the human facilitator's hours, conforms-to the facilitator
;; skill so the planner's skill-matcher can staff it (meeting.scm's pattern).
(define (mimir-work-flow id process-id hours)
  (make-recipe-flow #:id id #:action 'work #:resource-conforms-to "spec:mimir-facilitator-h"
                    #:effort-quantity (make-measure hours %effort-unit) #:recipe-input-of process-id))

;; A `use` flow for the AI co-facilitator: one instance engaged for HOURS.
;; Both quantities matter (count engaged + duration) per the recipes skill's
;; oven lesson — Mímir is a durable, not consumed by being consulted.
(define (mimir-agent-use-flow id process-id hours)
  (make-recipe-flow #:id id #:action 'use #:resource-conforms-to "spec:mimir-agent"
                    #:resource-quantity (make-measure 1 %count-unit) #:effort-quantity (make-measure hours %effort-unit)
                    #:recipe-input-of process-id))

;; A `consume` flow: one draft/prior-stage artifact into PROCESS-ID.
(define (mimir-consume-flow id spec-id process-id)
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec-id
                    #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of process-id))

;; A `produce` flow: one artifact out of PROCESS-ID, primary for that process.
(define (mimir-produce-flow id spec-id process-id)
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec-id
                    #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of process-id #:is-primary #t))

(define (seed-mimir-specs recipe-store)
  "Add Mímir's resource specifications: the facilitator-hour and AI-agent
   inputs, a `-draft` and audited spec per gated stage, and the
   instrument/closing-report deliverables."
  (for-each
    (lambda (row)
      ($ recipe-store 'add-resource-spec
         (make-resource-specification #:id (car row) #:name (cadr row)
                                      #:default-unit-of-resource (caddr row))))
    '(("spec:mimir-facilitator-h"        "Human Facilitator"                  "hours")
      ("spec:mimir-agent"                "Mímir Agent (AI co-facilitator)"    "each")
      ("spec:mimir-predesign-draft"      "Pre-Design (draft, Loop A)"         "each")
      ("spec:mimir-predesign"            "Pre-Design (audited, Loop A)"       "each")
      ("spec:mimir-session-design-draft" "Session Design (draft, Loop B)"     "each")
      ("spec:mimir-session-design"       "Session Design (audited, Loop B)"   "each")
      ("spec:mimir-agenda-draft"         "Agenda (draft, sequence/rhythm)"    "each")
      ("spec:mimir-handback"             "Audited Hand-Back"                  "each")
      ("spec:mimir-instrument"           "Feedback Instrument"                "each")
      ("spec:mimir-closing-report"       "Session Closing Report"             "each"))))

(define (seed-mimir-recipes recipe-store)
  "Seed the Mímir engagement chain — predesign → gate → design ‖ instrument
   → gate → sequence → gate — plus the standalone instrument/closing
   recipes."

  ;; ── rp-mimir-predesign: Loop A — 2 hours ─────────────────────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-predesign" #:name "Pre-Design (Loop A)"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-predesign" #:name "Pre-Design Interview"
                          #:process-conforms-to "pspec-mimir-predesign" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 2 %effort-unit) #:sequence-group 0))
  ($ recipe-store 'add-recipe-flow (mimir-work-flow "rf-mimir-predesign-work" "rp-mimir-predesign" 2))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-predesign-agent" "rp-mimir-predesign" 2))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-predesign-out" "spec:mimir-predesign-draft" "rp-mimir-predesign"))

  ;; ── rp-mimir-gate-predesign: audit the pre-design draft — 6 minutes ──────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-gate-predesign"
                                 #:name "Delivery Gate (pre-design)"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-gate-predesign" #:name "Self-Audit of the Pre-Design"
                          #:process-conforms-to "pspec-mimir-gate-predesign" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 0.1 %effort-unit) #:sequence-group 1))
  ($ recipe-store 'add-recipe-flow
     (mimir-consume-flow "rf-mimir-gate-predesign-in" "spec:mimir-predesign-draft" "rp-mimir-gate-predesign"))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-gate-predesign-agent" "rp-mimir-gate-predesign" 0.1))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-gate-predesign-out" "spec:mimir-predesign" "rp-mimir-gate-predesign"))

  ;; ── rp-mimir-design: Loop B — 3 hours, gated on the AUDITED pre-design ───
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-design" #:name "Session Design (Loop B)"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-design" #:name "Design the Movement and Format"
                          #:process-conforms-to "pspec-mimir-design" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 3 %effort-unit) #:sequence-group 2))
  ($ recipe-store 'add-recipe-flow
     (mimir-consume-flow "rf-mimir-design-predesign-in" "spec:mimir-predesign" "rp-mimir-design"))
  ($ recipe-store 'add-recipe-flow (mimir-work-flow "rf-mimir-design-work" "rp-mimir-design" 3))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-design-agent" "rp-mimir-design" 3))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-design-out" "spec:mimir-session-design-draft" "rp-mimir-design"))

  ;; ── rp-mimir-instrument: instrument construction — 1.5 hours ────────────
  ;; Same sequence-group as rp-mimir-design: nothing gates it on a closed
  ;; design, so it runs in the same window rather than only after (HABILIDADES
  ;; §5 is a standing capability, not a step that waits its turn). No consume
  ;; flow — it has no data dependency on Loop B, only a scheduling-tier one.
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-instrument" #:name "Instrument Construction"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-instrument" #:name "Draft Questionnaire/Form"
                          #:process-conforms-to "pspec-mimir-instrument" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 1.5 %effort-unit) #:sequence-group 2))
  ($ recipe-store 'add-recipe-flow (mimir-work-flow "rf-mimir-instrument-work" "rp-mimir-instrument" 1.5))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-instrument-agent" "rp-mimir-instrument" 1.5))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-instrument-out" "spec:mimir-instrument" "rp-mimir-instrument"))

  ;; ── rp-mimir-gate-design: audit the session-design draft — 6 minutes ────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-gate-design" #:name "Delivery Gate (design)"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-gate-design" #:name "Self-Audit of the Session Design"
                          #:process-conforms-to "pspec-mimir-gate-design" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 0.1 %effort-unit) #:sequence-group 3))
  ($ recipe-store 'add-recipe-flow
     (mimir-consume-flow "rf-mimir-gate-design-in" "spec:mimir-session-design-draft" "rp-mimir-gate-design"))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-gate-design-agent" "rp-mimir-gate-design" 0.1))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-gate-design-out" "spec:mimir-session-design" "rp-mimir-gate-design"))

  ;; ── rp-mimir-sequence: sequence/rhythm check — 1 hour ────────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-sequence" #:name "Sequence/Rhythm Check"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-sequence" #:name "Verify Prerequisites and Energy Curve"
                          #:process-conforms-to "pspec-mimir-sequence" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 1 %effort-unit) #:sequence-group 4))
  ($ recipe-store 'add-recipe-flow
     (mimir-consume-flow "rf-mimir-sequence-design-in" "spec:mimir-session-design" "rp-mimir-sequence"))
  ($ recipe-store 'add-recipe-flow (mimir-work-flow "rf-mimir-sequence-work" "rp-mimir-sequence" 1))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-sequence-agent" "rp-mimir-sequence" 1))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-sequence-out" "spec:mimir-agenda-draft" "rp-mimir-sequence"))

  ;; ── rp-mimir-gate-sequence: audit the agenda into the round's ───────────
  ;; hand-back — 6 minutes, no human work (HABILIDADES.md §10)
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-gate-sequence" #:name "Delivery Gate (agenda)"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-gate-sequence" #:name "Self-Audit of the Agenda"
                          #:process-conforms-to "pspec-mimir-gate-sequence" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 0.1 %effort-unit) #:sequence-group 5))
  ($ recipe-store 'add-recipe-flow
     (mimir-consume-flow "rf-mimir-gate-sequence-in" "spec:mimir-agenda-draft" "rp-mimir-gate-sequence"))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-gate-sequence-agent" "rp-mimir-gate-sequence" 0.1))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-gate-sequence-out" "spec:mimir-handback" "rp-mimir-gate-sequence"))

  ;; ── rp-mimir-closing: session-closing protocol — 1 hour, runs only ──────
  ;; at close, gated on a delivered hand-back
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mimir-closing" #:name "Session-Closing Protocol"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mimir-closing" #:name "Close the Case and Consolidate the Log"
                          #:process-conforms-to "pspec-mimir-closing" #:process-classified-as '("tag:facilitation")
                          #:has-duration (make-duration 1 %effort-unit) #:sequence-group 0))
  ($ recipe-store 'add-recipe-flow
     (mimir-consume-flow "rf-mimir-closing-handback-in" "spec:mimir-handback" "rp-mimir-closing"))
  ($ recipe-store 'add-recipe-flow (mimir-work-flow "rf-mimir-closing-work" "rp-mimir-closing" 1))
  ($ recipe-store 'add-recipe-flow (mimir-agent-use-flow "rf-mimir-closing-agent" "rp-mimir-closing" 1))
  ($ recipe-store 'add-recipe-flow
     (mimir-produce-flow "rf-mimir-closing-out" "spec:mimir-closing-report" "rp-mimir-closing"))

  ;; ── Recipes ───────────────────────────────────────────────────────────────
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-mimir-engagement" #:name "Mímir Co-Facilitation Round"
                  #:primary-output "spec:mimir-handback"
                  #:recipe-processes (list "rp-mimir-predesign" "rp-mimir-gate-predesign"
                        "rp-mimir-design" "rp-mimir-instrument" "rp-mimir-gate-design"
                        "rp-mimir-sequence" "rp-mimir-gate-sequence")))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-mimir-instrument" #:name "Mímir Instrument Construction"
                  #:primary-output "spec:mimir-instrument" #:recipe-processes (list "rp-mimir-instrument")))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-mimir-closing" #:name "Mímir Session Closing"
                  #:primary-output "spec:mimir-closing-report" #:recipe-processes (list "rp-mimir-closing"))))
