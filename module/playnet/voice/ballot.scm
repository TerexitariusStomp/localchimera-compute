;;; voice/ballot.scm — liquid-democracy ballot with frozen-snapshot tally
;;;
;;; A ^ballot freezes at open-time:
;;;   - each citizen's voice-share (pure labor proportion)
;;;   - each citizen's resolved delegation map (for the ballot's franchise)
;;;
;;; During the open window, citizens cast stances. The tally is a
;;; PURE function over the frozen snapshot + accumulated stances; it makes
;;; no cross-actor queries.
;;;
;;; The tally walks each citizen's voice forward:
;;;   - If they cast a stance: full voice → their position (direct override
;;;     removes them from delegation chains, automatically).
;;;   - Else if they have delegation entries (for this franchise): voice is
;;;     distributed by fraction to each delegate and resolved recursively.
;;;   - Remainder (1 − Σ fractions) or no-delegates case: unexercised.
;;;
;;; Every citizen's voice lands exactly once, either on a position or in
;;; abstention. No double-counting; no cycles (cycle-check is enforced at
;;; ^delegation-map delegate-time).
;;;
;;; Stance verification is pluggable via a VERIFIER function:
;;;   (verifier citizen-id cleartext auth-proof) → #t | raises
;;; Tests use sealer-based verification; production uses KERI Ed25519.
;;; The tally algorithm is blind to the verification method.
;;;

(define-module (playnet voice ballot)
  #:use-module (playnet voice delegation-map)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet keri citizen-sig)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (voice-snap voice-snap-share voice-snap-delegation *max-tally-depth*
            tally-snapshot make-citizen-verifier make-sealer-verifier ^ballot
            open-ballot ballot-env))

;; =========================================================================
;; Per-citizen voice snapshot
;; =========================================================================
;;
;; Represented as a pair: (voice-share . resolved-delegation-map)
;; where resolved-delegation-map is a hashmap delegate-id → fraction.

(define (voice-snap voice-share resolved-delegation)
  (cons voice-share resolved-delegation))

(define (voice-snap-share vs) (car vs))
(define (voice-snap-delegation vs) (cdr vs))


;; =========================================================================
;; Tally algorithm — pure function over snapshot + stances
;; =========================================================================

;; Hard cap on resolve-recursion depth. Real delegation chains shouldn't
;; come close; this defends against pathological graphs even after cycle
;; checks. A chain longer than this abstains the residual voice.
(define *max-tally-depth* 64)


(define (tally-snapshot voice-snapshot stances)
  "Pure tally.
   voice-snapshot: hashmap citizen-id → <voice-snap>
                   where <voice-snap> = (voice-share . delegation-map)
                   and delegation-map values are <entry> = (fraction . mandate)
   stances:        hashmap citizen-id → (list 'stance proposal-id position citizen-id)

   Returns a hashmap: position → total-weight. Positions with zero weight
   are omitted. Also returns, as a second value, the total unexercised
   weight (abstention).

   Mandate semantics: if a delegation entry has a mandate (procedure) and
   the delegate's stance does not satisfy it — OR the delegate didn't cast
   — the delegated voice is abstained, NOT flowed through. If the mandate
   is #f (liquid), voice flows normally."
  (let ((tally    (hashmap))
        (abstain  0))

    (define (add-to-tally position weight)
      (let ((current (hashmap-ref tally position 0)))
        (set! tally (hashmap-set tally position (+ current weight)))))

    (define (add-abstention weight)
      (set! abstain (+ abstain weight)))

    ;; Recursion safety:
    ;;   visited: list of citizen-ids already on the current resolve chain.
    ;;            If a citizen is revisited, we have a cycle — abstain to
    ;;            break it safely. Cross-citizen cycles can in principle slip
    ;;            past delegation-map's per-actor cycle check, so this is the
    ;;            authoritative guard at tally time.
    ;;   depth:   absolute recursion depth, capped at *max-tally-depth*.
    ;;            Defends against pathological non-cyclic graphs.
    (define (resolve citizen incoming-voice visited depth)
      (cond
        ((member citizen visited)
         ;; Cycle: voice held to break the loop.
         (add-abstention incoming-voice))
        ((>= depth *max-tally-depth*)
         ;; Depth cap reached: voice held.
         (add-abstention incoming-voice))
        (else
         (let ((cast-stance (hashmap-ref stances citizen #f)))
           (cond
             ;; Direct cast: attribute all incoming voice to this stance.
             (cast-stance
              (let ((position (caddr cast-stance)))
                (add-to-tally position incoming-voice)))
             ;; No cast — look at delegation.
             (else
              (let ((vs (hashmap-ref voice-snapshot citizen #f)))
                (cond
                  ((not vs)
                   ;; Unknown delegate (no snapshot entry, no cast): unexercised.
                   (add-abstention incoming-voice))
                  (else
                   (let* ((delegation (voice-snap-delegation vs))
                          (sum-fractions
                            (hashmap-fold (lambda (_k e a)
                                            (+ (entry-fraction e) a))
                                          0 delegation))
                          (next-visited (cons citizen visited))
                          (next-depth   (+ depth 1)))
                     ;; Distribute to delegates; gate each by mandate.
                     (hashmap-fold
                       (lambda (delegate-id entry _)
                         (let ((fraction (entry-fraction entry))
                               (mandate  (entry-mandate entry))
                               (delegated-voice (* incoming-voice
                                                   (entry-fraction entry))))
                           (cond
                             ((mandate-satisfied?
                                mandate
                                (hashmap-ref stances delegate-id #f))
                              (resolve delegate-id delegated-voice
                                       next-visited next-depth))
                             (else
                              (add-abstention delegated-voice)))))
                       #f
                       delegation)
                     ;; Direct-fraction remainder is unexercised.
                     (add-abstention (* incoming-voice (- 1 sum-fractions)))))))))))))

    ;; Outer loop: every citizen's OWN voice-share enters the resolution once.
    (hashmap-fold
      (lambda (citizen vs _)
        (resolve citizen (voice-snap-share vs) '() 0))
      #f
      voice-snapshot)

    (values tally abstain)))


;; =========================================================================
;; Verifier constructors
;; =========================================================================
;;
;; A verifier is (lambda (citizen-id cleartext auth-proof) → #t | raises).
;; The ballot calls it to validate a stance bundle. The verifier
;; encapsulates both "is this citizen known?" and "is this proof valid?".

(define (make-citizen-verifier citizen-registry)
  "THE stance verifier. Accepts two proof forms, both cryptographically
   checked, so the live tally and the durable ACDC rest on the SAME evidence
   instead of two parallel trust paths:

   KERI (preferred) — AUTH-PROOF is a pair (SAID . SIG-QB64): the citizen's own
   Ed25519 signature over the stance ACDC's SAID, the very signature the
   durable credential carries. Verified against CITIZEN-ID's AID directly.
   Because a KERI AID is self-certifying (the prefix commits to the public
   key), this needs NO registry entry — which is what lets a citizen who was
   not in the frozen open-time snapshot, or who reconnects after a recovery,
   still cast. The old registry-only design could never admit them.

   Sealer (legacy/tests) — AUTH-PROOF is a Goblins sealed blob, checked against
   the citizen's sealed?-actor in CITIZEN-REGISTRY. Vat-local and not
   foreign-verifiable; retained so existing ballots and tests keep working
   while clients migrate to signing.

   citizen-registry: hashmap citizen-id → sealed?-actor (sealer path only)."
  (lambda (citizen-id _cleartext auth-proof)
    (cond
     ;; KERI: (said . sig) — verify against CITIZEN-ID, whose D/B prefix IS the
     ;; key (self-certifying, non-transferable). Or (said sig . vkey) — verify
     ;; against VKEY, the caller's resolved current signing key: a transferable
     ;; E-prefix AID's prefix is the SAID of its inception event, NOT its key, so
     ;; the key must be resolved from the KEL (the lobby session does this and
     ;; threads it in via cast-signed). Both rest on the citizen's own signature.
     ((and (pair? auth-proof) (string? (car auth-proof)))
      (let* ((said (car auth-proof))
             (rest (cdr auth-proof))
             (sig  (if (pair? rest) (car rest) rest))
             (vkey (if (and (pair? rest) (string? (cdr rest))) (cdr rest) citizen-id)))
        (unless (and (string? sig) (verify-said-signature said sig vkey))
          (error "Invalid KERI signature — stance not signed by this citizen"
                 citizen-id))
        #t))
     (else
      (let ((sealed? (hashmap-ref citizen-registry citizen-id #f)))
        (unless sealed?
          (error "Unknown citizen for this ballot" citizen-id))
        (unless ($ sealed? auth-proof)
          (error "Invalid endorsement — stance not sealed by this citizen"
                 citizen-id))
        #t)))))

;; Back-compat alias — the sealer path is now one branch of the unified verifier.
(define make-sealer-verifier make-citizen-verifier)


;; =========================================================================
;; ^ballot — per-proposal coordinator
;; =========================================================================

(define-actor (^ballot bcom
                       domain              ;; 'policy | 'recomposition | …
                       proposal-id
                       franchise           ;; 'federation | ('scope sid)
                       description
                       voice-snapshot      ;; hashmap citizen-id → <voice-snap>
                       stances             ;; hashmap citizen-id → unsealed-stance
                       verifier            ;; (citizen-id cleartext proof) → #t | raises
                       credential-check    ;; (lambda (keri-aid) bool)
                       close-authority     ;; sealed?-actor for close gate, or #f
                       advisory-stances    ;; hashmap aid → cleartext (non-binding)
                       advisory-registry   ;; hashmap aid → sealed?-actor
                       status)             ;; 'open | 'closed
  #:version 6

  (methods

    ;; --- Reads ---
    ((kind) 'ballot)
    ((domain) domain)
    ((proposal-id) proposal-id)
    ((id) proposal-id)
    ((franchise) franchise)
    ((description) description)
    ((status) status)
    ((voice-snapshot) voice-snapshot)
    ((stances) stances)

    ;; --- Cast a stance ---
    ;;
    ;; stance-bundle is a pair (cleartext . auth-proof) as returned by
    ;; ^voice-signer.stance. auth-proof is either a Goblins sealed blob
    ;; (test mode) or a KERI Ed25519 signature (production).
    ;; cleartext shape: (stance proposal-id position citizen-id keri-aid)
    ((cast citizen-id stance-bundle)
     (when (eq? status 'closed)
       (error "Ballot is closed" proposal-id))
     (unless (pair? stance-bundle)
       (error "Stance bundle must be (cleartext . auth-proof)" stance-bundle))
     (let ((cleartext (car stance-bundle))
           (proof     (cdr stance-bundle)))
       (verifier citizen-id cleartext proof)
       (unless (and (pair? cleartext)
                    (eq? (car cleartext) 'stance)
                    (equal? (cadr cleartext) proposal-id)
                    (equal? (cadddr cleartext) citizen-id)
                    (= (length cleartext) 5))
         (error "Stance does not match this ballot+citizen" cleartext))
       (let ((keri-aid (list-ref cleartext 4)))
         (unless (credential-check keri-aid)
           (error "Credential check failed for citizen" citizen-id keri-aid)))
       (bcom (^ballot bcom domain proposal-id franchise description voice-snapshot
                      (hashmap-set stances citizen-id cleartext)
                      verifier credential-check close-authority
                      advisory-stances advisory-registry status))))

    ;; --- Advisory cast (for affected-interest non-members) ---
    ;; Recorded separately; does NOT contribute to the binding tally.
    ;; Advisory path keeps sealer verification (advisors are local).
    ((advisory-cast aid stance-bundle)
     (when (eq? status 'closed)
       (error "Ballot is closed" proposal-id))
     (let ((sealed? (hashmap-ref advisory-registry aid #f)))
       (unless sealed?
         (error "Unknown advisory voice for this ballot" aid))
       (unless (pair? stance-bundle)
         (error "Stance bundle must be (cleartext . auth-proof)" stance-bundle))
       (let ((cleartext (car stance-bundle))
             (proof     (cdr stance-bundle)))
         (unless ($ sealed? proof)
           (error "Invalid endorsement on advisory stance" aid))
         (unless (and (pair? cleartext)
                      (eq? (car cleartext) 'stance)
                      (equal? (cadr cleartext) proposal-id)
                      (equal? (cadddr cleartext) aid)
                      (= (length cleartext) 5))
           (error "Advisory stance shape mismatch" cleartext))
         (bcom (^ballot bcom domain proposal-id franchise description voice-snapshot
                        stances verifier credential-check
                        close-authority
                        (hashmap-set advisory-stances aid cleartext)
                        advisory-registry status)))))

    ((advisory-tally)
     ;; Headcount of advisory positions; no voice weighting (advisors
     ;; aren't members and don't have voice-shares in this ballot's
     ;; voice-snapshot).
     (let ((tally (hashmap)))
       (hashmap-fold
         (lambda (_aid cleartext _)
           (let ((position (caddr cleartext)))
             (let ((current (hashmap-ref tally position 0)))
               (set! tally (hashmap-set tally position (+ current 1))))))
         #f advisory-stances)
       (list (cons 'advisory-counts tally)
             (cons 'total-advisory
                   (hashmap-fold (lambda (_k _v a) (+ a 1)) 0
                                 advisory-stances)))))

    ((register-advisor aid sealed?-actor)
     ;; Register a non-member as an affected-interest advisory voice.
     (bcom (^ballot bcom domain proposal-id franchise description voice-snapshot
                    stances verifier credential-check
                    close-authority advisory-stances
                    (hashmap-set advisory-registry aid sealed?-actor)
                    status)))

    ;; --- Close the ballot ---
    ;; If close-authority is #f, anyone holding the ref can close (used by
    ;; standalone ^ballot tests and transitional callers). If close-authority
    ;; is a sealed?-actor, the caller must present a sealed-bundle whose
    ;; sealing satisfies the authority. ^commune always sets close-authority
    ;; so close is gov-gated in commune-managed ballots.
    ((close . rest)
     (when close-authority
       (let ((cap (and (pair? rest) (car rest))))
         (unless (and cap ($ close-authority cap))
           (error "Close requires a valid gov-authority capability"
                  proposal-id))))
     (bcom (^ballot bcom domain proposal-id franchise description voice-snapshot
                    stances verifier credential-check close-authority
                    advisory-stances advisory-registry 'closed)))

    ;; --- Tally ---
    ((tally)
     (call-with-values
       (lambda () (tally-snapshot voice-snapshot stances))
       (lambda (tally-map abstain)
         (list (cons 'tally tally-map)
               (cons 'abstain abstain)))))

    ;; --- Summary result: winning position + margins ---
    ((result)
     (call-with-values
       (lambda () (tally-snapshot voice-snapshot stances))
       (lambda (tally-map abstain)
         ;; Return the position with the max weight, plus the full tally.
         (let* ((entries (hashmap-fold (lambda (k v acc)
                                         (cons (cons k v) acc))
                                        '() tally-map))
                (sorted (sort entries (lambda (a b) (> (cdr a) (cdr b))))))
           (list (cons 'winner (and (pair? sorted) (caar sorted)))
                 (cons 'tally tally-map)
                 (cons 'abstain abstain))))))))


;; =========================================================================
;; open-ballot — convenience constructor; freezes voice+delegation snapshot
;; =========================================================================

(define* (open-ballot domain proposal-id franchise description
                      citizen-registry citizen-voice-data
                      #:key
                      (credential-check (lambda (_aid) #t))
                      (close-authority #f))
  "Create a new ballot with a frozen voice/delegation snapshot.

   domain:               'policy | 'recomposition | …
                         Tags the ballot kind so downstream consumers
                         (audit, ACDC indexing) can filter without
                         re-deriving from proposal-id. Math is
                         identical across domains.
   proposal-id:          identifier for the proposal
   franchise:            'federation  OR  (list 'scope scope-id)
   description:          human-readable text
   citizen-registry:     hashmap citizen-id → sealed?-actor
   citizen-voice-data:   hashmap citizen-id → (voice-share . delegation-map-ref)
                         — caller's responsibility to compute voice-shares
                         and pick the right scope-roots for the franchise.
   credential-check:     (lambda (keri-aid) bool); called per cast on the
                         cleartext's bound AID. Default: always-true — no
                         production caller currently wires a stricter check
                         here (voice rides on labor evidence, not credentials).
   close-authority:      sealed?-actor used to gate the close method, or
                         #f for ungated. ^commune always sets this so
                         commune-managed ballots are gov-gated.

   Returns a ^ballot actor ref.

   The delegation-map-ref can be #f if the citizen has no delegation-map;
   that's treated as empty delegation (all voice is direct-or-abstain)."
  (let ((voice-snapshot
          (hashmap-fold
            (lambda (cid data acc)
              (let* ((voice-share (car data))
                     (dm-ref      (cdr data))
                     (resolved    (if dm-ref
                                      ($ dm-ref 'resolve-for franchise)
                                      (hashmap))))
                (hashmap-set acc cid (voice-snap voice-share resolved))))
            (hashmap)
            citizen-voice-data)))
    (spawn ^ballot domain proposal-id franchise description
           voice-snapshot (hashmap)
           (make-sealer-verifier citizen-registry)
           credential-check close-authority
           (hashmap) (hashmap)   ;; advisory-stances, advisory-registry
           'open)))


;; =========================================================================
;; Persistence
;; =========================================================================

(define ballot-env
  (make-persistence-env
    `((((playnet governance) ^ballot) ,^ballot))))
