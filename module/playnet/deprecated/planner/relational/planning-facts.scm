;;; planning-facts.scm — Lift, index, and query planning facts
;;;
;;; Facts are lifted once at session start. Indexes are built for O(1)
;;; key lookup. Unified fact-*-o relations accept a ctx and auto-dispatch:
;;; indexed when available, full scan otherwise. No if-indexes at call sites.
;;;
;;; Raw-facts variants (recipe-o, flow-o, etc.) remain for code outside a ctx.
;;; Legacy *-indexed-o aliases remain for backward compatibility in tests.

(define-module (playnet deprecated planner relational planning-facts)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module (playnet ddmrp records)
  #:use-module (playnet deprecated planner relational compute)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet observation observer)
  #:use-module (playnet algorithms propagation)
  #:export (*non-consuming-actions* build-indexes idx-ref idx-ref-single cred-claim-of
            custody-cred-live? cred-live? lift-live lift-custody-facts
            skill-cred-live? lift-skill-facts qty-of lift-intent-facts
            lift-claim-facts lift-commitment-facts effective-skills
            lift-planning-facts fact-recipe-o fact-chain-o fact-flow-o
            fact-inventory-o fact-custodian-of-o fact-buffer-zone-o recipe-o chain-o
            process-o flow-o inventory-o recipe-indexed-o chain-indexed-o
            flow-indexed-o inventory-indexed-o buffer-zone-indexed-o))

(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))

;; Actions excluded from recursive demand explosion. Handled by specialized
;; solvers in demand-relation.scm:
;;   use/accept/pickup/work → time-windowed allocation (solve-use-inputs-o)
;;   cite/deliver-service → existence gate (solve-cite-inputs-o)
(define *non-consuming-actions* '(use accept pickup work cite deliver-service))


;;; ── Index builder ───────────────────────────────────────────────────���─────────

(define (build-indexes facts)
  "Build hash-table indexes for O(1) key lookup.
   Returns alist of (index-name . hash-table)."
  (let ((recipes-by-output (make-hash-table))
        (chains-by-recipe (make-hash-table))
        (flows-by-process (make-hash-table))
        (inventory-by-spec (make-hash-table))
        (buffer-by-spec (make-hash-table))
        (specs-by-word (make-hash-table))
        (custody-by-spec (make-hash-table)))
    (for-each (lambda (f)
      (case (car f)
        ((recipe)
         (let ((output (cadddr f)))
           (hash-set! recipes-by-output output
             (cons f (hash-ref recipes-by-output output '())))))
        ((chain)
         (hash-set! chains-by-recipe (cadr f) f))
        ((flow)
         (let ((pid (cadr f)))
           (hash-set! flows-by-process pid
             (cons f (hash-ref flows-by-process pid '())))))
        ((inventory)
         (let ((spec (caddr f)))
           (hash-set! inventory-by-spec spec
             (cons f (hash-ref inventory-by-spec spec '())))))
        ((buffer-zone)
         (hash-set! buffer-by-spec (cadr f) f))
        ((custodian-of)
         (let ((spec (cadr f)))
           (hash-set! custody-by-spec spec
             (cons f (hash-ref custody-by-spec spec '())))))
        ((spec-name)
         (let* ((spec-id (cadr f))
                (name (caddr f))
                (words (map string-downcase (string-split name #\space))))
           (for-each (lambda (w)
             (hash-set! specs-by-word w
               (cons spec-id (hash-ref specs-by-word w '()))))
             words)))))
      facts)
    `((recipes-by-output . ,recipes-by-output)
      (chains-by-recipe . ,chains-by-recipe)
      (flows-by-process . ,flows-by-process)
      (inventory-by-spec . ,inventory-by-spec)
      (buffer-by-spec . ,buffer-by-spec)
      (specs-by-word . ,specs-by-word)
      (custody-by-spec . ,custody-by-spec))))

(define (idx-ref indexes name key)
  "O(1) index lookup. Returns list of matching facts or '()."
  (let ((table (assq-ref indexes name)))
    (if table (hash-ref table key '()) '())))

(define (idx-ref-single indexes name key)
  "O(1) lookup for single-valued indexes. Returns fact or #f."
  (let ((table (assq-ref indexes name)))
    (if table (hash-ref table key #f) #f)))


;;; ── Lift ──────────────────────────────────────────────────────────────────────

;;; ── Custody attestation lifting ─────────────────────────────────────────────
;;;
;;; Custody-attestation ACDCs (schema "playnet-custody-attestation/v1") are
;;; lifted into facts of shape:
;;;
;;;   (custodian-of <resource-spec> <scope-aid> <qty> <valid-from> <valid-until>)
;;;
;;; The lift takes pre-filtered credential alists rather than an acdc-store
;;; reference, keeping the planner free of a governance-umbrella import.
;;; Callers that have access to both layers fetch live credentials via
;;; `(non-revoked-by-schema acdc-store *schema-playnet-custody-attestation*)`
;;; and feed the result here. Expiry is enforced by `custody-cred-live?` —
;;; an attestation whose valid-until is in the past is treated as not-live
;;; even if the credential's revoked? flag is still #f.

(define (cred-claim-of cred key)
  (let ((claims (assq-ref cred 'claims)))
    (and claims (assq-ref claims key))))

(define* (custody-cred-live? cred #:optional (now-epoch #f))
  "True iff CRED is not revoked and its valid-until (if present) is in the
   future. NOW-EPOCH defaults to current-time. Strings (ISO-8601) and
   numbers (epoch seconds) are both accepted for valid-until."
  (and (not (assq-ref cred 'revoked?))
       (let ((vu (cred-claim-of cred 'valid-until)))
         (cond
          ((not vu) #t)
          ((number? vu)
           (> vu (or now-epoch (current-time))))
          ((string? vu)
           ;; Lexicographic compare on ISO-8601 is monotone; cheap, no parse.
           (let ((now-iso (or (and now-epoch #f)
                              (strftime "%Y-%m-%dT%H:%M:%SZ"
                                        (gmtime (current-time))))))
             (or (not now-iso) (string>? vu now-iso))))
          (else #t)))))

(define cred-live? custody-cred-live?)   ; generic name for the revoked?/valid-until logic

(define* (lift-live creds builder #:optional (now-epoch #f))
  "filter-map BUILDER over the live (non-revoked, unexpired) members of CREDS —
   the shared shell of every lift-*-facts. BUILDER takes a cred → its fact."
  (filter-map (lambda (c) (and (cred-live? c now-epoch) (builder c))) creds))

(define* (lift-custody-facts custody-creds #:optional (now-epoch #f))
  "Lift live custody-attestation credentials into (custodian-of …) facts."
  (lift-live custody-creds
    (lambda (c) `(custodian-of ,(cred-claim-of c 'resource-spec)
                               ,(cred-claim-of c 'custodian-aid)
                               ,(cred-claim-of c 'qty)
                               ,(cred-claim-of c 'valid-from)
                               ,(cred-claim-of c 'valid-until)))
    now-epoch))


;;; ── Skill membership lifting + conformance closure ──────────────────────────
;;;
;;; Skill ACDCs (schema "playnet-skill/v1") lift to facts of shape:
;;;
;;;   (holds-skill <worker-aid> <skill> <founding-event-id>)
;;;
;;; Same pre-filtered-creds contract + revoked?/valid-until liveness as custody
;;; (skill-cred-live? is the same predicate — recertification decay reuses it).
;;; The worker is the credential's HOLDER (top-level), the skill + founding event
;;; are claims.

(define skill-cred-live? custody-cred-live?)   ; named alias for the skill domain

(define* (lift-skill-facts skill-creds #:optional (now-epoch #f))
  "Lift live skill membership credentials into (holds-skill …) facts."
  (lift-live skill-creds
    (lambda (c) `(holds-skill ,(assq-ref c 'holder)
                              ,(cred-claim-of c 'skill)
                              ,(cred-claim-of c 'founding-event-id)))
    now-epoch))


;;; ── Intent / commitment lifting (caveat-1 complement) ───────────────────────
;;;
;;; Intent ACDCs (playnet-intent/v1) and commitment ACDCs (playnet-commitment/v1)
;;; lift to facts carrying the DESIRED quantities the credit Validation Gate needs
;;; for its satisfied-fraction, plus the plan membership that lets the OPEN-intent
;;; side of a plan be reconstructed (an unfilled intent no work event ever touched
;;; is unreachable from the work-event chain alone). Quantities are stored as
;;; (qty . unit) pairs in the claims; `qty-of` projects the number.

(define (qty-of pair) (and (pair? pair) (car pair)))

(define* (lift-intent-facts intent-creds #:optional (now-epoch #f))
  "Lift intent ACDCs → (attested-intent id action conforms-to res-qty eff-qty plan-id)."
  (lift-live intent-creds
    (lambda (c) `(attested-intent ,(cred-claim-of c 'intent-id)
                                  ,(cred-claim-of c 'action)
                                  ,(cred-claim-of c 'resource-conforms-to)
                                  ,(qty-of (cred-claim-of c 'resource-quantity))
                                  ,(qty-of (cred-claim-of c 'effort-quantity))
                                  ,(cred-claim-of c 'plan-id)))
    now-epoch))

(define* (lift-claim-facts claim-creds #:optional (now-epoch #f))
  "Lift claim ACDCs → (claimed claimant labor-cost resource-spec). The consumption
   side of the ledger: credit = gross (work-event facts) − Σ claimed."
  (lift-live claim-creds
    (lambda (c) `(claimed ,(assq-ref c 'holder)
                          ,(cred-claim-of c 'labor-cost)
                          ,(cred-claim-of c 'resource-spec)))
    now-epoch))

(define* (lift-commitment-facts commitment-creds #:optional (now-epoch #f))
  "Lift commitment ACDCs → (attested-commitment id action conforms-to eff-qty plan-id satisfies)."
  (lift-live commitment-creds
    (lambda (c) `(attested-commitment ,(cred-claim-of c 'commitment-id)
                                      ,(cred-claim-of c 'action)
                                      ,(cred-claim-of c 'resource-conforms-to)
                                      ,(qty-of (cred-claim-of c 'effort-quantity))
                                      ,(cred-claim-of c 'plan-id)
                                      ,(cred-claim-of c 'satisfies)))
    now-epoch))

(define (effective-skills held catalogue practiced-hours-of)
  "A worker's CONFORMANCE closure — the skills they may supply.

   held               : list of directly-held skill ids (from holds-skill facts).
   catalogue          : list of (spec . satisfied-by-DNF) for specs with substitutes,
                        each DNF a list of clauses, each clause ((component . min-hours) …).
   practiced-hours-of : (lambda (skill) → validated hours) for THIS worker.

   Returns held ∪ the transitive closure of specs S such that some clause of S's
   satisfied-by is met — every component already in the closure AND practiced at
   ≥ its min hours. Fixpoint: the set only grows and is bounded by the catalogue,
   and the `(not (member …))` guard makes a self-referential satisfied-by harmless."
  (let loop ((have held))
    (let ((added
           (filter-map
            (lambda (entry)
              (let ((spec (car entry)) (dnf (or (cdr entry) '())))
                (and (not (member spec have))
                     (any (lambda (clause)
                            (every (lambda (comp)
                                     (let ((cs (car comp)) (minh (or (cdr comp) 0)))
                                       (and (member cs have)
                                            (>= (practiced-hours-of cs) minh))))
                                   clause))
                          dnf)
                     spec)))
            catalogue)))
      (if (null? added) have (loop (append added have))))))


(define* (lift-planning-facts recipe-store #:optional (observer #f)
                              (plan-store #f) (buffer-zone-store #f)
                              (live-registry #f)
                              (custody-creds '()))
  "Extract all planning facts. Recipes sorted by SNE (lowest first)."
  (let* ((all-recipes ($ recipe-store 'all-recipes))
         (chain-facts
           (filter-map
             (lambda (r)
               (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
                 (and (pair? chain)
                      `(chain ,(recipe-id r) ,(map recipe-process-id chain)))))
             all-recipes))
         (process-facts
           (append-map
             (lambda (r)
               (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
                 (map (lambda (rp)
                        (let ((mbq (recipe-process-minimum-batch-quantity rp)))
                          `(process ,(recipe-process-id rp)
                                    ,(recipe-process-name rp)
                                    ,(rp-duration-ms rp)
                                    ,(if mbq
                                         (inexact->exact
                                           (ceiling (measure-has-numerical-value mbq)))
                                         1))))
                      chain)))
             all-recipes))
         (flow-facts
           (append-map
             (lambda (r)
               (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
                 (append-map
                   (lambda (rp)
                     (let* ((pid (recipe-process-id rp))
                            (pair ($ recipe-store 'flows-for-process pid))
                            (inputs (car pair)) (outputs (cdr pair)))
                       (append
                         (map (lambda (f)
                                `(flow ,pid input
                                       ,(recipe-flow-resource-conforms-to f)
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-numerical-value
                                               (recipe-flow-resource-quantity f)))
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-unit
                                               (recipe-flow-resource-quantity f)))
                                       ,(recipe-flow-action f)
                                       ,(recipe-flow-resolve-from-flow f)
                                       ,(recipe-flow-id f)))
                              inputs)
                         (map (lambda (f)
                                `(flow ,pid output
                                       ,(recipe-flow-resource-conforms-to f)
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-numerical-value
                                               (recipe-flow-resource-quantity f)))
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-unit
                                               (recipe-flow-resource-quantity f)))
                                       ,(recipe-flow-action f)
                                       ,(recipe-flow-resolve-from-flow f)
                                       ,(recipe-flow-id f)))
                              outputs))))
                   chain)))
             all-recipes))
         (unsorted-recipes
           (map (lambda (r)
                  `(recipe ,(recipe-id r) ,(recipe-name r) ,(recipe-primary-output r)))
                all-recipes))
         (structural-facts (append unsorted-recipes chain-facts process-facts flow-facts))
         (sne-index (build-sne-index structural-facts))
         (sorted-recipes
           (sort unsorted-recipes
                 (lambda (a b)
                   (let ((sne-a (or (assoc-ref sne-index (cadddr a)) 999999))
                         (sne-b (or (assoc-ref sne-index (cadddr b)) 999999)))
                     (< sne-a sne-b)))))
         (spec-name-facts
           (map (lambda (rs)
                  `(spec-name ,(resource-specification-id rs)
                              ,(resource-specification-name rs)))
                ($ recipe-store 'all-resource-specs))))
    (append
      sorted-recipes chain-facts process-facts flow-facts
      spec-name-facts
      (if observer
          (filter-map
            (lambda (r)
              (let* ((rid (economic-resource-id r))
                     (live (and live-registry ($ live-registry 'get rid)))
                     (qty (if live
                              ($ live 'available)
                              (measure-qty (economic-resource-accounting-quantity r)))))
                (and (> qty 0)
                     `(inventory ,rid
                                ,(economic-resource-conforms-to r)
                                ,(inexact->exact (round qty))
                                ,(economic-resource-current-location r)
                                ,(economic-resource-contained-in r)))))
            ($ observer 'all-resources))
          '())
      (if observer
          (map (lambda (e)
                 `(event ,(economic-event-id e)
                         ,(economic-event-action e)
                         ,(economic-event-resource-conforms-to e)
                         ,(if (economic-event-resource-quantity e)
                              (inexact->exact (round (measure-has-numerical-value
                                (economic-event-resource-quantity e)))) 0)
                         ,(if (economic-event-has-point-in-time e)
                              (iso-datetime->epoch (economic-event-has-point-in-time e)) #f)))
               ($ observer 'all-events))
          '())
      (if plan-store
          (map (lambda (i)
                 `(intent ,(intent-id i) ,(intent-action i)
                          ,(intent-resource-conforms-to i)
                          ,(if (intent-resource-quantity i)
                               (inexact->exact (round (measure-has-numerical-value
                                 (intent-resource-quantity i)))) 0)
                          ,(if (intent-resource-quantity i)
                               (measure-has-unit (intent-resource-quantity i)) "each")
                          ,(if (intent-due i) (iso-datetime->epoch (intent-due i)) #f)
                          ,(if (intent-input-of i) 'input #f)
                          ,(if (intent-output-of i) 'output #f)
                          ,(or (intent-resource-classified-as i) '())
                          ,(intent-finished i)))
               ($ plan-store 'all-intents))
          '())
      (if plan-store
          (map (lambda (c)
                 `(commitment ,(commitment-id c) ,(commitment-action c)
                              ,(commitment-resource-conforms-to c)
                              ,(if (commitment-resource-quantity c)
                                   (inexact->exact (round (measure-has-numerical-value
                                     (commitment-resource-quantity c)))) 0)
                              ,(if (commitment-resource-quantity c)
                                   (measure-has-unit (commitment-resource-quantity c)) "each")
                              ,(if (commitment-due c) (iso-datetime->epoch (commitment-due c)) #f)
                              ,(commitment-provider c) ,(commitment-receiver c)
                              ,(commitment-finished c)))
               ($ plan-store 'all-commitments))
          '())
      (if buffer-zone-store
          (map (lambda (bz)
                 `(buffer-zone ,(buffer-zone-spec-id bz)
                               ,(buffer-zone-tor bz) ,(buffer-zone-toy bz)
                               ,(buffer-zone-tog bz) ,(buffer-zone-adu bz)
                               ,(buffer-zone-dlt-days bz)))
               ($ buffer-zone-store 'all-zones))
          '())
      (lift-custody-facts custody-creds))))


;;; ── Unified fact relations (ctx-aware, auto-indexed) ─────────────────────────
;;; Each takes a ctx (plan-ctx record) and auto-dispatches:
;;; indexed O(1)/O(R) when available, full scan O(N) otherwise.

(define (fact-recipe-o ctx rid name output)
  "Relate a recipe to its id, name, and output spec. Auto-indexed."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (let ((matches (idx-ref indexes 'recipes-by-output output)))
          (if (null? matches)
              fail
              (in-list-o `(recipe ,rid ,name ,output) matches)))
        (in-list-o `(recipe ,rid ,name ,output) (ctx-facts ctx)))))

(define (fact-chain-o ctx rid pids)
  "Relate a recipe to its process chain. O(1) when indexed."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (lambda (st)
          (let* ((walked (walk* rid (cstate-S st)))
                 (fact (idx-ref-single indexes 'chains-by-recipe walked)))
            (if fact ((== pids (caddr fact)) st) '())))
        (in-list-o `(chain ,rid ,pids) (ctx-facts ctx)))))

(define (fact-flow-o ctx pid direction spec-id qty unit action)
  "Relate a process to its flows. O(F) per process when indexed."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (lambda (st)
          (let* ((walked (walk* pid (cstate-S st)))
                 (matches (idx-ref indexes 'flows-by-process walked)))
            (if (null? matches)
                '()
                ((fresh (resolve-from flow-id)
                   (in-list-o `(flow ,walked ,direction ,spec-id ,qty ,unit
                                     ,action ,resolve-from ,flow-id)
                              matches))
                 st))))
        (fresh (resolve-from flow-id)
          (in-list-o `(flow ,pid ,direction ,spec-id ,qty ,unit
                            ,action ,resolve-from ,flow-id)
                     (ctx-facts ctx))))))

(define (fact-inventory-o ctx resource-id spec-id qty location)
  "Relate a resource to its inventory. O(I) per spec when indexed."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (let ((matches (idx-ref indexes 'inventory-by-spec spec-id)))
          (if (null? matches)
              fail
              (fresh (contained-in)
                (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location
                                      ,contained-in)
                           matches))))
        (fresh (contained-in)
          (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location
                                ,contained-in)
                     (ctx-facts ctx))))))

(define (fact-custodian-of-o ctx spec-id custodian-aid qty valid-from valid-until)
  "Relate a spec to its current custodian (per live ACDC attestation).
   O(C) per spec when indexed."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (let ((matches (idx-ref indexes 'custody-by-spec spec-id)))
          (if (null? matches)
              fail
              (in-list-o `(custodian-of ,spec-id ,custodian-aid ,qty
                                        ,valid-from ,valid-until)
                         matches)))
        (in-list-o `(custodian-of ,spec-id ,custodian-aid ,qty
                                  ,valid-from ,valid-until)
                   (ctx-facts ctx)))))

(define (fact-buffer-zone-o ctx spec-id tor toy tog adu dlt)
  "Relate a spec to its DDMRP buffer zone. O(1) when indexed."
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (let ((fact (idx-ref-single indexes 'buffer-by-spec spec-id)))
          (if fact
              (== `(buffer-zone ,spec-id ,tor ,toy ,tog ,adu ,dlt) fact)
              fail))
        (in-list-o `(buffer-zone ,spec-id ,tor ,toy ,tog ,adu ,dlt)
                   (ctx-facts ctx)))))


;;; ── Raw-facts variants (for code without a ctx) ─────────────────────────────

(define (recipe-o facts rid name output)
  (in-list-o `(recipe ,rid ,name ,output) facts))

(define (chain-o facts rid pids)
  (in-list-o `(chain ,rid ,pids) facts))

(define (process-o facts pid name duration-ms)
  (fresh (mbq)
    (in-list-o `(process ,pid ,name ,duration-ms ,mbq) facts)))

(define (flow-o facts pid direction spec-id qty unit action)
  (fresh (resolve-from flow-id)
    (in-list-o `(flow ,pid ,direction ,spec-id ,qty ,unit ,action ,resolve-from ,flow-id) facts)))

(define (inventory-o facts resource-id spec-id qty location)
  (fresh (contained-in)
    (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location ,contained-in) facts)))


;;; ��─ Legacy indexed aliases (for tests that call them directly) ──────────────

(define (recipe-indexed-o indexes output rid name)
  (let ((matches (idx-ref indexes 'recipes-by-output output)))
    (if (null? matches) fail
        (in-list-o `(recipe ,rid ,name ,output) matches))))

(define (chain-indexed-o indexes rid pids)
  (lambda (st)
    (let* ((walked (walk* rid (cstate-S st)))
           (fact (idx-ref-single indexes 'chains-by-recipe walked)))
      (if fact ((== pids (caddr fact)) st) '()))))

(define (flow-indexed-o indexes pid direction spec-id qty unit action)
  (lambda (st)
    (let* ((walked (walk* pid (cstate-S st)))
           (matches (idx-ref indexes 'flows-by-process walked)))
      (if (null? matches) '()
          ((fresh (resolve-from flow-id)
             (in-list-o `(flow ,walked ,direction ,spec-id ,qty ,unit
                               ,action ,resolve-from ,flow-id)
                        matches))
           st)))))

(define (inventory-indexed-o indexes spec-id resource-id qty location)
  (let ((matches (idx-ref indexes 'inventory-by-spec spec-id)))
    (if (null? matches) fail
        (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location) matches))))

(define (buffer-zone-indexed-o indexes spec-id tor toy tog adu dlt)
  (let ((fact (idx-ref-single indexes 'buffer-by-spec spec-id)))
    (if fact
        (== `(buffer-zone ,spec-id ,tor ,toy ,tog ,adu ,dlt) fact)
        fail)))
