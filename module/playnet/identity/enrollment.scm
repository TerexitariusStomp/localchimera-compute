;;; enrollment-ceremony.scm — k-of-n witness co-signature for PHC issuance
;;;
;;; The First-Person Project's intent **I2** ("one credential per real
;;; person") is the lone non-cryptographic requirement in the FPP/KERI
;;; mapping: it depends on humans meeting a candidate and confirming
;;; "we have not enrolled this person under another AID." This module
;;; encodes that ritual cryptographically:
;;;
;;;   1. A ceremony opens for a candidate AID — by the candidate's own
;;;      request (sponsor #f: "recognise me"), or by a PHC-holder who
;;;      introduces them — with the ecosystem's threshold k
;;;      (first-person/personhood-policy.scm).
;;;   2. Verified people ("witnesses") who have met the candidate sign the
;;;      *enrollment statement* (a SAID over the ceremony's key
;;;      parameters). Their signature binds the witness's AID to a
;;;      vouched-for candidate.
;;;   3. When ≥k attestations land, the ceremony issues a PHC whose ACDC
;;;      `e` block carries one NI2I edge per witness, pointing at that
;;;      witness's own PHC. The new PHC then *cryptographically records*
;;;      who vouched.
;;;
;;; Who may witness: anyone holding a live personhood the ecosystem admits —
;;; issued here, or issued by an ecosystem that chains to the root the
;;; gateway trusts (the same portability fp-status and the planner gate
;;; read) — and who has not signed more enrollments than the ecosystem's
;;; witness-cap allows within its window. The cap is the Sybil bound that
;;; stands where a gatekeeper stood: no one can mint persons faster than
;;; it, however many asks stand open.
;;;
;;; The ask is DURABLE. Every ceremony keeps a record of itself under
;;; <state>/witness/ceremonies/<said>.scm — its parameters, its attestations
;;; with the time each landed, its state — written on every transition and
;;; read back at boot (rehydrate-enrollment-ceremonies!), so a gateway
;;; restart keeps every open ask and every vouch already gathered. The
;;; records are also the witness-cap's index and the requester's own status
;;; read. An ask older than the ecosystem's ceremony-ttl lapses on the next
;;; read (expire-stale-enrollments!).
;;;
;;; A module of (playnet governance); the umbrella re-exports it.

(define-module (playnet identity enrollment)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet governance credentials)
  #:use-module (playnet governance attestation-ceremony)
  #:use-module (playnet keri said-portable)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet keri first-person personhood-policy)
  #:use-module ((playnet governance acdc-bridge)
                #:select (remember-witness-pending!))
  #:use-module ((playnet governance witness-relay)
                #:select (publish-witness-request! retract-witness-request!
                          witness-dir ensure-dir! safe-name))
  #:use-module (playnet utils boot-cell)
  #:use-module (ice-9 ftw)
  #:use-module (goblins)
  #:export (enrollment-statement-said spawn-enrollment-ceremony
            enroll-ceremony-for-candidate enroll-asks enrollment-record
            witness-recent-enrollments expire-stale-enrollments!
            rehydrate-enrollment-ceremonies! current-enroll-announcer
            *self-request-evidence*))

;; =========================================================================
;; Statement-SAID — what witnesses sign.
;; =========================================================================
;;
;; A SAID over a canonical alist binding scope-aid, candidate-aid,
;; evidence-digest, and threshold-k. Any change in those fields produces
;; a different SAID, so attestations are pinned to a specific ceremony.
;; A self-request's evidence is one fixed word, so its SAID is a function
;; of (ecosystem, candidate, k) alone — one collector per candidate.

(define *self-request-evidence* "self-request")

(define (enrollment-statement-said scope-aid candidate-aid evidence-digest k)
  (compute-said scope-aid candidate-aid 'enrollment-statement
                `((scope-aid . ,scope-aid)
                  (candidate-aid . ,candidate-aid)
                  (evidence-digest . ,evidence-digest)
                  (threshold . ,k))
                '()))

;; =========================================================================
;; The record — a ceremony's durable self.
;; =========================================================================

(define (records-dir) (witness-dir "ceremonies"))
(define (record-path said) (string-append (records-dir) "/" (safe-name said) ".scm"))

(define (write-record! rec)
  "Write REC atomically under its SAID — a half-written file is never read."
  (let* ((path (record-path (assq-ref rec 'said)))
         (tmp  (string-append path ".tmp")))
    (ensure-dir! (records-dir))
    (call-with-output-file tmp (lambda (port) (write rec port)))
    (rename-file tmp path)))

(define (enrollment-record said)
  "The durable record of the ceremony SAID names, or #f."
  (let ((path (record-path said)))
    (and (file-exists? path)
         (catch #t (lambda () (call-with-input-file path read)) (lambda _ #f)))))

(define (all-records)
  (let ((dir (records-dir)))
    (if (file-exists? dir)
        (filter-map (lambda (f)
                      (and (string-suffix? ".scm" f)
                           (catch #t
                             (lambda () (call-with-input-file (string-append dir "/" f) read))
                             (lambda _ #f))))
                    (scandir dir))
        '())))

(define (record-update rec . kvs)
  "REC with each key in KVS (alternating key value) replaced."
  (let loop ((rec rec) (kvs kvs))
    (if (null? kvs) rec
        (loop (cons (cons (car kvs) (cadr kvs))
                    (filter (lambda (p) (not (eq? (car p) (car kvs)))) rec))
              (cddr kvs)))))

;; attestations in a record are (aid sig at): the actor's (aid . sig) pairs
;; with the time each landed, kept from the earlier record so a re-write
;; never re-dates a vouch
(define (merge-attestations prior pairs now)
  (map (lambda (p)
         (let ((old (find (lambda (a) (equal? (car a) (car p))) prior)))
           (list (car p) (cdr p) (if old (caddr old) now))))
       pairs))

;; =========================================================================
;; Indexes over the live registry: by candidate, and every open ask.
;; =========================================================================

(define *enroll-by-candidate* (make-hash-table))   ; "scope|candidate" → statement-said
(define (candidate-key scope-aid candidate-aid)
  (string-append scope-aid "|" candidate-aid))

(define (enroll-ceremony-for-candidate scope-aid candidate-aid)
  "The COLLECTING ceremony for CANDIDATE-AID in SCOPE-AID, or #f."
  (let* ((said (hash-ref *enroll-by-candidate* (candidate-key scope-aid candidate-aid) #f))
         (c (and said (attestation-ceremony-for said))))
    (and c (eq? ($ c 'status) 'collecting) c)))

(define (enroll-asks scope-aid)
  "Every collecting enrollment in SCOPE-AID, as rows a surface can show:
   ((said . …) (candidate . …) (sponsor . …) (count . n) (quorum . k)
   (opened-at . secs))."
  (filter-map
   (lambda (rec)
     (and (equal? scope-aid (assq-ref rec 'scope))
          (eq? 'collecting (assq-ref rec 'state))
          (let ((c (attestation-ceremony-for (assq-ref rec 'said))))
            (and c (eq? ($ c 'status) 'collecting)
                 `((said . ,(assq-ref rec 'said))
                   (candidate . ,(assq-ref rec 'candidate))
                   (sponsor . ,(assq-ref rec 'sponsor))
                   (count . ,($ c 'attestation-count))
                   (quorum . ,($ c 'threshold))
                   (opened-at . ,(assq-ref rec 'opened-at)))))))
   (all-records)))

;; =========================================================================
;; The witness cap — the records as its index.
;; =========================================================================

(define* (witness-recent-enrollments witness-aid window #:optional (now (instant->unix (clock-now))))
  "How many enrollments WITNESS-AID has signed within the last WINDOW
   seconds — collecting or finalized alike, so parallel asks count too."
  (let ((since (- now window)))
    (fold (lambda (rec n)
            (+ n (count (lambda (a) (and (equal? (car a) witness-aid)
                                         (number? (caddr a))
                                         (>= (caddr a) since)))
                        (or (assq-ref rec 'attestations) '()))))
          0 (all-records))))

;; =========================================================================
;; Announcing — the rail beyond the inbox.
;; =========================================================================
;;
;; The gateway binds this cell to something that tells verified people an
;; ask stands (the notify-router over the recipient registry). Unbound —
;; tests, a bare planner — an ask is still on the inbox and relay rails.

(define current-enroll-announcer (make-boot-cell))

;; =========================================================================
;; ^enrollment-ceremony — the ritual with enrollment's specifics injected
;; =========================================================================

(define* (spawn-enrollment-ceremony scope-aid candidate-aid evidence-digest
                                    sponsor-aid threshold-k acdc-store
                                    #:key (signing-keypair #f) (sign-cred #f)
                                          (root-aid #f)
                                          (witness-cap (assq-ref *personhood-policy-defaults* 'witness-cap))
                                          (witness-window (assq-ref *personhood-policy-defaults* 'witness-window))
                                          (announce? #t)
                                          (opened-at #f))
  "Spawn a ceremony for CANDIDATE-AID under ECO=SCOPE-AID, requiring
   THRESHOLD-K signed attestations from witnesses. SPONSOR-AID is the
   PHC-holder introducing the candidate, or #f when the candidate asks for
   themself. The issued PHC is signed by SIGNING-KEYPAIR (a raw scope key)
   or by SIGN-CRED (a cred→cred post-signer built over a ^scope's sign-said,
   so the key never leaves the actor); with the scope's blessing AIC it
   comes out signed + root-anchored like any other.

   A witness holds a live personhood the ecosystem admits — issued here,
   or by an ecosystem chaining to ROOT-AID (one root, or the list of roots
   this gateway recognises) when given — and has
   signed fewer than WITNESS-CAP enrollments in WITNESS-WINDOW.

   The ritual itself is ^attestation-ceremony (attestation-ceremony.scm) —
   this injects enrollment's specifics (the statement, the witness rule, a
   finalizer that mints the PHC with one NI2I edge per witness, the durable
   record) and puts the ask on every rail: registered for attest landing,
   indexed by candidate, remembered for the witness inbox, published for
   peer gateways' polls, and — when ANNOUNCE? — told to verified people
   through the bound announcer. Spawning IS asking.

   Idempotent while collecting: re-opening the same (candidate, evidence, k)
   hands back the standing ceremony — never a rival collector that would
   reset already-gathered vouches."
  (when (and sponsor-aid (not (holds-live-phc? acdc-store scope-aid sponsor-aid)))
    (error "spawn-enrollment-ceremony: sponsor lacks a live PHC" sponsor-aid))
  (let* ((statement-said
          (enrollment-statement-said scope-aid candidate-aid
                                     evidence-digest threshold-k))
         (standing (attestation-ceremony-for statement-said))
         (own-aic-said
          (lambda ()
            (let ((aic (find (lambda (c)
                               (and (equal? (cred-holder c) scope-aid)
                                    (cred-live-at? c (instant->unix (clock-now)))))
                             ($ acdc-store 'by-schema *schema-playnet-authorized-issuer*))))
              (and aic (cred-said aic)))))
         ;; the witness's personhood as the ecosystem admits it: its own
         ;; issue first, else any live PHC whose issuing ecosystem chains to
         ;; the trusted root (the registry walk fp-present trusts)
         (witness-phc
          (lambda (w-aid)
            (let ((own (phc-for acdc-store scope-aid w-aid)))
              (or own
                  (let ((any (any-live-phc-for acdc-store w-aid)))
                    (and any root-aid
                         (ecosystem-chains-to-any-root? acdc-store root-aid
                                                        (cred-claim any 'ecosystem-aid)
                                                        #:require-signature? #f)
                         any))))))
         (witness-edge-for
          (lambda (entry)
            (let ((w-phc (witness-phc (car entry))))
              (cons (string->symbol (string-append "witness-" (car entry)))
                    (make-edge (cred-said w-phc)
                               #:operator 'NI2I
                               #:schema *schema-playnet-personhood*)))))
         (eligible?
          (lambda (w-aid)
            (cond
             ((equal? w-aid candidate-aid) "attest: a candidate cannot witness themself")
             ((not (witness-phc w-aid))
              "attest: witness holds no personhood this ecosystem admits")
             ((>= (witness-recent-enrollments w-aid witness-window) witness-cap)
              "attest: witness has signed as many enrollments as this window allows")
             (else #t))))
         (issue!
          (lambda (attestations)
            ;; SIGN-CRED is the actor-held-key alternative to a raw
            ;; SIGNING-KEYPAIR: a (cred → cred) post-signer the caller
            ;; builds over its scope's sign-said, so the key never
            ;; leaves the ^scope (the fp-grant/fp-vouch pattern).
            (let ((phc (make-personhood-credential
                        scope-aid candidate-aid (instant->unix (clock-now))
                        #:enrollment-evidence-digest evidence-digest
                        #:sponsor-aid sponsor-aid
                        #:witness-edges (map witness-edge-for attestations)
                        #:issuer-authz-said (own-aic-said)
                        #:signing-keypair signing-keypair)))
              ($ acdc-store 'issue
                 (if sign-cred (sign-cred phc) phc)))))
         (opened (or opened-at (instant->unix (clock-now))))
         ;; the durable self: every transition rewrites the record, the
         ;; time each vouch landed carried forward from the record before
         (on-change
          (lambda (state atts finalized)
            (let* ((prior (or (enrollment-record statement-said) '()))
                   (now (instant->unix (clock-now))))
              (write-record!
               (record-update prior
                 'said statement-said 'scope scope-aid 'candidate candidate-aid
                 'evidence evidence-digest 'k threshold-k 'sponsor sponsor-aid
                 'opened-at (or (assq-ref prior 'opened-at) opened)
                 'state state
                 'attestations (merge-attestations (or (assq-ref prior 'attestations) '())
                                                   atts now)
                 'finalized (and finalized
                                 (if (string? finalized) finalized
                                     (false-if-exception (cred-said finalized))))))
              (unless (eq? state 'collecting)
                (retract-witness-request! statement-said)
                (hash-remove! *enroll-by-candidate*
                              (candidate-key scope-aid candidate-aid)))))))
    (if (and standing (eq? ($ standing 'status) 'collecting))
        standing
        (let ((ceremony (spawn ^attestation-ceremony 'collecting statement-said
                               threshold-k eligible? issue! '() #f on-change)))
          (register-attestation-ceremony! statement-said ceremony)
          (hash-set! *enroll-by-candidate* (candidate-key scope-aid candidate-aid)
                     statement-said)
          (on-change 'collecting '() #f)
          ;; The same rails work ceremonies ride: remembered in the shared
          ;; pending table so the inbox shows verified people what they are
          ;; asked to vouch for (`worker` is the SUBJECT slot: the candidate,
          ;; whom the inbox excludes from witnessing themself), and published
          ;; so every peer gateway's witness poll surfaces the ask too.
          (let ((ctx `((kind . enroll)
                       (worker . ,candidate-aid)
                       (sponsor . ,(or sponsor-aid ""))
                       (evidence . ,(or evidence-digest ""))
                       (scope . ,scope-aid)
                       (opened-at . ,opened))))
            (remember-witness-pending! statement-said ctx)
            (publish-witness-request! statement-said ctx)
            (when announce?
              (let ((announce (current-enroll-announcer)))
                (when announce
                  (catch #t (lambda () (announce ctx)) (lambda _ #f))))))
          ceremony))))

;; =========================================================================
;; Lapse, and coming back after a restart.
;; =========================================================================

(define* (expire-stale-enrollments! ttl #:optional (now (instant->unix (clock-now))))
  "Abandon every collecting enrollment opened more than TTL seconds ago:
   the actor lapses, its record says so, its ask leaves every rail. Returns
   the SAIDs abandoned."
  (filter-map
   (lambda (rec)
     (and (eq? 'collecting (assq-ref rec 'state))
          (number? (assq-ref rec 'opened-at))
          (< (assq-ref rec 'opened-at) (- now ttl))
          (let ((c (attestation-ceremony-for (assq-ref rec 'said))))
            (if (and c (eq? ($ c 'status) 'collecting))
                ($ c 'abandon)
                (write-record! (record-update rec 'state 'abandoned)))
            (retract-witness-request! (assq-ref rec 'said))
            (hash-remove! *enroll-by-candidate*
                          (candidate-key (assq-ref rec 'scope) (assq-ref rec 'candidate)))
            (assq-ref rec 'said))))
   (all-records)))

(define* (rehydrate-enrollment-ceremonies! acdc-store
                                           #:key (sign-cred-of (lambda (scope-aid) #f))
                                                 (root-aid #f)
                                                 (witness-cap (assq-ref *personhood-policy-defaults* 'witness-cap))
                                                 (witness-window (assq-ref *personhood-policy-defaults* 'witness-window)))
  "Bring every collecting enrollment back from its record: respawn the
   ceremony with its own parameters and land each recorded vouch again.
   A vouch whose witness no longer qualifies is dropped, not carried on
   faith. Nothing is re-announced. Returns the SAIDs restored."
  (filter-map
   (lambda (rec)
     (and (eq? 'collecting (assq-ref rec 'state))
          (not (attestation-ceremony-for (assq-ref rec 'said)))
          (catch #t
            (lambda ()
              (let ((c (spawn-enrollment-ceremony
                        (assq-ref rec 'scope) (assq-ref rec 'candidate)
                        (assq-ref rec 'evidence) (assq-ref rec 'sponsor)
                        (assq-ref rec 'k) acdc-store
                        #:sign-cred (sign-cred-of (assq-ref rec 'scope))
                        #:root-aid root-aid
                        #:witness-cap witness-cap #:witness-window witness-window
                        #:announce? #f
                        #:opened-at (assq-ref rec 'opened-at))))
                (for-each (lambda (a)
                            (catch #t
                              (lambda () ($ c 'attest (car a) (cadr a)))
                              (lambda _ #f)))
                          (or (assq-ref rec 'attestations) '()))
                (assq-ref rec 'said)))
            (lambda _ #f))))
   (all-records)))
