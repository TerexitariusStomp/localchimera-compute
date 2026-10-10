;;; module/playnet/keys/scope-witness.scm — federation-peer KEL mirror
;;;
;;; In rules.md / democracy-on-keri.md §4.1, a scope's KEL is published
;;; for verifiability beyond the home vat. We don't publish to a global
;;; HTTP witness pool (that's a follow-on); instead, **federation peers
;;; mirror each other's KELs** via Goblins async sends.
;;;
;;; A `^scope-witness` actor lives in some peer's vat and holds a
;;; per-AID hashmap of kel-stores. When a home scope appends a KEL
;;; event, it async-sends the event body to each of its registered
;;; witnesses; each witness appends to its mirror.
;;;
;;; For recovery: if a host loses its local kel-store, it can fetch
;;; the KEL of a known scope by asking any of its witnesses.
;;;
;;; This is symmetrically elegant with bran-custodians: the same set
;;; of federation peers that hold Shamir shares for a scope's bran can
;;; also hold mirrors of its KEL. k peers = bran recovery; 1 peer = KEL
;;; recovery.

(define-module (playnet keys scope-witness)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet keys kel-store)
  #:use-module (playnet utils paths)
  #:export (^scope-witness
            spawn-scope-witness
            scope-witness-env
            scope-witness-mirror!
            scope-witness-kel-for))

(define-actor (^scope-witness bcom mirrors)
  ;; mirrors :: hashmap aid → ^kel-store ref

  ;; mirrors' values are ^kel-store refs, which now (see keys/kel-store.scm)
  ;; carry their own #:portrait/#:restore, so Goblins can serialize this
  ;; graph natively.
  #:portrait
  (lambda () (list mirrors))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^scope-witness data))
      (else (error "Unknown ^scope-witness version" version))))

  (define (rebuild new-mirrors)
    (^scope-witness bcom new-mirrors))
  (methods
   ((mirror aid event-body)
    "Receive a KEL event-body from a home scope. Append it to the
     per-AID mirror kel-store, creating the mirror on first sight.
     Idempotent: replaying an existing event is a no-op."
    (let ((store (hashmap-ref mirrors aid #f)))
      (cond
       (store
        ($ store 'append event-body)
        'ok)
       (else
        ;; Durable — this actor's whole purpose is disaster recovery for
        ;; peers; an in-memory-only mirror defeats that the moment the
        ;; witness's own vat restarts, before any peer even needs it.
        (let ((new-store (spawn-kel-store #:durable-dir (witness-mirror-kel-dir aid)
                                          #:aid aid)))
          ($ new-store 'append event-body)
          (bcom (rebuild (hashmap-set mirrors aid new-store))
                'ok))))))

   ((kel-for aid)
    "Return the list of KEL events the witness has mirrored for AID,
     or '() if this witness has never seen AID."
    (let ((store (hashmap-ref mirrors aid #f)))
      (if store ($ store 'all) '())))

   ((knows-aid? aid)
    (and (hashmap-ref mirrors aid #f) #t))

   ((known-aids)
    (hashmap-fold (lambda (k _v acc) (cons k acc)) '() mirrors))))

(define (spawn-scope-witness)
  (spawn ^scope-witness (hashmap)))

(define scope-witness-env
  (make-persistence-env
    `((((playnet keys scope-witness) ^scope-witness) ,^scope-witness))
    #:extends (list kel-store-env)))

(define (scope-witness-mirror! witness-ref aid event-body)
  "Convenience: send a KEL event to a witness asynchronously."
  (<- witness-ref 'mirror aid event-body))

(define (scope-witness-kel-for witness-ref aid)
  "Synchronous query (same vat) for a witness's mirror of AID's KEL."
  ($ witness-ref 'kel-for aid))
