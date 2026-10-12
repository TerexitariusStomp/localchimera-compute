;;; inventory.scm — what a scope holds, as the browser's inventory reads it
;;;
;;; Drives the browser's "inventory" tab. Two builders, two methods:
;;;
;;;   build-inventory-snapshot — bulk listing of resource specs in the
;;;     scope plus the concrete economic resources conforming to them,
;;;     filtered by plan when one is selected.
;;;
;;;   build-resource-detail — full custody history (via the observer's
;;;     trace-resource walk) and contained-in children for one resource.
;;;
;;; Resources are filtered to the current scope by EconomicResource's
;;; custodian-scope (falling back to primary-accountable). When a plan
;;; is selected, the result is further narrowed to resources touched by
;;; events that fulfill commitments in that plan.

(define-module (playnet doors inventory)
  #:use-module ((playnet doors record-rows) #:select (lookup-spec-name))
  #:use-module ((playnet scope live) #:select (find-recipe-process-for-spec))
  #:use-module ((playnet vf formulas actions) #:select (input-action? occupying-actions relocating-actions))
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond lot)
  #:use-module ((playnet vf aggregation containment) #:select (containment-first))
  #:use-module ((playnet observation observer) #:select (event-stamps))
  #:use-module ((playnet vf facts rail) #:select (spec-rail))
  #:use-module ((playnet algorithms rollup) #:select (crystallized-snlt-for-spec))
  #:export (recipe-flow->flow-alist recipes-conforming resolve-recipe-process proc-use-specs build-process-context scope-inventory-wire resource->inv-alist spec->inv-alist build-inventory-snapshot build-resource-detail))

(define* (resource->inv-alist r obs as #:optional (rs #f))
  "Project an <economic-resource> into the inventory wire format.
   OBS is consulted for has-children?; AS resolves the custodian to a
   human-readable agent name; RS (the scope's own recipe-store) scopes the
   rail read so it can never be a different scope's (rail.scm spec-rail)."
  (let* ((rid       (economic-resource-id r))
         ;; who HOLDS it (the observer's one word, custodian-scope), else who owns it
         (cust      (or (economic-resource-custodian-scope r)
                        (economic-resource-primary-accountable r)))
         (cust-rec  (and cust ($ as 'get-agent cust)))
         (cust-name (or (and cust-rec (agent-name cust-rec))
                        cust ""))
         (oh        (economic-resource-onhand-quantity r))
         (kids      ($ obs 'resources-contained-in rid))
         (lot       (let ((l (economic-resource-lot r)))
                      (and l (batch-lot-record? l) l)))
         ;; where it is: its own place, else the place of the nearest thing it
         ;; sits in that has one
         (place     (containment-first r economic-resource-current-location
                                       #:parent-of economic-resource-contained-in
                                       #:resolve (lambda (id) ($ obs 'get-resource id)))))
    `((id . ,rid)
      (name . ,(or (economic-resource-name r) rid))
      (image . ,(economic-resource-image r))
      (conforms-to . ,(economic-resource-conforms-to r))
      (tracking-identifier . ,(economic-resource-tracking-identifier r))
      (onhand . ,(or (measure->qty oh) 0))
      (unit . ,(or (measure->unit oh) ""))
      ;; WHO OWNS IT, as its own field. `custodian` below falls back to the
      ;; custodian scope when nobody is accountable — fine while everything had
      ;; an owner, but a thing held by a box would then read as owned BY the
      ;; box. Rights and custody are two facts and the wire says both.
      (primary-accountable . ,(economic-resource-primary-accountable r))
      (custodian . ,cust)
      (custodian-name . ,cust-name)
      (custodian-scope . ,(economic-resource-custodian-scope r))
      (location . ,place)
      (stage . ,(economic-resource-stage r))
      (state . ,(economic-resource-state r))
      (contained-in . ,(economic-resource-contained-in r))
      ;; the lot: its code, its date, and which date that is
      (lot-code . ,(and lot (batch-lot-record-batch-lot-code lot)))
      (expires . ,(and lot (batch-lot-record-expiration-date lot)))
      (expires-kind . ,(and lot (and=> (batch-lot-record-expiration-kind lot) symbol->string)))
      ;; the rail: 'communal | 'individual-claimable | #f. The dial maps it to
      ;; rail common/claim/own; the shop face lists only individual-claimable.
      ;; Read off the recipes (rail.scm spec-rail): individual when some claim
      ;; recipe consumes it for someone, communal when only the scope's do; the
      ;; record's own field is the import vocabulary that stands until a plan has
      ;; spoken, and a means carries no rail on the wire.
      (distribution-mode . ,(case (spec-rail (economic-resource-conforms-to r) rs)
                              ((individual) "individual-claimable")
                              ((communal)   "communal")
                              (else (and=> (economic-resource-distribution-mode r) symbol->string))))
      (has-children? . ,(not (null? (or kids '())))))))

(define* (spec->inv-alist s resource-alists #:optional (rs #f))
  "Project a <resource-specification> into the inventory wire format.
   RESOURCE-ALISTS is the already-shaped, already-filtered resource list
   for the scope+plan; we filter it by conforms-to to compute counts.
   RS (recipe-store), when given, prices the spec: crystallized SNLT per
   unit — what one unit costs society, hence what a claim costs the
   claimant (playnet.typ: credit uses SNLT_crystallized, never direct)."
  (let* ((sid (resource-specification-id s))
         (mine (filter (lambda (r) (equal? (assq-ref r 'conforms-to) sid))
                       resource-alists))
         (count (length mine))
         (total (fold (lambda (r acc)
                        (let ((oh (assq-ref r 'onhand)))
                          (+ acc (if (number? oh) oh 0))))
                      0 mine))
         (default-unit (or (resource-specification-default-unit-of-resource s)
                           (and (pair? mine) (assq-ref (car mine) 'unit))
                           "")))
    `((id . ,sid)
      (name . ,(or (resource-specification-name s) sid))
      (note . ,(or (resource-specification-note s) ""))
      (image . ,(resource-specification-image s))
      (categories . ,(or (resource-specification-resource-classified-as s) '()))
      (default-unit . ,default-unit)
      (substitutable . ,(resource-specification-substitutable s))
      (resource-count . ,count)
      (onhand-total . ,total)
      ;; crystallized hours per unit (direct + embodied inputs — the credit
      ;; measure); #f when the spec has no recipe to price it by
      (snlt . ,(and rs
                    (let ((v (crystallized-snlt-for-spec rs sid)))
                      (and (number? v) (finite? v) v)))))))

(define (collect-plan-resource-ids ps obs plan-id)
  "Resource IDs touched by events that fulfill commitments belonging to
   PLAN-ID. Walks plan-store -> observer -> events -> resource refs.
   Empty when the plan has no observed activity yet."
  (let* ((cmts (or ($ ps 'commitments-for-plan plan-id) '()))
         (cmt-ids (map commitment-id cmts)))
    (delete-duplicates
      (append-map
        (lambda (cid)
          (append-map
            (lambda (e)
              (filter string?
                      (list (economic-event-resource-inventoried-as e)
                            (economic-event-to-resource-inventoried-as e))))
            (or ($ obs 'fulfilled-by cid) '())))
        cmt-ids))))

(define (build-inventory-snapshot scope-root scope-id plan-id)
  "Bulk inventory listing for a scope (and optionally a plan within it).
   Returns plain alists — never records or actor refs — so the OCapN
   wire format stays browser-friendly."
  (let* ((rs    ($ scope-root 'recipe-store))
         (as    ($ scope-root 'agent-store))
         (obs   ($ scope-root 'observer))
         (ps    ($ scope-root 'plan-store))
         (specs (or ($ rs 'all-resource-specs) '()))
         ;; Plan filter: when plan-id is set, only resources touched by
         ;; events fulfilling commitments in that plan survive.
         (in-plan?
           (cond
             ((not plan-id) (lambda (r) #t))
             (else
              (let ((ids (collect-plan-resource-ids ps obs plan-id)))
                (lambda (r)
                  (and (member (economic-resource-id r) ids) #t))))))
         ;; Scope filter: held by this scope. We accept the resource if
         ;; either custodian-scope or primary-accountable matches scope-id.
         ;; If neither field is set, the resource is unattributed and we
         ;; surface it (a bare seed-resource has no custodian until events
         ;; flow through it).
         (in-scope?
           (lambda (r)
             (let ((cs (economic-resource-custodian-scope r))
                   (pa (economic-resource-primary-accountable r)))
               (or (and (not cs) (not pa))
                   (equal? cs scope-id)
                   (equal? pa scope-id)))))
         ;; Walk every spec once, gather conforming resources, and
         ;; filter. delete-duplicates keeps the first occurrence so a
         ;; resource appearing under multiple specs (shouldn't happen)
         ;; only shows once.
         (resource-records
           (delete-duplicates
             (filter (lambda (r) (and (in-scope? r) (in-plan? r)))
                     (append-map
                       (lambda (s)
                         (or ($ obs 'conforming-resources
                                 (resource-specification-id s))
                             '()))
                       specs))
             (lambda (a b)
               (equal? (economic-resource-id a)
                       (economic-resource-id b)))))
         (resource-alists
           (map (lambda (r) (resource->inv-alist r obs as rs)) resource-records))
         (spec-alists
           (map (lambda (s) (spec->inv-alist s resource-alists rs)) specs))
         ;; Drop specs with no in-scope+in-plan resources so the grid
         ;; reflects what this scope actually holds. The "library of all
         ;; possible specs" view can be added later as a separate mode.
         (visible-specs
           (filter (lambda (sa) (> (assq-ref sa 'resource-count) 0))
                   spec-alists))
         (category-tree
           (sort
             (delete-duplicates
               (append-map
                 (lambda (sa) (or (assq-ref sa 'categories) '()))
                 visible-specs)
               equal?)
             string<?))
         (category-tree-pairs
           (map (lambda (uri) (cons uri uri)) category-tree)))
    `((scope-id . ,scope-id)
      (scope-name . ,($ scope-root 'name))
      (plan-id . ,plan-id)
      (category-tree . ,category-tree-pairs)
      (specs . ,visible-specs)
      (resources . ,resource-alists))))

(define (event->custody-step e as)
  "Project an <economic-event> into a single custody-history step."
  (let* ((aid       (or (economic-event-receiver e)
                        (economic-event-provider e)))
         (agent-rec (and aid ($ as 'get-agent aid)))
         (aname     (or (and agent-rec (agent-name agent-rec))
                        aid ""))
         (m         (or (economic-event-resource-quantity e)
                        (economic-event-effort-quantity e)))
         ;; when: the close of the event's interval, the observer's one reading
         (at        (or (and=> (event-stamps e) cdr) "")))
    `((event-id . ,(economic-event-id e))
      (action . ,(let ((a (economic-event-action e)))
                   (if (symbol? a) (symbol->string a) (or a ""))))
      (provider . ,(economic-event-provider e))
      (receiver . ,(economic-event-receiver e))
      (agent . ,aid)
      (agent-name . ,aname)
      (qty . ,(or (measure->qty m) 0))
      (unit . ,(or (measure->unit m) ""))
      (when . ,at)
      (note . ,(or (economic-event-note e) "")))))

(define (build-resource-detail scope-root resource-id)
  "Full custody history (via observer's trace-resource walk) plus
   contained-in children for RESOURCE-ID. Returns #f resource on miss."
  (let* ((as  ($ scope-root 'agent-store))
         (obs ($ scope-root 'observer))
         (rs  ($ scope-root 'recipe-store))
         (r   ($ obs 'get-resource resource-id)))
    (cond
      ((not r)
       `((id . ,resource-id) (resource . #f)
         (children . ()) (custody-history . ())
         (current-custodian . #f) (current-custodian-name . "")))
      (else
       (let* ((events  (or ($ obs 'trace-resource resource-id) '()))
              (history (map (lambda (e) (event->custody-step e as)) events))
              (kids    (or ($ obs 'resources-contained-in resource-id) '()))
              (children (map (lambda (c) (resource->inv-alist c obs as rs)) kids))
              ;; Current custodian: the observer's one word (custodian-scope,
              ;; written by its implied-transfer phase), else the owner
              (cust (or (economic-resource-custodian-scope r)
                        (economic-resource-primary-accountable r)))
              (cust-name
                (cond
                  (cust (let ((a ($ as 'get-agent cust)))
                          (if a (agent-name a) cust)))
                  (else ""))))
         `((id . ,resource-id)
           (resource . ,(resource->inv-alist r obs as rs))
           (children . ,children)
           (current-custodian . ,cust)
           (current-custodian-name . ,(or cust-name ""))
           (custody-history . ,history)))))))

;; the scope's on-hand stock, for the inventory tab. Projects every economic
;; resource through resource->inv-alist into { resources: [...] };
;; the browser's normLive maps conforms-to/onhand/unit/stage/state/location and
;; distribution-mode→rail, falling back to the demo stock when this is absent.
;; #f when the scope has no observer (keeps the wire lean rather than empty-noisy).
(define (scope-inventory-wire scope-root scope-id)
  (let* ((obs   ($ scope-root 'observer))
         (as    ($ scope-root 'agent-store))
         (specs ($ scope-root 'recipe-store))
         (rs    ($ obs 'all-resources))
         ;; is this resource a CONTAINER — a thing whose use keeps what is in it
         ;; where it is? That is one flag on its ResourceSpecification
         ;; (keep-in-place), and it is the difference between a silo, a fridge, a
         ;; lending shelf, a box under a bridge — and a sack of flour. The wire
         ;; carries it so a reader can tell a container from its contents without
         ;; fetching every spec, and so an EMPTY container is still a container.
         (container?
          (lambda (r)
            (let* ((spec-id (economic-resource-conforms-to r))
                   (s (and spec-id ($ specs 'get-resource-spec spec-id))))
              (and s (resource-spec-keep-in-place? s) #t)))))
    (and (pair? rs)
         `((resources . ,(map (lambda (r)
                                (cons (cons 'container? (container? r))
                                      (resource->inv-alist r obs as specs)))
                              rs))))))

;;; ── Process context (detail panel) ───────────────────────────────────

(define (recipe-flow->flow-alist f rs is-input?)
  (let* ((spec (recipe-flow-resource-conforms-to f))
         (rq   (recipe-flow-resource-quantity f))
         (eq   (recipe-flow-effort-quantity f))
         (m    (or rq eq)))
    `((spec . ,spec)
      (spec-name . ,(or (lookup-spec-name rs spec) spec ""))
      (qty . ,(or (measure->qty m) 1))
      (unit . ,(or (measure->unit m) ""))
      (action . ,(recipe-flow-action f))
      (is-input . ,is-input?))))

(define (recipes-conforming rs aspect-id)
  "All recipe ids that PERFORM ASPECT-ID — any recipe-process whose
   process-conforms-to matches. The structural gate a legal aspect (or spec) opens:
   which recipes it enables. Generalizes find-recipe-process-for-spec to every hit.
   Injected into (explain-claim …) as #:gated-by, keeping the provenance bridge
   decoupled from the planner."
  (if (not aspect-id) '()
      (let ((want (if (symbol? aspect-id) (symbol->string aspect-id) aspect-id)))
        (filter-map
         (lambda (r)
           (let ((rps ($ rs 'processes-for-recipe (recipe-id r))))
             (and (any (lambda (rp)
                         (equal? (recipe-process-process-conforms-to rp) want))
                       rps)
                  (recipe-id r))))
         ($ rs 'all-recipes)))))

;; The <recipe-process> PROCESS-ID stands for: a recipe-process id (e.g.
;; 'rp-meeting') directly, else a dynamic id (a performed trip, dependent demand)
;; through the <process> record the books or the registry hold and its based-on spec.
(define (resolve-recipe-process scope-root process-id)
  (let ((rs   ($ scope-root 'recipe-store))
        (obs  ($ scope-root 'observer))
        (preg ($ scope-root 'process-registry)))
    (or ($ rs 'get-recipe-process process-id)
        (let ((p (or ($ obs 'get-process process-id) ($ preg 'get process-id))))
          (and p (find-recipe-process-for-spec rs (process-based-on p)))))))

;; The specs PROCESS-ID engages without consuming — its `use` flows, the Svc|
;; capacities a socialized means lends — what the steward gate asks about.
(define (proc-use-specs scope-root process-id)
  (let ((rp (false-if-exception (resolve-recipe-process scope-root process-id))))
    (if (not rp) '()
        ;; the means a process puts in someone's hands: what it uses, and
        ;; what it carries (a pickup — the key a carrier walks to the door)
        (filter-map (lambda (f) (and (memq (recipe-flow-action f) (append occupying-actions (filter input-action? relocating-actions)))
                                     (recipe-flow-resource-conforms-to f)))
                    (car ($ ($ scope-root 'recipe-store) 'flows-for-process
                            (recipe-process-id rp)))))))

(define (build-process-context scope-root process-id)
  (let* ((rs ($ scope-root 'recipe-store))
         (rp (resolve-recipe-process scope-root process-id)))
    (cond
      ((not rp)
       `((proc . ,process-id)
         (proc-name . #f)
         (inputs . ())
         (outputs . ())
         (upstream . ())
         (downstream . ())))
      (else
       (let* ((rp-id (recipe-process-id rp))
              (flows-pair ($ rs 'flows-for-process rp-id))
              (in-flows  (car flows-pair))
              (out-flows (cdr flows-pair)))
         `((proc . ,process-id)
           (proc-name . ,(or (recipe-process-name rp) process-id))
           (inputs . ,(map (lambda (f) (recipe-flow->flow-alist f rs #t)) in-flows))
           (outputs . ,(map (lambda (f) (recipe-flow->flow-alist f rs #f)) out-flows))
           (upstream . ())
           (downstream . ())))))))