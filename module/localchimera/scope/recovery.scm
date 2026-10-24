;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/scope/recovery.scm — restart hook for
;;; durable autonomous-signer scopes.
;;;
;;; A durable scope persists three things on disk under
;;; <state>/scopes/<aid>/:
;;;
;;;   acdc/   — its credential store (durable acdc-store layout)
;;;   kel/    — its KEL events (durable kel-store layout)
;;;   vault   — bran encrypted under LOCALCHIMERA_VAULT_KEY (when no Shamir
;;;             share-holders were configured at spawn time)
;;;
;;; When share-holders WERE configured, the bran is reconstituted from
;;; bran-share ACDCs in a designated share-store rather than vault.
;;;
;;; `restore-scope!` rebuilds a fully-functional `^scope` actor from
;;; that state: loads stores, recovers the bran, derives signing/next
;;; keypairs deterministically (HKDF), respawns the actor with the
;;; recovered material. The new actor's signatures validate against the
;;; original AID — proving end-to-end portability.
;;;
;;; `restore-all-scopes!` walks <state>/scopes/ and restores every scope
;;; with on-disk state. Designed to be called from the gateway boot
;;; path right after gateway-controller-init!.

(define-module (localchimera scope recovery)
  #:use-module ((localchimera keri key-state) #:select (rotation-count))
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 ftw)
  #:use-module ((ice-9 rdelim) #:select (read-line))
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  ;; read-scope-kind / write-scope-kind! live in (localchimera utils paths), so the
  ;; scope actor reads them without a cycle through (localchimera scope recovery).
  #:use-module ((localchimera utils paths)
                #:select (read-scope-kind write-scope-kind!))
  #:use-module ((localchimera keri signify-portable)
                #:select (bran->signing-keypair bran->next-keypair))
  #:use-module ((localchimera keys peers) #:select (peer-base-urls))
  #:use-module ((localchimera utils hex) #:select (bv->hex hex->bv))
  #:use-module (localchimera keys bran-custody)
  #:use-module (localchimera keys kel-store)
  #:use-module (localchimera utils paths)
  #:use-module (localchimera scope actor)
  #:use-module (localchimera keri acdc-store)
  #:use-module (localchimera keri witness-publisher)
  #:export (scope-state-on-disk?
            list-known-scopes
            restore-scope!
            restore-all-scopes!
            find-universal-commune-aid)
  #:re-export (read-scope-kind write-scope-kind!))

(define (scope-state-on-disk? aid)
  "Returns #t iff <state>/scopes/<aid>/ has at least an acdc subdir."
  (and (file-exists? (scope-state-dir aid))
       (file-exists? (scope-acdc-dir aid))))

(define (list-known-scopes)
  "Walk <state>/scopes/ for subdirectories that look like scope state.
   Returns a list of AID prefixes (the directory names)."
  (let ((dir (string-append (localchimera-state-dir) "/scopes")))
    (cond
     ((not (file-exists? dir)) '())
     (else
      (or (scandir dir
                   (lambda (entry)
                     (and (not (member entry '("." "..")))
                          (file-exists?
                           (string-append dir "/" entry "/acdc"))
                          (file-exists?
                           (string-append dir "/" entry "/kel")))))
          '())))))

(define* (restore-scope! aid
                         #:key
                         (kind 'commune)
                         (name #f)
                         (scope-root-ref #f)
                         (mycapn-ref #f)
                         (members (hashmap))
                         (share-store #f)
                         (threshold 1)
                         (keri-backend #f)
                         (witness #f)
                         (kel-events #f)
                         (witness-urls '())
                         (custodians '()))
  "Rebuild a `^scope` actor for AID from its on-disk state.

   Lookup order for bran recovery:
     1. <state>/scopes/<aid>/vault (vault mode, single host).
     2. SHARE-STORE searched for ≥THRESHOLD bran-share ACDCs naming AID
        as `subject-aid` (Shamir mode, federation distributed).

   Errors when neither path yields a bran or when the on-disk state
   is incomplete.

   WITNESS-URLS: explicit fallback list for KEL recovery when local
   kel/ is empty. When unset (default '()), automatically populated
   from `(peer-base-urls)` — every LOCALCHIMERA_PEERS entry doubles as a
   KEL-fetch source. Pillar #45: multi-gateway witness pool
   coordination falls out for free, since every peer gateway already
   serves /oobi/{aid} for any scope its KERIA knows about.

   Returns the restored `^scope` ref. The new actor signs new ACDCs
   under the original AID — proving end-to-end recoverability."
  ;; Allow recovery from witness mirror even when no local state exists.
  (let* ((have-local? (scope-state-on-disk? aid))
         (acdc-dir   (scope-acdc-dir aid))
         (kel-dir    (scope-kel-dir aid))
         (vault-path (scope-vault-path aid))
         (_ (when have-local? #t))   ;; just here for clarity
         (_ (ensure-directory! acdc-dir))
         (_ (ensure-directory! kel-dir))
         (acdc-store (spawn-acdc-store #:durable-dir acdc-dir))
         (kel-store  (spawn-kel-store  #:durable-dir kel-dir #:aid aid))
         ;; If the local kel-store is empty, replay events from the
         ;; first available source: pre-fetched (cross-vat caller),
         ;; same-vat witness ref, or one of WITNESS-URLS over HTTP.
         ;; Multi-gateway witness coordination: when the operator
         ;; didn't supply witness-urls, fall back to every peer
         ;; gateway in LOCALCHIMERA_PEERS. Each peer's /oobi/{aid} serves
         ;; the CESR KEL stream for any scope its KERIA knows about,
         ;; so peers are de-facto witness pools for each other.
         (effective-witness-urls
          (cond ((pair? witness-urls) witness-urls)
                (else (peer-base-urls))))
         (_replay-into-kel
          (when (zero? ($ kel-store 'count))
            (let ((events
                   (cond
                    (kel-events kel-events)
                    (witness    ($ witness 'kel-for aid))
                    ((pair? effective-witness-urls)
                     (let loop ((urls effective-witness-urls))
                       (cond
                        ((null? urls) '())
                        (else
                         (let ((evs (keri-fetch-kel-from-witness
                                     (car urls) aid)))
                           (cond
                            ((pair? evs) evs)
                            (else (loop (cdr urls)))))))))
                    (else '()))))
              (for-each (lambda (e) ($ kel-store 'append e)) events))))
         (bran (cond
                ((file-exists? vault-path)
                 (read-vault-bran vault-path))
                ((pair? custodians)
                 (reconstitute-bran-from-custodians custodians threshold))
                (share-store
                 (reconstitute-bran-from-store share-store aid threshold))
                (else
                 (error "restore-scope!: no vault, custodians, or share-store"
                        aid))))
         (bran-str (bv->hex bran))
         ;; the keys at the depth the log has reached: a scope that rotated n
         ;; times signs with the n-th keypair and has committed to the (n+1)-th,
         ;; so a restart signs as the log says and can rotate again
         (depth    (rotation-count ($ kel-store 'all)))
         (derive   (rotation-keypair-fn bran))
         (kp       (if (zero? depth) (bran->signing-keypair bran-str) (derive depth)))
         (nkp      (if (zero? depth) (bran->next-keypair bran-str) (derive (+ depth 1)))))
    (register-rotation-keypair-fn! aid derive)
    (spawn-scope (or name aid)
                 #:kind kind
                 #:scope-aid aid
                 #:scope-root-ref scope-root-ref
                 #:mycapn-ref mycapn-ref
                 #:members members
                 #:keri-backend keri-backend
                 #:durable? #t
                 #:acdc-store acdc-store
                 #:kel-store  kel-store
                 #:keypair    kp
                 #:next-keypair nkp)))

(define* (restore-all-scopes! #:key
                              (share-store #f)
                              (threshold 1)
                              (kind 'commune)
                              (keri-backend #f))
  "Walk <state>/scopes/ and `restore-scope!` each. Returns an alist
   ((aid . scope-ref) …). Errors that prevent restoring an individual
   scope are caught and logged; the others continue.

   When a per-scope `kind` file exists on disk (written by `spawn-scope`
   for durable scopes), that overrides the `#:kind` keyword default —
   so a mixed deployment (communes + federations + UC) restores each
   scope with its correct kind without the caller needing to know the
   kinds in advance. The `#:kind` keyword remains the fallback for
   pre-promotion scopes that lack a kind file."
  (filter-map
   (lambda (aid)
     (catch #t
       (lambda ()
         (let ((on-disk-kind (read-scope-kind aid)))
           (cons aid (restore-scope! aid
                                     #:kind (or on-disk-kind kind)
                                     #:share-store share-store
                                     #:threshold threshold
                                     #:keri-backend keri-backend))))
       (lambda (key . args)
         ;; Log to STDOUT (captured) not stderr — a silent stderr restore
         ;; failure here hid the UC-churn bug for a long time.
         (format (current-output-port)
                 "  [scope-recovery] failed to restore ~a: ~a ~a~%"
                 aid key args)
         (force-output (current-output-port))
         #f)))
   (list-known-scopes)))

;;; ── UC discovery ─────────────────────────────────────────────────────────

(define (find-universal-commune-aid)
  "Scan known scopes for the one with kind = 'universal-commune.
   Returns the AID or #f. Asserts at most one UC exists per host (the
   gateway enforces this on spawn — see universal-commune.scm — but
   the boot path double-checks to catch corruption.)"
  (let ((ucs (filter (lambda (aid)
                       (eq? (read-scope-kind aid) 'universal-commune))
                     (list-known-scopes))))
    (cond
     ((null? ucs) #f)
     ((null? (cdr ucs)) (car ucs))
     (else
      ;; Multiple UCs on disk — a stray mint (concurrent boots have raced
      ;; this). RECOVER deterministically rather than bricking the boot:
      ;; prefer the AID recorded in universal-commune-aid.txt (the canonical
      ;; the gateway persisted), else the lexicographically-first. The stray
      ;; should be cleaned up out-of-band, but the dial must never lose its
      ;; commune over it.
      (let* ((aid-file (string-append (localchimera-state-dir)
                                      "/universal-commune-aid.txt"))
             (recorded (and (file-exists? aid-file)
                            (catch #t
                              (lambda ()
                                (call-with-input-file aid-file
                                  (lambda (port)
                                    (let ((l (read-line port)))
                                      (and (string? l) (string-trim-both l))))))
                              (lambda _ #f)))))
        (if (and (string? recorded) (member recorded ucs))
            recorded
            (car (sort ucs string<?))))))))
