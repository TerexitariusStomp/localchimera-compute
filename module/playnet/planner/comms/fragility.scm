;;; comms/fragility.scm — channel fragility from VF rights vs custody.
;;;
;;; Design: docs/planning/faces/communications-recipes.md §7. A channel is a fragility
;;; not because of a TAG, but because of who holds the RIGHTS to it. ValueFlows
;;; separates two relationships an agent can have to a resource (docs/valueflows
;;; concepts/resources.md §"rights"/"custody", concepts/transfers.md), and
;;; deliberately avoids the word "ownership":
;;;   • primary-accountable — full (human-realm) rights & responsibilities; VF
;;;                           calls this stewardship, not ownership.
;;;   • custodian-scope     — custody / possession, irrespective of rights (the
;;;                           onhand side; transferCustody moves it without rights).
;;;
;;; A RENTED channel is exactly that split: the scope has CUSTODY (it can post)
;;; but is NOT the primary-accountable — an external agent (the platform) holds
;;; the rights and can revoke custody (deplatforming): the reefer-van fragility in
;;; the digital domain. A SOVEREIGN channel is one the scope is itself
;;; primary-accountable for; nobody can deplatform it. This is the SAME
;;; rights/custody test compliance.scm already uses (resource-held-by?), read off
;;; the held <economic-resource> — so no new machinery and no invented tag.
;;; Posting through a custodied-but-not-accountable channel draws down a finite
;;; fragility headroom, scored by the SAME frag φ = −w·log(s) the ecology uses.
;;;
;;; Load AFTER planner.scm (uses mk-frag / flatten / term-values).

;; The comms profile IS the general rented-fragility profile (schemas.scm) — a
;; channel is just one kind of rented resource, so there is one steepness, one tip,
;; for all; comms just gives them channel-facing names. The standalone scorer
;; (campaign-fragility) and the in-solve path (seed-channel-fragility!) both read
;; them, so they can never drift apart.
(define comms-rented-profile %rented-frag-profile)     ; ⇒ tip = 4 posts, weight = 1
(define comms-rented-weight (list-ref comms-rented-profile 3))
(define comms-rented-tip %rented-frag-tip)             ; quantile_alpha(lo,hi) — the shared frag tip

;; channel-rented?/channel-sovereign? are the comms-facing names for the GENERAL
;; tenure predicates (schemas.scm). A rented channel is just a rented resource —
;; deplatforming is owner-recall in the digital domain — so there is one predicate,
;; not a comms copy. Kept as aliases so the comms readers still speak of channels.
(define channel-rented? resource-rented?)
(define channel-sovereign? resource-sovereign?)

;; ─── the platform registry : who is primarily accountable for each channel ──
;; A platform's TENURE is the ground truth the fragility reads:
;;   rented    — cannot be self-hosted; the platform is always primary-accountable
;;               (X, Instagram, Threads — you can never own Meta/X).
;;   federated — either; sovereign IFF self-hosted (Mastodon, Bluesky).
;;   sovereign — always self-run (Reticulum, Radicle).
;; An UNKNOWN platform is assumed rented — fail-safe: price the fragility rather
;; than pretend safety, the same fail-closed posture as the publish gate.
(define (platform-tenure platform)
  (case platform
    ((x twitter instagram threads) 'rented)
    ((mastodon bluesky)            'federated)
    ((reticulum radicle)           'sovereign)
    (else                          'rented)))

(define (platform-org platform)
  "The external agent primarily accountable for a rented/hosted platform — the
   one who can deplatform you."
  (case platform
    ((x twitter)         "org:x")
    ((instagram threads) "org:meta")
    ((mastodon)          "org:mastodon-host")
    ((bluesky)           "org:bluesky")
    (else                "org:unknown-platform")))

;; channel-resource — the held channel account as a VF <economic-resource>. The
;; scope always CUSTODIES it (it operates the account); the primary-accountable is
;; the platform for a rented/hosted channel, or the scope itself when self-hosted.
;; This is the wiring that makes channel-rented? classify a REAL platform.
(define* (channel-resource id platform scope #:key (self-hosted? #f))
  (let* ((tenure (platform-tenure platform))
         (accountable (case tenure
                        ((sovereign) scope)
                        ((rented)    (platform-org platform))            ; never self-hostable
                        ((federated) (if self-hosted? scope (platform-org platform))))))
    (make-economic-resource
     #:id id #:name id
     #:conforms-to (string-append "spec:channel-" (symbol->string platform))   ; conforms-to
     #:classified-as '("infrastructure" "channel")                               ; classified-as (generic)
     #:primary-accountable accountable #:custodian-scope scope                                           ; primary-accountable, custodian-scope
)))

;; A campaign = list of (economic-resource . post-count). rented-draw = the posts
;; routed through channels the scope custodies but has no rights over — the
;; pressure on the fragility barrier. Sovereign channels draw nothing.
(define (rented-draw held-channels scope)
  (fold (lambda (e acc) (if (channel-rented? (car e) scope) (+ acc (cdr e)) acc))
        0 held-channels))

;; the `frag` form for a campaign's reliance on rights-less channels (draw baked
;; in as the coefficient; evaluated at x=1), and its headroom (slack = tip − draw).
(define (campaign-rented-form held-channels scope)
  (mk-frag comms-rented-tip
           (list (cons 0 (- (exact->inexact (rented-draw held-channels scope)))))
           comms-rented-weight))
(define (campaign-rented-slack held-channels scope)
  (vector-ref (term-values (flatten (list (campaign-rented-form held-channels scope)))
                           (vector 1.0)) 0))

;; φ = −w·log(s): the barrier's heat. Higher = more fragile; +inf past the tip
;; (leaning on channels you don't have rights to, past their headroom, is
;; deplatform-fatal).
(define (campaign-fragility held-channels scope)
  (let ((s (campaign-rented-slack held-channels scope)))
    (if (<= s 0.0) +inf.0 (* (- comms-rented-weight) (log s)))))

;; ─── build-located integration : DERIVE the frag caps from rights/custody ───
;; Rather than hand-place a frag barrier per rented channel, seed them from the
;; SAME channel-rented? test: every channel the scope custodies-but-does-not-own
;; gets a frag barrier on its Svc good at CELL, so a normal build-located solve
;; prices posting through it. Sovereign channels get none. SVC-NAME maps a channel
;; resource to the Svc good the publish recipe `use`s (its conforms-to by default).
(define* (seed-channel-fragility! scope channels cell
                                  #:key (profile comms-rented-profile)   ; same source of truth
                                        (svc-name economic-resource-conforms-to))
  (for-each
   (lambda (ch)
     (when (channel-rented? ch scope)
       (hash-set! *frag-cap* (lg (string-append "Svc|" (svc-name ch)) cell) profile)))
   channels))
