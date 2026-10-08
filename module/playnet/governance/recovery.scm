;;; recovery.scm — reconstruct a live governance actor graph from ACDCs
;;;
;;; The architectural premise: ACDCs are the durable source of truth;
;;; the live actor graph is a projection. Recovery is the inverse of
;;; mutation — given an `^acdc-store` (or list of credentials), build
;;; a fresh actor graph whose state matches what the original system
;;; would have produced.
;;;
;;; Pure with respect to KERIA: in Phase-1, the acdc-store is in-memory
;;; (so recovery is in-process). Phase-2 will fetch from witnesses; the
;;; recovery functions here are unchanged because they consume the same
;;; acdc-store interface.
;;;
;;; What's recovered:
;;;
;;;   recover-delegation-map(citizen-id, acdc-store, target-acdc-store)
;;;     → fresh ^delegation-map populated from non-revoked
;;;       playnet-delegation credentials issued by citizen-id.
;;;       target-acdc-store: the store the recovered map should write
;;;       to going forward (typically the same acdc-store).
;;;
;;;   recover-commune-state(commune, acdc-store)
;;;     → applies non-revoked exclusion + ccf-assessment + membership
;;;       credentials scoped to commune's name. Modifies the commune
;;;       in-place via gov-cap minted from itself + the wrapped
;;;       ^account-store. Latest CCF assessment per (commune, citizen)
;;;       wins (by `assessed-at`).
;;;
;;;   recover-federation-state(federation, acdc-store, communes-by-id)
;;;     → re-admits each commune in non-revoked
;;;       playnet-federation-membership credentials, using the supplied
;;;       lookup table to resolve commune-id → live ^commune ref.
;;;
;;; All three are convenience compositions; the building blocks are
;;; pure helpers below.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.

(define-module (playnet governance recovery)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet governance credentials)
  #:use-module (playnet governance ballot)
  #:use-module (playnet governance delegation-map)
  #:use-module (playnet openvtc first-person)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet planner pools credit-fold)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet governance acdc-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (latest-by-claim recover-delegation-map recover-commune-state
            recover-federation-state recover-federation-state-remote
            recover-ballot-state recover-ballots-into-scope! recover-commitments
            recover-work-events recover-intents recover-lineage
            recover-personhood-state recover-economic-state))

;; =========================================================================
;; Pure helpers — pick latest, group, etc.
;; =========================================================================

(define (latest-by-claim creds claim-key)
  "From a list of credentials, group by holder and return a hashmap
   holder → credential where the credential is the one with the largest
   value at CLAIM-KEY (e.g. 'assessed-at). Revoked credentials are
   excluded by the caller before passing in."
  (let loop ((remaining creds) (acc (hashmap)))
    (cond
      ((null? remaining) acc)
      (else
       (let* ((c     (car remaining))
              (holder (cred-holder c))
              (ts    (cred-claim c claim-key))
              (existing (hashmap-ref acc holder #f)))
         (cond
           ((or (not existing)
                (> ts (cred-claim existing claim-key)))
            (loop (cdr remaining) (hashmap-set acc holder c)))
           (else
            (loop (cdr remaining) acc))))))))

;; `non-revoked-by-schema` is acdc-store.scm's — a store query in the store's
;; own vocabulary, shared with first-person.scm's lineage walk.

;; =========================================================================
;; recover-delegation-map
;; =========================================================================

(define* (recover-delegation-map citizen-id acdc-store
                                  #:key (write-store #f))
  "Build a fresh ^delegation-map for CITIZEN-ID by replaying all
   non-revoked playnet-delegation credentials issued by them.

   Bypasses the public delegate methods to avoid re-emitting ACDCs
   (which would collide on the existing SAIDs). Writes are constructed
   directly into the federation-default + scope-overrides hashmaps,
   then the actor is spawned with that state.

   write-store: the acdc-store the recovered map should emit into for
   future mutations (after recovery completes). Default #f."
  (let* ((all-creds (filter
                      (lambda (c)
                        (and (equal? (cred-schema c) *schema-playnet-delegation*)
                             (equal? (cred-issuer c) citizen-id)
                             (not (cred-revoked? c))))
                      ($ acdc-store 'by-issuer citizen-id)))
         ;; Deterministic order in case of duplicates (later wins).
         (sorted (sort all-creds (lambda (a b)
                                   (string<? (cred-said a) (cred-said b))))))
    (let loop ((remaining sorted)
               (fed-default (hashmap))
               (scope-overrides (hashmap)))
      (cond
        ((null? remaining)
         (spawn ^delegation-map citizen-id fed-default scope-overrides
                write-store))
        (else
         (let* ((c  (car remaining))
                (cl (cred-claims c))
                (delegate (cred-holder c))
                (franchise (assq-ref cl 'franchise))
                (fraction (assq-ref cl 'fraction))
                (mandate-spec (assq-ref cl 'mandate))
                (mandate-pred (and mandate-spec
                                   (compile-mandate-spec mandate-spec)))
                (entry (make-entry fraction mandate-pred)))
           (cond
             ((eq? franchise 'federation)
              (loop (cdr remaining)
                    (hashmap-set fed-default delegate entry)
                    scope-overrides))
             ((and (pair? franchise) (eq? (car franchise) 'scope))
              (let* ((sid (cadr franchise))
                     (current (hashmap-ref scope-overrides sid (hashmap)))
                     (new-override (hashmap-set current delegate entry)))
                (loop (cdr remaining) fed-default
                      (hashmap-set scope-overrides sid new-override))))
             (else (error "Unknown franchise in cred" franchise)))))))))


;; =========================================================================
;; recover-commune-state
;; =========================================================================

(define (recover-commune-state commune acdc-store)
  "Apply all non-revoked exclusion + ccf-assessment + membership
   credentials scoped to commune's name. The COMMUNE must be a live
   ^commune already wired to ACDC-STORE (otherwise mutations would
   re-emit credentials and infinite-loop on round-trip)."
  (let* ((name ($ commune 'name))
         (commune-aid ($ commune 'commune-aid))
         (gov-cap     ($ commune 'mint-gov-cap "recovery-bot"))
         (all-creds   ($ acdc-store 'by-issuer commune-aid)))

    ;; --- Membership: ensure-account for each member of THIS commune ---
    (for-each
      (lambda (c)
        (when (and (equal? (cred-schema c) *schema-playnet-membership*)
                   (not (cred-revoked? c))
                   (equal? (cred-claim c 'commune) name))
          ($ ($ ($ commune 'scope-root) 'account-store)
             'ensure-account (cred-holder c))))
      all-creds)

    ;; --- CCF: latest non-revoked per holder wins ---
    (let* ((ccf-creds (filter
                        (lambda (c)
                          (and (equal? (cred-schema c) *schema-playnet-ccf-assessment*)
                               (not (cred-revoked? c))
                               (equal? (cred-claim c 'commune) name)))
                        all-creds))
           (latest (latest-by-claim ccf-creds 'assessed-at)))
      (hashmap-fold
        (lambda (holder c _)
          (let ((ccf (cred-claim c 'ccf)))
            ;; set-ccf will re-emit a new ACDC since acdc-store is wired.
            ;; That's intentional: the recovered ACDC carries the new
            ;; SAID so the round-trip is observable. Tests that want
            ;; pristine round-trip can compare CCF VALUES, not ACDC
            ;; contents.
            ($ commune 'set-ccf gov-cap holder ccf)))
        #f latest))

    ;; --- Exclusions: each non-revoked exclusion is reapplied ---
    (for-each
      (lambda (c)
        (when (and (equal? (cred-schema c) *schema-playnet-exclusion*)
                   (not (cred-revoked? c))
                   (equal? (cred-claim c 'commune) name))
          ($ commune 'exclude-member gov-cap (cred-holder c))))
      all-creds)

    commune))


;; =========================================================================
;; recover-federation-state
;; =========================================================================

(define (recover-federation-state federation acdc-store communes-by-id)
  "Re-admit each commune in non-revoked playnet-federation-membership
   credentials. COMMUNES-BY-ID: hashmap commune-id → live ^commune ref."
  (let* ((name ($ federation 'name))
         (fed-aid ($ federation 'federation-aid))
         (gov-cap ($ federation 'mint-gov-cap "recovery-bot")))
    (for-each
      (lambda (c)
        (when (and (equal? (cred-schema c)
                           *schema-playnet-federation-membership*)
                   (not (cred-revoked? c))
                   (equal? (cred-claim c 'federation) name))
          (let* ((commune-id (cred-claim c 'commune-id))
                 (commune-ref (hashmap-ref communes-by-id commune-id #f)))
            (when commune-ref
              ($ federation 'admit-commune gov-cap commune-id commune-ref)))))
      ($ acdc-store 'by-issuer fed-aid))
    federation))


;; =========================================================================
;; recover-federation-state-remote — resolve sturdyrefs from ACDCs
;; =========================================================================

(define (recover-federation-state-remote federation acdc-store)
  "Re-admit remote communes from sturdyref credentials. For each
   non-revoked playnet-federation-sturdyref credential, extract the
   commune-id and sturdyref-uri, and call admit-commune-remote (which
   stores the URI without resolving it). Caller should then call
   ($ federation 'resolve-all-communes) to enliven the sturdyrefs.

   Does NOT re-issue credentials (they already exist in the store)."
  (let* ((name    ($ federation 'name))
         (fed-aid ($ federation 'federation-aid))
         (gov-cap ($ federation 'mint-gov-cap "recovery-bot"))
         (all     ($ acdc-store 'by-issuer fed-aid)))
    ;; Unbind acdc-store to prevent re-emission during recovery
    (let ((orig-store ($ federation 'acdc-store)))
      ($ federation 'set-acdc-store #f)
      (for-each
        (lambda (c)
          (when (and (equal? (cred-schema c)
                             *schema-playnet-federation-sturdyref*)
                     (not (cred-revoked? c)))
            (let ((commune-id   (cred-claim c 'commune-id))
                  (sturdyref    (cred-claim c 'sturdyref-uri))
                  (commune-aid  (cred-holder c)))
              ($ federation 'admit-commune-remote
                 gov-cap commune-id commune-aid sturdyref))))
        all)
      ($ federation 'set-acdc-store orig-store))
    federation))


;; =========================================================================
;; recover-ballot-state — rebuild a ballot from snapshot + stance ACDCs
;; =========================================================================

(define* (recover-ballot-state ballot-store acdc-store proposal-id sealed-by-aid
                               #:key (credential-check (lambda (_aid) #t)))
  "Rebuild a ^ballot from its snapshot + stance ACDCs.

   ballot-store:    the ^ballot-store to record the recovered ballot in
   acdc-store:      ^acdc-store with playnet-ballot-snapshot + stance ACDCs
   proposal-id:     which proposal to recover
   sealed-by-aid:   hashmap aid → sealed?-actor (live registry from
                    governance-service; sealers are vat-local)
   credential-check: passed through to ^ballot

   Returns the recovered ballot ref, or #f if no snapshot found."
  (let ((snap-cred ($ acdc-store 'by-claim-1
                      *schema-playnet-ballot-snapshot*
                      'proposal-id proposal-id)))
    (cond
      ((not snap-cred) #f)
      (else
       (let* ((domain      (or (cred-claim snap-cred 'domain) 'policy))
              (franchise   (cred-claim snap-cred 'franchise))
              (description (or (cred-claim snap-cred 'description) ""))
              (entries     (or (cred-claim snap-cred 'voice-snapshot-entries) '()))
              (registry-aids (or (cred-claim snap-cred 'citizen-registry-aids) '()))
              ;; Reconstruct voice-snapshot from entries
              (voice-snapshot
                (fold (lambda (entry acc)
                        (let* ((cid          (list-ref entry 0))
                               (voice-share  (list-ref entry 1))
                               (deleg-list   (list-ref entry 2))
                               (resolved
                                (fold (lambda (de sub-acc)
                                        (let* ((delegate-aid (list-ref de 0))
                                               (fraction     (list-ref de 1))
                                               (mandate-spec (list-ref de 2))
                                               (mandate-pred (and mandate-spec
                                                                  (compile-mandate-spec
                                                                    mandate-spec))))
                                          (hashmap-set sub-acc delegate-aid
                                                       (make-entry fraction
                                                                   mandate-pred))))
                                      (hashmap) deleg-list)))
                          (hashmap-set acc cid (voice-snap voice-share resolved))))
                      (hashmap) entries))
              ;; Reconstruct citizen-registry from sealed-by-aid map
              (citizen-registry
                (fold (lambda (cid acc)
                        (let ((sealed? (hashmap-ref sealed-by-aid cid #f)))
                          (if sealed? (hashmap-set acc cid sealed?) acc)))
                      (hashmap) registry-aids))
              ;; Read stance ACDCs and rebuild stances hashmap
              (stance-creds ($ acdc-store 'by-claim
                               *schema-playnet-stance*
                               'proposal-id proposal-id))
              (stances
                (fold (lambda (sc acc)
                        (cond
                          ((cred-revoked? sc) acc)
                          (else
                           ;; A stance is the citizen's own assertion: issuer =
                           ;; the casting citizen, issuee = the recording scope.
                           (let* ((citizen-id (cred-issuer sc))
                                  (position   (cred-claim sc 'position))
                                  (cleartext (list 'stance proposal-id position
                                                   citizen-id citizen-id)))
                             (hashmap-set acc citizen-id cleartext)))))
                      (hashmap) stance-creds))
              ;; Determine status from tally-result presence
              (tally-cred ($ acdc-store 'by-claim-1
                             *schema-playnet-tally-result*
                             'proposal-id proposal-id))
              (status (if tally-cred 'closed 'open))
              ;; Spawn fresh ballot
              (b (spawn ^ballot domain proposal-id franchise description
                        voice-snapshot stances
                        (make-sealer-verifier citizen-registry)
                        credential-check #f
                        (hashmap) (hashmap)
                        status)))
         ;; the meta a fresh open writes; an opened-at already held stays
         ($ ballot-store 'record proposal-id b
            (list (cons 'kind 'ballot) (cons 'domain domain)
                  (cons 'description description) (cons 'franchise franchise)))
         (when tally-cred
           ($ ballot-store 'record-tally proposal-id
              (let ((td (cred-claim tally-cred 'tally-data)))
                ;; tally-data was canonical-string'd; for tests we keep
                ;; the data. Production would re-parse.
                (if (string? td) (hashmap) td))
              (or (cred-claim tally-cred 'abstain-weight) 0)
              (or (cred-claim tally-cred 'closed-at) (instant->unix (clock-now)))))
         b)))))


;; =========================================================================
;; recover-ballots-into-scope! — rebuild + register every ballot for a scope
;; =========================================================================
;;
;; recover-ballot-state (above) rebuilds one ballot, given its proposal-id,
;; and records it in the shared ballot-store — but that leaves the ballot
;; invisible to $ scope 'get-ballot / 'close-ballot, which read a
;; scope-local ballots index that only open-direct-ballot/
;; open-ballot-for-scope ever write to. This finds every ballot-snapshot
;; ACDC whose franchise names SCOPE, recovers each, and registers it back
;; via 'register-ballot! (governance/scope.scm).
;;
;; CAVEAT, deliberately not papered over: recover-ballot-state's verifier
;; (make-sealer-verifier citizen-registry) is a frozen snapshot built from
;; SEALED-BY-AID at call time. Goblins sealers aren't derived from any
;; stable secret — spawn-voice-signer mints a fresh one per process, so a
;; citizen's PRE-restart sealed?-actor cannot be reconstructed at all
;; post-restart. Historical stances are unaffected (recover-ballot-state
;; trusts the stance ACDCs directly, not the original seals), but a
;; citizen who reconnects AFTER this runs and gets a freshly-minted
;; sealed?-actor (via ensure-citizen) will NOT be recognized by the
;; recovered ballot's verifier, because that hashmap is frozen at
;; construction and has no path to grow afterward — so calling this at
;; gateway BOOT time, before any citizen has reconnected, would silently
;; produce ballots no one can cast new stances on. Call it lazily instead
;; — e.g. the first time a citizen who's already back (present in
;; SEALED-BY-AID) touches this scope's ballots — or accept that new
;; stances need re-opening the ballot until ^ballot's verifier is made
;; live-updatable. Not resolved here; that's a decision about ^ballot's
;; own architecture, not this function.
(define* (recover-ballots-into-scope! scope acdc-store ballot-store sealed-by-aid
                                      #:key (credential-check (lambda (_aid) #t)))
  "Recover every ballot belonging to SCOPE from ACDC-STORE and register
   each into SCOPE's own ballots index. Returns the list of recovered
   proposal-ids (a ballot with a tally-result ACDC — i.e. already
   closed — is still recovered and registered, for get-ballot/history
   purposes, even though no one will cast on it again)."
  (let* ((name       ($ scope 'name))
         (kind       ($ scope 'kind))
         (my-franchise (if (memq kind '(federation universal-commune))
                           'federation
                           (list 'scope name)))
         (snapshots  (filter
                      (lambda (c)
                        (and (equal? (cred-schema c) *schema-playnet-ballot-snapshot*)
                             (equal? (cred-claim c 'franchise) my-franchise)))
                      ($ acdc-store 'by-schema *schema-playnet-ballot-snapshot*))))
    (filter-map
     (lambda (snap)
       (let* ((proposal-id (cred-claim snap 'proposal-id))
              (b (recover-ballot-state ballot-store acdc-store proposal-id
                                       sealed-by-aid
                                       #:credential-check credential-check)))
         (and b
              (begin
                ($ scope 'register-ballot! proposal-id b)
                proposal-id))))
     snapshots)))


;; =========================================================================
;; recover-economic-state — work events + commitments from ACDCs
;; =========================================================================

(define (recover-commitments plan-store observer acdc-store)
  "Replay non-revoked playnet-commitment ACDCs into PLAN-STORE via
   the silent variant (no re-emission). Reconstructs minimal commitment
   records from claims — enough for the SAID lookup index to work.
   Also registers each commitment with OBSERVER so that the §III.1
   Validation Gate can match work events against fulfillment state."
  (let ((cmt-creds ($ acdc-store 'by-schema *schema-playnet-commitment*)))
    (for-each
      (lambda (cred)
        (when (not (cred-revoked? cred))
          (let* ((cid (cred-claim cred 'commitment-id))
                 ;; Skip if already present (idempotent recovery)
                 (existing ($ plan-store 'get-commitment cid)))
            (unless existing
              (let* ((rq    (cred-claim cred 'resource-quantity))
                     (rq-m  (and rq (pair? rq)
                                 (make-measure (car rq) (cdr rq))))
                     (eq    (cred-claim cred 'effort-quantity))
                     (eq-m  (and eq (pair? eq)
                                 (make-measure (car eq) (cdr eq))))
                     (c (make-commitment #:id cid #:action (cred-claim cred 'action)
                                         #:input-of (cred-claim cred 'process-id) #:resource-conforms-to (cred-claim cred 'resource-conforms-to)
                                         #:resource-classified-as (or (cred-claim cred 'resource-classified-as) '())
                                         #:resource-quantity rq-m #:effort-quantity eq-m
                                         #:provider (cred-issuer cred)  ;; provider
                                         #:receiver (cred-holder cred)  ;; receiver
                                         #:due (cred-claim cred 'due)
                                         #:satisfies (cred-claim cred 'satisfies)
                                         #:planned-within (cred-claim cred 'plan-id))))
                ($ plan-store 'add-commitment-silent c)
                ;; guarded: register-commitment builds a FRESH fulfillment
                ;; state (0 fulfilled), so replaying over an observer that
                ;; already tracks this cid (restored from its own event
                ;; stream while the plan-store's portrait was lost) would
                ;; zero recorded progress — and recover-work-events then
                ;; SKIPS the proving events because the observer already
                ;; holds them by id, making the wipe permanent
                (unless ($ observer 'get-fulfillment (commitment-id c))
                  ($ observer 'register-commitment c)))))))
      cmt-creds))
  plan-store)

(define (recover-work-events account-store observer acdc-store)
  "Replay non-revoked playnet-work-event ACDCs. Records each event into
   OBSERVER (so the Validation Gate can compute the fulfillment
   fraction at query time) and also calls credit-from-event-silent on
   ACCOUNT-STORE to ensure the provider's account row exists without
   re-firing the on-work ACDC emission callback.

   Idempotent: skips any event the OBSERVER already holds (by event-id).
   Unlike commitments and intents, recording a work event both appends to
   the observer's log AND credits the account — neither of which dedups on
   its own — so replaying an already-present event would double-count
   fulfillment and double-credit hours. The guard makes recover-economic-
   state safe to run unconditionally after a native-portrait restore: a
   no-op when the portrait already brought the events back, a rebuild when
   only the (more durable, witnessed) ACDCs survived."
  (let ((work-creds ($ acdc-store 'by-schema *schema-playnet-work-event*)))
    (for-each
      (lambda (cred)
        (when (not (cred-revoked? cred))
          (let* ((evt-id (cred-claim cred 'event-id))
                 (existing ($ observer 'get-event evt-id)))
            (unless existing
              (let* ((worker (cred-holder cred))
                     (hours  (cred-claim cred 'hours))
                     (unit   (or (cred-claim cred 'unit) "hour"))
                     (event (make-economic-event
                              #:id evt-id #:action 'work
                              #:resource-conforms-to (cred-claim cred 'resource-conforms-to)
                              #:provider worker
                              #:effort-quantity (make-measure hours unit)
                              #:created (cred-claim cred 'timestamp)
                              #:fulfills (cred-claim cred 'fulfills)
                              #:satisfies (cred-claim cred 'satisfies))))
                ($ observer 'record-event event)
                ($ account-store 'credit-from-event-silent event))))))
      work-creds))
  account-store)

(define (recover-intents plan-store observer acdc-store)
  "Replay non-revoked playnet-intent ACDCs into PLAN-STORE and register
   with OBSERVER so the §III.1 Validation Gate can anchor satisfying
   events against the intent's satisfaction-state post-recovery."
  (let ((intent-creds ($ acdc-store 'by-schema *schema-playnet-intent*)))
    (for-each
      (lambda (cred)
        (when (not (cred-revoked? cred))
          (let* ((iid (cred-claim cred 'intent-id))
                 (existing ($ plan-store 'get-intent iid)))
            (unless existing
              (let* ((rq    (cred-claim cred 'resource-quantity))
                     (rq-m  (and rq (pair? rq)
                                 (make-measure (car rq) (cdr rq))))
                     (eq    (cred-claim cred 'effort-quantity))
                     (eq-m  (and eq (pair? eq)
                                 (make-measure (car eq) (cdr eq))))
                     (av    (cred-claim cred 'available-quantity))
                     (av-m  (and av (pair? av)
                                 (make-measure (car av) (cdr av))))
                     (mn    (cred-claim cred 'minimum-quantity))
                     (mn-m  (and mn (pair? mn)
                                 (make-measure (car mn) (cdr mn))))
                     (i (make-intent #:id iid #:action (cred-claim cred 'action)
                                     #:input-of (cred-claim cred 'process-id) #:resource-conforms-to (cred-claim cred 'resource-conforms-to)
                                     #:resource-classified-as (or (cred-claim cred 'resource-classified-as) '())
                                     #:resource-quantity rq-m #:effort-quantity eq-m #:available-quantity av-m #:minimum-quantity mn-m
                                     #:provider (cred-claim cred 'provider)
                                     #:receiver (cred-claim cred 'receiver)
                                     #:due (cred-claim cred 'due)
                                     #:planned-within (cred-claim cred 'plan-id)
                                     #:satisfies (cred-claim cred 'satisfies))))
                ($ plan-store 'add-intent-silent i)
                ($ observer 'register-intent i))))))
      intent-creds))
  plan-store)

;; =========================================================================
;; Recomposition lineage — reconstruct ancestor chain from merger/split ACDCs
;; =========================================================================

(define (recover-lineage scope acdc-store)
  "Reconstruct SCOPE's lineage by walking scope-merger and scope-split
   ACDCs in ACDC-STORE.

   For each non-revoked merger ACDC where SCOPE's AID = new-scope-aid,
   the predecessors join the lineage. For each non-revoked split ACDC
   that names SCOPE's AID in sub-scope-aids, the parent joins the lineage.
   Order: oldest event first (so the deepest ancestor appears earliest).

   Calls (set-lineage scope new-lineage). Returns SCOPE."
  (let* ((scope-aid ($ scope 'scope-aid))
         (mergers (non-revoked-by-schema acdc-store *schema-playnet-scope-merger*))
         (splits  (non-revoked-by-schema acdc-store *schema-playnet-scope-split*))
         (merger-ancestors
          (fold (lambda (cred acc)
                  (if (equal? (cred-claim cred 'new-scope-aid) scope-aid)
                      (cons (list (cred-claim cred 'merged-at)
                                  (cred-claim cred 'predecessor-a)
                                  (cred-claim cred 'predecessor-b))
                            acc)
                      acc))
                '() mergers))
         (split-ancestors
          (fold (lambda (cred acc)
                  (let ((subs (cred-claim cred 'sub-scope-aids)))
                    (if (and subs (member scope-aid subs))
                        (cons (list (cred-claim cred 'split-at)
                                    (cred-claim cred 'parent-scope-aid))
                              acc)
                        acc)))
                '() splits))
         ;; Combine and sort by timestamp (oldest first)
         (events (sort (append merger-ancestors split-ancestors)
                       (lambda (a b) (< (car a) (car b)))))
         (lineage (fold (lambda (event acc)
                          (append acc (cdr event)))
                        '() events)))
    ($ scope 'set-lineage lineage)
    scope))

;; =========================================================================
;; Personhood — validate the PHC + VRC corpus end-to-end
;; =========================================================================
;;
;; Personhood is not actor state to mutate (the trust triangle is
;; computed on demand from credentials), so this function does not
;; rebuild anything; it walks the corpus and reports any structural
;; or cryptographic problems a foreign verifier would notice. Useful
;; after `'import` from a peer or a `#:durable-dir` reload to surface
;; "this credential set has issues" before relying on it.

(define (recover-personhood-state acdc-store ecosystem-aid)
  "Audit ECOSYSTEM-AID's personhood corpus. Returns alist:
     ((phc-count . N)
      (vrc-count . M)
      (live-triangles . list-of-(a . b))
      (issues . list-of-(symbol . SAID)))
   Issue symbols:
     - 'unsigned-vrc      — VRC has no Ed25519 signature
     - 'invalid-vrc-sig   — sig doesn't verify against issuer AID
     - 'orphan-vrc        — issuer-phc edge doesn't resolve to a live PHC
     - 'broken-i2i        — issuer-phc edge fails I2I
   Pure: never mutates the store; callers decide whether to revoke."
  (define (vrc-issue vrc)
    (let* ((edge     (cred-edge vrc 'issuer-phc))
           (target-c (and edge ($ acdc-store 'get (edge-target edge)))))
      (cond
        ((not (cred-signature vrc))                'unsigned-vrc)
        ((not (cred-signature-valid? vrc))         'invalid-vrc-sig)
        ((or (not target-c) (not (phc-live? target-c))) 'orphan-vrc)
        ((not (edge-i2i-holds? edge vrc target-c)) 'broken-i2i)
        (else                                      #f))))

  (let* ((phcs (phcs-in-ecosystem acdc-store ecosystem-aid))
         (vrcs (filter (lambda (c) (not (cred-revoked? c)))
                       ($ acdc-store 'by-schema
                          *schema-playnet-relationship*)))
         (issues
           (filter-map
             (lambda (v)
               (let ((sym (vrc-issue v)))
                 (and sym (cons sym (cred-said v)))))
             vrcs))
         (triangles
           (append-map
             (lambda (a)
               (filter-map
                 (lambda (b)
                   (and (string<? (cred-holder a) (cred-holder b))
                        (trust-triangle-holds? acdc-store
                                               (cred-holder a)
                                               (cred-holder b)
                                               ecosystem-aid)
                        (cons (cred-holder a) (cred-holder b))))
                 phcs))
             phcs)))
    `((phc-count      . ,(length phcs))
      (vrc-count      . ,(length vrcs))
      (live-triangles . ,triangles)
      (issues         . ,issues))))


(define (recover-economic-state scope-root acdc-store)
  "Recover commitments, intents, and work events for SCOPE-ROOT from
   ACDCs. Three-phase: intents first (so commitment.satisfies is
   resolvable), then commitments (so work-event.fulfills is resolvable),
   then work events. The store must be passed in unbound (callers
   haven't yet wired set-on-commitment / set-on-intent / set-on-work)."
  (let ((plan-store ($ scope-root 'plan-store))
        (observer ($ scope-root 'observer))
        (account-store ($ scope-root 'account-store)))
    (recover-intents plan-store observer acdc-store)
    (recover-commitments plan-store observer acdc-store)
    (recover-work-events account-store observer acdc-store)
    scope-root))
