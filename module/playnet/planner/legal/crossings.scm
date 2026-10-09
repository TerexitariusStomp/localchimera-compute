;;; legal/crossings.scm — the legal "crossings" a recipe can trip.
;;;
;;; Design: docs/planning/legal/legal-crossings.md. A legal requirement is NOT a
;;; property of a recipe; it is the demand of a guard over context, and a
;;; recipe merely TRIPS crossings that feed that context. This file is the
;;; inductive core: an OPEN catalogue of crossings, and the derivation that reads
;;; which of them a process, a thing or a record trips off the ValueFlows facts
;;; it already carries (`*crossing-patterns*`) — an action, on a kind of thing,
;;; with or without something coming back, with custody and rights together or
;;; apart. What the records do not say, a `crossing:<name>` tag declares.
;;;
;;; The catalogue is OPEN by construction — a crossing is ANY symbol; the
;;; library only ANNOTATES the well-known ones with a kind. An unrecognised
;;; crossing defaults to 'mirrored (the safe assumption: treat an unknown
;;; trigger as one you cannot dodge). Stewards in a jurisdiction register new
;;; annotated crossings via register-crossing! — so the vocabulary generalises
;;; to data-processing, regulated-speech, regulated-conduct, … in any
;;; jurisdiction, without a closed enum.
;;;
;;; The record wrappers (recipe-flow-crossings …) call schemas.scm accessors;
;;; load schemas.scm before USING them (loading this file alone is fine — the
;;; accessors are only referenced inside lambda bodies, late-bound).
;;;
;;; Run the demo:  guile -L . module/playnet/planner/legal/crossings.scm

(define-module (playnet planner legal crossings)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner formulas actions)
  #:use-module ((playnet planner facts rail) #:select (spec-rail))
  #:use-module ((playnet planner facts agent-tags) #:select (tag-value tag-values))   ; the "key:value" tag, read one way
  #:export (*default-crossings* *extra-crossings* register-crossing! crossing-row
            known-crossing? crossing-kind crossing-gloss all-crossings
            crossings-of-kind classification-crossings
            *kind-signs* kinds-of spec-kinds
            *channel-of-rail* classification-channel
            rail-channel recipe-channel
            classification-act recipe-act
            flow-fact *crossing-patterns* derivable-crossings crossing-lacks
            recipe-crossings recipe-crossings/derived recipe-crossings/declared
            asset-fact asset-crossings record-fact record-crossings
            default-irreversible-skill?
            crossings-demo)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format))


;;; ─── the seed catalogue : the well-known crossings, each (kind gloss) ─────
;;; A fourth element, where present, is what the records lack when a tag has to
;;; declare the crossing (see `register-crossing!`).
;;; kind ∈ avoidable | by-choice | mirrored  — the colour bands of the
;;; playnet.typ crossings table and by-branch list (§The catalogue of
;;; crossings), both rendered from one Typst catalogue whose rows carry these
;;; ids and kinds (`make check-crossing-catalogue` refuses a drift).
(define *default-crossings*
  '((public-sale     avoidable  "transfers to a non-member / for fiat" handover)
    (state-money     avoidable  "converts to or from state money")
    (wage-labour     avoidable  "employs non-member wage labour" handover)
    (own-property    by-choice  "owns/leases real property or contracts a legal-only outsider")
    (public-vehicle  by-choice  "operates a titled vehicle on public ways")
    (built-structure mirrored   "builds or occupies an inspected structure" state)   ; building is derived; a standing structure's state is a tag
    (act-on-person   mirrored   "performs a state-regulated act on a person")
    (dangerous-thing mirrored   "handles a dangerous or controlled thing")
    (eco-draw        mirrored   "draws on / emits into the shared environment")
    (food-vending    avoidable  "sells or serves food to the public" handover)
    (data-processing mirrored   "processes other people's personal data")))

;;; jurisdiction-registered extensions (mutable; in the live engine this is the
;;; governance actor's state — see legal/registry.scm's actor sketch).
(define *extra-crossings* '())
;;; A row is (symbol kind gloss [lacks]). LACKS says, for a crossing a tag has to
;;; declare, which fact the records do not carry — `crossing-lacks` below. A
;;; crossing with no pattern states it where the crossing is defined, so every
;;; crossing is either read off the records or says why it cannot be.
(define* (register-crossing! sym kind gloss #:optional (lacks #f))
  (set! *extra-crossings*
        (cons (if lacks (list sym kind gloss lacks) (list sym kind gloss)) *extra-crossings*))
  sym)

(define (crossing-row x)
  (or (assq x *extra-crossings*) (assq x *default-crossings*)))
(define (known-crossing? x) (and (crossing-row x) #t))
(define (crossing-kind x)             ; unknown ⟹ 'mirrored (can't-dodge default)
  (let ((e (crossing-row x))) (if e (cadr e) 'mirrored)))
(define (crossing-gloss x)
  (let ((e (crossing-row x))) (and e (caddr e))))
(define (all-crossings)
  (map car (append *extra-crossings* *default-crossings*)))
(define (crossings-of-kind k)
  (filter-map (lambda (e) (and (eq? (cadr e) k) (car e)))
              (append *extra-crossings* *default-crossings*)))

;;; ─── a crossing DECLARED on the records : the `crossing:<name>` tag ──────
;;; What the structure of a recipe does not say — where a thing was cooked,
;;; whose it was, how it is presented — a steward says with a tag on the flow or
;;; its spec: "crossing:<name>" names ANY crossing (open vocabulary). The
;;; derivation below reads everything else off the records, so a tag is for what
;;; only a person can state.
(define (tagged tags key)                 ; every value of a "key:value" tag, as symbols
  (if (list? tags) (delete-duplicates (map string->symbol (tag-values tags key))) '()))
(define (tagged-one tags key)             ; the first, or #f
  (and (list? tags) (and=> (tag-value tags key) string->symbol)))

(define (classification-crossings tags) (tagged tags "crossing"))

;;; ─── the KIND of thing a spec is ─────────────────────────────────────────
;;; A pattern asks what an act is done TO: money, food, a dwelling, a vehicle.
;;; A spec already says, in the ways it was given to say it — a typed field
;;; (`medium-of-exchange`), its id, a classification — and this table is the one
;;; reading of those signs. A row is (how sign kind):
;;;   (field  <accessor>  kind)   the spec's typed field is true
;;;   (id     "<spec-id>" kind)   the spec is this one
;;;   (tag    "<class>"   kind)   the spec or the flow is classified so
;;;   (prefix "<class:>"  kind)   …by any classification with this prefix
(define *kind-signs*
  `((field ,resource-specification-medium-of-exchange money)
    (tag    "currency"            money)
    (tag    "food"                food)
    (prefix "vf:food-class:"      food)
    (id     "spec-dwelling"       dwelling)
    (tag    "occupied-structure"  dwelling)
    (id     "spec-shelter"        shelter)
    (id     "land"                land)
    (tag    "vf:vehicle"          vehicle)
    (tag    "vehicle"             vehicle)
    (tag    "self-propelled"      self-propelled)
    (tag    "controlled"          hazard)
    (tag    "hazardous"           hazard)
    (tag    "firearm"             hazard)
    (tag    "pharmaceutical"      hazard)
    (tag    "ecological-agent"    ecological)
    (tag    "personal-data"       personal-data)
    (tag    "irreversible-error"  irreversible-skill)))

(define* (kinds-of spec classes #:optional (spec-id #f))
  "The kinds SPEC (a <resource-specification> or #f), its id SPEC-ID (what a flow
   names, whether or not a store holds the spec) and CLASSES (classification
   strings, the flow's or the resource's own) say the thing is."
  (let ((classes (if (list? classes) classes '()))
        (spec-id (or (and spec (resource-specification-id spec)) spec-id)))
    (delete-duplicates
     (filter-map
      (lambda (row)
        (let ((how (car row)) (sign (cadr row)) (kind (caddr row)))
          (and (case how
                 ((field)  (and spec (sign spec) #t))
                 ((id)     (equal? sign spec-id))
                 ((tag)    (and (member sign classes) #t))
                 ((prefix) (any (lambda (c) (and (string? c) (string-prefix? sign c))) classes))
                 (else #f))
               kind)))
      *kind-signs*))))

(define (spec-classes spec)
  (or (and spec (resource-specification-resource-classified-as spec)) '()))

;;; What a thing is said to be, wherever it is named — on a recipe flow, a
;;; resource, a record: its spec (resolved, when a store holds it) and every
;;; classification on it and on its spec. → (values spec classes kinds)
(define (thing-read resolve-spec spec-id own-classes)
  (let* ((spec    (and spec-id (resolve-spec spec-id)))
         (classes (append (or own-classes '()) (spec-classes spec))))
    (values spec classes (kinds-of spec classes spec-id))))
(define (flow-classes flow resolve-spec)
  (call-with-values
      (lambda () (thing-read resolve-spec (recipe-flow-resource-conforms-to flow)
                             (recipe-flow-resource-classified-as flow)))
    (lambda (spec classes kinds) classes)))
(define* (spec-kinds spec #:optional (spec-id #f)) (kinds-of spec (spec-classes spec) spec-id))

;;; ─── the CHANNEL a good is handed on by ──────────────────────────────────
;;; A crossing says WHAT an act is; a channel says HOW the good reaches a person.
;;; Both rulebooks for a public fridge turn on the pair rather than on either
;;; alone: the same home-cooked pot may pass hand-to-hand and may NOT be left in
;;; a Fairteiler, and the same rescued yoghurt is fine in both. So a rule needs
;;; to read (crossing × channel), and this is the second half.
;;;
;;; Read exactly the way a crossing is read, off the real records, so there is one
;;; convention and not two: a `channel:<name>` tag names any channel (open
;;; vocabulary). The RAIL the plan published (rail.scm spec-rail, read off the
;;; recipes) maps onto the same symbols — a good handed to a person by a claim
;;; is personal, a communal good lands nobody-to-nobody — the comment above
;;; names it as this file's precedent, and it IS the precedent.
;;;
;;;   non-personal  a Fairteiler, a public shelf, an organisation — nobody hands
;;;                 it over, and nobody is there to judge the recipient
;;;   personal      hand to hand, with a person present who can say "eat it today"
;;;   own-use       kept, or fed to animals — it never reaches another person
;;;   disposal      it leaves as waste
(define *channel-of-rail*
  '((communal   . non-personal)
    (individual . personal)))

(define (classification-channel tags) (tagged-one tags "channel"))

(define* (rail-channel spec #:optional (store #f))
  "The channel a spec's rail implies; #f (unspecified) when no plan has
   spoken. STORE scopes the rail read to one scope's own recipe-store, so
   it can never be a different scope's (rail.scm spec-rail)."
  (and=> (spec-rail spec store) (lambda (rail) (assq-ref *channel-of-rail* rail))))

;;; the channel a PROCESS hands its good on by — the twin of `recipe-crossings`,
;;; reading the same flows through the same spec resolver. #f when nothing says,
;;; and #f is "unstated", never a channel: a rule guarded on a channel then
;;; stands in doubt — it prices and warns, and prunes nothing. A recipe that
;;; means a channel says so.
;;; ─── the ACT : what KIND of activity this is, off the recipe ─────────────
;;; A crossing says the activity touches the state; the CHANNEL says how the good
;;; lands; the ACT says what kind of act it is — `food`, `alcohol`, `agriculture`,
;;; `housing`. Thresholds turn on it: a commune's zone A forbids building unless
;;; the act is farming, and half a licensing code reads the same way.
;;;
;;; It is a tag on the flow or its spec (`act:agriculture`), read exactly as a
;;; crossing is, so a recipe carries its own act and the gate stops having to be
;;; told one act for every process it will ever decorate. #f ⇒ the caller's own
;;; statement stands; where nobody states one the act is unknown, and a rule that
;;; reads it is a hit in doubt (legal/registry.scm).
(define (classification-act tags) (tagged-one tags "act"))

(define* (recipe-act flows resolve-spec)
  (any (lambda (f) (classification-act (flow-classes f resolve-spec))) flows))

(define* (recipe-channel flows resolve-spec #:optional (store #f))
  (any (lambda (f)
         (or (classification-channel (flow-classes f resolve-spec))
             (rail-channel (recipe-flow-resource-conforms-to f) store)))   ; the tag speaks first, then the plan's rail
       flows))

;;; ─── the FACTS a pattern reads ───────────────────────────────────────────
;;; One flow of a process, as plain data: what is done (action), to what kind of
;;; thing (kinds), on which side (direction), and whether something comes back
;;; (reciprocal). A recipe says "something comes back" with an exchange: a flow
;;; that is a clause of a RecipeExchange which also holds a money flow has money
;;; coming back; a clause of an exchange with no money has `none`; a flow no
;;; exchange names leaves it unsaid (#f).
;;;   EXCHANGE-FLOWS : a RecipeExchange id → its flows (the recipe store's
;;;   `flows-for-exchange`); the default knows of no exchange.
(define* (flow-fact flow resolve-spec #:key (exchange-flows (lambda (id) '()))
                    (irreversible-skill? default-irreversible-skill?))
  (call-with-values
      (lambda () (thing-read resolve-spec (recipe-flow-resource-conforms-to flow)
                             (recipe-flow-resource-classified-as flow)))
    (lambda (spec classes kinds)
      (let ((rex    (recipe-flow-recipe-clause-of flow))
            (money? (lambda (f)
                      (call-with-values
                          (lambda () (thing-read resolve-spec (recipe-flow-resource-conforms-to f)
                                                 (recipe-flow-resource-classified-as f)))
                        (lambda (sp cls ks) (memq 'money ks))))))
        `((action     . ,(recipe-flow-action flow))
          (kinds      . ,(if (and spec irreversible-skill? (irreversible-skill? spec))
                             (lset-adjoin eq? kinds 'irreversible-skill)
                             kinds))
          (classes    . ,classes)
          (direction  . ,(cond ((recipe-flow-recipe-output-of flow) 'output)
                               ((recipe-flow-recipe-input-of flow)  'input)
                               (else #f)))
          (reciprocal . ,(and rex
                              (let ((clauses (exchange-flows rex)))
                                ;; an exchange holds at least the flow that names
                                ;; it; a reader shown none was not shown the
                                ;; recipe's exchanges, and would read a sale as a gift
                                (unless (any (lambda (f) (equal? (recipe-flow-id f) (recipe-flow-id flow)))
                                             clauses)
                                  (error "recipe-crossings: a flow is a clause of an exchange; pass #:exchange-flows"
                                         (recipe-flow-id flow) rex))
                                (if (any (lambda (f) (and (not (equal? (recipe-flow-id f) (recipe-flow-id flow)))
                                                          (money? f)))
                                         clauses)
                                    'money 'none)))))))))

(define (fact-ref fact k) (assq-ref fact k))
(define (fact-action? fact . actions) (and (memq (fact-ref fact 'action) actions) #t))
(define (fact-kind? fact kind) (and (memq kind (fact-ref fact 'kinds)) #t))

;;; ─── the PATTERNS : what trips a crossing, read off the records ──────────
;;; The law attaches to a pattern — an action, on a kind of thing, with or
;;; without something coming back, with rights and custody together or apart —
;;; and a crossing is the name of one. Each row states the pattern once:
;;;
;;;   (crossing level test)
;;;     level `process` : TEST over the list of flow-facts of ONE process
;;;     level `asset`   : TEST over one asset-fact (a resource at the cell)
;;;     level `record`  : TEST over one record-fact (an intent, commitment, event)
;;;
;;; What a row here derives, no tag need say. What stays DECLARED (a
;;; `crossing:` tag, or a way's own list) is what these records do not carry:
;;;   where     — feed-in-public, home-kitchen, public-fridge
;;;   whose     — occupy-property (who holds the title)
;;;   its state — past-use-by, opened-packaging, bloated-packs
;;;   how shown — open-buffet, open-sandwich
;;;   what kind of food it is — raw-meat, raw-fish, raw-eggs, raw-milk,
;;;               foraged-fungi, alcohol (a food class says meat, not raw)
;;;   to whom, and for what — where a recipe states no exchange: a handover is
;;;               read off the exchange (handover.scm), and a recipe that states
;;;               none leaves share-food, a sale, a receipt to a tag
;;;   no flow at all — communications, ai-processing, organising
(define (any-fact facts . tests)
  (any (lambda (f) (every (lambda (t) (t f)) tests)) facts))
(define (food? f) (fact-kind? f 'food))
(define (gift? side)                      ; handed over (output) or received (input), nothing passing the other way
  (lambda (f) (and (eq? side (fact-ref f 'direction)) (eq? 'none (fact-ref f 'reciprocal)))))
(define (rights-move? f)                  ; the action table's own set (schemas.scm)
  (and (memq (fact-ref f 'action) *rights-moving-actions*) #t))
(define (incoming? f) (eq? 'input (fact-ref f 'direction)))
(define (sold? f)                         ; an output with money coming back, or rights moving out
  (or (and (eq? 'output (fact-ref f 'direction)) (eq? 'money (fact-ref f 'reciprocal)))
      (and (rights-move? f) (not (incoming? f)))))
(define (real-property? f) (or (fact-kind? f 'land) (fact-kind? f 'dwelling)))

(define *crossing-patterns*
  `((state-money     process ,(lambda (fs) (any-fact fs (lambda (f) (fact-kind? f 'money)))))
    (public-sale     process ,(lambda (fs) (any-fact fs sold?)))
    (food-vending    process ,(lambda (fs) (any-fact fs sold? food?)))
    ;; food under an exchange with nothing passing the other way: given, or received
    (share-food      process ,(lambda (fs) (any-fact fs (gift? 'output) food?)))
    (recover-surplus process ,(lambda (fs) (any-fact fs (gift? 'input) food?)))
    (act-on-person   process ,(lambda (fs) (any-fact fs (lambda (f) (fact-action? f 'work))
                                                     (lambda (f) (fact-kind? f 'irreversible-skill)))))
    ;; the rights to land or a dwelling come IN: property acquired
    (own-property    process ,(lambda (fs) (any-fact fs rights-move? incoming? real-property?)))
    (occupancy       process ,(lambda (fs)
                                (and (any-fact fs (lambda (f) (fact-action? f 'deliver-service))
                                               (lambda (f) (fact-kind? f 'shelter)))
                                     (any-fact fs (lambda (f) (fact-action? f 'cite 'use))
                                               (lambda (f) (fact-kind? f 'dwelling))))))
    (built-structure process ,(lambda (fs) (any-fact fs (lambda (f) (fact-action? f 'produce))
                                                     (lambda (f) (fact-kind? f 'dwelling)))))
    (public-vehicle  process ,(lambda (fs) (any-fact fs (lambda (f) (fact-action? f 'use))
                                                     (lambda (f) (fact-kind? f 'vehicle))
                                                     (lambda (f) (not (fact-kind? f 'self-propelled))))))
    (dangerous-thing process ,(lambda (fs) (any-fact fs (lambda (f) (fact-kind? f 'hazard)))))
    (eco-draw        process ,(lambda (fs) (any-fact fs (lambda (f) (fact-kind? f 'ecological)))))
    (data-processing process ,(lambda (fs) (any-fact fs (lambda (f) (fact-kind? f 'personal-data)))))
    ;; a thing at the cell: custody and rights apart on money is funds held for
    ;; another; land or a dwelling held (owned or leased) is property
    (hold-funds      asset   ,(lambda (a) (and (fact-kind? a 'money) (fact-ref a 'split?))))
    (own-property    asset   ,(lambda (a) (and (or (fact-kind? a 'land) (fact-kind? a 'dwelling))
                                               (not (member "tenure:lodged" (fact-ref a 'classes))))))
    ;; one record a door writes: money sent on a member's behalf; a good handed
    ;; over against labour hours
    (hold-funds          record ,(lambda (r) (and (memq (fact-ref r 'action) *rights-moving-actions*)
                                                  (fact-kind? r 'money))))
    (credit-contribution record ,(lambda (r) (and (memq (fact-ref r 'action) *rights-moving-actions*)
                                                  (fact-ref r 'labour-settled?) #t)))))

(define (patterns-at level)
  (filter (lambda (row) (eq? level (cadr row))) *crossing-patterns*))
(define (pattern-crossings level subject)
  (filter-map (lambda (row) (and ((caddr row) subject) (car row))) (patterns-at level)))
(define (derivable-crossings)             ; every crossing some pattern yields
  (delete-duplicates (map car *crossing-patterns*)))

;;; Why a crossing is declared and not derived: the fact its catalogue row says
;;; the records lack (`register-crossing!`). The classes:
;;;   where · whose · state · shown · food · handover · no-flow
;;; #f for a crossing nobody has classified, or one a pattern always derives.
(define (crossing-lacks crossing)
  (let ((row (crossing-row crossing)))
    (and row (> (length row) 3) (list-ref row 3))))

;;; ─── a PROCESS's crossings : derived ∪ declared ──────────────────────────
;;; `resolve-spec` : a ResourceSpecification id → <resource-specification> | #f.
(define* (recipe-crossings/derived flows resolve-spec
                                   #:optional (irreversible-skill? default-irreversible-skill?)
                                   #:key (exchange-flows (lambda (id) '())))
  (pattern-crossings 'process
                     (map (lambda (f) (flow-fact f resolve-spec
                                                 #:exchange-flows exchange-flows
                                                 #:irreversible-skill? irreversible-skill?))
                          flows)))

(define (recipe-crossings/declared flows resolve-spec)
  (delete-duplicates
   (append-map (lambda (f) (classification-crossings (flow-classes f resolve-spec))) flows)))

(define* (recipe-crossings flows resolve-spec
                           #:optional (irreversible-skill? default-irreversible-skill?)
                           #:key (exchange-flows (lambda (id) '())))
  (lset-union eq?
              (recipe-crossings/declared flows resolve-spec)
              (recipe-crossings/derived flows resolve-spec irreversible-skill?
                                        #:exchange-flows exchange-flows)))

(define (default-irreversible-skill? spec)
  (let ((cls (resource-specification-resource-classified-as spec)))
    (and (list? cls) (member "irreversible-error" cls) #t)))

;;; ─── a THING's crossings : a resource at the cell ────────────────────────
;;; ASSET is the gate's own alist of a resource (legal/gate.scm
;;; `legal-asset-fields`): conforms-to, classified-as, and `rented?` — custody
;;; and rights apart, the one test `resource-rented?` (schemas.scm) makes of the
;;; record.
(define (asset-fact asset resolve-spec)
  (call-with-values
      (lambda () (thing-read resolve-spec (assq-ref asset 'conforms-to)
                             (assq-ref asset 'classified-as)))
    (lambda (spec classes kinds)
      `((kinds   . ,kinds)
        (classes . ,classes)
        (split?  . ,(and (assq-ref asset 'rented?) #t))))))

(define (asset-crossings assets resolve-spec)   ; ASSETS #f — nobody looked — trips nothing
  (delete-duplicates
   (append-map (lambda (a) (pattern-crossings 'asset (asset-fact a resolve-spec)))
               (or assets '()))))

;;; ─── a RECORD's crossings : one intent, commitment or event ──────────────
;;; What a door writes is a record, and the record says what was done: its
;;; action, the spec it moves, and — for a claim — that it is settled in labour
;;; hours (an effort quantity beside the good).
(define (record-fact record resolve-spec)
  (call-with-values
      (lambda ()
        (cond ((economic-event? record)
               (values (economic-event-action record)
                       (economic-event-resource-conforms-to record)
                       (economic-event-resource-classified-as record)
                       (economic-event-effort-quantity record)))
              ((commitment? record)
               (values (commitment-action record)
                       (commitment-resource-conforms-to record)
                       (commitment-resource-classified-as record)
                       (commitment-effort-quantity record)))
              ((intent? record)
               (values (intent-action record)
                       (intent-resource-conforms-to record)
                       (intent-resource-classified-as record)
                       (intent-effort-quantity record)))
              (else (error "record-crossings: an intent, a commitment or an event" record))))
    (lambda (action spec-id own-classes effort)
      (call-with-values (lambda () (thing-read resolve-spec spec-id own-classes))
        (lambda (spec classes kinds)
          `((action          . ,action)
            (kinds           . ,kinds)
            (classes         . ,classes)
            (labour-settled? . ,(and effort #t))))))))

(define (record-crossings record resolve-spec)
  (pattern-crossings 'record (record-fact record resolve-spec)))

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (crossings-demo)
  (format #t "~%seed crossings by kind:~%")
  (for-each (lambda (k) (format #t "  ~10a ~a~%" k (crossings-of-kind k)))
            '(avoidable by-choice mirrored))
  (register-crossing! 'data-processing 'mirrored "processes personal data")
  (register-crossing! 'regulated-speech 'mirrored "publishes / broadcasts under licence")
  (format #t "~%after registering data-processing + regulated-speech:~%")
  (format #t "  mirrored ~a~%" (crossings-of-kind 'mirrored))
  (format #t "  unknown 'capital-control kind → ~a (safe default)~%"
          (crossing-kind 'capital-control))
  (format #t "~%declared: tags '(\"crossing:morality-conduct\" \"food\") → ~a~%"
          (classification-crossings '("crossing:morality-conduct" "food")))
  (format #t "kinds of '(\"food\" \"vf:vehicle\") → ~a~%" (kinds-of #f '("food" "vf:vehicle")))
  (format #t "derivable: ~a~%" (derivable-crossings)))

;; run as a program on a host; a page loads this as a library only
(cond-expand
 (guile
  (when (and (pair? (command-line))
             (string-suffix? "legal/crossings.scm" (car (command-line))))
    (crossings-demo)))
 (else))
