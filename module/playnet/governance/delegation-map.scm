;;; delegation-map.scm — per-citizen universal delegation with scope overrides
;;;                      and optional per-entry instructed mandates
;;;
;;; One ^delegation-map per citizen. Each entry is (fraction . mandate):
;;;   fraction ∈ (0, 1]
;;;   mandate  = #f (liquid — delegate votes freely with this voice)
;;;            OR procedure (cleartext-stance → bool; delegate's stance
;;;                          must satisfy, else the voice is abstained)
;;;
;;; Delegation entries are scoped:
;;;   federation-default  — applies to every ballot
;;;   scope-overrides[s]  — replaces per-delegate entries in scope s
;;;
;;; Resolve rule for franchise F:
;;;   F == 'federation      → federation-default
;;;   F == ('scope sid)     → federation-default with each key present in
;;;                           scope-overrides[sid] replaced by the override
;;;                           entry (so overrides win per-delegate)
;;;
;;; Validation on delegate-*: for every affected franchise, resolved-map
;;; fraction-sum must be ≤ 1.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.

(define-module (playnet governance delegation-map)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials delegation)
  #:use-module (playnet keri acdc)
  #:use-module (goblins utils hashmap)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (make-entry entry-fraction entry-mandate delegation-sum merge-overrides
            resolve-delegation scope-ids-of would-self-cycle? mandate-satisfied?
            rest->franchise set-entry ^delegation-map spawn-delegation-map
            delegation-map-env))

;; =========================================================================
;; Entry accessors
;; =========================================================================

(define (make-entry fraction mandate)
  "Construct a delegation entry. mandate = #f for liquid, or a predicate."
  (cons fraction mandate))

(define (entry-fraction e) (car e))
(define (entry-mandate e)  (cdr e))


;; =========================================================================
;; Pure helpers: merge + validation
;; =========================================================================

(define (delegation-sum entries)
  "Sum the fractions across a delegate→entry hashmap."
  (hashmap-fold (lambda (_k e acc) (+ (entry-fraction e) acc))
                0 entries))

(define (merge-overrides federation-default overrides)
  "Return federation-default with each key in overrides replaced by the
   override's entry. Keys only in federation-default are retained."
  (hashmap-fold
    (lambda (k e acc) (hashmap-set acc k e))
    federation-default
    overrides))

(define (resolve-delegation federation-default scope-overrides franchise)
  "Return the applicable delegate→entry hashmap for FRANCHISE.
   FRANCHISE: 'federation  OR  (list 'scope scope-id)"
  (cond
    ((eq? franchise 'federation) federation-default)
    ((and (pair? franchise) (eq? (car franchise) 'scope))
     (let* ((sid (cadr franchise))
            (override (hashmap-ref scope-overrides sid #f)))
       (if override
           (merge-overrides federation-default override)
           federation-default)))
    (else (error "Unknown franchise spec" franchise))))

(define (scope-ids-of scope-overrides)
  "List of scope-ids that currently have override entries."
  (hashmap-fold (lambda (k _v acc) (cons k acc)) '() scope-overrides))


;; =========================================================================
;; Cycle detection (intra-citizen safety)
;; =========================================================================

(define (would-self-cycle? delegator proposed-delegate)
  "Reject the trivial self-cycle: A delegating to A.
   Cross-citizen cycle detection requires walking other citizens'
   delegation maps; we don't hold those refs here, so rely on the
   tally's recursion guard for cross-citizen cycle safety."
  (equal? delegator proposed-delegate))


;; =========================================================================
;; Mandate satisfaction
;; =========================================================================

(define (mandate-satisfied? mandate cleartext-stance)
  "#t if no mandate (liquid) OR the mandate procedure accepts the stance.
   cleartext-stance: (list 'stance proposal-id position citizen-id), or #f
                     if delegate did not cast."
  (cond
    ((not mandate) #t)                                   ; liquid — always OK
    ((not cleartext-stance) #f)                          ; must-act — delegate didn't cast
    (else (mandate cleartext-stance))))


;; =========================================================================
;; set-entry — shared write path for delegate / delegate-mandated
;; =========================================================================

(define (split-rest rest)
  "Split a (delegate)-method's rest-args into (values franchise-rest at).
   The protocol, backward-compatible — every pre-existing caller passes
   one of the first two shapes untouched:
   '()                      → '()               #f
   ('scope SID)             → ('scope SID)      #f
   ('at AT)                 → '()               AT
   ('scope SID 'at AT)      → ('scope SID)      AT"
  (cond
    ((and (pair? rest) (eq? (car rest) 'at) (pair? (cdr rest)))
     (values '() (cadr rest)))
    ((and (= (length rest) 4) (eq? (car rest) 'scope) (eq? (caddr rest) 'at))
     (values (list (car rest) (cadr rest)) (cadddr rest)))
    (else (values rest #f))))

(define (rest->franchise rest)
  "Convert a (delegate)-method's FRANCHISE rest-args (post split-rest) to
   a franchise spec.
   '()                    → 'federation
   ('scope SID)           → (list 'scope SID)"
  (cond
    ((null? rest) 'federation)
    ((and (pair? rest) (eq? (car rest) 'scope) (pair? (cdr rest)))
     (list 'scope (cadr rest)))
    (else (error "Bad franchise rest-args" rest))))

(define* (set-entry bcom citizen-id federation-default scope-overrides
                    acdc-store delegate-id entry rest #:optional (signature #f))
  "Common write path. rest is the remaining args after (D F) or (D F PRED):
   '() for federation-default, ('scope SID) for a scope override — either
   optionally followed by ('at TIMESTAMP), split off by split-rest. AT
   rides the delegation ACDC's claims so each write mints a fresh SAID:
   the UNSIGNED path stamps iso-utc-now itself when the caller passes
   none; the SIGNED path takes it only from the caller (the client signed
   a specific SAID — the server must rebuild exactly that credential).
   If acdc-store is non-#f, also issues a delegation ACDC.

   SIGNATURE, when supplied, is the CITIZEN's own KERI signature over the
   delegation ACDC's SAID (a delegation is the citizen's assertion, so it is
   only a conformant ACDC when the citizen's controller signs it — and that key
   is client-side, so the service verifies + threads it here). The credential
   the service verified is rebuilt identically below, so the SAID — and thus the
   signature — matches."
  (let ((fraction (entry-fraction entry)))
    (when (or (<= fraction 0) (> fraction 1))
      (error "Delegation fraction must be in (0, 1]" fraction)))
  ;; Reject self-cycle (A → A). Cross-citizen cycles are caught at tally
  ;; time by the recursion guard, since walking other citizens'
  ;; delegation maps would require holding refs to all of them here.
  (when (would-self-cycle? citizen-id delegate-id)
    (error "Self-delegation cycle: citizen cannot delegate to themself"
           citizen-id))
  (call-with-values (lambda () (split-rest rest))
    (lambda (rest at*)
  (let* ((at (or at* (and (not signature) (iso-utc-now))))
         (emit-acdc!
          (lambda ()
            (when acdc-store
              ;; Re-delegating SUPERSEDES: revoke the prior credential(s) for
              ;; this (delegate, franchise) before issuing, so the store's
              ;; LIVE set is the state — at most one credential per key, and
              ;; recovery's replay cannot resurrect a superseded fraction
              ;; (the delegation-recovery law: recover(store) ≡ the live map).
              (let ((franchise (rest->franchise rest)))
                (for-each
                 (lambda (c) ($ acdc-store 'revoke (cred-said c)))
                 (filter (lambda (c)
                           (and (not (cred-revoked? c))
                                (equal? (cred-holder c) delegate-id)
                                (equal? (assq-ref (cred-claims c) 'franchise)
                                        franchise)))
                         ($ acdc-store 'by-issuer citizen-id))))
              (let* ((m (entry-mandate entry))
                     (mandate-spec (and m (mandate-spec-of m)))
                     (cred (make-delegation-credential
                             citizen-id delegate-id
                             (rest->franchise rest)
                             (entry-fraction entry)
                             mandate-spec
                             #:at at)))
                ;; a SIGNED write with no AT can still rebuild a SAID the
                ;; supersede history already revoked (returning to a prior
                ;; fraction) — the store's collision error was opaque and
                ;; aborted the whole write; name the way out instead
                (catch #t
                  (lambda ()
                    ($ acdc-store 'issue
                       (if signature (cred-with-signature cred signature) cred)))
                  (lambda (key . args)
                    (error "delegation ACDC collides with a superseded credential — pass ('at TIMESTAMP) in the franchise args so the re-assertion mints a fresh SAID" args))))))))
    (cond
      ;; Federation-default
      ((null? rest)
       (let ((new-default (hashmap-set federation-default delegate-id entry)))
         (when (> (delegation-sum new-default) 1)
           (error "Federation-default delegation sum > 1"
                  (delegation-sum new-default)))
         (for-each
           (lambda (sid)
             (let* ((override (hashmap-ref scope-overrides sid (hashmap)))
                    (resolved (merge-overrides new-default override)))
               (when (> (delegation-sum resolved) 1)
                 (error "Scope override sum > 1 after federation update"
                        sid (delegation-sum resolved)))))
           (scope-ids-of scope-overrides))
         (emit-acdc!)
         (bcom (^delegation-map bcom citizen-id new-default scope-overrides
                                 acdc-store))))
      ;; Scope-specific override
      ((and (pair? rest) (eq? (car rest) 'scope) (pair? (cdr rest)))
       (let* ((sid (cadr rest))
              (current-override (hashmap-ref scope-overrides sid (hashmap)))
              (new-override (hashmap-set current-override delegate-id entry))
              (resolved (merge-overrides federation-default new-override)))
         (when (> (delegation-sum resolved) 1)
           (error "Scope override sum > 1" sid (delegation-sum resolved)))
         (emit-acdc!)
         (bcom (^delegation-map bcom citizen-id federation-default
                  (hashmap-set scope-overrides sid new-override)
                  acdc-store))))
      (else (error "Bad delegate args" rest)))))))


;; =========================================================================
;; ^delegation-map — persistent Goblins actor
;; =========================================================================

(define-actor (^delegation-map bcom
                               citizen-id
                               federation-default   ;; delegate -> <entry>
                               scope-overrides      ;; scope-id -> (delegate -> <entry>)
                               acdc-store)          ;; ^acdc-store ref or #f

  ;; Deliberately no #:portrait/#:restore. entries can hold a live mandate
  ;; predicate (a procedure), which can't survive any generic serialization
  ;; scheme — a native Goblins portrait would either crash or have to
  ;; silently strip it. The REAL recovery path already exists and is
  ;; strictly better: recover-delegation-map (governance/recovery.scm)
  ;; replays this citizen's non-revoked playnet-delegation ACDCs from
  ;; ACDC-STORE and recompiles each mandate from its DSL spec via
  ;; compile-mandate-spec — so a DSL-built mandate (the `mandate` helper
  ;; in credentials.scm) actually survives a restart intact, not just its
  ;; fraction. It's tested (tests/governance/test-recovery.scm) but not
  ;; yet wired into any boot path — that's the integration gap to close,
  ;; not a reason to add a second, inconsistent, lossier recovery
  ;; mechanism here.

  (methods

    ;; --- Reads ---

    ((citizen-id) citizen-id)

    ((entries)
     (cons federation-default scope-overrides))

    ((resolve-for franchise)
     (resolve-delegation federation-default scope-overrides franchise))

    ((federation-default) federation-default)

    ((scope-overrides) scope-overrides)

    ((acdc-store) acdc-store)

    ((direct-fraction-for franchise)
     (let ((resolved (resolve-delegation federation-default scope-overrides
                                          franchise)))
       (- 1 (delegation-sum resolved))))

    ((snapshot)
     (cons federation-default scope-overrides))

    ;; --- Writes ---
    ;;
    ;; delegate (liquid, no mandate):
    ;;   (delegate D F)                   -> federation-default
    ;;   (delegate D F 'scope SID)        -> scope override
    ;;
    ;; delegate-mandated (instructed):
    ;;   (delegate-mandated D F PRED)               -> federation-default w/ mandate
    ;;   (delegate-mandated D F PRED 'scope SID)    -> scope override w/ mandate
    ;;
    ;; revoke:
    ;;   (revoke D)                       -> from federation-default
    ;;   (revoke D 'scope SID)            -> from a specific scope override
    ;;
    ;; If acdc-store is non-#f, every write also issues (or revokes) a
    ;; corresponding playnet-delegation ACDC.

    ((delegate delegate-id fraction . rest)
     (set-entry bcom citizen-id federation-default scope-overrides
                acdc-store delegate-id (make-entry fraction #f) rest))

    ;; As `delegate`, but the delegation ACDC carries the citizen's own KERI
    ;; SIGNATURE (verified by the service before it reaches here). Liquid.
    ((delegate-signed delegate-id fraction signature . rest)
     (set-entry bcom citizen-id federation-default scope-overrides
                acdc-store delegate-id (make-entry fraction #f) rest signature))

    ((delegate-mandated delegate-id fraction mandate . rest)
     (unless (procedure? mandate)
       (error "Mandate must be a procedure" mandate))
     (set-entry bcom citizen-id federation-default scope-overrides
                acdc-store delegate-id (make-entry fraction mandate) rest))

    ;; Mandated + client-signed. MANDATE is the compiled predicate the service
    ;; built from the client's mandate *spec* via `(mandate spec)` — which
    ;; registers spec↔predicate, so set-entry's `mandate-spec-of` recovers the
    ;; exact spec the client signed over, and the rebuilt SAID matches the
    ;; signature. (A raw closure could never cross the wire; the spec can, and
    ;; the citizen signs the credential carrying it — see service.scm.)
    ((delegate-mandated-signed delegate-id fraction mandate signature . rest)
     (unless (procedure? mandate)
       (error "Mandate must be a procedure" mandate))
     (set-entry bcom citizen-id federation-default scope-overrides
                acdc-store delegate-id (make-entry fraction mandate) rest signature))

    ((revoke delegate-id . rest)
     ;; Find and revoke the matching ACDC if acdc-store is set.
     (when acdc-store
       (let* ((franchise (rest->franchise rest))
              (matches
                (filter
                  (lambda (c)
                    (let ((cl (cred-claims c)))
                      (and (not (cred-revoked? c))
                           (equal? (cred-issuer c) citizen-id)
                           (equal? (cred-holder c) delegate-id)
                           (equal? (assq-ref cl 'franchise) franchise))))
                  ($ acdc-store 'by-issuer citizen-id))))
         (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c))) matches)))
     (cond
       ((null? rest)
        (bcom (^delegation-map bcom citizen-id
                 (hashmap-remove federation-default delegate-id)
                 scope-overrides acdc-store)))
       ((and (pair? rest) (eq? (car rest) 'scope) (pair? (cdr rest)))
        (let* ((sid (cadr rest))
               (current-override (hashmap-ref scope-overrides sid (hashmap)))
               (new-override (hashmap-remove current-override delegate-id))
               (new-scope-overrides
                 (if (= 0 (hashmap-fold (lambda (_k _v a) (+ a 1)) 0 new-override))
                     (hashmap-remove scope-overrides sid)
                     (hashmap-set scope-overrides sid new-override))))
          (bcom (^delegation-map bcom citizen-id federation-default
                                  new-scope-overrides acdc-store))))
       (else (error "Bad revoke args" rest))))))


;; =========================================================================
;; Spawn helper
;; =========================================================================

(define* (spawn-delegation-map citizen-id #:key (acdc-store #f))
  "Create an empty delegation-map for a citizen. Optionally takes an
   acdc-store ref — if provided, every mutation issues or revokes a
   playnet-delegation ACDC. Must be called within a vat context."
  (spawn ^delegation-map citizen-id (hashmap) (hashmap) acdc-store))


;; =========================================================================
;; Persistence
;; =========================================================================

(define delegation-map-env
  (make-persistence-env
    `((((playnet governance) ^delegation-map) ,^delegation-map))))
