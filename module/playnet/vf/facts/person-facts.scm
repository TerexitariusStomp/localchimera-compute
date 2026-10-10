;;; person-facts.scm — what a person states about themselves, and where it lives.
;;;
;;; A citizen belongs to the federation; a scope is a gateway they connect
;;; through. The facts a person states ABOUT THEMSELVES — what they need, what
;;; they can lend, when they can work, the skills they hold, who they are,
;;; where they are, the places they name and the dwelling they live in — are
;;; read by every fold above the scope as quantities, so each lives at ONE
;;; scope, the person's home (docs/planning/federation/federation-identity-and-folds.md).
;;;
;;; What two parties do together lives where it was done. A work offer, an
;;; accepted assignment, a journey, a purchase, a count and a payout are each
;;; a commitment or an event between a person and a scope, keyed by its own id,
;;; so no fold counts one twice; a willingness is a person's word about one
;;; scope's open cell. A claim is made where the plan holds it: the plan is
;;; made where the need is, which is the home, so the claim doors are the
;;; person's.
;;;
;;; This module is the one place that says which is which:
;;;   • the ids a person's facts carry (builders and the matching tests),
;;;   • the doors that write them (`person-write-doors`, routed to the home),
;;;     the doors that read them (`person-read-doors`), and the doors that act
;;;     at the scope the call names (`scope-subject-doors`).
;;; tests/doors/test-person-doors.scm refuses a planner door that takes a
;;; person in its second place and is in none of the three lists.

(define-module (playnet vf facts person-facts)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf schemas) #:select (intent-id intent-finished intent-receiver make-resource-specification))
  #:export (need-id need-prefix need-id? declared-need?
            means-id means-prefix means-id?
            skill-id generic-skill-id skill-spec generic-labour-spec generic-labour-spec-id
            person-place-id person-place-prefix dwelling-id
            position-key position-key? position-prefix
            location-share-key location-modes fix-lease-seconds fix-fresh?
            person-write-doors person-read-doors scope-subject-doors
            home-row home-row-aid
            person-argument-position person-door-argument?))

;; ── the ids ────────────────────────────────────────────────────────────────
(define (need-prefix aid) (string-append "need:" aid ":"))
(define (need-id aid spec) (string-append (need-prefix aid) spec))
(define (need-id? id) (and (string? id) (string-prefix? "need:" id)))

;; What counts as a citizen's declared need — asked in exactly ONE place, so
;; the incremental fold, the full re-read and the partition guard cannot come
;; to differ about it: the id says it was declared on the share face (and not
;; a work intent, a materialized suggestion, an invitation), it stands, and it
;; has a receiver.
(define (declared-need? i)
  (and (not (intent-finished i))
       (intent-receiver i)
       (need-id? (intent-id i))
       #t))

(define (means-prefix aid) (string-append "means:" aid ":"))
(define (means-id aid spec) (string-append (means-prefix aid) spec))
(define (means-id? id) (and (string? id) (string-prefix? "means:" id)))

;; a declared skill, and the generic labour skill an offer of time seeds
(define (skill-id aid spec) (string-append "skill:" aid ":" spec))
(define (generic-skill-id aid) (string-append "skill-" aid "-labor"))
;; The generic labour every person can work, as the spec it is: a worked spec
;; states its unit of effort (formulas/actions labour-specs reads that field), so
;; an offer of time seeds this spec beside the person's skill resource and the
;; roster, the solve and the holders table all read the hours as labour.
(define (skill-spec id)
  "The spec a declared skill ID conforms to, as a WORKED spec: a person is its
   stock, hours its effort. Declared into the scope's store when the store
   holds no spec of that id (declare-skill!), so a skill a person states is
   labour by the record's own word, recipe or no recipe."
  (make-resource-specification #:id id #:name id
                               #:default-unit-of-resource "person" #:default-unit-of-effort %effort-unit))
(define generic-labour-spec-id "spec-labor")
(define generic-labour-spec (skill-spec generic-labour-spec-id))

;; a place the person names (`here`, `home`, a slug) and the dwelling they live in
(define (person-place-prefix aid) (string-append "place:" aid ":"))
(define (person-place-id aid name) (string-append (person-place-prefix aid) name))
(define (dwelling-id aid) (string-append "dwelling:" aid))

;; a person's home is a plan-store meta row at the scope: `home:AID`
(define (home-row aid) (string-append "home:" aid))
(define (home-row-aid key)               ; the AID a `home:` row key names, else #f
  (and (string? key) (string-prefix? "home:" key) (substring key 5)))

;; where the person is at a period (0 = now): a plan-store meta row
(define (position-prefix aid) (string-append "pos|" aid "|"))
(define (position-key aid period) (string-append (position-prefix aid) (number->string period)))
(define (position-key? key) (and (string? key) (string-prefix? "pos|" key)))

;; Whether a person shares where they are: a plan-store meta row at the home,
;; `((mode . live|here|off) (at . instant))`. A fix is a LEASE: it counts for
;; FIX-LEASE-SECONDS from the instant it was sent, so a page that is closed
;; ends its own sharing; a place declared for a later period counts for that
;; period and carries no lease.
(define (location-share-key aid) (string-append "location-share:" aid))
(define location-modes '(live here off))
(define fix-lease-seconds 1200)
(define (fix-fresh? at now)
  (and (number? at) (<= (- now at) fix-lease-seconds)))

;; ── the doors ──────────────────────────────────────────────────────────────
;; Second argument a person, subject that person's standing: a write lands at
;; the home whichever scope the call names.
(define person-write-doors
  '(set-position set-position-latlon set-location-sharing set-home declare-place declare-dwelling
    claim record-claim
    set-availability set-availability-ranges set-profile
    declare-skill revoke-skill declare-means retire-means
    declare-need retire-need))

;; the same persons' standing read back: asked of the home, so the answer is whole
(define person-read-doors '(my-skills my-slots skill-standing location-sharing my-claims))

;; A person named, subject the call's scope: a commitment, an event or a word
;; made THERE (work, assignments, effort, journeys, purchases, counts, drops,
;; chat, payouts, willingness, witnessing, the kinds a scope ratifies), and the
;; doors that manage the home itself (`home-of`, `move-home`, `our-slots`).
(define scope-subject-doors
  '(witness-open witness-inbox witness-attest
    journey-begin journey-end express-willingness
    count-commitment-of plan-counts count-history label-stock read-label
    log-observe count-stock read-condition credit-balance
    invite-contact accept-invite
    offer-work accept-work-offer release-commitment
    accept-assignment decline-assignment record-effort drop-event chat-post
    home-of move-home
    request-payout my-payouts retire-payout
    record-purchase ratify-kind audit-kinds our-slots
    scope-replica))                    ; the scope's books copied to the asking member's device

;; Where a door takes its person, 1-based, the scope being first: the second
;; place unless the table says otherwise (`claim` names what is claimed first).
(define %person-argument-positions '((claim . 4)))
(define (person-argument-position door)
  (or (assq-ref %person-argument-positions door) 2))

;; the argument names that stand for a person, wherever a door takes one
(define (person-door-argument? sym)
  (and (memq sym '(agent-id aid worker inviter claimant acting-as agent)) #t))
