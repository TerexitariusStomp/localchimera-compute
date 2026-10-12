;;; plan/store.scm — Goblins actor for the VF planning layer
;;;
;;; Translated from src/lib/planning/planning.ts (PlanStore)
;;; State: 10 hashmaps (plans, commitments, intents, claims, agreements,
;;;        agreement-bundles, proposals, proposal-lists, scenarios,
;;;        scenario-definitions) + signal metadata + secondary indexes.

(define-module (playnet plan store)
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet vf facts agent-tags) #:select (tag-values))
  #:use-module (playnet utils store-utils)
  #:use-module (playnet vf serdes)
  #:use-module (playnet algorithms propagation)
  #:use-module (playnet algorithms signals)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet utils clock) #:select (days->seconds civil->instant instant->unix (now . clock-now) window-close-epoch))
  #:re-export (window-close-epoch)
  #:use-module (goblins)
  #:export (<plan-store-state> make-plan-store-state plan-store-state? pss-plans
            pss-commitments pss-intents pss-claims pss-agreements
            pss-agreement-bundles pss-proposals pss-proposal-lists pss-scenarios
            pss-scenario-definitions pss-meta pss-tag-index pss-intents-by-spec
            pss-commitments-by-spec pss-intents-by-plan pss-commitments-by-plan
            pss-commitments-by-process empty-plan-store-state pss-update
            pss-with-intents pss-with-commitments append-to-index remove-from-index
            index-intent-tags index-intent-spec index-commitment-spec
            serialize-plan-store-state rebuild-plan-indexes
            deserialize-plan-store-state pss-add-plan pss-add-commitment
            pss-add-agreement pss-set-commitment-clause-of pss-promote-intent
            validate-proposal-acceptance! fold-promotions
            offer-rows offer-window-expired?
            intent-window-passed? proposal-stands?
            standing-accepts dated-facts rate-of how-commitments-end
            ^plan-store plan-store-env)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 match))


;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Plan store state record (bundles all maps for clean bcom)
;; =========================================================================

(define-record-type <plan-store-state>
  (make-plan-store-state plans commitments intents claims
                         agreements agreement-bundles
                         proposals proposal-lists
                         scenarios scenario-definitions
                         meta
                         ;; secondary indexes (hashmap of key -> list of IDs)
                         tag-index intents-by-spec commitments-by-spec
                         intents-by-plan commitments-by-plan
                         commitments-by-process)
  plan-store-state?
  (plans               pss-plans)
  (commitments         pss-commitments)
  (intents             pss-intents)
  (claims              pss-claims)
  (agreements          pss-agreements)
  (agreement-bundles   pss-agreement-bundles)
  (proposals           pss-proposals)
  (proposal-lists      pss-proposal-lists)
  (scenarios           pss-scenarios)
  (scenario-definitions pss-scenario-definitions)
  (meta                pss-meta)
  (tag-index           pss-tag-index)
  (intents-by-spec     pss-intents-by-spec)
  (commitments-by-spec pss-commitments-by-spec)
  (intents-by-plan     pss-intents-by-plan)
  (commitments-by-plan pss-commitments-by-plan)
  (commitments-by-process pss-commitments-by-process))

(define (empty-plan-store-state)
  (make-plan-store-state
    (hashmap) (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap)))

;; Functional record-update: copy the state, overriding only the named fields.
;; Replaces the hand-written 17-arg reconstruction at every update site — each only
;; ever changes a few fields, so the rest threading through by hand was pure noise
;; (and an easy place for a passed-through field to get mistyped — e.g. the old
;; pss-with-* helpers re-serialized proposal-lists in place; #:proposal-lists is
;; simply left untouched here).
(define* (pss-update st #:key
           (plans (pss-plans st)) (commitments (pss-commitments st))
           (intents (pss-intents st)) (claims (pss-claims st))
           (agreements (pss-agreements st)) (agreement-bundles (pss-agreement-bundles st))
           (proposals (pss-proposals st)) (proposal-lists (pss-proposal-lists st))
           (scenarios (pss-scenarios st)) (scenario-definitions (pss-scenario-definitions st))
           (meta (pss-meta st))
           (tag-index (pss-tag-index st)) (intents-by-spec (pss-intents-by-spec st))
           (commitments-by-spec (pss-commitments-by-spec st))
           (intents-by-plan (pss-intents-by-plan st)) (commitments-by-plan (pss-commitments-by-plan st))
           (commitments-by-process (pss-commitments-by-process st)))
  (make-plan-store-state plans commitments intents claims
                         agreements agreement-bundles proposals proposal-lists
                         scenarios scenario-definitions meta
                         tag-index intents-by-spec commitments-by-spec
                         intents-by-plan commitments-by-plan commitments-by-process))

(define (pss-with-intents st new-intents) (pss-update st #:intents new-intents))
(define (pss-with-commitments st new-commitments) (pss-update st #:commitments new-commitments))


;; =========================================================================
;; Index maintenance helpers
;; =========================================================================

(define (append-to-index idx key val)
  "Append val to the list stored at key."
  (hashmap-set idx key (cons val (hashmap-ref idx key '()))))

(define (remove-from-index idx key val)
  "Remove val from the list at key."
  (let ((lst (hashmap-ref idx key '())))
    (hashmap-set idx key (delete val lst))))

(define (index-intent-tags tag-index intent)
  "Add intent to tag index for each of its resourceClassifiedAs tags."
  (let ((tags (or (intent-resource-classified-as intent) '()))
        (iid (intent-id intent)))
    (fold (lambda (tag idx) (append-to-index idx tag iid))
          tag-index tags)))

(define (index-intent-spec ibs intent)
  "Add intent to spec index."
  (let ((spec (intent-resource-conforms-to intent)))
    (if spec (append-to-index ibs spec (intent-id intent)) ibs)))

(define (index-commitment-spec cbs commitment)
  "Add commitment to spec index."
  (let ((spec (commitment-resource-conforms-to commitment)))
    (if spec (append-to-index cbs spec (commitment-id commitment)) cbs)))


;; =========================================================================
;; Record <-> list serialization for persistence
;; =========================================================================
;;
;; All per-type `X->list` / `list->X*` pairs have been replaced by
;; `vf-serialize` / `vf-deserialize` from utils/serdes.scm, which uses
;; the record-type registry (schemas.scm define-vf-record registers each type) to introspect
;; fields automatically.
;;
;; The legacy Measure helpers sm/dm and the per-type pairs that were here
;; previously are no longer needed — vf-serialize recurses into nested
;; records (including <measure>, <availability-window>, etc.) and the
;; self-describing (@vf TypeName fields) wire format handles field
;; reordering and new-field addition without breaking old data.
;;
;; Backwards-compatibility: vf-deserialize falls through for plain pairs
;; and alists, so scenarios/scenario-definitions stored as alists (the
;; add-scenario convention) round-trip correctly without a special case.


;; =========================================================================
;; Serialize / deserialize full plan-store-state
;; =========================================================================

(define (serialize-plan-store-state st)
  (list (serialize-hashmap (pss-plans st) vf-serialize)
        (serialize-hashmap (pss-commitments st) vf-serialize)
        (serialize-hashmap (pss-intents st) vf-serialize)
        (serialize-hashmap (pss-claims st) vf-serialize)
        (serialize-hashmap (pss-agreements st) vf-serialize)
        ;; Note: indexes not serialized — rebuilt from data on restore
        (serialize-hashmap (pss-agreement-bundles st) vf-serialize)
        (serialize-hashmap (pss-proposals st) vf-serialize)
        (serialize-hashmap (pss-proposal-lists st) vf-serialize)
        (serialize-hashmap (pss-scenarios st) vf-serialize)
        (serialize-hashmap (pss-scenario-definitions st) vf-serialize)
        (pss-meta st)  ;; alist-based metadata
        (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))

;; Rebuild the secondary indexes that serialize-plan-store-state deliberately drops
;; (they are derivable from the data). → (values intents-by-plan commitments-by-plan
;; commitments-by-process), the last keyed by BOTH a commitment's input-of and
;; output-of process. All three are the append-to-index pattern over the records.
(define (rebuild-plan-indexes d-intents d-commitments)
  (values
    (hashmap-fold (lambda (_id i acc)
                    (let ((pw (intent-planned-within i)))
                      (if pw (append-to-index acc pw (intent-id i)) acc)))
                  (hashmap) d-intents)
    (hashmap-fold (lambda (_id c acc)
                    (let ((pw (commitment-planned-within c)))
                      (if pw (append-to-index acc pw (commitment-id c)) acc)))
                  (hashmap) d-commitments)
    (hashmap-fold (lambda (_id c acc)
                    (let* ((cid (commitment-id c))
                           (a1 (if (commitment-input-of c)  (append-to-index acc (commitment-input-of c) cid) acc))
                           (a2 (if (commitment-output-of c) (append-to-index a1 (commitment-output-of c) cid) a1)))
                      a2))
                  (hashmap) d-commitments)))

(define (deserialize-plan-store-state data)
  (match data
    ((sp sc si scl sa sab sprop spl sscen ssd smeta
      stag sibs scbs . _rest)
     (let*-values (((d-intents) (deserialize-hashmap si vf-deserialize))
                   ((d-commitments) (deserialize-hashmap sc vf-deserialize))
                   ((ibp cbpl cbpr) (rebuild-plan-indexes d-intents d-commitments)))
       (make-plan-store-state
         (deserialize-hashmap sp vf-deserialize)
         d-commitments d-intents
         (deserialize-hashmap scl vf-deserialize)
         (deserialize-hashmap sa vf-deserialize)
         (deserialize-hashmap sab vf-deserialize)
         (deserialize-hashmap sprop vf-deserialize)
         (deserialize-hashmap spl vf-deserialize)
         (deserialize-hashmap sscen vf-deserialize)
         (deserialize-hashmap ssd vf-deserialize)
         smeta stag sibs scbs ibp cbpl cbpr)))))


;; =========================================================================
;; Pure state transforms (Goblins #256 workaround)
;; Actors with #:self can't persist. These let methods compose multiple
;; state changes via (values new-st id) — single bcom at the end.
;; =========================================================================

(define (pss-add-plan st plan)
  (let* ((id (or (plan-id plan) (generate-id "plan-")))
         (ps (hashmap-set (pss-plans st) id plan)))
    (values (pss-update st #:plans ps) id)))

(define (pss-add-commitment st c)
  (let* ((id (or (commitment-id c) (generate-id "commit-")))
         (cs (hashmap-set (pss-commitments st) id c))
         (cbs (index-commitment-spec (pss-commitments-by-spec st) c))
         (cbpl (let ((pw (commitment-planned-within c)))
                 (if pw (append-to-index (pss-commitments-by-plan st) pw id)
                     (pss-commitments-by-plan st))))
         (cbpr (let* ((s0 (pss-commitments-by-process st))
                      (s1 (if (commitment-input-of c)
                              (append-to-index s0 (commitment-input-of c) id) s0))
                      (s2 (if (commitment-output-of c)
                              (append-to-index s1 (commitment-output-of c) id) s1)))
                 s2)))
    (values (pss-update st #:commitments cs #:commitments-by-spec cbs
                        #:commitments-by-plan cbpl #:commitments-by-process cbpr)
            id)))

(define (pss-add-agreement st agr)
  (let* ((id (agreement-id agr))
         (as (hashmap-set (pss-agreements st) id agr)))
    (values (pss-update st #:agreements as) id)))

(define (pss-set-commitment-clause-of st cid agr-id)
  "Set clause-of (agreement back-reference) on an existing commitment.
   Indexes key on fields (spec, plan, process) that don't change, so
   they pass through. Unknown CID is a no-op."
  (let ((c (hashmap-ref (pss-commitments st) cid #f)))
    (cond
      ((not c) st)
      (else
       (pss-with-commitments
         st
         (hashmap-set (pss-commitments st) cid
           (copy-commitment c #:clause-of agr-id)))))))

(define (pss-promote-intent st iid counterparty)
  "Promote intent→commitment. Returns (values new-st cid)."
  (let* ((it (hashmap-ref (pss-intents st) iid #f)))
    (unless it (error (format #f "Intent ~a not found" iid)))
    ;; a FINISHED intent has nothing left to promote — without this check a
    ;; re-accept minted a duplicate commitment (fresh commit- id every call)
    ;; and decremented the intent's available quantity a second time. A
    ;; STANDING order (an availability-window keeps the intent unfinished by
    ;; design — declare-need's docstring) remains re-promotable, exactly as
    ;; before.
    (when (intent-finished it)
      (error (format #f "Intent ~a is already fully committed" iid)))
    (let* ((prov (or (intent-provider it) (assq-ref counterparty 'provider)))
           (recv (or (intent-receiver it) (assq-ref counterparty 'receiver))))
      (unless (and prov recv) (error "Cannot promote: need both provider and receiver"))
      (let ((cq (if (intent-resource-quantity it) (measure-has-numerical-value (intent-resource-quantity it)) 0))
            (mq (if (intent-minimum-quantity it) (measure-has-numerical-value (intent-minimum-quantity it)) 0))
            (aq (if (intent-available-quantity it) (measure-has-numerical-value (intent-available-quantity it)) +inf.0)))
        (when (< cq mq) (error (format #f "Committed qty ~a < minimum ~a" cq mq)))
        (when (> cq aq) (error (format #f "Committed qty ~a > available ~a" cq aq))))
      (let* ((cid (generate-id "commit-"))
             (c (intent->commitment it cid prov recv))
             (cq (if (intent-resource-quantity it) (measure-has-numerical-value (intent-resource-quantity it)) 0))
             (oa (if (intent-available-quantity it) (measure-has-numerical-value (intent-available-quantity it)) #f))
             (na (and oa (max 0 (- oa cq))))
             (nam (and na (intent-resource-quantity it)
                       (make-measure na (measure-has-unit (intent-resource-quantity it)))))
             (fin? (and (not (intent-availability-window it)) (or (not na) (<= na 0))))
             (upd (if (or fin? nam)
                      (copy-intent it
                        #:available-quantity (or nam (intent-available-quantity it))
                        #:finished fin?)
                      it))
             (nis (hashmap-set (pss-intents st) iid upd))
             (ncs (hashmap-set (pss-commitments st) cid c))
             (ncbs (index-commitment-spec (pss-commitments-by-spec st) c))
             (ncbpl (let ((pw (commitment-planned-within c)))
                      (if pw (append-to-index (pss-commitments-by-plan st) pw cid)
                          (pss-commitments-by-plan st))))
             (ncbpr (let* ((s0 (pss-commitments-by-process st))
                           (s1 (if (commitment-input-of c) (append-to-index s0 (commitment-input-of c) cid) s0))
                           (s2 (if (commitment-output-of c) (append-to-index s1 (commitment-output-of c) cid) s1)))
                      s2)))
        (values (pss-update st #:commitments ncs #:intents nis #:commitments-by-spec ncbs
                            #:commitments-by-plan ncbpl #:commitments-by-process ncbpr)
                cid)))))

(define (validate-proposal-acceptance! proposal proposal-id accepting-aid verify-with)
  "Enforce the proposal's temporal window, the `proposed-to` whitelist,
   and an optional KERI/sealed verify-with predicate. Raises on any
   violation. Returns #t on success."
  (let ((now (number->string (instant->unix (clock-now)))))
    (when (and (proposal-has-end proposal)
               (string>? now (proposal-has-end proposal)))
      (error "Proposal expired"))
    (when (and (proposal-has-beginning proposal)
               (string<? now (proposal-has-beginning proposal)))
      (error "Proposal not yet open")))
  (when (and (proposal-proposed-to proposal)
             (pair? (proposal-proposed-to proposal)))
    (unless (and accepting-aid
                 (member accepting-aid (proposal-proposed-to proposal)))
      (error "Not authorized to accept this proposal")))
  (when verify-with
    (unless (verify-with accepting-aid proposal-id)
      (error "accept-proposal: verify-with rejected caller"
             accepting-aid proposal-id)))
  #t)

(define (fold-promotions st intent-ids counterparty)
  "Thread state through N promote calls. Returns (cons final-st cid-list)."
  (let loop ((ids intent-ids) (s st) (cids '()))
    (if (null? ids) (cons s (reverse cids))
        (let-values (((ns cid) (pss-promote-intent s (car ids) counterparty)))
          (loop (cdr ids) ns (cons cid cids))))))

;; ── the offer enumeration both live rungs read ──────────────────────────────
;; (commitment-horizon.md, the bounded rung.) ((proposal . intent) …) for
;; every 'offer proposal publishing a work intent that is still an intent
;; (unaccepted). The ONE enumeration behind live.scm's hold compile and
;; uc-matching's tentative bookings. Expiry is the caller's cut
;; (offer-window-expired?) — the urgency-lapse sweep needs to SEE the
;; expired rows it names. A store without proposals has no offers.
(define (offer-rows plan-store)
  (filter-map
   (lambda (p)
     (and (eq? (proposal-purpose p) 'offer)
          (pair? (proposal-publishes p))
          (let ((it (false-if-exception
                     ($ plan-store 'get-intent (car (proposal-publishes p))))))
            (and it (eq? (intent-action it) 'work)
                 (not (intent-finished it))
                 (cons p it)))))
   (or (false-if-exception ($ plan-store 'all-proposals)) '())))

;; ── the standing accepts: the one enumeration, offer-rows' twin ────────────
;; Unfinished WORK commitments — the decided rung as the store holds it.
;; Behind the pins compile (accepts.scm), the deployment seed
;; (uc-matching.scm) and the presentation's already-accepted check
;; (offers.scm), so "what is accepted" is answered in one place. Material
;; (produce) accepts ride the pins compile's own produce arm.
(define* (standing-accepts plan-store #:optional (at #f))
  "The accepts that still STAND, by each commitment's own terms: work,
   unfinished, and its window — where it names one — not yet closed.
   Derived at the read, so the pins compile never depends on the expire
   sweep having run first; the sweep only DATES the fact on the rail."
  (let ((nowu (or at (instant->unix (clock-now)))))
    (filter (lambda (c)
              (and (eq? (commitment-action c) 'work)
                   (not (commitment-finished c))
                   (let ((u (window-close-epoch (commitment-has-end c))))
                     (or (not u) (> u nowu)))))
            (or (false-if-exception ($ plan-store 'all-commitments)) '()))))

;; has the proposal's acceptance window closed at NOW (unix seconds)?
;; The window rides has-end as an epoch string — the same clock
;; convention validate-proposal-acceptance! compares against.
(define (offer-window-expired? p now)
  (let ((e (proposal-has-end p)))
    (and e (> now (or (string->number e) 0)))))

;; ── standing, derived from a record's OWN terms at the read ────────────────
;; The store's one temporal law, stated once: a timed boundary ("…T17:00")
;; closes at its minute, a bare date at the END of its day. Every reader that
;; asks "does this still stand?" derives the answer from the record's own
;; window through these — a sweep (expire-commitments, the lapse door) only
;; DATES the fact on the rail, it is never what makes the answer true. That
;; is what keeps a wire read honest between sweeps: yesterday's offer is dead
;; on the wire the moment its window passes, whether or not a solve ran.
;; window-close-epoch itself lives on the one clock — (playnet utils clock) —
;; and is re-exported here, so credential liveness reads the same law.

(define (intent-window-passed? i now)
  "Has this intent's own window wholly passed? An intent with no end stands —
   that is what makes an undated need standing."
  (let ((u (window-close-epoch (intent-has-end i))))
    (and u (> now u))))

(define (proposal-stands? p plan-store now)
  "Does this proposal still ASK anything? By its own terms: its acceptance
   window (has-end) not passed, and its published intent — where it has one —
   still an intent (unfinished) with its own window open. A proposal record
   outliving its question is history, and history rides the meta rail, not
   the wire."
  (and (not (offer-window-expired? p now))
       (let ((pubs (proposal-publishes p)))
         (or (not (pair? pubs))
             (let ((it (false-if-exception ($ plan-store 'get-intent (car pubs)))))
               (and it (not (intent-finished it))
                    (not (intent-window-passed? it now))))))))

;; ── dated facts: the store's own ledger of what happened, when ─────────────
;; Everything the drift question reads is ONE shape on the meta rail —
;; <id> → ((KEY . kind) (at . t)) — written by one procedure, note-fact:
;;   declared   "decl:<intent-id>:<t>"  added | removed    (a declaration change)
;;   lapsed     <proposal-id>           offer-lapsed | offer-infeasible
;;   ended      <commitment-id>         released | fulfilled | expired
;; so every rate is ONE read over one source on one clock — rate-of — and no
;; meter, no listener, no coverage accounting stands between the facts and
;; the number. A declaration keys by (id . time) because one intent may be
;; declared and withdrawn many times and each is an event; a lapse and an
;; ending key by the record, which ends once.
(define (note-fact meta id key kind at)
  (hashmap-set meta id `((,key . ,kind) (at . ,at))))
(define (note-declaration meta id action)
  ;; keyed by id, time AND action: an add and a withdrawal in the same second
  ;; are two events, and the ledger must hold both
  (let ((t (instant->unix (clock-now))))
    (note-fact meta (string-append "decl:" id ":" (number->string t) ":" (symbol->string action))
               'declared action t)))

(define (dated-facts plan-store key since until)
  "The meta rows carrying KEY whose `at` lies in [SINCE, UNTIL] (unix) — the
   store's own facts-since read, so the filter runs beside the rows. A
   window has two edges, and the signature says so: an epoch that ended
   must not count what happened after it."
  (or (false-if-exception ($ plan-store 'facts-since key since until)) '()))

(define (rate-of plan-store key now window-days)
  "Events carrying KEY per day over the WINDOW-DAYS ending at NOW —
   declarations ('declared), lapses ('lapsed), endings ('ended), all off
   the same rail on the same clock."
  (/ (length (dated-facts plan-store key (- now (days->seconds window-days)) now))
     window-days))

;; how the commitments ENDED over the window, by kind: a commitment leaves
;; the decided rung three ways — released (a person withdrew), fulfilled
;; (the work was done), expired (its window closed unworked) — and each is
;; one dated fact <commitment-id> → ((ended . kind) (at . t)), written by
;; the store's own end-commitment door. → ((released . n) (fulfilled . n)
;; (expired . n)), counts over the window.
(define (how-commitments-end plan-store now window-days)
  (let ((facts (dated-facts plan-store 'ended (- now (days->seconds window-days)) now)))
    (map (lambda (kind)
           (cons kind (count (lambda (kv) (eq? kind (assq-ref (cdr kv) 'ended))) facts)))
         '(released fulfilled expired))))

;; a lapse ENDS the offer the way an expiry ends an accept: the store's
;; lapse-offer door finishes the published intent (so offer-rows, and every
;; reader behind it, drops the offer BY STATE — no reader subtracts a lapse
;; by hand) and dates the fact under the proposal's id for the drift read.
;; Re-presenting the slot removes and re-adds the intent, unfinished: a
;; fresh offer is a fresh hold, and the old fact is overwritten when it
;; lapses again. The alert rail only announces.

;; ── the fresh-check door (commitment-horizon.md, certification) ─────────────
;; A held offer's wall rode every re-solve, so its accept is certified by
;; the current solve. An accept whose intent NO open offer publishes was
;; never held — nothing certified it — and today's guard is the NEXT
;; solve's raise: loud but late. The `fresh-check` callback (installed by
;; the service: a trial solve with the candidate pinned) refuses such an
;; accept AT the door instead. Verdict protocol as the gate's: #t passes,
;; a string names the refusal. Only work intents are checked; held ones
;; skip. A lapsed hold no longer holds — its intent is finished, and a
;; finished intent is never asked about here (fresh-check! reads the
;; unfinished ones only), so state answers and no lapse fact is consulted.
(define (held-intent? st iid now)
  (any (lambda (p) (and (eq? (proposal-purpose p) 'offer)
                        (member iid (or (proposal-publishes p) '()))
                        (not (offer-window-expired? p now))))
       (hashmap-values (pss-proposals st))))

(define (fresh-check! callbacks st iids)
  (let ((check (assq-ref callbacks 'fresh-check)))
    (when check
      (let ((nowu (instant->unix (clock-now))))
        (for-each
         (lambda (iid)
           (let ((it (hashmap-ref (pss-intents st) iid #f)))
             (when (and it (eq? (intent-action it) 'work)
                        (not (held-intent? st iid nowu)))
               (let ((verdict (check it)))
                 (unless (eq? verdict #t)
                   (error "accept refused by the fresh feasibility check" iid verdict))))))
         iids)))))

;; The commitment-horizon gate (docs/planning/solve/commitment-horizon.md): the
;; standing `gate-accept` callback, consulted at BOTH accept doors —
;; promote-to-commitment and accept-proposal — over every intent an
;; acceptance would promote. Verdict #t passes; a string names the refusal
;; and the door raises with it: an accept is refused loudly, never
;; silently trimmed. GATE may be #f (no gate installed) — then every
;; intent passes.
(define (gate-intents! gate intents iids)
  (when gate
    (for-each
     (lambda (iid)
       (let* ((it (hashmap-ref intents iid #f))
              (verdict (if it (gate it) #t)))
         (unless (eq? verdict #t)
           (error "accept refused by the commitment-horizon gate" iid verdict))))
     iids)))


;; =========================================================================
;; ^plan-store — persistent Goblins actor
;; =========================================================================

(define-actor (^plan-store bcom st callbacks)
  ;; st:        <plan-store-state>
  ;; callbacks: alist of (KEY . PROC) where KEY is 'on-commitment,
  ;;            'on-intent / 'on-intent-change, 'on-plan, 'on-agreement (and any future
  ;;            emission hook). Each PROC is (lambda (…) → unit). The
  ;;            alist is opaque to the planner; callbacks encapsulate
  ;;            ACDC emission and observer forwarding so the planner
  ;;            stays oblivious to credential schemas and gate state.
  ;;
  ;; Callback signatures:
  ;;   on-commitment: (proc commitment-record)
  ;;   on-intent-change: (proc intent-record action) — 'added | 'removed.
  ;;                  THE intent channel, and the one key that FANS OUT: a
  ;;                  store legitimately has several readers of change (a
  ;;                  credential minter, the observer's mirror, an aggregate
  ;;                  folding it), so every entry under this key is notified
  ;;                  and `add-intent-listener` appends rather than shadows.
  ;;                  A single-valued key keeps `set-callback`'s shadowing.
  ;;                  `set-on-intent` is sugar: it registers a listener
  ;;                  FILTERED to arrivals, so a caller that only cares that an
  ;;                  intent came into being writes no action guard and there is
  ;;                  still exactly one emission.
  ;;   on-plan:       (proc plan-record) — fires when a plan is added.
  ;;                  Used by scope-root to forward to the observer's
  ;;                  confirm-plan, so the leaf implicitly endorses
  ;;                  its own plans (§III.1 federation stratification).
  ;;   on-agreement:  (proc agreement proposal result-alist)
  ;;                  where RESULT-ALIST carries 'proposal-id,
  ;;                  'primary-commitment-ids, 'reciprocal-commitment-ids,
  ;;                  'counterparty, 'accepting-agent-id.

  #:portrait
  (lambda () (list (serialize-plan-store-state st)))

  #:version 3

  #:restore
  (lambda (version . args)
    ;; Callbacks aren't serializable; restore with an empty alist and
    ;; let the gateway re-bind via set-on-* after recovery.
    (case version
      ((1 2 3)
       (spawn ^plan-store (deserialize-plan-store-state (car args)) '()))
      (else (error "Unknown ^plan-store version" version))))

  ;; Shadow callback slots as ordinary names so the method bodies can
  ;; reference `on-commitment` / `emit-intent!` / `on-agreement` directly
  ;; without repeating the lookup. Re-evaluated each time the actor
  ;; respawns with an updated callbacks alist.
  (let* ((on-commitment (assq-ref callbacks 'on-commitment))
         (on-plan       (assq-ref callbacks 'on-plan))
         (on-agreement  (assq-ref callbacks 'on-agreement))
         ;; Every listener on the intent channel, in registration order. The
         ;; two keys are ONE channel read two ways, and what `on-intent` means
         ;; is defined HERE — once — so it means the same thing however it was
         ;; registered: through `set-on-intent`, or in an alist handed straight
         ;; to the constructor (observation/credentials and the scope wiring both build one).
         (intent-listeners
          (filter-map
           (lambda (p)
             (case (car p)
               ;; the channel itself: (intent action)
               ((on-intent-change) (cdr p))
               ;; "an intent came into being" — the channel, filtered to
               ;; arrivals, so such a listener never mints from a withdrawal
               ((on-intent) (let ((f (cdr p)))
                              (lambda (intent action)
                                (when (eq? action 'added) (f intent)))))
               (else #f)))
           callbacks))
         ;; ONE emission point for everything that happens to an intent. What
         ;; the listener is handed is the record AND what happened to it — the
         ;; observer's discipline (observer.scm: on-event carries the event and
         ;; its affected resources), and for the same reason: a listener must be
         ;; able to fold the change without reading the store, because this
         ;; fires from inside the write, before the new state is committed.
         (emit-intent! (lambda (intent action)
                         (for-each (lambda (f) (f intent action)) intent-listeners)))
         ;; a commitment leaving the decided rung, whichever way — the body
         ;; behind end-commitment and release-commitment alike
         (end-commitment!
          (lambda (cid kind at aid)
            (let ((c (hashmap-ref (pss-commitments st) cid #f)))
              (unless c (error "end-commitment: no such commitment" cid))
              (unless (memq kind '(released fulfilled expired failed))   ; failed: the provider could not (economy/payouts.scm)
                (error "end-commitment: an ending kind the store does not know" kind))
              (when (commitment-finished c)
                (error "end-commitment: the commitment is already finished" cid))
              (when (eq? kind 'released)
                (unless (and aid (equal? aid (commitment-provider c)))
                  (error "end-commitment: only the provider releases their own accept" cid aid)))
              (bcom (^plan-store bcom
                      (pss-update st
                        #:commitments (hashmap-set (pss-commitments st) cid
                                                   (copy-commitment c #:finished #t))
                        #:meta (note-fact (pss-meta st) cid 'ended kind at))
                      callbacks)
                    cid)))))

  (methods

    ;; --- Plans ---

    ((add-plan plan)
     (let-values (((new-st id) (pss-add-plan st plan)))
       (when on-plan
         (on-plan (hashmap-ref (pss-plans new-st) id)))
       (bcom (^plan-store bcom new-st callbacks) id)))

    ((add-plan-silent plan)
     ;; Recovery path: skip on-plan callback to avoid double-confirming
     ;; a plan that was already endorsed and persisted.
     (let-values (((new-st id) (pss-add-plan st plan)))
       (bcom (^plan-store bcom new-st callbacks) id)))

    ((get-plan id) (hashmap-ref (pss-plans st) id #f))
    ((all-plans)   (hashmap-values (pss-plans st)))

    ;; --- Intents ---

    ((add-intent intent)
     ;; VF rule: provider OR receiver, not both
     (when (and (intent-provider intent) (intent-receiver intent))
       (error "VF constraint: Intent cannot have both provider and receiver"))
     (let* ((id (or (intent-id intent) (generate-id "intent-")))
            (new-intents (hashmap-set (pss-intents st) id intent))
            (new-tag-idx (index-intent-tags (pss-tag-index st) intent))
            (new-ibs (index-intent-spec (pss-intents-by-spec st) intent))
            ;; Maintain intents-by-plan index
            (new-ibp (let ((pw (intent-planned-within intent)))
                       (if pw (append-to-index (pss-intents-by-plan st) pw id)
                           (pss-intents-by-plan st)))))
       (emit-intent! (hashmap-ref new-intents id) 'added)
       (bcom (^plan-store bcom
               (pss-update st #:intents new-intents #:tag-index new-tag-idx
                           #:intents-by-spec new-ibs #:intents-by-plan new-ibp
                           #:meta (note-declaration (pss-meta st) id 'added)) callbacks)
             id)))

    ((add-intent-silent intent)
     ;; Recovery path: skip on-intent callback to avoid re-emission.
     (when (and (intent-provider intent) (intent-receiver intent))
       (error "VF constraint: Intent cannot have both provider and receiver"))
     (let* ((id (or (intent-id intent) (generate-id "intent-")))
            (new-intents (hashmap-set (pss-intents st) id intent))
            (new-tag-idx (index-intent-tags (pss-tag-index st) intent))
            (new-ibs (index-intent-spec (pss-intents-by-spec st) intent))
            (new-ibp (let ((pw (intent-planned-within intent)))
                       (if pw (append-to-index (pss-intents-by-plan st) pw id)
                           (pss-intents-by-plan st)))))
       (bcom (^plan-store bcom
               (pss-update st #:intents new-intents #:tag-index new-tag-idx
                           #:intents-by-spec new-ibs #:intents-by-plan new-ibp) callbacks)
             id)))

    ((get-intent id)  (hashmap-ref (pss-intents st) id #f))
    ((all-intents)    (hashmap-values (pss-intents st)))

    ;; Drop an intent from the main map. The by-plan/spec/tag indexes keep the
    ;; dead id, but every reader resolves ids through (pss-intents …) with a #f
    ;; fallback (filter-map / hashmap-ref), so a dangling index entry is inert.
    ;; Used to clear ephemeral materialized (mi|…) intents before re-persisting.
    ((remove-intent id)
     ;; A withdrawal travels the same channel as a declaration — an aggregate
     ;; over this store has to hear a retirement as loudly, or a withdrawn
     ;; standing order keeps pulling forever. Listeners that only mint from
     ;; arrivals registered through `set-on-intent` and never see this.
     (let ((gone (hashmap-ref (pss-intents st) id #f)))
       (when gone (emit-intent! gone 'removed))
       (bcom (^plan-store bcom
               (pss-update st #:intents (hashmap-remove (pss-intents st) id)
                           #:meta (if gone (note-declaration (pss-meta st) id 'removed)
                                      (pss-meta st)))
               callbacks))))

    ((open-intents)
     (hashmap-filter (lambda (i) (not (intent-finished i))) (pss-intents st)))

    ((intents-for-plan plan-id)
     ;; O(log n) via index
     (filter-map (lambda (iid) (hashmap-ref (pss-intents st) iid #f))
                 (hashmap-ref (pss-intents-by-plan st) plan-id '())))

    ((intents-for-tag tag)
     (let ((ids (hashmap-ref (pss-tag-index st) tag '())))
       (filter-map (lambda (id) (hashmap-ref (pss-intents st) id #f)) ids)))

    ((intents-for-spec spec-id)
     (let ((ids (hashmap-ref (pss-intents-by-spec st) spec-id '())))
       (filter-map (lambda (id) (hashmap-ref (pss-intents st) id #f)) ids)))

    ((offers)
     (hashmap-filter
       (lambda (i) (and (intent-provider i) (not (intent-receiver i))
                        (not (intent-finished i))))
       (pss-intents st)))

    ((requests)
     (hashmap-filter
       (lambda (i) (and (intent-receiver i) (not (intent-provider i))
                        (not (intent-finished i))))
       (pss-intents st)))

    ;; --- Commitments ---

    ((add-commitment commitment)
     (let-values (((new-st id) (pss-add-commitment st commitment)))
       (when on-commitment
         (on-commitment (hashmap-ref (pss-commitments new-st) id)))
       (bcom (^plan-store bcom new-st callbacks) id)))

    ((add-commitment-silent commitment)
     ;; Recovery path: skip the on-commitment callback to avoid re-emission.
     (let-values (((new-st id) (pss-add-commitment st commitment)))
       (bcom (^plan-store bcom new-st callbacks) id)))

    ;; Late-bind any emission callback (post-recovery). Prepends to
    ;; the alist so the new binding shadows older ones.
    ((set-callback key proc)
     (bcom (^plan-store bcom st (cons (cons key proc) callbacks))))

    ;; Back-compat convenience wrappers — delegate to set-callback.
    ((set-on-commitment proc)
     (bcom (^plan-store bcom st
             (cons (cons 'on-commitment proc) callbacks))))
    ;; "Tell me when an intent comes into being" — stored plainly under its own
    ;; key; the arrivals filter that gives it that meaning lives at the read
    ;; above, so this path and a constructor-supplied alist cannot diverge.
    ((set-on-intent proc)
     (bcom (^plan-store bcom st (cons (cons 'on-intent proc) callbacks))))

    ;; The commitment-horizon gate: (proc intent) → #t | a refusal string.
    ;; Consulted at both accept doors (accept-proposal, promote-to-commitment)
    ;; before an intent becomes a commitment. Installed by the scope-root's
    ;; rewire-callbacks (a wire, so it is re-installed after persistence load).
    ((set-gate proc)
     (bcom (^plan-store bcom st (cons (cons 'gate-accept proc) callbacks)) 'ok))

    ;; the fresh feasibility check for never-held accepts — see fresh-check!
    ((set-fresh-check proc)
     (bcom (^plan-store bcom st (cons (cons 'fresh-check proc) callbacks)) 'ok))

    ;; The channel itself, for a listener that folds change: (intent action).
    ;; APPENDS — several readers of one store is the ordinary case, and a
    ;; second one must not silence the first.
    ((add-intent-listener proc)
     (bcom (^plan-store bcom st (cons (cons 'on-intent-change proc) callbacks))))
    ((set-on-plan proc)
     (bcom (^plan-store bcom st
             (cons (cons 'on-plan proc) callbacks))))
    ((set-on-agreement proc)
     (bcom (^plan-store bcom st
             (cons (cons 'on-agreement proc) callbacks))))

    ((get-commitment id) (hashmap-ref (pss-commitments st) id #f))
    ((all-commitments)   (hashmap-values (pss-commitments st)))

    ((commitments-for-process process-id)
     (filter-map (lambda (cid) (hashmap-ref (pss-commitments st) cid #f))
                 (hashmap-ref (pss-commitments-by-process st) process-id '())))

    ((commitments-for-plan plan-id)
     (filter-map (lambda (cid) (hashmap-ref (pss-commitments st) cid #f))
                 (hashmap-ref (pss-commitments-by-plan st) plan-id '())))

    ((commitments-for-spec spec-id)
     (let ((ids (hashmap-ref (pss-commitments-by-spec st) spec-id '())))
       (filter-map (lambda (id) (hashmap-ref (pss-commitments st) id #f)) ids)))

    ((add-non-process-commitment action spec-id qty unit provider receiver due plan-id)
     (let* ((c (make-commitment #:id (generate-id "c-") #:action action #:resource-conforms-to spec-id
                                #:resource-quantity (make-measure qty unit) #:provider provider #:receiver receiver #:due due #:planned-within plan-id)))
       (let-values (((new-st id) (pss-add-commitment st c)))
         (when on-commitment
           (on-commitment (hashmap-ref (pss-commitments new-st) id)))
         (bcom (^plan-store bcom new-st callbacks) id))))

    ;; --- Promote intent to commitment (delegates to pss-promote-intent) ---

    ((promote-to-commitment iid counterparty)
     ;; the commitment-horizon gate, then the fresh check for a
     ;; never-held accept — see gate-intents! / fresh-check!
     (gate-intents! (assq-ref callbacks 'gate-accept) (pss-intents st) (list iid))
     (fresh-check! callbacks st (list iid))
     (let-values (((new-st cid) (pss-promote-intent st iid counterparty)))
       (when (and on-commitment cid)
         (on-commitment (hashmap-ref (pss-commitments new-st) cid)))
       (bcom (^plan-store bcom new-st callbacks) cid)))

    ;; --- Release: the decided rung's withdrawal (commitment-horizon.md) ---
    ;; retire-need's mirror at the commitment layer: a release travels the
    ;; channel the accept did. The commitment FINISHES — the record stays,
    ;; and the next solve drops its pin, so the release is felt exactly
    ;; where the accept was felt. The work returns to the free rung on its
    ;; own: a standing (windowed) declaration never finished at promotion
    ;; and still stands, and a one-shot's demand re-emerges from the next
    ;; solve — resurrecting the SPENT offer proposal by unfinishing its
    ;; intent would silently re-open a hold nobody re-presented. Only the
    ;; commitment's own provider releases it.
    ;; ONE door for a commitment leaving the decided rung, whichever way:
    ;;   released   a person withdrew (their own accept — checked)
    ;;   fulfilled  the work was done (record-work-done / record-flow-done)
    ;;   expired    its window closed unworked (the offer sweep)
    ;; The record finishes and stays; the ending is a dated FACT on the meta
    ;; rail under the commitment's id — a lapse's sibling — so the drift
    ;; question reads how commitments end, by kind, on one clock. AT is the
    ;; instant (unix) from the caller's clock; the store stamps what it is told.
    ((end-commitment cid kind at . maybe-aid)
     (end-commitment! cid kind at (and (pair? maybe-aid) (car maybe-aid))))
    ;; an offer LAPSES — urgency (its window closed unaccepted) or
    ;; feasibility (a re-solve cannot honor its hold): the published intent
    ;; finishes, so every enumeration drops the offer by state, and the
    ;; lapse is a dated fact under the proposal's id. Idempotent: a second
    ;; lapse of a finished offer is a no-op, so the sweeps need no memory.
    ;; → #t when this call lapsed it, #f when it already had.
    ((lapse-offer pid kind at)
     (let* ((p (hashmap-ref (pss-proposals st) pid #f))
            (iid (and p (pair? (proposal-publishes p)) (car (proposal-publishes p))))
            (it (and iid (hashmap-ref (pss-intents st) iid #f))))
       (unless (memq kind '(offer-lapsed offer-infeasible))
         (error "lapse-offer: a lapse kind the store does not know" kind))
       (if (not (and it (not (intent-finished it))))
           #f
           (bcom (^plan-store bcom
                   (pss-update st
                     #:intents (hashmap-set (pss-intents st) iid (copy-intent it #:finished #t))
                     #:meta (note-fact (pss-meta st) pid 'lapsed kind at))
                   callbacks)
                 #t))))

    ;; the store's own clock-driven ending, in ONE turn: every unfinished
    ;; commitment whose window closed before AT expires — finished, dated —
    ;; and the ids come back so the caller can announce them. The same
    ;; fact end-commitment writes one at a time; a sweep over a store
    ;; should not cost a turn per row.
    ((expire-commitments at)
     (let* ((gone (filter (lambda (c)
                            (and (not (commitment-finished c))
                                 (let ((u (window-close-epoch (commitment-has-end c))))
                                   (and u (< u at)))))
                          (hashmap-values (pss-commitments st))))
            (ids (map commitment-id gone)))
       (if (null? gone) '()
           (bcom (^plan-store bcom
                   (pss-update st
                     #:commitments (fold (lambda (c cs) (hashmap-set cs (commitment-id c)
                                                                       (copy-commitment c #:finished #t)))
                                         (pss-commitments st) gone)
                     #:meta (fold (lambda (c m) (note-fact m (commitment-id c) 'ended 'expired at))
                                  (pss-meta st) gone))
                   callbacks)
                 ids))))

    ;; the release, as the provider's own door (the kind fixed)
    ((release-commitment cid releasing-aid . maybe-at)
     (end-commitment! cid 'released
                      (if (pair? maybe-at) (car maybe-at) (instant->unix (clock-now)))
                      releasing-aid))

    ;; --- Claims ---

    ((add-claim claim)
     (let* ((id (or (claim-id claim) (generate-id "claim-")))
            (new-claims (hashmap-set (pss-claims st) id claim)))
       (bcom (^plan-store bcom
               (pss-update st #:claims new-claims) callbacks)
             id)))

    ((get-claim id) (hashmap-ref (pss-claims st) id #f))
    ((all-claims)   (hashmap-values (pss-claims st)))

    ;; --- Agreements ---

    ((add-agreement agreement)
     (let-values (((new-st id) (pss-add-agreement st agreement)))
       (bcom (^plan-store bcom new-st callbacks) id)))

    ((get-agreement id) (hashmap-ref (pss-agreements st) id #f))
    ((all-agreements) (hashmap-values (pss-agreements st)))

    ;; --- Agreement bundles ---

    ((add-agreement-bundle bundle)
     (let ((id (or (assq-ref bundle 'id) (generate-id "ab-"))))
       (bcom (^plan-store bcom
               (pss-update st #:agreement-bundles (hashmap-set (pss-agreement-bundles st) id bundle)) callbacks))))
    ((get-agreement-bundle id) (hashmap-ref (pss-agreement-bundles st) id #f))
    ((all-agreement-bundles) (hashmap-values (pss-agreement-bundles st)))

    ;; --- Scenarios ---

    ((add-scenario scenario)
     (let ((id (or (assq-ref scenario 'id) (generate-id "scen-"))))
       (bcom (^plan-store bcom
               (pss-update st #:scenarios (hashmap-set (pss-scenarios st) id scenario)) callbacks))))
    ((get-scenario id) (hashmap-ref (pss-scenarios st) id #f))
    ((all-scenarios) (hashmap-values (pss-scenarios st)))

    ((add-scenario-definition sdef)
     (let ((id (or (assq-ref sdef 'id) (generate-id "sdef-"))))
       (bcom (^plan-store bcom
               (pss-update st #:scenario-definitions (hashmap-set (pss-scenario-definitions st) id sdef)) callbacks))))
    ((get-scenario-definition id) (hashmap-ref (pss-scenario-definitions st) id #f))
    ((all-scenario-definitions) (hashmap-values (pss-scenario-definitions st)))

    ;; --- Proposals ---

    ((add-proposal proposal)
     (let ((id (proposal-id proposal)))
       (bcom (^plan-store bcom
               (pss-update st #:proposals (hashmap-set (pss-proposals st) id proposal)) callbacks))))
    ((get-proposal id) (hashmap-ref (pss-proposals st) id #f))
    ((all-proposals) (hashmap-values (pss-proposals st)))

    ((add-proposal-list plist)
     (let ((id (or (assq-ref plist 'id) (generate-id "pl-"))))
       (bcom (^plan-store bcom
               (pss-update st #:proposal-lists (hashmap-set (pss-proposal-lists st) id plist)) callbacks))))
    ((get-proposal-list id) (hashmap-ref (pss-proposal-lists st) id #f))
    ((all-proposal-lists) (hashmap-values (pss-proposal-lists st)))

    ;; --- Signal metadata ---

    ((set-meta intent-id meta-alist)
     (let ((new-meta (hashmap-set (pss-meta st) intent-id meta-alist)))
       (bcom (^plan-store bcom
               (pss-update st #:meta new-meta) callbacks))))

    ((get-meta intent-id) (hashmap-ref (pss-meta st) intent-id #f))

    ;; All (id . meta-alist) pairs — lets a caller rebuild a predicate over
    ;; signal metadata (e.g. who has marked status=willing) across re-solves,
    ;; since meta persists by id while the intents themselves are re-derived.
    ((all-meta) (hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() (pss-meta st)))

    ;; the dated facts carrying KEY at or after SINCE — filtered HERE, where
    ;; the rows live, so a rate never marshals the whole rail out of the
    ;; actor to count a few of its rows
    ((facts-since key since until)
     (hashmap-fold (lambda (k m acc)
                     (if (and (list? m) (assq-ref m key)
                              (let ((at (assq-ref m 'at)))
                                (and (number? at) (>= at since) (<= at until))))
                         (cons (cons k m) acc)
                         acc))
                   '() (pss-meta st)))

    ;; --- Signal lifecycle ---

    ((emit-signal signal plan-id)
     ;; Convert PlanSignal alist -> Intent + metadata, store both
     (let-values (((intent-fields meta) (signal->intent signal plan-id)))
       ;; Add the intent (this calls bcom internally)
       ;; But we need to add intent AND set meta atomically.
       ;; Build the new state manually:
       (let* ((iid (or (intent-id intent-fields) (generate-id "sig-")))
              ;; Rebuild intent with assigned id so indexes are consistent
              (intent-with-id
                (if (intent-id intent-fields) intent-fields
                    (copy-intent intent-fields #:id iid)))
              (new-intents (hashmap-set (pss-intents st) iid intent-with-id))
              (new-tag-idx (index-intent-tags (pss-tag-index st) intent-with-id))
              (new-ibs (index-intent-spec (pss-intents-by-spec st) intent-with-id))
              (new-ibp (let ((pw (intent-planned-within intent-with-id)))
                         (if pw (append-to-index (pss-intents-by-plan st) pw iid)
                             (pss-intents-by-plan st))))
              (new-meta (hashmap-set (pss-meta st) iid meta)))
         (bcom (^plan-store bcom
                 (pss-update st #:intents new-intents #:meta new-meta #:tag-index new-tag-idx
                             #:intents-by-spec new-ibs #:intents-by-plan new-ibp) callbacks)
               iid))))

    ((signals-of-kind kind)
     ;; Query by signal kind, reconstruct via intent->signal
     (let ((tag (plan-tag kind)))
       (filter-map
         (lambda (i)
           (intent->signal i (hashmap-ref (pss-meta st) (intent-id i) #f)))
         (filter-map (lambda (iid) (hashmap-ref (pss-intents st) iid #f))
                     (hashmap-ref (pss-tag-index st) tag '())))))

    ((approve-replenishment iid provider receiver . rest)
     ;; Promote replenishment Intent -> Commitment with validation
     (let* ((opts (if (pair? rest) (car rest) '()))
            (intent (hashmap-ref (pss-intents st) iid #f)))
       (unless intent (error (format #f "Replenishment ~a not found" iid)))
       ;; Validate: must not be finished
       (when (intent-finished intent)
         (error (format #f "Replenishment ~a already finished" iid)))
       ;; Validate: must have replenishment tag
       (unless (and (intent-resource-classified-as intent)
                    (member "replenishment" (tag-values (intent-resource-classified-as intent) "tag:plan")))
         (error (format #f "Intent ~a is not a replenishment signal" iid)))
       (let* ((action-override (assq-ref opts 'action))
              (output-of (assq-ref opts 'output-of))
              (planned-within-override (assq-ref opts 'planned-within))
              (cid (generate-id "commit-"))
              ;; the one promotion map (intent->commitment), then the door's own overrides
              (commitment (copy-commitment (intent->commitment intent cid provider receiver)
                                           #:action (or action-override (intent-action intent))
                                           #:output-of (or output-of (intent-output-of intent))
                                           #:planned-within (or planned-within-override (intent-planned-within intent))))
              ;; Mark intent finished
              (finished-intent (copy-intent intent #:finished #t))
              ;; Update meta
              (old-meta (hashmap-ref (pss-meta st) iid '()))
              (new-meta-entry (cons* (cons 'status 'approved)
                                     (cons 'approved-commitment-id cid)
                                     (if (pair? old-meta) old-meta '())))
              ;; Build new state
              (new-intents (hashmap-set (pss-intents st) iid finished-intent))
              (new-commitments (hashmap-set (pss-commitments st) cid commitment))
              (new-cbs (index-commitment-spec (pss-commitments-by-spec st) commitment))
              (new-meta (hashmap-set (pss-meta st) iid new-meta-entry)))
         (bcom (^plan-store bcom
                 (pss-update st #:commitments new-commitments #:intents new-intents
                             #:meta new-meta #:commitments-by-spec new-cbs) callbacks)
               cid))))

    ((reject-replenishment iid)
     (let ((intent (hashmap-ref (pss-intents st) iid #f)))
       (unless intent (error (format #f "Replenishment ~a not found" iid)))
       (let* ((finished-intent (copy-intent intent #:finished #t))
              (old-meta (hashmap-ref (pss-meta st) iid '()))
              (new-meta-entry (cons (cons 'status 'rejected)
                                    (if (pair? old-meta) old-meta '()))))
         (bcom (^plan-store bcom
                 (pss-update st #:intents (hashmap-set (pss-intents st) iid finished-intent)
                             #:meta (hashmap-set (pss-meta st) iid new-meta-entry)) callbacks)))))

    ((commitments-for-agreement agreement-id)
     (hashmap-filter
       (lambda (c) (equal? (commitment-clause-of c) agreement-id))
       (pss-commitments st)))

    ((signal-outputs-of-process process-id)
     (hashmap-filter
       (lambda (i) (and (equal? (intent-output-of i) process-id)
                        (let ((tags (intent-resource-classified-as i)))
                          (and tags (pair? (tag-values tags "tag:plan"))))))
       (pss-intents st)))

    ;; --- Bulk operations ---

    ((remove-records proc-ids commit-ids intent-ids)
     ;; Batch delete by ID lists with full index cleanup.
     (let* (;; Remove commitments + clean indexes
            (new-commitments
              (fold (lambda (cid hm) (hashmap-remove hm cid)) (pss-commitments st) (or commit-ids '())))
            (new-cbs
              (fold (lambda (cid idx)
                      (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                        (if (and c (commitment-resource-conforms-to c))
                            (let* ((spec (commitment-resource-conforms-to c))
                                   (existing (hashmap-ref idx spec '())))
                              (hashmap-set idx spec (delete cid existing)))
                            idx)))
                    (pss-commitments-by-spec st) (or commit-ids '())))
            (new-cbpl
              (fold (lambda (cid idx)
                      (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                        (if (and c (commitment-planned-within c))
                            (let* ((pw (commitment-planned-within c))
                                   (existing (hashmap-ref idx pw '())))
                              (hashmap-set idx pw (delete cid existing)))
                            idx)))
                    (pss-commitments-by-plan st) (or commit-ids '())))
            ;; Remove intents + clean indexes
            (new-intents
              (fold (lambda (iid hm) (hashmap-remove hm iid)) (pss-intents st) (or intent-ids '())))
            (new-tag-idx
              (fold (lambda (iid idx)
                      (let ((i (hashmap-ref (pss-intents st) iid #f)))
                        (if (and i (intent-resource-classified-as i))
                            (fold (lambda (tag ix)
                                    (hashmap-set ix tag (delete iid (hashmap-ref ix tag '()))))
                                  idx (intent-resource-classified-as i))
                            idx)))
                    (pss-tag-index st) (or intent-ids '())))
            (new-ibs
              (fold (lambda (iid idx)
                      (let ((i (hashmap-ref (pss-intents st) iid #f)))
                        (if (and i (intent-resource-conforms-to i))
                            (let* ((spec (intent-resource-conforms-to i))
                                   (existing (hashmap-ref idx spec '())))
                              (hashmap-set idx spec (delete iid existing)))
                            idx)))
                    (pss-intents-by-spec st) (or intent-ids '())))
            (new-ibp
              (fold (lambda (iid idx)
                      (let ((i (hashmap-ref (pss-intents st) iid #f)))
                        (if (and i (intent-planned-within i))
                            (let* ((pw (intent-planned-within i))
                                   (existing (hashmap-ref idx pw '())))
                              (hashmap-set idx pw (delete iid existing)))
                            idx)))
                    (pss-intents-by-plan st) (or intent-ids '())))
            (new-meta
              (fold (lambda (iid hm) (hashmap-remove hm iid)) (pss-meta st) (or intent-ids '())))
            ;; Clean commitments-by-process index
            (new-cbpr
              (fold (lambda (cid idx)
                      (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                        (let* ((a0 idx)
                               (a1 (if (and c (commitment-input-of c))
                                       (hashmap-set a0 (commitment-input-of c)
                                         (delete cid (hashmap-ref a0 (commitment-input-of c) '())))
                                       a0))
                               (a2 (if (and c (commitment-output-of c))
                                       (hashmap-set a1 (commitment-output-of c)
                                         (delete cid (hashmap-ref a1 (commitment-output-of c) '())))
                                       a1)))
                          a2)))
                    (pss-commitments-by-process st) (or commit-ids '()))))
       (bcom (^plan-store bcom
               (pss-update st #:commitments new-commitments #:intents new-intents #:meta new-meta
                           #:tag-index new-tag-idx #:intents-by-spec new-ibs #:commitments-by-spec new-cbs
                           #:intents-by-plan new-ibp #:commitments-by-plan new-cbpl
                           #:commitments-by-process new-cbpr) callbacks))))

    ((remove-records-for-plan plan-id)
     ;; Surgical removal: find all intents/commitments for this plan.
     ;; Uses the by-plan indexes for O(log n) lookup.
     (let ((iids (hashmap-ref (pss-intents-by-plan st) plan-id '()))
           (cids (hashmap-ref (pss-commitments-by-plan st) plan-id '())))
       ;; Build cleaned state (same logic as remove-records but inline)
       (let* ((new-intents (fold (lambda (iid hm) (hashmap-remove hm iid)) (pss-intents st) iids))
              (new-commitments (fold (lambda (cid hm) (hashmap-remove hm cid)) (pss-commitments st) cids))
              ;; Clean intent indexes
              (new-tag-idx (fold (lambda (iid idx)
                                  (let ((i (hashmap-ref (pss-intents st) iid #f)))
                                    (if (and i (intent-resource-classified-as i))
                                        (fold (lambda (tag ix)
                                                (hashmap-set ix tag (delete iid (hashmap-ref ix tag '()))))
                                              idx (intent-resource-classified-as i))
                                        idx)))
                                (pss-tag-index st) iids))
              (new-ibs (fold (lambda (iid idx)
                               (let ((i (hashmap-ref (pss-intents st) iid #f)))
                                 (if (and i (intent-resource-conforms-to i))
                                     (hashmap-set idx (intent-resource-conforms-to i)
                                       (delete iid (hashmap-ref idx (intent-resource-conforms-to i) '())))
                                     idx)))
                             (pss-intents-by-spec st) iids))
              (new-ibp (hashmap-remove (pss-intents-by-plan st) plan-id))
              ;; Clean commitment indexes
              (new-cbs (fold (lambda (cid idx)
                               (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                                 (if (and c (commitment-resource-conforms-to c))
                                     (hashmap-set idx (commitment-resource-conforms-to c)
                                       (delete cid (hashmap-ref idx (commitment-resource-conforms-to c) '())))
                                     idx)))
                             (pss-commitments-by-spec st) cids))
              (new-cbpl (hashmap-remove (pss-commitments-by-plan st) plan-id))
              (new-meta (fold (lambda (iid hm) (hashmap-remove hm iid)) (pss-meta st) iids)))
         (bcom (^plan-store bcom
                 (pss-update st #:commitments new-commitments #:intents new-intents #:meta new-meta
                             #:tag-index new-tag-idx #:intents-by-spec new-ibs #:commitments-by-spec new-cbs
                             #:intents-by-plan new-ibp #:commitments-by-plan new-cbpl) callbacks)))))

    ;; --- Merge: monoidal fold of source into self ---

    ((merge source-plan-store)
     ;; Query source actor for all records, fold into local state.
     ;; Merge IS the monoid operation: (fold add source-records identity-state).
     ;; We build the new state in one bcom (not N separate transitions).
     (let* (;; Query source
            (their-intents ($ source-plan-store 'all-intents))
            (their-commits ($ source-plan-store 'all-commitments))
            (their-plans   ($ source-plan-store 'all-plans))
            ;; Fold intents into local maps + indexes
            (merged-intents
              (fold (lambda (i hm) (hashmap-set hm (intent-id i) i))
                    (pss-intents st) their-intents))
            (merged-tag-idx
              (fold (lambda (i idx)
                      (fold (lambda (tag ix)
                              (let ((existing (hashmap-ref ix tag '())))
                                (if (member (intent-id i) existing) ix
                                    (hashmap-set ix tag (cons (intent-id i) existing)))))
                            idx (or (intent-resource-classified-as i) '())))
                    (pss-tag-index st) their-intents))
            (merged-ibs
              (fold (lambda (i idx)
                      (let ((spec (intent-resource-conforms-to i)))
                        (if (not spec) idx
                            (let ((existing (hashmap-ref idx spec '())))
                              (if (member (intent-id i) existing) idx
                                  (hashmap-set idx spec (cons (intent-id i) existing)))))))
                    (pss-intents-by-spec st) their-intents))
            (merged-ibp
              (fold (lambda (i idx)
                      (let ((pw (intent-planned-within i)))
                        (if (not pw) idx
                            (let ((existing (hashmap-ref idx pw '())))
                              (if (member (intent-id i) existing) idx
                                  (hashmap-set idx pw (cons (intent-id i) existing)))))))
                    (pss-intents-by-plan st) their-intents))
            ;; Fold commitments
            (merged-commits
              (fold (lambda (c hm) (hashmap-set hm (commitment-id c) c))
                    (pss-commitments st) their-commits))
            (merged-cbs
              (fold (lambda (c idx)
                      (let ((spec (commitment-resource-conforms-to c)))
                        (if (not spec) idx
                            (let ((existing (hashmap-ref idx spec '())))
                              (if (member (commitment-id c) existing) idx
                                  (hashmap-set idx spec (cons (commitment-id c) existing)))))))
                    (pss-commitments-by-spec st) their-commits))
            (merged-cbpl
              (fold (lambda (c idx)
                      (let ((pw (commitment-planned-within c)))
                        (if (not pw) idx
                            (let ((existing (hashmap-ref idx pw '())))
                              (if (member (commitment-id c) existing) idx
                                  (hashmap-set idx pw (cons (commitment-id c) existing)))))))
                    (pss-commitments-by-plan st) their-commits))
            (merged-cbpr
              (fold (lambda (c idx)
                      (let* ((a0 idx)
                             (a1 (if (commitment-input-of c)
                                     (let ((existing (hashmap-ref a0 (commitment-input-of c) '())))
                                       (if (member (commitment-id c) existing) a0
                                           (hashmap-set a0 (commitment-input-of c)
                                             (cons (commitment-id c) existing))))
                                     a0))
                             (a2 (if (commitment-output-of c)
                                     (let ((existing (hashmap-ref a1 (commitment-output-of c) '())))
                                       (if (member (commitment-id c) existing) a1
                                           (hashmap-set a1 (commitment-output-of c)
                                             (cons (commitment-id c) existing))))
                                     a1)))
                        a2))
                    (pss-commitments-by-process st) their-commits))
            ;; Fold plans
            (merged-plans
              (fold (lambda (p hm) (hashmap-set hm (plan-id p) p))
                    (pss-plans st) their-plans)))
       (bcom (^plan-store bcom
               (pss-update st #:plans merged-plans #:commitments merged-commits #:intents merged-intents
                           #:tag-index merged-tag-idx #:intents-by-spec merged-ibs #:commitments-by-spec merged-cbs
                           #:intents-by-plan merged-ibp #:commitments-by-plan merged-cbpl
                           #:commitments-by-process merged-cbpr) callbacks))))

    ;; --- Recipe instantiation (full implementation) ---

    ((instantiate-recipe recipe-id recipe-store quantity due-date agents
                         . rest)
     ;; Expand recipe template into plan with processes, flows, and agreements.
     ;; Supports scaleFactor, back/forward scheduling, inventory allocation.
     (let* ((scheduling (if (pair? rest) (car rest) 'back))
            (observer (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
            (recipe ($ recipe-store 'get-recipe recipe-id))
            (chain ($ recipe-store 'get-process-chain recipe-id))
            ;; Compute scale factor from primary output
            (primary-spec (and recipe (recipe-primary-output recipe)))
            (last-proc (and (pair? chain) (last chain)))
            (last-outs (and last-proc
                            (cdr ($ recipe-store 'flows-for-process
                                     (recipe-process-id last-proc)))))
            (primary-flow (and last-outs primary-spec
                               (find (lambda (f)
                                       (equal? (recipe-flow-resource-conforms-to f) primary-spec))
                                     last-outs)))
            (primary-out-qty (if (and primary-flow (recipe-flow-resource-quantity primary-flow))
                                 (measure-has-numerical-value (recipe-flow-resource-quantity primary-flow))
                                 1))
            (scale-factor (/ quantity primary-out-qty))
            ;; Create plan — thread the post-add state through `ns` to the
            ;; single tail `bcom` below, instead of committing here.
            (pid (generate-id "plan-"))
            (ns (call-with-values
                  (lambda ()
                    (pss-add-plan st
                      (make-plan #:id pid
                        #:name (format #f "Plan: ~a × ~a" (and recipe (recipe-name recipe)) quantity) #:refinement-of (and due-date (number->string due-date)))))
                  (lambda (new-st _id) new-st)))
            ;; Schedule processes
            (ordered-chain (if (eq? scheduling 'back) (reverse chain) chain))
            (initial-cursor (if (eq? scheduling 'back) due-date
                                (or (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                                         (caddr rest))
                                    (instant->unix (clock-now)))))
            ;; Process creation: walk chain, create Process + flows
            (processes '())
            (commitments '())
            (intents '())
            (allocated '()))
       (let proc-loop ((procs ordered-chain) (cursor initial-cursor))
         (when (pair? procs)
           (let* ((rp (car procs))
                  (dur-s (inexact->exact (round (/ (rp-duration-ms rp) 1000))))
                  (proc-begin (if (eq? scheduling 'back) (- cursor dur-s) cursor))
                  (proc-end (if (eq? scheduling 'back) cursor (+ cursor dur-s)))
                  (proc-id (generate-id "proc-"))
                  (proc (make-process #:id proc-id #:name (recipe-process-name rp)
                          #:based-on (recipe-process-process-conforms-to rp) #:planned-within pid
                          #:has-beginning (number->string proc-begin) #:has-end (number->string proc-end)))
                  (flows-pair ($ recipe-store 'flows-for-process (recipe-process-id rp)))
                  (flow-inputs (car flows-pair))
                  (flow-outputs (cdr flows-pair)))
             (set! processes (cons proc processes))
             ;; Input flows: check durable actions, inventory allocation
             (for-each
               (lambda (f)
                 (let* ((action (recipe-flow-action f))
                        (def (get-action-def action))
                        (is-durable (and def (eq? (action-definition-accounting-effect def) 'no-effect)))
                        (spec (recipe-flow-resource-conforms-to f))
                        (rq (recipe-flow-resource-quantity f))
                        (needed (if rq (* (measure-has-numerical-value rq) scale-factor) 0))
                        (unit (if rq (measure-has-unit rq) %count-unit)))
                   ;; Durable inputs: skip demand if resource exists
                   (if (and is-durable spec observer)
                       (let ((resources (filter
                                          (lambda (r) (> (measure-qty (economic-resource-accounting-quantity r)) 0))
                                          ($ observer 'conforming-resources spec))))
                         (unless (pair? resources)
                           ;; Resource doesn't exist — create intent
                           (let ((rec (create-flow-record f proc-id 'input scale-factor
                                        (number->string proc-begin) pid agents #f #f)))
                             (if (commitment? rec)
                                 (set! commitments (cons rec commitments))
                                 (set! intents (cons rec intents))))))
                       ;; Non-durable: check inventory + create flow
                       (begin
                         ;; Inventory allocation (if observer available)
                         (when (and observer spec (> needed 0))
                           (let ((resources (filter
                                              (lambda (r) (> (measure-qty (economic-resource-accounting-quantity r)) 0))
                                              ($ observer 'conforming-resources spec))))
                             (let alloc-loop ((rs resources) (remaining needed))
                               (when (and (pair? rs) (> remaining 0))
                                 (let* ((r (car rs))
                                        (avail (measure-qty (economic-resource-accounting-quantity r)))
                                        (take (min avail remaining)))
                                   (set! allocated (cons `(,(economic-resource-id r) ,spec ,take) allocated))
                                   (alloc-loop (cdr rs) (- remaining take)))))))
                         ;; Create flow record
                         (let ((rec (create-flow-record f proc-id 'input scale-factor
                                      (number->string proc-begin) pid agents #f #f)))
                           (if (commitment? rec)
                               (set! commitments (cons rec commitments))
                               (set! intents (cons rec intents))))))))
               flow-inputs)
             ;; Output flows
             (for-each
               (lambda (f)
                 (let ((rec (create-flow-record f proc-id 'output scale-factor
                              (number->string proc-end) pid agents #f #f)))
                   (if (commitment? rec)
                       (set! commitments (cons rec commitments))
                       (set! intents (cons rec intents)))))
               flow-outputs)
             ;; Advance cursor
             (proc-loop (cdr procs)
                        (if (eq? scheduling 'back) proc-begin proc-end)))))
       ;; RecipeExchange → Agreement conversion
       (let ((agreements '())
             (rex-ids (and recipe (recipe-recipe-exchanges recipe))))
         (when (and rex-ids (pair? rex-ids))
           (for-each
             (lambda (rex-id)
               (let* ((rex ($ recipe-store 'get-recipe-exchange rex-id))
                      (rex-flows ($ recipe-store 'flows-for-exchange rex-id))
                      (flow-list (if (list? rex-flows) rex-flows
                                     (hashmap-values rex-flows)))
                      (bilateral? (= (length flow-list) 2))
                      (primary-cids '())
                      (reciprocal-cids '()))
                 ;; Create commitment for each exchange flow
                 (let flow-loop ((fs flow-list) (idx 0))
                   (when (pair? fs)
                     (let* ((f (car fs))
                            (cid (generate-id "exc-"))
                            ;; primary is a recipe-flow FIELD, not a tag — read it
                            ;; (was: (member "isPrimary" resource-classified-as))
                            (is-primary (or (recipe-flow-is-primary f)
                                            (and bilateral? (= idx 0))))
                            (commitment (make-commitment
                                          #:id cid #:action (recipe-flow-action f)
                                          #:resource-conforms-to (recipe-flow-resource-conforms-to f)
                                          #:resource-classified-as (recipe-flow-resource-classified-as f)
                                          #:resource-quantity (if (recipe-flow-resource-quantity f)
                                              (make-measure (* (measure-has-numerical-value
                                                                 (recipe-flow-resource-quantity f))
                                                               scale-factor)
                                                            (measure-has-unit
                                                              (recipe-flow-resource-quantity f)))
                                              #f)
                                          #:provider (and agents (assq-ref agents 'provider))
                                          #:receiver (and agents (assq-ref agents 'receiver)) #:planned-within pid)))
                       (set! commitments (cons commitment commitments))
                       (if is-primary
                           (set! primary-cids (cons cid primary-cids))
                           (set! reciprocal-cids (cons cid reciprocal-cids))))
                     (flow-loop (cdr fs) (+ idx 1))))
                 ;; Create Agreement
                 (let ((agr-id (generate-id "agr-")))
                   (set! agreements
                     (cons (make-agreement #:id agr-id
                             #:name (and rex (recipe-exchange-name rex))
                             #:created (number->string (instant->unix (clock-now)))
                             #:stipulates (if (pair? primary-cids) (reverse primary-cids) #f)
                             #:stipulates-reciprocal (if (pair? reciprocal-cids) (reverse reciprocal-cids) #f))
                           agreements)))))
             rex-ids))
         ;; Commit the plan added above and return the result — single
         ;; tail bcom, reply value is the result alist.
         (bcom (^plan-store bcom ns callbacks)
               `((plan-id . ,pid)
                 (processes . ,(reverse processes))
                 (commitments . ,(reverse commitments))
                 (intents . ,(reverse intents))
                 (agreements . ,(reverse agreements))
                 (allocated . ,(reverse allocated)))))))

    ;; --- Proposal publishing ---

    ((publish-offer intent-id . rest)
     ;; Package intent as public offer. Optional reciprocal-intent-id.
     (let* ((intent (hashmap-ref (pss-intents st) intent-id #f))
            (reciprocal-id (and (pair? rest) (car rest))))
       (if (not intent) #f
           (let* ((prop-id (generate-id "prop-"))
                  (proposal (make-proposal #:id prop-id
                              #:purpose 'offer #:publishes (list intent-id)
                              #:reciprocal (if reciprocal-id (list reciprocal-id) #f))))
             (bcom (^plan-store bcom
                     (pss-update st #:proposals (hashmap-set (pss-proposals st) prop-id proposal)) callbacks)
                   prop-id)))))

    ((publish-request intent-id . rest)
     (let* ((intent (hashmap-ref (pss-intents st) intent-id #f))
            (reciprocal-id (and (pair? rest) (car rest))))
       (if (not intent) #f
           (let* ((prop-id (generate-id "prop-"))
                  (proposal (make-proposal #:id prop-id
                              #:purpose 'request
                              #:publishes (if reciprocal-id (list reciprocal-id) #f)
                              #:reciprocal (list intent-id))))
             (bcom (^plan-store bcom
                     (pss-update st #:proposals (hashmap-set (pss-proposals st) prop-id proposal)) callbacks)
                   prop-id)))))

    ((accept-proposal proposal-id counterparty . rest)
     ;; Validate → promote primary + reciprocal intents → add agreement
     ;; → back-reference commitments via clause-of → fire on-agreement
     ;; → commit. The three pre-transition checks (temporal window,
     ;; proposedTo whitelist, KERI verify-with) live in
     ;; validate-proposal-acceptance!.
     (let* ((opts (if (pair? rest) (car rest) '()))
            (accepting-aid (assq-ref opts 'accepting-agent-id))
            (verify-with   (assq-ref opts 'verify-with))
            (proposal (hashmap-ref (pss-proposals st) proposal-id #f)))
       (unless proposal (error "Proposal not found"))
       (validate-proposal-acceptance! proposal proposal-id
                                       accepting-aid verify-with)
       ;; the commitment-horizon gate — the same standing check as the
       ;; promote door, run over every intent this acceptance would promote
       (gate-intents! (assq-ref callbacks 'gate-accept) (pss-intents st)
                      (append (or (proposal-publishes proposal) '())
                              (or (proposal-reciprocal proposal) '())))
       ;; the fresh check — an offer proposal's own intents count held and
       ;; skip it; a request's work intents get the trial
       (fresh-check! callbacks st
                     (append (or (proposal-publishes proposal) '())
                             (or (proposal-reciprocal proposal) '())))
       (let* ((flipped `((provider . ,(assq-ref counterparty 'receiver))
                         (receiver . ,(assq-ref counterparty 'provider))))
              (st+primary (fold-promotions st
                            (or (proposal-publishes proposal) '()) counterparty))
              (st+recip   (fold-promotions (car st+primary)
                            (or (proposal-reciprocal proposal) '()) flipped))
              (primary-cids (cdr st+primary))
              (recip-cids (cdr st+recip))
              (all-cids (append primary-cids recip-cids))
              (agr-id (generate-id "agr-"))
              (agr (make-agreement #:id agr-id #:name (proposal-name proposal)
                     #:created (number->string (instant->unix (clock-now)))
                     #:stipulates (if (pair? primary-cids) primary-cids #f)
                     #:stipulates-reciprocal (if (pair? recip-cids) recip-cids #f))))
         (let-values (((st+agr _) (pss-add-agreement (car st+recip) agr)))
           (let ((final-st (fold (lambda (cid s)
                                   (pss-set-commitment-clause-of s cid agr-id))
                                 st+agr all-cids))
                 (result `((agreement-id . ,agr-id)
                           (proposal-id  . ,proposal-id)
                           (primary-commitment-ids    . ,primary-cids)
                           (reciprocal-commitment-ids . ,recip-cids)
                           (counterparty . ,counterparty)
                           (accepting-agent-id . ,accepting-aid)
                           (commitments  . ,all-cids))))
             (when on-agreement (on-agreement agr proposal result))
             (bcom (^plan-store bcom final-st callbacks)
                   result)))))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define plan-store-env
  (make-persistence-env
    `((((vf planning) ^plan-store) ,^plan-store))))
