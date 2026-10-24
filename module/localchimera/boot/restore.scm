;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/restore.scm — the durable scopes restored into their vats, and replayed from their credentials.
;;;
;;; A scope's home vat by kind: governance roots (UC, federations) live in
;;; the gateway vat; economic communes in the planner vat. Restore AND every
;;; later read must use the scope's own vat — a $ on a ref from another vat
;;; throws "Not in the same vat: ^scope" — so each restored scope carries its
;;; vat, and the boot reads it off the record instead of re-reading the
;;; scope's kind from disk.

(define-module (localchimera boot restore)
  #:use-module ((localchimera boot site) #:select (log! scopes-durable?))
  #:use-module ((localchimera federation rebuild) #:select (recover-ballots-into-scope! recover-commune-state
                                                       recover-federation-state recover-lineage))
  #:use-module ((localchimera keys keri-backend live) #:select (live-keri-backend))
  #:use-module ((localchimera scope recovery) #:select (list-known-scopes restore-scope!))
  #:use-module ((localchimera utils paths) #:select (localchimera-state-dir read-scope-kind scope-vault-path))
  #:use-module ((goblins utils hashmap) #:select (hashmap hashmap-set))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((srfi srfi-1) #:select (filter-map find fold partition))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (<restored> make-restored restored? restored-aid restored-kind restored-ref restored-vat
            restored-scope restore-scopes! replay-scope-state!))

(define-record-type <restored>
  (make-restored aid kind ref vat)
  restored?
  (aid  restored-aid)      ; the scope's AID
  (kind restored-kind)     ; commune | federation | universal-commune
  (ref  restored-ref)      ; the live ^scope
  (vat  restored-vat))     ; the vat it lives in

(define (restored-scope restored aid)
  "The live ^scope restored for AID among RESTORED, or #f."
  (and=> (find (lambda (r) (equal? aid (restored-aid r))) restored) restored-ref))

(define (restore-scopes! gateway-vat planner-vat earth meeting-scope)
  "Every durable scope on disk restored into its vat: governance roots into
GATEWAY-VAT, communes into PLANNER-VAT re-linked to their own economic root
under EARTH (MEETING-SCOPE, the founding commune's, for any scope earth
does not yet carry). The list of <restored>, empty unless
LOCALCHIMERA_SCOPES_DURABLE. NOT gated on KERIA_BRAN: restore uses the live
backend itself. Restoring lets the UC and the founding commune keep their
persisted AIDs instead of re-minting one every boot."
  (define (vat-for-scope-kind kind)
    (if (memq kind '(federation universal-commune)) gateway-vat planner-vat))
  (define (restore-one aid)
    (let* ((kind (or (read-scope-kind aid) 'commune))
           (vat  (vat-for-scope-kind kind)))
      (catch #t
        (lambda ()
          (make-restored
           aid kind
           (with-vat vat
             (if (memq kind '(federation universal-commune))
                 (restore-scope! aid #:kind kind
                                 #:keri-backend (live-keri-backend))
                 ;; a commune re-links to its OWN economic root under
                 ;; earth (keyed by aid), durably restored with its own
                 ;; state; falls back to meeting-scope (the founding
                 ;; commune) for any scope earth doesn't yet carry.
                 (restore-scope! aid #:kind kind
                                 #:scope-root-ref (or ($ earth 'commune aid) meeting-scope)
                                 #:keri-backend (live-keri-backend))))
           vat))
        (lambda (key . args)
          (log! "  [scope-recovery] failed to restore ~a: ~a ~a~%" aid key args)
          #f))))
  (if (not (scopes-durable?))
      '()
      (catch #t
        (lambda ()
          ;; Restorable here means the bran vault is on disk: this loop
          ;; passes no share-store and no custodians, so a dir without a
          ;; vault can only ever fail with "no vault, custodians, or
          ;; share-store" — once per dir, every boot. Vault-less dirs are
          ;; either SYNTHETIC scopes (no bran was ever minted; they
          ;; re-create deterministically below, so skipping IS their
          ;; restore path) or the remnants of live mints that died before
          ;; their bran persisted (spawn-scope sweeps its own now, but
          ;; older ones linger). One summary line, not a page of noise.
          (define-values (restorable vaultless)
            (partition (lambda (aid) (file-exists? (scope-vault-path aid)))
                       (list-known-scopes)))
          (when (pair? vaultless)
            (log! "  [gateway] ~a scope dir(s) carry no bran vault — synthetic scopes re-mint below; failed-mint remnants can be cleared with rm -r ~a/scopes/<aid>~%"
                  (length vaultless) (localchimera-state-dir)))
          (let ((restored (filter-map restore-one restorable)))
            (log! "  [gateway] restored ~a durable scope(s)~%" (length restored))
            restored))
        (lambda (key . args)
          (log! "  [gateway] scope-restore error: ~a ~a~%" key args)
          '()))))

;; ── Replay governance state from ACDCs into the restored scopes ──
;; restore-scope! only rebuilds a ^scope's identity (KEL + ACDC store +
;; keypair) — a fresh commune/federation actor still comes back with empty
;; `excluded`/`members`/`lineage`, even though the ACDCs proving exclusions,
;; CCF assessments, and federation memberships are sitting right there in
;; the just-restored acdc-store. (localchimera federation rebuild) exists
;; precisely for this — replaying non-revoked ACDCs back into live actor
;; state — and is exercised by tests/org/test-recovery.scm. A second
;; pass over the whole list, because federation recovery needs every
;; commune ref already restored to resolve commune-id → live ref.
(define (replay-scope-state! restored)
  "Each scope of RESTORED replayed from its own credential store, in its vat."
  (unless (null? restored)
    (let ((communes-by-id
           (fold (lambda (r acc)
                   (if (eq? (restored-kind r) 'commune)
                       (hashmap-set acc (restored-aid r) (restored-ref r))
                       acc))
                 (hashmap) restored)))
      (for-each
       (lambda (r)
         (let ((aid (restored-aid r)) (scope-ref (restored-ref r)) (kind (restored-kind r)))
           (catch #t
             (lambda ()
               (with-vat (restored-vat r)
                (let ((store ($ scope-ref 'acdc-store)))
                  (when store
                    (case kind
                      ((commune)
                       (recover-commune-state scope-ref store))
                      ((federation universal-commune)
                       (recover-federation-state scope-ref store communes-by-id)))
                    (recover-lineage scope-ref store)
                    ;; Ballots: rebuild this scope's OWN ballots index
                    ;; from its snapshot + stance ACDCs, so a ballot that
                    ;; predates the restart is findable by get-ballot /
                    ;; close-ballot again.
                    ;;
                    ;; Safe at boot only because ^ballot's verifier now
                    ;; accepts KERI-signed stances, which verify against
                    ;; a self-certifying AID and need no registry entry.
                    ;; The sealer registry is necessarily EMPTY at boot
                    ;; (no citizen has reconnected, and Goblins sealers
                    ;; can't be reconstructed anyway), so under the old
                    ;; registry-only verifier this would have produced
                    ;; ballots nobody could cast on.
                    (let ((sr ($ scope-ref 'scope-root)))
                      (when sr
                        (recover-ballots-into-scope!
                         scope-ref store ($ sr 'ballot-store) (hashmap))))))))
             (lambda (key . args)
               (log! "  [scope-recovery] state-replay failed for ~a (~a): ~a ~a~%"
                     aid kind key args)))))
       restored)
      (log! "  [gateway] replayed governance state for ~a restored scope(s)~%"
            (length restored)))))
