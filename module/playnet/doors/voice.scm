;;; module/playnet/doors/voice.scm — the voice doors of the governance service: a proposal opened, cast on, closed and read; a hand on the plan
;;;
;;; A fragment of the governance service (playnet doors governance): a procedure
;;; from the actor's context to the doors it serves, composed into the service by
;;; (playnet boot governance). `with-governance-ctx` binds the actor's arguments,
;;; cells and shared helpers under their own names, so each clause reads as it did
;;; inside the actor (docs/planning/codebase-layout.md §5).

(define-module (playnet doors voice)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet credentials voting)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet vf facts parts) #:select (validate-hand))
  #:use-module ((playnet observation observer) #:select (void-event))
  #:use-module (playnet keri said-portable)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet utils clock) #:select (instant->civil (now . clock-now)))
  #:use-module (goblins utils hashmap)
  #:use-module ((playnet personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (governance-voice-doors))

(define (governance-voice-doors ctx)
  (with-governance-ctx ctx
    ;; A closed contest ballot (contest-work below): `void` at half the
    ;; franchise's voice or more, and the work is corrected to nothing through
    ;; the scope's own observer — the kernel's correction, so hours, credit,
    ;; skill standing and the portable record all follow. The correcting event
    ;; keeps the worker as provider and the act's own edges (it is their act,
    ;; restated to zero) and names the ballot in its note. Below half, or on a
    ;; ballot that is no contest, nothing is written.
    ;; THE one rule for a decision that binds: a position carries when it
    ;; holds half the franchise's voice or more, abstention counted against.
    ;; A ratification reads its winner by it; a contest reads `void` by it.
    (define (carries? weight entries abstain)
      (let ((total (+ abstain (fold + 0 (map cdr entries)))))
        (and (> total 0) (>= (/ weight total) 1/2))))
    (define (position-weight entries name)
      (fold + 0 (map cdr (filter (lambda (e) (equal? name (format #f "~a" (car e)))) entries))))
    (define (settle-contest! id tally-map abstain)
      (let ((c (assq-ref ($ ballot-store 'meta id) 'contest)))
        (when c
          (let* ((entries (hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() tally-map))
                 (eid     (assq-ref c 'event-id))
                 (obs     (scope-observer (assq-ref c 'scope-id)))
                 (ev      (and obs ($ obs 'get-event eid))))
            (when (and ev ($ obs 'event-standing? eid)
                       (carries? (position-weight entries "void") entries abstain))
              (for-each
               (lambda (e)
                 ($ obs 'apply-correction
                    (void-event e (if (equal? (economic-event-id e) eid)
                                      (string-append id ":void")
                                      (string-append id ":void~" (economic-event-id e)))
                                (string-append "contested, and found not done: " id)
                                (assq-ref c 'scope-id)
                                (instant->civil (clock-now)))))
               (contest-family obs ev)))
            (when contest-settled
              (catch #t (lambda () (contest-settled id)) (lambda _ #f)))))))

    (declared-doors governance

      ;; Your two governance weights (playnet.typ §Governance), reusing the
      ;; planner: PRODUCER voice = labour share (`voice-share`) on production;
      ;; CONSUMER voice = share of the claimable pool (`consumer-voice`) on
      ;; consumption. #f substrate → 0.
      ((my-voice identity-key)
       (catch #t
         (lambda ()
           (let ((cv (consumer-voice identity-key scope-roots)))
             (list (cons 'producer (exact->inexact (voice-share identity-key scope-roots)))
                   ;; #f when the claimable pool is empty — surfaced as -1 so
                   ;; the dial shows the qualitative consumer voice, not 0%.
                   (cons 'consumer (if cv (exact->inexact cv) -1.0)))))
         (lambda _ (list (cons 'producer 0.0) (cons 'consumer -1.0)))))

      ;; Producer voice IN ONE COMMUNE — your labour share there, the weight
      ;; a ballot under that scope's franchise gives you. Reads the commune's
      ;; own root (a list of one, for account.scm's global reads); a commune
      ;; the gateway cannot name answers 0.
      ((set-scope-root-of! f) (set! scope-root-of f) 'ok)

      ((voice-in identity-key scope-id)
       (catch #t
         (lambda ()
           (let ((root (scope-root scope-id)))
             (list (cons 'producer (if root
                                       (exact->inexact (voice-share identity-key (list root)))
                                       0.0)))))
         (lambda _ (list (cons 'producer 0.0)))))

      ((open identity-key kind domain id description franchise . rest)
       (cond
         ((not (governor? identity-key))
          (list 'error "governor credential required to open"))
         ;; an id already open (or already tallied) must not be silently
         ;; replaced — `record` is a bare hashmap-set, so re-opening
         ;; discarded a live ballot actor with every vote cast so far
         ;; (the stance ACDCs survived in the store, but the replacement
         ;; actor tallied none of them)
         (($ ballot-store 'get id)
          (list 'error (string-append "proposal already open: " id)))
         (($ ballot-store 'get-tally id)
          (list 'error (string-append "proposal already closed: " id)))
         (else
          (ensure-citizen identity-key)
          (open-proposal! kind domain id description franchise rest))))

      ;; Legacy (unsigned) cast — the sealer path, kept for clients with no
      ;; signing key. A stance is CITIZEN-issued; the citizen cannot sign
      ;; server-side, so the durable ACDC is issued UNSIGNED (an honest unsigned
      ;; assertion). It must NOT be scope-signed: a scope signature would not
      ;; verify against the citizen issuer — worse than none. The conformant
      ;; path is `cast-signed`.
      ((cast identity-key id arg)
       (let ((event ($ ballot-store 'get id)))
         (cond
           ((not event) (list 'error "no such open event" id))
           (else
            (call-with-values
              (lambda () (ensure-citizen identity-key))
              (lambda (voice _s _dm)
                (catch #t
                  (lambda ()
                    (let ((kind   ($ event 'kind))
                          (domain ($ event 'domain)))
                      (case kind
                        ((ballot)     ($ event 'cast identity-key ($ voice 'stance id arg)))
                        ((expression) ($ event 'cast identity-key
                                         ($ voice 'stance-expression domain id arg))))
                      (when acdc-store
                        (case kind
                          ((ballot)
                           ($ acdc-store 'issue
                              (make-stance-credential
                               identity-key (recorder-aid) domain id arg (current-time)
                               #:ballot-snapshot-said (hashmap-ref snapshot-saids id #f))))
                          ((expression)
                           ;; arg is a live goblins hashmap — fold it to a
                           ;; key-sorted alist BEFORE it becomes SAID
                           ;; material. Hashing the hashmap itself went
                           ;; through its truncating printer (10 pairs, then
                           ;; "..."), so two DIFFERENT large distributions
                           ;; could collide into one SAID, and the durable
                           ;; store wrote an unreplayable #<hashmap …> form.
                           ;; canonical-string now refuses such objects
                           ;; loudly (said-portable.scm), so this fold is
                           ;; what makes the mint succeed at all.
                           ($ acdc-store 'issue
                              (make-expression-stance-credential
                               identity-key (recorder-aid) domain id
                               (distribution->alist arg) (current-time))))))
                      'ok))
                  (lambda (key . args)
                    (list 'error (format #f "cast failed: ~a ~a" key args))))))))))

      ;; --- Client-side citizen signing (the conformant stance path) ---
      ;;
      ;; A stance is the CITIZEN's assertion, so for it to be a conformant ACDC
      ;; the citizen's own controller must sign it — and their key is
      ;; client-side. Uses the generic protocol (see credentials.scm):
      ;;   stance-preimage → the exact credential's SAID fields; the client
      ;;   re-derives the SAID (compute-said, shared via keri/said-portable) and
      ;;   signs it; cast-signed rebuilds identically and accepts iff the
      ;;   signature verifies against the caller AID.
      ;;
      ;; The client provides its position up front, so the server builds the WHOLE
      ;; credential and hands back its SAID fields — no ballot-specific preimage
      ;; shape. Timestamp is server-issued (the Hoot client is clock-free) and
      ;; echoed back; the SAID commits to it, and an identical replay collapses
      ;; under issue-idempotent.
      ((stance-preimage identity-key id position)
       (let ((event ($ ballot-store 'get id)))
         (cond
           ((not event) (list 'error "no such open event" id))
           (else
            (list 'ok
                  (credential-preimage-fields
                   (make-stance-credential
                    identity-key (recorder-aid)
                    ($ event 'domain) id position (current-time)
                    #:ballot-snapshot-said (hashmap-ref snapshot-saids id #f))))))))

      ;; U is the blinding nonce the client signed over, echoed back from the
      ;; preimage's claims alongside TIMESTAMP. Both are server-issued and
      ;; SAID-committed, so the rebuild below MUST use the client's values or
      ;; the signature cannot verify.
      ;;
      ;; The trailing arg is variadic only so a five-arg call is a clean
      ;; rejection rather than an arity crash — see the explicit guard below.
      ;; DEPLOY ORDER: the browser wasm (day-boot.scm) and this service must
      ;; ship together; a stale service-worker-cached client will be told to
      ;; refresh rather than silently failing to vote.
      ;; The trailing tail is `(U)` from a direct/test caller, or `(U VERIFY-KEY)`
      ;; from the lobby session. VERIFY-KEY is the caller's CURRENT signing key,
      ;; which the session resolved from the KEL (^oobi-host, in its own vat): a
      ;; transferable E-prefix AID does NOT encode its key in the prefix — the
      ;; latest rotation's k[0] does — so a stance signature must be checked
      ;; against the resolved key, not the AID. A non-transferable D/B-prefix AID
      ;; (tests, direct calls) supplies no key and we fall back to the AID, which
      ;; IS the key. This mirrors ^lobby's keri-authenticate resolution.
      ((cast-signed identity-key id position timestamp signature . opt)
       (let ((event ($ ballot-store 'get id))
             (u     (if (pair? opt) (car opt) #f))
             (vkey  (if (and (pair? opt) (pair? (cdr opt)) (string? (cadr opt)))
                        (cadr opt) identity-key)))
         (cond
           ((not event) (list 'error "no such open event" id))
           ((not u)
            (list 'error
                  "stance nonce (u) missing — echo it from the preimage claims; \
a stale client bundle needs a refresh"))
           (else
            (call-with-values
              (lambda () (ensure-citizen identity-key))
              (lambda (voice _s _dm)
                (catch #t
                  (lambda ()
                    (let ((cred (make-stance-credential
                                 identity-key (recorder-aid)
                                 ($ event 'domain) id position timestamp
                                 #:u u
                                 #:ballot-snapshot-said
                                 (hashmap-ref snapshot-saids id #f))))
                      (cond
                        ((not (client-signature-ok? cred vkey signature))
                         (list 'error
                               "stance signature does not verify against caller AID"))
                        (else
                         ;; ONE signature, both consumers: the live tally and the
                         ;; durable ACDC verify the SAME citizen signature over the
                         ;; SAME SAID. The ballot's unified verifier takes the
                         ;; (said sig . vkey) proof and checks it against the
                         ;; resolved key (falling back to the AID when vkey is the
                         ;; AID) — no sealer, no need for the citizen to be in the
                         ;; frozen registry.
                         (let ((cleartext (list 'stance id position
                                                identity-key identity-key)))
                           ($ event 'cast identity-key
                              (cons cleartext
                                    (cons (cred-said cred) (cons signature vkey)))))
                         (when acdc-store
                           ($ acdc-store 'issue-idempotent
                              (cred-with-signature cred signature)))
                         'ok))))
                  (lambda (key . args)
                    (list 'error
                          (format #f "cast-signed failed: ~a ~a" key args))))))))))

      ;; ── Producer voice over the plan: a HAND of signed stances on PARTS ──────
      ;; docs/planning/voice/voice-over-the-plan.md "The warp, and the
      ;; conversation": a stance is signed as an expression-stance credential
      ;; with domain plan-part, its targets the parts in VF terms
      ;; (parts.scm part->string), its values SIGNED in [−1, 1] — dislike to
      ;; like. No expression is opened: the hand stands on the scope's rail
      ;; under expression-id "plan-part:<scope>", the newest non-revoked
      ;; credential per citizen is their standing hand (a cast revokes the
      ;; previous one), and the planner's voice fold reads the rows through
      ;; `plan-part-hands`. The client signs, as for cast-signed: the preimage
      ;; hands back the SAID fields, the signed leg rebuilds the identical
      ;; credential and accepts iff the signature verifies. HAND is an alist
      ;; ((part-string . portion) …) — checked by parts.scm validate-hand,
      ;; never by validate-distribution (that is the ballot tally's rule, and
      ;; a hand is signed where a distribution is not).
      ((part-stance-preimage identity-key scope-id hand)
       (catch #t
         (lambda ()
           (validate-hand hand)
           (list 'ok (credential-preimage-fields
                      (make-expression-stance-credential
                       identity-key (recorder-aid) "plan-part"
                       (string-append "plan-part:" scope-id)
                       (distribution->alist hand) (current-time)))))
         (lambda (key . args) (list 'error (format #f "part-stance-preimage failed: ~a ~a" key args)))))

      ((cast-part-signed identity-key scope-id hand timestamp signature . opt)
       (let ((u    (if (pair? opt) (car opt) #f))
             (vkey (if (and (pair? opt) (pair? (cdr opt)) (string? (cadr opt))) (cadr opt) identity-key)))
         (cond
           ((not u) (list 'error "stance nonce (u) missing — echo it from the preimage claims"))
           ((not acdc-store) (list 'error "no credential store: a hand needs a rail to stand on"))
           (else
            (catch #t
              (lambda ()
                (validate-hand hand)
                (let ((cred (make-expression-stance-credential
                             identity-key (recorder-aid) "plan-part"
                             (string-append "plan-part:" scope-id)
                             (distribution->alist hand) timestamp #:u u)))
                  (cond
                    ((not (client-signature-ok? cred vkey signature))
                     (list 'error "stance signature does not verify against caller AID"))
                    (else
                     ;; the previous hand steps down: stances stand until changed
                     (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c)))
                               (standing-part-hands acdc-store scope-id identity-key))
                     ($ acdc-store 'issue-idempotent (cred-with-signature cred signature))
                     'ok))))
              (lambda (key . args) (list 'error (format #f "cast-part-signed failed: ~a ~a" key args))))))))

      ;; the standing hands on SCOPE-ID's rail, as rows ((owner part-string portion) …):
      ;; what the planner's voice fold takes (planner service `hands!`)
      ((plan-part-hands scope-id) (plan-part-hands-of acdc-store scope-id))

      ;; opts (kw-ref): 'ratify (cons proposal-type proposal-spec) — mint a
      ;; recomposition-ratification credential from THIS close's own tally,
      ;; self-issued by (recorder-aid), the same generic shape
      ;; make-recomposition-ratification-credential already uses for
      ;; admit-commune/merge-with/split (credentials.scm). Read right here,
      ;; not as a separate step: snap-said/entries/winner exist in this one
      ;; place, and snapshot-saids is freed at the end of this same call —
      ;; a caller that wanted to ratify AFTER close would find nothing left
      ;; to point the ballot-snapshot edge at. Returns (ok id) normally, or
      ;; (ok id ratification-said) when 'ratify was requested and the
      ;; threshold was met — accept-socialization/accept-reimbursement take
      ;; that SAID straight as their own 'ratification opt.
      ((close identity-key id . opts)
       (cond
         ((not (governor? identity-key))
          (list 'error "governor credential required to close"))
         (else
          (let ((event ($ ballot-store 'get id)))
            (cond
              ((not event) (list 'error "no such open event" id))
              (else
               (let ((kind   ($ event 'kind))
                     (domain ($ event 'domain))
                     (ratify (kw-ref opts 'ratify #f)))
                 ($ event 'close)
                 (case kind
                   ((ballot)
                    (let* ((tally-result ($ event 'tally))
                           (tally-map  (assoc-ref tally-result 'tally))
                           (abstain    (assoc-ref tally-result 'abstain))
                           (now        (current-time))
                           (ratification-said #f))
                      ($ ballot-store 'record-tally id tally-map abstain now)
                      ($ ballot-store 'forget id)
                      (settle-contest! id tally-map abstain)
                      (when acdc-store
                        (let* ((entries
                                (hashmap-fold
                                  (lambda (k v acc) (cons (cons k v) acc))
                                  '() tally-map))
                               (winner
                                (and (pair? entries)
                                     (caar (sort entries
                                                 (lambda (a b) (> (cdr a) (cdr b)))))))
                               (snap-said (hashmap-ref snapshot-saids id #f))
                               (tally-cred
                                (sign-as-recorder
                                 (make-tally-result-credential
                                  (recorder-aid) domain id 'federation
                                  ;; the folded, key-sorted entries — never
                                  ;; the raw hashmap, whose printer truncates
                                  ;; past 10 pairs (a lossy "auditable proof")
                                  ;; and which canonical-string now refuses
                                  winner (canonical-string (said-sort-pairs entries))
                                  abstain now
                                  ;; §4.9: edge to ballot-snapshot.
                                  #:ballot-snapshot-said snap-said))))
                          ($ acdc-store 'issue tally-cred)
                          ;; §4.6: anchor tally-result in the home
                          ;; scope's KEL via an ixn event.
                          (when (and home-scope
                                     ($ home-scope 'has-keypair?))
                            (catch #t
                              (lambda ()
                                ($ home-scope 'anchor-acdc
                                   (cred-said tally-cred)))
                              (lambda _ #f)))
                          (when ratify
                            (let* ((proposal-type (car ratify))
                                   (proposal-spec (cdr ratify))
                                   (threshold-met? (and winner (carries? (assoc-ref entries winner) entries abstain))))
                              (when threshold-met?
                                (let ((rat (sign-as-recorder
                                            (make-recomposition-ratification-credential
                                             (recorder-aid) proposal-type proposal-spec
                                             snap-said entries #:threshold-met? #t))))
                                  ($ acdc-store 'issue rat)
                                  (set! ratification-said (cred-said rat))))))
                          ;; Free the proposal-id from the snapshot map
                          ;; once we no longer need to look it up.
                          (set! snapshot-saids
                                (hashmap-remove snapshot-saids id))))
                      (if ratification-said
                          (list 'ok id ratification-said)
                          (list 'ok id))))
                   ((expression)
                    ($ ballot-store 'forget id)
                    (list 'ok id))))))))))

      ((get-result id)
       ;; Public read. Returns:
       ;;   (closed . tally-record)        — for closed ballots (recorded)
       ;;   (open   . live-result-alist)   — for open ballots/expressions
       ;;   (error …)                      — for unknown ids
       (let ((rec  ($ ballot-store 'get-tally id))
             (meta ($ ballot-store 'meta id)))
         (cond
           (rec (cons 'closed (append rec meta)))
           (else
            (let ((event ($ ballot-store 'get id)))
              (cond
                ((not event) (list 'error "unknown id" id))
                (else
                 ;; Carry the proposal's CLASS metadata (kind + domain) so the
                 ;; dial can sort it into production vs consumption governance
                 ;; (governance-surface.md — the two classes, two voices).
                 (cons 'open
                       (append
                        (case ($ event 'kind)
                          ((ballot)     ($ event 'tally))
                          ((expression) ($ event 'result)))
                        ;; the registry's meta: kind, domain, the question
                        ;; itself, franchise, opened-at, subject
                        meta)))))))))

      ((list-proposals)
       ($ ballot-store 'list-proposals)))))
