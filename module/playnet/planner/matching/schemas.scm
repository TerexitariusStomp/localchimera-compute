;;; matching/schemas.scm — Sidecar records for the matching layer.
;;;
;;; The matcher operates on VF records from (playnet planner):
;;;   <intent>, <proposal>, <commitment>, <agreement>, <agent>,
;;;   <availability-window>, <measure>, <spatial-thing>.
;;;
;;; This module defines ONLY what VF can't express:
;;;
;;;   <skill>                    — competence reference (ESCO URI etc.)
;;;   <agent-profile>            — sidecar on <agent>; carries public-key
;;;                                (DID material) + skills. agent-id is
;;;                                the same string as <agent>.id.
;;;   <intent-matching-criteria> — sidecar on <intent>; carries
;;;                                matcher-only fields (h3 hints,
;;;                                throughput limits, scheduling buffers,
;;;                                priority). intent-id is the same
;;;                                string as <intent>.id.
;;;                                Spatial fact (where) lives on the
;;;                                <spatial-thing> referenced by
;;;                                <intent>.at-location; the matcher
;;;                                does NOT denorm those onto criteria.
;;;   <intent-binding>           — an <intent> together with everything
;;;                                the matcher uses that VF expresses
;;;                                by ID reference: the resolved
;;;                                <spatial-thing> for at-location, the
;;;                                <agent-profile> for provider/receiver,
;;;                                the criteria sidecar, recognition
;;;                                weights, and an optional prior
;;;                                <commitment> for travel scoring.
;;;                                (This is the record the pre-VF code
;;;                                called <match-side>. Whether a side
;;;                                is "need-like" or "offer-like" is
;;;                                read off intent.action via
;;;                                input-action? / output-action?.)
;;;   <feasibility-scores>       — 7-dim analytical scoring output.
;;;   <feasibility-status>       — possible/impossible discriminator.

(define-module (playnet planner matching schemas)
  #:use-module (srfi srfi-9)
  #:export (<skill> make-skill skill?
            skill-id skill-name skill-category skill-level

            <agent-profile> make-agent-profile agent-profile?
            agent-profile-agent-id agent-profile-public-key
            agent-profile-skills

            <intent-matching-criteria>
            make-intent-matching-criteria
            intent-matching-criteria-filter-rule
            intent-matching-criteria?
            intent-matching-criteria-intent-id
            intent-matching-criteria-h3-resolution
            intent-matching-criteria-search-radius-km
            intent-matching-criteria-online-link
            intent-matching-criteria-min-atomic-size
            intent-matching-criteria-max-participation
            intent-matching-criteria-max-concurrency
            intent-matching-criteria-min-calendar-duration
            intent-matching-criteria-advance-notice-hours
            intent-matching-criteria-booking-window-hours
            intent-matching-criteria-time-zone
            intent-matching-criteria-required-skills
            intent-matching-criteria-priority
            intent-matching-criteria-priority-distribution

            <intent-binding>
            make-intent-binding
            intent-binding?
            intent-binding-intent
            intent-binding-criteria
            intent-binding-agent
            intent-binding-weights
            intent-binding-location
            intent-binding-prior
            intent-binding-prior-location

            <feasibility-scores> make-feasibility-scores feasibility-scores?
            feasibility-scores-time feasibility-scores-location
            feasibility-scores-skills feasibility-scores-travel
            feasibility-scores-resources feasibility-scores-affinity
            feasibility-scores-continuity
            make-perfect-feasibility-scores

            <feasibility-status> make-feasibility-status feasibility-status?
            feasibility-status-kind feasibility-status-confidence
            feasibility-status-risk-factors feasibility-status-reasons
            feasibility-status-scores
            feasibility-possible? feasibility-impossible?

            *default-h3-resolution*
            *default-search-radius-km*
            *remote-h3-index*
            *h3-edge-lengths-km*
            *h3-areas-km2*

            *input-actions*
            *output-actions*
            input-action?
            output-action?))


;;; ── VF action discrimination ───────────────────────────────────────────────
;;;
;;; Two halves of every VF economic event: the side that *receives*
;;; the resource flow (input — consume/use/accept) and the side that
;;; *emits* it (output — produce/deliver-service). Both sides are
;;; <intent>s; the distinction is purely in the action field.

(define *input-actions*  '(consume use accept))
(define *output-actions* '(produce deliver-service))

(define (input-action?  a) (and (symbol? a) (memq a *input-actions*)  #t))
(define (output-action? a) (and (symbol? a) (memq a *output-actions*) #t))


;;; ── Skill ──────────────────────────────────────────────────────────────────

(define-record-type <skill>
  (make-skill id name category level)
  skill?
  (id       skill-id)
  (name     skill-name)
  (category skill-category)
  (level    skill-level))


;;; ── AgentProfile (sidecar on VF <agent>) ───────────────────────────────────

(define-record-type <agent-profile>
  (make-agent-profile agent-id public-key skills)
  agent-profile?
  (agent-id   agent-profile-agent-id)
  (public-key agent-profile-public-key)
  (skills     agent-profile-skills))


;;; ── IntentMatchingCriteria (sidecar on VF <intent>) ────────────────────────
;;;
;;; Holds matcher-only fields. SPATIAL FACTS LIVE ELSEWHERE:
;;;   - WHERE this intent is (lat/lng/address) → <spatial-thing>
;;;     referenced by intent.at-location, carried on <intent-binding>
;;;     by intent-binding-location.
;;;   - H3 cell id → computed on demand from spatial-thing.lat/lng +
;;;     h3-resolution. Not stored.
;;;
;;; The only spatial field kept here is `online-link` (a URL), which
;;; has no VF analogue and is not a property of a physical location.

(define-record-type <intent-matching-criteria>
  (make-intent-matching-criteria
   intent-id
   h3-resolution search-radius-km online-link
   min-atomic-size max-participation max-concurrency min-calendar-duration
   advance-notice-hours booking-window-hours time-zone
   required-skills
   priority priority-distribution
   filter-rule)
  intent-matching-criteria?
  (intent-id             intent-matching-criteria-intent-id)
  (h3-resolution         intent-matching-criteria-h3-resolution)
  (search-radius-km      intent-matching-criteria-search-radius-km)
  (online-link           intent-matching-criteria-online-link)
  (min-atomic-size       intent-matching-criteria-min-atomic-size)
  (max-participation     intent-matching-criteria-max-participation)
  (max-concurrency       intent-matching-criteria-max-concurrency)
  (min-calendar-duration intent-matching-criteria-min-calendar-duration)
  (advance-notice-hours  intent-matching-criteria-advance-notice-hours)
  (booking-window-hours  intent-matching-criteria-booking-window-hours)
  (time-zone             intent-matching-criteria-time-zone)
  (required-skills       intent-matching-criteria-required-skills)
  (priority              intent-matching-criteria-priority)
  (priority-distribution intent-matching-criteria-priority-distribution)
  ;; the ELIGIBILITY rule (matching/filter-rule.scm): who this slot may be
  ;; paired with, evaluated bilaterally before any pairing; #f = anyone
  (filter-rule           intent-matching-criteria-filter-rule))


;;; ── IntentBinding ──────────────────────────────────────────────────────────
;;; A VF <intent> plus everything the matcher needs that VF expresses
;;; by ID reference — no denorms of fields that already live on the
;;; intent itself.
;;;
;;;   intent          — VF <intent>           (REQUIRED)
;;;                     The desire being matched. Input- vs
;;;                     output-action is read off intent.action.
;;;   criteria        — <intent-matching-criteria> | #f
;;;                     Matcher-only sidecar; same intent-id as intent.
;;;   agent           — <agent-profile> | #f
;;;                     Profile sidecar for the agent on this side
;;;                     (provider for output-actions, receiver for input).
;;;   weights         — alist (pubkey . [0,1]) | #f
;;;                     Recognition table this side holds; used to
;;;                     score how much THIS side trusts the OTHER side.
;;;   location        — VF <spatial-thing> | #f
;;;                     The spatial-thing referenced by
;;;                     intent.at-location, resolved by the caller.
;;;                     lat/lng/address all live on this record.
;;;   prior           — VF <commitment> | #f
;;;                     A previous commitment whose end this side is
;;;                     transitioning from. Used by travel-score on
;;;                     output-action sides.
;;;   prior-location  — VF <spatial-thing> | #f
;;;                     The spatial-thing referenced by
;;;                     prior.at-location, resolved by the caller.

(define-record-type <intent-binding>
  (make-intent-binding* intent criteria agent weights
                        location prior prior-location)
  intent-binding?
  (intent         intent-binding-intent)
  (criteria       intent-binding-criteria)
  (agent          intent-binding-agent)
  (weights        intent-binding-weights)
  (location       intent-binding-location)
  (prior          intent-binding-prior)
  (prior-location intent-binding-prior-location))

(define* (make-intent-binding intent
                              #:key criteria agent weights
                                    location prior prior-location)
  (make-intent-binding* intent criteria agent weights
                        location prior prior-location))


;;; ── FeasibilityScores ──────────────────────────────────────────────────────

(define-record-type <feasibility-scores>
  (make-feasibility-scores time location skills travel
                           resources affinity continuity)
  feasibility-scores?
  (time       feasibility-scores-time)
  (location   feasibility-scores-location)
  (skills     feasibility-scores-skills)
  (travel     feasibility-scores-travel)
  (resources  feasibility-scores-resources)
  (affinity   feasibility-scores-affinity)
  (continuity feasibility-scores-continuity))

(define (make-perfect-feasibility-scores)
  (make-feasibility-scores 1.0 1.0 1.0 1.0 1.0 1.0 1.0))


;;; ── FeasibilityStatus ──────────────────────────────────────────────────────

(define-record-type <feasibility-status>
  (make-feasibility-status kind confidence risk-factors reasons scores)
  feasibility-status?
  (kind         feasibility-status-kind)
  (confidence   feasibility-status-confidence)
  (risk-factors feasibility-status-risk-factors)
  (reasons      feasibility-status-reasons)
  (scores       feasibility-status-scores))

(define (feasibility-possible? s)
  (and (feasibility-status? s) (eq? (feasibility-status-kind s) 'possible)))

(define (feasibility-impossible? s)
  (and (feasibility-status? s) (eq? (feasibility-status-kind s) 'impossible)))


;;; ── Constants ──────────────────────────────────────────────────────────────

(define *default-h3-resolution*    7)
(define *default-search-radius-km* 50)
(define *remote-h3-index*          "remote")

(define *h3-edge-lengths-km*
  '#(1107.71 418.68 158.24 59.81 22.61 8.54 3.23 1.22
     0.461 0.174 0.066 0.025 0.009 0.003 0.001 0.0005))

(define *h3-areas-km2*
  '#(4250547.0 607220.0 86745.0 12393.0 1770.0 252.9 36.1 5.16
     0.74 0.10 0.015 0.002 0.0003 0.00004 0.000006 0.0000009))
