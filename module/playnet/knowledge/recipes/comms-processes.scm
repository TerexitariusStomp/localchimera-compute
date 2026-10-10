;;; comms-processes.scm — the two production recipes for social posting.
;;;
;;; Design: docs/planning/faces/communications-recipes.md §6. A post is DIGITAL
;;; PRODUCTION on the infrastructure.scm lineage — NOT the compliance/permit
;;; lineage. Two ordinary VF recipes:
;;;
;;;   compose-post :  use(inference) + cite(announced-fact) → produce(draft)
;;;   publish-post :  use(channel)   + cite(draft)          → produce(published)
;;;
;;; compose IS Stage 3 of the comms pipeline (comms.scm renders the Stage-2
;;; skeleton; the AI only restyles it, fenced by entails-skeleton?). publish is
;;; the tail. A channel is `use`d infrastructure (occupied then released) — no
;;; account ⇒ the use flow is unsatisfiable ⇒ that channel's publish fills 0.
;;; That is scarcity, not permitting. Whether a channel is rented (revocable) or
;;; sovereign is a fact about the HELD resource — does the scope hold the rights
;;; (primary-accountable) or only custody? — read by comms/fragility.scm, so
;;; channel concentration surfaces on the fragility barrier with no new machinery.
;;;
;;; Assumes schemas ((playnet vf schemas)) + a live ^recipe-store.

;; ─── Resource specifications (infrastructure.scm idiom — 11 positional) ──────
(define-module (playnet knowledge recipes comms-processes)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:export (comms-inference-spec comms-fact-spec comms-draft-spec comms-published-spec
            comms-channel-x-spec comms-channel-reticulum-spec comms-resource-specs
            comms-process-specs seed-comms-process-catalogue %rf-use %rf-cite %rf-prod
            seed-compose-post-recipe seed-publish-recipe seed-comms-campaign))

(define comms-inference-spec            ; inference is compute (cf. spec:compute)
  (make-resource-specification
    #:id "spec:inference" #:name "LLM inference"
    #:resource-classified-as '("infrastructure" "compute" "ai") #:default-unit-of-resource "completions"))

(define comms-fact-spec                 ; the announced fact — cited, not consumed
  (make-resource-specification
    #:id "spec:announced-fact" #:name "Announced fact"
    #:resource-classified-as '("knowledge" "claim") #:default-unit-of-resource %count-unit))

(define comms-draft-spec                ; the compose output
  (make-resource-specification
    #:id "spec:post-draft" #:name "Post draft"
    #:resource-classified-as '("content" "text") #:default-unit-of-resource "post"))

(define comms-published-spec            ; the deliverable
  (make-resource-specification
    #:id "spec:published-post" #:name "Published post"
    #:resource-classified-as '("content" "published") #:default-unit-of-resource %count-unit))

;; Two example channels. The spec is generic — the KIND of channel. Whether a
;; channel is rented (revocable) or sovereign is NOT a spec tag: it is a fact
;; about the held <economic-resource> — does the scope hold the RIGHTS
;; (primary-accountable) or merely CUSTODY? comms/fragility.scm reads those VF
;; fields, the same rights/custody test compliance.scm uses. So an X account
;; conforming to spec:channel-x has primary-accountable = the platform (rented);
;; a self-hosted instance conforming to spec:channel-reticulum has
;; primary-accountable = the scope (sovereign).
(define comms-channel-x-spec
  (make-resource-specification
    #:id "spec:channel-x" #:name "X/Twitter channel"
    #:resource-classified-as '("infrastructure" "channel") #:default-unit-of-resource "post-slot"))
(define comms-channel-reticulum-spec
  (make-resource-specification
    #:id "spec:channel-reticulum" #:name "Reticulum broadcast"
    #:resource-classified-as '("infrastructure" "channel") #:default-unit-of-resource "post-slot"))

(define comms-resource-specs
  (list comms-inference-spec comms-fact-spec comms-draft-spec comms-published-spec
        comms-channel-x-spec comms-channel-reticulum-spec))

;; ─── the two ProcessSpecifications ──────────────────────────────────────────
(define comms-process-specs
  (list (make-process-specification #:id "pspec:compose-post" #:name "Compose Post")
        (make-process-specification #:id "pspec:publish-post" #:name "Publish Post")))

(define (seed-comms-process-catalogue recipe-store)
  "Register the comms resource specs + the two ProcessSpecifications. Idempotent;
   call once per store before seeding the compose / publish recipes."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s)) comms-resource-specs)
  (for-each (lambda (ps) ($ recipe-store 'add-process-spec ps)) comms-process-specs))

;; ─── flow helpers (mirror compliance-processes.scm's positional make-recipe-flow)
(define (%rf-use   id spec q unit rp) (make-recipe-flow #:id id #:action 'use    
                                                        #:resource-conforms-to spec
                                                        #:resource-quantity (make-measure q unit)
                                                        #:recipe-input-of rp))
(define (%rf-cite  id spec q unit rp) (make-recipe-flow #:id id #:action 'cite   
                                                        #:resource-conforms-to spec
                                                        #:resource-quantity (make-measure q unit)
                                                        #:recipe-input-of rp))
(define (%rf-prod  id spec q unit rp) (make-recipe-flow #:id id #:action 'produce
                                                        #:resource-conforms-to spec
                                                        #:resource-quantity (make-measure q unit)
                                                        #:recipe-output-of rp #:is-primary #t))

;; ─── COMPOSE : use inference + cite the announced fact → a draft ────────────
(define* (seed-compose-post-recipe recipe-store #:key (id "rp:compose"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id id #:name "Compose a post"
                          #:process-conforms-to "pspec:compose-post" #:has-duration (make-duration 0.1 %effort-unit)))
  ($ recipe-store 'add-recipe-flow (%rf-use  (string-append id "/infer") "spec:inference"      1 "completions" id))
  ($ recipe-store 'add-recipe-flow (%rf-cite (string-append id "/fact")  "spec:announced-fact" 1 "each"        id))
  ($ recipe-store 'add-recipe-flow (%rf-prod (string-append id "/out")   "spec:post-draft"     1 "post"        id))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe:compose" #:name "Compose a post" #:primary-output "spec:post-draft"
                  #:recipe-processes (list id)))
  id)

;; ─── PUBLISH : use a channel + cite the draft → a published post ────────────
;; One recipe PER channel — same draft, different `use`d channel. A campaign that
;; reaches N channels is N publish processes over one draft.
(define* (seed-publish-recipe recipe-store #:key channel-spec (id #f))
  (let ((rp (or id (string-append "rp:publish:" channel-spec))))
    ($ recipe-store 'add-recipe-process
       (make-recipe-process #:id rp #:name (string-append "Publish to " channel-spec)
                            #:process-conforms-to "pspec:publish-post" #:has-duration (make-duration 0.05 %effort-unit)))
    ($ recipe-store 'add-recipe-flow (%rf-use  (string-append rp "/chan")  channel-spec      1 "post-slot" rp))
    ($ recipe-store 'add-recipe-flow (%rf-cite (string-append rp "/draft") "spec:post-draft" 1 "post"      rp))
    ($ recipe-store 'add-recipe-flow (%rf-prod (string-append rp "/out")   "spec:published-post" 1 "each"  rp))
    ($ recipe-store 'add-recipe
       (make-recipe #:id (string-append "recipe:publish:" channel-spec)
                    #:name (string-append "Publish to " channel-spec)
                    #:primary-output "spec:published-post" #:recipe-processes (list rp)))
    rp))

;; ─── the payoff : a whole campaign is compose + one publish per channel ─────
(define* (seed-comms-campaign recipe-store #:key (channels '("spec:channel-x" "spec:channel-reticulum")))
  "Seed the catalogue, the compose recipe, and one publish recipe per channel.
   → (list compose-rp publish-rp …), the fan-out for one draft across channels."
  (seed-comms-process-catalogue recipe-store)
  (cons (seed-compose-post-recipe recipe-store)
        (map (lambda (ch) (seed-publish-recipe recipe-store #:channel-spec ch)) channels)))
