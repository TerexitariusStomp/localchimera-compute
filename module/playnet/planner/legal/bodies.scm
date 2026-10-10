;;; legal/bodies.scm — a legal body is its ValueFlows records: an organization
;;; <agent>, the <agent-relationship>s of the people who stand behind it, and
;;; the <economic-resource>s it holds. Everything here is a fold over those.
;;;
;;; Design: docs/legal/bodies.md; playnet.typ §"Standing: held by key, a mask at
;;; the door". A body is what the law can address — an association, a co-op, a
;;; foundation, a purpose trust — and the mask a scope wears at one door
;;; (legal/adapters.scm) is a body too, with the role `adapter`. Its id is its
;;; AID: the k-of-n group identifier of its custodian-stewards
;;; (identity/body-ceremony.scm), or a provisional id until that group is
;;; incepted (`close-body!` rebinds it).
;;;
;;; The record and its tags (facts/agent-tags.scm registers the keys):
;;;   "body"                     the class
;;;   "kind:association"         association · cooperative · foundation ·
;;;                              purpose-trust · unincorporated · adapter
;;;   "role:provider" …          title-holder · provider · buyer · membership ·
;;;                              voice · host · seller · adapter (docs/legal/structure.md §2)
;;;   "jurisdiction:fr"          where it is registered
;;;   "asset-lock:yes|no"        may its assets be sold off or paid out?
;;;   "register:inspectable|closed"  who can learn who its members are
;;;   "quorum:2"                 the k of its stewards' quorum (the KEL's kt is truth)
;;;   "door:<crossing>"          the door a mask opens
;;;   "sells:<spec>"             a good it sells into a market (the selling test)
;;;   "crossing:<x>"             a crossing it declares (legal/crossings.scm)
;;;   "operator"                 it is the body that runs this gateway
;;;
;;; Who stands behind it: <agent-relationship> subject = person AID, object =
;;; body AID, relationship = a role of knowledge/body-roles.scm, in-scope-of =
;;; the scope. A body joins a scope as subject = body AID, object = scope,
;;; role:member — so `scope-member-ids` (doors/service.scm) lists it unchanged.
;;;
;;; What it holds: permits, policies, leases are <economic-resource>s with
;;; `primary-accountable` = the body AID, read by the compliance fold
;;; (legal/compliance.scm `holding-status`); `scope-body-subject` tells the
;;; solve's decorate which body answers for a demand at a cell.
;;;
;;; Admission: the eight tests of docs/legal/structure.md §2 read as crossings
;;; the body trips (`body-crossings`) against the roles it claims, and come out
;;; as findings (knowledge/dsl/findings.scm). The one refusal is two bodies
;;; selling the same good at the same place under one plan.

(define-module (playnet planner legal bodies)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner facts agent-tags) #:select (tag agent-tag-value agent-tag-values))
  #:use-module ((playnet utils operator) #:select (operator-ref))
  #:use-module (playnet planner knowledge body-roles)
  #:use-module ((playnet planner legal crossings)
                #:select (classification-crossings asset-crossings record-crossings))
  #:use-module ((playnet planner legal gate) #:select (legal-asset-fields))
  #:use-module ((playnet planner legal adapters) #:select (mask-subject-of))
  #:use-module ((playnet planner legal registry) #:select (demand-name))
  #:use-module ((playnet planner beyond lot) #:select (make-batch-lot-record))
  #:use-module (playnet planner knowledge dsl findings)
  #:export (body-class make-body body? body-kind body-roles body-jurisdiction
            body-asset-lock? body-register-inspectable? body-quorum body-door
            body-sells body-operator? body-has-role?
            scope-bodies all-bodies body-stewards body-members body-officers
            body-register bodies-of
            declare-body! body-add-steward! body-add-member! close-body!
            body-holdings body-present-holding! body-crossings
            *admission-tests* admission-findings
            scope-body-subject body-reconcile-subject body-holds-spec?
            cell-place))

;;; ─── the record ───────────────────────────────────────────────────────────
(define body-class "body")
(define (agent-tags a) (or (agent-classified-as a) (quote ())))

(define (yes-no v) (if v "yes" "no"))

(define* (make-body id name #:key (kind 'association) (roles '()) (jurisdiction #f)
                    (asset-lock #f) (register 'closed) (quorum #f) (crossings '())
                    (door #f) (sells '()) (extra '()))
  "A body as an organization <agent>: ID (its AID, or a provisional id), NAME,
   and its facts as tags. It is tagged `operator` when NAME is the operator's."
  (make-agent
   #:id id #:type 'organization #:name name
   #:classified-as
   (append (list body-class (tag "kind" kind))
           (map (lambda (r) (tag "role" r)) roles)
           (filter string?
                   (list (tag "jurisdiction" jurisdiction)
                         (tag "asset-lock" (yes-no asset-lock))
                         (tag "register" register)
                         (tag "quorum" quorum)
                         (tag "door" door)
                         (and (equal? name (operator-ref 'name)) "operator")))
           (map (lambda (s) (tag "sells" s)) sells)
           (map (lambda (c) (tag "crossing" c)) crossings)
           extra)))

(define (body? a)
  (and (agent? a) (member body-class (agent-tags a)) #t))
(define (body-kind a)          (and=> (agent-tag-value a "kind") string->symbol))
(define (body-roles a)         (map string->symbol (agent-tag-values a "role")))
(define (body-has-role? a role) (and (memq role (body-roles a)) #t))
(define (body-jurisdiction a)  (agent-tag-value a "jurisdiction"))
(define (body-asset-lock? a)   (equal? "yes" (agent-tag-value a "asset-lock")))
(define (body-register-inspectable? a) (equal? "inspectable" (agent-tag-value a "register")))
(define (body-quorum a)        (and=> (agent-tag-value a "quorum") string->number))
(define (body-door a)          (and=> (agent-tag-value a "door") string->symbol))
(define (body-sells a)         (agent-tag-values a "sells"))
(define (body-operator? a)     (and (member "operator" (agent-tags a)) #t))

;;; ─── who stands behind it : folds over relationships ──────────────────────
(define (rel-subjects-in-role as object role)
  (delete-duplicates
   (filter-map (lambda (r) (and (equal? (agent-relationship-relationship r) role)
                                (agent-relationship-subject r)))
               ($ as 'relationships-as-object object))))

(define (body-stewards as body-id) (rel-subjects-in-role as body-id role:steward))
(define (body-members  as body-id) (rel-subjects-in-role as body-id role:member))
(define (body-officers as body-id) (rel-subjects-in-role as body-id role:officer))

(define (body-register as body)
  "(values inspectable? ids): the people in any role of BODY, or none when its
   register is closed — the privacy read is the fold itself."
  (let ((id (agent-id body)))
    (if (body-register-inspectable? body)
        (values #t (delete-duplicates
                    (append (body-stewards as id) (body-officers as id) (body-members as id))))
        (values #f '()))))

(define (all-bodies as)
  (filter body? ($ as 'organizations)))

(define (scope-bodies as scope-id)
  "The bodies that are members of SCOPE-ID, in the order the store knows them."
  (filter-map (lambda (r)
                (and (equal? (agent-relationship-relationship r) role:member)
                     (equal? (agent-relationship-object r) scope-id)
                     (let ((a ($ as 'get-agent (agent-relationship-subject r))))
                       (and a (body? a) a))))
              ($ as 'relationships-in-scope scope-id)))

(define (bodies-of as person-aid)
  "The bodies PERSON-AID holds any role in."
  (delete-duplicates
   (filter-map (lambda (r)
                 (and (member (agent-relationship-relationship r) (body-role-ids))
                      (let ((a ($ as 'get-agent (agent-relationship-object r))))
                        (and a (body? a) a))))
               ($ as 'relationships-as-subject person-aid))
   (lambda (a b) (equal? (agent-id a) (agent-id b)))))

;;; ─── writing the records ──────────────────────────────────────────────────
(define (relate! as subject object role scope-id)
  ($ as 'add-relationship
     (make-agent-relationship #:id (string-append role ":" subject "→" object)
                              #:subject subject #:object object
                              #:relationship role #:in-scope-of scope-id)))

(define (declare-body! as scope-id id name facts)
  "BODY stands in AS as a member of SCOPE-ID. FACTS is an alist of the keys
   make-body takes (kind role roles jurisdiction asset-lock register quorum
   door sells crossings). Returns the agent."
  (seed-body-roles! as)
  (let* ((role  (assq-ref facts 'role))
         (roles (append (if role (list (if (string? role) (string->symbol role) role)) '())
                        (or (assq-ref facts 'roles) '())))
         (body  (make-body id name
                           #:kind (or (assq-ref facts 'kind) 'association)
                           #:roles roles
                           #:jurisdiction (assq-ref facts 'jurisdiction)
                           #:asset-lock (let ((v (assq-ref facts 'asset-lock)))
                                          (and v (not (member v '("no" #f "false")))))
                           #:register (or (assq-ref facts 'register) 'closed)
                           #:quorum (assq-ref facts 'quorum)
                           #:door (assq-ref facts 'door)
                           #:sells (or (assq-ref facts 'sells) '())
                           #:crossings (or (assq-ref facts 'crossings) '()))))
    ($ as 'add-agent body)
    (relate! as id scope-id role:member scope-id)
    body))

(define (body-add-steward! as scope-id body-id person-aid)
  (relate! as person-aid body-id role:steward scope-id))
(define (body-add-member! as scope-id body-id person-aid)
  (relate! as person-aid body-id role:member scope-id))

(define (close-body! as scope-id provisional-id aid)
  "The body declared under PROVISIONAL-ID now stands under AID, its group
   identifier: the agent and every relationship naming it move; the
   provisional agent goes. Returns the agent under AID."
  (let* ((old (or ($ as 'get-agent provisional-id)
                  (error "close-body!: no body" provisional-id)))
         (new (make-agent #:id aid #:type 'organization #:name (agent-name old)
                          #:note (agent-note old) #:image (agent-image old)
                          #:primary-location (agent-primary-location old)
                          #:classified-as (agent-classified-as old)
                          #:availability-window (agent-availability-window old))))
    ($ as 'add-agent new)
    (for-each
     (lambda (r)
       (let ((s (agent-relationship-subject r)) (o (agent-relationship-object r)))
         (when (or (equal? s provisional-id) (equal? o provisional-id))
           ($ as 'remove-relationship (agent-relationship-id r))
           (relate! as (if (equal? s provisional-id) aid s)
                    (if (equal? o provisional-id) aid o)
                    (agent-relationship-relationship r)
                    (or (agent-relationship-in-scope-of r) scope-id)))))
     ($ as 'all-relationships))
    ($ as 'remove-agent provisional-id)
    new))

;;; ─── what it holds ────────────────────────────────────────────────────────
(define (body-holdings observer body-id)
  ($ observer 'inventory-for-agent body-id))

(define* (body-present-holding! observer body-id spec-id
                                #:key (name spec-id) (issuer #f) (valid-until #f) (ref #f)
                                (id (string-append "held:" body-id ":" spec-id)))
  "A permit, policy or lease BODY-ID holds: a resource conforming to SPEC-ID in
   its custody, expiring at VALID-UNTIL (ISO date) when given. Returns its id."
  (let ((r (make-economic-resource
            #:id id #:name name #:conforms-to spec-id
            #:classified-as (filter string? (list "credential" (tag "issuer" issuer) (tag "ref" ref)))
            #:onhand-quantity (make-measure 1 "u") #:accounting-quantity (make-measure 1 "u")
            #:primary-accountable body-id #:state "active"
            #:lot (and valid-until
                       (make-batch-lot-record (string-append id ":lot") #f valid-until)))))
    ($ observer 'record-resource r)
    id))

;;; ─── the crossings a body trips ──────────────────────────────────────────
(define* (body-crossings as observer body #:key (claims '()) (resolve-spec (lambda (id) #f)))
  "Declared on the body ∪ read off what it holds ∪ read off the events it
   provides ∪ read off CLAIMS it is party to (the observer keeps a claim's
   target, not its record, so the caller brings the records). OBSERVER #f:
   only the declared ones. RESOLVE-SPEC: spec id → its <resource-specification>
   (the recipe store's), so a record's kind of thing is read as the law reads it."
  (let* ((id (agent-id body))
         (resolve (lambda (sid) (and observer ($ observer 'get-resource sid))))
         (declared (classification-crossings (agent-tags body)))
         (held (if observer
                   (asset-crossings (map (lambda (r) (legal-asset-fields r resolve))
                                         (body-holdings observer id))
                                    resolve-spec)
                   '()))
         (resolve-record (lambda (rid) (or (and observer ($ observer 'get-event rid))
                                           (find (lambda (c) (equal? (claim-id c) rid)) claims))))
         (resolve-agreement (lambda (aid) (and observer ($ observer 'get-agreement aid))))
         (read-record (lambda (r) (record-crossings r resolve-spec #:resolve-agreement resolve-agreement
                                                    #:resolve-record resolve-record)))
         (done (if observer
                   (append-map (lambda (e)
                                 (if (equal? (economic-event-provider e) id) (read-record e) '()))
                               ($ observer 'events-for-agent id))
                   '()))
         ;; money claimed by or owed to the body: a claim it receives for the
         ;; use of what it lent reads as metered use
         (claimed (append-map (lambda (c)
                                (if (or (equal? (claim-receiver c) id) (equal? (claim-provider c) id))
                                    (read-record c) '()))
                              claims))
         (sold (if (pair? (body-sells body)) '(public-sale) '())))
    (delete-duplicates (append declared held done claimed sold))))

;;; ─── admission : the eight tests, as findings ────────────────────────────
;;; (test crossing roles-where-it-is-fine severity-otherwise detail)
(define *admission-tests*
  '((selling     public-sale          (seller adapter)              error
     "sells into a market: coordination with another seller of the same good is the one refusal")
    (unpaid-work credit-contribution  (provider host voice membership title-holder buyer) error
     "takes credited unpaid work: lawful in a charity or an association; a business that sells reads it as unpaid wages")
    (voice       organise             (voice membership)            warning
     "presses a program: a charity's political voice is limited; a union's or a plain association's is free")
    (licence     hold-funds           ()                            warning
     "holds or pays out funds: a licensed door comes with it")
    (licence     pool-risk            ()                            warning
     "insures or pools risk: a licensed door comes with it")
    (licence     act-on-person        ()                            warning
     "performs a regulated act on a person: a licensed door comes with it")
    (cost-share  cost-share           ()                            info
     "bears a lent thing's running cost as a fixed sum by period: a share, not a rent")
    (lessor      metered-use          (seller)                      warning
     "is paid for a lent thing by the use made of it: a lease in all but name, and the role of a lessor")))

(define (finding-about severity kind body detail)
  (finding severity kind (agent-id body) (string-append (agent-name body) " " detail)))

(define (crossing-findings body crossings)
  (append-map
   (lambda (row)
     (let ((test (list-ref row 0)) (c (list-ref row 1)) (fine (list-ref row 2))
           (sev (list-ref row 3)) (detail (list-ref row 4)))
       (cond ((not (memq c crossings)) '())
             ((and (pair? fine) (any (lambda (r) (memq r fine)) (body-roles body)))
              (list (finding-about 'info test body detail)))
             (else (list (finding-about sev test body detail))))))
   *admission-tests*))

(define (structural-findings body crossings holds-anything?)
  (append
   ;; unpaid work in a selling body
   (if (and (memq 'public-sale crossings) (memq 'credit-contribution crossings))
       (list (finding-about 'error 'unpaid-work body
                            "sells and takes credited work: the credit reads as unpaid wages"))
       '())
   ;; shield: attaches to a provider
   (if (body-has-role? body 'provider)
       (list (finding-about 'info 'shield body
                            "provides as a charitable body: donation and good-faith shields attach to it"))
       '())
   ;; person: an unincorporated group that holds anything answers personally
   (if (and (eq? (body-kind body) 'unincorporated) holds-anything?)
       (list (finding-about 'error 'person body
                            "is no legal person and holds something: its members answer for it personally"))
       '())
   ;; lock: a title holder without an asset lock
   (if (and (or (memq 'own-property crossings) (body-has-role? body 'title-holder))
            (not (body-asset-lock? body)))
       (list (finding-about 'error 'lock body
                            "holds property with no asset lock: the property can be sold off or paid out"))
       '())
   ;; register
   (if (body-register-inspectable? body)
       (list (finding-about 'info 'register body
                            "keeps a register others can inspect"))
       '())))

(define (same-market-refusals bodies)
  "Two bodies selling the same good in the same jurisdiction: one error naming both."
  (let loop ((bs bodies) (acc '()))
    (if (null? bs) (reverse acc)
        (let* ((a (car bs))
               (clash (find (lambda (b)
                              (and (equal? (body-jurisdiction a) (body-jurisdiction b))
                                   (pair? (lset-intersection equal? (body-sells a) (body-sells b)))))
                            (cdr bs))))
          (loop (cdr bs)
                (if clash
                    (cons (finding 'error 'selling (list (agent-id a) (agent-id clash))
                                   (format #f "~a and ~a both sell ~a in ~a under one plan: coordination between competitors"
                                           (agent-name a) (agent-name clash)
                                           (car (lset-intersection equal? (body-sells a) (body-sells clash)))
                                           (body-jurisdiction a)))
                          acc)
                    acc))))))

(define* (admission-findings as observer scope-id #:key (bodies (scope-bodies as scope-id)) (claims '())
                             (resolve-spec (lambda (id) #f)))
  "The eight tests over every body of SCOPE-ID, most severe first. CLAIMS:
   the money claims the bodies are party to, read for metered use."
  (findings-by-severity
   (append
    (append-map (lambda (b)
                  (let ((cs (body-crossings as observer b #:claims claims #:resolve-spec resolve-spec)))
                    (append (crossing-findings b cs)
                            (structural-findings b cs (and observer (pair? (body-holdings observer (agent-id b))))))))
                bodies)
    (same-market-refusals bodies))))

;;; ─── which body answers for a demand at a cell ────────────────────────────
(define (cell-place cell)
  (let ((at (string-index cell #\@))) (if at (substring cell 0 at) cell)))

(define* (scope-body-subject as observer bodies #:key (path-of (lambda (place) (list (list place)))))
  "(proc cell spec) → the body that answers for SPEC at CELL: the one holding a
   resource conforming to it; else the one body standing in the cell's
   jurisdiction, a mask before any other; else #f (nobody is named, as today)."
  (lambda (proc cell spec)
    (let* ((place (cell-place cell))
           (chain (apply append (path-of place)))
           (holding (find (lambda (b)
                            (any (lambda (r) (equal? (economic-resource-conforms-to r) spec))
                                 (body-holdings observer (agent-id b))))
                          bodies))
           (here (filter (lambda (b) (member (body-jurisdiction b) chain)) bodies))
           (masks (filter (lambda (b) (body-has-role? b 'adapter)) here))
           (one (lambda (bs) (and (pair? bs) (null? (cdr bs)) (agent-id (car bs))))))
      (cond (holding (agent-id holding))
            ((one masks))
            ((one here))
            (else #f)))))

(define (body-holds-spec? observer)
  "(body spec) → does BODY hold a resource conforming to SPEC?"
  (lambda (b spec)
    (any (lambda (r) (equal? (economic-resource-conforms-to r) spec))
         (body-holdings observer (agent-id b)))))

(define* (body-reconcile-subject as observer bodies #:key (person-of (lambda (d) 'person)) (fallback 'scope))
  "A `subject-of` for compliance.scm `reconcile`: the one `mask-subject-of`
   makes (legal/adapters.scm), a body covering a demand by holding its spec."
  (mask-subject-of bodies #:covers? (body-holds-spec? observer) #:id-of agent-id
                   #:person-of person-of #:fallback fallback))
