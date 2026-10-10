;;; vf-conformance-fields-test.scm — every field of a VF record is a property of its class.
;;;
;;; `vf-conformance-classes-test.scm` holds the vocabulary file's record types to the
;;; TTL's classes. This holds each record's FIELDS to the TTL's properties: a field
;;; named `has-beginning` on <commitment> is the property `hasBeginning`, whose
;;; domain names Commitment. What playnet names otherwise — an id (an IRI in RDF),
;;; a field the TTL has no property for — is declared here with its reason, and
;;; the declaration is checked for rot both ways: a declared field that became a
;;; property, or left the record, fails.
;;;
;;; Run: guile -L module tests/vf/vf-conformance-fields-test.scm

(use-modules (playnet test harness)
             (playnet vf schemas)
             ((playnet utils records) #:select (vf-record-type-fields vf-record-type-name))
             (playnet test vf-ttl)
             (srfi srfi-1) (srfi srfi-13))

(define root (vf-repo-root))
(define properties (ttl-properties root))          ; (name label domain range card) …
(define property-names (map car properties))

;; kebab->camel-class / kebab->camel-field: (playnet test vf-ttl)

;; the record types that are classes of the TTL, by their names
(define (record-types module-name)
  (filter-map (lambda (sym)
                (let ((s (symbol->string sym)))
                  (and (string-prefix? "<" s) (string-suffix? ">" s)
                       (module-ref (resolve-interface module-name) sym))))
              (module-map (lambda (sym var) sym) (resolve-interface module-name))))

(define (class-of rtd) (symbol->string (vf-record-type-name rtd)))

(define ttl-classes
  (delete-duplicates
   (append-map (lambda (p) (caddr p)) properties)))

;; a property belongs to a class when its domain names the class, or names none
(define (property-of? field-name class)
  (any (lambda (p) (and (string=? (car p) field-name)
                        (or (null? (caddr p)) (member class (caddr p)))))
       properties))

;; What playnet names otherwise, per record: (field . reason). `id` is every
;; record's: a record's identity is its IRI in RDF, a field here. The reasons fall
;; into a few kinds, each named in the entry: the TTL spells it otherwise; the TTL
;; names the property on other classes only; the field is a declared extension
;; (its route into the core in codebase-organization.md §7); a family's field.
(define *every-record* '((id . "the record's identity: an IRI in RDF, a field here")))
(define at-location "the TTL has currentLocation, primaryLocation and toLocation; a flow's one place is atLocation here")
(define recurrence "the recurrence over the horizon (beyond/schedules); inventory Part D step 9")
(define ddmrp "the buffer planner's (ddmrp/); a classification of the specification once the route holds")
(define *named-otherwise*
  `((commitment (at-location . ,at-location) (availability-window . ,recurrence))
    (intent (at-location . ,at-location) (availability-window . ,recurrence)
            (name . "the TTL names `name` on no Intent; the label the day shows an intent by")
            (satisfies . "the TTL names satisfies on Commitment and EconomicEvent; read forward here, the commitments that satisfy the intent"))
    (economic-event (at-location . ,at-location)
                    (distribution-mode . "how the resource moved, by its custodian's choosing or by lot (accounting S5)")
                    (previous-event . "the event this one follows in a chain, read forward"))
    (economic-resource (lot . "the lot (beyond/lot): trackingIdentifier is the code; the expiry has one date and no kind in the TTL")
                       (custodian-scope . "the scope that holds custody, beside the primary accountable (custody/rights split)")
                       (previous-event . "the last event that moved it, read forward")
                       (availability-window . ,recurrence)
                       (distribution-mode . "how it is given out, by its custodian's choosing or by lot (accounting S5)"))
    (agent (type . "person | organization | ecological-agent: the TTL's three subclasses, one record")
           (classified-as . "the TTL names classifiedAs on Organization and EcologicalAgent; one record carries all three kinds")
           (availability-window . ,recurrence))
    (plan (classified-as . "a plan's classifications, the TTL naming classifiedAs on no Plan"))
    (proposal (in-scope-of . "the TTL names inScopeOf on no Proposal; a directed proposal rides its scope"))
    (scenario-definition (in-scope-of . "the TTL names inScopeOf on no ScenarioDefinition; a definition rides its scope"))
    (recipe (based-on . "the TTL names basedOn on Process alone; a recipe names what it is based on")
            (recipe-processes . "the recipe's processes, held on the recipe (the TTL has recipeIncludes on the group)")
            (recipe-exchanges . "the recipe's exchanges, held on the recipe"))
    (recipe-process (sequence-group . "the group a process is sequenced in (recipes-as-topology)")
                    (minimum-batch-quantity . "the whole-count layer's batch (discrete-layer); a stated fact of the process"))
    (recipe-flow (is-primary . "the flow the recipe is named for: what it makes")
                 (resolve-from-flow . "the flow a quantity is resolved from (propagation)"))
    (recipe-exchange (name . "the TTL names `name` on no RecipeExchange") (note . "the TTL names `note` on no RecipeExchange"))
    (recipe-group (recipes . "the TTL has recipeIncludes; read forward here, the recipes the group includes"))
    (resource-specification (medium-of-exchange . "a credit specification (consume-grant money)")
                            (buffer-profile-id . ,ddmrp) (positioning-analysis . ,ddmrp)
                            (satisfied-by . "what satisfies the specification: the substitution reading (reproduction diet)")
                            (keep-in-place . "a thing that is used where it stands (rented fragility, transport)")
                            (composition . "the substances the thing is made of (matter face)"))
    (process-specification (is-decoupling-point . ,ddmrp) (is-control-point . ,ddmrp) (buffer-type . ,ddmrp)
                           (is-divergent-point . ,ddmrp) (is-convergent-point . ,ddmrp))
    (spatial-thing (contained-in . "the containment forest of places (room ⊂ venue ⊂ commune); the TTL has containedIn on EconomicResource alone")
                   (boundary . "the place's polygon (a GeoJSON geometry)"))
    (proposal-list (name . "the TTL names `name` on no ProposalList") (note . "the TTL names `note` on no ProposalList")
                   (created . "the TTL names `created` on no ProposalList"))
    (agreement-bundle (name . "the TTL names `name` on no AgreementBundle") (note . "the TTL names `note` on no AgreementBundle")
                      (created . "the TTL names `created` on no AgreementBundle"))
    (agent-relationship-role (label . "the TTL spells it roleLabel") (inverse-label . "the TTL spells it inverseRoleLabel")
                             (classified-as . "the TTL names classifiedAs on no AgentRelationshipRole"))))

(define (declared record field)
  (or (assq field *every-record*)
      (let ((r (assq record *named-otherwise*))) (and r (assq field (cdr r))))))

(format #t "\n── ~a properties of the TTL; each record's fields against its class ──\n" (length properties))

(define checked '())
(for-each
 (lambda (rtd)
   (let* ((class (class-of rtd)) (record (string->symbol (string-drop (camel->kebab class) 1))))
     (when (member class ttl-classes)
       (set! checked (cons record checked))
       (for-each
        (lambda (field)
          (let ((prop (kebab->camel-field field)) (why (declared record field)))
            (check (format #f "<~a> ~a is ~a" record field
                           (cond ((property-of? prop class) (string-append "vf:" prop))
                                 (why (cdr why))
                                 (else "a property of its class, or declared otherwise")))
                   (or (property-of? prop class) (and why #t)))))
        (vf-record-type-fields rtd)))))
 (record-types '(playnet vf schemas)))

(check-pred "records of several classes were checked" (> (length checked) 10))

(format #t "\n── what is declared otherwise is so ──\n")
(for-each
 (lambda (entry)
   (let* ((record (car entry))
          (rtd (find (lambda (t) (string=? (class-of t) (kebab->camel-class record)))
                     (record-types '(playnet vf schemas)))))
     (check (format #f "<~a> is a record of a class" record) (and rtd (memq record checked) #t))
     (when rtd
       (for-each
        (lambda (f)
          (check (format #f "declared <~a> ~a is a field of the record and no property of its class" record (car f))
                 (and (memq (car f) (vf-record-type-fields rtd))
                      (not (property-of? (kebab->camel-field (car f)) (class-of rtd))))))
        (cdr entry)))))
 *named-otherwise*)

(test-summary!)
