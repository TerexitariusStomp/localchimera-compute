;;; module/playnet/doors/identity.scm — the identity doors of the lobby and the session
;;;
;;; Who is this, what may they sign, how are they reached: the doors that
;;; are identity's, written here as two FRAGMENTS the gateway's objects
;;; compose (protocol/dispatch.scm declared-doors / declared-methods*):
;;;
;;;   (identity-lobby-doors signup-agent oobi-host spawn-session)
;;;       the anonymous lobby's: signup, the key log witnessed and served,
;;;       the seat, the challenge and the two authentications — which spawn
;;;       the session through SPAWN-SESSION (aid tier doors)
;;;   (identity-session-doors ctx)
;;;       a seated AID's: contact points, cards, the profile, personhood and
;;;       vouches, credential backups and watches, recovery shares, devices,
;;;       rotation, erasure — over a <session-identity> that names what the
;;;       session's closure gave them (doors/lobby.scm ^lobby-session)
;;;
;;; The clauses are the ones doors/lobby.scm held, moved verbatim; what each door
;;; does is documented on its declaration in (playnet doors protocol). The
;;; protocol lint (tools/lint/protocol-extract.scm) reads this file with
;;; doors/lobby.scm, so the declaration is held to the union.

(define-module (playnet doors identity)
  #:use-module (goblins)
  #:use-module ((goblins utils hashmap) #:select (hashmap hashmap-ref hashmap-set hashmap-remove))
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))
  #:use-module ((playnet utils common) #:select (env-flag?))
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module (playnet utils constant-time)
  #:use-module ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes))
  #:use-module ((playnet keri citizen-sig)
                #:select (verify-said-signature verify-said-signature-under-key))
  #:use-module ((playnet keri bridge) #:select (keri-verify-signature))
  #:use-module ((playnet keri reticulum-binding) #:select (anchored-destinations))
  #:use-module ((playnet identity seat) #:select (verify-rotation-event normalize-vecs aid-tag))
  #:use-module ((playnet identity devices)
                #:select (device-wire->cred device-credential-verdict
                          device-enroll! device-revoke! devices-of device-entry
                          device-entry-doors device-entry-live? device-entry->wire-alist))
  #:use-module ((playnet identity cards)
                #:select (card-wire->card card-verdict card-at card-put! card-get card-drop! person-aid?))
  #:use-module ((playnet identity contact-points)
                #:select (contact-point-wire->cred contact-point-verdict))
  #:use-module ((playnet identity forget) #:select (forget-member!))
  #:use-module ((playnet interface adapters email) #:select (mail-spool-forget!))
  #:use-module ((playnet identity user-files)
                #:select (%data-dir %user-file %read-user-data %write-user-data!))
  #:use-module ((playnet keri first-person credentials) #:select (contact-point-binding-fields))
  #:use-module ((playnet federation keria-notifications)
                #:select (register-credential-watcher! unregister-credential-watcher!))
  #:use-module ((playnet notify recipient) #:select (durable-kind? binding-kind binding-ctx))
  #:use-module ((playnet social lens) #:select (contact-aid))
  #:export (identity-lobby-doors identity-session-doors
            make-session-identity session-identity?
            cards-dir credentials-file-for))

;;; ── what the session's identity doors read ──────────────────────────────
;;; The names a session's closure gave its identity doors, as one record:
;;; the stores, the tier the seat was proven at, and three procedures of
;;; the session's own — planner! (its forward to the planner), own-book
;;; (its contact book), anchored-mesh-pub (its KEL-anchored mesh key) — plus
;;; announced-name, a thunk, since presence keys by the name the session
;;; announced and a forget leaves by it.

(define-record-type <session-identity>
  (%make-session-identity aid-prefix tier signup-agent oobi-host acdc-store
                          recipient-registry contact-desk presence push-store pins
                          folksonomy mailbox-mgr governance-svc planner! announced-name
                          own-book anchored-mesh-pub mesh-mailbox)
  session-identity?
  (aid-prefix si-aid-prefix) (tier si-tier) (signup-agent si-signup-agent)
  (oobi-host si-oobi-host) (acdc-store si-acdc-store)
  (recipient-registry si-recipient-registry) (contact-desk si-contact-desk)
  (presence si-presence) (push-store si-push-store) (pins si-pins)
  (folksonomy si-folksonomy) (mailbox-mgr si-mailbox-mgr)
  (governance-svc si-governance-svc) (planner! si-planner!)
  (announced-name si-announced-name) (own-book si-own-book)
  (anchored-mesh-pub si-anchored-mesh-pub) (mesh-mailbox si-mesh-mailbox))

(define* (make-session-identity #:key aid-prefix (tier 'root) signup-agent
                                (oobi-host #f) (acdc-store #f) (recipient-registry #f)
                                (contact-desk #f) (presence #f) (push-store #f) (pins #f)
                                (folksonomy #f) (mailbox-mgr #f) governance-svc planner!
                                (announced-name (lambda () #f)) own-book anchored-mesh-pub
                                (mesh-mailbox #f))
  (%make-session-identity aid-prefix tier signup-agent oobi-host acdc-store
                          recipient-registry contact-desk presence push-store pins
                          folksonomy mailbox-mgr governance-svc planner! announced-name
                          own-book anchored-mesh-pub mesh-mailbox))

;;; ── the files identity keeps beside the per-AID files ───────────────────
(define (cards-dir) (string-append (%data-dir) "/cards"))
(define (credentials-file-for aid-prefix) (%user-file "credentials" aid-prefix))

;;; ── the challenge: nonces that expire, so a signature cannot be replayed ──
(define %nonce-ttl 120)  ; 2 minutes

(define (generate-nonce)
  "Generate a 32-byte random nonce as a hex string. Routes through the
   keri-crypto backend (server: /dev/urandom; browser: getRandomValues)
   instead of Guile's `(random …)`, whose default *random-state* is a
   fixed Mersenne-Twister seed — that would make every gateway boot
   emit the same nonce sequence and break replay protection."
  (bv->hex (keri-crypto-random-bytes 32)))

(define (nonce-expired? timestamp)
  (> (- (instant->unix (clock-now)) timestamp) %nonce-ttl))

;;; ── the lobby's identity doors ───────────────────────────────────────────

(define (identity-lobby-doors signup-agent oobi-host spawn-session)
  "The anonymous lobby's identity doors (declared `lobby` in (playnet doors protocol)): a declared-doors fragment. SPAWN-SESSION (aid-prefix tier
   doors) is the lobby's own — the session it hands a proven seat."
  ;; pending-challenges: hashmap of nonce → (aid-prefix . timestamp),
  ;; checked on keri-authenticate, expired entries pruned lazily
  (let ((pending-challenges (hashmap)))
    ;; The account-creation feature, on or off: a GDPR-deferral switch, not
    ;; a capability gap. PLAYNET_DISABLE_REAL_SIGNUP turns new real-identity
    ;; signups off; unset (the default) leaves them on, matching every
    ;; deploy before this flag existed. See docs/legal/gdpr-
    ;; analysis.md and deploy/os.scm's gateway-service environment for why
    ;; production sets it and dev does not. The doors it gates are the ones
    ;; declared `#:feature account-creation` in doors/protocol.scm — the same
    ;; declaration the product's law reads them off (`doors-of-feature`);
    ;; tests/knowledge/test-signup-disabled-gate.scm holds the wrappers below to
    ;; exactly that set, so neither can drift from the other.
    (define (real-signup-enabled?)
      (not (env-flag? "PLAYNET_DISABLE_REAL_SIGNUP")))

    (define (signup-gated thunk)
      (if (real-signup-enabled?)
          (thunk)
          (list 'error "real account creation is temporarily disabled on this gateway")))

    (declared-doors lobby

     ;; ── Account registration (KERI) ───────────────────────────────────────
     ;; Legacy path: user provides AID prefix + OOBI URL hosted elsewhere.
     ;; Server resolves OOBI via KERIA (witness-verified), then persists.
     ((signup username email aid-prefix oobi-url)
      (signup-gated (lambda ()
        (<- signup-agent 'register! username email aid-prefix oobi-url))))

     ;; Browser-resident-Signify path: the user creates the AID locally
     ;; and ships the inception event + signatures. The server verifies
     ;; them offline (no KERIA round-trip) and stores the ICP in
     ;; ^oobi-host. Per (playnet identity seat) verify-self-signed-icp,
     ;; we check (i) AID matches icp.k[0], (ii) recomputed SAID matches
     ;; icp.d, (iii) sigs[0] verifies under the AID's pubkey.
     ;; Returns 'ok or (list 'error "reason").
     ((signup-with-icp username email aid-prefix icp-alist sigs)
      (signup-gated (lambda ()
        (<- signup-agent 'register-with-icp!
            username email aid-prefix icp-alist sigs oobi-host))))

     ;; The controller brings its whole KEL — icp, sigs, and ROTATIONS
     ;; (a vector of (rot . sigs) in sn order) — and takes a seat here
     ;; under its existing, possibly rotated, key state. This is the
     ;; door an identity walks through when it arrives at a commune
     ;; that has never seen it: the KEL is the controller's own signed
     ;; log, verified end to end by signup-agent. A KEL with no
     ;; rotations is signup-with-icp.
     ((signup-with-kel username email aid-prefix icp-alist sigs rotations)
      (signup-gated (lambda ()
        (<- signup-agent 'register-with-kel!
            username email aid-prefix icp-alist sigs rotations oobi-host))))

     ;; The controller's log has moved on elsewhere and this commune is
     ;; behind: ROTATIONS (a vector of (rot . sigs), sn order, continuing
     ;; from this commune's last event) catch it up. Public, like
     ;; fetch-icp — a rotation proves its own authorship, so possession
     ;; of a verifiable one is the only authority that matters, and the
     ;; session that would otherwise gate it is exactly what a stale
     ;; copy of the log cannot grant.
     ((extend-kel aid-prefix rotations)
      (<- signup-agent 'register-rotations! aid-prefix rotations
          (and oobi-host (string? aid-prefix) ($ oobi-host 'get aid-prefix))
          oobi-host))

     ;; ── witnessing and seating, apart ──
     ;; witness-kel: the log into ^oobi-host on its own terms — any
     ;; verifiable KEL from anyone who forwards it; no username, no seat.
     ;; Levels a known AID up (rotations beyond the held depth), refuses
     ;; a different history under one AID. Public, like fetch-icp.

     ;; join: a seat in this gateway's universal commune for an AID
     ;; already witnessed here. The seat is what keri-authenticate checks
     ;; for; scope standing below the UC is a governance act, not this.
     ((join username email aid-prefix)
      (signup-gated (lambda ()
        (<- signup-agent 'join! username email aid-prefix
            (and oobi-host (string? aid-prefix)
                 ($ oobi-host 'get aid-prefix) #t)))))

     ((has-seat aid-prefix)
      (<- signup-agent 'has-seat? aid-prefix))

     ;; Follow-up to signup-with-icp: the browser endorses its OKEA
     ;; endpoint replies (/end/role/add + /loc/scheme, framed CESR
     ;; strings) with the AID's own key and ships them here, so the
     ;; served OOBI advertises WHERE the AID is, not just WHO
     ;; (OOBI §3.4). Validation (sig under the AID's pubkey, route
     ;; whitelist) happens in signup-agent.
     ;; We read the AID's current signing key here (^lobby shares
     ;; gateway-vat with ^oobi-host, so the `$` read is synchronous)
     ;; and pass it along — signup-agent lives in another vat and
     ;; must not read oobi-host itself.
     ((register-oobi-replies aid-prefix replies)
      (<- signup-agent 'register-oobi-replies!
          aid-prefix
          (and oobi-host (string? aid-prefix)
               ($ oobi-host 'current-key aid-prefix))
          replies oobi-host))

     ;; Cross-device recovery: hand back the stored ICP+rotations for AID
     ;; so a new browser can import the AID and unlock with its bran.
     ;; Returns the entry alist, or #f if the AID isn't known.
     ;; Public method — no auth needed; callers prove AID ownership by
     ;; possessing the bran (which they use to re-derive keys locally).
     ((fetch-icp aid-prefix)
      (and oobi-host (<- oobi-host 'get aid-prefix)))

     ;; The same entry, found by a KEY its events carry: a device that
     ;; holds only the passcode derives the passcode's first key — the
     ;; inception's, or the rotation's that a passcode change made — and
     ;; asks for the log it appears in. Public, like fetch-icp — a log is
     ;; public, and the caller verifies the one it is handed and checks its
     ;; own passcode opens it before using it.
     ((find-icp event-key)
      (and oobi-host (<- oobi-host 'by-event-key event-key)))

     ;; NOTE: rotate-aid and list-credentials have moved to
     ;; ^lobby-session (returned by keri-authenticate). Callers
     ;; holding the session cap invoke them there; the AID is
     ;; closed-over and cannot be impersonated.

     ;; ── KERI challenge-response auth ──────────────────────────────────────
     ;;
     ;; Step 1: get a nonce to sign.
     ;; The client should send their AID prefix so we can associate the nonce.
     ;; Returns nonce string (hex).
     ((keri-challenge aid-prefix)
      (let* ((nonce (generate-nonce))
             (now   (instant->unix (clock-now))))
        (set! pending-challenges
              (hashmap-set pending-challenges nonce (cons aid-prefix now)))
        nonce))

     ;; Step 2: verify the signed nonce.
     ;; aid-prefix     — the user's AID
     ;; signature-qb64 — CESR ed25519 sig over nonce ('0B...')
     ;; nonce          — the nonce returned from keri-challenge
     ;; Returns 'ok (with aid-prefix as identity) or (list 'error reason).
     ((keri-authenticate aid-prefix signature-qb64 nonce)
      ;; Prune expired challenges lazily
      (let ((entry (hashmap-ref pending-challenges nonce #f)))
        (cond
         ((not entry)
          (list 'error "unknown or expired nonce"))
         ;; Constant-time comparison: prevents timing side-channel
         ;; that could reconstruct a valid AID prefix byte-by-byte.
         ((not (constant-time-string=? (car entry) aid-prefix))
          (list 'error "AID mismatch for this nonce"))
         ((nonce-expired? (cdr entry))
          (set! pending-challenges
                (hashmap-remove pending-challenges nonce))
          (list 'error "nonce expired"))
         (else
          (set! pending-challenges
                (hashmap-remove pending-challenges nonce))
          ;; ^oobi-host now lives in the same vat as ^lobby, so we
          ;; can call it synchronously to resolve the current signing
          ;; key (post-rotation the AID prefix no longer encodes the
          ;; key — the latest-rotation k[0] does). For unrotated D/B-
          ;; prefix AIDs (or when the AID isn't in oobi-host) we fall
          ;; back to keri-verify-signature, which handles fast-path
          ;; verification against the prefix.
          (catch #t
            (lambda ()
              (let* ((current-key (and oobi-host
                                       ($ oobi-host 'current-key aid-prefix)))
                     (verified?
                      (cond
                       ((string? current-key)
                        (verify-said-signature nonce signature-qb64 current-key))
                       (else
                        (keri-verify-signature aid-prefix nonce signature-qb64)))))
                (cond
                 ((not verified?)
                  (list 'error "signature verification failed"))
                 (else
                  ;; Spawn a session facet bound to this AID and return
                  ;; the cap. Callers use the cap for all privileged
                  ;; operations (rotate-aid, list-credentials, governance
                  ;; methods, terminal, mailbox). The AID is the
                  ;; closure, not a passable parameter.
                  ;;
                  ;; THE SEAT GATE. A key proven is not a seat held:
                  ;; ^oobi-host witnesses any verifiable KEL, so an AID
                  ;; with a current-key here may never have joined. With
                  ;; an oobi-host in play the seat is asked of
                  ;; signup-agent (another vat — so the answer is a
                  ;; promise, which the caller's `on` resolves). Without
                  ;; one, the prefix-verified path stands as it was.
                  (let ((seat!
                         (lambda ()
                           (let ((session (spawn-session aid-prefix 'root #f)))
                             (format (current-error-port)
                                     "[lobby] authenticated (~a)\n" (aid-tag aid-prefix))
                             (list 'ok session)))))
                    (if (string? current-key)
                        (on (<- signup-agent 'has-seat? aid-prefix)
                            (lambda (seated?)
                              (if seated?
                                  (seat!)
                                  (list 'error "no seat here: join first")))
                            #:catch (lambda _ (list 'error "no seat here: join first"))
                            #:promise? #t)
                        (seat!)))))))
            (lambda (key . args)
              (list 'error (format #f "auth verify error: ~a ~a" key args))))))))

     ;; Step 2, device form: the AID's root authorized this device's key
     ;; (WIRE-JSON, a device-authorization credential the root signed) and
     ;; the device signed the nonce. The session is the person's, at tier
     ;; 'device. The nonce came from keri-challenge under the PERSON's AID.
     ((keri-authenticate-device aid-prefix wire-json signature-qb64 nonce)
      (let ((entry (hashmap-ref pending-challenges nonce #f)))
        (cond
         ((not entry) (list 'error "unknown or expired nonce"))
         ((not (constant-time-string=? (car entry) aid-prefix))
          (list 'error "AID mismatch for this nonce"))
         ((nonce-expired? (cdr entry))
          (set! pending-challenges (hashmap-remove pending-challenges nonce))
          (list 'error "nonce expired"))
         (else
          (set! pending-challenges (hashmap-remove pending-challenges nonce))
          (catch #t
            (lambda ()
              (let* ((cred (and (string? wire-json) (device-wire->cred wire-json)))
                     (root-key (or (and oobi-host ($ oobi-host 'current-key aid-prefix))
                                   aid-prefix))
                     (verdict (and cred (device-credential-verdict cred aid-prefix root-key)))
                     (said (and cred (assq-ref cred 'said)))
                     (reg (and said (device-entry aid-prefix said)))
                     (device-aid (and cred (assq-ref cred 'holder))))
                (cond
                 ((not cred) (list 'error "malformed device authorization"))
                 ;; the registry speaks first: a retired device is told so
                 ;; whatever else is true of its authorization
                 ((and reg (not (device-entry-live? reg (instant->unix (clock-now)))))
                  (list 'error "device authorization revoked or expired"))
                 ;; an authorization verifies under the key in force: one the
                 ;; root signed before a rotation is retired by that rotation,
                 ;; and the passcode seat that follows authorizes afresh
                 ((equal? verdict "signature is not the root's")
                  (list 'error "device authorization revoked: it predates the key now in force"))
                 ((not (eq? verdict #t)) (list 'error verdict))
                 ((not reg) (list 'error "device not enrolled here"))
                 ((not (verify-said-signature-under-key nonce signature-qb64 device-aid))
                  (list 'error "signature verification failed"))
                 (else
                  (let ((seat!
                         (lambda ()
                           (let ((session (spawn-session aid-prefix 'device (device-entry-doors reg))))
                             (format (current-error-port)
                                     "[lobby] authenticated (~a) by device ~a\n"
                                     (aid-tag aid-prefix) (aid-tag device-aid))
                             (list 'ok session)))))
                    (if oobi-host
                        (on (<- signup-agent 'has-seat? aid-prefix)
                            (lambda (seated?)
                              (if seated? (seat!) (list 'error "no seat here: join first")))
                            #:catch (lambda _ (list 'error "no seat here: join first"))
                            #:promise? #t)
                        (seat!)))))))
            (lambda (key . args)
              (list 'error (format #f "auth verify error: ~a ~a" key args))))))))

     ;; The AI doors (transcribe, express, ai-complete) are the session's:
     ;; the commons pays per call, so a call has a seat and a budget.
)))

;;; ── the session's identity doors ────────────────────────────────────────

(define (identity-session-doors ctx)
  "A seated AID's identity doors (declared `session` in (playnet doors protocol)):
   a declared-doors fragment over CTX, a <session-identity>."
  (let ((aid-prefix (si-aid-prefix ctx)) (tier (si-tier ctx))
        (signup-agent (si-signup-agent ctx)) (oobi-host (si-oobi-host ctx))
        (acdc-store (si-acdc-store ctx)) (recipient-registry (si-recipient-registry ctx))
        (contact-desk (si-contact-desk ctx)) (presence (si-presence ctx))
        (push-store (si-push-store ctx)) (pins (si-pins ctx))
        (folksonomy (si-folksonomy ctx)) (mailbox-mgr (si-mailbox-mgr ctx))
        (governance-svc (si-governance-svc ctx)) (planner! (si-planner! ctx))
        (announced-name (si-announced-name ctx)) (own-book (si-own-book ctx))
        (anchored-mesh-pub (si-anchored-mesh-pub ctx)) (mesh-mailbox (si-mesh-mailbox ctx)))
    ;; the acts that reshape the identity need the KEL key, never a device's
    (define (root-only what thunk)
      (if (eq? tier 'root)
          (thunk)
          (list 'error (string-append what " needs the passcode: sign in with it first"))))

    (declared-doors session

   ;; Diagnostic: which AID is this session bound to? Browser uses
   ;; this to verify the cap it's holding matches what it expects.
   ((whoami) aid-prefix)

   ;; ── Contact points ──────────────────────────────────────────────────
   ;;
   ;; How to reach this AID on a durable channel: an email address, an lxmf
   ;; address, a matrix room. `announce` binds 'browser and `register-push`
   ;; binds 'push as a client connects; the four methods below are the path
   ;; from a person's own word to the router for the channels that last.
   ;;
   ;; The AID is closed over, so a caller can only ever bind, list or drop
   ;; its OWN channel. That is the security property: without it anyone
   ;; could bind a channel under someone else's AID and redirect their
   ;; notifications.
   ;;
   ;; The registry is the live source of truth — the member record's email
   ;; field predates this and is display-only. `withdraw-contact-point` is
   ;; therefore a real erasure path for a notification address.
   ;;
   ;; What binds is the person's own contact-point credential, presented
   ;; (identity/contact-points.scm): self-issued, blinded, signed. The commune
   ;; rebuilds it, checks it is the presenter's own, and holds it at the desk
   ;; while a code travels to the address itself; the code said back
   ;; (confirm-contact-point) is what binds the channel. So a commune delivers
   ;; only to an address that answered, for a person who signed for it.
   ((present-contact-point wire)
    (let ((cred (contact-point-wire->cred wire)))
      (cond
       ((string? cred) (cons 'error cred))
       ((not (and recipient-registry contact-desk))
        (cons 'error "this commune delivers to no contact points"))
       (else
        (let ((verdict (contact-point-verdict cred aid-prefix)))
          (if (not (eq? verdict #t))
              (cons 'error verdict)
              (let* ((fields (contact-point-binding-fields cred))
                     (held (apply contact-desk 'present aid-prefix fields)))
                (if (eq? held 'pending) (cons 'ok 'pending) held))))))))

   ((confirm-contact-point kind ctx code)
    (if (not (and recipient-registry contact-desk))
        (cons 'error "this commune delivers to no contact points")
        (let ((style (contact-desk 'confirm aid-prefix kind ctx code)))
          (if (symbol? style)
              (begin (<-np recipient-registry 'bind aid-prefix kind ctx style)
                     (cons 'ok #t))
              style))))

   ;; withdrawing is erasure: the binding leaves the registry (and its
   ;; keeper's file), and a point still waiting at the desk is put down
   ((withdraw-contact-point kind ctx)
    (cond
     ((not recipient-registry) (cons 'error "this commune delivers to no contact points"))
     (else
      (when contact-desk (contact-desk 'drop aid-prefix kind ctx))
      (<-np recipient-registry 'unbind aid-prefix kind ctx)
      (cons 'ok #t))))

   ;; The kinds this commune delivers on, and this AID's points on them: each
   ;; (kind ctx state), state `bound` or `pending` (its code is on its way).
   ;; Live kinds (browser, push) are connect-time state rebuilt on reconnect —
   ;; they are not contact points the person manages, so they stay out.
   ((my-contact-points)
    `((delivers . ,(if contact-desk (contact-desk 'delivers) '()))
      (points . ,(append
                  (if (not recipient-registry) '()
                      (filter-map
                       (lambda (b)
                         (and (durable-kind? (binding-kind b))
                              (list (binding-kind b) (binding-ctx b) 'bound)))
                       ($ recipient-registry 'bindings-for aid-prefix)))
                  (if (not contact-desk) '()
                      (map (lambda (p) (list (car p) (cadr p) 'pending))
                           (contact-desk 'pending aid-prefix)))))))

   ;; ── profile (settings) ── the AID edits its OWN display-name + email.
   ((profile) (<- signup-agent 'profile aid-prefix))

   ((update-profile display-name email)
    (<- signup-agent 'update-profile! aid-prefix display-name email))

   ;; ── First-Person ── personhood/vouch/enrollment, bound to THIS AID.
   ((fp-status scope-id) (<- governance-svc 'fp-status aid-prefix scope-id))

   ((fp-vouch scope-id subject-aid rel)
    (<- governance-svc 'fp-vouch aid-prefix scope-id subject-aid rel))

   ;; the client-signed pair: the vouch in the voucher's own signature
   ((fp-vouch-preimage scope-id subject-aid rel at)
    (<- governance-svc 'fp-vouch-preimage aid-prefix scope-id subject-aid rel at))

   ((fp-vouch-signed scope-id subject-aid rel at signature)
    (<- governance-svc 'fp-vouch-signed aid-prefix scope-id subject-aid rel at signature))

   ((fp-withdraw-vouch scope-id subject-aid)
    (<- governance-svc 'fp-withdraw-vouch aid-prefix scope-id subject-aid))

   ;; what stands between this AID and each person in its own book — the
   ;; book is read here, so the reading is of the caller's contacts alone

   ;; ── compute ── the commons' machine book. Identity-bound doors pass
   ;; this AID as the member the act belongs to: the lender on offer,
   ;; claim and preempt; the borrower on submit, withdraw and accept.
   ;; Reads are open.
   ((machine-offer commune-aid lane classes headroom repro . opts)
    (apply <- governance-svc 'machine-offer
           aid-prefix commune-aid lane classes headroom repro opts))

   ((machine-retract commune-aid offer-id)
    (<- governance-svc 'machine-retract aid-prefix commune-aid offer-id))

   ((machine-offers commune-aid)
    (<- governance-svc 'machine-offers commune-aid))

   ((machine-submit commune-aid task-class lane repro input-hash . opts)
    (apply <- governance-svc 'machine-submit
           aid-prefix commune-aid task-class lane repro input-hash opts))

   ((machine-withdraw commune-aid job-id)
    (<- governance-svc 'machine-withdraw aid-prefix commune-aid job-id))

   ((machine-jobs commune-aid)
    (<- governance-svc 'machine-jobs commune-aid))

   ((machine-match commune-aid job-id)
    (<- governance-svc 'machine-match commune-aid job-id))

   ((machine-claim commune-aid job-id offer-id . opts)
    (apply <- governance-svc 'machine-claim
           aid-prefix commune-aid job-id offer-id opts))

   ((machine-accept commune-aid claim-id)
    (<- governance-svc 'machine-accept aid-prefix commune-aid claim-id))

   ((machine-preempt commune-aid claim-id)
    (<- governance-svc 'machine-preempt aid-prefix commune-aid claim-id))

   ((machine-claims commune-aid)
    (<- governance-svc 'machine-claims commune-aid))

   ((machine-receipt commune-aid w)
    (<- governance-svc 'machine-receipt aid-prefix commune-aid w))

   ((machine-verify w)
    (<- governance-svc 'machine-verify w))

   ((machine-settle commune-aid w)
    (<- governance-svc 'machine-settle aid-prefix commune-aid w))

   ((machine-statements commune-aid)
    (<- governance-svc 'machine-statements commune-aid))

   ((machine-envelope w)
    (<- governance-svc 'machine-envelope w))

   ((machine-fetch-envelope commune-aid claim-id)
    (<- governance-svc 'machine-fetch-envelope aid-prefix commune-aid claim-id))

   ((machine-replay commune-aid claim-id)
    (<- governance-svc 'machine-replay aid-prefix commune-aid claim-id))

   ((machine-dispute commune-aid claim-id kind)
    (<- governance-svc 'machine-dispute aid-prefix commune-aid claim-id kind))

   ((machine-dispute-verdict commune-aid dispute-id verdict)
    (<- governance-svc 'machine-dispute-verdict aid-prefix commune-aid dispute-id verdict))

   ((machine-disputes commune-aid)
    (<- governance-svc 'machine-disputes aid-prefix commune-aid))

   ((machine-dispute-close commune-aid dispute-id)
    (<- governance-svc 'machine-dispute-close aid-prefix commune-aid dispute-id))

   ((machine-bind commune-aid w)
    (<- governance-svc 'machine-bind aid-prefix commune-aid w))

   ((machine-unbind commune-aid key side)
    (<- governance-svc 'machine-unbind aid-prefix commune-aid key side))

   ((machine-bindings commune-aid)
    (<- governance-svc 'machine-bindings aid-prefix commune-aid))

   ((machine-payout commune-aid w)
    (<- governance-svc 'machine-payout aid-prefix commune-aid w))

   ;; ── Cards ── how to reach this person, handed to one contact. The
   ;; content is sealed to the receiver in the giver's browser; the commune
   ;; keeps ciphertext it can tell is the giver's, one card per pair, and a
   ;; withdrawal erases it (identity/cards.scm). A card goes to, and is read
   ;; from, the people in the caller's own book.
   ((give-card subject-aid wire)
    (let ((card (card-wire->card wire)))
      (cond
       ((string? card) (cons 'error card))
       ((not (equal? subject-aid (assq-ref card 'to))) (cons 'error "the card is for someone else"))
       ((not (member subject-aid (filter-map contact-aid (own-book))))
        (cons 'error "a card goes to someone in your contacts"))
       (else
        (let ((verdict (card-verdict card aid-prefix)))
          (if (eq? verdict #t)
              (catch #t
                (lambda () (card-put! (cards-dir) card wire) (cons 'ok #t))
                (lambda _ (cons 'error "the card could not be kept")))
              (cons 'error verdict)))))))

   ((withdraw-card subject-aid)
    (if (person-aid? subject-aid)
        (begin (card-drop! (cards-dir) subject-aid aid-prefix) (cons 'ok #t))
        (cons 'error "a card is given to a person")))

   ;; what stands in cards between this AID and each person in its own book:
   ;; the card they gave (its wire, sealed to this AID) and when this AID's
   ;; own card to them was made
   ((cards)
    (cons 'ok
          (filter-map
           (lambda (aid)
             (and (person-aid? aid)
                  (let* ((theirs (card-get (cards-dir) aid-prefix aid))
                         (mine (card-get (cards-dir) aid aid-prefix))
                         (given (and mine (let ((c (card-wire->card mine))) (and (pair? c) (card-at c))))))
                    (and (or theirs given)
                         `((aid . ,aid) (card . ,theirs) (given . ,given))))))
           (filter-map contact-aid (own-book)))))

   ((fp-request-enroll scope-id)
    (<- governance-svc 'fp-request-enroll aid-prefix scope-id))

   ((fp-pending scope-id) (<- governance-svc 'fp-pending aid-prefix scope-id))

   ;; the caller's own ask, read from the ceremony
   ((fp-my-ceremony scope-id) (<- governance-svc 'fp-my-ceremony aid-prefix scope-id))

   ((fp-grant scope-id candidate-aid)
    (<- governance-svc 'fp-grant aid-prefix scope-id candidate-aid))

   ((fp-open-ceremony scope-id candidate-aid k)
    (<- governance-svc 'fp-open-ceremony aid-prefix scope-id candidate-aid k))

   ((my-phc) (<- governance-svc 'fp-my-phc aid-prefix))

   ((present-phc wire) (<- governance-svc 'present-phc aid-prefix wire))

   ;; the bundle: what you carry between gateways — personhood, vouches,
   ;; the blessings and key logs that make them checkable elsewhere

   ((present-bundle wire) (<- governance-svc 'present-bundle aid-prefix wire))

   ;; Two credential surfaces, DON'T confuse them (they have different threat
   ;; models — conflating them is what made the encrypted sync a no-op before):
   ;;
   ;;   sync-credentials / list-credential-backups  — the CLIENT's zero-knowledge
   ;;     backup. The browser seals its full credential view under a bran-derived
   ;;     key before it ever reaches the wire (hoot/repl.scm encrypt-blob), so
   ;;     `data` here is opaque ciphertext this gateway cannot read. This is the
   ;;     restore-of-record on a fresh device — do-keri-fetch-credentials! reads
   ;;     it back and decrypt-blobs it client-side.
   ;;
   ;;   list-credentials (below) — this gateway's OWN operational holdings
   ;;     (acdc-store 'by-holder): the credentials it issued or witnesses and
   ;;     must read in the clear to run governance (personhood gate, delegation
   ;;     tally). Those sit plaintext in acdc-store's #:durable-dir. Encrypting
   ;;     that operational store at rest is a real, separate hardening — but the
   ;;     gateway has to decrypt it on every governance read, and this box has no
   ;;     FDE and boots unattended (nowhere to hold the key that a cold-disk
   ;;     thief couldn't also reach), so it is deliberately deferred, not faked
   ;;     with redundant crypto. The off-box snapshots ARE age-encrypted, so a
   ;;     stolen backup stays sealed; a stolen live disk does not. That residual
   ;;     is the gateway's own issued creds, not the client's aggregate view —
   ;;     the latter is protected by the zero-knowledge blob above.
   ((sync-credentials data)
    (catch #t
      (lambda () (%write-user-data! (credentials-file-for aid-prefix) data) 'ok)
      (lambda (k . a) (list 'error (format #f "credentials: ~a ~a" k a)))))

   ((list-credential-backups)
    (catch #t
      (lambda () (%read-user-data (credentials-file-for aid-prefix)))
      (lambda _ '())))

   ;; Live credential push — browser registers a watcher ref that
   ;; receives on-credential messages when the notification poller
   ;; admits a new credential for this AID. Replaces polling with
   ;; delta-only push after the initial list-credentials pull.
   ((watch-credentials watcher-ref)
    (register-credential-watcher! aid-prefix watcher-ref)
    'ok)

   ((unwatch-credentials watcher-ref)
    (unregister-credential-watcher! aid-prefix watcher-ref)
    'ok)

   ;; Shamir share storage — browser splits the bran and sends shares
   ;; here for safekeeping. Each share is addressed to a contact's AID.
   ;; Recovery: browser collects k shares from contacts and reconstructs.
   ((store-shamir-shares source-aid threshold shares)
    (catch #t
      (lambda ()
        (%write-user-data!
         (%user-file "shamir" aid-prefix)
         `((source . ,source-aid)
           (threshold . ,threshold)
           (shares . ,shares)))
        'ok)
      (lambda (k . a) (list 'error (format #f "shamir: ~a ~a" k a)))))

   ((get-shamir-shares)
    (catch #t
      (lambda () (%read-user-data (%user-file "shamir" aid-prefix)))
      (lambda _ '())))

   ;; ── devices: the keys the root lets sign as this AID ───────────────
   ((tier) tier)

   ;; WIRE-JSON is the device-authorization credential the browser built
   ;; (compute-said over the claims) and signed with the KEL key — this
   ;; session's own, so only a root session may present one. Verified
   ;; against the current key, then recorded; from here the device
   ;; authenticates and signs on its own.
   ((enroll-device wire-json)
    (root-only "authorizing a device"
      (lambda ()
        (let* ((cred (and (string? wire-json) (device-wire->cred wire-json)))
               (root-key (or (and oobi-host ($ oobi-host 'current-key aid-prefix))
                             aid-prefix)))
          (cond
           ((not cred) (list 'error "malformed device authorization"))
           (else
            (let ((v (device-credential-verdict cred aid-prefix root-key)))
              (if (eq? v #t)
                  (begin (device-enroll! aid-prefix cred (instant->unix (clock-now)))
                         (format (current-error-port)
                                 "[lobby-session] device enrolled for ~a\n" (aid-tag aid-prefix))
                         'ok)
                  (list 'error v)))))))))

   ((my-devices)
    (map device-entry->wire-alist (devices-of aid-prefix)))

   ;; Any session of the person retires a device — a lost phone is revoked
   ;; from the laptop, and a device signs itself out. The registry is the
   ;; authority the signer-keys resolver reads on every verification.
   ((revoke-device said)
    (if (and (string? said) (device-revoke! aid-prefix said (instant->unix (clock-now))))
        'ok
        (list 'error "no such device")))

   ;; ── forget ───────────────────────────────────────────────────────────
   ;; Erasure, as identity/forget.scm states it: every store of this
   ;; gateway's own keyed by this AID goes, the AID→person link last; the
   ;; key log stays, data about a pseudonym nobody here can resolve. Root
   ;; only — a device key able to erase its person would make a stolen
   ;; phone an erasure. The reply is the receipt. From the act's first turn
   ;; every session of this AID — this one, a phone's — refuses at the gate
   ;; its dispatch passes through (forgotten-gated, below the methods).
   ((forget-me)
    (root-only "forgetting you"
      (lambda ()
        (format (current-error-port) "[lobby-session] forgetting ~a\n" (aid-tag aid-prefix))
        (forget-member!
         aid-prefix
         #:signup-agent signup-agent #:registry recipient-registry
         #:push-store push-store #:presence presence
         #:presence-names (let ((n (announced-name))) (if n (list n) '()))
         #:desk contact-desk
         #:mailbox-mgr mailbox-mgr #:pins pins #:folksonomy folksonomy
         #:mesh-mailbox mesh-mailbox
         #:mesh-dests (let ((pub (anchored-mesh-pub)))
                        (if pub (map cdr (anchored-destinations pub)) '()))
         #:cards-dir (cards-dir)
         #:mail-forget (lambda (addresses)
                         (mail-spool-forget! (getenv "PLAYNET_MAIL_DIR") addresses))))))

   ;; Rotation — bound to this session's AID. Caller can't rotate
   ;; someone else through this cap. Root-only: a device key cannot
   ;; author a rotation (it is not in the bran's chain).
   ((rotate-aid rot-alist-raw sigs)
    (root-only "rotating the identity" (lambda ()
    (catch #t
      (lambda ()
        (let ((rot-alist (normalize-vecs rot-alist-raw))
              (entry (and oobi-host ($ oobi-host 'get aid-prefix))))
          (cond
           ((not oobi-host)
            (list 'error "no oobi-host configured"))
           ((not entry)
            (list 'error (string-append "AID not registered: " aid-prefix)))
           (else
            (let ((verdict (verify-rotation-event
                            aid-prefix entry rot-alist sigs)))
              (cond
               ((eq? verdict #t)
                ($ oobi-host 'append-rotation! aid-prefix rot-alist sigs)
                (format (current-error-port)
                        "[lobby-session] rotation accepted for ~a (sn=~a)\n"
                        (aid-tag aid-prefix) (assoc-ref rot-alist "s"))
                'ok)
               (else (list 'error verdict))))))))
      (lambda (key . args)
        (list 'error (format #f "rotation error: ~a ~a" key args)))))))

   ;; Credentials issued to THIS AID. The filter is intrinsic — the
   ;; caller can't ask for a different AID's credentials through this
   ;; cap.
   ((list-credentials)
    (if acdc-store
        (<- acdc-store 'by-holder aid-prefix)
        '()))

   ;; Issue an ACDC. The full credential alist is constructed + signed by
   ;; the browser (browser has the signing keypair). What doors/lobby.scm can
   ;; check WITHOUT a round trip it checks here — the credential's own
   ;; `issuer` field must match this session's AID, so a caller can never
   ;; attribute issuance to someone else. Governor standing and the actual
   ;; store write are governance-svc's own capabilities (`governor?`,
   ;; `acdc-store`, both already closed over there), so the rest of the
   ;; act crosses to it in one call — the same division present-phc and
   ;; every socialize-* door already use. Replies the credential's SAID.
   ((issue-credential cred-alist-raw)
    (let* ((cred (normalize-vecs cred-alist-raw))
           (issuer (assq-ref cred 'issuer)))
      (if (not (equal? issuer aid-prefix))
          (list 'error
                (string-append "credential.issuer must match the caller's own AID: got "
                                (if (string? issuer) issuer "<not-a-string>")))
          (<- governance-svc 'issue-credential aid-prefix cred))))

   ;; Revoke an ACDC by SAID. No issuer check here — governance may revoke
   ;; ANY credential by policy, so the only gate is the caller's own
   ;; governor standing, checked (with the actual write) in governance-svc.
   ((revoke-credential said)
    (<- governance-svc 'revoke-credential aid-prefix said))

   ;; NOTE: open-terminal and get-mailbox stay on the public ^lobby
   ;; for now — they're consumed by the legacy inner-mode flow that
   ;; uses an org pubkey, not the KERI AID. When the terminal/mailbox
   ;; UX migrates onto the KERI identity, expose them here too.

   ;; Upserts this AID's profile tags from a JSON array, keeping other classifications; replies the tags.
   ((set-profile scope-id json)
    (planner! 'set-profile scope-id aid-prefix json))
)))
