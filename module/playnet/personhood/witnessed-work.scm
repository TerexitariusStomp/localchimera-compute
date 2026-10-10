;;; module/playnet/personhood/witnessed-work.scm — work vouched for by its peers:
;;; the witness, quorum by command, the ceremony over a work event, and the
;;; pending inbox a browser reads to decide whether to co-sign.
;;;
;;; The ceremony is ^attestation-ceremony (attestation-ceremony.scm) over the
;;; unsigned work-event credential's SAID, as the enrollment ceremony is over a
;;; candidate PHC: the same k-of-n vouching, collecting then finalized, here
;;; attaching the gathered block as the credential's multisig block and
;;; STRENGTHENING the store's single-signer copy in place.
;;;
(define-module (playnet personhood witnessed-work)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet utils boot-cell)
  #:use-module ((playnet utils units) #:select (hours-in))
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri citizen-sig)
  #:use-module ((playnet observation credentials) #:select (mint-skill-if-new!))
  #:use-module (playnet personhood attestation-ceremony)
  #:use-module (playnet vf schemas)
  #:export (^work-witness witness-quorum
            spawn-witnessed-work-ceremony gather-witnessed-attestation!
            open-work-witnessing! witness-work-inbox witness-work-outbox
            current-vouch-reader
            witness-pending-context remember-witness-pending!
            remember-remote-witness-request! forget-remote-witness-request!
            remote-witness-request))

;; attest-contribution! #:witnesses takes keypairs in hand — right for a
;; single-operator group, wrong for real witnesses, whose keys must never
;; leave them. This is the collect-then-attach choreography over ACTORS: the
;; credential is built UNSIGNED (its SAID does not depend on the signature),
;; each ^work-witness is asked to sign that SAID inside its own closure, and
;; the gathered block is attached only if quorum is met — otherwise NOTHING
;; issues. Refusal is the default, here as everywhere.
;;
;; DRY NOTE, from the audit that followed: this is the SYNCHRONOUS sibling of
;; ^enrollment-ceremony (enrollment-ceremony.scm) — the standing k-of-n
;; vouching ritual, stateful (collecting → finalized), gov-cap-authorized,
;; recording its witnesses as NI2I edges where this records a multisig block.
;; The consolidation path for REMOTE witnesses is that actor generalized from
;; candidate-PHC to any credential SAID — its collecting state is exactly the
;; async form IPEX round-trips need — over the /multisig/exn routes and
;; ipex-policy registry that already exist (federation/keria-notifications.scm,
;; federation/ipex-policy.scm). Do not grow this function a network layer.
;;
;; Vocabulary: "witness" here and in enrollment means VOUCHER — a party
;; co-signing that work happened. KERI's own "witness"
;; (keys/witness-pool.scm, receiptor.scm) is receipt infrastructure,
;; an unrelated role.

;; A witness: holds its keypair privately, applies its own POLICY to what it
;; will co-sign. POLICY is (cred → bool) — a witness that cannot verify the
;; work happened says no, and no is silent.
(define (^work-witness bcom keri-id policy)
  (lambda (msg . args)
    (case msg
      ((aid) (keri-identity-aid keri-id))
      ((witness)
       (let ((cred (car args)))
         (and (policy cred)
              (cons (keri-identity-aid keri-id)
                    (sign-said (cred-said cred)
                               (keri-identity-keypair keri-id))))))
      (else (error "work-witness: unknown message" msg)))))

;; Quorum follows command (the recert-cadence logic applied to evidence): work
;; that commands little of the commons needs one witness; a third of the
;; commons, two; two thirds, three. COMMAND-SHARE ∈ [0,1].
(define (witness-quorum command-share)
  (max 1 (inexact->exact (ceiling (* 3.0 (min 1.0 (max 0.0 command-share)))))))

;; The pending WORK-WITNESS inbox: the human-facing context beside the
;; ceremony registry — what a browser needs to decide whether to co-sign.
;; An entry is live exactly while its ceremony collects; dead ones sweep on
;; read, so nothing has to remember to clean up.
(define *witness-work-pending* (make-hash-table))   ; statement-said → context alist

(define (remember-witness-pending! said ctx)
  "Register a collecting ceremony's human context in the shared inbox
   table. Work ceremonies and enrollment ceremonies both live here —
   ctx's `kind` says which, and its `worker` slot names the SUBJECT
   (the worker, or the enrollment candidate), which the inbox uses to
   keep a party from witnessing their own claim."
  (hash-set! *witness-work-pending* said ctx))

(define (witness-pending-context said)
  "A collecting ceremony's human context, for the request the gateway fans
   out to remote peers."
  (hash-ref *witness-work-pending* said #f))

;; Requests from ANOTHER gateway's ceremony, remembered until answered: the
;; ceremony itself lives at the origin, so the only local truth is the
;; request — `origin` names the AID the co-signature returns to over the
;; /multisig/exn rail.
(define *witness-remote-requests* (make-hash-table))   ; statement-said → context alist
(define (remember-remote-witness-request! said ctx)
  (hash-set! *witness-remote-requests* said ctx))
(define (forget-remote-witness-request! said)
  (hash-remove! *witness-remote-requests* said))
(define (remote-witness-request said)
  (hash-ref *witness-remote-requests* said #f))

;; Whether the reader already vouches for a subject by relationship
;; credential — bound by the gateway over its credential store, so an
;; enroll ask can say "you already vouch for them". Unbound: never.
(define current-vouch-reader (make-boot-cell))   ; (reader-aid subject-aid) → bool

(define (collecting-ceremonies keep?)
  "The pending table, walked ONCE for both of its readers: each local
   ceremony still collecting, as (said ctx ceremony), for the contexts KEEP?
   admits. A ceremony that has finalized or gone is swept from the table on
   the way past — the table holds exactly what still collects."
  (let ((out '()))
    (hash-for-each
     (lambda (said ctx)
       (let ((c (attestation-ceremony-for said)))
         (cond
          ((not (and c (eq? ($ c 'status) 'collecting)))
           (hash-remove! *witness-work-pending* said))
          ((keep? ctx) (set! out (cons (list said ctx c) out))))))
     *witness-work-pending*)
    out))

(define (ceremony-row said ctx c . more)
  "One row of a ceremony: what it is about (CTX), how far it stands, and MORE."
  (append `((said . ,said) (count . ,($ c 'attestation-count)) (quorum . ,($ c 'threshold)))
          more ctx))

(define (witness-work-inbox for-aid)
  "The work-witness requests FOR-AID may answer — every LOCAL collecting
   ceremony and every REMOTE request remembered from a peer gateway, always
   over someone ELSE's work (you cannot witness your own). Each local row
   says whether FOR-AID may sign it (`eligible`, the ceremony's own rule
   asked without signing) and, for an enrollment, whether they already
   vouch for the candidate (`vouched`)."
  (let ((vouched? (or (current-vouch-reader) (lambda (a b) #f)))
        (others   (lambda (ctx) (not (equal? (assq-ref ctx 'worker) for-aid)))))
    (append
     (map (lambda (e)
            (let ((said (car e)) (ctx (cadr e)) (c (caddr e)))
              (ceremony-row said ctx c
                            (cons 'eligible (eq? #t (false-if-exception ($ c 'eligible? for-aid))))
                            (cons 'vouched (and (eq? 'enroll (assq-ref ctx 'kind))
                                                (vouched? for-aid (assq-ref ctx 'worker))
                                                #t)))))
          (collecting-ceremonies others))
     (let ((out '()))
       (hash-for-each
        (lambda (said ctx) (when (others ctx) (set! out (cons (cons (cons 'said said) ctx) out))))
        *witness-remote-requests*)
       out))))

(define (witness-work-outbox worker)
  "The inbox read from the other end: the work ceremonies still collecting
   over WORKER's own events, each with how far its quorum stands."
  (map (lambda (e) (ceremony-row (car e) (cadr e) (caddr e)))
       (collecting-ceremonies (lambda (ctx) (and (eq? 'work (assq-ref ctx 'kind))
                                                (equal? (assq-ref ctx 'worker) worker))))))

(define* (spawn-witnessed-work-ceremony acdc-store scope-aid event
                                        #:key (quorum (witness-quorum 0.0))
                                              (eligible? (lambda (aid) #t))
                                              (on-issued (lambda (we) we)))
  "The ASYNC form: ^attestation-ceremony over a work event. The statement is
   the unsigned work-event ACDC's SAID (signature-independent by
   construction); the finalizer attaches the collected attestations as the
   multisig block — the alist IS the block — and STRENGTHENS the store: the
   SAID is the single-signer copy's own, so a provenance-signed credential
   already held upgrades in place to its witnessed form, and nothing
   downstream re-keys. A remote witness's signature, arriving over the
   /multisig/exn routes across however many turns the network takes, lands
   as ($ ceremony 'attest aid sig); at quorum, ($ ceremony 'finalize) —
   which also runs ON-ISSUED with the witnessed credential. Returns
   (values ceremony base-cred), or #f when the event carries no attestable
   work."
  (let* ((worker (economic-event-provider event))
         (skill  (economic-event-resource-conforms-to event))
         (eq     (economic-event-effort-quantity event))
         (hours  (and eq (hours-in (measure-has-numerical-value eq) (measure-has-unit eq))))
         (unit   (and eq "hours")))
    (and worker skill
         (let ((base (make-work-event-credential
                      scope-aid worker (economic-event-id event) hours unit
                      #:process-id (or (economic-event-input-of event)
                                       (economic-event-output-of event))
                      #:timestamp (economic-event-has-point-in-time event)
                      #:resource-conforms-to skill
                      #:fulfills (economic-event-fulfills event)
                      #:satisfies (economic-event-satisfies event))))
           (let ((ceremony (spawn ^attestation-ceremony 'collecting
                                  (cred-said base) quorum eligible?
                                  (lambda (attestations)
                                    (let ((we (cred-with-signature base attestations)))
                                      ($ acdc-store 'strengthen we)
                                      (on-issued we)
                                      we))
                                  '() #f)))
             ;; addressable by the SAID its witnesses sign, so a remote reply
             ;; finds it (land-witness-attestation!) — and readable by the
             ;; inbox, so a browser knows what it is being asked to co-sign
             (register-attestation-ceremony! (cred-said base) ceremony)
             (remember-witness-pending! (cred-said base)
                        `((kind . work)
                          (event-id . ,(economic-event-id event))
                          (worker . ,worker) (skill . ,skill)
                          (hours . ,(or hours 0)) (unit . ,(or unit "hours"))
                          (scope . ,scope-aid)))
             (values ceremony base))))))

(define* (open-work-witnessing! acdc-store scope-aid event roster #:key (signer #f))
  "The on-demand DRIVE: open a witnessing ceremony over an already-recorded
   work event, eligible = ROSTER minus the worker, quorum by command share
   (one witness at the floor), capped at who is actually there to ask.
   The single-signer provenance credential the on-event hook already issued
   stays authoritative until quorum STRENGTHENS it in place. Returns the
   statement SAID witnesses will sign, or #f (no attestable work, nobody to
   ask, or a ceremony already collecting for this event's credential)."
  (let* ((worker (economic-event-provider event))
         (peers  (filter (lambda (a) (and (string? a) (not (equal? a worker))))
                         (or roster '())))
         ;; one ceremony per event: a re-open while one collects hands back
         ;; the standing statement rather than a rival collector
         (standing (let ((hit #f))
                     (hash-for-each
                      (lambda (said ctx)
                        (when (and (not hit)
                                   (equal? (assq-ref ctx 'event-id)
                                           (economic-event-id event))
                                   (let ((c (attestation-ceremony-for said)))
                                     (and c (eq? ($ c 'status) 'collecting))))
                          (set! hit said)))
                      *witness-work-pending*)
                     hit)))
    (or standing
        (and (pair? peers)
             (call-with-values
                 (lambda ()
                   (spawn-witnessed-work-ceremony acdc-store scope-aid event
                     #:quorum (min (witness-quorum 0.0) (length peers))
                     #:eligible? (lambda (aid) (and (member aid peers) #t))
                     #:on-issued (lambda (we)
                                   (mint-skill-if-new! acdc-store scope-aid worker
                                     (economic-event-resource-conforms-to event)
                                     (cred-said we) #:signer signer)
                                   we)))
               (lambda (ceremony base)
                 (and ceremony (cred-said base))))))))

(define* (gather-witnessed-attestation! acdc-store scope-aid event witnesses
                                        #:key (quorum (witness-quorum 0.0)))
  "The SYNCHRONOUS form, on the same ritual: spawn the ceremony, ask every
   witness actor inline, finalize at quorum. Below quorum nothing issues and
   #f returns: an unwitnessed claim is not weak evidence, it is no evidence.
   Returns the issued credential or #f."
  (call-with-values
      (lambda () (spawn-witnessed-work-ceremony acdc-store scope-aid event
                                                #:quorum quorum))
    (lambda (ceremony base)
      (and ceremony
           (begin
             (for-each (lambda (w)
                         (let ((att ($ w 'witness base)))
                           (when att ($ ceremony 'attest (car att) (cdr att)))))
                       witnesses)
             (and (>= ($ ceremony 'attestation-count) quorum)
                  ($ ceremony 'finalize)))))))
