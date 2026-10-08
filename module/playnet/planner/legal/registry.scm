;;; legal/registry.scm — guarded DEMANDS folded over an activity context.
;;;
;;; Design: docs/planning/legal/legal-crossings.md. The elegant general core: a legal
;;; rule is  (guard : context → bool) → demands,  and the legal exterior of an
;;; activity is the FOLD  ⋃ { d | (guard,d) ∈ rules, guard(context) }.
;;;
;;; A DEMAND is what the state asks of a *chosen* activity, in one of four kinds
;;; — the four activity-triggered modes of state interaction:
;;;   obtain  — a credential to get  (authorisation: licence / permit / registration / entity)
;;;   pay     — a levy               (tax / duty / fee)
;;;   tell    — a disclosure         (report / filing / beneficial-owner / breach notice)
;;;   forbid  — a prohibition        (no demand satisfies it; relocate / exposed-adapter / don't)
;;; Two further modes stand OUTSIDE this fold and are noted, not folded:
;;;   standing    — the capacity to be a legal party (adjudication): a FIXTURE
;;;                 (one entity), drawn on reactively, not a per-activity demand.
;;;   subjection  — the state acting on you unchosen (criminal / eminent domain /
;;;                 crackdown): not derivable; met structurally (pseudonymity,
;;;                 exposed adapter, dual power).
;;;
;;; "Crossing" is a coarse index into the guards; "jurisdiction" is one guard
;;; among several (spatial / personal / extraterritorial). A demand may carry a
;;; SPEC (a standard) — only `obtain` permits/licences do — which feeds the
;;; reform diff (reform.scm).
;;;
;;; The catalogue lives as `^legal-registry` (legal-registry-actor.scm), a
;;; governance actor like tension-registry's: register/repeal are event-sourced
;;; production-governance acts, and each ^scope-root carries one, persisted with
;;; its other registries and seeded from a rule-pack folder (load-rule-packs).
;;; legal/gate.scm folds it into every solve at the door (live.scm).
;;;
;;; The worked example (five rules, three contexts) is tests/planner/legal-example-rules.scm.

;; The whole file is the interface: everything it defines was already in scope
;; for every includer, so exporting the lot preserves what they saw. `vf-record-type`
;; stays #:select'ed — a type is its name, the same object on both sides of the seam.
(define-module (playnet planner legal registry)
  #:use-module ((playnet utils records) #:select (vf-record-accessor vf-record-constructor vf-record-predicate vf-record-type))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((playnet planner facts places) #:select (place-extra-ref place-parent-of place-known?))
  ;; `rule` and `negate` collide with core: core's `rule` is an unbound slot, and
  ;; core's `negate` negates a predicate — near enough in spirit to this guard
  ;; combinator to be worth shadowing on purpose. #:replace is how Guile lets a
  ;; module say the override is deliberate, and it silences the warning.
  #:replace (rule negate)
  #:export (<demand> make-demand demand? demand-kind demand-name
            demand-rides demand-spec demand-detail demand-ref demand-retain
            demand-renew obtain pay tell forbid %demand-kinds
            demand-kind->vf-action demand=? demand-weight demands-weight bill-weight
            *burden-tiers* guard-atoms guard-places guard-crossings border-rule? read-pack pack-section regime-endpoints
            place-chain place-endpoints rule-speaks-of provenance-problems
            guard-asks rule-doubted hit-unknowns custody-unknown
            <legal-context> %make-legal-context common-ancestor paths-cross? endpoints-diverge?
            legal-context ctx-crossings ctx-place-path ctx-agents ctx-assets
            ctx-act ctx-endpoints ctx-channel ctx-border-level always
            on-crossing in-jurisdiction place-has at-origin at-destination border-level-is
            act-is via-channel agent-has asset-has for-citizens-of
            all-of any-of compile-guard <legal-rule>
            %make-legal-rule legal-rule-guard-form legal-rule? legal-rule-guard
            legal-rule-demands legal-rule-label legal-rule-source legal-rule-as-of legal-rule-confidence
            legal-rule-until rule-in-force? legal-rule-cancels rule-may-cancel?
            legal-rule-steward demand->sexp sexp->demand rule->sexp sexp->rule
            rules->sexp sexp->rules save-rule-pack load-rule-pack pack-paths load-rule-packs
            jurisdiction-path
            %bill-keys demand-bill-key bill-ref legal-demands
            %confidences rule-sure? forbid-sure? bill-forbid bill-unread %stances bill-stance stance-forbids?))

(cond-expand (guile) (else
  ;; a page has no file system: no file is there to read, and none is written
  (define (file-exists? path) #f)
  (define (call-with-input-file path proc) (error "no file system here" path))
  (define (call-with-output-file path proc) (error "no file system here" path))
  (define (set-port-encoding! port encoding) #t)
  (define (in-vicinity dir file) (string-append dir "/" file))
  (define (%search-load-path file) #f)))


(cond-expand (guile) (else
  (define (string-filter pred s)           ; the characters of S that PRED keeps (Hoot has no srfi-13)
    (list->string (let loop ((cs (string->list s)))
                    (cond ((null? cs) '())
                          ((pred (car cs)) (cons (car cs) (loop (cdr cs))))
                          (else (loop (cdr cs)))))))))


;; a directory of packs is read on a host; a page has no directory to scan
(cond-expand (guile (use-modules (ice-9 ftw)))
             (else (define (scandir dir) '())))


;;; ─── Demand : the four activity-triggered modes, one record ──────────────
;;; kind  ∈ obtain | pay | tell | forbid
;;; rides ∈ entity | person | #f   (facility-vs-competence, for `obtain`)
;;; spec  : a set of atoms (the standard) | #f   (only spec-bearing obtains)
;;; detail: alist — issuer/per (obtain), base/rate (pay), to/discloses (tell),
;;;                 reason (forbid)
(define <demand>
  (vf-record-type 'Demand
    '((immutable kind) (immutable name) (immutable rides)
      (immutable spec) (immutable detail))))
(define make-demand   (vf-record-constructor <demand>))
(define demand?       (vf-record-predicate <demand>))
;; the four kinds a demand can be — the one list the statute extractor's prompt
;; and check read, so a kind added here reaches the model the same day
(define %demand-kinds '(obtain pay tell forbid))
(define demand-kind   (vf-record-accessor  <demand> 'kind))
(define demand-name   (vf-record-accessor  <demand> 'name))
(define demand-rides  (vf-record-accessor  <demand> 'rides))
(define demand-spec   (vf-record-accessor  <demand> 'spec))
(define demand-detail (vf-record-accessor  <demand> 'detail))
(define (demand-ref d key) (assq-ref (demand-detail d) key))
(define (demand-retain d) (demand-ref d 'retain))   ; statutory keep-period (years) | #f
;;; RENEW — the cadence on which a held credential or a filing comes round again,
;;; in the vocabulary compliance.scm's `obligation-for` matches:
;;;   ('renew-before . days)  renew this many days before it expires
;;;   ('every . period)       a recurring filing, the next one due at period end
;;; #f ⇒ nothing recurs. It rides the RULE, like `retain`, so the calendar needs
;;; no side-table: the law that demands a thing also says how often.
(define (demand-renew d) (demand-ref d 'renew))

;;; the four constructors — the demand vocabulary. `direction` (import |
;;; export | #f) marks a border demand's SIDE: an import duty falls on the
;;; destination, an export certificate on the origin (§2.6).
;; `retain` — the statutory keep-period (YEARS) for the artifact this demand
;; yields; a datum that travels WITH the rule, stamped onto the filing at render
;; time (legal/filings.scm retention-sweep), so retention needs no global side-table.
(define* (obtain #:key rides name (issuer #f) (per #f) (spec #f) (direction #f)
                      (retain #f) (renew #f))
  (make-demand 'obtain name rides spec
               `((issuer . ,issuer) (per . ,per) (direction . ,direction)
                 (retain . ,retain) (renew . ,renew))))
(define* (pay #:key name (base #f) (rate #f) (direction #f))
  (make-demand 'pay name 'entity #f `((base . ,base) (rate . ,rate) (direction . ,direction))))
(define* (tell #:key name (to #f) (discloses '()) (direction #f) (retain #f) (renew #f))
  (make-demand 'tell name 'entity #f
               `((to . ,to) (discloses . ,discloses) (direction . ,direction)
                 (retain . ,retain) (renew . ,renew))))
(define* (forbid #:key (reason "prohibited") (direction #f))
  (make-demand 'forbid reason #f #f `((reason . ,reason) (direction . ,direction))))

;;; ─── the demand → VF boundary : the action its FULFILLMENT event carries ─────
;;; A <demand> is a legal requirement (a rule output), not itself a ValueFlows
;;; flow. When it becomes actionable it is LOWERED into VF — a <commitment> to the
;;; authority, or a recipe producing the artifact — and that VF event carries a
;;; real action. This is the single source of truth for that correspondence, so
;;; the lowering sites (compliance.scm obligation-for, …) do not each hardcode it.
;;;
;;;   obtain → produce         the compliance work produces the held credential
;;;   pay    → transfer        money's rights move to the authority
;;;   tell   → deliver-service a disclosure is delivered to the authority
;;;   forbid → #f              a prohibition is NOT an economic event — it prunes
;;;                            the process column (a possibility-tension), so it
;;;                            has no fulfillment action at all.
;;;
;;; (Renewal of an obtained credential lowers to `modify`, not `produce` — that is
;;; a lifecycle action on the held resource, distinct from FRESH fulfillment, and
;;; lives at the obligation site.)
(define (demand-kind->vf-action kind)
  (case kind
    ((obtain) 'produce)
    ((pay)    'transfer)
    ((tell)   'deliver-service)
    ((forbid) #f)
    (else     #f)))

(define (demand=? a b)
  (and (eq? (demand-kind a) (demand-kind b))
       (equal? (demand-name a) (demand-name b))))

;;; ─── universal severity : the generic cost of ANY legal exterior ─────────
;;; A demand's weight is intrinsic to its KIND — and, for an `obtain`, whether
;;; it rides a PERSON (a competence, a human to train) and its CADENCE (a
;;; per-event facility permit vs a one-time registration). `forbid` dominates:
;;; a possibility-tension no desire buys across. This is activity-agnostic — it
;;; weighs Alameda's food permit and Brussels' data-DPO on one scale, so any
;;; activity, anywhere, projects to one comparable number.
(define (demand-weight d)
  (case (demand-kind d)
    ((forbid) +inf.0)
    ((tell)   0.5)                                    ; a disclosure — lightest
    ((pay)    1.0)                                    ; a levy
    ((obtain)
     (if (eq? (demand-rides d) 'person) 2.0          ; competence — train a human
         (case (demand-ref d 'per)
           ((each-event each-site each-kitchen) 3.0) ; a recurring facility permit
           (else 1.5))))                             ; a one-time registration / entity
    (else 1.0)))
(define (demands-weight ds)
  (if (any (lambda (d) (eq? (demand-kind d) 'forbid)) ds)
      +inf.0
      (apply + (map demand-weight ds))))
;;; weight a fold-output bill (the alist `legal-demands` returns).
(define (bill-weight bill) (demands-weight (append-map cdr bill)))

;;; The tiers of that scale, lightest first: (upper-bound name), the last one
;;; open. Each is named by what the weights above add up to, so the names hold
;;; for any activity. A reader that paints the scale (the law face) reads these;
;;; a forbidden bill stands outside them.
(define *burden-tiers*
  '((0.75 "nothing asked, or a notice")       ; ≤ one disclosure
    (2    "one standing registration")        ; ≤ one entity permit or one competence
    (3.5  "one permit per event or site")     ; ≤ one recurring permit and a notice
    (5.5  "two demands stacked")              ; ≤ a recurring permit and a competence
    (#f   "several demands stacked")))

;;; ─── LegalContext : everything a guard may see about the activity ────────
;;; `agents` and `assets` are alists of VF RECORD FIELDS under the schema's own
;;; names (legal/gate.scm `legal-asset-fields` / `legal-agent-fields`): the
;;; things the activity touches at the cell, with `contained-in` climbed to a
;;; chain, and their holders (custodian-scope / primary-accountable). Personal
;;; and extraterritorial law reads them; spatial law reads the path.
;;; `place-path` is the PRIMARY cell's jurisdiction-path. `endpoints` is every
;;; cell the activity touches: one for a located activity, two for a transport
;;; ARC, two for a facility that straddles a line (§2.6 "The border is a
;;; crossing"). A guard sees the UNION of the endpoints, so an arc satisfies
;;; BOTH jurisdictions' rules at once — doubly-wrapped by exactly the mechanism
;;; that wraps a single-jurisdiction activity once. The constructor trips a
;;; `border` crossing whenever the endpoints diverge; production, transport and
;;; the border are then the same kind of object, folded the same way.
(define <legal-context>
  (vf-record-type 'LegalContext
    '((immutable crossings) (immutable place-path)
      (immutable agents) (immutable assets) (immutable act) (immutable endpoints)
      ;; CHANNEL — how the good reaches a person (legal/crossings.scm `recipe-channel`).
      ;; A crossing says what the act is; the channel says how it lands. Rules for
      ;; a public fridge turn on the PAIR: the same home-cooked pot may pass hand
      ;; to hand and may not be left in a Fairteiler. #f = unspecified, and a
      ;; channel guard then does not fire.
      (immutable channel))))
(define %make-legal-context (vf-record-constructor <legal-context>))

;;; deepest common ancestor of two jurisdiction-paths (paths run self→root):
;;; the longest shared tail — the level at which an arc crosses. #f if none.
(define (common-ancestor pa pb)
  (let loop ((a (reverse pa)) (b (reverse pb)) (anc #f))
    (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
        (loop (cdr a) (cdr b) (car a))
        anc)))
;;; an arc's endpoints diverge ⟺ their cells sit in DIFFERENT branches — the
;;; common ancestor is a PROPER ancestor of both. (A county and its own state
;;; are in a containment line, not across a border, so they do not diverge.)
(define (paths-cross? a b)
  (and (pair? a) (pair? b)
       (let ((ca (common-ancestor a b)))
         (and ca (not (equal? ca (car a))) (not (equal? ca (car b)))))))
(define (endpoints-diverge? eps)
  (and (> (length eps) 1)
       (any (lambda (p) (paths-cross? (car eps) p)) (cdr eps))))

;;; AGENTS and ASSETS are a list when someone looked — '() says "none here" —
;;; and #f when nobody did. ACT and CHANNEL are #f when unstated.
(define* (legal-context #:key (crossings '()) (place-path '())
                        (agents #f) (assets #f) (act #f) (endpoints #f)
                        (channel #f))
  (let* ((eps (or endpoints (list place-path)))
         ;; the border IS a crossing: an arc across diverging cells trips it.
         (xs  (if (endpoints-diverge? eps) (lset-adjoin eq? crossings 'border) crossings))
         (pp  (if (null? place-path) (if (pair? eps) (car eps) '()) place-path)))
    (%make-legal-context xs pp agents assets act eps channel)))
(define ctx-crossings  (vf-record-accessor <legal-context> 'crossings))
(define ctx-place-path (vf-record-accessor <legal-context> 'place-path))
(define ctx-agents     (vf-record-accessor <legal-context> 'agents))
(define ctx-assets     (vf-record-accessor <legal-context> 'assets))
(define ctx-act        (vf-record-accessor <legal-context> 'act))
(define ctx-endpoints  (vf-record-accessor <legal-context> 'endpoints))
(define ctx-channel    (vf-record-accessor <legal-context> 'channel))
;;; the level at which an arc crosses (its common ancestor), or #f for a point.
(define (ctx-border-level ctx)
  (let ((eps (ctx-endpoints ctx)))
    (and (endpoints-diverge? eps) (common-ancestor (car eps) (cadr eps)))))

;;; ─── guard combinators : now DATA FORMS, not closures ────────────────────
;;; A guard is a plain S-expression — so a rule SERIALIZES to disk (the registry
;;; persists like tension-registry's symbol tags). `compile-guard` interprets a
;;; form into the (ctx → bool) predicate; `rule` compiles once and caches it, so
;;; the fold stays closure-fast. The combinators just BUILD the data.
(define always '(always))
(define (on-crossing c)     (list 'on-crossing c))
;;; `in-jurisdiction` names ONE place. `place-has` asks a QUESTION of every place
;;; in every endpoint chain instead — "is any of them classified this way?" — so
;;; a rule can speak about a KIND of place without naming the places.
;;;
;;; It is what a national rule needs. SAFER holds a pre-emption over agricultural
;;; land everywhere in France, but the zones that ARE agricultural are named per
;;; commune (fr-33330-A, fr-33330-A1, …), so before this the adapter had to emit
;;; the rule once per zone it found — thirty-six thousand communes' worth of the
;;; same sentence. With it the nation says it once and the adapter only has to
;;; CLASSIFY: mark a zone agricultural, and every rule about agricultural land
;;; reaches it.
;;;
;;; The classification is read from the shared place tree (knowledge/places.scm),
;;; the same source the gate's climb already falls through to when a scope's own
;;; tree runs out — so a guard and a chain cannot disagree about what a place is.
(define (in-jurisdiction j) (list 'in-jurisdiction j))
(define (place-has key val)  (list 'place-has key val))
(define (at-origin j)       (list 'at-origin j))         ; the arc's origin side (export)
(define (at-destination j)  (list 'at-destination j))    ; the arc's destination side (import)
(define (border-level-is l) (list 'border-level-is l))   ; crosses at exactly this level
(define (act-is a)          (list 'act-is a))            ; the activity is (or is unspecified)
(define (via-channel c)     (list 'via-channel c))       ; the good reaches a person THIS way
(define (agent-has key val) (list 'agent-has key val))
(define (asset-has key val) (list 'asset-has key val))
(define (for-citizens-of c) (list 'agent-has 'citizenship c))
(define (all-of . gs)       (cons 'all-of gs))
(define (any-of . gs)       (cons 'any-of gs))
(define (negate g)          (list 'negate g))

;;; an agent/asset alist holds VF RECORD FIELDS under their schema names
;;; (schemas.scm <economic-resource> / <agent>): `conforms-to`, `classified-as`,
;;; `contained-in`, `current-location`, `custodian-scope`, `primary-accountable`,
;;; `state`, `stage`, `type`, `primary-location`. A list-valued field
;;; (`classified-as`; `contained-in` as the climbed chain, the resource twin of
;;; `place-path`) matches by membership, a scalar by equality — so one guard
;;; reads a tag, a container anywhere up the chain, or a holder the same way.
(define (field-has? field v)
  (if (list? field) (and (member v field) #t) (equal? v field)))

;;; compile a guard FORM → a predicate (ctx → bool). in-jurisdiction tests ANY
;;; endpoint (§2.6 doubly-wrapped); member (equal?) not memq, ids may be strings.
;;; ─── a guard answers yes, no, or UNKNOWN ─────────────────────────────────
;;; A guard reads facts of the context. Most are always there: the crossings,
;;; the place. Four may be missing: the ACT and the CHANNEL, when nobody states
;;; them, and the THINGS at the cell and their HOLDERS, when nobody looked (a
;;; fold with no observer). Of a fact nobody stated or looked up there is
;;; nothing to answer yes or no to. So a guard has three answers: #t, #f, and
;;; `unknown`, and the combinators carry the third through as far as it matters
;;; (Kleene's): a conjunction with a no in it is no whatever is unknown, a
;;; disjunction with a yes in it is yes, and the negation of unknown is unknown.
;;;
;;; The fold reads the third answer as DOUBT (`legal-demands`): the rule is a hit
;;; at confidence `uncertain`, so it prices and warns and neither prunes nor
;;; cancels. A caller that knows the act states it and gets yes or no.
(define (k-not x) (if (eq? x 'unknown) 'unknown (not x)))
(define (k-every vals)                  ; #f beats unknown beats #t
  (cond ((memq #f vals) #f) ((memq 'unknown vals) 'unknown) (else #t)))
(define (k-any vals)                    ; #t beats unknown beats #f
  (cond ((memq #t vals) #t) ((memq 'unknown vals) 'unknown) (else #f)))
(define (stated-is fact value)          ; an unstated fact is unknown
  (if fact (eq? fact value) 'unknown))
(define (looked-has things k v)         ; things nobody looked at are unknown
  (if things
      (and (any (lambda (t) (field-has? (assq-ref t k) v)) things) #t)
      'unknown))

(define (compile-guard form)
  (let ((tag (and (pair? form) (car form))) (a (and (pair? form) (cdr form))))
    (case tag
      ((always)         (lambda (ctx) #t))
      ((on-crossing)    (let ((c (car a))) (lambda (ctx) (and (memq c (ctx-crossings ctx)) #t))))
      ((in-jurisdiction)(let ((j (car a))) (lambda (ctx) (and (any (lambda (p) (member j p)) (ctx-endpoints ctx)) #t))))
      ((at-origin)      (let ((j (car a))) (lambda (ctx) (let ((e (ctx-endpoints ctx))) (and (pair? e) (member j (car e)) #t)))))
      ((at-destination) (let ((j (car a))) (lambda (ctx) (let ((e (ctx-endpoints ctx))) (and (pair? e) (member j (last e)) #t)))))
      ((border-level-is)(let ((l (car a))) (lambda (ctx) (equal? l (ctx-border-level ctx)))))
      ;; the two facts a context may leave unstated: unstated is `unknown`
      ((act-is)         (let ((s (car a))) (lambda (ctx) (stated-is (ctx-act ctx) s))))
      ((via-channel)    (let ((c (car a))) (lambda (ctx) (stated-is (ctx-channel ctx) c))))
      ((place-has)      (let ((k (car a)) (v (cadr a)))
                          (lambda (ctx)
                            (and (any (lambda (path)
                                        (any (lambda (id) (field-has? (place-extra-ref id k) v)) path))
                                      (ctx-endpoints ctx))
                                 #t))))
      ;; the things at the cell and their holders: a list when someone looked
      ;; (empty when there are none), #f when nobody did — then unknown
      ((agent-has)      (let ((k (car a)) (v (cadr a))) (lambda (ctx) (looked-has (ctx-agents ctx) k v))))
      ((asset-has)      (let ((k (car a)) (v (cadr a))) (lambda (ctx) (looked-has (ctx-assets ctx) k v))))
      ((all-of)         (let ((cs (map compile-guard a))) (lambda (ctx) (k-every (map (lambda (c) (c ctx)) cs)))))
      ((any-of)         (let ((cs (map compile-guard a))) (lambda (ctx) (k-any   (map (lambda (c) (c ctx)) cs)))))
      ((negate)         (let ((c (compile-guard (car a)))) (lambda (ctx) (k-not (c ctx)))))
      (else (error "unknown guard form" form)))))

;;; What a guard STATES, read off its form: every (TAG x) in it. By default the
;;; walk stays outside a `negate` — a negated clause says where the rule stops,
;;; so what sits under it is no part of what the rule keys on. NEGATED? #t reads
;;; those too, for a reader that asks what the form NAMES (the pack lint: a
;;; negated jurisdiction nobody places is a misspelling all the same).
(define* (guard-atoms tag form #:key (negated? #f))
  (cond ((not (pair? form)) '())
        ((eq? (car form) tag) (list (cadr form)))
        ((or (memq (car form) '(all-of any-of))
             (and negated? (eq? (car form) 'negate)))
         (append-map (lambda (f) (guard-atoms tag f #:negated? negated?)) (cdr form)))
        (else '())))
;;; What a guard form keys on, read off it by `guard-atoms`. A negated clause
;;; says where the rule stops, so by default what stands under a `negate` stays
;;; out; NEGATED? #t reads those too (a lint wants every name the form spells).
(define* (guard-places form #:key (negated? #f))          ; the jurisdictions
  (append-map (lambda (tag) (guard-atoms tag form #:negated? negated?))
              '(in-jurisdiction at-origin at-destination)))
(define* (guard-crossings form #:key (negated? #f))       ; the crossings
  (guard-atoms 'on-crossing form #:negated? negated?))
;;; Which of the facts a context may lack a form reads, at any depth:
;;; `act`, `channel`, `assets`, `agents`.
(define %askable '((act . act-is) (channel . via-channel) (assets . asset-has) (agents . agent-has)))
(define (guard-asks form)
  (filter-map (lambda (row) (and (pair? (guard-atoms (cdr row) form #:negated? #t)) (car row)))
              %askable))

;;; ─── LegalRule : guard FORM (data) + compiled predicate, with provenance ──
(define <legal-rule>
  (vf-record-type 'LegalRule
    '((immutable guard) (immutable guard-form) (immutable demands) (immutable label)
      (immutable source) (immutable as-of) (immutable confidence) (immutable steward)
      (immutable until)     ; in force UNTIL (exclusive); #f = no end
      (immutable cancels))))  ; demand NAMES this rule derogates from; '() = none
(define %make-legal-rule (vf-record-constructor <legal-rule>))
;;; AS-OF is the date the rule came into force, UNTIL the date it ceases to be
;;; (exclusive). Both are optional and both are provenance a pack already
;;; carries; what changed is that `legal-demands` now READS them when it is told
;;; what day it is. A repeal remains a governance act that removes the rule; a
;;; window is for the law that says its own end date — a transitional provision,
;;; a sunset clause, a derogation for one season.
;;; CANCELS names the demands this rule derogates from — a DEROGATION, the one
;;; kind of precedence the fold cannot express as a guard.
;;;
;;; Most apparent precedence is not precedence at all but missing CONTEXT: a
;;; threshold ("under 5 m² needs no permis") is two rules with complementary
;;; guards over a fact the context already carries, and a zone that permits its
;;; own use is `negate (act-is …)`. Those need nothing new. And a hierarchy of
;;; norms — a PLU that must conform to its SCoT — is a question of VALIDITY that
;;; a prefect or a court settles; the fold sees the published text either way.
;;;
;;; What is irreducible is a derogation by ANOTHER AUTHORITY: a national rule
;;; exempting a class of act from every commune's permit. The commune's pack is
;;; right at its own level and cannot be edited by the nation, so the fold's
;;; union gives the wrong answer and no guard can fix it from either side.
;;;
;;; The key is the demand NAME, not the rule label: one national derogation
;;; reaches any number of communal rules, where naming labels would mean naming
;;; thousands. The name is already the join key everywhere else — `demand-name`
;;; IS `demand->spec-id`, the id a held permit conforms to (compliance.scm).
;;;
;;; Only a rule at `verified` or `reported` cancels. A derogation the pack is
;;; UNCERTAIN of must not silently erase a prohibition the law is sure of —
;;; confidence gates the strong effect here exactly as it gates a prune.
(define* (rule guard-form demands
               #:key (label #f) (source #f) (as-of #f)
                     (confidence 'reported) (steward #f) (until #f) (cancels '()))
  (%make-legal-rule (compile-guard guard-form) guard-form demands label source as-of
                    confidence steward until cancels))
(define legal-rule-guard-form  (vf-record-accessor  <legal-rule> 'guard-form))
(define legal-rule?            (vf-record-predicate <legal-rule>))
(define legal-rule-guard       (vf-record-accessor  <legal-rule> 'guard))
(define legal-rule-demands     (vf-record-accessor  <legal-rule> 'demands))
(define legal-rule-label       (vf-record-accessor  <legal-rule> 'label))
(define legal-rule-source      (vf-record-accessor  <legal-rule> 'source))
(define legal-rule-as-of       (vf-record-accessor  <legal-rule> 'as-of))
(define legal-rule-confidence  (vf-record-accessor  <legal-rule> 'confidence))
(define legal-rule-steward     (vf-record-accessor  <legal-rule> 'steward))
(define legal-rule-until       (vf-record-accessor  <legal-rule> 'until))
(define legal-rule-cancels     (vf-record-accessor  <legal-rule> 'cancels))
;;; ─── confidence : how well a steward has checked a rule ──────────────────
;;; `verified` — a steward read the source and stands behind the rule;
;;; `reported` — taken from a source as stated; `uncertain` — the pack doubts
;;; it. The first two are SURE: only a sure rule has a strong effect (it prunes,
;;; it cancels). An uncertain rule prices and warns.
(define %confidences '(verified reported uncertain))
(define (rule-sure? r)
  (and (memq (legal-rule-confidence r) '(verified reported)) #t))
(define rule-may-cancel? rule-sure?)
;;; The same rule, doubted: what the fold makes of a rule whose guard could not
;;; be answered. It keeps its label, source and demands; its confidence is
;;; `uncertain`, so it does everything an uncertain rule does and nothing more.
(define (rule-doubted r)
  (if (eq? 'uncertain (legal-rule-confidence r))
      r
      (%make-legal-rule (legal-rule-guard r) (legal-rule-guard-form r) (legal-rule-demands r)
                        (legal-rule-label r) (legal-rule-source r) (legal-rule-as-of r)
                        'uncertain (legal-rule-steward r) (legal-rule-until r)
                        (legal-rule-cancels r))))

;;; What every stated fact about a place owes — a rule, a reading, a protection:
;;; a place in the tree, a source, a confidence the layer knows. → a list of
;;; sentences, empty when the fact is sound. WHERE names the fact; NOUN is what
;;; it is ("reading"); CONFIDENCE 'none skips that check for a fact that carries
;;; none.
(define* (provenance-problems where noun #:key place source (confidence 'none)
                              (known-place? place-known?))
  (append
   (if (and (string? place) (known-place? place)) '()
       (list (string-append where ": the place is not in the tree")))
   (if (or (eq? confidence 'none) (memq confidence %confidences)) '()
       (list (string-append where ": confidence is verified, reported or uncertain")))
   (if (and (string? source) (not (string-null? source))) '()
       (list (format #f "~a: a ~a cites its source" where noun)))))

;;; a rule of the BORDER: it speaks of an arc's two ends, so it belongs to an arc
;;; and to no single place.
(define (border-rule? r)
  (let ((form (legal-rule-guard-form r)))
    (and (or (pair? (guard-atoms 'at-origin form))
             (pair? (guard-atoms 'at-destination form))
             (pair? (guard-atoms 'border-level-is form))
             (memq 'border (guard-crossings form)))
         #t)))

;;; Dates reach a pack in whatever shape its source writes them — the GPU says
;;; "20241212", a statute reference says "2022-03-10". Compare on digits only, so
;;; the two orderings agree; a shorter key (a bare year) still orders correctly
;;; against a longer one.
(define (date-key s)
  (and (string? s) (string-filter char-numeric? s)))

(define (rule-in-force? r as-of)
  "Is R in force on AS-OF? With no AS-OF, every rule stands — a timeless read of
   the catalogue, which is what the law face wants."
  (or (not as-of)
      (let ((now (date-key as-of))
            (from (date-key (legal-rule-as-of r)))
            (until (date-key (legal-rule-until r))))
        (and (or (not from) (not now) (string<=? from now))
             (or (not until) (not now) (string<? now until))))))

;;; ─── serialization : a rule ⇄ plain S-expression (disk-persistable) ──────
;;; The guard is already DATA (a form); a demand's fields are data (kind/name/
;;; rides/spec/detail). So a whole rule round-trips through `write`/`read` — the
;;; registry persists like tension-registry, only with richer data than tags.
(define (demand->sexp d)
  (list (demand-kind d) (demand-name d) (demand-rides d) (demand-spec d) (demand-detail d)))
(define (sexp->demand s)
  (apply make-demand s))
(define (rule->sexp r)
  (list (legal-rule-guard-form r) (map demand->sexp (legal-rule-demands r))
        (legal-rule-label r) (legal-rule-source r) (legal-rule-as-of r)
        (legal-rule-confidence r) (legal-rule-steward r)
        (legal-rule-until r)            ; 8th slot: packs written before it read as #f
        (legal-rule-cancels r)))        ; 9th slot: likewise, absent reads as '()
(define (sexp->rule s)
  (rule (list-ref s 0) (map sexp->demand (list-ref s 1))
        #:label (list-ref s 2) #:source (list-ref s 3) #:as-of (list-ref s 4)
        #:confidence (list-ref s 5) #:steward (list-ref s 6)
        #:until (and (> (length s) 7) (list-ref s 7))
        #:cancels (if (> (length s) 8) (or (list-ref s 8) '()) '())))
(define (rules->sexp rules) (map rule->sexp rules))
(define (sexp->rules sexps) (map sexp->rule sexps))

;;; ─── rule packs on disk : "add a jurisdiction = drop a signed file" ───────
;;; A rule-pack is a file holding `(rules->sexp …)` — one jurisdiction's laws as
;;; plain data. Because a rule is fully serializable (guard FORM + demand data +
;;; provenance), a pack round-trips through write/read. `save-rule-pack` writes
;;; one; `load-rule-pack` reads one; `load-rule-packs` merges a directory (loads
;;; its *.sexp in name order) OR an explicit path list into one rule set — the
;;; fold's library, assembled from disk.
;;; Steward/confidence ride each rule, so a scraped pack loads at 'reported and a
;;; steward-checked one at 'verified, unchanged — the curation pipeline is just files.
(define (save-rule-pack path rules)
  (call-with-output-file path
    (lambda (port) (write (rules->sexp rules) port) (newline port))))
;;; A pack file is either a bare rule list (what `save-rule-pack` writes) or a
;;; CONTEXT PACK — `((places …) (rules …))`, knowledge/context-pack.scm — which
;;; ships the places its rules are guarded on beside them, so a pack can never
;;; name a jurisdiction it forgot to place. Both are read here; a caller that
;;; also wants the places reads them with `pack-place-rows`.
;;; `read-pack` is the ONE reader of a pack file: every loader and the lint go
;;; through it, so they agree on what a pack is. A pack is an alist of sections
;;; — places, rules, readings, aspects — and a bare rule list reads as a pack
;;; with the one section. The sections: places, rules, readings, aspects,
;;; protections.
(define (read-pack path)
  (let ((datum (call-with-input-file path
                 (lambda (port) (set-port-encoding! port "UTF-8") (read port)))))
    (if (and (pair? datum) (pair? (car datum)) (symbol? (caar datum)))
        datum
        `((rules . ,datum)))))
(define (pack-section pack key) (or (assq-ref pack key) '()))
(define (load-rule-pack path)
  (sexp->rules (pack-section (read-pack path) 'rules)))
;;; SOURCE → the pack files it names: a directory's *.sexp in name order, or an
;;; explicit path list as given. A directory that is not there holds no packs.
(define (pack-paths source)
  (cond ((not (string? source)) source)
        ((not (file-exists? source)) '())
        (else (map (lambda (f) (in-vicinity source f))
                   (sort (filter (lambda (f) (string-suffix? ".sexp" f))
                                 (or (scandir source) '()))
                         string<?)))))
(define (load-rule-packs source)
  (append-map load-rule-pack (pack-paths source)))

;;; ─── jurisdiction path : walk SpatialThing.contained-in upward ───────────
(define (jurisdiction-path place-id parent-of)
  (let loop ((id place-id) (acc '()))
    (if (not id) (reverse acc) (loop (parent-of id) (cons id acc)))))
;;; ─── the OTHER regimes a place stands in : `within` ──────────────────────
;;; A place is contained in one thing and STANDS IN several regimes that do not
;;; nest — a water basin, an appellation, a reserve. It declares them as
;;; `(within . (id …))` among its extras, at any level of its chain, and each
;;; becomes another endpoint climbed by the same walk (legal/gate.scm tells the
;;; whole story). PATH-OF is the climb: place → its containment path, self first.
;;; → the list of endpoint paths, the place's own chain first.
(define %max-regimes 32)
(define (regime-endpoints place path-of)
  (let loop ((queue (list place)) (seen '()) (paths '()))
    (if (or (null? queue) (> (length paths) %max-regimes))
        (reverse paths)
        (let ((p (car queue)))
          (if (member p seen)
              (loop (cdr queue) seen paths)
              (let* ((path (path-of p))
                     (more (append-map (lambda (id) (or (place-extra-ref id 'within) '()))
                                       path)))
                (loop (append (cdr queue) more) (cons p seen) (cons path paths))))))))

;;; The two walks over the shared tree every reader of a place shares:
;;; its containment chain, self first; and every path it stands in — the chain,
;;; then its `within` regimes'.
(define (place-chain place-id) (jurisdiction-path place-id place-parent-of))
(define (place-endpoints place-id) (regime-endpoints place-id place-chain))

;;; ─── the bill : demands grouped by what they ask ─────────────────────────
;;; A bill is an alist over these keys, each a list of demands:
;;;   obtain-entity  authorise — a facility's permit
;;;   obtain-person  authorise — a person's competence
;;;   pay            levy
;;;   tell           disclosure
;;;   forbid         prohibition
(define %bill-keys '(obtain-entity obtain-person pay tell forbid))
(define (demand-bill-key d)
  (case (demand-kind d)
    ((obtain) (case (demand-rides d)
                ((entity) 'obtain-entity) ((person) 'obtain-person) (else #f)))
    (else (demand-kind d))))
(define (bill-ref bill key) (or (assq-ref bill key) '()))

;;; legal-demands : the whole legal exterior of an activity in one fold.
;;; → (values bill hits), bill an alist grouped by the demand vocabulary.
;;; RULES are named by the caller: a scope folds its own registry's, a face folds
;;; the packs on disk (`current-legal-rules`, knowledge/context-pack.scm). The
;;; fold holds no rule set of its own, so a bill always says whose law it read.
(define* (legal-demands ctx #:key (rules (error "legal-demands: #:rules names the law to fold"))
                        (as-of #f))
  (let* ((hits (filter-map
                (lambda (r)
                  (and (rule-in-force? r as-of)
                       (case ((legal-rule-guard r) ctx)
                         ((#t)      r)
                         ;; the context left a fact this guard reads unstated:
                         ;; the rule may apply, so it is a hit, in doubt
                         ((unknown) (rule-doubted r))
                         (else      #f))))
                rules))
         ;; a derogation removes the demands it names from the bill — order
         ;; independent, since every matching rule's cancels are collected before
         ;; any is applied. A rule may cancel AND demand: an exemption that
         ;; replaces a permit with a lighter formality is one rule, not two.
         (cancelled (append-map legal-rule-cancels (filter rule-may-cancel? hits)))
         (ds   (remove (lambda (d) (member (demand-name d) cancelled))
                       (delete-duplicates (append-map legal-rule-demands hits) demand=?))))
    (values (map (lambda (k) (cons k (filter (lambda (d) (eq? k (demand-bill-key d))) ds)))
                 %bill-keys)
            hits)))

;;; Why a hit is in doubt for want of a stated fact: for each of HITS, the facts
;;; its guard reads that CTX leaves unstated → ((label fact …) …), hits whose
;;; guard reads none of them left out.
(define (hit-unknowns hits ctx)
  (filter-map
   (lambda (r)
     (let ((missing (filter (lambda (fact)
                              (not (case fact
                                     ((act) (ctx-act ctx)) ((channel) (ctx-channel ctx))
                                     ((assets) (ctx-assets ctx)) ((agents) (ctx-agents ctx)))))
                            (guard-asks (legal-rule-guard-form r)))))
       (and (pair? missing) (cons (legal-rule-label r) missing))))
   hits))

;;; ─── the stance : one reading of a bill ──────────────────────────────────
;;; What a bill means for doing the thing, read off the bill AS FOLDED — after
;;; derogations have removed what they cancel — and the confidence of the rules
;;; behind it. Every reader that decides (the solve's prune, the registry's
;;; `forbids?`, the law face, a product feature) reads this, so they give one
;;; answer to one law.
;;;
;;; bill-forbid → 'hard   a prohibition stands and a sure rule imposes it
;;;               'soft   prohibitions stand, every one from an uncertain rule
;;;               #f      no prohibition stands
;;; A prohibition is SURE when a sure rule among HITS imposes it.
(define (forbid-sure? d hits)
  (any (lambda (r) (and (rule-sure? r) (member d (legal-rule-demands r) demand=?) #t)) hits))
(define (bill-forbid bill hits)
  (let ((standing (bill-ref bill 'forbid)))
    (cond ((null? standing) #f)
          ((any (lambda (d) (forbid-sure? d hits)) standing) 'hard)
          (else 'soft))))

;;; What a rule speaks of: the crossings its guard names (a crossing under a
;;; `negate` is where the rule stops, so it is left out), and every crossing —
;;; '() — when the guard names none.
(define (rule-speaks-of r) (guard-crossings (legal-rule-guard-form r)))

;;; bill-unread → the CROSSINGS no rule that fired speaks of. A rule speaks of
;;; the crossings its guard names, and of every crossing when it names none. A
;;; steward who reads a crossing at a place and finds the law asks nothing
;;; writes that down as a rule with no demands; the crossing is then read, and
;;; its bill is empty. A crossing nobody has written a rule for is unread:
;;; nothing is known of it there.
(define (bill-unread hits crossings)
  (let ((spoken (map rule-speaks-of hits)))
    (if (any null? spoken)
        '()
        (filter (lambda (c) (not (any (lambda (xs) (memq c xs)) spoken))) crossings))))

;;; HELD? : demand-name → #t (held), #f (not held), or `unknown` — the answer
;;; when nobody has looked at what the scope holds. Only a permit known to be
;;; missing closes anything; one whose custody is unknown is priced and named.
(define (custody-unknown name) 'unknown)

;;; the stances, from nothing asked to nothing allowed
(define %stances '(open notice unread soft off))

;;; bill-stance → 'off     a hard prohibition, or an entity permit a sure rule
;;;                        demands that is not held (HELD? : demand-name → bool)
;;;               'soft    only uncertain prohibitions stand
;;;               'unread  nothing forbids, and a crossing in CROSSINGS is unread
;;;               'notice  something is asked: obtain, pay or tell
;;;               'open    the law asks nothing
;;; CROSSINGS is what the activity trips. A reader that states them learns where
;;; the law is silent because nobody has read it; one that leaves them out (the
;;; solve, which plans over what is known) reads the bill alone.
(define* (bill-stance bill hits #:optional (held? custody-unknown)
                      #:key (crossings '()))
  (let* ((sure-names (map demand-name (append-map legal-rule-demands (filter rule-sure? hits))))
         (unheld? (any (lambda (d) (and (member (demand-name d) sure-names)
                                        (eq? #f (held? (demand-name d)))))
                       (bill-ref bill 'obtain-entity)))
         (forbid (bill-forbid bill hits)))
    (cond ((or (eq? forbid 'hard) unheld?) 'off)
          ((eq? forbid 'soft) 'soft)
          ((pair? (bill-unread hits crossings)) 'unread)
          ((any (lambda (k) (pair? (bill-ref bill k))) '(obtain-entity obtain-person pay tell)) 'notice)
          (else 'open))))

;;; what "forbidden" means, wherever it is said: a prohibition stands.
(define (stance-forbids? stance) (and (memq stance '(off soft)) #t))

;;; ─── boundary: the governance actor (mirror of tension-registry.scm) ──────
;;; (use-modules (goblins) (goblins actor-lib methods))
;;; (define (^legal-registry bcom rules)
;;;   (methods
;;;     [(rules) rules]
;;;     [(register! r)  (bcom (^legal-registry bcom (cons r rules)) 'ok)]
;;;     [(repeal label) (bcom (^legal-registry bcom
;;;                             (filter (lambda (r) (not (equal? label (legal-rule-label r))))
;;;                                     rules)) 'ok)]
;;;     [(demands ctx)  (call-with-values
;;;                      (lambda () (legal-demands ctx #:rules rules)) list)]
;;;     [(portrait) rules]))
;;; (define (restore-legal-registry rules) (spawn ^legal-registry rules))
