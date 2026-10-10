;;; module/playnet/doors/personhood.scm — the personhood doors of the governance service: recognition, vouching, the ceremony, the bundle a person carries between gateways
;;;
;;; A fragment of the governance service (playnet doors governance): a procedure
;;; from the actor's context to the doors it serves, composed into the service by
;;; (playnet boot governance). `with-governance-ctx` binds the actor's arguments,
;;; cells and shared helpers under their own names, so each clause reads as it did
;;; inside the actor (docs/planning/codebase-layout.md §5).

(define-module (playnet doors personhood)
  #:use-module (srfi srfi-1)
  #:use-module (playnet economy socialization)
  #:use-module (playnet keri first-person predicates)
  #:use-module ((playnet social relationship-kinds) #:select (normalize-rel))
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module ((playnet keri citizen-sig) #:select (aid-signer-keys-resolver verify-said-multisig))
  #:use-module ((playnet utils clock) #:select (instant->civil (now . clock-now)))
  #:use-module (playnet keys exchange)
  #:use-module ((playnet keri signify-portable) #:select (scm->json-canonical json-read-ordered))
  #:use-module ((playnet personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (playnet keri first-person personhood-policy)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (governance-personhood-doors))

(define (governance-personhood-doors ctx)
  (with-governance-ctx ctx
    ;; scope-for says WHICH commune's key an act uses; WHO may ask it to
    ;; commit that commune's money or custody is ^scope's own mint-gov-cap
    ;; concern now (governance/scope.scm's may-govern?) — self-governed the
    ;; way ^wallet-policy governs Monero spend from inside the wallet, not
    ;; re-checked here. This service just propagates whatever mint-gov-cap
    ;; decides.
    ;; the ECOSYSTEM an act lands in: the real AID of the commune the id
    ;; resolves to — and when nothing resolves (a dial still carrying a
    ;; placeholder scope label), the home commune's own AID, so a
    ;; personhood is never issued into a name no key signs and no
    ;; blessing chains to
    (define (ecosystem-for scope-id)
      (let ((sc (scope-for scope-id)))
        (cond (sc ($ sc 'scope-aid))
              (home-scope ($ home-scope 'scope-aid))
              (else scope-id))))
    (define (scope-signer commune-aid)      ; (cred → signed cred), or #f when unsigned
      (let ((sc (scope-for commune-aid)))
        (and sc ($ sc 'has-keypair?)
             (lambda (c) (cred-with-signature c ($ sc 'sign-said (cred-said c)))))))
    ;; ── a vouch: the person's own word, built once for every leg ─────────
    ;; ISSUED-AT is the caller's own stamp (the bridge fills the clock), so
    ;; the preimage and the signed rebuild agree bit-for-bit and a re-vouch
    ;; after a revoke is a fresh SAID rather than the revoked one.
    (define (build-vrc identity-key subject-aid rel issued-at)
      (let ((caller-phc (any-live-phc-for acdc-store identity-key)))
        (when (equal? identity-key subject-aid) (error "cannot vouch for yourself"))
        (unless caller-phc (error "you must be a recognised person to vouch"))
        (make-relationship-credential
         identity-key subject-aid
         (string->symbol (normalize-rel rel))
         (cred-said caller-phc) issued-at)))
    ;; build-vrc's own refusals are worded; anything else reads "vouch failed"
    (define (vouch-refusal args)
      (if (and (pair? args) (string? (car args))) (car args) "vouch failed"))
    ;; ── being recognised — the ceremony as the one door ─────────────────
    ;; The ecosystem's policy is read off the commune's own scope-root
    ;; (first-person/personhood-policy.scm); absent a reachable scope, the defaults.
    (define (policy-store scope-id)
      (let ((sc (scope-for scope-id)))
        (and sc (false-if-exception ($ ($ sc 'scope-root) 'plan-store)))))
    (define (policy scope-id key) (personhood-policy (policy-store scope-id) key))
    ;; how many people could witness here: every live personhood the
    ;; store holds (portable, like fp-status reads it)
    (define (verified-count)
      (if acdc-store
          (length (delete-duplicates
                   (map cred-holder
                        (filter phc-live? ($ acdc-store 'by-schema *schema-playnet-personhood*)))))
          0))
    ;; open (or find) the candidate's ceremony with the ecosystem's word on
    ;; k, cap and window; SPONSOR is the introducing person or #f
    (define (open-enrollment! scope-id candidate-aid sponsor)
      (spawn-enrollment-ceremony
       scope-id candidate-aid
       (if sponsor (string-append "recognition:" sponsor) *self-request-evidence*)
       sponsor
       (effective-k (policy scope-id 'enrollment-k) (verified-count))
       acdc-store
       #:sign-cred (scope-signer scope-id)
       #:root-aid fp-root-aid
       #:witness-cap (policy scope-id 'witness-cap)
       #:witness-window (policy scope-id 'witness-window)))
    (define (expire-stale! scope-id)
      (catch #t
        (lambda () (expire-stale-enrollments! (policy scope-id 'ceremony-ttl)))
        (lambda _ '())))
    ;; who already vouches for AID by relationship credential AND is
    ;; recognised — the people an ask reaches first
    (define (vouchers-of aid)
      (if (not acdc-store) '()
          (delete-duplicates
           (filter-map (lambda (c)
                         (and (equal? aid (cred-holder c))
                              (holds-any-live-phc? acdc-store (cred-issuer c))
                              (cred-issuer c)))
                       (%live-by-schema acdc-store *schema-playnet-relationship* #f)))))
    (define (revoke-prior-vouches! identity-key subject-aid)
      (revoke-where! (%live-by-schema acdc-store *schema-playnet-relationship* #f)
                     (lambda (c) (and (equal? identity-key (cred-issuer c))
                                      (equal? subject-aid (cred-holder c))))))
    ;; ── credentials carried from elsewhere: the bundle ──────────────────
    ;; A BUNDLE is what a person carries between gateways: cards (the
    ;; wire shape of fp-my-phc — governance-cred->wire + the issuer's
    ;; signature) for a personhood, the relationship credentials that
    ;; vouch for them or that they spoke, the personhood of each voucher
    ;; and the root's blessing of its ecosystem; and, for every voucher
    ;; whose AID is a browser-born E-prefix, that voucher's KEY LOG — the
    ;; one thing a foreign gateway cannot derive, without which the
    ;; voucher's signature cannot be checked. present-bundle verifies in
    ;; dependency order and imports only what stands; every consumer of
    ;; a vouch reads the store, so an imported vouch counts here exactly
    ;; as it did where it was spoken.
    (define (trusted-ecosystem? eco pending-aics)
      (or (and fp-root-aid (ecosystem-chains-to-any-root? acdc-store fp-root-aid eco))
          (and (not fp-strict-root?) (member eco fp-trusted-issuers) #t)
          (and (pair? pending-aics)
               (any (lambda (a) (equal? eco (cred-holder a))) pending-aics))))
    (define (card->cred card) (fp-wire->cred card))
    (define (kel-wire->parts kel)
      ;; the dial's own KEL shape → (values icp sigs rotations-vector)
      (let ((rots (assoc-ref kel "rotations")))
        (values (assoc-ref kel "icp")
                (assoc-ref kel "sigs")
                (list->vector
                 (map (lambda (r) (cons (assoc-ref r "rot") (assoc-ref r "sigs")))
                      (if (vector? rots) (vector->list rots) '()))))))
    (define (land-kels! kels)
      ;; every carried key log lands first — a log that fails verification
      ;; fails the bundle. Returns #t or an error string.
      (let loop ((ks kels))
        (cond
         ((null? ks) #t)
         ((not kel-landing) "this gateway cannot land a carried key log")
         (else
          (let ((aid (car (car ks))) (kel (cdr (car ks))))
            (call-with-values (lambda () (kel-wire->parts kel))
              (lambda (icp sigs rots)
                (let ((v (catch #t (lambda () (kel-landing aid icp sigs rots))
                           (lambda (k . a) "key log could not be landed"))))
                  (if (eq? v #t) (loop (cdr ks))
                      (string-append "key log for " aid ": " (if (string? v) v "refused")))))))))))
    (define (present-bundle! identity-key parsed)
      (let* ((bare? (assoc "d" parsed))               ; one card, the older wire
             (cards (if bare? (list parsed)
                        (let ((c (assoc-ref parsed "creds")))
                          (cond ((vector? c) (vector->list c)) ((list? c) c) (else '())))))
             (kels  (let ((k (assoc-ref parsed "kels"))) (if (list? k) k '())))
             (creds (map card->cred cards))
             (of    (lambda (schema) (filter (lambda (c) (equal? schema (cred-schema c))) creds)))
             (aics  (of *schema-playnet-authorized-issuer*))
             (phcs  (of *schema-playnet-personhood*))
             (vrcs  (of *schema-playnet-relationship*))
             (bodies (of *schema-playnet-body*))
             (roles  (of *schema-playnet-body-role*))
             (now   (current-time))
             (sound? (lambda (c) (and (cred-said-consistent? c) (cred-signature-valid? c)
                                      (cred-live-at? c now))))
             (landed (land-kels! kels))
             ;; a body's signing keys: the whole `k` of the latest
             ;; establishment event in its key log — the one the bundle
             ;; carries (landed above, so verified), else the one held here
             ;; (kel-of), else what the bound resolver names; a group AID's
             ;; stewards are only read whole from a log
             (->list (lambda (x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '()))))
             (keys-of-kel (lambda (kel)
                            (and (pair? kel)
                                 (let* ((rots (->list (assoc-ref kel "rotations")))
                                        (ev (if (pair? rots)
                                                (assoc-ref (last rots) "rot")
                                                (assoc-ref kel "icp"))))
                                   (and ev (->list (assoc-ref ev "k")))))))
             (resolved-keys (lambda (aid)
                              (let* ((resolve (aid-signer-keys-resolver))
                                     (ks (and resolve (catch #t (lambda () (resolve aid #f))
                                                        (lambda _ '())))))
                                (if (list? ks) ks '()))))
             (body-keys-of (lambda (body-aid)
                             (let ((carried (keys-of-kel (assoc-ref kels body-aid))))
                               (if (pair? carried) carried
                                   (let ((held (and kel-of
                                                    (keys-of-kel (false-if-exception (kel-of body-aid))))))
                                     (if (pair? held) held (resolved-keys body-aid)))))))
             ;; the role's block: K distinct stewards — signers whose key is
             ;; one of the body's — over the SAID; K is the body credential's
             ;; quorum, else the role's own, else one
             (role-block-ok?
              (lambda (role body)
                (let* ((block (cred-signature role))
                       (keys (body-keys-of (cred-issuer role)))
                       (q (or (cred-claim body 'quorum) (cred-claim role 'quorum)))
                       (k (if (and (number? q) (> q 0)) q 1))
                       (steward? (lambda (aid)
                                   (and (string? aid)
                                        (any (lambda (x) (member x keys))
                                             (cons aid (resolved-keys aid))))))
                       (stewards (filter steward? (map (lambda (e) (and (pair? e) (car e)))
                                                       (if (list? block) block '())))))
                  (and (pair? keys) (pair? block)
                       (verify-said-multisig (cred-said role) block stewards k))))))
        (cond
         ((not (eq? landed #t)) (cons 'error landed))
         ((not (= (length creds) (+ (length aics) (length phcs) (length vrcs)
                                    (length bodies) (length roles))))
          (cons 'error "the bundle carries a credential of a kind this gateway does not present"))
         ;; the root's blessings: only a root's own word
         ((not (every (lambda (a) (and (sound? a)
                                       fp-root-aid
                                       (ecosystem-chains-to-any-root? acdc-store fp-root-aid (cred-issuer a))))
                      aics))
          (cons 'error "a carried issuer blessing is not the root's"))
         ;; a body's admission: a scope that chains to a root admitted it —
         ;; the same gate an AIC's ecosystem passes — signed, live, consistent
         ((not (every (lambda (b) (and (sound? b) (trusted-ecosystem? (cred-issuer b) aics))) bodies))
          (cons 'error "a carried body credential was not issued by a scope that chains to a root"))
         (else
          (let* ((anchor-of (lambda (v) (let ((e (cred-edge v 'issuer-phc))) (and e (edge-target e)))))
                 (anchors (filter-map anchor-of vrcs))
                 ;; a personhood is accepted as the CALLER's, or as the anchor
                 ;; of a vouch in this bundle — never as anyone else's
                 ;; the personhood gates, in the order the one-card door has
                 ;; always asked them: whose it is, who issued it, that the
                 ;; digest commits to the content, the signature, liveness
                 (phc-ok (lambda (p)
                           (cond
                            ((not (or (equal? (cred-holder p) identity-key)
                                      (member (cred-said p) anchors)))
                             "presented PHC is not yours")
                            ((not (trusted-ecosystem? (cred-issuer p) aics))
                             "issuer is not a federated commune")
                            ((not (cred-said-consistent? p))
                             "PHC digest does not commit to its contents")
                            ((not (cred-signature-valid? p))
                             "PHC signature does not verify")
                            ((not (cred-live-at? p now))
                             "presented PHC is not live")
                            (else #t))))
                 (phc-verdicts (map phc-ok phcs))
                 (bad-phc (find string? phc-verdicts)))
            (if bad-phc (cons 'error bad-phc)
                (let* ((live-phc (lambda (said)
                                   (or (find (lambda (p) (equal? said (cred-said p))) phcs)
                                       (let ((c ($ acdc-store 'get said)))
                                         (and c (equal? *schema-playnet-personhood* (cred-schema c))
                                              (cred-live-at? c now) c)))))
                       (vrc-ok (lambda (v)
                                 (let ((p (live-phc (anchor-of v))))
                                   (cond
                                    ((not (sound? v)) "a carried vouch does not verify")
                                    ((not (or (equal? (cred-holder v) identity-key)
                                              (equal? (cred-issuer v) identity-key)))
                                     "a carried vouch neither names you nor is yours")
                                    ((not p) "a carried vouch's voucher holds no personhood here")
                                    ((not (equal? (cred-holder p) (cred-issuer v)))
                                     "a carried vouch's personhood belongs to someone else")
                                    (else #t)))))
                       (vrc-verdicts (map vrc-ok vrcs))
                       (bad-vrc (find string? vrc-verdicts))
                       ;; a role's body: the body credential its `body` edge
                       ;; names, in this bundle or already held here, live
                       (body-of (lambda (r)
                                  (let* ((e (cred-edge r 'body)) (said (and e (edge-target e))))
                                    (and said
                                         (or (find (lambda (b) (equal? said (cred-said b))) bodies)
                                             (let ((c ($ acdc-store 'get said)))
                                               (and c (equal? *schema-playnet-body* (cred-schema c))
                                                    (cred-live-at? c now) c)))))))
                       (role-ok (lambda (r)
                                  (let ((e (cred-edge r 'body)) (b (body-of r)))
                                    (cond
                                     ((not (equal? (cred-holder r) identity-key))
                                      "a carried body role is not yours")
                                     ((not (cred-said-consistent? r))
                                      "a carried body role's digest does not commit to its contents")
                                     ((not (cred-live-at? r now)) "a carried body role is not live")
                                     ((not e) "a carried body role names no body credential")
                                     ((not b) "a carried body role's body is not admitted here")
                                     ((not (edge-i2i-holds? e r b))
                                      "a carried body role is not the named body's word")
                                     ((not (role-block-ok? r b))
                                      "a carried body role's stewards do not meet the body's quorum")
                                     (else #t)))))
                       (role-verdicts (map role-ok roles))
                       (bad-role (find string? role-verdicts)))
                  (cond
                   (bad-vrc (cons 'error bad-vrc))
                   (bad-role (cons 'error bad-role))
                   (else
                    (let ((n ($ acdc-store 'import
                                (map (lambda (c) (cons c #f))
                                     (append aics phcs vrcs bodies roles)))))
                      (cons 'ok (if (number? n) n 0))))))))))))
    (define (card c) (append (governance-cred->wire c) (list (cons "sig" (or (cred-signature c) "")))))
    (define (my-bundle identity-key)
      ;; what IDENTITY-KEY carries: their personhood; every live vouch for
      ;; them and every live vouch they spoke; each voucher's personhood
      ;; and its ecosystem's blessing when held; a key log for every
      ;; E-prefix AID a foreign verifier would otherwise be unable to check
      (let* ((mine (any-live-phc-for acdc-store identity-key))
             (vrcs (filter (lambda (c) (or (equal? identity-key (cred-holder c))
                                           (equal? identity-key (cred-issuer c))))
                           (%live-by-schema acdc-store *schema-playnet-relationship* #f)))
             (vouchers (delete-duplicates (map cred-issuer vrcs)))
             (phcs (delete-duplicates
                    (append (if mine (list mine) '())
                            (filter-map (lambda (a) (any-live-phc-for acdc-store a)) vouchers))))
             (ecos (delete-duplicates (map cred-issuer phcs)))
             (aics (filter-map (lambda (eco)
                                 (find (lambda (a) (and (equal? eco (cred-holder a))
                                                        (cred-live-at? a (current-time))))
                                       ($ acdc-store 'by-schema *schema-playnet-authorized-issuer*)))
                               ecos))
             (need-kel (filter (lambda (a) (and (string? a) (string-prefix? "E" a)))
                               (delete-duplicates (cons identity-key vouchers))))
             (kels (if kel-of
                       (filter-map (lambda (a) (let ((k (false-if-exception (kel-of a))))
                                                 (and k (cons a k))))
                                   need-kel)
                       '())))
        `(("creds" . ,(list->vector (map card (append aics phcs vrcs))))
          ("kels" . ,kels))))

    (declared-doors governance

      ;; --- First-Person: personhood (PHC) + relationship (VRC) ---
      ;; identity-key is the session-bound, KERI-authenticated AID — trusted.
      ;; We query our OWN acdc-store directly; personhood is PORTABLE (a live
      ;; PHC from ANY ecosystem counts — refederation-proof). scope-id labels
      ;; the request and is the ecosystem we ISSUE into on grant.
      ((fp-status identity-key scope-id)
       (cons 'ok (list (cons 'person (holds-any-live-phc? acdc-store identity-key))
                       (cons 'scope scope-id)
                       ;; what the dial may offer: a founder's genesis act
                       ;; only while no one is recognised; how many could
                       ;; witness, which is what the quorum clamps to
                       (cons 'governor (and (governor? identity-key) #t))
                       (cons 'bootstrapped (and acdc-store (personhood-bootstrapped? acdc-store) #t))
                       (cons 'verified-count (verified-count)))))

      ;; ── vouching: the person's word, in the person's signature ────────────
      ;; fp-vouch-preimage / fp-vouch-signed are the client-signed pair (the
      ;; twin of socialize-preimage/-signed): the browser re-derives the SAID
      ;; over the returned fields and signs with the resident key; the server
      ;; rebuilds from the same wire args and issues iff the signature is the
      ;; voucher's. The bare fp-vouch remains for a session that cannot sign
      ;; (no resident key): the same credential, issued unsigned — no scope
      ;; speaks in a person's name. All three end the prior vouches first.
      ((fp-vouch-preimage identity-key scope-id subject-aid rel at)
       (%preimage (lambda () (build-vrc identity-key subject-aid rel at)) #:refusal vouch-refusal))

      ((fp-vouch-signed identity-key scope-id subject-aid rel at signature)
       (%signed! (lambda () (build-vrc identity-key subject-aid rel at)) identity-key signature "vouch"
                 #:before (lambda (_) (revoke-prior-vouches! identity-key subject-aid))
                 #:refusal vouch-refusal))

      ((fp-vouch identity-key scope-id subject-aid rel)
       (catch #t
         (lambda ()
           (let ((vrc (build-vrc identity-key subject-aid rel (current-time))))
             (revoke-prior-vouches! identity-key subject-aid)
             ($ acdc-store 'issue vrc)
             (cons 'ok #t)))
         (lambda (k . a) (cons 'error (vouch-refusal a)))))

      ;; a vouch is the voucher's own to end: every standing vouch from the
      ;; caller for SUBJECT-AID is revoked, and none standing is the same ok
      ((fp-withdraw-vouch identity-key scope-id subject-aid)
       (if (not acdc-store)
           (cons 'error "no credential store on this gateway")
           (begin (revoke-prior-vouches! identity-key subject-aid)
                  (cons 'ok #t))))

      ;; ── what stands between the caller and each of AIDS ───────────────────
      ;; The reading a contact row shows, for the people in the caller's own
      ;; book (the session reads the book and hands the AIDs). Each row is
      ;; of the pair: is this person recognised, the kind the caller's
      ;; standing vouch for them states, the kind theirs for the caller
      ;; states, and their open ask in SCOPE-ID with whether the caller has
      ;; signed it. Who else vouches for them is theirs to carry.
      ((relationships identity-key scope-id aids)
       (let* ((scope-id (ecosystem-for scope-id))
              (kind (lambda (issuer subject)
                      (let ((c (and acdc-store (vrc-from-to acdc-store issuer subject))))
                        (and c (normalize-rel (cred-claim c 'relationship-type))))))
              (ask-of (lambda (aid)
                        (let ((c (enroll-ceremony-for-candidate scope-id aid)))
                          (and c `((said . ,($ c 'statement-said))
                                   (count . ,($ c 'attestation-count))
                                   (quorum . ,($ c 'threshold))
                                   (signed . ,(and (member identity-key ($ c 'attesting-witnesses)) #t))))))))
         (expire-stale! scope-id)
         (cons 'ok
               (map (lambda (aid)
                      `((aid . ,aid)
                        (recognised . ,(and acdc-store (holds-any-live-phc? acdc-store aid) #t))
                        (mine . ,(kind identity-key aid))
                        (theirs . ,(kind aid identity-key))
                        (ask . ,(ask-of aid))))
                    (delete identity-key (delete-duplicates (filter string? aids)))))))

      ;; ── being recognised: the request IS the ceremony ─────────────────────
      ;; A candidate asks for themself: the ask is an enrollment ceremony
      ;; opened with no sponsor, the ecosystem's quorum (personhood-policy,
      ;; clamped to the verified population), durable on disk and on every
      ;; witness rail. Asking again finds the standing ask. What the
      ;; candidate reads back is the ceremony itself — fp-my-ceremony.
      ((fp-request-enroll identity-key scope-id)
       (let ((scope-id (ecosystem-for scope-id)))
       (cond
        ((not acdc-store) (cons 'error "no credential store on this gateway"))
        ((holds-any-live-phc? acdc-store identity-key)
         (cons 'error "you are already recognised"))
        (else
         (catch #t
           (lambda ()
             (open-enrollment! scope-id identity-key #f)
             (cons 'ok #t))
           (lambda (key . args)
             (format (current-error-port)
                     "[governance-svc] fp-request-enroll failed: ~a ~a~%" key args)
             (cons 'error "could not open the ask")))))))

      ;; the standing asks in SCOPE-ID, with each one's progress — what the
      ;; witness rail and the sheet's queue show
      ((fp-pending identity-key scope-id)
       (let ((scope-id (ecosystem-for scope-id)))
       (expire-stale! scope-id)
       (cons 'ok (map (lambda (row)
                        (cons (cons 'vouchers (vouchers-of (assq-ref row 'candidate))) row))
                      (enroll-asks scope-id)))))

      ;; the caller's own ask: none, collecting (n of k, who already vouches
      ;; for them by relationship credential), or finalized
      ((fp-my-ceremony identity-key scope-id)
       (let* ((scope-id (ecosystem-for scope-id)))
       (expire-stale! scope-id)
       (let ((c (enroll-ceremony-for-candidate scope-id identity-key)))
         (cons 'ok
               (cond
                ((holds-any-live-phc? acdc-store identity-key)
                 `((state . finalized)))
                (c `((state . collecting)
                     (count . ,($ c 'attestation-count))
                     (quorum . ,($ c 'threshold))
                     (witnesses . ,($ c 'attesting-witnesses))
                     (vouchers . ,(vouchers-of identity-key))))
                (else `((state . none))))))))

      ((fp-grant identity-key scope-id* candidate-aid)
       ;; GENESIS only: the operator's founding act, for an ecosystem with
       ;; no verified person yet (the founders.txt seed is the same act at
       ;; boot). Once anyone is recognised, every later person comes in
       ;; through witnesses — fp-request-enroll / fp-open-ceremony.
       (let ((scope-id (ecosystem-for scope-id*)))
       (cond
        ((not (governor? identity-key))
         (cons 'error "only governance can grant personhood"))
        ((ecosystem-personhood-bootstrapped? acdc-store scope-id)
         (cons 'error "personhood is bootstrapped — recognition comes through witnesses now"))
        ((not (%sponsor-fanout-ok? acdc-store scope-id identity-key))
         (cons 'error "sponsor fan-out cap reached — too many recent grants"))
        (else
         (catch #t
           (lambda ()
             ;; Signed by the ECOSYSTEM the personhood is issued into —
             ;; scope-id's own scope, through scope-signer — the way
             ;; scope.scm's issue-phc/invite sign (sign-said, keypair inside
             ;; the scope actor). Unsigned when this process holds no key
             ;; for that commune.
             (let* ((phc (make-personhood-credential
                          scope-id candidate-aid (current-time)
                          #:sponsor-aid identity-key))
                    (sign (scope-signer scope-id))
                    (signed (if sign (sign phc) phc)))
               ($ acdc-store 'issue signed))
             (cons 'ok #t))
           (lambda (k . a)
             (format (current-error-port) "[governance-svc] fp-grant: ~a ~a~%" k a)
             (cons 'error "grant failed")))))))

      ((fp-open-ceremony identity-key scope-id* candidate-aid . _k)
       ;; A verified person INTRODUCES a newcomer: the same ceremony the
       ;; candidate could open for themself, with the introducer recorded as
       ;; sponsor (fan-out capped). The ecosystem's quorum applies; a
       ;; trailing k from an older bundle is ignored. The ask lands on
       ;; every witness rail and each vouch is the witness's OWN signature
       ;; over the statement-SAID; at quorum the PHC issues carrying one
       ;; NI2I edge per witness.
       (let ((scope-id (ecosystem-for scope-id*)))
       (cond
        ((not acdc-store)
         (cons 'error "no credential store on this gateway"))
        ((not (holds-any-live-phc? acdc-store identity-key))
         (cons 'error "only a recognised person can introduce someone"))
        ((not (%sponsor-fanout-ok? acdc-store scope-id identity-key))
         (cons 'error "sponsor fan-out cap reached — too many recent introductions"))
        (else
         (catch #t
           (lambda ()
             (open-enrollment! scope-id candidate-aid identity-key)
             (cons 'ok #t))
           (lambda (key . args)
             (format (current-error-port)
                     "[governance-svc] fp-open-ceremony failed: ~a ~a~%"
                     key args)
             (cons 'error "ceremony open failed")))))))

      ((set-home-scope! s) (set! home-scope s) 'ok)

      ;; after boot, once the scopes and the root are wired: every open ask
      ;; comes back from its record with its vouches — the gateway calls
      ;; this where it installs the witness door
      ((fp-rehydrate!)
       (if (not acdc-store) (cons 'ok '())
           (cons 'ok (rehydrate-enrollment-ceremonies!
                      acdc-store
                      #:sign-cred-of scope-signer
                      #:root-aid fp-root-aid))))

      ;; the caller's own live PHC as a portable card (said+issuer+sig is the
      ;; verifiable core; a foreign gateway can re-SAID the claims and check
      ;; the sig). #f when the caller holds none. Slice-1 of PHC presentation.
      ((fp-my-phc identity-key)
       ;; the holder's PHC as a portable, presentable wire (governance-cred->wire
       ;; SAD shape + the issuer's signature) — the dial carries this and can
       ;; present it to other gateways. #f when the caller holds none.
       (let ((c (any-live-phc-for acdc-store identity-key)))
         (cons 'ok
               (and c (append (governance-cred->wire c)
                              (list (cons "sig" (or (cred-signature c) ""))))))))

      ((set-fp-trusted-issuers! lst)
       (set! fp-trusted-issuers (if (list? lst) lst '())) 'ok)

      ;; Set the trust-registry root. AID is a single root AID, or a LIST of
      ;; recognized roots (multi-root cross-recognition — persons chaining to
      ;; ANY recognized root are honoured, so two independently-booted graphs
      ;; legibilise each other without merging). #f disables root-chain trust.
      ((set-fp-root! aid)
       (set! fp-root-aid (cond ((string? aid) aid) ((pair? aid) aid) (else #f)))
       'ok)

      ;; Drop/keep the whitelist fallback. Flip on once the root chain is live.
      ((set-fp-strict-root! flag)
       (set! fp-strict-root? (and flag #t)) 'ok)

      ;; A PHC carried from ANOTHER gateway/commune, presented for recognition.
      ;; Honour iff: holder == the authenticated caller, the issuer's signature
      ;; verifies (verify-said-signature resolves the issuer's key state), and
      ;; the issuer is a TRUSTED federated commune. Then import into our store so
      ;; the any-ecosystem fold recognises this person locally.
      ;; A PHC carried from ANOTHER gateway/commune, presented for recognition:
      ;; the one-card bundle. Honour iff: holder == the authenticated caller,
      ;; the issuer's signature verifies, and the issuer is a TRUSTED
      ;; federated commune. present-bundle below is the whole rule.
      ((present-phc identity-key wire-json)
       (catch #t
         (lambda ()
           (let ((parsed (json-read-ordered wire-json)))
             (if (not (equal? (assoc-ref parsed "s") *schema-playnet-personhood*))
                 (cons 'error "not a personhood credential")
                 (let ((r (present-bundle! identity-key parsed)))
                   (if (eq? 'ok (car r)) (cons 'ok #t) r)))))
         (lambda (k . a) (cons 'error "present-phc failed"))))

      ;; A BUNDLE carried from elsewhere — personhoods, vouches, the
      ;; blessings and key logs that make them checkable here. Verified in
      ;; dependency order, imported only when every card stands; a
      ;; re-presentation is a no-op. Answers (ok . newly-imported).
      ((present-bundle identity-key wire-json)
       (catch #t
         (lambda () (present-bundle! identity-key (json-read-ordered wire-json)))
         (lambda (k . a)
           (format (current-error-port) "[governance-svc] present-bundle: ~a ~a~%" k a)
           (cons 'error "present-bundle failed"))))

      ;; what the caller carries to the next gateway, as one JSON string —
      ;; my-bundle above. "" when there is nothing to carry.
      ((fp-my-vouches identity-key)
       (catch #t
         (lambda ()
           (let ((b (my-bundle identity-key)))
             (cons 'ok (if (zero? (vector-length (assoc-ref b "creds"))) ""
                           (scm->json-canonical b)))))
         (lambda (k . a) (cons 'error "fp-my-vouches failed")))))))
