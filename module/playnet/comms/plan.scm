;;; comms/plan.scm — communications derived from the plan (the deterministic core).
;;;
;;; Design: docs/planning/faces/communications-recipes.md §3–§5.
;;;
;;; NO new schema. A "communicative intent" is an ordinary ValueFlows <intent>
;;; whose need is UNDER-SATISFIED — total-satisfied < total-desired in its
;;; <satisfaction-state>. Those are diagnostics the planner already emits every
;;; run; comms is a fold over them, exactly as compliance folds a jurisdiction's
;;; bill. The comm "kind" (call-to-action / recruitment / mobilization /
;;; resilience / offer) is a PURE FUNCTION of the intent (its action + its
;;; classified-as tags), never a stored field.
;;;
;;; Three deterministic stages, no AI in this file:
;;;   plan->comm-intents  — Stage 0/1: the under-satisfied intents (a filter)
;;;   render-skeleton     — Stage 2:   intent → a factual, citable, wooden post
;;;   entails-skeleton?   — Stage 3 fence: does an AI restyle preserve the facts?
;;;
;;; Everything TRUE is produced here; the AI (later) only restyles the skeleton,
;;; and entails-skeleton? rejects any restyle that adds a number or drops the
;;; citation — so a fabricated fact cannot reach a post. The dry skeleton is
;;; always a valid fallback.
;;;
;;; Assumes (playnet planner) is loaded (the <intent>/<satisfaction-state>/
;;; <measure> accessors). Load: (load ".../planner/comms/plan.scm").

(define-module (playnet comms plan)
  #:use-module ((playnet vf formulas actions) #:select (labour-actions creating-actions transferring-actions))
  #:use-module (playnet vf schemas)
  #:use-module (playnet observation states)
  #:use-module (ice-9 format)
  #:export (intent-gap under-satisfied? intent-has-tag? comm-kind broadcast-intent
            plan->comm-intents %recruitable-actions intent-recruitable?
            intent-priority rank-comm-intents comm-citation comm-subject
            comm-magnitude render-skeleton plan->skeletons %digit-runs %cite-token
            entails-skeleton? skeleton-fence-reason))

(use-modules (srfi srfi-1) (srfi srfi-13) (ice-9 format))

;; ─── the shortfall : desired − satisfied, read off the satisfaction-state ───
(define (intent-gap intent sat)
  "The unmet magnitude of INTENT as a <measure>, or #f if there is no shortfall.
   Gap = total-desired − total-satisfied; the unit is the desired measure's."
  (and sat
       (let* ((d  (satisfaction-state-total-desired sat))
              (s  (satisfaction-state-total-satisfied sat))
              (dv (if d (measure-has-numerical-value d) 0))
              (sv (if s (measure-has-numerical-value s) 0))
              (gap (- dv sv)))
         (and (> gap 0)
              (make-measure gap (and d (measure-has-unit d)))))))

(define (under-satisfied? intent sat)
  "An intent worth speaking about: not finished, and with a positive gap."
  (and sat
       (not (satisfaction-state-finished sat))
       (intent-gap intent sat)
       #t))

;; ─── the comm KIND : a pure function of the intent, no stored field ─────────
(define (intent-has-tag? intent tag)
  (and (member tag (or (intent-resource-classified-as intent) '())) #t))

(define (comm-kind intent)
  "Classify INTENT into a communicative kind. Tags win over action, so a
   below-floor need mobilizes even when it is satisfied by labour."
  (cond ((intent-has-tag? intent "reproduction-floor") 'mobilization)
        ((intent-has-tag? intent "fragility")          'resilience)
        ((intent-has-tag? intent "offer")              'offer)         ; a recipe's capability
        ((intent-has-tag? intent "proof")              'proof)         ; a done work-event
        ((intent-has-tag? intent "celebration")        'celebration)   ; a met floor
        ((intent-has-tag? intent "education")          'education)     ; a tension, narrated
        ((eq? (intent-action intent) 'work)            'recruitment)
        (else                                          'call-to-action)))

;; A BROADCAST intent — offer / proof / celebration / education. Unlike a
;; shortfall it has no satisfaction-state; it announces a capability, a done deed,
;; a win, or a fact. Sourced from recipes / work-events / met floors / tensions and
;; rendered with (render-skeleton intent #f). The kind rides classified-as.
(define* (broadcast-intent id kind subject #:key (classified '()))
  (make-intent #:id id #:action 'produce #:name subject #:resource-conforms-to subject
               #:resource-classified-as (cons (symbol->string kind) classified) #:in-scope-of '()))

;; ─── Stage 0/1 : the under-satisfied intents, in input order ────────────────
(define (plan->comm-intents intents sat-states)
  "Fold the plan's diagnostics into the intents worth posting about. SAT-STATES
   join to INTENTS by intent-id. Deterministic — no AI, no new record."
  (let ((sat-of (lambda (i)
                  (find (lambda (s) (equal? (satisfaction-state-intent-id s)
                                            (intent-id i)))
                        sat-states))))
    (filter (lambda (i) (under-satisfied? i (sat-of i))) intents)))

;; ─── Stage 1 : derived selection — rank by shadow price × recruitability ────
;; Selection is not a policy layer: the planner already computes, for every unmet
;; intent, the DUAL (shadow price) of its constraint — the marginal improvement to
;; the whole plan from relieving that gap, i.e. how much recruiting help there most
;; reproduces the commons. So priority = the intent's dual, GATED by whether an
;; outside agent can actually supply the gap (a hard physical constraint no
;; volunteer can relieve is worth 0 to post about, however high its dual).

;; the actions an OUTSIDE contributor can fulfil (bring a good, do the work, hand
;; it over, render a service). A `use` of a fixed natural cap is not among them.
(define %recruitable-actions
  (append labour-actions creating-actions transferring-actions))

(define (intent-recruitable? intent)
  "Can an outside agent supply this gap? Derived from the intent's action, with a
   `hard-constraint` classification as an explicit override to #f."
  (and (not (intent-has-tag? intent "hard-constraint"))
       (and (memq (intent-action intent) %recruitable-actions) #t)))

(define* (intent-priority intent dual-of #:key (recruitable? intent-recruitable?))
  "The posting priority of INTENT: its dual (marginal reproduction value) if an
   outside agent can supply it, else 0. DUAL-OF maps an intent-id → its shadow
   price (the solver's dual vector in production; a lookup in a test). RECRUITABLE?
   is injectable — pass a recipe-graph-aware predicate (does the fulfilling process
   have a human-suppliable input?) to refine the default action heuristic."
  (if (recruitable? intent)
      (let ((d (dual-of (intent-id intent)))) (if (number? d) d 0.0))
      0.0))

(define* (rank-comm-intents intents dual-of #:key (min-priority 0.0)
                            (recruitable? intent-recruitable?))
  "Stage 1, derived: the intents worth posting about, MOST VALUABLE FIRST. Each is
   scored by intent-priority (dual × recruitable); those at or below min-priority
   are dropped. → a list of (intent . priority), descending. No policy, no AI —
   the ranking is the solver's own shadow prices. RECRUITABLE? is injectable."
  (sort
   (filter-map (lambda (i)
                 (let ((p (intent-priority i dual-of #:recruitable? recruitable?)))
                   (and (> p min-priority) (cons i p))))
               intents)
   (lambda (a b) (> (cdr a) (cdr b)))))

;; ─── Stage 2 : deterministic skeleton rendering (the render-filing pattern) ─
(define (comm-citation intent)
  "The provenance anchor of a post — the intent's own id (the plan node)."
  (or (intent-id intent) "?"))

(define (comm-subject intent)
  (or (intent-name intent) (intent-resource-conforms-to intent) "it"))

(define (comm-magnitude gap)
  (if gap
      (format #f "~a ~a" (measure-has-numerical-value gap)
              (or (measure-has-unit gap) ""))
      "some"))

(define (render-skeleton intent sat)
  "Stage 2: a factual, citable, wooden post for INTENT. Every number comes from
   the satisfaction-state; the [cite:…] anchor is the intent id. No AI."
  (let* ((gap  (intent-gap intent sat))
         (mag  (string-trim-right (comm-magnitude gap)))
         (subj (comm-subject intent))
         (cite (comm-citation intent)))
    (case (comm-kind intent)
      ((recruitment)
       (format #f "We need ~a of ~a — can you help? [cite:~a]" mag subj cite))
      ((mobilization)
       (format #f "We are ~a under the floor on ~a — step up? [cite:~a]" mag subj cite))
      ((resilience)
       (format #f "~a leans fragile (short ~a) — help diversify. [cite:~a]" subj mag cite))
      ;; ── broadcast kinds : no shortfall, so no number (sat is #f) ──
      ((offer)       (format #f "~a — available now. [cite:~a]" subj cite))
      ((proof)       (format #f "Done: ~a. [cite:~a]" subj cite))
      ((celebration) (format #f "~a. Thank you all. [cite:~a]" subj cite))
      ((education)   (format #f "Worth knowing: ~a. [cite:~a]" subj cite))
      (else ; call-to-action
       (format #f "Short ~a of ~a — can you bring some? [cite:~a]" mag subj cite)))))

;; ─── Stage 0→2 in one deterministic call : the campaign's skeletons ─────────
(define (plan->skeletons intents sat-states)
  "The whole deterministic pipeline in one fold: each under-satisfied intent →
   its factual, citable skeleton, in input order. No AI. This is the list a
   Stage-3 AI restyle then styles per channel, each fenced by entails-skeleton?."
  (let ((sat-of (lambda (i)
                  (find (lambda (s) (equal? (satisfaction-state-intent-id s)
                                            (intent-id i)))
                        sat-states))))
    (filter-map (lambda (i) (and (under-satisfied? i (sat-of i))
                                 (render-skeleton i (sat-of i))))
                intents)))

;; ─── Stage 3 fence : does an AI restyle PRESERVE the skeleton's facts? ───────
(define (%digit-runs s)
  "The maximal runs of digits in S, as strings (e.g. \"12\" \"52\")."
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (define (flush) (if (null? cur) acc (cons (list->string (reverse cur)) acc)))
    (cond ((null? cs) (reverse (flush)))
          ((char-numeric? (car cs)) (loop (cdr cs) (cons (car cs) cur) acc))
          (else (loop (cdr cs) '() (flush))))))

(define (%cite-token s)
  "The [cite:…] substring of S, or #f."
  (let ((i (string-contains s "[cite:")))
    (and i (let ((j (string-index s #\] i)))
             (and j (substring s i (+ j 1)))))))

(define (skeleton-fence-reason skeleton candidate)
  "Stage 3 fence, spelled out: #f when the AI CANDIDATE preserves SKELETON's
   facts — the citation token, every number, and NO new number — else one
   sentence naming what it broke. Deterministic. The sentence is what a re-ask
   quotes back to the model (playnet ai conform), so it names the facts, never
   the mechanism."
  (let* ((cite    (%cite-token skeleton))
         (sk-nums (%digit-runs skeleton))
         (ca-nums (%digit-runs candidate))
         ;; The citation is required present in the candidate, so its digit-runs
         ;; appear on both sides and cancel in the membership checks below.
         (dropped (filter (lambda (n) (not (member n ca-nums))) sk-nums))
         (added   (filter (lambda (n) (not (member n sk-nums))) ca-nums))
         (faults
          (filter identity
           (list (and cite (not (string-contains candidate cite))
                      (string-append "the citation token " cite " must appear exactly as given"))
                 (and (pair? dropped)
                      (string-append "these numbers from the message are missing and must be kept exactly: "
                                     (string-join dropped ", ")))
                 (and (pair? added)
                      (string-append "these numbers are not in the message and must not appear: "
                                     (string-join added ", ")))))))
    (and (pair? faults) (string-join faults "; "))))

(define (entails-skeleton? skeleton candidate)
  "Stage 3 fence: does the AI CANDIDATE preserve SKELETON's facts? The boolean
   face of skeleton-fence-reason; a fabricated fact ⇒ #f ⇒ the caller falls
   back to the dry skeleton."
  (not (skeleton-fence-reason skeleton candidate)))
