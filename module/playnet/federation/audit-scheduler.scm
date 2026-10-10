;;; federation/audit-scheduler.scm — ^audit-scheduler
;;;
;;; Periodically issues `playnet-derived-state-snapshot/v1` ACDCs for
;;; one or more scopes. Per democracy-on-keri.md §4.5, this answers
;;; "how do you authenticate live derived numbers (voice shares, credit
;;; balances, P_extract) without re-signing them on every read?": the
;;; auditor signs a snapshot tagged with `NI2I` edges to every input
;;; ACDC the snapshot was computed from. A verifier recomputes from the
;;; listed inputs and confirms the match; the snapshot's signature
;;; provides "this was attested at this time."
;;;
;;; Mirror of `^rollover-scheduler` shape: external `tick`, no internal
;;; timer. Shepherd or gateway calls `(tick as-of-seconds)` on cadence;
;;; the actor pulls derived state via the supplied COMPUTE-FN, builds
;;; the credential, and issues into AUDITOR-STORE.

(define-module (playnet federation audit-scheduler)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet federation audit-scheduler)
  #:use-module (playnet credentials audit)
  #:use-module (playnet credentials registry)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri acdc)
  #:export (^audit-scheduler
            spawn-audit-scheduler
            audit-scheduler-env))

(define-actor (^audit-scheduler bcom
                                auditor-aid    ;; AID issuing the snapshots
                                target-scopes  ;; list of (scope-aid . scope-ref)
                                auditor-store  ;; ^acdc-store to issue into
                                compute-fn     ;; (scope-ref) → (values data input-saids)
                                last-result    ;; last issued snapshot (alist) or #f
                                tick-count)    ;; monotonic count

  ;; auditor-aid/target-scopes/auditor-store/last-result/tick-count are
  ;; plain data or actor refs (target-scopes' entries carry live scope
  ;; refs, which Goblins serializes as graph refs). compute-fn is a
  ;; caller-supplied closure and can't survive a portrait — excluded here;
  ;; restore leaves it as an erroring stub until 'rewire-compute-fn! is
  ;; called, instead of the previous default self-portrait, which would
  ;; have crashed the whole checkpoint the moment it tried to serialize a
  ;; procedure.
  #:portrait
  (lambda () (list auditor-aid target-scopes auditor-store last-result tick-count))

  #:version 1

  #:restore
  (lambda (version aid scopes store result count)
    (case version
      ((1)
       (spawn ^audit-scheduler aid scopes store
              (lambda (_scope-ref)
                (error "^audit-scheduler: compute-fn not yet rewired after restore — call 'rewire-compute-fn! first"))
              result count))
      (else (error "Unknown ^audit-scheduler version" version))))

  (methods

   ;; Run a snapshot for every target scope. compute-fn yields the
   ;; derived-state alist + the list of input ACDC SAIDs (work-events,
   ;; audit-passes, index observations) the data was computed from.
   ;; Each snapshot is issued and accumulated into a per-tick result
   ;; alist `((scope-aid . snapshot-said) …)`.
   ((tick as-of-seconds)
    (let ((results
           (map (lambda (target)
                  (let* ((scope-aid (car target))
                         (scope-ref (cdr target)))
                    (call-with-values
                      (lambda () (compute-fn scope-ref))
                      (lambda (data input-saids)
                        ;; The snapshot is about SCOPE-AID's derived state, so
                        ;; that scope issues + signs it via its own sign-said
                        ;; (issuer = scope-aid, keypair stays in the actor).
                        ;; AUDITOR-AID stays the scheduler's nominal label.
                        (let ((cred
                               (cred-signed-by-scope
                                (make-derived-state-snapshot-credential
                                 scope-aid scope-aid data
                                 #:input-saids input-saids
                                 #:snapshot-at as-of-seconds)
                                scope-ref)))
                          ($ auditor-store 'issue cred)
                          (cons scope-aid (cred-said cred)))))))
                target-scopes)))
      (bcom (^audit-scheduler bcom auditor-aid target-scopes
                              auditor-store compute-fn
                              results (+ 1 tick-count))
            results)))

   ((last-result) last-result)
   ((tick-count)  tick-count)
   ((target-scopes) target-scopes)

   ;; Adjust the target list dynamically (gateway can register new
   ;; scopes as they spawn).
   ((add-target! scope-aid scope-ref)
    (let ((updated (append target-scopes
                           (list (cons scope-aid scope-ref)))))
      (bcom (^audit-scheduler bcom auditor-aid updated
                              auditor-store compute-fn
                              last-result tick-count)
            'ok)))

   ((rewire-compute-fn! new-compute-fn)
    "Re-supply the compute-fn closure lost on restore (see #:portrait)."
    (bcom (^audit-scheduler bcom auditor-aid target-scopes
                            auditor-store new-compute-fn
                            last-result tick-count)))))

(define audit-scheduler-env
  (make-persistence-env
    `((((playnet federation audit-scheduler) ^audit-scheduler) ,^audit-scheduler))))

(define* (spawn-audit-scheduler auditor-aid auditor-store compute-fn
                                #:key (initial-scopes '()))
  "Spawn a ^audit-scheduler.

   AUDITOR-AID:    issuer AID stamped on each snapshot ACDC.
   AUDITOR-STORE:  acdc-store the snapshots are issued into. In production
                   this is the auditor scope's own durable store.
   COMPUTE-FN:     procedure (scope-ref → (values snapshot-data input-saids)).
                   Caller wires this to whatever derived-state computation
                   makes sense (voice shares, credits, the leverage bound).
                   Returning `(values '() '())` is a valid no-op snapshot.
   INITIAL-SCOPES: alist of (scope-aid . scope-ref) — can be empty;
                   add later via 'add-target!."
  (spawn ^audit-scheduler auditor-aid initial-scopes
         auditor-store compute-fn
         #f 0))
