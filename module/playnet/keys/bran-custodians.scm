;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keys/bran-custodians.scm — periodic ping
;;; of Shamir bran-share custodians; raises an alert when reachability
;;; drops below the configured threshold so the operator knows BEFORE
;;; recovery is needed that shares are unreachable.
;;;
;;; Two complementary mechanisms cover bran-custody resilience:
;;;
;;;   - keys/bran-custody.scm's ^bran-custodian actors hold one share each
;;;     and expose 'identify + 'release-share. They're passive — they
;;;     respond when polled.
;;;
;;;   - ^custodian-heartbeat (this file) polls each registered
;;;     custodian on a schedule; if fewer than THRESHOLD respond,
;;;     emits an incoherence-alert ACDC (same schema the federation
;;;     auditor uses) so /audit/{scope-aid}.json surfaces the issue.
;;;
;;; The actor is intentionally tiny — it reuses every primitive that
;;; already exists (^bran-custodian's 'identify, the auditor's
;;; incoherence-alert schema, the gateway's periodic-fiber pattern,
;;; for-each-catching from util/common). No new infrastructure.

(define-module (playnet keys bran-custodians)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module ((playnet utils common) #:select (safe-call))
  #:use-module ((playnet credentials audit) #:select (make-incoherence-alert-credential))
  #:use-module ((playnet credentials registry) #:select (cred-signed-by-scope))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (^custodian-heartbeat
            spawn-custodian-heartbeat
            custodian-heartbeat-env))

(define-actor (^custodian-heartbeat bcom
                                    subject-aid       ; scope being protected
                                    custodian-refs    ; list of refs
                                    threshold         ; min reachable shares
                                    sink-store        ; for incoherence-alert
                                    cycle             ; monotonic counter
                                    subject-scope-ref); ^scope ref for signing, or #f

  ;; All plain data / actor refs — no closures. Without this, custodian-refs
  ;; and cycle both silently reset on restart, going dark on exactly the
  ;; early-warning mechanism this actor exists to provide until something
  ;; explicitly re-spawns it with the same custodian list.
  #:portrait
  (lambda () (list subject-aid custodian-refs threshold sink-store cycle
                   subject-scope-ref))

  #:version 1

  #:restore
  (lambda (version . args)
    (case version
      ((1) (apply spawn ^custodian-heartbeat args))
      (else (error "Unknown ^custodian-heartbeat version" version))))

  (methods
   ((subject) subject-aid)
   ((cycle)   cycle)
   ((custodians) custodian-refs)

   ((tick!)
    ;; Probe each custodian via 'identify (cheap; returns the holder
    ;; AID without releasing the share). Count reachable. If fewer
    ;; than threshold respond, emit incoherence-alert.
    (let* ((reachable
            (filter-map
             (lambda (ref)
               (safe-call (lambda () ($ ref 'identify))))
             custodian-refs))
           (n-reachable (length reachable))
           (n-total     (length custodian-refs))
           (healthy?    (>= n-reachable threshold)))
      (unless healthy?
        (when sink-store
          ;; Reuse the federation auditor's incoherence-alert schema —
          ;; operators get a unified /audit/{aid}.json view of both
          ;; structural invariants AND custody health.
          ;; The subject scope (whose custody is at risk) issues + signs its
          ;; own health alert — issuer = subject-aid, signed via its sign-said
          ;; when a scope ref is wired; unsigned otherwise (matches the
          ;; not-yet-gateway-wired state). Was a synthetic keyless issuer.
          (let ((cred (cred-signed-by-scope
                       (make-incoherence-alert-credential
                        #:auditor-aid subject-aid
                        #:federation-aid subject-aid
                        #:violations `((custody-shares-unreachable
                                        . ((reachable . ,n-reachable)
                                           (threshold . ,threshold)
                                           (total     . ,n-total))))
                        #:cycle cycle)
                       subject-scope-ref)))
            ($ sink-store 'issue cred)))
        (format (current-error-port)
                "[custodian-heartbeat] ~a: ~a/~a custodians reachable (need ~a)~%"
                subject-aid n-reachable n-total threshold))
      (bcom (^custodian-heartbeat bcom subject-aid custodian-refs
                                  threshold sink-store (+ cycle 1)
                                  subject-scope-ref)
            (list 'reachable n-reachable 'total n-total
                  'threshold threshold 'healthy? healthy?))))))

(define* (spawn-custodian-heartbeat subject-aid custodian-refs threshold
                                    #:key (sink-store #f) (subject-scope-ref #f))
  "Spawn a heartbeat actor for the SUBJECT-AID scope's custodian set.
   THRESHOLD is the minimum number of reachable custodians before an
   incoherence-alert fires. SINK-STORE (optional) gets the alert
   credential — typically the scope's own acdc-store so operators see
   the alert at /audit/{subject-aid}.json.
   SUBJECT-SCOPE-REF (optional) — the ^scope ref for the subject; when
   supplied, alerts are signed under the subject scope's key."
  (spawn ^custodian-heartbeat subject-aid custodian-refs threshold
         sink-store 0 subject-scope-ref))

(define custodian-heartbeat-env
  (make-persistence-env
    `((((playnet keys bran-custodians) ^custodian-heartbeat) ,^custodian-heartbeat))))
