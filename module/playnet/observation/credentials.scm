;;; observation/credentials.scm — the bridge between the planner's event/plan layer and the
;;; ACDC substrate, in BOTH directions. Issuance: planner events become portable
;;; signed credentials (work-event + skill via the observer on-event hook; intent
;;; + commitment via the plan-store callbacks). Reconstruction: the ACDC graph is
;;; walked back into the observer's own views (earned-skills, practiced-hours) and
;;; checked for completeness (derived-state snapshots). The planner stays oblivious
;;; to ACDC schemas — all of that lives here, in governance.
;;;
;;; § Work + skill issuance (observer on-event hook)
;;;
;;; On each `work` EconomicEvent it:
;;;   1. issues a WORK-EVENT ACDC — the portable, edge-chained substrate the
;;;      credit ledger and skills both derive from (edges to the commitment it
;;;      fulfils + the intent it satisfies, for the Validation Gate); and
;;;   2. the FIRST time a worker performs a given skill, mints a SKILL membership
;;;      ACDC edged to that founding work event.
;;;
;;; Skills are derive-don't-store: no hours live on the token (they are summed
;;; from the work log by `practiced-hours`); the skill ACDC is minted ONCE per
;;; (worker, skill), gated on a possession query — not on SAID idempotency,
;;; since each event's founding edge would otherwise yield a fresh SAID.

(define-module (playnet observation credentials)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils units) #:select (hours-in))
  #:use-module (playnet credentials audit)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials registry)
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet keri acdc-store) #:select (non-revoked-by-schema))
  #:use-module (playnet keri acdc)
  #:use-module (playnet observation observer)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet observation event-log-store)
  #:use-module ((playnet observation evidence) #:select (tags-evidence))
  #:use-module ((playnet observation observer) #:select (void-correction? legacy-corrections->canonical))
  #:use-module (goblins)
  #:use-module (ice-9 format)
  #:export (held-skill-cred skill-held? mint-skill-if-new! attest-contribution!
            attest-consumption! make-credentialing-on-event measure->pair
            revoke-corrected-records!
            make-plan-credentialing-callbacks event-log-compaction-threshold
            install-event-log! install-credentialing! kel-anchored-saids
            event-log-reconcile! work-events-for-skill held-by cred-sum
            reconstruct-earned-skills reconstruct-practiced-hours
            reconstruct-claimed-hours reconstruct-credit-balance snapshot-input-saids
            snapshot-missing snapshot-complete? snapshot-over
            scope-acdc-store cred-attesters reconstruct-skill-attestation
            skill-attestation-standing))

(define* (held-skill-cred acdc-store worker skill)
  "WORKER's live (non-revoked) skill ACDC for SKILL, or #f. by-holder is the
   indexed read every credential gets; we filter to the skill schema + claim
   (by-claim-1 returns only the first match across all holders)."
  (find (lambda (c) (and (equal? (cred-schema c) *schema-playnet-skill*)
                         (equal? (cred-claim c 'skill) skill)
                         ;; live by the credential's own terms — a lapsed
                         ;; skill (valid-until past) qualifies nobody, the
                         ;; convention credentials.scm:make-skill-credential
                         ;; already states
                         (cred-live? c)))
        ($ acdc-store 'by-holder worker)))

(define* (skill-held? acdc-store worker skill)
  "True iff WORKER already holds a live skill ACDC for SKILL."
  (and (held-skill-cred acdc-store worker skill) #t))

;; Ledger ACDCs are PROVENANCE-signed via the witnessing scope's own SIGNER ref
;; (a ^scope) — cred-signed-by-scope routes through its sign-said, keypair stays
;; in the actor. The signature means "this scope recorded this occurrence" — NOT
;; that the work was socially validated. Validity is a separate, recipient-
;; anchored, read-time computation (the §III.1 Validation Gate on intent
;; satisfaction), so this provenance sig closes the recovery-forgery hole
;; without over-claiming. #f / keyless SIGNER (synthetic / demo scope) →
;; unsigned. Same one primitive used by service.scm and universal-commune.scm.

(define* (mint-skill-if-new! acdc-store scope-aid worker skill founding-said
                             #:key (valid-until #f) (signer #f))
  "Mint a skill ACDC for (WORKER, SKILL) unless one is already held. Returns the
   new skill SAID if minted, else #f (mint-once)."
  (and (not (skill-held? acdc-store worker skill))
       (let ((cred (cred-signed-by-scope
                    (make-skill-credential scope-aid worker skill founding-said
                                           #:valid-until valid-until)
                    signer)))
         ($ acdc-store 'issue cred)
         (cred-said cred))))

;; CONTRIBUTION: a `work` event → its work-event ACDC (edge-chained to the
;; commitment it fulfils, the intent it satisfies, and — after the founding one —
;; its skill), plus, once per (worker, skill), the founding skill ACDC.
(define* (attest-contribution! acdc-store scope-aid event
                               #:key (signer #f) (witnesses #f))
  (let* ((worker (economic-event-provider event))
         (skill  (economic-event-resource-conforms-to event))
         (eq     (economic-event-effort-quantity event))
         (hours  (and eq (hours-in (measure-has-numerical-value eq) (measure-has-unit eq))))   ; the credential counts time in hours
         (unit   (and eq "hours")))
    (when (and worker skill)
      (let* ((prior (held-skill-cred acdc-store worker skill))
             ;; WITNESSES ((member-aid . keypair) …) closes the single-issuer
             ;; integrity hole for this event: the ACDC carries a k-of-n
             ;; multisig block instead of one scope signature, and the recipe
             ;; metabolism's evidence layer stops being one scope's word.
             ;; Absent, the single-signer path is exactly what it always was.
             (base (make-work-event-credential
                    scope-aid worker (economic-event-id event) hours unit
                    #:process-id (or (economic-event-input-of event)
                                     (economic-event-output-of event))
                    #:timestamp (economic-event-has-point-in-time event)
                    #:resource-conforms-to skill
                    #:fulfills (economic-event-fulfills event)
                    #:satisfies (economic-event-satisfies event)
                    #:skill-said (and prior (cred-said prior))
                    #:multisig-signers witnesses))
             (we (if witnesses base (cred-signed-by-scope base signer))))
        ($ acdc-store 'issue-idempotent we)
        (mint-skill-if-new! acdc-store scope-aid worker skill (cred-said we)
                            #:signer signer)))))

;; CONSUMPTION: an individually-claimable `transfer` (a credit DRAW) → its claim
;; ACDC, so ledger-claimed — hence the full credit-balance — reconstructs from the
;; ACDC set exactly as work events give the gross side. Holder = claimant.
(define* (attest-consumption! acdc-store scope-aid event #:key (signer #f))
  (when (and (eq? (event-distribution-mode event) 'individual-claimable)
             (economic-event-receiver event)
             (economic-event-effort-quantity event))
    (let ((teq (economic-event-effort-quantity event)))
      ($ acdc-store 'issue-idempotent
         (cred-signed-by-scope
          (make-claim-event-credential
           scope-aid (economic-event-receiver event) (economic-event-id event)
           (hours-in (measure-has-numerical-value teq) (measure-has-unit teq)) "hours"
           #:resource-spec (economic-event-resource-conforms-to event)
           #:qty (and=> (economic-event-resource-quantity event) measure-has-numerical-value)
           #:timestamp (economic-event-has-point-in-time event)
           #:settles (economic-event-settles event))
          signer)))))

;; OBSERVATION: every other QUANTIFIED action → one generic observation ACDC,
;; scope-signed like the work and claim halves — the material confirmation
;; mile (produce/consume/pickup/dropoff), use, raise/lower, and a journey's two ends all
;; leave portable evidence rather than only an in-memory fold. The quantity
;; guard is what keeps the cascade's zero-quantity containment events
;; (combine/separate) and other bookkeeping echoes out of the credential set.
(define* (attest-observation! acdc-store scope-aid event #:key (signer #f))
  (let* ((holder (or (economic-event-provider event)
                     (economic-event-receiver event)))
         (m (or (economic-event-resource-quantity event)
                (economic-event-effort-quantity event))))
    (when (and holder m (positive? (measure-has-numerical-value m)))
      ($ acdc-store 'issue-idempotent
         (cred-signed-by-scope
          (make-observation-event-credential
           scope-aid holder (economic-event-id event)
           (symbol->string (economic-event-action event))
           #:qty (measure-has-numerical-value m)
           #:unit (measure-has-unit m)
           #:resource-conforms-to (economic-event-resource-conforms-to event)
           #:at-location (economic-event-at-location event)
           #:to-location (economic-event-to-location event)
           #:timestamp (or (economic-event-has-point-in-time event)
                           (economic-event-has-beginning event)
                           (economic-event-has-end event))
           #:fulfills (economic-event-fulfills event)
           ;; a photo read names its picture on the event, by hash
           #:evidence (tags-evidence (economic-event-resource-classified-as event)))
          signer)))))

(define (revoke-corrected-records! acdc-store event)
  "Revoke every live credential recording the event that EVENT corrects, and
   return them. The observer reads a corrected event at its net quantity; the
   portable records say the same by revoking the record of the stated quantity
   and attesting the standing event again (see make-credentialing-on-event)."
  (let ((oid (economic-event-corrects event)))
    (if (not oid)
        '()
        (filter-map (lambda (c)
                      (and (equal? (cred-claim c 'event-id) oid)
                           (not (cred-revoked? c))
                           (begin ($ acdc-store 'revoke (cred-said c)) c)))
                    ($ acdc-store 'all)))))

(define* (attest-event! acdc-store scope-aid event #:key (signer #f))
  "EVENT's portable record, by what it is: the labour half (work), the draw half
   (transfer), and every other quantified action through the one observation shape."
  (case (economic-event-action event)
    ((work)     (attest-contribution! acdc-store scope-aid event #:signer signer))
    ((transfer) (attest-consumption!  acdc-store scope-aid event #:signer signer))
    ((produce consume use move raise lower pickup dropoff deliver-service)   ; verb-meant: which acts get a credential is a decision (beyond-valueflows §6.6), not the table's
     (unless (void-correction? event)
       (attest-observation! acdc-store scope-aid event #:signer signer)))))

(define* (make-credentialing-on-event acdc-store scope-aid #:key (signer #f))
  "Build the observer `on-event` callback: each planner event becomes its portable
   credential. SCOPE-AID is the witnessing scope (the issuer). SIGNER, when
   supplied, provenance-signs each record via the scope's own sign-said
   (cred-signed-by-scope). A correction is no act of its own: the records of the
   event it corrects are revoked, and the event as the observer now reads it (its
   net, passed as STANDING) is attested again under its own id, so every
   reconstruction over live credentials (hours, co-signers, credit) says what the
   observer's standing folds say. A full back-out leaves no record."
  (lambda (event affected . rest)
    (if (economic-event-corrects event)
        (let ((revoked (revoke-corrected-records! acdc-store event))
              (standing (and (pair? rest) (car rest))))
          (when (and (pair? revoked) standing)
            (attest-event! acdc-store scope-aid standing #:signer signer)))
        (attest-event! acdc-store scope-aid event #:signer signer))))


;;; ── Plan-store credentialing: intent + commitment ACDCs ─────────────────────
;;;
;;; Installed as the ^plan-store on-intent / on-commitment callbacks. Attesting
;;; the intents/commitments makes the OPEN-intent side of the plan reconstructable
;;; AND supplies the desired quantities the credit Validation Gate needs for its
;;; satisfied-fraction — the work-event chain alone carries hours, not the intent's
;;; desired qty. Complements the work-event/skill chain (caveat 1).

(define (measure->pair m)
  (and m (cons (measure-has-numerical-value m) (measure-has-unit m))))

(define* (make-plan-credentialing-callbacks acdc-store scope-aid #:key (signer #f))
  "Return ((on-intent . proc) (on-commitment . proc)) for ^plan-store, issuing an
   intent / commitment ACDC (idempotent by SAID) as each record is added.
   SIGNER provenance-signs, but ONLY when the credential's issuer resolves to
   SCOPE-AID (the fallback case) — when the issuer is a real external
   provider/receiver AID, the scope can't sign for it (its key would fail
   verification against that AID), so those stay unsigned, same invariant as the
   N-way scope-merger."
  (list
   (cons 'on-intent
     (lambda (intent)
       (let ((iss (or (intent-provider intent) (intent-receiver intent) scope-aid)))
         ($ acdc-store 'issue-idempotent
            (let ((cred (make-intent-credential
                         iss (intent-id intent) (intent-action intent)
                         #:provider (intent-provider intent) #:receiver (intent-receiver intent)
                         #:resource-conforms-to (intent-resource-conforms-to intent)
                         #:resource-quantity (measure->pair (intent-resource-quantity intent))
                         #:effort-quantity   (measure->pair (intent-effort-quantity intent))
                         #:available-quantity (measure->pair (intent-available-quantity intent))
                         #:minimum-quantity  (measure->pair (intent-minimum-quantity intent))
                         #:due (intent-due intent) #:plan-id (intent-planned-within intent)
                         #:process-id (or (intent-input-of intent) (intent-output-of intent))
                         #:satisfies (intent-satisfies intent)
                         #:holder-aid scope-aid)))
              (if (equal? iss scope-aid) (cred-signed-by-scope cred signer) cred))))))
   (cons 'on-commitment
     (lambda (c)
       (let ((prov (or (commitment-provider c) scope-aid))
             (recv (or (commitment-receiver c) scope-aid)))
         ($ acdc-store 'issue-idempotent
            (let ((cred (make-commitment-credential
                         prov recv (commitment-id c) (commitment-action c)
                         #:resource-conforms-to (commitment-resource-conforms-to c)
                         #:resource-quantity (measure->pair (commitment-resource-quantity c))
                         #:effort-quantity   (measure->pair (commitment-effort-quantity c))
                         #:due (commitment-due c) #:plan-id (commitment-planned-within c)
                         #:process-id (or (commitment-input-of c) (commitment-output-of c))
                         #:satisfies (commitment-satisfies c))))
              (if (equal? prov scope-aid) (cred-signed-by-scope cred signer) cred))))))
   ;; on-agreement: when accept-proposal seals an Agreement, mint its ACDC —
   ;; binding the primary + reciprocal commitment ids (e.g. a socialization's
   ;; custody grant ↔ the commune's return commitment). Provenance completion.
   (cons 'on-agreement
     (lambda (agr proposal result)
       (let ((acceptor (or (assq-ref result 'accepting-agent-id) scope-aid))
             (proposer (or (assq-ref result 'counterparty) scope-aid)))
         ($ acdc-store 'issue-idempotent
            (let ((cred (make-agreement-credential
                         acceptor proposer (assq-ref result 'agreement-id)
                         #:proposal-id (assq-ref result 'proposal-id)
                         #:primary-commitment-ids    (or (assq-ref result 'primary-commitment-ids) '())
                         #:reciprocal-commitment-ids (or (assq-ref result 'reciprocal-commitment-ids) '())
                         #:accepted-at (iso-utc-now))))
              (if (equal? acceptor scope-aid) (cred-signed-by-scope cred signer) cred))))))))


;;; ── Turn it on: install the substrate into a live scope ─────────────────────

;; How many live (post-checkpoint) events a stream may hold before the next
;; commitment folds them into a checkpoint and prunes. A parameter so tests can
;; lower it; the default keeps checkpoints rare (commits are already the gate).
(define event-log-compaction-threshold (make-parameter 2000))

(define (record->list r)
  "The portable payload of a log record: an EconomicEvent, or a record the books were
   told of (an EconomicResource, a Process: observer record-resource, record-process).
   vf-serialize writes any of them."
  (economic-event->list r))

(define (replay-record! obs payload)
  "Fold one log payload into OBS silently: an event as the fold records it, a resource
   or a process record as the books hold it (no callback is set yet, so nothing
   re-issues or re-appends)."
  (let ((r (list->economic-event payload)))                 ; vf-deserialize reads any record
    (cond ((economic-resource? r) ($ obs 'seed-resource r))
          ((process? r)           ($ obs 'register-process r))
          (else                   ($ obs 'record-event r)))))

(define* (install-event-log! obs scope-aid #:key (dir #f))
  "Wire the scope's portable, SAID-chained event stream (gap #18) to observer
   OBS. On a cross-gateway restore — OBS empty, on-disk stream non-empty — fold
   the stream back into OBS BEFORE any callback is set, so the silent replay
   neither re-issues credentials nor re-appends to the log; skipped when OBS is
   already populated (same-gateway syrup restore), so it can never double-count.
   Then mirror every future record — an EconomicEvent, or a resource the books
   were told of — into the stream via the observer's `log-sink`. A scope that
   predates its log writes its events and then its resources as they stand: the
   replay lands on the same books whatever the order, for the last record of a
   resource is the resource as it stands. Returns the `^event-log-store` ref."
  (let ((elog (spawn-event-log-store scope-aid #:dir dir)))
    (cond
     ;; cross-gateway restore: the on-disk stream rebuilds a fresh observer.
     ;; If the stream was compacted, restore observer state from the checkpoint
     ;; blob first (the pruned prefix), then fold the post-checkpoint tail.
     ((and (zero? ($ obs 'event-count)) (zero? ($ obs 'resource-count)) (null? ($ obs 'all-processes))
          (> ($ elog 'seq) 0))
      (let ((blob ($ elog 'checkpoint-blob)))
        (when blob ($ obs 'load-snapshot blob)))
      ;; the stream's v1 entries hold corrections written under the older reading
      ;; (a correction that REPLACES its original): read them into the ValueFlows
      ;; form; its v2 entries are in that form already
      (for-each (lambda (e) ($ obs 'record-event e))
                (legacy-corrections->canonical (map list->economic-event ($ elog 'legacy-payloads))))
      (for-each (lambda (p) (replay-record! obs p)) ($ elog 'current-payloads)))
     ;; pre-existing scope: the observer predates the log — one-time backfill
     ;; of its history into the empty stream, so the record is complete from
     ;; the scope's first event, not just from when logging was switched on
     ((and (or (> ($ obs 'event-count) 0) (> ($ obs 'resource-count) 0) (pair? ($ obs 'all-processes)))
           (zero? ($ elog 'seq)))
      (for-each (lambda (ev) ($ elog 'append (record->list ev)))
                ($ obs 'all-events))
      (for-each (lambda (r) ($ elog 'append (record->list r)))
                (append ($ obs 'all-resources) ($ obs 'all-processes)))))
    ($ obs 'set-callback 'log-sink
       (lambda (rec) ($ elog 'append (record->list rec))))
    elog))

(define* (install-credentialing! scope-root acdc-store scope-aid
                                 #:key (event-log-dir #f) (anchor #f) (signer #f))
  "Wire the credential substrate into a live scope: the observer `on-event` hook
   (work → work-event + skill ACDCs; individually-claimable transfer → claim ACDC)
   and the plan-store `on-intent` / `on-commitment` hooks (intent + commitment
   ACDCs). The intent hook COMPOSES with the planner's own register-intent
   forwarding (the Validation Gate) — governance may call both layers. Idempotent
   (later set-on-* shadows earlier), so re-call after restoring a scope from
   persistence; restored records replay via the silent paths, so nothing
   double-issues. SCOPE-AID is the issuer; ACDC-STORE is its credential store.

   EVENT-LOG-DIR (gap #18, docs/planning/books/portable-event-log.md): when set, every
   recorded EconomicEvent also mirrors into the scope's portable, SAID-chained
   event stream under that directory. On a CROSS-GATEWAY restore the observer
   comes up empty while the on-disk stream still holds the history; we then fold
   the stream back into the observer BEFORE wiring any callback — so the silent
   replay neither re-issues credentials nor re-appends to the log. Skipped when
   the observer is already populated (same-gateway syrup restore), so the replay
   can never double-count. ANCHOR, when set, is a one-arg procedure called with
   the stream's head SAID at each commitment, to anchor it into the scope KEL
   (§4.6) — a debounced cadence (commitments, not raw stockbook draws).

   SIGNER, when set, is the scope's own ^scope ref — each issued credential is
   provenance-signed via its sign-said (cred-signed-by-scope; keypair stays in
   the actor). Omitted / keyless for synthetic/demo scopes → records issue
   unsigned as before."
  (unless signer
    (format (current-error-port)
            "[credentialing] WARNING: no #:signer for scope ~a — every \
credential issued through it will be unsigned or fall back to the gateway's \
own controller identity. Fine for a demo/synthetic scope; if this is a real \
commune, wire its own ^scope ref as #:signer before treating anything \
issued through it as authoritative.\n"
            scope-aid))
  (hash-set! *scope-acdc-stores* scope-aid acdc-store)   ; the witness door's lookup
  (let* ((obs ($ scope-root 'observer))
         (ps  ($ scope-root 'plan-store))
         (cbs (make-plan-credentialing-callbacks acdc-store scope-aid #:signer signer))
         (mint-intent (assq-ref cbs 'on-intent))
         (on-commit   (assq-ref cbs 'on-commitment))
         ;; the event log is wired FIRST: its replay-if-empty must run before
         ;; set-on-event, so a cross-gateway restore doesn't re-issue credentials
         (elog (install-event-log! obs scope-aid #:dir event-log-dir))
         (last-anchored ""))
    ($ obs 'set-on-event (make-credentialing-on-event acdc-store scope-aid #:signer signer))
    ($ ps 'set-on-intent (lambda (intent)
                           ($ obs 'register-intent intent)   ; planner Validation Gate
                           (mint-intent intent)))            ; + governance credential
    ($ ps 'set-on-commitment
       (lambda (c)
         (on-commit c)                                       ; commitment ACDC
         ;; anchor the stream head into the scope KEL once per NEW head — so
         ;; repeated commits with no events in between don't churn the KEL
         (let ((h ($ elog 'head)))
           (when (and anchor (not (string=? h "")) (not (string=? h last-anchored)))
             (set! last-anchored h)
             (anchor h)))
         ;; compaction: once the live tail outgrows the threshold, fold it into a
         ;; checkpoint carrying the observer's WRITE-SAFE state snapshot (gap #18),
         ;; prune the pruned prefix, and anchor the cut into the scope KEL
         (when (and event-log-dir
                    (> (- ($ elog 'seq) ($ elog 'checkpoint-seq))
                       (event-log-compaction-threshold)))
           (let ((ck-said ($ elog 'checkpoint ($ obs 'serialize))))
             (when anchor (anchor ck-said))
             (set! last-anchored ck-said)))))
    ;; seal the Agreement into an ACDC when accept-proposal fires (provenance)
    ($ ps 'set-on-agreement (assq-ref cbs 'on-agreement))
    elog))

;;; ── Multi-custody reconcile (gap #18 §8) ────────────────────────────────────

(define (kel-anchored-saids kel-store)
  "The SAIDs sealed into KEL-STORE's interaction events — every event-log head
   or checkpoint that has been anchored (§4.6). These are the committed points
   that fix the merge frontier."
  (append-map
   (lambda (body)
     (let ((ixn (assoc-ref body "ixn")))
       (if (not ixn) '()
           (let ((seals (assoc-ref ixn "a")))
             (filter-map (lambda (seal) (and (pair? seal) (assoc-ref seal "d")))
                         (cond ((vector? seals) (vector->list seals))
                               ((list? seals) seals)
                               (else '())))))))
   ($ kel-store 'all)))

(define (event-log-reconcile! elog-store kel-store foreign-entries)
  "Merge another custodian's FOREIGN-ENTRIES into ELOG-STORE, rebasing only the
   un-committed tail above the precise KEL-anchored frontier — so committed
   history is never reordered and no un-committed event is lost. Returns the
   resulting seq.

   This is an OFFLINE, in-trust-domain operator tool for the rare split-brain
   case (a failed-over primary returns with a divergent tail), fed by a
   file-level dir union under operator control. It is NOT a network service:
   there is deliberately no peer-served `/events` endpoint — raw events never
   leave the trust domain (they carry the plaintext stockbook + per-event
   location). Cross-domain reconciliation rides the §4.5 derived-state snapshot,
   not this. See portable-event-log.md §9–§10."
  (let ((frontier ($ elog-store 'frontier (kel-anchored-saids kel-store))))
    ($ elog-store 'merge foreign-entries frontier)))


;;; ── Offline reconstruction: replay the observer's views from the ACDC graph ─
;;;
;;; The observer is a fold over an event log; with the log living as edge-chained
;;; ACDCs, any party re-derives the same views from the records alone — no server
;;; state. work-events-for-skill walks the skill ↔ work-event edges; the two
;;; reconstructors re-compute earned-skills and practiced-hours offline.

(define (work-events-for-skill skill-cred work-event-creds)
  "The work-event creds behind SKILL-CRED: its founding event (the SAID the skill
   edges to) plus every work-event whose `skill` edge points back at it."
  (let ((skill-said (cred-said skill-cred))
        (founding (and=> (cred-edge skill-cred 'founding-event) edge-target)))
    (filter (lambda (we)
              (or (and founding (equal? (cred-said we) founding))
                  (let ((e (cred-edge we 'skill)))
                    (and e (equal? (edge-target e) skill-said)))))
            work-event-creds)))

;; Shared primitives: HELD-BY filters a cred set to one holder's live (non-revoked)
;; credentials — so revocation drops a node from EVERY aggregate; CRED-SUM folds a
;; numeric claim over a set.
(define (held-by holder creds)
  (filter (lambda (c) (and (equal? (cred-holder c) holder) (cred-live? c))) creds))
(define (cred-sum creds field)
  (fold (lambda (c acc) (+ acc (or (cred-claim c field) 0))) 0 creds))

(define (reconstruct-earned-skills worker skill-creds)
  "Skills WORKER holds, re-derived from their live skill ACDCs (≡ earned-skills)."
  (map (lambda (c) (cred-claim c 'skill)) (held-by worker skill-creds)))

(define (reconstruct-practiced-hours skill-cred work-event-creds)
  "Sum the hours of the work events behind SKILL-CRED — practiced-hours re-derived
   offline. Equals the observer's value at full satisfaction; the validated form
   joins each event's `satisfies` edge to the intent's desired qty (intent ACDCs)."
  (cred-sum (work-events-for-skill skill-cred work-event-creds) 'hours))

(define (reconstruct-claimed-hours claimant claim-creds)
  "Sum the credit CLAIMANT has drawn across their claim ACDCs (≡ ledger-claimed)."
  (cred-sum (held-by claimant claim-creds) 'labor-cost))

(define (reconstruct-credit-balance worker work-event-creds claim-creds)
  "Credit balance re-derived offline: gross (Σ hours of WORKER's work-event ACDCs)
   − claimed (Σ labor-cost of their claim ACDCs). Equals the observer's
   credit-balance at full satisfaction — BOTH halves of the ledger now reconstruct
   from the portable ACDC set, contribution and consumption symmetric."
  (- (cred-sum (held-by worker work-event-creds) 'hours)
     (reconstruct-claimed-hours worker claim-creds)))

;; The social half of a skill's standing. A work-event credential that reached
;; its witness quorum carries a multisig block — ((witness-aid . sig) …) — so
;; the people who co-signed a worker's practice are read straight off the
;; records. Grouped by the skill the work conforms to, that is how far each
;; skill has been validated by others: how many events, how many of them
;; witnessed, by how many distinct people, over how many hours.
(define (cred-attesters c)
  "The AIDs that co-signed C: the keys of its multisig block, '() for a
   single-signer credential."
  (let ((sig (cred-signature c)))
    (if (pair? sig) (map car (filter pair? sig)) '())))

(define (reconstruct-skill-attestation worker work-event-creds)
  "WORKER's work-event ACDCs folded per skill →
   ((skill . ((events . n) (witnessed . n) (attesters . n) (witnessed-hours . h))) …).
   A witness counts once per skill however many events they co-signed; the
   worker's own signature never counts."
  (let ((by-skill '()))
    (for-each
     (lambda (we)
       (let* ((skill (cred-claim we 'resource-conforms-to))
              (who   (delete worker (cred-attesters we)))
              (row   (or (assoc-ref by-skill skill) '(0 0 () 0))))
         (when skill
           (set! by-skill
                 (assoc-set! by-skill skill
                             (list (+ 1 (car row))
                                   (+ (cadr row) (if (pair? who) 1 0))
                                   (lset-union equal? (caddr row) who)
                                   (+ (cadddr row)
                                      (if (pair? who) (or (cred-claim we 'hours) 0) 0))))))))
     (held-by worker work-event-creds))
    (map (lambda (p)
           (let ((row (cdr p)))
             (cons (car p)
                   `((events . ,(car row))
                     (witnessed . ,(cadr row))
                     (attesters . ,(length (caddr row)))
                     (witnessed-hours . ,(cadddr row))))))
         by-skill)))

(define (skill-attestation-standing acdc-store worker . more-stores)
  "reconstruct-skill-attestation over a live store's work-event credentials —
   and over MORE-STORES': work is witnessed in the scope it was done in, and a
   person's standing is the record across all of them, a credential told to two
   stores standing once by its SAID."
  (reconstruct-skill-attestation
   worker
   (delete-duplicates
    (append-map (lambda (st) (non-revoked-by-schema st *schema-playnet-work-event*))
                (delete-duplicates (cons acdc-store more-stores) eq?))
    (lambda (a b) (equal? (cred-said a) (cred-said b))))))


;;; ── Completeness anchor: derived-state snapshots ────────────────────────────
;;;
;;; Cryptographic chains prove what EXISTS, not that nothing is missing. A
;;; derived-state-snapshot ACDC edges (NI2I) to every input it covers, so a party
;;; holding the snapshot + the inputs can confirm they have the COMPLETE expected
;;; set, not merely a valid subset. `snapshot-over` crystallizes one across a
;;; store; `snapshot-missing` is the verifier — '() means you hold everything the
;;; auditor enumerated (caveat 3).

(define (snapshot-input-saids snapshot-cred)
  "The input SAIDs a derived-state snapshot edges to — the expected set."
  (filter-map (lambda (e) (edge-target (cdr e))) (cred-edges snapshot-cred)))

(define (snapshot-missing snapshot-cred held-creds)
  "SAIDs the snapshot expects that are absent from HELD-CREDS — '() ⇒ complete."
  (let ((have (map cred-said held-creds)))
    (filter (lambda (said) (not (member said have)))
            (snapshot-input-saids snapshot-cred))))

(define (snapshot-complete? snapshot-cred held-creds)
  "True iff HELD-CREDS contains every input the snapshot enumerates."
  (null? (snapshot-missing snapshot-cred held-creds)))

(define* (snapshot-over acdc-store auditor-aid scope-aid schemas snapshot-data
                        #:key (snapshot-at #f))
  "Crystallize a completeness anchor over ACDC-STORE: a derived-state-snapshot
   edging to every non-revoked credential of SCHEMAS (the expected set), carrying
   SNAPSHOT-DATA. Returns the snapshot credential — issue it to publish."
  (let ((saids (map cred-said
                    (append-map (lambda (s)
                                  (filter (lambda (c) (not (cred-revoked? c)))
                                          ($ acdc-store 'by-schema s)))
                                schemas))))
    (make-derived-state-snapshot-credential auditor-aid scope-aid snapshot-data
      #:input-saids saids #:snapshot-at snapshot-at)))

;; Which credential store witnesses a scope: filled by install-credentialing!
;; (the one place that holds both), read by the service's witness door — the
;; planner scope-root never learns what an acdc-store is.
(define *scope-acdc-stores* (make-hash-table))   ; scope-aid → acdc-store ref
(define (scope-acdc-store scope-aid) (hash-ref *scope-acdc-stores* scope-aid #f))
