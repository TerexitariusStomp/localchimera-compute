;;; service.scm — gateway-facing governance facade
;;;
;;; ^governance-service holds the per-AID voice actors and exposes
;;; ballot/expression/delegation/cast methods. KERI auth at lobby time
;;; proves the caller controls the AID; the service then acts through
;;; the matching ^voice-signer on their behalf.
;;;
;;; Voice rides on labor, not membership. Anyone authenticated may
;;; cast — their weight is whatever their labor produced (zero if
;;; none). Open/close are admin actions and gate on `governor?`. The
;;; only credential gate is `governor?` for ballot/expression
;;; lifecycle; voice itself has no membership gate by design.
;;;
;;; Citizen-id throughout = the AID string. One sealer per AID, spawned
;;; lazily on first access. The seal lives server-side.
;;;
;;; State held by the service:
;;;   - scope-roots:      list of ^scope-root refs (the federation universe)
;;;   - ballot-store:     ^ballot-store from the primary scope
;;;   - voices:           hashmap aid → ^voice
;;;   - sealed?-of:       hashmap aid → sealed?-actor (published verifier)
;;;   - delegations:      hashmap aid → ^delegation-map
;;;
;;; A module of (playnet governance); the umbrella re-exports it.


(define-module (playnet governance service)
  #:use-module ((playnet wire replies) #:select (finishing))
  #:use-module (srfi srfi-1)
  #:use-module (playnet governance socialization)
  #:use-module ((playnet governance debts) #:select (purchase-claim))
  #:use-module (playnet openvtc first-person)
  #:use-module ((playnet social relationship-kinds) #:select (normalize-rel))
  #:use-module (playnet governance credentials)
  #:use-module ((playnet planner facts parts) #:select (validate-hand))
  #:use-module ((playnet planner observation observer) #:select (void-event))
  #:use-module ((playnet planner observation evidence) #:select (tags-evidence))
  #:use-module ((playnet planner observation adjustment) #:select (count-event? count-event-of))
  #:use-module ((playnet planner formulas counting) #:select (count-base-id count-family-id? contest-ballot-id))
  #:use-module ((playnet keri acdc-store) #:select (non-revoked-by-schema))
  #:use-module (playnet governance snapshot)
  #:use-module (playnet keri said-portable)
  #:use-module (playnet planner pools credit-fold)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->civil (now . clock-now)))
  #:use-module (playnet governance delegation-map)
  #:use-module (playnet governance keri scope-exchange)
  #:use-module ((playnet keri signify-portable) #:select (scm->json-canonical json-read-ordered))
  #:use-module (goblins utils hashmap)
  #:use-module (json)
  #:use-module (playnet governance ballot)
  #:use-module (playnet governance expression)
  #:use-module (playnet governance recovery)
  #:use-module (playnet governance voice-signer)
  #:use-module ((playnet identity enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (playnet openvtc personhood-policy)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (fp-wire->cred ^governance-service spawn-governance-service
            governance-service-env plan-part-hands-of contrary-observations-of contrary-readings-of))

;; ── The plan-part rail, read off a store ─────────────────────────────────────
;; The live plan-part hands on SCOPE-ID's rail: every non-revoked
;; expression-stance credential with domain plan-part and this scope's
;; expression-id; WHO narrows to one citizen's (#f = everyone's). Module-level
;; because two readers stand on it — the service's doors and the planner's
;; boot-time seed (server/gateway.scm injects `plan-part-hands-of` over the
;; same store, the pool-of idiom), so a restart reads the rail as it stands.
(define (standing-part-hands store scope-id who)
  (if store
      (filter (lambda (c)
                (and (equal? (format #f "~a" (cred-claim c 'domain)) "plan-part")
                     (equal? (cred-claim c 'expression-id) (string-append "plan-part:" scope-id))
                     (or (not who) (equal? (cred-issuer c) who))))
              (non-revoked-by-schema store *schema-playnet-expression-stance*))
      '()))

(define (plan-part-hands-of store scope-id)
  "The standing hands on SCOPE-ID's rail as rows ((owner part-string portion) …):
   what the planner's voice fold takes (planner service `hands!`)."
  (append-map (lambda (c)
                (let ((who (cred-issuer c)))
                  (map (lambda (kv) (list who (car kv) (cdr kv)))
                       (or (cred-claim c 'distribution) '()))))
              (standing-part-hands store scope-id #f)))

;; ── Contrary observations, read off a store ──────────────────────────────────
;; The live contrary observations on SCOPE-ID's map: every non-revoked
;; contrary-observation credential naming this scope. Module-level for the
;; same reason as the hands: the service's doors and the gateway's standing
;; read (`scope-standing #:observed`, over the same store) both stand on it.
(define (standing-contrary-observations store scope-id who)
  (if store
      (filter (lambda (c)
                (and (equal? (cred-claim c 'scope-id) scope-id)
                     (or (not who) (equal? (cred-issuer c) who))))
              (non-revoked-by-schema store *schema-playnet-contrary-observation*))
      '()))

(define (contrary-readings-of store scope-id)
  "The standing contrary observations on SCOPE-ID's map as readings, one per
   witness: ((spec process action nominal reading observed-at said) …),
   anonymous — the reading is what was seen, whoever saw it. What the
   planner's reading fold takes (pools/reading-fold.scm) beside the
   readings its observer records."
  (map (lambda (c)
         (list (cred-claim c 'spec)
               (cred-claim c 'process)
               (string->symbol (format #f "~a" (cred-claim c 'action)))
               (cred-claim c 'nominal) (cred-claim c 'reading)
               (cred-claim c 'observed-at) (cred-said c)))
       (standing-contrary-observations store scope-id #f)))

(define (contrary-observations-of store scope-id)
  "The same readings as the solve takes them (planner/solve/engine/robust.scm
   observed-shocks): ((process action nominal reading) …)."
  (map (lambda (r) (list (cadr r) (caddr r) (cadddr r) (list-ref r 4)))
       (contrary-readings-of store scope-id)))

(define (fp-wire->cred w)
  "Reconstruct a symbol-keyed credential alist from governance-cred->wire's
   SAD-shaped projection (d/i/s/a/e) plus a trailing (\"sig\" . qb64). The
   inverse used by `present-phc` to verify + import a carried PHC."
  (define (wref k) (let ((p (assoc k w))) (and p (cdr p))))
  (define (s->sym k) (if (string? k) (string->symbol k) k))
  ;; Claims a constructor writes as SYMBOLS (make-relationship-credential's
  ;; relationship-type) come back from JSON as strings, and the SAID tells
  ;; the two apart (canonical-string quotes a string, not a symbol) — so
  ;; the inverse restores them, the way it restores the edge operator.
  (define symbol-claims
    (let ((schema (wref "s")))
      (cond ((equal? schema *schema-playnet-relationship*) '(relationship-type))
            (else '()))))
  (define (claim-value k v)
    (if (and (memq k symbol-claims) (string? v)) (string->symbol v) v))
  (let* ((a      (or (wref "a") '()))
         (claims (let loop ((ps a) (acc '()))
                   (cond ((null? ps) (reverse acc))
                         ((equal? (caar ps) "i") (loop (cdr ps) acc))
                         (else (loop (cdr ps)
                                     (let ((k (s->sym (caar ps))))
                                       (cons (cons k (claim-value k (cdar ps))) acc)))))))
         (edges  (let ((e (wref "e")))
                   (if (pair? e)
                       ;; Normalize each edge: the outer name AND the inner
                       ;; spec keys back to symbols, and the operator VALUE
                       ;; (`o`) from its JSON string back to a symbol — else
                       ;; the edge re-derives to a different SAID (compute-said
                       ;; hashes symbol keys/operators) and a PHC carrying an
                       ;; `issuer-authz` edge fails the digest-consistency gate.
                       (map (lambda (edge)
                              (cons (s->sym (car edge))
                                    (map (lambda (kv)
                                           (let ((k (s->sym (car kv))) (v (cdr kv)))
                                             (cons k (if (and (eq? k 'o) (string? v))
                                                         (string->symbol v) v))))
                                         (cdr edge))))
                            e)
                       '()))))
    (list (cons 'said      (wref "d"))
          (cons 'schema    (wref "s"))
          (cons 'issuer    (wref "i"))
          (cons 'holder    (let ((p (assoc "i" a))) (and p (cdr p))))
          (cons 'claims    claims)
          (cons 'edges     edges)
          (cons 'signature (wref "sig"))
          (cons 'revoked?  #f))))

;; A goblins hashmap folded to a key-sorted alist — the ONLY form a
;; distribution/tally may take on its way into SAID material (claims).
;; canonical-string (said-portable.scm) refuses the raw hashmap loudly:
;; its printer is host-dependent and truncates past 10 pairs, so hashing
;; it let two distinct distributions collide into one SAID and wrote an
;; unreplayable form to the durable store.
(define (distribution->alist d)
  "A distribution as SAID material, key-sorted with inexact values. D is a live
   goblins hashmap (an expression's cast) or an alist (a plan-part hand): one
   fold for both, for the same reason."
  (said-sort-pairs
   (map (lambda (kv) (cons (car kv) (exact->inexact (cdr kv))))
        (if (hashmap? d) (hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() d) d))))

(define (%sponsor-fanout-ok? acdc-store scope-id sponsor-aid)
  "Sybil-resistance layer 1B: even a governor can't sponsor more than the
   fan-out cap of PHCs per window (counts PHCs sponsored by this AID) —
   the shared gate under fp-grant and fp-open-ceremony."
  (catch #t
    (lambda ()
      (assert-sponsor-fanout! acdc-store scope-id sponsor-aid
                              *default-sponsor-fanout-cap*
                              *default-sponsor-fanout-window*
                              (current-time))
      #t)
    (lambda _ #f)))

(define (%as-symbol x) (if (string? x) (string->symbol x) x))

(define* (^governance-service bcom scope-roots ballot-store
                              governor? ;; (lambda (aid) bool) — e.g. founders-list membership
                              acdc-store ;; ^acdc-store or ^keria-acdc-store ref, or #f
                              #:optional [home-scope #f]  ;; ^scope ref for KEL anchoring (§4.6)
                                        [scope-of #f]     ;; commune-aid → ^scope, for a commune's OWN acts
                                        [kel-landing #f]  ;; (aid icp sigs rotations) → #t | error string: land a carried KEL
                                        [kel-of #f])      ;; aid → the KEL this gateway holds for it, wire-shaped, or #f
  ;; a scope's self-declaration, minted for it by a governor (MAKE : → cred)
  (define (%scope-declare! identity-key make)
    (cond
      ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
      ((not (governor? identity-key)) (list 'error "a scope's declaration is spoken by a governor"))
      (else (catch #t
              (lambda ()
                (let ((cred (make)))
                  ($ acdc-store 'issue-idempotent cred)
                  (list 'ok (cred-said cred))))
              (lambda (k . args) (list 'error (format #f "~a ~s" k args)))))))
  ;; Mutable per-AID registries (cell-style; rebuilt by re-spawning is
  ;; possible but per-call mutation is simpler for a long-lived service).
  (let ((voices         (hashmap))
        (sealed?-of     (hashmap))
        (delegations    (hashmap))
        ;; scope-id → the commune's planner root, for per-scope voice (voice-in)
        (scope-root-of  #f)
        ;; ballot-id → (): told when a contest ballot has settled, so what the
        ;; gateway holds for it (a counter's picture) can be let go
        (contest-settled #f)
        ;; Per-proposal snapshot SAIDs, recorded at 'open and retrieved
        ;; at 'cast / 'close so stance and tally-result ACDCs can carry
        ;; the §4.9 ballot-snapshot edge.
        (snapshot-saids (hashmap))
        ;; First-Person: commune AIDs whose PHCs we honour when PRESENTED by a
        ;; holder from another gateway (set by the gateway to the UC's members).
        (fp-trusted-issuers '())
        ;; First-Person: the trust-registry root AID (the Universal Commune's
        ;; group AID). When set, an ecosystem is a legitimate PHC issuer iff it
        ;; chains to root (holds a live authorized-issuer credential), making
        ;; `fp-trusted-issuers` a fallback rather than the sole source of trust.
        (fp-root-aid #f)
        ;; First-Person: when #t, the flat `fp-trusted-issuers` whitelist is
        ;; DROPPED — trust derives only from chaining to root. Flip this once
        ;; the live root chain is populated (ecosystems blessed), so the
        ;; hand-maintained bypass no longer undermines the verifiable chain.
        (fp-strict-root? #f)
        ;; Cross-gateway UC merge-proposal registry (^uc-merge-proposals), set
        ;; by the gateway once both are spawned, so the governance surface can
        ;; show collisions as scope-formation decisions.
        (uc-proposals-ref #f))

    ;; The client-signed leg's one success path: verify the caller's signature
    ;; over the SAID, issue the signed credential, answer the SAID. The
    ;; preimage/signed pairs that only issue (socialize, ownership) end here;
    ;; the ones whose success ACTS (a stance casts, a delegation writes the
    ;; map) keep their own tails — similarity is not duplication.
    (define (issue-client-signed! cred identity-key signature what)
      (cond
        ((not (client-signature-ok? cred identity-key signature))
         (list 'error (string-append
                       what " signature does not verify against caller AID")))
        ;; a SAID already in the store AND revoked stays revoked forever
        ;; (append-only revocation — and deliberately so: the old signature
        ;; still verifies, so un-revoking on re-issue would let anyone who
        ;; ever saw the signed credential replay a recalled grant back to
        ;; life). issue-idempotent would silently no-op here and this used
        ;; to answer 'ok — the citizen was told their re-issued title/grant
        ;; stood while it stayed dead. Say it loudly instead: vary a field
        ;; (the ref, where the wire carries one) to mint a fresh SAID.
        ((let ((prior (and acdc-store ($ acdc-store 'get (cred-said cred)))))
           (and prior (cred-revoked? prior)))
         (list 'error (string-append
                       what ": an identical credential was issued and revoked —"
                       " change a field (e.g. the ref) to issue it anew")))
        (else
         (when acdc-store
           ($ acdc-store 'issue-idempotent (cred-with-signature cred signature)))
         (list 'ok (cred-said cred)))))

    ;; THE CLIENT-SIGNED ACT, in two legs stated once. A preimage door answers
    ;; the SAID fields of the credential MAKE builds; the signed door rebuilds
    ;; it, runs GATE, runs BEFORE (a supersession), and issues it under the
    ;; caller's signature (issue-client-signed!). REFUSAL turns a raise into
    ;; the door's error text. The pairs whose success ACTS beyond issuing (a
    ;; stance casts, a delegation writes the map) keep their own tails.
    (define* (%preimage make #:key (refusal (lambda (a) (format #f "~a" a))))
      (catch #t
        (lambda () (list 'ok (credential-preimage-fields (make))))
        (lambda (k . a) (list 'error (refusal a)))))
    (define* (%signed! make identity-key signature what
                       #:key (gate (lambda (cred) #t)) (gate-refusal "refused")
                             (before (lambda (cred) #t))
                             (refusal (lambda (a) (format #f "~a: ~a" what a))))
      (catch #t
        (lambda ()
          (let ((cred (make)))
            (if (gate cred)
                (begin (before cred) (issue-client-signed! cred identity-key signature what))
                (list 'error gate-refusal))))
        (lambda (k . a) (list 'error (refusal a)))))

    ;; The ONE construction both purchase-claim legs share, so preimage and
    ;; signed rebuild the identical SAID from the same wire args with nothing
    ;; to echo (the socialize-preimage discipline). Wire absents are "" — each
    ;; normalizes to #f/omitted here, once.
    (define (build-purchase-claim identity-key commune-aid spec qty unit due res ref trig)
      (define (ne s) (and (string? s) (not (string-null? s)) s))
      ;; the ref is what keeps two same-shaped purchases two claims — an
      ;; empty one degrades the id to claim:AID:SPEC:open and the second
      ;; claim silently dedupes away. The shop always sends one (receipt,
      ;; or a timestamp fallback); refuse rather than degrade.
      (unless (ne ref)
        (error "purchase-claim: a non-empty ref (receipt or nonce) is required"))
      (purchase-claim identity-key commune-aid
                      (string-append "claim:" identity-key ":" spec ":"
                                     (or (ne due) "open")
                                     (let ((r (ne ref)))
                                       (if r (string-append ":" r) "")))
                      spec qty (ne unit) (ne due)
                      #:resource-inventoried-as (ne res)
                      #:triggered-by (ne trig)))

    (define (ensure-citizen aid)
      ;; Lazily spawn ^voice-signer + ^delegation-map for aid.
      ;; Returns (values voice sealed? delegation-map).
      ;;
      ;; recover-delegation-map (not a bare spawn-delegation-map) — the
      ;; first time a citizen is seen after a gateway restart, their
      ;; delegation ACDCs from before the restart are still sitting in
      ;; ACDC-STORE; a bare spawn would silently hand them a blank map,
      ;; discarding every delegation they'd set up. recover-delegation-map
      ;; replays those non-revoked credentials (mandates recompiled from
      ;; their DSL spec, not just fractions) and is a safe drop-in when
      ;; there's nothing to recover too — an AID with no prior ACDCs
      ;; recovers to the same empty map spawn-delegation-map would give.
      (let ((existing-voice (hashmap-ref voices aid #f)))
        (if existing-voice
            (values existing-voice
                    (hashmap-ref sealed?-of aid)
                    (hashmap-ref delegations aid))
            (call-with-values
              (lambda () (spawn-voice-signer aid aid))
              (lambda (voice sealed?)
                (let ((dm (if acdc-store
                              (recover-delegation-map aid acdc-store
                                                      #:write-store acdc-store)
                              (spawn-delegation-map aid #:acdc-store acdc-store))))
                  (set! voices      (hashmap-set voices      aid voice))
                  (set! sealed?-of  (hashmap-set sealed?-of  aid sealed?))
                  (set! delegations (hashmap-set delegations aid dm))
                  (values voice sealed? dm)))))))

    (define (registry-snapshot)
      ;; All known AIDs → sealed?-actor, for ballot's citizen-registry.
      sealed?-of)

    (define (voice-data-snapshot)
      ;; All known AIDs → (citizen-record), suitable for build-voice-snapshot.
      ;; Note: build-voice-snapshot operates on records; we hand-build a
      ;; list of (aid aid delegation-map) tuples (id == aid here).
      (hashmap-fold
        (lambda (aid dm acc)
          (cons (list aid aid dm) acc))
        '() delegations))

    ;; Ballot-lifecycle records (snapshot, tally) are recorded by the
    ;; authoritative governance scope, not a placeholder identity. When a
    ;; home-scope with a keypair is wired, its AID is the issuer and it signs
    ;; the record — so a forged snapshot/tally ACDC (which recovery would
    ;; otherwise trust) is rejectable. Falls back to the "governance"
    ;; placeholder unsigned in test/degraded mode (no home-scope), matching
    ;; every other #f-home-scope path in this file.
    (define (recorder-aid)
      (if (and home-scope ($ home-scope 'has-keypair?))
          ($ home-scope 'scope-aid)
          "governance"))
    (define (sign-as-recorder cred)
      (cred-signed-by-scope cred home-scope))
    ;; The one way a proposal opens: snapshot the franchise's voice, spawn the
    ;; ballot or expression, record its meta, anchor a snapshot credential.
    ;; CITIZEN-DATA, when given, is the franchise already built (a contest's:
    ;; the event's scope, the worker left out); META rides with the record.
    (define* (open-proposal! kind domain id description franchise rest
                             #:key (citizen-data #f) (meta '()))
          (let* ((citizen-data (or citizen-data
                                   (build-voice-snapshot (voice-data-snapshot) scope-roots)))
                 (registry     (registry-snapshot))
                 (event
                  (case kind
                    ((ballot)
                     (open-ballot domain id franchise description
                                  registry citizen-data))
                    ((expression)
                     (let ((target-ids (and (pair? rest) (car rest))))
                       (unless target-ids
                         (error "open: 'expression requires target-ids" id))
                       (open-expression domain id franchise description
                                        target-ids registry citizen-data)))
                    (else (error "open: unknown kind" kind)))))
            ;; The proposal's meta rides with the registry: when it opened,
            ;; and what it is about. A ballot's rest is (subject); an
            ;; expression's is (target-ids [subject]). SUBJECT is a
            ;; "kind:id" string the forum resolves against what it knows.
            (let ((subject (case kind
                             ((ballot) (and (pair? rest) (string? (car rest)) (car rest)))
                             (else (and (pair? rest) (pair? (cdr rest)) (string? (cadr rest)) (cadr rest))))))
              ($ ballot-store 'record id event
                 (append (list (cons 'opened-at   (current-time))
                               (cons 'kind        kind)
                               (cons 'domain      domain)
                               (cons 'description description)
                               (cons 'franchise   franchise))
                         (if subject (list (cons 'subject subject)) '())
                         meta)))
            ;; Anchor a snapshot ACDC for ballots (rich enough to recover).
            ;; Expressions don't carry a separate snapshot ACDC today.
            (when (and acdc-store (eq? kind 'ballot))
              (let* ((entries
                      (hashmap-fold
                        (lambda (cid pair acc)
                          (let* ((voice-share (car pair))
                                 (dm-ref      (cdr pair))
                                 (resolved    (if dm-ref
                                                  ($ dm-ref 'resolve-for franchise)
                                                  (hashmap)))
                                 (entry-list
                                  (hashmap-fold
                                    (lambda (delegate-aid entry sub-acc)
                                      (cons (list delegate-aid
                                                  (entry-fraction entry)
                                                  (let ((m (entry-mandate entry)))
                                                    (and m (mandate-spec-of m))))
                                            sub-acc))
                                    '() resolved)))
                            (cons (list cid voice-share entry-list) acc)))
                        '() citizen-data))
                     (registry-aids
                      (hashmap-fold (lambda (cid _v acc) (cons cid acc))
                                    '() registry))
                     (snap-issuer (recorder-aid))
                     (snapshot-said
                      (compute-said snap-issuer snap-issuer
                                    *schema-playnet-ballot-snapshot*
                                    (list (cons 'domain      domain)
                                          (cons 'proposal-id id)
                                          (cons 'entries entries)))))
                ($ acdc-store 'issue
                   (sign-as-recorder
                    (make-ballot-snapshot-credential
                     snap-issuer domain id franchise
                     snapshot-said (current-time)
                     #:description description
                     #:voice-snapshot-entries entries
                     #:citizen-registry-aids registry-aids)))
                ;; §4.9 + §4.6: remember the snapshot SAID for stance
                ;; / tally edges, and anchor it in the home scope's KEL
                ;; via an interaction event so verifiers see the ballot
                ;; in chain order.
                (set! snapshot-saids
                      (hashmap-set snapshot-saids id snapshot-said))
                (when (and home-scope ($ home-scope 'has-keypair?))
                  (catch #t
                    (lambda () ($ home-scope 'anchor-acdc snapshot-said))
                    (lambda _ #f)))))
            (list 'ok id)))

    ;; A closed contest ballot (contest-work below): `void` at half the
    ;; franchise's voice or more, and the work is corrected to nothing through
    ;; the scope's own observer — the kernel's correction, so hours, credit,
    ;; skill standing and the portable record all follow. The correcting event
    ;; keeps the worker as provider and the act's own edges (it is their act,
    ;; restated to zero) and names the ballot in its note. Below half, or on a
    ;; ballot that is no contest, nothing is written.
    ;; THE one rule for a decision that binds: a position carries when it
    ;; holds half the franchise's voice or more, abstention counted against.
    ;; A ratification reads its winner by it; a contest reads `void` by it.
    (define (carries? weight entries abstain)
      (let ((total (+ abstain (fold + 0 (map cdr entries)))))
        (and (> total 0) (>= (/ weight total) 1/2))))
    (define (position-weight entries name)
      (fold + 0 (map cdr (filter (lambda (e) (equal? name (format #f "~a" (car e)))) entries))))
    ;; The events a contest settles. A work event stands alone. A count is a
    ;; family: the adjustment, its record and the counter's hours, all named
    ;; from the adjustment's id (planner/formulas/counting.scm), and a contest of any
    ;; one of them is a contest of the count. What the adjustment did to a
    ;; container's contents goes back with it, in the observer. The contested
    ;; event comes first.
    (define (contest-family obs ev)
      (if (count-event? ev)
          (let ((base (count-base-id (economic-event-id ev))))
            (cons ev (filter (lambda (e) (and (count-family-id? base (economic-event-id e))
                                              (not (equal? (economic-event-id e) (economic-event-id ev)))))
                             (or ($ obs 'standing-log) '()))))
          (list ev)))
    (define (settle-contest! id tally-map abstain)
      (let ((c (assq-ref ($ ballot-store 'meta id) 'contest)))
        (when c
          (let* ((entries (hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() tally-map))
                 (eid     (assq-ref c 'event-id))
                 (obs     (scope-observer (assq-ref c 'scope-id)))
                 (ev      (and obs ($ obs 'get-event eid))))
            (when (and ev ($ obs 'event-standing? eid)
                       (carries? (position-weight entries "void") entries abstain))
              (for-each
               (lambda (e)
                 ($ obs 'apply-correction
                    (void-event e (if (equal? (economic-event-id e) eid)
                                      (string-append id ":void")
                                      (string-append id ":void~" (economic-event-id e)))
                                (string-append "contested, and found not done: " id)
                                (assq-ref c 'scope-id)
                                (instant->civil (clock-now)))))
               (contest-family obs ev)))
            (when contest-settled
              (catch #t (lambda () (contest-settled id)) (lambda _ #f)))))))

    ;; a scope's root, through the injected scope-root-of; #f where none is
    ;; injected or the scope is unknown
    (define (scope-root scope-id)
      (and scope-root-of (scope-root-of scope-id)))
    ;; its planner observer — the record a contest is settled against
    (define (scope-observer scope-id)
      (let ((root (scope-root scope-id)))
        (and root ($ root 'observer))))
    ;; the members of a scope, as AIDs, and what a contest lets one of them do:
    ;; `attach` a picture when the act is theirs, `vote` when they are in the
    ;; franchise (the roster less the worker), `none` otherwise
    (define (scope-roster root)
      (if root (map agent-id ($ ($ root 'agent-store) 'all-agents)) '()))
    (define (contest-role identity-key worker roster)
      (cond ((equal? identity-key worker) 'attach)
            ((member identity-key roster) 'vote)
            (else 'none)))

    ;; ── a contrary observation: a worker's witnessed reading against a figure ──
    ;; docs/planning/voice/feasibility-follows-the-map.md. Who may speak is the
    ;; worker the WITNESS names: a work event of theirs, in this scope's record,
    ;; on the very process the figure sits on — read off the observer, never
    ;; asserted. One live statement per (observer, scope, process, action); a
    ;; restatement supersedes. What it does to the solve is the planner's
    ;; law (engine/robust.scm observed-shocks): the cautious direction only.
    (define (build-contrary-observation identity-key scope-id process action spec nominal reading witness at)
      (let* ((obs (scope-observer scope-id))
             (act (and (or (symbol? action) (string? action)) (string->symbol (format #f "~a" action))))
             (ev  (and obs (string? witness) ($ obs 'get-event witness))))
        (unless obs (error "no such scope"))
        (unless (and (string? process) (not (string-null? process))) (error "name the process the figure sits on"))
        (unless (memq act '(produce consume use work)) (error "the figure's action is produce, consume, use or work"))   ; verb-meant: the door's own list of figures
        (unless (and (real? nominal) (> nominal 0.0)) (error "the map's figure is a positive number"))
        (unless (and (real? reading) (>= reading 0.0)) (error "the reading is a number, zero or more"))
        (unless ev (error "the witness is a work event of yours in this scope's record"))
        (unless (equal? identity-key (economic-event-provider ev)) (error "the witness names another worker"))
        (unless (equal? process (economic-event-input-of ev)) (error "the witness is a run of another process"))
        (make-contrary-observation-credential identity-key scope-id process act spec nominal reading witness at)))
    (define (revoke-prior-contrary-observations! observer scope-id process action)
      (when acdc-store
        (revoke-where! (standing-contrary-observations acdc-store scope-id observer)
                       (lambda (c) (and (equal? process (cred-claim c 'process))
                                        (equal? (format #f "~a" action) (format #f "~a" (cred-claim c 'action))))))))
    ;; a refusal in the door's own words when the error carried them, else the bare word
    (define (attest-refusal args)
      (if (and (pair? args) (string? (car args))) (car args) "refused"))

    ;; ── whose act is it ─────────────────────────────────────────────────
    ;; Two kinds of act pass through this service. A COMMUNE's own act —
    ;; accepting a grant, issuing a personhood into its ecosystem, opening a
    ;; ceremony — needs THAT commune's key and gov-cap: scope-for resolves
    ;; the named commune through the injected SCOPE-OF (the gateway's scope
    ;; graph, aid → ^scope), and home-scope answers only when it IS the
    ;; commune named. A gateway serving several communes, or a member whose
    ;; commune is elsewhere on the box, reaches the right scope; a commune
    ;; this process holds no keys for resolves to #f and the act degrades the
    ;; way every #f-home-scope path here already does. Acts that name no
    ;; commune — the ballot recorder, KEL anchoring — stay with home-scope,
    ;; this gateway's governance identity. A PERSON's act (a vouch) is signed
    ;; by the person: fp-vouch-preimage/-signed below.
    (define (scope-for commune-aid)
      (or (and scope-of (string? commune-aid)
               (false-if-exception (scope-of commune-aid)))
          (and home-scope (string? commune-aid)
               (equal? commune-aid ($ home-scope 'scope-aid))
               home-scope)))
    ;; scope-for says WHICH commune's key an act uses; WHO may ask it to
    ;; commit that commune's money or custody is ^scope's own mint-gov-cap
    ;; concern now (governance/scope.scm's may-govern?) — self-governed the
    ;; way ^wallet-policy governs Monero spend from inside the wallet, not
    ;; re-checked here. This service just propagates whatever mint-gov-cap
    ;; decides.
    ;; the ECOSYSTEM an act lands in: the real AID of the commune the id
    ;; resolves to — and when nothing resolves (a dial still carrying a
    ;; placeholder scope label), the home commune's own AID, so a
    ;; personhood is never issued into a name no key signs and no
    ;; blessing chains to
    (define (ecosystem-for scope-id)
      (let ((sc (scope-for scope-id)))
        (cond (sc ($ sc 'scope-aid))
              (home-scope ($ home-scope 'scope-aid))
              (else scope-id))))
    (define (scope-signer commune-aid)      ; (cred → signed cred), or #f when unsigned
      (let ((sc (scope-for commune-aid)))
        (and sc ($ sc 'has-keypair?)
             (lambda (c) (cred-with-signature c ($ sc 'sign-said (cred-said c)))))))
    ;; ── a vouch: the person's own word, built once for every leg ─────────
    ;; ISSUED-AT is the caller's own stamp (the bridge fills the clock), so
    ;; the preimage and the signed rebuild agree bit-for-bit and a re-vouch
    ;; after a revoke is a fresh SAID rather than the revoked one.
    (define (build-vrc identity-key subject-aid rel issued-at)
      (let ((caller-phc (any-live-phc-for acdc-store identity-key)))
        (when (equal? identity-key subject-aid) (error "cannot vouch for yourself"))
        (unless caller-phc (error "you must be a recognised person to vouch"))
        (make-relationship-credential
         identity-key subject-aid
         (string->symbol (normalize-rel rel))
         (cred-said caller-phc) issued-at)))
    ;; build-vrc's own refusals are worded; anything else reads "vouch failed"
    (define (vouch-refusal args)
      (if (and (pair? args) (string? (car args))) (car args) "vouch failed"))
    ;; ── being recognised — the ceremony as the one door ─────────────────
    ;; The ecosystem's policy is read off the commune's own scope-root
    ;; (personhood-policy.scm); absent a reachable scope, the defaults.
    (define (policy-store scope-id)
      (let ((sc (scope-for scope-id)))
        (and sc (false-if-exception ($ ($ sc 'scope-root) 'plan-store)))))
    (define (policy scope-id key) (personhood-policy (policy-store scope-id) key))
    ;; how many people could witness here: every live personhood the
    ;; store holds (portable, like fp-status reads it)
    (define (verified-count)
      (if acdc-store
          (length (delete-duplicates
                   (map cred-holder
                        (filter phc-live? ($ acdc-store 'by-schema *schema-playnet-personhood*)))))
          0))
    ;; open (or find) the candidate's ceremony with the ecosystem's word on
    ;; k, cap and window; SPONSOR is the introducing person or #f
    (define (open-enrollment! scope-id candidate-aid sponsor)
      (spawn-enrollment-ceremony
       scope-id candidate-aid
       (if sponsor (string-append "recognition:" sponsor) *self-request-evidence*)
       sponsor
       (effective-k (policy scope-id 'enrollment-k) (verified-count))
       acdc-store
       #:sign-cred (scope-signer scope-id)
       #:root-aid fp-root-aid
       #:witness-cap (policy scope-id 'witness-cap)
       #:witness-window (policy scope-id 'witness-window)))
    (define (expire-stale! scope-id)
      (catch #t
        (lambda () (expire-stale-enrollments! (policy scope-id 'ceremony-ttl)))
        (lambda _ '())))
    ;; who already vouches for AID by relationship credential AND is
    ;; recognised — the people an ask reaches first
    (define (vouchers-of aid)
      (if (not acdc-store) '()
          (delete-duplicates
           (filter-map (lambda (c)
                         (and (equal? aid (cred-holder c))
                              (holds-any-live-phc? acdc-store (cred-issuer c))
                              (cred-issuer c)))
                       (%live-by-schema acdc-store *schema-playnet-relationship* #f)))))
    ;; retag IS revoke + issue: the book holds one rel per person, so the
    ;; standing vouches from IDENTITY-KEY to SUBJECT-AID end when a new one
    ;; is spoken — no earlier rel stays live beside it
    ;; one live statement per key: a new one revokes what it supersedes
    (define (revoke-where! creds same?)
      (for-each (lambda (c) (when (same? c) ($ acdc-store 'revoke (cred-said c)))) creds))
    (define (revoke-prior-vouches! identity-key subject-aid)
      (revoke-where! (%live-by-schema acdc-store *schema-playnet-relationship* #f)
                     (lambda (c) (and (equal? identity-key (cred-issuer c))
                                      (equal? subject-aid (cred-holder c))))))

    ;; ── credentials carried from elsewhere: the bundle ──────────────────
    ;; A BUNDLE is what a person carries between gateways: cards (the
    ;; wire shape of fp-my-phc — governance-cred->wire + the issuer's
    ;; signature) for a personhood, the relationship credentials that
    ;; vouch for them or that they spoke, the personhood of each voucher
    ;; and the root's blessing of its ecosystem; and, for every voucher
    ;; whose AID is a browser-born E-prefix, that voucher's KEY LOG — the
    ;; one thing a foreign gateway cannot derive, without which the
    ;; voucher's signature cannot be checked. present-bundle verifies in
    ;; dependency order and imports only what stands; every consumer of
    ;; a vouch reads the store, so an imported vouch counts here exactly
    ;; as it did where it was spoken.
    (define (trusted-ecosystem? eco pending-aics)
      (or (and fp-root-aid (ecosystem-chains-to-any-root? acdc-store fp-root-aid eco))
          (and (not fp-strict-root?) (member eco fp-trusted-issuers) #t)
          (and (pair? pending-aics)
               (any (lambda (a) (equal? eco (cred-holder a))) pending-aics))))
    (define (card->cred card) (fp-wire->cred card))
    (define (kel-wire->parts kel)
      ;; the dial's own KEL shape → (values icp sigs rotations-vector)
      (let ((rots (assoc-ref kel "rotations")))
        (values (assoc-ref kel "icp")
                (assoc-ref kel "sigs")
                (list->vector
                 (map (lambda (r) (cons (assoc-ref r "rot") (assoc-ref r "sigs")))
                      (if (vector? rots) (vector->list rots) '()))))))
    (define (land-kels! kels)
      ;; every carried key log lands first — a log that fails verification
      ;; fails the bundle. Returns #t or an error string.
      (let loop ((ks kels))
        (cond
         ((null? ks) #t)
         ((not kel-landing) "this gateway cannot land a carried key log")
         (else
          (let ((aid (car (car ks))) (kel (cdr (car ks))))
            (call-with-values (lambda () (kel-wire->parts kel))
              (lambda (icp sigs rots)
                (let ((v (catch #t (lambda () (kel-landing aid icp sigs rots))
                           (lambda (k . a) "key log could not be landed"))))
                  (if (eq? v #t) (loop (cdr ks))
                      (string-append "key log for " aid ": " (if (string? v) v "refused")))))))))))
    (define (present-bundle! identity-key parsed)
      (let* ((bare? (assoc "d" parsed))               ; one card, the older wire
             (cards (if bare? (list parsed)
                        (let ((c (assoc-ref parsed "creds")))
                          (cond ((vector? c) (vector->list c)) ((list? c) c) (else '())))))
             (kels  (let ((k (assoc-ref parsed "kels"))) (if (list? k) k '())))
             (creds (map card->cred cards))
             (of    (lambda (schema) (filter (lambda (c) (equal? schema (cred-schema c))) creds)))
             (aics  (of *schema-playnet-authorized-issuer*))
             (phcs  (of *schema-playnet-personhood*))
             (vrcs  (of *schema-playnet-relationship*))
             (now   (current-time))
             (sound? (lambda (c) (and (cred-said-consistent? c) (cred-signature-valid? c)
                                      (cred-live-at? c now))))
             (landed (land-kels! kels)))
        (cond
         ((not (eq? landed #t)) (cons 'error landed))
         ((not (= (length creds) (+ (length aics) (length phcs) (length vrcs))))
          (cons 'error "the bundle carries a credential of a kind this gateway does not present"))
         ;; the root's blessings: only a root's own word
         ((not (every (lambda (a) (and (sound? a)
                                       fp-root-aid
                                       (ecosystem-chains-to-any-root? acdc-store fp-root-aid (cred-issuer a))))
                      aics))
          (cons 'error "a carried issuer blessing is not the root's"))
         (else
          (let* ((anchor-of (lambda (v) (let ((e (cred-edge v 'issuer-phc))) (and e (edge-target e)))))
                 (anchors (filter-map anchor-of vrcs))
                 ;; a personhood is accepted as the CALLER's, or as the anchor
                 ;; of a vouch in this bundle — never as anyone else's
                 ;; the personhood gates, in the order the one-card door has
                 ;; always asked them: whose it is, who issued it, that the
                 ;; digest commits to the content, the signature, liveness
                 (phc-ok (lambda (p)
                           (cond
                            ((not (or (equal? (cred-holder p) identity-key)
                                      (member (cred-said p) anchors)))
                             "presented PHC is not yours")
                            ((not (trusted-ecosystem? (cred-issuer p) aics))
                             "issuer is not a federated commune")
                            ((not (cred-said-consistent? p))
                             "PHC digest does not commit to its contents")
                            ((not (cred-signature-valid? p))
                             "PHC signature does not verify")
                            ((not (cred-live-at? p now))
                             "presented PHC is not live")
                            (else #t))))
                 (phc-verdicts (map phc-ok phcs))
                 (bad-phc (find string? phc-verdicts)))
            (if bad-phc (cons 'error bad-phc)
                (let* ((live-phc (lambda (said)
                                   (or (find (lambda (p) (equal? said (cred-said p))) phcs)
                                       (let ((c ($ acdc-store 'get said)))
                                         (and c (equal? *schema-playnet-personhood* (cred-schema c))
                                              (cred-live-at? c now) c)))))
                       (vrc-ok (lambda (v)
                                 (let ((p (live-phc (anchor-of v))))
                                   (cond
                                    ((not (sound? v)) "a carried vouch does not verify")
                                    ((not (or (equal? (cred-holder v) identity-key)
                                              (equal? (cred-issuer v) identity-key)))
                                     "a carried vouch neither names you nor is yours")
                                    ((not p) "a carried vouch's voucher holds no personhood here")
                                    ((not (equal? (cred-holder p) (cred-issuer v)))
                                     "a carried vouch's personhood belongs to someone else")
                                    (else #t)))))
                       (vrc-verdicts (map vrc-ok vrcs))
                       (bad-vrc (find string? vrc-verdicts)))
                  (if bad-vrc (cons 'error bad-vrc)
                      (let ((n ($ acdc-store 'import
                                  (map (lambda (c) (cons c #f)) (append aics phcs vrcs)))))
                        (cons 'ok (if (number? n) n 0)))))))))))
    (define (card c) (append (governance-cred->wire c) (list (cons "sig" (or (cred-signature c) "")))))
    (define (my-bundle identity-key)
      ;; what IDENTITY-KEY carries: their personhood; every live vouch for
      ;; them and every live vouch they spoke; each voucher's personhood
      ;; and its ecosystem's blessing when held; a key log for every
      ;; E-prefix AID a foreign verifier would otherwise be unable to check
      (let* ((mine (any-live-phc-for acdc-store identity-key))
             (vrcs (filter (lambda (c) (or (equal? identity-key (cred-holder c))
                                           (equal? identity-key (cred-issuer c))))
                           (%live-by-schema acdc-store *schema-playnet-relationship* #f)))
             (vouchers (delete-duplicates (map cred-issuer vrcs)))
             (phcs (delete-duplicates
                    (append (if mine (list mine) '())
                            (filter-map (lambda (a) (any-live-phc-for acdc-store a)) vouchers))))
             (ecos (delete-duplicates (map cred-issuer phcs)))
             (aics (filter-map (lambda (eco)
                                 (find (lambda (a) (and (equal? eco (cred-holder a))
                                                        (cred-live-at? a (current-time))))
                                       ($ acdc-store 'by-schema *schema-playnet-authorized-issuer*)))
                               ecos))
             (need-kel (filter (lambda (a) (and (string? a) (string-prefix? "E" a)))
                               (delete-duplicates (cons identity-key vouchers))))
             (kels (if kel-of
                       (filter-map (lambda (a) (let ((k (false-if-exception (kel-of a))))
                                                 (and k (cons a k))))
                                   need-kel)
                       '())))
        `(("creds" . ,(list->vector (map card (append aics phcs vrcs))))
          ("kels" . ,kels))))
(finishing
    (methods

      ;; --- First-Person: personhood (PHC) + relationship (VRC) ---
      ;; identity-key is the session-bound, KERI-authenticated AID — trusted.
      ;; We query our OWN acdc-store directly; personhood is PORTABLE (a live
      ;; PHC from ANY ecosystem counts — refederation-proof). scope-id labels
      ;; the request and is the ecosystem we ISSUE into on grant.
      ((fp-status identity-key scope-id)
       (cons 'ok (list (cons 'person (holds-any-live-phc? acdc-store identity-key))
                       (cons 'scope scope-id)
                       ;; what the dial may offer: a founder's genesis act
                       ;; only while no one is recognised; how many could
                       ;; witness, which is what the quorum clamps to
                       (cons 'governor (and (governor? identity-key) #t))
                       (cons 'bootstrapped (and acdc-store (personhood-bootstrapped? acdc-store) #t))
                       (cons 'verified-count (verified-count)))))
      ;; ── vouching: the person's word, in the person's signature ────────────
      ;; fp-vouch-preimage / fp-vouch-signed are the client-signed pair (the
      ;; twin of socialize-preimage/-signed): the browser re-derives the SAID
      ;; over the returned fields and signs with the resident key; the server
      ;; rebuilds from the same wire args and issues iff the signature is the
      ;; voucher's. The bare fp-vouch remains for a session that cannot sign
      ;; (no resident key): the same credential, issued unsigned — no scope
      ;; speaks in a person's name. All three end the prior vouches first.
      ((fp-vouch-preimage identity-key scope-id subject-aid rel at)
       (%preimage (lambda () (build-vrc identity-key subject-aid rel at)) #:refusal vouch-refusal))

      ((fp-vouch-signed identity-key scope-id subject-aid rel at signature)
       (%signed! (lambda () (build-vrc identity-key subject-aid rel at)) identity-key signature "vouch"
                 #:before (lambda (_) (revoke-prior-vouches! identity-key subject-aid))
                 #:refusal vouch-refusal))

      ((fp-vouch identity-key scope-id subject-aid rel)
       (catch #t
         (lambda ()
           (let ((vrc (build-vrc identity-key subject-aid rel (current-time))))
             (revoke-prior-vouches! identity-key subject-aid)
             ($ acdc-store 'issue vrc)
             (cons 'ok #t)))
         (lambda (k . a) (cons 'error (vouch-refusal a)))))
      ;; a vouch is the voucher's own to end: every standing vouch from the
      ;; caller for SUBJECT-AID is revoked, and none standing is the same ok
      ((fp-withdraw-vouch identity-key scope-id subject-aid)
       (if (not acdc-store)
           (cons 'error "no credential store on this gateway")
           (begin (revoke-prior-vouches! identity-key subject-aid)
                  (cons 'ok #t))))
      ;; ── what stands between the caller and each of AIDS ───────────────────
      ;; The reading a contact row shows, for the people in the caller's own
      ;; book (the session reads the book and hands the AIDs). Each row is
      ;; of the pair: is this person recognised, the kind the caller's
      ;; standing vouch for them states, the kind theirs for the caller
      ;; states, and their open ask in SCOPE-ID with whether the caller has
      ;; signed it. Who else vouches for them is theirs to carry.
      ((relationships identity-key scope-id aids)
       (let* ((scope-id (ecosystem-for scope-id))
              (kind (lambda (issuer subject)
                      (let ((c (and acdc-store (vrc-from-to acdc-store issuer subject))))
                        (and c (normalize-rel (cred-claim c 'relationship-type))))))
              (ask-of (lambda (aid)
                        (let ((c (enroll-ceremony-for-candidate scope-id aid)))
                          (and c `((said . ,($ c 'statement-said))
                                   (count . ,($ c 'attestation-count))
                                   (quorum . ,($ c 'threshold))
                                   (signed . ,(and (member identity-key ($ c 'attesting-witnesses)) #t))))))))
         (expire-stale! scope-id)
         (cons 'ok
               (map (lambda (aid)
                      `((aid . ,aid)
                        (recognised . ,(and acdc-store (holds-any-live-phc? acdc-store aid) #t))
                        (mine . ,(kind identity-key aid))
                        (theirs . ,(kind aid identity-key))
                        (ask . ,(ask-of aid))))
                    (delete identity-key (delete-duplicates (filter string? aids)))))))
      ;; ── being recognised: the request IS the ceremony ─────────────────────
      ;; A candidate asks for themself: the ask is an enrollment ceremony
      ;; opened with no sponsor, the ecosystem's quorum (personhood-policy,
      ;; clamped to the verified population), durable on disk and on every
      ;; witness rail. Asking again finds the standing ask. What the
      ;; candidate reads back is the ceremony itself — fp-my-ceremony.
      ((fp-request-enroll identity-key scope-id)
       (let ((scope-id (ecosystem-for scope-id)))
       (cond
        ((not acdc-store) (cons 'error "no credential store on this gateway"))
        ((holds-any-live-phc? acdc-store identity-key)
         (cons 'error "you are already recognised"))
        (else
         (catch #t
           (lambda ()
             (open-enrollment! scope-id identity-key #f)
             (cons 'ok #t))
           (lambda (key . args)
             (format (current-error-port)
                     "[governance-svc] fp-request-enroll failed: ~a ~a~%" key args)
             (cons 'error "could not open the ask")))))))
      ;; the standing asks in SCOPE-ID, with each one's progress — what the
      ;; witness rail and the sheet's queue show
      ((fp-pending identity-key scope-id)
       (let ((scope-id (ecosystem-for scope-id)))
       (expire-stale! scope-id)
       (cons 'ok (map (lambda (row)
                        (cons (cons 'vouchers (vouchers-of (assq-ref row 'candidate))) row))
                      (enroll-asks scope-id)))))
      ;; the caller's own ask: none, collecting (n of k, who already vouches
      ;; for them by relationship credential), or finalized
      ((fp-my-ceremony identity-key scope-id)
       (let* ((scope-id (ecosystem-for scope-id)))
       (expire-stale! scope-id)
       (let ((c (enroll-ceremony-for-candidate scope-id identity-key)))
         (cons 'ok
               (cond
                ((holds-any-live-phc? acdc-store identity-key)
                 `((state . finalized)))
                (c `((state . collecting)
                     (count . ,($ c 'attestation-count))
                     (quorum . ,($ c 'threshold))
                     (witnesses . ,($ c 'attesting-witnesses))
                     (vouchers . ,(vouchers-of identity-key))))
                (else `((state . none))))))))
      ((fp-grant identity-key scope-id* candidate-aid)
       ;; GENESIS only: the operator's founding act, for an ecosystem with
       ;; no verified person yet (the founders.txt seed is the same act at
       ;; boot). Once anyone is recognised, every later person comes in
       ;; through witnesses — fp-request-enroll / fp-open-ceremony.
       (let ((scope-id (ecosystem-for scope-id*)))
       (cond
        ((not (governor? identity-key))
         (cons 'error "only governance can grant personhood"))
        ((ecosystem-personhood-bootstrapped? acdc-store scope-id)
         (cons 'error "personhood is bootstrapped — recognition comes through witnesses now"))
        ((not (%sponsor-fanout-ok? acdc-store scope-id identity-key))
         (cons 'error "sponsor fan-out cap reached — too many recent grants"))
        (else
         (catch #t
           (lambda ()
             ;; Signed by the ECOSYSTEM the personhood is issued into —
             ;; scope-id's own scope, through scope-signer — the way
             ;; scope.scm's issue-phc/invite sign (sign-said, keypair inside
             ;; the scope actor). Unsigned when this process holds no key
             ;; for that commune.
             (let* ((phc (make-personhood-credential
                          scope-id candidate-aid (current-time)
                          #:sponsor-aid identity-key))
                    (sign (scope-signer scope-id))
                    (signed (if sign (sign phc) phc)))
               ($ acdc-store 'issue signed))
             (cons 'ok #t))
           (lambda (k . a)
             (format (current-error-port) "[governance-svc] fp-grant: ~a ~a~%" k a)
             (cons 'error "grant failed")))))))
      ((fp-open-ceremony identity-key scope-id* candidate-aid . _k)
       ;; A verified person INTRODUCES a newcomer: the same ceremony the
       ;; candidate could open for themself, with the introducer recorded as
       ;; sponsor (fan-out capped). The ecosystem's quorum applies; a
       ;; trailing k from an older bundle is ignored. The ask lands on
       ;; every witness rail and each vouch is the witness's OWN signature
       ;; over the statement-SAID; at quorum the PHC issues carrying one
       ;; NI2I edge per witness.
       (let ((scope-id (ecosystem-for scope-id*)))
       (cond
        ((not acdc-store)
         (cons 'error "no credential store on this gateway"))
        ((not (holds-any-live-phc? acdc-store identity-key))
         (cons 'error "only a recognised person can introduce someone"))
        ((not (%sponsor-fanout-ok? acdc-store scope-id identity-key))
         (cons 'error "sponsor fan-out cap reached — too many recent introductions"))
        (else
         (catch #t
           (lambda ()
             (open-enrollment! scope-id candidate-aid identity-key)
             (cons 'ok #t))
           (lambda (key . args)
             (format (current-error-port)
                     "[governance-svc] fp-open-ceremony failed: ~a ~a~%"
                     key args)
             (cons 'error "ceremony open failed")))))))

      ((set-home-scope! s) (set! home-scope s) 'ok)
      ((set-scope-of! f) (set! scope-of f) 'ok)
      ;; after boot, once the scopes and the root are wired: every open ask
      ;; comes back from its record with its vouches — the gateway calls
      ;; this where it installs the witness door
      ((fp-rehydrate!)
       (if (not acdc-store) (cons 'ok '())
           (cons 'ok (rehydrate-enrollment-ceremonies!
                      acdc-store
                      #:sign-cred-of scope-signer
                      #:root-aid fp-root-aid))))

      ;; the caller's own live PHC as a portable card (said+issuer+sig is the
      ;; verifiable core; a foreign gateway can re-SAID the claims and check
      ;; the sig). #f when the caller holds none. Slice-1 of PHC presentation.
      ((fp-my-phc identity-key)
       ;; the holder's PHC as a portable, presentable wire (governance-cred->wire
       ;; SAD shape + the issuer's signature) — the dial carries this and can
       ;; present it to other gateways. #f when the caller holds none.
       (let ((c (any-live-phc-for acdc-store identity-key)))
         (cons 'ok
               (and c (append (governance-cred->wire c)
                              (list (cons "sig" (or (cred-signature c) ""))))))))

      ((set-fp-trusted-issuers! lst)
       (set! fp-trusted-issuers (if (list? lst) lst '())) 'ok)

      ;; Set the trust-registry root. AID is a single root AID, or a LIST of
      ;; recognized roots (multi-root cross-recognition — persons chaining to
      ;; ANY recognized root are honoured, so two independently-booted graphs
      ;; legibilise each other without merging). #f disables root-chain trust.
      ((set-fp-root! aid)
       (set! fp-root-aid (cond ((string? aid) aid) ((pair? aid) aid) (else #f)))
       'ok)
      ((fp-root) (cons 'ok fp-root-aid))
      ;; Drop/keep the whitelist fallback. Flip on once the root chain is live.
      ((set-fp-strict-root! flag)
       (set! fp-strict-root? (and flag #t)) 'ok)

      ;; Your two governance weights (playnet.typ §Governance), reusing the
      ;; planner: PRODUCER voice = labour share (`voice-share`) on production;
      ;; CONSUMER voice = share of the claimable pool (`consumer-voice`) on
      ;; consumption. #f substrate → 0.
      ((my-voice identity-key)
       (catch #t
         (lambda ()
           (let ((cv (consumer-voice identity-key scope-roots)))
             (list (cons 'producer (exact->inexact (voice-share identity-key scope-roots)))
                   ;; #f when the claimable pool is empty — surfaced as -1 so
                   ;; the dial shows the qualitative consumer voice, not 0%.
                   (cons 'consumer (if cv (exact->inexact cv) -1.0)))))
         (lambda _ (list (cons 'producer 0.0) (cons 'consumer -1.0)))))

      ;; Producer voice IN ONE COMMUNE — your labour share there, the weight
      ;; a ballot under that scope's franchise gives you. Reads the commune's
      ;; own root (a list of one, for account.scm's global reads); a commune
      ;; the gateway cannot name answers 0.
      ((set-scope-root-of! f) (set! scope-root-of f) 'ok)
      ((set-contest-settled! f) (set! contest-settled f) 'ok)

      ;; The contests open in SCOPE-ID, as they stand to IDENTITY-KEY: each with
      ;; the event it names, the member who contested and why, whose act it is,
      ;; and what IDENTITY-KEY may do about it — `attach` a picture when the act
      ;; is theirs, `vote` when they are in the franchise (the roster less the
      ;; worker), `none` otherwise.
      ((contests identity-key scope-id)
       (catch #t
         (lambda ()
           (let* ((root   (scope-root scope-id))
                  (roster (scope-roster root)))
             (list 'ok
                   (filter-map
                    (lambda (p)
                      (let* ((id (car p))
                             (c  (assq-ref ($ ballot-store 'meta id) 'contest)))
                        (and c (eq? 'open (cdr p)) (equal? scope-id (assq-ref c 'scope-id))
                             `((id . ,id)
                               (event-id . ,(assq-ref c 'event-id))
                               (kind . ,(or (assq-ref c 'kind) 'work))
                               (resource . ,(or (assq-ref c 'resource) ""))
                               (worker . ,(assq-ref c 'worker))
                               (by . ,(assq-ref c 'by))
                               (reason . ,(assq-ref c 'reason))
                               (role . ,(contest-role identity-key (assq-ref c 'worker) roster))))))
                    ($ ballot-store 'list-proposals)))))
         (lambda (_k . args) (list 'error (format #f "~a" args)))))

      ;; What a contested count lets IDENTITY-KEY do with a picture: the hash the
      ;; count's events name, and the role. The counter whose act it is may
      ;; attach it; the franchise may read it; no one else may do either.
      ((contest-terms identity-key ballot-id)
       (catch #t
         (lambda ()
           (let* ((c      (assq-ref ($ ballot-store 'meta ballot-id) 'contest))
                  (open?  (and c ($ ballot-store 'get ballot-id)))
                  (root   (and c (scope-root (assq-ref c 'scope-id))))
                  (obs    (and root ($ root 'observer)))
                  (ev     (and obs ($ obs 'get-event (assq-ref c 'event-id))))
                  (role   (and c (contest-role identity-key (assq-ref c 'worker) (scope-roster root)))))
             (cond
               ((not c) (list 'error "no such contest"))
               ((not open?) (list 'error "this contest has settled"))
               ((not ev) (list 'error "event not found"))
               ((not (memq (or (assq-ref c 'kind) 'work) '(count))) (list 'error "only a count's picture is held"))
               ((eq? role 'none) (list 'error "only the counter and the scope's members see this contest's picture"))
               (else
                (list 'ok `((role . ,role) (scope-id . ,(assq-ref c 'scope-id))
                            (hash . ,(any (lambda (e) (tags-evidence (economic-event-resource-classified-as e)))
                                          (contest-family obs ev)))))))))
         (lambda (_k . args) (list 'error (format #f "~a" args)))))
      ((voice-in identity-key scope-id)
       (catch #t
         (lambda ()
           (let ((root (scope-root scope-id)))
             (list (cons 'producer (if root
                                       (exact->inexact (voice-share identity-key (list root)))
                                       0.0)))))
         (lambda _ (list (cons 'producer 0.0)))))

      ;; Cross-gateway UC merge proposals (scope-formation decisions). The
      ;; gateway sets the registry ref; we surface its pending list.
      ((set-uc-proposals! ref) (set! uc-proposals-ref ref) 'ok)
      ((list-uc-proposals)
       (if uc-proposals-ref
           (map (lambda (e) (list (car e) (cadr e))) ($ uc-proposals-ref 'pending))
           '()))

      ;; A PHC carried from ANOTHER gateway/commune, presented for recognition.
      ;; Honour iff: holder == the authenticated caller, the issuer's signature
      ;; verifies (verify-said-signature resolves the issuer's key state), and
      ;; the issuer is a TRUSTED federated commune. Then import into our store so
      ;; the any-ecosystem fold recognises this person locally.
      ;; A PHC carried from ANOTHER gateway/commune, presented for recognition:
      ;; the one-card bundle. Honour iff: holder == the authenticated caller,
      ;; the issuer's signature verifies, and the issuer is a TRUSTED
      ;; federated commune. present-bundle below is the whole rule.
      ((present-phc identity-key wire-json)
       (catch #t
         (lambda ()
           (let ((parsed (json-read-ordered wire-json)))
             (if (not (equal? (assoc-ref parsed "s") *schema-playnet-personhood*))
                 (cons 'error "not a personhood credential")
                 (let ((r (present-bundle! identity-key parsed)))
                   (if (eq? 'ok (car r)) (cons 'ok #t) r)))))
         (lambda (k . a) (cons 'error "present-phc failed"))))

      ;; A BUNDLE carried from elsewhere — personhoods, vouches, the
      ;; blessings and key logs that make them checkable here. Verified in
      ;; dependency order, imported only when every card stands; a
      ;; re-presentation is a no-op. Answers (ok . newly-imported).
      ((present-bundle identity-key wire-json)
       (catch #t
         (lambda () (present-bundle! identity-key (json-read-ordered wire-json)))
         (lambda (k . a)
           (format (current-error-port) "[governance-svc] present-bundle: ~a ~a~%" k a)
           (cons 'error "present-bundle failed"))))

      ;; what the caller carries to the next gateway, as one JSON string —
      ;; my-bundle above. "" when there is nothing to carry.
      ((fp-my-vouches identity-key)
       (catch #t
         (lambda ()
           (let ((b (my-bundle identity-key)))
             (cons 'ok (if (zero? (vector-length (assoc-ref b "creds"))) ""
                           (scm->json-canonical b)))))
         (lambda (k . a) (cons 'error "fp-my-vouches failed"))))

      ;; --- Citizen access ---
      ((citizen-voice identity-key)
       ;; Returns the caller's ^voice-signer ref. Auto-spawns on first
       ;; access. Caller has been KERI-authenticated at the lobby.
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (voice _s _dm) voice)))

      ((delegation-map identity-key)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm) dm)))

      ;; The caller's federation-default delegations as DATA (for the dial's
      ;; liquid-democracy view): a list of (delegate-aid fraction mandated?).
      ;; The fraction you keep is 1 − Σ delegated.
      ((list-delegations identity-key)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (hashmap-fold
             (lambda (delegate entry acc)
               (cons (list delegate (entry-fraction entry)
                           (and (entry-mandate entry) #t))
                     acc))
             '() ($ dm 'federation-default)))))

      ;; --- Delegation writes (caller must be the AID) ---
      ((set-delegation identity-key delegate-aid fraction . rest)
       ;; rest: () for federation-default, ('scope SID) for scope override
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (cond
             ((null? rest)
              ($ dm 'delegate delegate-aid fraction))
             (else
              ($ dm 'delegate delegate-aid fraction (car rest) (cadr rest))))
           'ok)))

      ;; Client-signed delegation — the same shape as the stance path. A
      ;; delegation is the CITIZEN's assertion, so the conformant ACDC must
      ;; carry the citizen's own signature, and their key is client-side. This
      ;; pair handles LIQUID delegations; mandated ones use the mandate-spec
      ;; variant below (same protocol, credential carries a mandate spec).
      ;;
      ;;   delegation-preimage → the SAID-relevant fields of the exact
      ;;   credential we would issue. The client re-derives the SAID
      ;;   (compute-said, shared via keri/said-portable) and signs it — not
      ;;   blind-signing, since it re-derives from the claims it can inspect
      ;;   (who it delegates to, what fraction).
      ;;
      ;;   set-delegation-signed → we rebuild the same credential from the
      ;;   client's own delegate/fraction, verify the signature against the
      ;;   caller's AID, and issue it signed. The caller AID is session-bound
      ;;   and we rebuild from the client's args, so the delegation can be
      ;;   neither forged as another citizen nor silently retargeted.
      ((delegation-preimage identity-key delegate-aid fraction . rest)
       (list 'ok
             (credential-preimage-fields
              (make-delegation-credential
               identity-key delegate-aid
               (if (and (pair? rest) (eq? (car rest) 'scope))
                   (list 'scope (cadr rest))
                   'federation)
               fraction #f))))

      ((set-delegation-signed identity-key delegate-aid fraction signature . rest)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (catch #t
             (lambda ()
               (let ((cred (make-delegation-credential
                            identity-key delegate-aid
                            (if (and (pair? rest) (eq? (car rest) 'scope))
                                (list 'scope (cadr rest))
                                'federation)
                            fraction #f)))
                 (cond
                   ((not (client-signature-ok? cred identity-key signature))
                    (list 'error "delegation signature does not verify against caller AID"))
                   (else
                    (if (null? rest)
                        ($ dm 'delegate-signed delegate-aid fraction signature)
                        ($ dm 'delegate-signed delegate-aid fraction signature
                           (car rest) (cadr rest)))
                    'ok))))
             (lambda (key . args)
               (list 'error (format #f "set-delegation-signed failed: ~a ~a" key args)))))))

      ;; Mandated delegation — the same client-signing shape as liquid, but the
      ;; credential carries a mandate SPEC (a data expression like
      ;; '(equal-position yes)), never a predicate closure. A closure can't cross
      ;; the wire and can't be signed; the spec can. The client re-derives the
      ;; SAID over the credential-with-mandate-spec and signs it; we rebuild,
      ;; verify against the caller AID, then compile the spec into the live
      ;; predicate via `(mandate spec)` (which registers spec↔predicate so the
      ;; issued ACDC's SAID matches what the client signed).
      ((delegation-mandated-preimage identity-key delegate-aid fraction mandate-spec . rest)
       (list 'ok
             (credential-preimage-fields
              (make-delegation-credential
               identity-key delegate-aid
               (if (and (pair? rest) (eq? (car rest) 'scope))
                   (list 'scope (cadr rest))
                   'federation)
               fraction mandate-spec))))

      ((set-delegation-mandated-signed identity-key delegate-aid fraction mandate-spec signature . rest)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (catch #t
             (lambda ()
               (let ((cred (make-delegation-credential
                            identity-key delegate-aid
                            (if (and (pair? rest) (eq? (car rest) 'scope))
                                (list 'scope (cadr rest))
                                'federation)
                            fraction mandate-spec))
                     (pred (mandate mandate-spec)))
                 (cond
                   ((not pred)
                    (list 'error (format #f "unrecognized mandate spec: ~s" mandate-spec)))
                   ((not (client-signature-ok? cred identity-key signature))
                    (list 'error "mandated delegation signature does not verify against caller AID"))
                   (else
                    (if (null? rest)
                        ($ dm 'delegate-mandated-signed delegate-aid fraction pred signature)
                        ($ dm 'delegate-mandated-signed delegate-aid fraction pred signature
                           (car rest) (cadr rest)))
                    'ok))))
             (lambda (key . args)
               (list 'error (format #f "set-delegation-mandated-signed failed: ~a ~a" key args)))))))

      ((revoke-delegation identity-key delegate-aid . rest)
       (call-with-values
         (lambda () (ensure-citizen identity-key))
         (lambda (_v _s dm)
           (cond
             ((null? rest) ($ dm 'revoke delegate-aid))
             (else ($ dm 'revoke delegate-aid (car rest) (cadr rest))))
           'ok)))

      ;; --- Voice events: ballot ('binary yes/no) and expression
      ;; ('fractional distribution). Unified surface — kind dispatches.
      ;;
      ;;   open  : governor opens an event of given kind in given domain
      ;;   cast  : anyone authenticated casts; voice-weight from snapshot
      ;;   close : governor closes; ballots get tally-result ACDC
      ;;   get-result : live or closed result
      ;;
      ;; KIND: 'ballot  → arg/cast is a position symbol ('yes | 'no | …);
      ;;                  rest = ()
      ;;       'expression → arg/cast is a distribution hashmap;
      ;;                     rest = (target-ids) — list of target strings

      ;; Issue an ACDC as this gateway's store: a governor act, gated on
      ;; the same founders.txt `governor?` every other admin door here
      ;; gates on. CRED has already been through lobby.scm's own
      ;; issuer==caller check — this door is the only path that reaches
      ;; the store, so a caller without governor standing gets refused
      ;; before ACDC-STORE ever sees the credential. The reply CHAINS
      ;; acdc-store's own — its `issue` resolves to the SAID on success,
      ;; and a rejection (a SAID collision) propagates as one, the same
      ;; shape every other governance-svc→acdc-store door here already
      ;; returns unwrapped (present-bundle, socialize-signed, …) — no
      ;; local catch, so the reply is never claimed before the write
      ;; that backs it has actually landed.
      ((issue-credential identity-key cred)
       (cond
         ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
         ((not (governor? identity-key)) (list 'error "issuer must hold governor standing"))
         (else (<- acdc-store 'issue cred))))

      ;; Revoke an ACDC by SAID — same governor gate, no issuer check:
      ;; governance revokes by policy, not by authorship. acdc-store's
      ;; `revoke` resolves to no useful value on success (a rebind, not a
      ;; reply) and raises on an unknown SAID, so this turns the settled
      ;; promise into 'ok — never claiming success before the rebind has
      ;; actually happened, the same bug this replaces.
      ((revoke-credential identity-key said)
       (cond
         ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
         ((not (governor? identity-key)) (list 'error "revoker must hold governor standing"))
         (else (on (<- acdc-store 'revoke said)
                   (lambda (_) 'ok)
                   #:catch (lambda (e) (list 'error (format #f "revoke error: ~a" e)))
                   #:promise? #t))))

      ((open identity-key kind domain id description franchise . rest)
       (cond
         ((not (governor? identity-key))
          (list 'error "governor credential required to open"))
         ;; an id already open (or already tallied) must not be silently
         ;; replaced — `record` is a bare hashmap-set, so re-opening
         ;; discarded a live ballot actor with every vote cast so far
         ;; (the stance ACDCs survived in the store, but the replacement
         ;; actor tallied none of them)
         (($ ballot-store 'get id)
          (list 'error (string-append "proposal already open: " id)))
         (($ ballot-store 'get-tally id)
          (list 'error (string-append "proposal already closed: " id)))
         (else
          (ensure-citizen identity-key)
          (open-proposal! kind domain id description franchise rest))))

      ;; ── contrary-observation doors: the vouch's three shapes, on a figure ──
      ;; preimage → the client signs the SAID with its own key → signed lands
      ;; it; the unsigned door is the fallback for a session with no resident
      ;; key. contrary-observations is the read: what stands against this
      ;; scope's map, with who saw it.
      ((observe-contrary-preimage identity-key scope-id process action spec nominal reading witness at)
       (%preimage (lambda () (build-contrary-observation identity-key scope-id process action spec nominal reading witness at))
                  #:refusal attest-refusal))

      ((observe-contrary-signed identity-key scope-id process action spec nominal reading witness at signature)
       (%signed! (lambda () (build-contrary-observation identity-key scope-id process action spec nominal reading witness at))
                 identity-key signature "observation"
                 #:before (lambda (_) (revoke-prior-contrary-observations! identity-key scope-id process action))
                 #:refusal attest-refusal))

      ((observe-contrary identity-key scope-id process action spec nominal reading witness)
       (catch #t
         (lambda ()
           (let ((c (build-contrary-observation identity-key scope-id process action spec nominal reading witness (current-time))))
             (revoke-prior-contrary-observations! identity-key scope-id process action)
             ($ acdc-store 'issue c)
             (list 'ok (cred-said c))))
         (lambda (k . a) (list 'error (attest-refusal a)))))

      ((contrary-observations identity-key scope-id)
       (cons 'ok (map (lambda (c)
                        (list (cred-issuer c) (cred-claim c 'process) (cred-claim c 'action) (cred-claim c 'spec)
                              (cred-claim c 'nominal) (cred-claim c 'reading) (cred-claim c 'witness)
                              (cred-claim c 'observed-at)))
                      (standing-contrary-observations acdc-store scope-id #f))))

      ;; ── contesting work: the record says it happened; a member says it did not ──
      ;; docs/playnet.typ §Matching's absence claim — "a labour-voice-weighted
      ;; decision to revoke accrued hours" — given its door. It opens a ballot in
      ;; the event's own scope: the franchise is that scope's roster by producer
      ;; voice THERE, the worker's own voice left out; the positions are `void`
      ;; and `stands`. The close every ballot has settles it (settle-contest!).
      ;; The criterion is the spec's — whether the person did the work; quality
      ;; is a planning question and has no door here. One contest per event.
      ((contest-work identity-key scope-id event-id reason)
       (catch #t
         (lambda ()
           (let* ((root   (scope-root scope-id))
                  (obs    (and root ($ root 'observer)))
                  (ev     (and obs ($ obs 'get-event event-id)))
                  (roster (scope-roster root))
                  (worker (and ev (economic-event-provider ev)))
                  ;; a count, or any part of one: the adjustment, its record,
                  ;; the counter's hours (planner/formulas/counting.scm)
                  (count? (and ev (count-event? ev)))
                  ;; one contest per count, whichever of its parts is named
                  (id     (contest-ballot-id event-id count?))
                  (why    (if (string? reason) reason "")))
             (cond
               ((not root) (list 'error "no such scope"))
               ((not ev) (list 'error "event not found"))
               ((not (or (eq? 'work (economic-event-action ev)) count?))
                (list 'error "only work and counts are contested"))
               ((not ($ obs 'event-standing? event-id)) (list 'error "this event has already been corrected"))
               ((not (member identity-key roster)) (list 'error "only a member of the scope may contest its work"))
               ((equal? identity-key worker) (list 'error "your own record is corrected, never contested"))
               (($ ballot-store 'get id) (list 'error "this work is already contested"))
               (($ ballot-store 'get-tally id) (list 'error "this work was contested and settled"))
               (else
                (for-each (lambda (aid) (ensure-citizen aid)) roster)
                (let* ((records (filter (lambda (r) (not (equal? (car r) worker)))
                                        (voice-data-snapshot)))
                       (data    (build-voice-snapshot records (list root))))
                  (open-proposal! 'ballot 'contest-work id
                                  (string-append "did " worker (if count? " count this as stated? " " do this work? ") why)
                                  (list 'scope scope-id)
                                  (list (string-append "event:" event-id))
                                  #:citizen-data data
                                  #:meta `((contest . ((scope-id . ,scope-id)
                                                       (kind . ,(if count? 'count 'work))
                                                       ;; the stock a count is of, for the counter's prompt
                                                       (resource . ,(and count? (count-event-of ev)))
                                                       (event-id . ,event-id)
                                                       (worker . ,worker)
                                                       (by . ,identity-key)
                                                       (reason . ,why))))))))))
         (lambda (_k . args) (list 'error (format #f "~a" args)))))

      ;; Legacy (unsigned) cast — the sealer path, kept for clients with no
      ;; signing key. A stance is CITIZEN-issued; the citizen cannot sign
      ;; server-side, so the durable ACDC is issued UNSIGNED (an honest unsigned
      ;; assertion). It must NOT be scope-signed: a scope signature would not
      ;; verify against the citizen issuer — worse than none. The conformant
      ;; path is `cast-signed`.
      ((cast identity-key id arg)
       (let ((event ($ ballot-store 'get id)))
         (cond
           ((not event) (list 'error "no such open event" id))
           (else
            (call-with-values
              (lambda () (ensure-citizen identity-key))
              (lambda (voice _s _dm)
                (catch #t
                  (lambda ()
                    (let ((kind   ($ event 'kind))
                          (domain ($ event 'domain)))
                      (case kind
                        ((ballot)     ($ event 'cast identity-key ($ voice 'stance id arg)))
                        ((expression) ($ event 'cast identity-key
                                         ($ voice 'stance-expression domain id arg))))
                      (when acdc-store
                        (case kind
                          ((ballot)
                           ($ acdc-store 'issue
                              (make-stance-credential
                               identity-key (recorder-aid) domain id arg (current-time)
                               #:ballot-snapshot-said (hashmap-ref snapshot-saids id #f))))
                          ((expression)
                           ;; arg is a live goblins hashmap — fold it to a
                           ;; key-sorted alist BEFORE it becomes SAID
                           ;; material. Hashing the hashmap itself went
                           ;; through its truncating printer (10 pairs, then
                           ;; "..."), so two DIFFERENT large distributions
                           ;; could collide into one SAID, and the durable
                           ;; store wrote an unreplayable #<hashmap …> form.
                           ;; canonical-string now refuses such objects
                           ;; loudly (said-portable.scm), so this fold is
                           ;; what makes the mint succeed at all.
                           ($ acdc-store 'issue
                              (make-expression-stance-credential
                               identity-key (recorder-aid) domain id
                               (distribution->alist arg) (current-time))))))
                      'ok))
                  (lambda (key . args)
                    (list 'error (format #f "cast failed: ~a ~a" key args))))))))))

      ;; --- Client-side citizen signing (the conformant stance path) ---
      ;;
      ;; A stance is the CITIZEN's assertion, so for it to be a conformant ACDC
      ;; the citizen's own controller must sign it — and their key is
      ;; client-side. Uses the generic protocol (see credentials.scm):
      ;;   stance-preimage → the exact credential's SAID fields; the client
      ;;   re-derives the SAID (compute-said, shared via keri/said-portable) and
      ;;   signs it; cast-signed rebuilds identically and accepts iff the
      ;;   signature verifies against the caller AID.
      ;;
      ;; The client provides its position up front, so the server builds the WHOLE
      ;; credential and hands back its SAID fields — no ballot-specific preimage
      ;; shape. Timestamp is server-issued (the Hoot client is clock-free) and
      ;; echoed back; the SAID commits to it, and an identical replay collapses
      ;; under issue-idempotent.
      ((stance-preimage identity-key id position)
       (let ((event ($ ballot-store 'get id)))
         (cond
           ((not event) (list 'error "no such open event" id))
           (else
            (list 'ok
                  (credential-preimage-fields
                   (make-stance-credential
                    identity-key (recorder-aid)
                    ($ event 'domain) id position (current-time)
                    #:ballot-snapshot-said (hashmap-ref snapshot-saids id #f))))))))

      ;; U is the blinding nonce the client signed over, echoed back from the
      ;; preimage's claims alongside TIMESTAMP. Both are server-issued and
      ;; SAID-committed, so the rebuild below MUST use the client's values or
      ;; the signature cannot verify.
      ;;
      ;; The trailing arg is variadic only so a five-arg call is a clean
      ;; rejection rather than an arity crash — see the explicit guard below.
      ;; DEPLOY ORDER: the browser wasm (day-boot.scm) and this service must
      ;; ship together; a stale service-worker-cached client will be told to
      ;; refresh rather than silently failing to vote.
      ;; The trailing tail is `(U)` from a direct/test caller, or `(U VERIFY-KEY)`
      ;; from the lobby session. VERIFY-KEY is the caller's CURRENT signing key,
      ;; which the session resolved from the KEL (^oobi-host, in its own vat): a
      ;; transferable E-prefix AID does NOT encode its key in the prefix — the
      ;; latest rotation's k[0] does — so a stance signature must be checked
      ;; against the resolved key, not the AID. A non-transferable D/B-prefix AID
      ;; (tests, direct calls) supplies no key and we fall back to the AID, which
      ;; IS the key. This mirrors ^lobby's keri-authenticate resolution.
      ((cast-signed identity-key id position timestamp signature . opt)
       (let ((event ($ ballot-store 'get id))
             (u     (if (pair? opt) (car opt) #f))
             (vkey  (if (and (pair? opt) (pair? (cdr opt)) (string? (cadr opt)))
                        (cadr opt) identity-key)))
         (cond
           ((not event) (list 'error "no such open event" id))
           ((not u)
            (list 'error
                  "stance nonce (u) missing — echo it from the preimage claims; \
a stale client bundle needs a refresh"))
           (else
            (call-with-values
              (lambda () (ensure-citizen identity-key))
              (lambda (voice _s _dm)
                (catch #t
                  (lambda ()
                    (let ((cred (make-stance-credential
                                 identity-key (recorder-aid)
                                 ($ event 'domain) id position timestamp
                                 #:u u
                                 #:ballot-snapshot-said
                                 (hashmap-ref snapshot-saids id #f))))
                      (cond
                        ((not (client-signature-ok? cred vkey signature))
                         (list 'error
                               "stance signature does not verify against caller AID"))
                        (else
                         ;; ONE signature, both consumers: the live tally and the
                         ;; durable ACDC verify the SAME citizen signature over the
                         ;; SAME SAID. The ballot's unified verifier takes the
                         ;; (said sig . vkey) proof and checks it against the
                         ;; resolved key (falling back to the AID when vkey is the
                         ;; AID) — no sealer, no need for the citizen to be in the
                         ;; frozen registry.
                         (let ((cleartext (list 'stance id position
                                                identity-key identity-key)))
                           ($ event 'cast identity-key
                              (cons cleartext
                                    (cons (cred-said cred) (cons signature vkey)))))
                         (when acdc-store
                           ($ acdc-store 'issue-idempotent
                              (cred-with-signature cred signature)))
                         'ok))))
                  (lambda (key . args)
                    (list 'error
                          (format #f "cast-signed failed: ~a ~a" key args))))))))))

      ;; ── Producer voice over the plan: a HAND of signed stances on PARTS ──────
      ;; docs/planning/voice/voice-over-the-plan.md "The warp, and the
      ;; conversation": a stance is signed as an expression-stance credential
      ;; with domain plan-part, its targets the parts in VF terms
      ;; (parts.scm part->string), its values SIGNED in [−1, 1] — dislike to
      ;; like. No expression is opened: the hand stands on the scope's rail
      ;; under expression-id "plan-part:<scope>", the newest non-revoked
      ;; credential per citizen is their standing hand (a cast revokes the
      ;; previous one), and the planner's voice fold reads the rows through
      ;; `plan-part-hands`. The client signs, as for cast-signed: the preimage
      ;; hands back the SAID fields, the signed leg rebuilds the identical
      ;; credential and accepts iff the signature verifies. HAND is an alist
      ;; ((part-string . portion) …) — checked by parts.scm validate-hand,
      ;; never by validate-distribution (that is the ballot tally's rule, and
      ;; a hand is signed where a distribution is not).
      ((part-stance-preimage identity-key scope-id hand)
       (catch #t
         (lambda ()
           (validate-hand hand)
           (list 'ok (credential-preimage-fields
                      (make-expression-stance-credential
                       identity-key (recorder-aid) "plan-part"
                       (string-append "plan-part:" scope-id)
                       (distribution->alist hand) (current-time)))))
         (lambda (key . args) (list 'error (format #f "part-stance-preimage failed: ~a ~a" key args)))))
      ((cast-part-signed identity-key scope-id hand timestamp signature . opt)
       (let ((u    (if (pair? opt) (car opt) #f))
             (vkey (if (and (pair? opt) (pair? (cdr opt)) (string? (cadr opt))) (cadr opt) identity-key)))
         (cond
           ((not u) (list 'error "stance nonce (u) missing — echo it from the preimage claims"))
           ((not acdc-store) (list 'error "no credential store: a hand needs a rail to stand on"))
           (else
            (catch #t
              (lambda ()
                (validate-hand hand)
                (let ((cred (make-expression-stance-credential
                             identity-key (recorder-aid) "plan-part"
                             (string-append "plan-part:" scope-id)
                             (distribution->alist hand) timestamp #:u u)))
                  (cond
                    ((not (client-signature-ok? cred vkey signature))
                     (list 'error "stance signature does not verify against caller AID"))
                    (else
                     ;; the previous hand steps down: stances stand until changed
                     (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c)))
                               (standing-part-hands acdc-store scope-id identity-key))
                     ($ acdc-store 'issue-idempotent (cred-with-signature cred signature))
                     'ok))))
              (lambda (key . args) (list 'error (format #f "cast-part-signed failed: ~a ~a" key args))))))))
      ;; the standing hands on SCOPE-ID's rail, as rows ((owner part-string portion) …):
      ;; what the planner's voice fold takes (planner service `hands!`)
      ((plan-part-hands scope-id) (plan-part-hands-of acdc-store scope-id))

      ;; ── A scope's own word: three self-declarations on the rail ─────────
      ;; A span (where a resource's pool stands), hosting willingness (what a
      ;; scope will host, with a ceiling) and a regime claim (whether a
      ;; domain's statistics are licensed) are performatives issuer = holder
      ;; = the scope, spoken for it by a governor — the gate issue-credential
      ;; holds. Each is read where it lies (socialization consented-span-of,
      ;; live-willingness-of; recipe-standing live-regime-of): a lapsed or
      ;; revoked one stops contributing, with no further event. Replies
      ;; (ok said) or an error.
      ((declare-span identity-key scope-aid resource-id place . opt)
       (%scope-declare! identity-key
                        (lambda () (make-span-declaration-credential
                                    scope-aid resource-id place
                                    #:valid-until (and (pair? opt) (car opt))))))
      ((declare-hosting identity-key scope-aid resource-spec ceiling . opt)
       (%scope-declare! identity-key
                        (lambda () (make-hosting-willingness-credential
                                    scope-aid resource-spec (exact->inexact ceiling)
                                    #:valid-until (and (pair? opt) (car opt))))))
      ((claim-regime identity-key scope-aid domain-spec tails process . opt)
       (%scope-declare! identity-key
                        (lambda () (make-regime-claim-credential
                                    scope-aid domain-spec (%as-symbol tails) (%as-symbol process)
                                    #:valid-until (and (pair? opt) (car opt))))))

      ;; ── A federation admits a commune ────────────────────────────────────────
      ;; The federation's act, spoken by a governor of this gateway (the gate
      ;; every admin door here holds) and then by the scope's own ladder: the
      ;; federation mints the governor its gov-cap only if it recognises them
      ;; (scope.scm may-govern?), and its governance-policy may require the
      ;; commune's consent as a ratification (RATIFICATION, a SAID, optional).
      ;; The commune enters under its AID with the sturdyref its peer answers
      ;; at; what crosses it is the commune's to tell (a census), not the
      ;; admission's. Replies ok or an error.
      ((admit-commune identity-key federation-aid commune-aid sturdyref-uri . opt)
       (cond
         ((not (governor? identity-key)) (list 'error "a federation admits a commune through a governor"))
         (else
          (let ((fed (scope-for federation-aid)))
            (if (not fed)
                (list 'error "this gateway holds no federation by that AID")
                (on (<- fed 'mint-gov-cap identity-key)
                    (lambda (cap)
                      (on (apply <- fed 'admit-commune-remote cap commune-aid commune-aid sturdyref-uri
                                 (if (and (pair? opt) (car opt)) (list 'ratification (car opt)) '()))
                          (lambda (_) 'ok)
                          #:catch (lambda (e) (list 'error (format #f "admit-commune: ~a" e)))
                          #:promise? #t))
                    #:catch (lambda (e) (list 'error (format #f "admit-commune: ~a" e)))
                    #:promise? #t))))))

      ;; ── Temporary socialization — client-signed custody attestation ─────────
      ;; The owner (caller = IDENTITY-KEY) lends QTY of RESOURCE-SPEC into
      ;; COMMUNE-AID's use-pool until UNTIL. The custody-attestation's ISSUER is
      ;; the owner, so it must carry the OWNER's signature — the browser signs it
      ;; (the key never leaves the client). valid-from is left open, so the
      ;; credential is fully determined by these args and `socialize-preimage` /
      ;; `socialize-signed` rebuild the identical SAID with nothing to echo (the
      ;; twin of stance-preimage / cast-signed above). UNTIL/RT/CF/RES are strings
      ;; ("" = absent); MOVABLE is a boolean. KIND is "use" (lend the service,
      ;; "" reads as use) or "consume" (lend a quantity to SPEND — money, fuel)
      ;; — see socialization.scm grant-kind-claim.
      ;; REF ("" = none): a caller nonce folded into the grant's SAID so
      ;; recall-then-relend with identical terms mints a fresh credential
      ;; instead of colliding with the revoked one (issue-client-signed!
      ;; now refuses that collision loudly rather than lying 'ok).
      ;; ELIGIBLE ("" = anyone): the owner's steward rule — the slot criteria
      ;; JSON the dial already writes, whose filter-rule bounds who may be
      ;; assigned to work drawing on the grant (socialization.scm, the
      ;; steward gate). Echoed verbatim across both legs like every term.
      ((socialize-preimage identity-key commune-aid spec qty until movable rt cf res kind ref #:optional (eligible #f))
       (%preimage (lambda () (socialization-credential identity-key commune-aid spec qty
                               #:until until #:movable? movable #:return-to rt
                               #:condition-floor cf #:resource res #:kind kind #:ref ref
                               #:eligible eligible))))

      ((socialize-signed identity-key commune-aid spec qty until movable rt cf res kind ref signature #:optional (eligible #f))
       (%signed! (lambda () (socialization-credential identity-key commune-aid spec qty
                              #:until until #:movable? movable #:return-to rt
                              #:condition-floor cf #:resource res #:kind kind #:ref ref
                              #:eligible eligible))
                 identity-key signature "socialize"
                 ;; the title gate: a grant naming an exact resource must be the
                 ;; TITLED owner's to make, once any title over it has been spoken
                 ;; (title-permits? — silence keeps the field-only world)
                 #:gate (lambda (_) (title-permits? acdc-store identity-key
                                                    (and (string? res) (not (string-null? res)) res)))
                 #:gate-refusal "a standing title over that resource names another owner"))

      ;; ── Purchase claims — client-signed, the reimbursement trigger ──────────
      ;; The member (caller = IDENTITY-KEY) asserts "I gave the commons QTY of
      ;; SPEC" — the exact twin of socialize-preimage/-signed: the claim's
      ;; ISSUER is the member, so it must carry the MEMBER's signature (the
      ;; browser signs, the key never leaves the client). accept-reimbursement
      ;; (governance/scope.scm, below) mints the commune's debt with
      ;; triggered-by = this claim's SAID, never fabricating the claim itself.
      ;; RES ("" = unnamed) names WHICH resource paid — resourceInventoriedAs,
      ;; the precise funding-source check. REF ("" = none) is the member's own
      ;; receipt/reference, folded into the claim id so two same-shaped
      ;; purchases (same spec, amount and due) are two claims with two SAIDs,
      ;; not one that silently dedupes the second.
      ;; TRIG ("" = none): the purchase EVENT's id (record-purchase returns
      ;; it) — rides the claim as VF Claim.triggeredBy, tying the signed
      ;; word to the recorded raise it speaks about.
      ((purchase-claim-preimage identity-key commune-aid spec qty unit due res ref trig)
       (%preimage (lambda () (build-purchase-claim identity-key commune-aid spec qty unit due res ref trig))
                  #:refusal (lambda (a) (format #f "purchase-claim: ~a" a))))

      ((purchase-claim-signed identity-key commune-aid spec qty unit due res ref trig signature)
       (%signed! (lambda () (build-purchase-claim identity-key commune-aid spec qty unit due res ref trig))
                 identity-key signature "purchase-claim"))

      ;; ── Accepting a grant or a reimbursement — the commune's own word ───────
      ;; Both accept-socialization and accept-reimbursement (governance/scope.scm)
      ;; are gov-cap-gated ^scope methods, scoped to this gateway's single
      ;; HOME-SCOPE commune (there is no commune-aid → ^scope resolver for an
      ;; arbitrary federation member yet — a real, separate gap; COMMUNE-AID
      ;; is still required and checked, so a caller can never silently target
      ;; the wrong commune, only be refused for a right one this service
      ;; cannot reach).
      ;;
      ;; WHICH commune's key acts: scope-for (the scope graph, or home-scope
      ;; when it is that commune; a commune this process cannot reach is
      ;; refused by name, never silently redirected). WHO may ask it to:
      ;; mint-gov-cap's own concern (governance/scope.scm's may-govern?) —
      ;; refuses IDENTITY-KEY outright when this commune has recognised
      ;; anyone and IDENTITY-KEY isn't one of them. The one further guard
      ;; enforced here: a member can never accept their OWN reimbursement
      ;; claim (self-payout refused outright).
      ;; . opts (kw-ref): 'ratification SAID — a `close`-minted
      ;; recomposition-ratification (kind='ballot #:ratify), spliced
      ;; straight through as ^scope's own 'ratification opt
      ;; (require-ratification!). Absent, this commune's may-govern? alone
      ;; decides, exactly as before.
      ((accept-socialization identity-key commune-aid grant-said . opts)
       (let ((sc (scope-for commune-aid))
             (ratification-said (kw-ref opts 'ratification #f)))
         (if (not sc)
             (list 'error "accept-socialization: no scope reachable here for that commune")
             (catch #t
               (lambda ()
                 (list 'ok (apply $ sc 'accept-socialization
                             ($ sc 'mint-gov-cap identity-key) grant-said
                             (if ratification-said (list 'ratification ratification-said) '()))))
               (lambda (key . args) (list 'error (format #f "accept-socialization failed: ~a" args)))))))

      ((accept-reimbursement identity-key commune-aid claim-said . opts)
       (let ((sc (scope-for commune-aid))
             (ratification-said (kw-ref opts 'ratification #f)))
         (if (not sc)
             (list 'error "accept-reimbursement: no scope reachable here for that commune")
             (catch #t
               (lambda ()
                 (let* ((claim (and acdc-store ($ acdc-store 'get claim-said))))
                   (when (and claim (equal? identity-key (cred-issuer claim)))
                     (error "cannot accept your own reimbursement claim" claim-said))
                   (let ((r (apply $ sc 'accept-reimbursement
                              ($ sc 'mint-gov-cap identity-key) claim-said
                              (if ratification-said (list 'ratification ratification-said) '()))))
                     (list 'ok (car r) (cadr r)))))
               (lambda (key . args) (list 'error (format #f "accept-reimbursement failed: ~a" args)))))))

      ;; ── Ownership — client-signed title attestation ─────────────────────────
      ;; The caller asserts title over ONE resource (rid, spec). Issuer = holder
      ;; = the owner, so the browser signs (the key never leaves the client) —
      ;; the exact twin of socialize-preimage / socialize-signed. A title makes
      ;; the self-assertion declare-means records non-repudiable and contestable;
      ;; the socialization gates and the auditor read it (ownership-ok?).
      ;; REF ("" = none): lets a disowned title be re-asserted — identical
      ;; terms otherwise rebuild the revoked SAID and issue-client-signed!
      ;; refuses the collision loudly.
      ((own-means-preimage identity-key resource-id spec qty qty-unit ref)
       (%preimage (lambda () (ownership-credential identity-key resource-id spec #:qty qty #:qty-unit qty-unit #:ref ref))))

      ((own-means-signed identity-key resource-id spec qty qty-unit ref signature)
       (%signed! (lambda () (ownership-credential identity-key resource-id spec #:qty qty #:qty-unit qty-unit #:ref ref))
                 identity-key signature "ownership"))

      ;; the caller's own live titles: (said resource-id spec kind)
      ((my-titles identity-key)
       (if (not acdc-store) (list 'ok '())
           (list 'ok
                 (map (lambda (c)
                        (list (cred-said c) (cred-claim c 'resource-id)
                              (cred-claim c 'resource-spec)
                              (or (cred-claim c 'kind) "declared")))
                      (filter (lambda (c) (equal? identity-key (cred-issuer c)))
                              (%live-ownership-attestations acdc-store))))))

      ;; withdrawing a title — issuer-owned revocation, desocialize's twin
      ;; (both are revoke-own-credential!, stated once in socialization.scm)
      ((disown-means identity-key said)
       (if (not acdc-store) (list 'error "no credential store")
           (catch #t
             (lambda ()
               (list 'ok (withdraw-title! acdc-store identity-key said)))
             (lambda (key . args) (list 'error (format #f "disown failed: ~a" args))))))

      ;; the caller's own live grants, for the ledger:
      ;; (said spec holder until qty kind eligible)
      ((my-grants identity-key)
       (if (not acdc-store) (list 'ok '())
           (list 'ok
                 (map (lambda (c)
                        (list (cred-said c) (cred-claim c 'resource-spec) (cred-holder c)
                              (or (cred-claim c 'valid-until) "") (cred-claim c 'qty)
                              (if (grant-consume? c) "consume" "use")
                              (or (cred-claim c 'eligible) "")))
                      (filter (lambda (c) (equal? identity-key (cred-issuer c)))
                              (%live-custody-attestations acdc-store #f))))))

      ;; owner recalls a grant early — no signature; the store-side revoke is gated
      ;; by the issuer==owner check inside desocialize-private-resource!.
      ((desocialize identity-key said)
       (if (not acdc-store) (list 'error "no credential store")
           (catch #t
             (lambda () (list 'ok (desocialize-private-resource! acdc-store identity-key said)))
             (lambda (key . args) (list 'error (format #f "recall failed: ~a" args))))))

      ;; opts (kw-ref): 'ratify (cons proposal-type proposal-spec) — mint a
      ;; recomposition-ratification credential from THIS close's own tally,
      ;; self-issued by (recorder-aid), the same generic shape
      ;; make-recomposition-ratification-credential already uses for
      ;; admit-commune/merge-with/split (credentials.scm). Read right here,
      ;; not as a separate step: snap-said/entries/winner exist in this one
      ;; place, and snapshot-saids is freed at the end of this same call —
      ;; a caller that wanted to ratify AFTER close would find nothing left
      ;; to point the ballot-snapshot edge at. Returns (ok id) normally, or
      ;; (ok id ratification-said) when 'ratify was requested and the
      ;; threshold was met — accept-socialization/accept-reimbursement take
      ;; that SAID straight as their own 'ratification opt.
      ((close identity-key id . opts)
       (cond
         ((not (governor? identity-key))
          (list 'error "governor credential required to close"))
         (else
          (let ((event ($ ballot-store 'get id)))
            (cond
              ((not event) (list 'error "no such open event" id))
              (else
               (let ((kind   ($ event 'kind))
                     (domain ($ event 'domain))
                     (ratify (kw-ref opts 'ratify #f)))
                 ($ event 'close)
                 (case kind
                   ((ballot)
                    (let* ((tally-result ($ event 'tally))
                           (tally-map  (assoc-ref tally-result 'tally))
                           (abstain    (assoc-ref tally-result 'abstain))
                           (now        (current-time))
                           (ratification-said #f))
                      ($ ballot-store 'record-tally id tally-map abstain now)
                      ($ ballot-store 'forget id)
                      (settle-contest! id tally-map abstain)
                      (when acdc-store
                        (let* ((entries
                                (hashmap-fold
                                  (lambda (k v acc) (cons (cons k v) acc))
                                  '() tally-map))
                               (winner
                                (and (pair? entries)
                                     (caar (sort entries
                                                 (lambda (a b) (> (cdr a) (cdr b)))))))
                               (snap-said (hashmap-ref snapshot-saids id #f))
                               (tally-cred
                                (sign-as-recorder
                                 (make-tally-result-credential
                                  (recorder-aid) domain id 'federation
                                  ;; the folded, key-sorted entries — never
                                  ;; the raw hashmap, whose printer truncates
                                  ;; past 10 pairs (a lossy "auditable proof")
                                  ;; and which canonical-string now refuses
                                  winner (canonical-string (said-sort-pairs entries))
                                  abstain now
                                  ;; §4.9: edge to ballot-snapshot.
                                  #:ballot-snapshot-said snap-said))))
                          ($ acdc-store 'issue tally-cred)
                          ;; §4.6: anchor tally-result in the home
                          ;; scope's KEL via an ixn event.
                          (when (and home-scope
                                     ($ home-scope 'has-keypair?))
                            (catch #t
                              (lambda ()
                                ($ home-scope 'anchor-acdc
                                   (cred-said tally-cred)))
                              (lambda _ #f)))
                          (when ratify
                            (let* ((proposal-type (car ratify))
                                   (proposal-spec (cdr ratify))
                                   (threshold-met? (and winner (carries? (assoc-ref entries winner) entries abstain))))
                              (when threshold-met?
                                (let ((rat (sign-as-recorder
                                            (make-recomposition-ratification-credential
                                             (recorder-aid) proposal-type proposal-spec
                                             snap-said entries #:threshold-met? #t))))
                                  ($ acdc-store 'issue rat)
                                  (set! ratification-said (cred-said rat))))))
                          ;; Free the proposal-id from the snapshot map
                          ;; once we no longer need to look it up.
                          (set! snapshot-saids
                                (hashmap-remove snapshot-saids id))))
                      (if ratification-said
                          (list 'ok id ratification-said)
                          (list 'ok id))))
                   ((expression)
                    ($ ballot-store 'forget id)
                    (list 'ok id))))))))))

      ((get-result id)
       ;; Public read. Returns:
       ;;   (closed . tally-record)        — for closed ballots (recorded)
       ;;   (open   . live-result-alist)   — for open ballots/expressions
       ;;   (error …)                      — for unknown ids
       (let ((rec  ($ ballot-store 'get-tally id))
             (meta ($ ballot-store 'meta id)))
         (cond
           (rec (cons 'closed (append rec meta)))
           (else
            (let ((event ($ ballot-store 'get id)))
              (cond
                ((not event) (list 'error "unknown id" id))
                (else
                 ;; Carry the proposal's CLASS metadata (kind + domain) so the
                 ;; dial can sort it into production vs consumption governance
                 ;; (governance-surface.md — the two classes, two voices).
                 (cons 'open
                       (append
                        (case ($ event 'kind)
                          ((ballot)     ($ event 'tally))
                          ((expression) ($ event 'result)))
                        ;; the registry's meta: kind, domain, the question
                        ;; itself, franchise, opened-at, subject
                        meta)))))))))

      ((list-proposals)
       ($ ballot-store 'list-proposals))))))


(define* (spawn-governance-service scope-roots ballot-store
                                   #:key
                                   (governor? (lambda (_aid) #t))
                                   (acdc-store #f)
                                   (home-scope #f)
                                   (scope-of #f)
                                   (scope-root-of #f)
                                   (kel-landing #f)
                                   (kel-of #f))
  "Spawn a ^governance-service holding refs to the federation's
   scope-roots and the primary ballot-store. Must be called within
   the same vat as the scope-root that owns the ballot-store.

   governor?: AID predicate gating ballot/expression open/close (admin
   actions). Production callers pass a founders-list membership check
   (server/gateway.scm); the default always-true predicate is for tests.
   There is no membership gate on voice — voice rides on labor evidence
   in the snapshot, not on credentials.

   acdc-store: ^acdc-store or ^keria-acdc-store ref. When provided,
   delegation mutations emit ACDC credentials. #f disables emission.

   home-scope: optional ^scope ref. When supplied, ballot opens and
   tally closes call ($ home-scope 'anchor-acdc said) so the SAIDs
   land in the scope's KEL via interaction events (democracy-on-keri
   §4.6). When #f, only the legacy acdc-store path emits credentials.

   scope-of: optional (commune-aid → ^scope or #f). A commune's OWN acts —
   accepting a grant or a reimbursement, issuing a personhood into its
   ecosystem, opening a ceremony — resolve the commune they name through
   it (the gateway hands the scope graph's find-ref, cached). home-scope
   answers only for the commune it is; without scope-of, that is the one
   commune this service can act for."
  (let ((svc (spawn ^governance-service scope-roots ballot-store
                    governor? acdc-store home-scope scope-of kel-landing kel-of)))
    (when scope-root-of ($ svc 'set-scope-root-of! scope-root-of))
    svc))


(define governance-service-env
  (make-persistence-env
    `((((playnet governance) ^governance-service) ,^governance-service))))
