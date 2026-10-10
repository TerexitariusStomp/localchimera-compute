;;; test-temporary-socialization.scm — a person temporarily socializes a personal
;;; resource into a commune's use-pool: custody moves, rights stay, the grant is
;;; window-bounded, and it reverts on lapse or owner recall. NOT a sale.

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner facts validity) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))       ; custody-cred-live?, spawn-scope-root
(use-modules (playnet governance acdc-bridge) (playnet governance auditor) (playnet credentials commitments) (playnet credentials custody) (playnet keri acdc) (playnet governance scope) (playnet governance socialization) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins))
(use-modules (srfi srfi-1))

(define OWNER   "EAlice")        ; the person, keeps ownership throughout
(define COMMUNE "ECommune")      ; the scope that receives custody for a window
(define SPEC    "spec:cargo-bike")
(define FUTURE  "2099-12-31T00:00:00Z")
(define PAST    "2000-01-01T00:00:00Z")


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The grant: custody to the commune, rights retained (not a sale)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Socialize = usufruct grant, not a sale ──\n")

(let ((att (socialize-private-resource #f OWNER COMMUNE SPEC 1 #:until FUTURE)))
  (check-pred "issuer = owner (the grantor)" (equal? OWNER (cred-issuer att)))
  (check-pred "holder = commune (the custodian)" (equal? COMMUNE (cred-holder att)))
  ;; A CUSTODY attestation — never a transfer-all-rights — so ownership
  ;; (accountingQuantity / primaryAccountable) is untouched by construction.
  (check-pred "custody schema (rights untouched)"
              (equal? *schema-playnet-custody-attestation* (cred-schema att)))
  (check-pred "quantity socialized" (= 1 (cred-claim att 'qty)))
  (check-pred "resource-spec" (equal? SPEC (cred-claim att 'resource-spec)))
  (check-pred "return-by window set" (equal? FUTURE (cred-claim att 'valid-until)))
  (check-pred "grant carries a recall id" (string? (cred-said att))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. The window: live inside it, reverts when it lapses
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. The grant is window-bounded (custody-cred-live?) ──\n")

(let ((in-window  (socialize-private-resource #f OWNER COMMUNE SPEC 1 #:until FUTURE))
      (lapsed     (socialize-private-resource #f OWNER COMMUNE SPEC 1 #:until PAST))
      (open-ended (socialize-private-resource #f OWNER COMMUNE SPEC 1)))
  (check-pred "live inside the window" (custody-cred-live? in-window))
  (check-pred "open-ended grant is live" (custody-cred-live? open-ended))
  ;; Past return-by ⇒ not live ⇒ the commune's plan stops seeing it: custody
  ;; has reverted to the owner without any further act (the paper's "expires
  ;; rather than vests").
  (check-pred "lapsed grant is not live (custody reverted)"
              (not (custody-cred-live? lapsed))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Early recall: delegator-owned revocation (no recall ceremony)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Owner recalls early; a stranger cannot ──\n")

(define vat (spawn-vat))

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (att   (socialize-private-resource store OWNER COMMUNE SPEC 1
                                             #:until FUTURE))
         (said  (cred-said att)))
    (check-pred "grant live in store before recall"
                (any (lambda (c) (equal? said (cred-said c)))
                     (non-revoked-by-schema store
                                            *schema-playnet-custody-attestation*)))
    ;; A stranger cannot recall the owner's grant.
    (check-pred "non-owner recall is refused"
                (catch #t
                  (lambda () (desocialize-private-resource! store "EMallory" said) #f)
                  (lambda _ #t)))
    ;; The owner recalls: custody returns immediately.
    (desocialize-private-resource! store OWNER said)
    (check-pred "grant revoked after owner recall"
                (not (any (lambda (c) (equal? said (cred-said c)))
                          (non-revoked-by-schema
                           store *schema-playnet-custody-attestation*))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Passive expiry: the half-life watcher reverts custody to the OWNER
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Window lapse → watcher reverts to the granting owner ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Commune"))
         (scope (spawn-scope "Commune"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid COMMUNE
                             #:acdc-store store))
         ;; A grant whose window has already lapsed (issued directly so the test
         ;; needs no clock movement).
         (att   (socialize-private-resource store OWNER COMMUNE SPEC 1
                                             #:from PAST #:until PAST))
         (said  (cred-said att))
         ;; Reverter returns custody to the granting owner, not a commons pool.
         (watcher (spawn-custody-half-life-watcher
                   scope (socialization-owner-reverter store)
                   #:watcher-aid "EWatch"))
         (results ($ watcher 'tick!)))
    (check-pred "one lapsed grant processed" (= 1 (length results)))
    (let* ((rev-said (cdr (car results)))
           (revs ($ store 'by-schema *schema-playnet-reversion-attestation*))
           (rev  (find (lambda (c) (equal? rev-said (cred-said c))) revs)))
      (check-pred "reversion issued" (not (not rev)))
      (check-pred "custody reverted to the OWNER" (equal? OWNER (cred-holder rev)))
      (check-pred "reversion points back at the lapsed grant"
                  (equal? said (edge-target (cred-edge rev 'reverted-from))))
      (check-pred "lapsed grant now revoked"
                  (cred-revoked?
                   (find (lambda (c) (equal? said (cred-said c)))
                         ($ store 'by-schema
                            *schema-playnet-custody-attestation*)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Governance → live solve: a live grant contributes use-capacity
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. commune-socialized-caps: live grant → Svc capacity ──\n")

;; The durable as the commune's books see it once the bridge has set custody:
;; primary-accountable = OWNER (rights kept), custodian-scope = COMMUNE (custody
;; granted), located at "town".
(define bike
  (make-economic-resource #:id "res:bike1" #:name "cargo bike"
                          #:conforms-to SPEC #:classified-as '() #:onhand-quantity (make-measure 1 %count-unit)
                          #:current-location "town" #:primary-accountable OWNER          ; current-location, primary-accountable
                          #:custodian-scope COMMUNE))  ; custodian-scope = COMMUNE

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (att   (socialize-private-resource store OWNER COMMUNE SPEC 20 #:until FUTURE))
         (caps  (commune-socialized-caps store COMMUNE (list bike) '(0))))
    (check-pred "live grant yields one Svc cap" (= 1 (length caps)))
    (check-pred "cap keyed at the durable's cell (Svc|spec#place@0)"
                (equal? (caar caps) (string-append "Svc|" SPEC "#town@0")))
    (check-pred "cap = per-period service lent (20)" (= 20 (cdar caps)))
    ;; Owner recalls → the capacity vanishes from the next solve.
    (desocialize-private-resource! store OWNER (cred-said att))
    (check-pred "after recall, no capacity contributed"
                (null? (commune-socialized-caps store COMMUNE (list bike) '(0))))))

;; A grant whose window has lapsed contributes nothing (custody-cred-live? gate).
(with-vat vat
  (let* ((store (spawn-acdc-store)))
    (socialize-private-resource store OWNER COMMUNE SPEC 20 #:from PAST #:until PAST)
    (check-pred "lapsed grant contributes no capacity"
                (null? (commune-socialized-caps store COMMUNE (list bike) '(0))))))

;; TWO members lend the same spec into the SAME place: one pool, and the commons
;; may draw the sum. The caps are keyed `Svc|spec#place@t` and the located model
;; ingests them with hash-set! (a cap OVERRIDES stock), so unpooled facts would
;; collide on that key and the plan would see one member's capacity for all.
(define OWNER-2 "EOwnerTwoAbcdefghijklmnopqrstuvwxyz01234")
(define bike-2
  (make-economic-resource #:id "res:bike2" #:name "second cargo bike"
                          #:conforms-to SPEC #:classified-as '() #:onhand-quantity (make-measure 1 %count-unit)
                          #:current-location "town" #:primary-accountable OWNER-2
                          #:custodian-scope COMMUNE))
(with-vat vat
  (let* ((store (spawn-acdc-store)))
    (socialize-private-resource store OWNER   COMMUNE SPEC 20 #:until FUTURE)
    (socialize-private-resource store OWNER-2 COMMUNE SPEC 12 #:until FUTURE)
    (let ((caps (commune-socialized-caps store COMMUNE (list bike bike-2) '(0))))
      (check-pred "two grants at one place ⇒ ONE cap for that cell" (= 1 (length caps)))
      (check-pred "the cell's capacity is the SUM of what both lent (20+12)"
                  (= 32 (cdar caps))))))

;; Same spec, DIFFERENT places stays two cells — pooling is per (spec, place),
;; because a bike in the next town over is not this town's bike.
(define bike-far
  (make-economic-resource #:id "res:bike3" #:name "a bike elsewhere"
                          #:conforms-to SPEC #:classified-as '() #:onhand-quantity (make-measure 1 %count-unit)
                          #:current-location "hillside" #:primary-accountable OWNER-2
                          #:custodian-scope COMMUNE))
(with-vat vat
  (let* ((store (spawn-acdc-store)))
    (socialize-private-resource store OWNER   COMMUNE SPEC 20 #:until FUTURE)
    (socialize-private-resource store OWNER-2 COMMUNE SPEC 12 #:until FUTURE)
    (let ((caps (commune-socialized-caps store COMMUNE (list bike bike-far) '(0))))
      (check-pred "two places ⇒ two cells, unpooled" (= 2 (length caps)))
      ;; capacities are COMPUTED now (the lend, over the hours the thing stands
      ;; available), not the grant's integer echoed back — so they are compared as
      ;; the quantities they are
      (check-pred "each cell carries its own lend"
                  (equal? (map (lambda (x) (round x)) (sort (map cdr caps) <))
                          '(12.0 20.0))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Containment: socializing a container socializes its contents (unless retained)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. The apartment carries the oven — but not the retained fridge ──\n")

;; A container (apartment, custodied by the commune once socialized) with two
;; contents: an oven and a fridge, each contained-in the apartment, each at "block".
;; The contents' onhand IS their own service capacity, and a capacity is a rate —
;; eight oven-hours A DAY, not eight hours of nothing in particular. Stated as one
;; quotient unit so the number means the same however the horizon is partitioned.
(define (res id spec custodian onhand contained)
  (make-economic-resource #:id id #:conforms-to spec #:classified-as '()
                          #:onhand-quantity (and onhand (make-measure onhand "hours/day"))
                          #:current-location "block" #:primary-accountable OWNER #:custodian-scope custodian #:contained-in contained))
(define apt    (res "res:apt"    "apartment" COMMUNE 1 #f))
(define oven-c (res "res:oven"   "oven"      OWNER   8 "res:apt"))   ; onhand = its own service capacity
(define fridge (res "res:fridge" "fridge"    OWNER   5 "res:apt"))
(define contain-res (list apt oven-c fridge))

(with-vat vat
  (let* ((store (spawn-acdc-store)))
    ;; socialize the APARTMENT (lends 12 units of its own per-period service)
    (socialize-private-resource store OWNER COMMUNE "apartment" 12 #:until FUTURE)
    ;; owner RETAINS the fridge — the opt-out: a self-held custody attestation
    ($ store 'issue (make-custody-attestation-credential OWNER OWNER "fridge" 5 #:valid-until FUTURE))
    (let* ((caps (commune-socialized-caps store COMMUNE contain-res '(0)))
           (cap  (lambda (spec) (assoc (string-append "Svc|" spec "#block@0") caps))))
      (check-pred "apartment socialized (the root)"          (and (cap "apartment") #t))
      (check-pred "oven socialized IMPLICITLY (contained-in)" (and (cap "oven") #t))
      (check-pred "oven lends its OWN capacity (onhand 8)"    (and (cap "oven") (= 8 (cdr (cap "oven")))))
      (check-pred "retained fridge is NOT socialized"         (not (cap "fridge")))
      (check-pred "exactly apartment + oven contributed"      (= 2 (length caps))))))

;; the LENT-IN span analogue: a span declaration moves where the granted
;; capacity POOLS, exactly as it does for owned means — location untouched
(with-vat vat
  (let* ((store (spawn-acdc-store)))
    (socialize-private-resource store OWNER COMMUNE "apartment" 12 #:until FUTURE)
    (let ((caps (commune-socialized-caps store COMMUNE contain-res '(0)
                                         #:span-of '(("res:apt" . "town")))))
      (check-pred "the declared span moves the granted capacity's pool place"
                  (and (assoc "Svc|apartment#town@0" caps) #t))
      (check-pred "…and nothing remains keyed at the holding place"
                  (not (assoc "Svc|apartment#block@0" caps))))))

;; and when the container's grant is recalled, the contents drop with it
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (att   (socialize-private-resource store OWNER COMMUNE "apartment" 12 #:until FUTURE)))
    (check-pred "before recall: the oven is carried in"
                (and (assoc "Svc|oven#block@0"
                            (commune-socialized-caps store COMMUNE contain-res '(0))) #t))
    (desocialize-private-resource! store OWNER (cred-said att))
    (check-pred "after recall: the oven drops with the apartment"
                (null? (commune-socialized-caps store COMMUNE contain-res '(0))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Permissions: fixed-in-place by default; movable only when granted
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Use-in-place is the default; mobility is an explicit grant ──\n")

(define bike-res
  (make-economic-resource #:id "res:bike" #:conforms-to "spec:cargo-bike" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "depot" #:primary-accountable OWNER #:custodian-scope COMMUNE))
(define oven-fixed
  (make-economic-resource #:id "res:oven2" #:conforms-to "spec:oven" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "kitchen" #:primary-accountable OWNER #:custodian-scope COMMUNE))

(with-vat vat
  (let* ((store (spawn-acdc-store)))
    ;; the oven: an ordinary (fixed) grant — used where it sits
    (socialize-private-resource store OWNER COMMUNE "spec:oven" 10 #:until FUTURE)
    ;; the cargo-bike: explicitly movable — the commune may take it out
    (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4
                                #:until FUTURE #:movable? #t)
    (let* ((res  (list bike-res oven-fixed))
           (view (project-socialized-custody res store COMMUNE))
           (held (lambda (id) (let ((r (find (lambda (r) (equal? id (economic-resource-id r))) view)))
                                (measure-has-numerical-value (economic-resource-onhand-quantity r)))))
           (caps (commune-socialized-caps store COMMUNE res '(0))))
      ;; a fixed grant lends capacity at a place; a movable one lends the thing
      (check-pred "fixed oven's capacity is at its kitchen cell"
                  (and (assoc "Svc|spec:oven#kitchen@0" caps) #t))
      (check "…and the view holds none of the oven itself" (held "res:oven2") 0)
      (check "the movable bike is held in the view, the thing itself" (held "res:bike") 1)
      (check-pred "…and no cap pins its capacity to the depot: it serves where it stands"
                  (not (assoc "Svc|spec:cargo-bike#depot@0" caps))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Reciprocal care terms: bring it back, to origin, in condition
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Care terms: return-to-origin and return-in-condition ──\n")

;; a movable grant stating: return to the depot, in condition ≥ 5; window PAST
;; (so the return is due).
(define care-grant
  (make-custody-attestation-credential OWNER COMMUNE "spec:cargo-bike" 4
    #:valid-until PAST #:movable #t #:return-to "depot" #:condition-floor 5))

(define (bike-at loc cond)
  (make-economic-resource #:id "res:bike" #:conforms-to "spec:cargo-bike" #:classified-as '()
                          #:onhand-quantity (make-measure cond %count-unit) #:current-location loc #:primary-accountable OWNER #:custodian-scope COMMUNE))

;; the pure checker
(check-pred "returned to depot, in condition ⇒ no breach"
            (null? (socialization-care-breaches care-grant (bike-at "depot" 8))))
(check-pred "not returned to origin ⇒ breach"
            (and (memq 'not-at-origin (socialization-care-breaches care-grant (bike-at "street" 8))) #t))
(check-pred "returned worn below the floor ⇒ breach"
            (and (memq 'below-condition (socialization-care-breaches care-grant (bike-at "depot" 3))) #t))
(check-pred "both wrong ⇒ both breaches"
            (= 2 (length (socialization-care-breaches care-grant (bike-at "street" 3)))))

;; the terms readout exposes the structural obligations too
(let ((terms (socialization-care-terms care-grant)))
  (check-pred "care terms expose return-by (the window)"   (equal? PAST (assq-ref terms 'return-by)))
  (check-pred "care terms expose capacity-ceiling (= qty)" (equal? 4 (assq-ref terms 'capacity-ceiling))))

;; store-level: only DUE grants with breaches are reported; a clean return isn't
(with-vat vat
  (let ((store (spawn-acdc-store)))
    ($ store 'issue care-grant)
    (let ((bad (commune-care-breaches store COMMUNE (list (bike-at "street" 3)))))
      (check-pred "the due, breached grant is reported"    (and (assoc "spec:cargo-bike" bad) #t))
      (check-pred "with both breach reasons"               (= 2 (length (cdr (assoc "spec:cargo-bike" bad))))))
    (check-pred "a clean return reports nothing"
                (null? (commune-care-breaches store COMMUNE (list (bike-at "depot" 8)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Consent: grant ↔ care bound in a first-class VF Agreement
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 9. Bilateral consent: owner grants, the COMMUNE signs its acceptance ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Commune"))
         (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                             #:scope-aid COMMUNE #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         ;; 1. the OWNER grants — an offer into the commune's store (owner's own act)
         (grant (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4
                                            #:until FUTURE #:movable? #t
                                            #:return-to "depot" #:condition-floor 5))
         ;; 2. the COMMUNE accepts — gov-cap-gated, scope-signed (its OWN act)
         (agr-said ($ scope 'accept-socialization gov (cred-said grant)))
         (by      (lambda (s) (find (lambda (c) (equal? s (cred-said c))) ($ store 'all))))
         (agr     (by agr-said))
         (retc    (by (car (cred-claim agr 'reciprocal-commitment-ids)))))
    (check-pred "the grant is the OWNER's custody attestation, owner→commune"
                (and (equal? *schema-playnet-custody-attestation* (cred-schema grant))
                     (equal? OWNER (cred-issuer grant)) (equal? COMMUNE (cred-holder grant))))
    (check-pred "the COMMUNE (not the owner) issued the acceptance agreement"
                (and (equal? *schema-playnet-agreement* (cred-schema agr))
                     (equal? COMMUNE (cred-issuer agr)) (equal? OWNER (cred-holder agr))))
    (check-pred "PRIMARY = the owner's grant"
                (member (cred-said grant) (cred-claim agr 'primary-commitment-ids)))
    (check-pred "RECIPROCAL = the commune's return commitment (transfer-custody back)"
                (and (equal? *schema-playnet-commitment* (cred-schema retc))
                     (equal? COMMUNE (cred-issuer retc)) (equal? OWNER (cred-holder retc))
                     (eq? 'transfer-custody (cred-claim retc 'action))))
    (check-pred "the care terms remain on the owner's grant"
                (equal? "depot" (cred-claim grant 'return-to)))
    ;; only the commune, through its OWN gov-cap, can commit the commune
    (check-pred "acceptance is gov-cap-gated (a bogus cap is refused)"
                (catch #t (lambda () ($ scope 'accept-socialization 'bogus (cred-said grant)) #f)
                          (lambda _ #t)))
    ;; and it must be an actual custody grant to this commune
    (check-pred "a said that isn't a custody grant to this commune is refused"
                (catch #t (lambda () ($ scope 'accept-socialization gov "not-a-grant") #f)
                          (lambda _ #t)))))

;; the general plan-store hook: accept-proposal → an Agreement ACDC
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (cbs   (make-plan-credentialing-callbacks store COMMUNE))
         (on-agr (assq-ref cbs 'on-agreement))
         (result '((agreement-id . "agr-x") (proposal-id . "prop-x")
                   (primary-commitment-ids . ("c-own")) (reciprocal-commitment-ids . ("c-care"))
                   (accepting-agent-id . "ECommune") (counterparty . "EAlice"))))
    (on-agr #f #f result)
    (let ((agrs ($ store 'by-schema *schema-playnet-agreement*)))
      (check-pred "the on-agreement hook minted an agreement credential"
                  (and (pair? agrs)
                       (find (lambda (c) (equal? "agr-x" (cred-claim c 'agreement-id))) agrs)))
      (check-pred "it carries the primary + reciprocal commitment ids"
                  (let ((c (find (lambda (c) (equal? "agr-x" (cred-claim c 'agreement-id))) agrs)))
                    (and (member "c-own"  (cred-claim c 'primary-commitment-ids))
                         (member "c-care" (cred-claim c 'reciprocal-commitment-ids))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Projection: the live grant IS the custodian view (no stored state)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 10. custodian-scope is projected from the live grant, not stored ──\n")

;; the durable as it sits in the books BEFORE any grant: Alice owns it, no custodian.
(define (owned-bike)
  (make-economic-resource #:id "res:bike3" #:conforms-to "spec:cargo-bike" #:classified-as '()
                          #:onhand-quantity (make-measure 6 %count-unit) #:current-location "yard" #:primary-accountable OWNER   ; primary-accountable=OWNER, custodian-scope=#f
))

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (proj  (lambda () (car (project-socialized-custody (list (owned-bike)) store COMMUNE)))))
    ;; before any grant: projection is a no-op — the bike stays Alice's, uncustodied
    (check-pred "no grant ⇒ custodian-scope stays #f" (not (economic-resource-custodian-scope (proj))))
    ;; Alice socializes it; now the projection marks it commune-custodied
    (let* ((att (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4 #:until FUTURE))
           (r1  (proj)))
      (check-pred "live grant ⇒ custodian-scope projected to the commune"
                  (equal? COMMUNE (economic-resource-custodian-scope r1)))
      (check-pred "rights untouched — primary-accountable stays the owner"
                  (equal? OWNER (economic-resource-primary-accountable r1)))
      ;; and the projected resource flows straight into the capacity pass
      (check-pred "projected resource ⇒ commune-socialized-caps finds it"
                  (and (assoc "Svc|spec:cargo-bike#yard@0"
                              (commune-socialized-caps store COMMUNE (list r1) '(0))) #t))
      ;; recall the grant: the projection reverts of its own accord — no event, no write
      (desocialize-private-resource! store OWNER (cred-said att))
      (check-pred "recalled grant ⇒ projection drops, custody reverts to #f"
                  (not (economic-resource-custodian-scope (proj)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. Federation visibility: the commune's view = own ∪ live-granted (derived)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 11. commune-resource-view: own ∪ resolved-granted, projected ──\n")

(define (alice-bike)  ; lives in Alice's books; the commune owns nothing of its own
  (make-economic-resource #:id "res:abike" #:conforms-to "spec:cargo-bike" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "yard" #:primary-accountable OWNER))

(with-vat vat
  (let* ((store   (spawn-acdc-store))
         (resolve (lambda (grant) (list (alice-bike))))          ; the federation fetch
         (view    (lambda () (commune-resource-view '() store COMMUNE resolve))))
    ;; no grant yet ⇒ nothing resolved, nothing in view
    (check-pred "no grant ⇒ empty view (commune owns nothing)" (null? (view)))
    ;; Alice socializes ⇒ the bike is resolved INTO the commune's view, commune-custodied
    (let ((att (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4 #:until FUTURE)))
      (let ((rs (view)))
        (check-pred "live grant ⇒ the granted resource appears in the view" (= 1 (length rs)))
        (check-pred "and it is projected commune-custodied"
                    (equal? COMMUNE (economic-resource-custodian-scope (car rs))))
        (check-pred "rights untouched — still Alice's"
                    (equal? OWNER (economic-resource-primary-accountable (car rs))))
        ;; the resolved+projected resource feeds the capacity pass directly
        (check-pred "resolved resource ⇒ capacity injected"
                    (and (assoc "Svc|spec:cargo-bike#yard@0"
                                (commune-socialized-caps store COMMUNE rs '(0))) #t)))
      ;; recall ⇒ the resource drops from the view with its custody (derived, not stored)
      (desocialize-private-resource! store OWNER (cred-said att))
      (check-pred "recall ⇒ the resource drops out of the view" (null? (view))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. A grant may name the exact resource (owner holds several of a spec)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 12. #:resource names WHICH one when the owner has several ──\n")

(with-vat vat
  (let* ((store  (spawn-acdc-store))
         (bike-a (res "bike:A" "spec:cargo-bike" #f 1 #f))   ; two of a kind, both Alice's
         (bike-b (res "bike:B" "spec:cargo-bike" #f 1 #f))
         (by     (lambda (id proj) (find (lambda (r) (equal? id (economic-resource-id r))) proj))))
    ;; the grant names bike:A specifically
    (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4
                                #:until FUTURE #:resource "bike:A")
    (let ((proj (project-socialized-custody (list bike-a bike-b) store COMMUNE)))
      (check-pred "the NAMED resource is projected commune-custodied"
                  (equal? COMMUNE (economic-resource-custodian-scope (by "bike:A" proj))))
      (check-pred "the owner's OTHER one of the spec is untouched"
                  (not (economic-resource-custodian-scope (by "bike:B" proj)))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. Multi-period sub-windows: caps only the periods the grant is live in
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 13. A part-horizon grant caps only its in-window periods ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (bike  (res "res:mp" "spec:cargo-bike" COMMUNE 4 #f))   ; commune-custodied (post-projection)
         ;; grant expires mid-horizon
         (_     (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4
                                            #:until "2050-06-01T00:00:00Z"))
         ;; period 0 sits before the return-by (live); period 1 after it (lapsed)
         (pe    (lambda (t) (if (= t 0) "2050-01-01T00:00:00Z" "2099-01-01T00:00:00Z")))
         (caps  (commune-socialized-caps store COMMUNE (list bike) '(0 1) #f #:period-epoch pe)))
    (check-pred "in-window period 0 is capped"      (and (assoc "Svc|spec:cargo-bike#block@0" caps) #t))
    (check-pred "out-of-window period 1 is NOT capped" (not (assoc "Svc|spec:cargo-bike#block@1" caps)))
    (check-pred "exactly the one in-window period"  (= 1 (length caps)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 14. Intra-commune: a member's resource is already in own — no resolver needed
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 14. The common case: Alice is a member; her bike is already in own ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (own   (list (alice-bike))))   ; a commune's shared observer holds member resources
    ;; tenure: a member's private bike, ungranted, is not the commune's to
    ;; plan over — the view holds only what the commune owns or custodies
    (check-pred "no grant ⇒ the member's private bike stays out of the commune's view"
                (null? (commune-resource-view own store COMMUNE)))
    (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4 #:until FUTURE)
    (check-pred "grant ⇒ the member's own resource is projected commune-custodied (no fetch)"
                (equal? COMMUNE (economic-resource-custodian-scope
                                 (car (commune-resource-view own store COMMUNE)))))))


(display "\n")
(test-summary!)
