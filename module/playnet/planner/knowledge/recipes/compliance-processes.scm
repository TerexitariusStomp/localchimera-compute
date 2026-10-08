;;; compliance-processes.scm — the ProcessSpecification catalogue for compliance.
;;;
;;; Design: docs/planning/legal/legal-compliance-lifecycle.md §11–§13. Meeting the state
;;; is WORK — obtaining a permit, renewing it, filing a return, making a
;;; disclosure are each a Process that turns inputs (an application, a fee, admin
;;; labour) into outputs (the held credential, a filed return). So they are
;;; ordinary VF recipes, and this file is the reusable, jurisdiction-AGNOSTIC
;;; catalogue: four generic <process-specification>s and four builders that,
;;; given a demand, seed the concrete <recipe-process> + <recipe-flow>s. A new
;;; jurisdiction inherits the PROCESSES and only swaps the specs (which permit,
;;; which authority) + templates (legal/filings.scm) — nothing here is US-shaped.
;;;
;;; Where it sits in the lifecycle:
;;;   legal/filings.scm  render-filing   →  the application DOCUMENT ("filing")   ─┐
;;;   THIS file    obtain-permit   →  cites the application, works admin,    │
;;;                                    consumes a fee, PRODUCES the credential┘
;;;   compliance.scm holding-status → reads that credential as `satisfied`.
;;;
;;; And it makes compliance PLANNABLE: an obtain/renew process has a duration and
;;; a `spec-admin` work flow, so the planner can allocate administration hours to
;;; acquire exactly the permits a scope's bill (legal-demands) requires — the
;;; audit-intensity layer that reform.scm's dual power measures.
;;;
;;; Load legal/registry.scm before the bill-driven seeder (it reads `demand-name`,
;;; late-bound). Assumes schemas + a live ^recipe-store (the umbrella / a test).

;; ─── shared specs : the reusable inputs of compliance work ──────────────────
(define-module (playnet planner knowledge recipes compliance-processes)
  #:use-module (playnet planner legal registry)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:export (compliance-admin-skill-spec compliance-state-money-spec
            compliance-filing-spec %pspec compliance-process-specs
            seed-compliance-process-catalogue %str %rf-consume %rf-cite %rf-work
            %rf-produce %ensure-spec seed-obtain-permit-recipe seed-renew-recipe
            seed-file-return-recipe seed-disclose-recipe
            seed-compliance-recipes-for-bill))

(define compliance-admin-skill-spec
  (make-resource-specification #:id "spec-admin" #:name "Administration"
                               #:resource-classified-as '() #:default-unit-of-resource "hours"))
(define compliance-state-money-spec
  (make-resource-specification #:id "spec-state-money" #:name "State Money"
                               #:resource-classified-as '("fiat") #:default-unit-of-resource "unit"))
(define compliance-filing-spec        ; matches legal/filings.scm's document conforms-to "filing"
  (make-resource-specification #:id "filing" #:name "Filing Document"
                               #:resource-classified-as '("filing")
                               #:default-unit-of-resource "document"))

;; ─── the four generic ProcessSpecifications (the KINDS of compliance work) ──
(define (%pspec id name) (make-process-specification #:id id #:name name))
(define compliance-process-specs
  (list (%pspec "pspec-obtain-permit" "Obtain Permit")
        (%pspec "pspec-renew"         "Renew Credential")
        (%pspec "pspec-file-return"   "File Return")
        (%pspec "pspec-disclose"      "Disclose")))

(define (seed-compliance-process-catalogue recipe-store)
  "Register the shared specs + the four generic compliance ProcessSpecifications.
   Idempotent; call once per store before seeding concrete compliance recipes."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s))
            (list compliance-admin-skill-spec compliance-state-money-spec compliance-filing-spec))
  (for-each (lambda (ps) ($ recipe-store 'add-process-spec ps)) compliance-process-specs))

;; ─── flow + spec helpers (mirror food-surplus.scm's positional make-recipe-flow)
(define (%str . xs) (apply string-append xs))
(define (%rf-consume id spec q unit rp) (make-recipe-flow #:id id #:action 'consume
                                                          #:resource-conforms-to spec
                                                          #:resource-quantity (make-measure q unit)
                                                          #:recipe-input-of rp))
(define (%rf-cite    id spec q unit rp) (make-recipe-flow #:id id #:action 'cite   
                                                          #:resource-conforms-to spec
                                                          #:resource-quantity (make-measure q unit)
                                                          #:recipe-input-of rp))
(define (%rf-work    id skill hours rp) (make-recipe-flow #:id id #:action 'work   
                                                          #:resource-conforms-to skill
                                                          #:effort-quantity (make-measure hours "hours")
                                                          #:recipe-input-of rp))
(define (%rf-produce id spec q unit rp) (make-recipe-flow #:id id #:action 'produce
                                                          #:resource-conforms-to spec
                                                          #:resource-quantity (make-measure q unit)
                                                          #:recipe-output-of rp #:is-primary #t))
(define (%ensure-spec recipe-store id class unit)
  (unless ($ recipe-store 'get-resource-spec id)
    ($ recipe-store 'add-resource-spec
       (make-resource-specification #:id id #:name id #:resource-classified-as (list class)
                                    #:default-unit-of-resource unit))))

;; ─── OBTAIN a permit/licence : application + fee + admin → the credential ───
;; `permit-spec` is the demand-name (the credential's spec id — compliance.scm's
;; demand->spec-id join key). Produces exactly the resource holding-status finds.
(define* (seed-obtain-permit-recipe recipe-store #:key permit-spec authority
                                    (fee #f) (admin-hours 2.0) (id #f))
  (%ensure-spec recipe-store permit-spec "credential" "cert")
  (let ((rp (or id (%str "rp-obtain:" permit-spec))))
    ($ recipe-store 'add-recipe-process
       (make-recipe-process #:id rp #:name (%str "Obtain " permit-spec)
                            #:note (and authority (%str "issuer: " authority))
                            #:process-conforms-to "pspec-obtain-permit" #:has-duration (make-duration admin-hours "hours")))
    ($ recipe-store 'add-recipe-flow (%rf-cite (%str rp "/app") "filing" 1 "document" rp))
    ($ recipe-store 'add-recipe-flow (%rf-work (%str rp "/admin") "spec-admin" admin-hours rp))
    (when fee ($ recipe-store 'add-recipe-flow (%rf-consume (%str rp "/fee") "spec-state-money" fee "unit" rp)))
    ($ recipe-store 'add-recipe-flow (%rf-produce (%str rp "/out") permit-spec 1 "cert" rp))
    ($ recipe-store 'add-recipe
       (make-recipe #:id (%str "recipe-obtain:" permit-spec) #:name (%str "Obtain " permit-spec)
                    #:primary-output permit-spec #:recipe-processes (list rp)))
    rp))

;; ─── RENEW : the expiring credential + fee + admin → the extended credential ─
(define* (seed-renew-recipe recipe-store #:key permit-spec (fee #f) (admin-hours 1.0) (id #f))
  (%ensure-spec recipe-store permit-spec "credential" "cert")
  (let ((rp (or id (%str "rp-renew:" permit-spec))))
    ($ recipe-store 'add-recipe-process
       (make-recipe-process #:id rp #:name (%str "Renew " permit-spec)
                            #:process-conforms-to "pspec-renew" #:has-duration (make-duration admin-hours "hours")))
    ($ recipe-store 'add-recipe-flow (%rf-cite (%str rp "/old") permit-spec 1 "cert" rp))   ; the expiring one
    ($ recipe-store 'add-recipe-flow (%rf-work (%str rp "/admin") "spec-admin" admin-hours rp))
    (when fee ($ recipe-store 'add-recipe-flow (%rf-consume (%str rp "/fee") "spec-state-money" fee "unit" rp)))
    ($ recipe-store 'add-recipe-flow (%rf-produce (%str rp "/out") permit-spec 1 "cert" rp))   ; renewed
    ($ recipe-store 'add-recipe
       (make-recipe #:id (%str "recipe-renew:" permit-spec) #:name (%str "Renew " permit-spec)
                    #:primary-output permit-spec #:recipe-processes (list rp)))
    rp))

;; ─── FILE-RETURN : a levy (tax/duty) — admin + the payment → a filed return ──
(define* (seed-file-return-recipe recipe-store #:key levy (amount #f) (admin-hours 1.0) (id #f))
  (%ensure-spec recipe-store levy "return" "return")
  (let ((rp (or id (%str "rp-file:" levy))))
    ($ recipe-store 'add-recipe-process
       (make-recipe-process #:id rp #:name (%str "File " levy)
                            #:process-conforms-to "pspec-file-return" #:has-duration (make-duration admin-hours "hours")))
    ($ recipe-store 'add-recipe-flow (%rf-work (%str rp "/admin") "spec-admin" admin-hours rp))
    (when amount ($ recipe-store 'add-recipe-flow (%rf-consume (%str rp "/pay") "spec-state-money" amount "unit" rp)))
    ($ recipe-store 'add-recipe-flow (%rf-produce (%str rp "/out") levy 1 "return" rp))
    ($ recipe-store 'add-recipe
       (make-recipe #:id (%str "recipe-file:" levy) #:name (%str "File " levy) #:primary-output levy
                    #:recipe-processes (list rp)))
    rp))

;; ─── DISCLOSE : a tell — the facts + admin → a filed disclosure record ──────
(define* (seed-disclose-recipe recipe-store #:key disclosure (admin-hours 0.5) (id #f))
  (%ensure-spec recipe-store disclosure "disclosure" "disclosure")
  (let ((rp (or id (%str "rp-disclose:" disclosure))))
    ($ recipe-store 'add-recipe-process
       (make-recipe-process #:id rp #:name (%str "Disclose " disclosure)
                            #:process-conforms-to "pspec-disclose" #:has-duration (make-duration admin-hours "hours")))
    ($ recipe-store 'add-recipe-flow (%rf-cite (%str rp "/facts") "filing" 1 "document" rp))
    ($ recipe-store 'add-recipe-flow (%rf-work (%str rp "/admin") "spec-admin" admin-hours rp))
    ($ recipe-store 'add-recipe-flow (%rf-produce (%str rp "/out") disclosure 1 "disclosure" rp))
    ($ recipe-store 'add-recipe
       (make-recipe #:id (%str "recipe-disclose:" disclosure) #:name (%str "Disclose " disclosure)
                    #:primary-output disclosure #:recipe-processes (list rp)))
    rp))

;; ─── the payoff : seed the whole compliance metabolism FROM a demand bill ───
;; Feed it a legal-demands bill and it seeds one compliance recipe per demand —
;; obtain for every credential, file-return for every levy, disclose for every
;; tell. "Give me the compliance work-recipes for jurisdiction X" is then a fold
;; over X's bill; a new jurisdiction supplies only its rules + templates.
;; → the list of recipe-process ids seeded.
(define* (seed-compliance-recipes-for-bill recipe-store bill
                                           #:key (authority #f) (fee #f) (admin-hours 2.0))
  (seed-compliance-process-catalogue recipe-store)
  (append
   (map (lambda (d) (seed-obtain-permit-recipe recipe-store #:permit-spec (demand-name d)
                                               #:authority authority #:fee fee #:admin-hours admin-hours))
        (append (bill-ref bill 'obtain-entity) (bill-ref bill 'obtain-person)))
   (map (lambda (d) (seed-file-return-recipe recipe-store #:levy (demand-name d) #:admin-hours 1.0))
        (bill-ref bill 'pay))
   (map (lambda (d) (seed-disclose-recipe recipe-store #:disclosure (demand-name d) #:admin-hours 0.5))
        (bill-ref bill 'tell))))
