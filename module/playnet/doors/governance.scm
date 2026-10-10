;;; module/playnet/doors/governance.scm — the governance service: the gateway's one
;;; handle on voice, personhood, delegation, contests, the economy's doors and the
;;; federation's, composed from six fragments.
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
;;; The doors are written in six fragments of doors/ (docs/planning/codebase-layout.md
;;; §5): personhood, delegation, voice, contests, economy, federation. Each is a
;;; procedure from the actor's context — its arguments, its mutable cells and the
;;; helpers more than one group reads — to a declared-doors value; `with-governance-ctx`
;;; binds every field under the name the clauses were written with, a `set!` writing the
;;; field, so each clause reads as it did inside the actor. This module imports none
;;; of the fragments: the composition root (playnet boot governance) sets the list once
;;; per process.

(define-module (playnet doors governance)
  #:use-module ((playnet wire replies) #:select (finishing))
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials registry)
  #:use-module (playnet credentials voting)
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module ((playnet observation adjustment) #:select (count-event? count-event-of))
  #:use-module ((playnet vf formulas counting) #:select (count-base-id count-family-id? contest-ballot-id))
  #:use-module ((playnet keri acdc-store) #:select (non-revoked-by-schema))
  #:use-module (playnet voice snapshot)
  #:use-module (playnet keri said-portable)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet vf schemas)
  #:use-module (playnet voice delegation-map)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet voice ballot)
  #:use-module (playnet voice expression)
  #:use-module (playnet federation rebuild)
  #:use-module (playnet voice voice-signer)
  #:use-module ((playnet personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet protocol dispatch) #:select (compose-doors))
  #:export (fp-wire->cred ^governance-service spawn-governance-service
            governance-service-env plan-part-hands-of contrary-observations-of contrary-readings-of
            governance-fragments set-governance-fragments!
            make-governance-ctx governance-ctx? with-governance-ctx
            governance-ctx-scope-roots governance-ctx-ballot-store governance-ctx-governor? governance-ctx-acdc-store governance-ctx-home-scope governance-ctx-scope-of governance-ctx-kel-landing governance-ctx-kel-of governance-ctx-voices governance-ctx-sealed?-of governance-ctx-delegations governance-ctx-scope-root-of governance-ctx-contest-settled governance-ctx-snapshot-saids governance-ctx-fp-trusted-issuers governance-ctx-fp-root-aid governance-ctx-fp-strict-root? governance-ctx-uc-proposals-ref governance-ctx-%preimage governance-ctx-%signed! governance-ctx-ensure-citizen governance-ctx-voice-data-snapshot governance-ctx-recorder-aid governance-ctx-sign-as-recorder governance-ctx-open-proposal! governance-ctx-contest-family governance-ctx-scope-root governance-ctx-scope-observer governance-ctx-scope-for governance-ctx-revoke-where!
            set-governance-ctx-scope-roots! set-governance-ctx-ballot-store! set-governance-ctx-governor?! set-governance-ctx-acdc-store! set-governance-ctx-home-scope! set-governance-ctx-scope-of! set-governance-ctx-kel-landing! set-governance-ctx-kel-of! set-governance-ctx-voices! set-governance-ctx-sealed?-of! set-governance-ctx-delegations! set-governance-ctx-scope-root-of! set-governance-ctx-contest-settled! set-governance-ctx-snapshot-saids! set-governance-ctx-fp-trusted-issuers! set-governance-ctx-fp-root-aid! set-governance-ctx-fp-strict-root?! set-governance-ctx-uc-proposals-ref! set-governance-ctx-%preimage! set-governance-ctx-%signed!! set-governance-ctx-ensure-citizen! set-governance-ctx-voice-data-snapshot! set-governance-ctx-recorder-aid! set-governance-ctx-sign-as-recorder! set-governance-ctx-open-proposal!! set-governance-ctx-contest-family! set-governance-ctx-scope-root! set-governance-ctx-scope-observer! set-governance-ctx-scope-for! set-governance-ctx-revoke-where!!
            ;; the store readers and folds the fragments share
            standing-part-hands standing-contrary-observations distribution->alist %sponsor-fanout-ok? %as-symbol))


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
            ((equal? schema *schema-playnet-body-role*) '(role))
            ((equal? schema *schema-playnet-body*) '(kind))
            (else '()))))
  (define (claim-value k v)
    (cond ((and (memq k symbol-claims) (string? v)) (string->symbol v))
          ;; the body's registry identifiers: an alist keyed by scheme symbol
          ((and (eq? k 'legal-ids) (pair? v))
           (map (lambda (p) (cons (s->sym (car p)) (cdr p))) v))
          (else v)))
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

;;; ── the context a fragment reads ─────────────────────────────────────────────
;;;
;;; The actor's arguments, its mutable cells and the helpers more than one group
;;; reads, as one record a fragment is handed. The cells:
;;;   voices — (hashmap)
;;;   sealed?-of — (hashmap)
;;;   delegations — (hashmap)
;;; scope-id → the commune's planner root, for per-scope voice (voice-in)
;;;   scope-root-of — #f
;;; ballot-id → (): told when a contest ballot has settled, so what the
;;; gateway holds for it (a counter's picture) can be let go
;;;   contest-settled — #f
;;; Per-proposal snapshot SAIDs, recorded at 'open and retrieved
;;; at 'cast / 'close so stance and tally-result ACDCs can carry
;;; the §4.9 ballot-snapshot edge.
;;;   snapshot-saids — (hashmap)
;;; First-Person: commune AIDs whose PHCs we honour when PRESENTED by a
;;; holder from another gateway (set by the gateway to the UC's members).
;;;   fp-trusted-issuers — '()
;;; First-Person: the trust-registry root AID (the Universal Commune's
;;; group AID). When set, an ecosystem is a legitimate PHC issuer iff it
;;; chains to root (holds a live authorized-issuer credential), making
;;; `fp-trusted-issuers` a fallback rather than the sole source of trust.
;;;   fp-root-aid — #f
;;; First-Person: when #t, the flat `fp-trusted-issuers` whitelist is
;;; DROPPED — trust derives only from chaining to root. Flip this once
;;; the live root chain is populated (ecosystems blessed), so the
;;; hand-maintained bypass no longer undermines the verifiable chain.
;;;   fp-strict-root? — #f
;;; Cross-gateway UC merge-proposal registry (^uc-merge-proposals), set
;;; by the gateway once both are spawned, so the governance surface can
;;; show collisions as scope-formation decisions.
;;;   uc-proposals-ref — #f

(define-record-type <governance-ctx>
  (make-governance-ctx scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref %preimage %signed! ensure-citizen voice-data-snapshot recorder-aid sign-as-recorder open-proposal! contest-family scope-root scope-observer scope-for revoke-where!)
  governance-ctx?
  (scope-roots governance-ctx-scope-roots set-governance-ctx-scope-roots!)
  (ballot-store governance-ctx-ballot-store set-governance-ctx-ballot-store!)
  (governor? governance-ctx-governor? set-governance-ctx-governor?!)
  (acdc-store governance-ctx-acdc-store set-governance-ctx-acdc-store!)
  (home-scope governance-ctx-home-scope set-governance-ctx-home-scope!)
  (scope-of governance-ctx-scope-of set-governance-ctx-scope-of!)
  (kel-landing governance-ctx-kel-landing set-governance-ctx-kel-landing!)
  (kel-of governance-ctx-kel-of set-governance-ctx-kel-of!)
  (voices governance-ctx-voices set-governance-ctx-voices!)
  (sealed?-of governance-ctx-sealed?-of set-governance-ctx-sealed?-of!)
  (delegations governance-ctx-delegations set-governance-ctx-delegations!)
  (scope-root-of governance-ctx-scope-root-of set-governance-ctx-scope-root-of!)
  (contest-settled governance-ctx-contest-settled set-governance-ctx-contest-settled!)
  (snapshot-saids governance-ctx-snapshot-saids set-governance-ctx-snapshot-saids!)
  (fp-trusted-issuers governance-ctx-fp-trusted-issuers set-governance-ctx-fp-trusted-issuers!)
  (fp-root-aid governance-ctx-fp-root-aid set-governance-ctx-fp-root-aid!)
  (fp-strict-root? governance-ctx-fp-strict-root? set-governance-ctx-fp-strict-root?!)
  (uc-proposals-ref governance-ctx-uc-proposals-ref set-governance-ctx-uc-proposals-ref!)
  (%preimage governance-ctx-%preimage set-governance-ctx-%preimage!)
  (%signed! governance-ctx-%signed! set-governance-ctx-%signed!!)
  (ensure-citizen governance-ctx-ensure-citizen set-governance-ctx-ensure-citizen!)
  (voice-data-snapshot governance-ctx-voice-data-snapshot set-governance-ctx-voice-data-snapshot!)
  (recorder-aid governance-ctx-recorder-aid set-governance-ctx-recorder-aid!)
  (sign-as-recorder governance-ctx-sign-as-recorder set-governance-ctx-sign-as-recorder!)
  (open-proposal! governance-ctx-open-proposal! set-governance-ctx-open-proposal!!)
  (contest-family governance-ctx-contest-family set-governance-ctx-contest-family!)
  (scope-root governance-ctx-scope-root set-governance-ctx-scope-root!)
  (scope-observer governance-ctx-scope-observer set-governance-ctx-scope-observer!)
  (scope-for governance-ctx-scope-for set-governance-ctx-scope-for!)
  (revoke-where! governance-ctx-revoke-where! set-governance-ctx-revoke-where!!))

;; the arguments and the cells: what the actor's own helpers read and write
(define-syntax with-governance-state
  (lambda (x)
    (syntax-case x ()
      ((_ ctx body ...)
       (with-syntax (((name ...) (map (lambda (n) (datum->syntax x n)) '(scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref)))
                     ((ref ...) (map (lambda (n) (datum->syntax x (symbol-append 'governance-ctx- n))) '(scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref)))
                     ((setr ...) (map (lambda (n) (datum->syntax x (symbol-append 'set-governance-ctx- n '!))) '(scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref))))
         #'(let-syntax ((name (identifier-syntax (_ (ref ctx)) ((set! _ v) (setr ctx v)))) ...)
             body ...))))))

;; the whole context: what a fragment reads and writes
(define-syntax with-governance-ctx
  (lambda (x)
    (syntax-case x ()
      ((_ ctx body ...)
       (with-syntax (((name ...) (map (lambda (n) (datum->syntax x n)) '(scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref %preimage %signed! ensure-citizen voice-data-snapshot recorder-aid sign-as-recorder open-proposal! contest-family scope-root scope-observer scope-for revoke-where!)))
                     ((ref ...) (map (lambda (n) (datum->syntax x (symbol-append 'governance-ctx- n))) '(scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref %preimage %signed! ensure-citizen voice-data-snapshot recorder-aid sign-as-recorder open-proposal! contest-family scope-root scope-observer scope-for revoke-where!)))
                     ((setr ...) (map (lambda (n) (datum->syntax x (symbol-append 'set-governance-ctx- n '!))) '(scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of voices sealed?-of delegations scope-root-of contest-settled snapshot-saids fp-trusted-issuers fp-root-aid fp-strict-root? uc-proposals-ref %preimage %signed! ensure-citizen voice-data-snapshot recorder-aid sign-as-recorder open-proposal! contest-family scope-root scope-observer scope-for revoke-where!))))
         #'(let-syntax ((name (identifier-syntax (_ (ref ctx)) ((set! _ v) (setr ctx v)))) ...)
             body ...))))))

;;; ── the fragments ────────────────────────────────────────────────────────────
;;;
;;; Each is a procedure from a <governance-ctx> to a declared-doors fragment, set
;;; once per process by (playnet boot governance), in dispatch order.

(define *governance-fragments* '())
(define (governance-fragments) *governance-fragments*)
(define (set-governance-fragments! makers)
  "MAKERS: procedures from a <governance-ctx> to a fragment, in dispatch order."
  (set! *governance-fragments* makers))

(define* (^governance-service bcom scope-roots ballot-store
                              governor? ;; (lambda (aid) bool) — e.g. founders-list membership
                              acdc-store ;; ^acdc-store or ^keria-acdc-store ref, or #f
                              #:optional [home-scope #f]  ;; ^scope ref for KEL anchoring (§4.6)
                                        [scope-of #f]     ;; commune-aid → ^scope, for a commune's OWN acts
                                        [kel-landing #f]  ;; (aid icp sigs rotations) → #t | error string: land a carried KEL
                                        [kel-of #f])
  (let ((ctx (make-governance-ctx scope-roots ballot-store governor? acdc-store home-scope scope-of kel-landing kel-of
                                  (hashmap) (hashmap) (hashmap) #f #f (hashmap) '() #f #f #f
                                  #f #f #f #f #f #f #f #f #f #f #f #f)))
    (with-governance-state ctx

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

      ;; a scope's root, through the injected scope-root-of; #f where none is
      ;; injected or the scope is unknown
      (define (scope-root scope-id)
        (and scope-root-of (scope-root-of scope-id)))

      ;; its planner observer — the record a contest is settled against
      (define (scope-observer scope-id)
        (let ((root (scope-root scope-id)))
          (and root ($ root 'observer))))

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

      ;; retag IS revoke + issue: the book holds one rel per person, so the
      ;; standing vouches from IDENTITY-KEY to SUBJECT-AID end when a new one
      ;; is spoken — no earlier rel stays live beside it
      ;; one live statement per key: a new one revokes what it supersedes
      (define (revoke-where! creds same?)
        (for-each (lambda (c) (when (same? c) ($ acdc-store 'revoke (cred-said c)))) creds))

      ;; the helpers the fragments read, handed over once the actor has them
      (set-governance-ctx-%preimage! ctx %preimage)
      (set-governance-ctx-%signed!! ctx %signed!)
      (set-governance-ctx-ensure-citizen! ctx ensure-citizen)
      (set-governance-ctx-voice-data-snapshot! ctx voice-data-snapshot)
      (set-governance-ctx-recorder-aid! ctx recorder-aid)
      (set-governance-ctx-sign-as-recorder! ctx sign-as-recorder)
      (set-governance-ctx-open-proposal!! ctx open-proposal!)
      (set-governance-ctx-contest-family! ctx contest-family)
      (set-governance-ctx-scope-root! ctx scope-root)
      (set-governance-ctx-scope-observer! ctx scope-observer)
      (set-governance-ctx-scope-for! ctx scope-for)
      (set-governance-ctx-revoke-where!! ctx revoke-where!)

      (finishing
        (compose-doors
         (map (lambda (make) (make ctx)) (governance-fragments))
         (lambda (door . _) (error "governance-service: no such door" door)))))))



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
    `((((playnet doors governance) ^governance-service) ,^governance-service))))
