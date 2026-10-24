;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/audits.scm — the auditors and custody watchers ticking over every restored scope.
;;;
;;; Wires the already-existing ^federation-auditor (one per federation/UC
;;; scope) and ^custody-half-life-watcher (one per scope of any kind) into
;;; periodic-fire fibers. Auditor emits audit-pass / incoherence-alert ACDCs
;;; into the federation's own acdc-store — Phase 6 IPEX push then propagates
;;; them to peers. Watcher emits reversion-attestation on expired
;;; custody-attestation credentials.

(define-module (localchimera boot audits)
  #:use-module ((localchimera boot restore) #:select (restored-aid restored-kind restored-ref restored-vat))
  #:use-module ((localchimera boot site) #:select (log!))
  #:use-module ((localchimera federation auditor) #:select (spawn-custody-half-life-watcher spawn-federation-auditor))
  #:use-module ((localchimera utils common) #:select (env-int))
  #:use-module (fibers)
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (watch-scopes!))

(define (watch-scopes! restored)
  "The monitors over RESTORED. (values auditors watchers), each an alist of
aid → actor. Future scopes spawned at runtime pick up monitors on the next
gateway restart."
  (define %audit-interval-sec
    (env-int "LOCALCHIMERA_AUDIT_INTERVAL_SEC" 3600))    ; 1h default
  (define %custody-tick-sec
    (env-int "LOCALCHIMERA_CUSTODY_TICK_SEC"   21600))   ; 6h default

  (define (spawn-audit-fiber! actor-ref method interval-sec label vat)
    "Generic: tick ACTOR-REF.METHOD every INTERVAL-SEC in VAT (the
     monitored actor's vat). Logs each fire so audit cycles are
     visible; catches per-tick errors so one bad cycle doesn't kill
     the fiber."
    (spawn-fiber
     (lambda ()
       (let loop ()
         (sleep interval-sec)
         (catch #t
           (lambda ()
             (let ((result (with-vat vat
                             ($ actor-ref method))))
               (log! "  [gateway] ~a tick: ~a~%" label result)))
           (lambda (key . args)
             (log! "  [gateway] ~a tick error: ~a ~a~%"
                   label key args)))
         (loop)))))

  (define auditors '())       ; alist aid → auditor-ref
  (define watchers '())       ; alist aid → watcher-ref

  (define (wire-scope-monitors! r)
    "Spawn auditor (for federation/UC kinds) + custody-watcher
     (for any kind that issues custody-attestation creds) and the
     fibers that tick them. Idempotent per scope-aid; second call
     is a no-op."
    (define scope-aid  (restored-aid r))
    (define scope-ref  (restored-ref r))
    (define scope-kind (restored-kind r))
    (define monitor-vat (restored-vat r))
    (define (label kind)
      (format #f "~a[~a]" kind (substring scope-aid 0 (min 12 (string-length scope-aid)))))
    (unless (assoc scope-aid auditors)
      (when (memq scope-kind '(federation universal-commune))
        (let ((auditor (with-vat monitor-vat
                         (spawn-federation-auditor scope-ref))))
          (set! auditors (cons (cons scope-aid auditor) auditors))
          (spawn-audit-fiber! auditor 'audit! %audit-interval-sec (label "auditor") monitor-vat))))
    (unless (assoc scope-aid watchers)
      ;; Default custodian on expiry: the scope itself (resources
      ;; revert to scope custody). Operators can override later.
      (let ((watcher (with-vat monitor-vat
                       (spawn-custody-half-life-watcher
                        scope-ref
                        (lambda (_spec) scope-aid)))))
        (set! watchers (cons (cons scope-aid watcher) watchers))
        (spawn-audit-fiber! watcher 'tick! %custody-tick-sec (label "custody") monitor-vat))))

  (for-each wire-scope-monitors! restored)
  (log! "  [gateway] scheduled ~a auditor(s), ~a custody-watcher(s)~%"
        (length auditors) (length watchers))
  (values auditors watchers))
