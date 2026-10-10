;;; test-legal-service-door.scm — the scope's law at the SERVICE door, default-on.
;;;
;;; `^planner-service 'plan` runs every solve through plain-plan-fn, which
;;; installs `scope-legal-decorate` (compliance.scm) over the root's OWN stores:
;;; recipe-store → crossings, spatial-thing-store → jurisdiction path, observer →
;;; the activity's things, agent-store → their holders. The rules are a folder
;;; of files (PLAYNET_LAW_PACKS). Here the folder holds one rule place and
;;; channel cannot express — "a food-business operator may not vend" — and the
;;; produce's holder is one. The vend column is pruned live; the same scope with
;;; no folder solves the demand, so the door is additive.
;;;
;;; Run: guile -L module tests/doors/test-legal-service-door.scm

(use-modules (playnet test scope))
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas) (playnet doors service)
             (playnet legal registry) (playnet legal compliance)
             (playnet knowledge recipes compliance-food)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format) (ice-9 ftw))

(define packs (string-append (or (getenv "TMPDIR") "/tmp") "/playnet-law-packs-" (number->string (getpid))))
(mkdir packs)
(save-rule-pack (string-append packs "/operator.sexp")
  (list (rule (all-of (on-crossing 'food-vending) (agent-has 'classified-as "food-business"))
              (list (forbid #:reason "operator is a Lebensmittelunternehmer"))
              #:label "lmu/operator" #:confidence 'verified #:steward "scope:test")))

(define win (all-week-window "00:00" "23:59"))
(define permit-packs (string-append packs "-permit"))
(mkdir permit-packs)
(save-rule-pack (string-append permit-packs "/permit.sexp")
  (list (rule (all-of (in-jurisdiction "foodville") (on-crossing 'food-vending))
              (list (obtain #:rides 'entity #:name "Food Establishment Permit"
                            #:issuer "foodville-health" #:per 'each-site
                            #:spec '(fire-safety hygiene labeling)))
              #:label "foodville/permit" #:confidence 'verified #:steward "scope:test")))

;; a held credential: a resource conforming to the permit spec, accountable to
;; the commune, valid (no lot ⇒ no expiry)
(define (held-permit)
  (make-economic-resource #:id "res:permit" #:name "Food Establishment Permit"
    #:conforms-to "Food Establishment Permit" #:classified-as '("credential") #:accounting-quantity (make-measure 1 "cert") #:onhand-quantity (make-measure 1 "cert")
    #:current-location "foodville" #:primary-accountable "commune:foodville" #:custodian-scope "commune:foodville" #:state "active"))

(define* (fill-under law-dir #:key (permit? #f))
  (define vat (spawn-vat))
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Law Scope" #:law-packs law-dir))
           (svc (spawn ^planner-service (hashmap)))
           (rs  ($ sr 'recipe-store)) (obs ($ sr 'observer))
           (as  ($ sr 'agent-store))  (sts ($ sr 'spatial-thing-store)))
      (seed-compliance-food-recipe rs)
      ($ sts 'add-location (make-spatial-thing #:id "world"))
      ($ sts 'add-location (make-spatial-thing #:id "foodville" #:lat 40.0 #:long -74.0
                                               #:contained-in "world"))
      ($ obs 'seed-resource (er "pr" "spec-cf-produce" "agent:kantine" #:place "foodville" #:qty 100.0 #:custodian "agent:kantine"))
      ($ obs 'seed-resource (er "ck" "spec-cf-cook" "w-cook" #:place "foodville" #:qty 8.0 #:custodian "w-cook"))
      (when permit? ($ obs 'seed-resource (held-permit)))
      ($ as 'add-agent (make-agent #:id "w-cook"        #:type 'person       #:name "Cook"
                                   #:primary-location "foodville" #:classified-as '()
                                   #:availability-window win))
      ($ as 'add-agent (make-agent #:id "agent:kantine" #:type 'organization #:name "Kantine"
                                   #:primary-location "foodville" #:classified-as '("food-business")))
      ($ svc 'add-scope! "s1" sr)
      (let ((r ($ svc 'plan "s1" (list (list "spec-cf-meal" "foodville" 0 10.0)))))
        (if (eq? (car r) 'ok)
            (or (assq-ref (cdr r) 'met) 0.0)
            r)))))

(define fill-lawless (fill-under #f))
(define fill-lawful  (fill-under packs))
(format #t "\n  fill with no rule-pack: ~a   ·   under the operator rule: ~a\n" fill-lawless fill-lawful)
(check-pred "no rule-pack ⇒ the solve meets the demand (the door is additive)"
            (and (number? fill-lawless) (> fill-lawless 0.95)))
(check-pred "the food-business holder's produce trips the operator rule through the service door ⇒ vend pruned"
            (and (number? fill-lawful) (< fill-lawful 0.05)))

(define fill-unpermitted (fill-under permit-packs))
(define fill-permitted   (fill-under permit-packs #:permit? #t))
(format #t "  under a permit rule — permit absent: ~a   ·   permit held by the commune: ~a\n"
        fill-unpermitted fill-permitted)
(check-pred "an entity permit the commune does not hold prunes the vend column at the service door"
            (and (number? fill-unpermitted) (< fill-unpermitted 0.05)))
(check-pred "a permit standing in the commune's own stores IS the commune's permit ⇒ the demand is met"
            (and (number? fill-permitted) (> fill-permitted 0.95)))

(for-each (lambda (f) (delete-file (string-append permit-packs "/" f)))
          (filter (lambda (f) (string-suffix? ".sexp" f)) (scandir permit-packs)))
(rmdir permit-packs)
(for-each (lambda (f) (delete-file (string-append packs "/" f)))
          (filter (lambda (f) (string-suffix? ".sexp" f)) (scandir packs)))
(rmdir packs)
(test-summary!)
