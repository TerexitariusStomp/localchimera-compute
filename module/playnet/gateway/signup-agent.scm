;;; module/playnet/gateway/signup-agent.scm — ^signup-agent Goblins actor
;;;
;;; Handles account registration using KERI AIDs instead of SSH public keys.
;;; Users provide their AID prefix + an OOBI URL; the server resolves the OOBI
;;; via KERIA (which verifies the AID against witnesses), then persists the
;;; AID↔username mapping.
;;;
;;; If the user's KERIA instance (or our server) goes offline, the user's
;;; identity survives in the witness pool — they can reconnect to any new
;;; server instance by presenting the same AID.
;;;
;;; Usage (from gateway.scm):
;;;
;;;   (use-modules (playnet gateway signup-agent))
;;;   (define *signup-vat*   (spawn-vat #:name "signup"))
;;;   (define *signup-agent* (with-vat *signup-vat* (spawn ^signup-agent (hashmap) (hashmap))))
;;;
;;; Messages:
;;;
;;;   ($ *signup-agent* 'register! username email aid-prefix oobi-url)
;;;     → 'ok  |  (list 'error "reason string")
;;;
;;;   ($ *signup-agent* 'members)
;;;     → list of (username email registered-at) triples
;;;
;;;   ($ *signup-agent* 'member? username)
;;;     → #t | #f
;;;
;;;   ($ *signup-agent* 'lookup-aid aid-prefix)
;;;     → username or #f

(define-module (playnet gateway signup-agent)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins abstract-types)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet keri bridge)
  #:use-module (playnet keri signify-portable)
  #:use-module ((playnet keri citizen-sig)
                #:select (verify-bytes-under-aid))
  #:use-module ((playnet keri key-state) #:select (check-rotation check-icp verify-sig-on-event))
  #:use-module ((playnet gateway oobi-host)
                #:select (oobi-entry-last-event))
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils store-utils) #:select (hashmap-count))
  #:export (^signup-agent signup-agent-env
            verify-self-signed-icp
            verify-rotation-event
            verify-rotation-run
            verify-carried-kel
            normalize-vecs
            aid-tag))

;;; ── Log hygiene ─────────────────────────────────────────────────────────────
;;;
;;; Registration logs used to carry the username and the full AID, which
;;; put an unretained stream of identifying data into stderr (and from
;;; there into whatever collects it). Operationally we only ever need
;;; enough to correlate one log line with another, so log a short AID
;;; prefix and nothing else — never the handle, never the email.
;;; See docs/planning/legal/gdpr-analysis.md §3.5.

(define (aid-tag aid)
  "A short, non-identifying handle for logs: the first 8 chars of the
   AID. Enough to correlate lines during an incident, useless as a
   standalone identifier."
  (if (and (string? aid) (>= (string-length aid) 8))
      (string-append (substring aid 0 8) "…")
      "?"))

;;; ── Validation ──────────────────────────────────────────────────────────────

(define (valid-username? s)
  (and (string? s)
       (not (string-null? s))
       (string-match "^[a-z][a-z0-9-]{0,30}$" s)
       #t))

(define (valid-email? s)
  (and (string? s)
       (string-match "^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$" s)
       #t))

(define (valid-aid? s)
  ;; AID prefix: CESR qb64, typically starts with 'B', 'D', or 'E'
  ;; and is 44 chars for an ed25519 key. Anchor at both ends so trailing
  ;; whitespace/garbage doesn't sneak through.
  (and (string? s)
       (>= (string-length s) 44)
       (string-match "^[A-Za-z0-9_-]{44,}$" s)
       #t))

(define (valid-oobi? s)
  ;; Basic URL check; full validation happens via KERIA
  (and (string? s)
       (or (string-prefix? "http://" s)
           (string-prefix? "https://" s))
       (string-contains s "/oobi/")
       #t))

;;; ── Local ICP validation (browser-resident-Signify path) ───────────────────
;;;
;;; The browser creates an AID locally and ships {aid, icp, sigs} to
;;; signup. We verify, without KERIA, that:
;;;
;;;   1. icp.k[0] equals the AID prefix          (the AID IS the pubkey)
;;;   2. recompute SAID over the icp serialized exactly as the browser
;;;      did → must equal icp.d / icp.i           (self-addressing intact)
;;;   3. sigs[0] verifies under that pubkey       (controller signed it)
;;;
;;; This is sufficient for non-witnessed (toad=0) D-prefix AIDs, the
;;; flow Phase B targets. After the verification passes, the entry can
;;; be persisted in ^oobi-host and the user is registered. KERIA
;;; integration (witness receipts, KEL streaming) is a follow-up.

;; event-first-key + event-sn live in (playnet keri signify-portable)
;; (general event accessors); imported via the `(playnet keri ...)` line
;; above and re-used by validators below.

;; The signature check on an event, and the rotation check, are shared with every
;; other verifier of a key event log (playnet keri key-state).

(define (verify-oobi-reply key-qb64 frame)
  "Validate one framed OKEA endpoint reply: the frame must parse as
   exactly one rpy message routed /end/role/add or /loc/scheme, and its
   endorsement signature must verify under KEY-QB64 — the AID's CURRENT
   signing key (post-rotation the prefix no longer encodes it) — over the
   RAW rpy JSON (raw, because guile-json's parser reverses field order;
   a reserialize would change the signed bytes). Returns #t or an error
   string. Resolvers BADA-verify again downstream; this gate just keeps
   junk out of the served OOBI body."
  (catch #t
    (lambda ()
      (let ((frames (cesr-stream-parse frame)))
        (if (not (= 1 (length frames)))
            "reply frame must contain exactly one message"
            (let* ((rpy-json (caar frames))
                   (sigs     (cdar frames))
                   (rpy      (json-string->scm rpy-json))
                   (t        (assoc-ref rpy "t"))
                   (r        (assoc-ref rpy "r")))
              (cond
               ((not (equal? t "rpy"))
                "frame is not a reply (rpy)")
               ((not (member r '("/end/role/add" "/loc/scheme")))
                (string-append "unexpected reply route: " (if (string? r) r "?")))
               ((zero? (vector-length sigs))
                "reply carries no endorsement signature")
               ((verify-bytes-under-aid (string->utf8 rpy-json)
                                        (vector-ref sigs 0)
                                        key-qb64) #t)
               (else "reply signature does not verify under the AID's current key"))))))
    (lambda (key . args)
      (format #f "unparseable reply frame: ~a ~a" key args))))

;; Browser → server JSON values arrive with syrup taggings: vectors as
;; (tagged 'vec elems) and dotted pairs — e.g. the anchor alist entries
;; inside an icp's "a" seal — as (tagged 'pair (head tail)). Walk the
;; value tree and convert both back to native Scheme so that downstream
;; consumers (event-first-key, scm->json-canonical) work uniformly with
;; both locally-built and wire-decoded events.
(define (normalize-vecs x)
  (cond
   ((and (tagged? x) (eq? 'vec (tagged-label x)))
    (list->vector (map normalize-vecs (tagged-data x))))
   ((and (tagged? x) (eq? 'pair (tagged-label x)))
    (let ((d (tagged-data x)))
      (cons (normalize-vecs (car d)) (normalize-vecs (cadr d)))))
   ((vector? x)
    (list->vector (map normalize-vecs (vector->list x))))
   ((pair? x)
    (cons (normalize-vecs (car x)) (normalize-vecs (cdr x))))
   (else x)))

(define (verify-self-signed-icp aid-prefix icp-alist-raw sigs)
  "Locally validate an inception event signed by the controller.
   Returns #t on success or a string describing the first failure.
   ICP-ALIST is the parsed JSON alist (fields v t d i s kt k nt n bt b c a).
   SIGS is a vector of CESR-encoded indexed signatures."
  (let ((icp-alist (normalize-vecs icp-alist-raw)))
  (cond
   ((not (pair? icp-alist))         "icp must be an alist")
   ((not (vector? sigs))            "sigs must be a vector")
   ((zero? (vector-length sigs))    "sigs must contain at least one signature")
   (else
    (let ((d-field (assoc-ref icp-alist "d"))
          (i-field (assoc-ref icp-alist "i")))
      (cond
       ((not (and (string? d-field) (string? i-field)))
        "icp.d and icp.i must be strings")
       ;; The registration handle IS the AID: the icp's saidified `i`,
       ;; the identifier resolvers key their KEL/location dbs by. (The
       ;; inception key k0 is readable from the icp; it is never the
       ;; handle — it goes stale on the first rotation.)
       ((not (string=? i-field aid-prefix))
        (string-append "aid-prefix does not match icp.i: " i-field))
       ((not (string=? d-field i-field))
        "icp.d must equal icp.i (self-addressing)")
       ;; the inception itself — its key, its SAID, its signature — is the key
       ;; log reader's to check (keri/key-state.scm), as for every verifier
       (else (check-icp aid-prefix icp-alist sigs))))))))

;; Entry-shape accessors live in (playnet gateway oobi-host) — the actor owns
;; the entry shape, so its readers do too. Local validators just consume.
(define last-event oobi-entry-last-event)

(define (last-event-said entry)
  (assoc-ref (last-event entry) "d"))

(define (last-event-next-digest entry)
  "The 'n' field of the last event names the digest of the key whose
   public form must appear in the *next* rotation's `k`."
  (event-first-next-digest (last-event entry)))

(define (last-event-sn entry)
  ;; Delegates to event-sn (which returns -1 on parse failure); if
  ;; the entry has no last event the resulting expected-sn = 0 will
  ;; correctly fail the rot.s = prior.s + 1 invariant since real rot
  ;; events have sn ≥ 1.
  (event-sn (last-event entry)))

(define (verify-rotation-event aid-prefix entry rot-alist sigs)
  "Locally verify a rotation event posts after ENTRY's prior state: #t or an
   error string, by the one rotation check every verifier of a key log shares
   (`check-rotation`, keri/key-state.scm)."
  (check-rotation aid-prefix
                  `((sn . ,(last-event-sn entry)) (said . ,(last-event-said entry))
                    (next . ,(last-event-next-digest entry)))
                  rot-alist sigs))

;;; ── OOBI verification via KERIA ─────────────────────────────────────────────

(define (verify-oobi! aid-prefix oobi-url)
  "Resolve OOBI via KERIA. Returns #t on success, error string on failure.
   KERIA verifies the AID against witnesses — if this passes, the AID is real."
  (catch #t
    (lambda ()
      (let* ((op (keri-resolve-oobi oobi-url #:alias aid-prefix))
             (done (keri-wait-operation op #:timeout 30)))
        (if (assoc-ref done "done") #t
            "OOBI resolution timed out")))
    (lambda (key . args)
      (format #f "OOBI resolution failed: ~a ~a" key args))))

;;; ── Record helpers ──────────────────────────────────────────────────────────
;;;
;;; Member record: (username email aid-prefix registered-at)
;;; AID is the durable identity — survives server restarts via witness pool.

(define* (make-member username email aid registered-at #:optional (display-name ""))
  (list username email aid registered-at display-name))

(define (member-username      m) (list-ref m 0))
(define (member-email         m) (list-ref m 1))
(define (member-aid           m) (list-ref m 2))
(define (member-registered-at m) (list-ref m 3))
;; the mutable label set later in settings; pre-profile (4-field) records
;; have no display-name — fall back to the handle at the read site.
(define (member-display-name  m) (if (> (length m) 4) (list-ref m 4) ""))

;;; ── ^signup-agent ───────────────────────────────────────────────────────────

;;; ── witnessing: a KEL, on its own terms ─────────────────────────────────────
;;;
;;; Two acts that used to be one. WITNESSING a KEL is accepting a verifiable
;;; log into ^oobi-host — any log, from anyone who forwards it, with no
;;; username and no seat: a rotation proves its own authorship, and the KEL
;;; is public data whose home is wherever it is served (KERI: "ambient
;;; infrastructure"). JOINING is taking a seat in this gateway's universal
;;; commune — the member row the session cap hangs off — and presupposes the
;;; AID is witnessed here. Every gateway is thereby a witness-of-record for
;;; every AID it has seen, whether or not the AID ever sat down.

(define (rotation-list x)
  "ROTATIONS off the wire as a list of (rot . sigs), or #f."
  (let ((r (normalize-vecs x)))
    (cond ((vector? r) (vector->list r))
          ((list? r) r)
          (else #f))))

(define (entry-with-rotations entry rots)
  (cons (cons 'rotations rots)
        (filter (lambda (p) (not (eq? (car p) 'rotations))) entry)))

(define (verify-rotation-run aid-prefix entry rots)
  "Fold VERIFY-ROTATION-EVENT over ROTS against ENTRY's state as it grows.
   Returns (values #t entry-after) or (values error-string #f)."
  (let loop ((rs rots) (entry entry))
    (cond
     ((null? rs) (values #t entry))
     ((not (and (pair? (car rs)) (pair? (caar rs)) (vector? (cdar rs))))
      (values "each rotation must be (rot-alist . sigs-vector)" #f))
     (else
      (let ((v (verify-rotation-event aid-prefix entry (caar rs) (cdar rs))))
        (if (eq? v #t)
            (loop (cdr rs)
                  (entry-with-rotations
                   entry (append (or (assq-ref entry 'rotations) '()) (list (car rs)))))
            (values v #f)))))))

(define (verify-carried-kel aid-prefix icp-alist sigs rotations entry)
  "The log {icp, sigs, rotations} for AID-PREFIX, verified against ENTRY as
   it stands here (or #f) — witness-kel!'s judgement without its write, so
   a KEL carried inside a presented credential bundle can land from any
   vat through a plain file write. Unknown AID: the whole chain verifies.
   Known AID: the same inception, rotations held here matched event for
   event, any further rotations verified against the held state. Returns
   (values #t entry-to-store) — the entry as it should stand after this
   log, or the standing one when nothing new arrived — or (values
   error-string #f)."
  (let ((icp-alist (normalize-vecs icp-alist))
        (rots (rotation-list rotations)))
    (cond
     ((not (valid-aid? aid-prefix)) (values "invalid AID prefix" #f))
     ((not rots) (values "rotations must be a vector of (rot . sigs)" #f))
     ((not (pair? entry))
      (let ((v (verify-self-signed-icp aid-prefix icp-alist sigs)))
        (if (not (eq? v #t)) (values v #f)
            (verify-rotation-run
             aid-prefix
             `((aid . ,aid-prefix) (icp . ,icp-alist) (sigs . ,sigs)
               (rotations . ()) (replies . #())
               (registered-at . ,(number->string (instant->unix (clock-now)))))
             rots))))
     (else
      (let* ((stored (or (assq-ref entry 'rotations) '()))
             (depth  (length stored)))
        (cond
         ((not (equal? (assoc-ref (assq-ref entry 'icp) "d") (assoc-ref icp-alist "d")))
          (values "a different inception is held under this AID" #f))
         ((let loop ((a stored) (b rots))
            (and (pair? a) (pair? b)
                 (or (not (equal? (assoc-ref (car (car a)) "d")
                                  (assoc-ref (car (car b)) "d")))
                     (loop (cdr a) (cdr b)))))
          (values "the presented rotations diverge from the ones held here" #f))
         ((<= (length rots) depth) (values #t entry))
         (else (verify-rotation-run aid-prefix entry (list-tail rots depth)))))))))

(define (witness-kel! aid-prefix icp-alist sigs rotations entry oobi-host)
  "Accept the log {icp, sigs, rotations} for AID-PREFIX into OOBI-HOST.
   ENTRY is the oobi-host entry as it stands, or #f — read by the CALLER
   (^lobby shares oobi-host's vat; signup-agent does not, so its only
   touch on oobi-host is the async write). Unknown AID: the whole chain
   is verified and lands. Known AID: the presented icp must be the
   stored one, rotations already held must match event for event (a
   different history under one AID is not levelled, it is refused), and
   rotations beyond the stored depth are verified against the stored
   state and appended. A presented log shorter than the stored one
   changes nothing. Returns 'ok or (list 'error reason)."
  (let ((icp-alist (normalize-vecs icp-alist))
        (rots (rotation-list rotations)))
    (cond
     ((not (valid-aid? aid-prefix)) (list 'error "invalid AID prefix"))
     ((not oobi-host) (list 'error "no oobi-host configured"))
     ((not rots) (list 'error "rotations must be a vector of (rot . sigs)"))
     (else
      (let ((entry (and (pair? entry) entry)))
        (cond
         ((not entry)
          (let ((v (verify-self-signed-icp aid-prefix icp-alist sigs)))
            (if (not (eq? v #t))
                (list 'error v)
                (call-with-values
                 (lambda ()
                   (verify-rotation-run
                    aid-prefix
                    `((aid . ,aid-prefix) (icp . ,icp-alist) (sigs . ,sigs) (rotations . ()))
                    rots))
                 (lambda (v _)
                   (cond
                    ((not (eq? v #t)) (list 'error v))
                    (else
                     (<- oobi-host 'put! aid-prefix icp-alist sigs)
                     (for-each (lambda (r)
                                 (<- oobi-host 'append-rotation! aid-prefix (car r) (cdr r)))
                               rots)
                     (format (current-error-port)
                             "[signup-agent] witnessed ~a (~a rotations)\n"
                             (aid-tag aid-prefix) (length rots))
                     'ok)))))))
         (else
          (let* ((stored (or (assq-ref entry 'rotations) '()))
                 (depth  (length stored)))
            (cond
             ((not (equal? (assoc-ref (assq-ref entry 'icp) "d") (assoc-ref icp-alist "d")))
              (list 'error "a different inception is held under this AID"))
             ((let loop ((a stored) (b rots))
                (and (pair? a) (pair? b)
                     (or (not (equal? (assoc-ref (car (car a)) "d")
                                      (assoc-ref (car (car b)) "d")))
                         (loop (cdr a) (cdr b)))))
              (list 'error "the presented rotations diverge from the ones held here"))
             ((<= (length rots) depth) 'ok)
             (else
              (let ((extra (list-tail rots depth)))
                (call-with-values
                 (lambda () (verify-rotation-run aid-prefix entry extra))
                 (lambda (v _)
                   (cond
                    ((not (eq? v #t)) (list 'error v))
                    (else
                     (for-each (lambda (r)
                                 (<- oobi-host 'append-rotation! aid-prefix (car r) (cdr r)))
                               extra)
                     (format (current-error-port)
                             "[signup-agent] ~a rotation(s) caught up for ~a\n"
                             (length extra) (aid-tag aid-prefix))
                     'ok)))))))))))))))

(define (aid->handle aid)
  "A deterministic, valid username minted from an AID, for a seat taken
   with no name given (the display name is a profile field)."
  (let* ((cs (filter (lambda (c) (or (char-alphabetic? c) (char-numeric? c)))
                     (string->list (string-downcase aid))))
         (n  (min 12 (length cs))))
    (string-append "u" (list->string (list-head cs n)))))

(define (seat-join members aid-index username email aid-prefix witnessed?)
  "The checks behind join!. Returns (list 'error reason), or
   (cons new-members new-aid-index) for the method to bcom with.
   WITNESSED? is the caller's reading of oobi-host (the lobby's `$`,
   or the witnessing this same turn just did)."
  (let ((username (if (and (string? username) (not (string=? username "")))
                      username (aid->handle aid-prefix))))
    (cond
     ((not (valid-username? username))
      (list 'error (string-append "invalid username (must match [a-z][a-z0-9-]{0,31}): "
                                  username)))
     ((and (not (string=? email "")) (not (valid-email? email)))
      (list 'error (string-append "invalid email: " email)))
     ((not (valid-aid? aid-prefix))
      (list 'error "invalid AID prefix (must be 44+ char CESR qb64)"))
     ((hashmap-ref aid-index aid-prefix #f)
      (list 'error (string-append "AID already registered: " aid-prefix)))
     ((hashmap-ref members username #f)
      (list 'error (string-append "username already registered: " username)))
     ((not witnessed?)
      (list 'error (string-append "AID not witnessed here: " aid-prefix)))
     (else
      (let ((now (number->string (instant->unix (clock-now)))))
        (format (current-error-port)
                "[signup-agent] seat taken: ~a\n" (aid-tag aid-prefix))
        (cons (hashmap-set members username
                           (make-member username email aid-prefix now))
              (hashmap-set aid-index aid-prefix username)))))))

(define-actor (^signup-agent bcom members aid-index)
  ;; members:   hashmap of username  → member record
  ;; aid-index: hashmap of aid-prefix → username  (reverse lookup)

  #:portrait
  (lambda ()
    (list (hashmap-fold (lambda (k v acc) (cons v acc)) '() members)))

  #:version 2

  #:restore
  (lambda (version serialized-members)
    (case version
      ;; v1: old SSH-key records — migrate by dropping key field
      ((1)
       (let* ((migrated (map (lambda (m)
                               ;; old: (username email ssh-key registered-at)
                               ;; new: (username email aid registered-at)
                               ;; ssh-key has no AID — store placeholder
                               (make-member (list-ref m 0)
                                            (list-ref m 1)
                                            (string-append "legacy:" (list-ref m 2))
                                            (list-ref m 3)))
                             serialized-members))
              (hm (fold (lambda (m hm) (hashmap-set hm (member-username m) m))
                        (hashmap) migrated))
              (idx (fold (lambda (m idx) (hashmap-set idx (member-aid m) (member-username m)))
                         (hashmap) migrated)))
         (spawn ^signup-agent hm idx)))
      ((2)
       (let* ((hm (fold (lambda (m hm) (hashmap-set hm (member-username m) m))
                        (hashmap) serialized-members))
              (idx (fold (lambda (m idx) (hashmap-set idx (member-aid m) (member-username m)))
                         (hashmap) serialized-members)))
         (spawn ^signup-agent hm idx)))
      (else (error "Unknown ^signup-agent version" version))))

  (methods

    ;; ── register! ────────────────────────────────────────────────────────────
    ;; Resolve the user's OOBI via KERIA (witness-verified), then persist.
    ;; Returns 'ok or (list 'error "reason").
    ((register! username email aid-prefix oobi-url)
     (cond
       ((not (valid-username? username))
        (list 'error (string-append "invalid username (must match [a-z][a-z0-9-]{0,31}): "
                                    username)))
       ((not (valid-email? email))
        (list 'error (string-append "invalid email: " email)))
       ((not (valid-aid? aid-prefix))
        (list 'error "invalid AID prefix (must be 44+ char CESR qb64)"))
       ((not (valid-oobi? oobi-url))
        (list 'error "invalid OOBI URL (must contain /oobi/)"))
       ((hashmap-ref members username #f)
        (list 'error (string-append "username already registered: " username)))
       ((hashmap-ref aid-index aid-prefix #f)
        (list 'error (string-append "AID already registered: " aid-prefix)))
       (else
        (let ((result (verify-oobi! aid-prefix oobi-url)))
          (if (eq? result #t)
              (let* ((now (number->string (instant->unix (clock-now))))
                     (mem (make-member username email aid-prefix now))
                     (new-members (hashmap-set members username mem))
                     (new-index   (hashmap-set aid-index aid-prefix username)))
                (format (current-error-port)
                        "[signup-agent] registered ~a\n" (aid-tag aid-prefix))
                ;; bcom must be the *returned value* of the handler for
                ;; the behavior swap to take effect; pass 'ok as the
                ;; method return.
                (bcom (^signup-agent bcom new-members new-index) 'ok))
              (list 'error result))))))

    ;; ── witness-kel! ────────────────────────────────────────────────────────
    ;; The log into ^oobi-host, on its own terms — see witness-kel! above.
    ;; No username, no seat, no bcom: witnessing changes nothing about
    ;; membership.
    ((witness-kel! aid-prefix icp-alist sigs rotations entry oobi-host)
     (witness-kel! aid-prefix icp-alist sigs rotations entry oobi-host))

    ;; ── join! ───────────────────────────────────────────────────────────────
    ;; A seat in this gateway's universal commune for an AID witnessed
    ;; here: the member row the session cap hangs off. USERNAME may be
    ;; "" — a handle is minted from the AID; the display name is a
    ;; profile field, set later. Returns 'ok or (list 'error reason).
    ((join! username email aid-prefix witnessed?)
     (let ((r (seat-join members aid-index username email aid-prefix witnessed?)))
       (if (and (pair? r) (eq? 'error (car r)))
           r
           ;; bcom must be the *returned value* of the handler for
           ;; the behavior swap to take effect.
           (bcom (^signup-agent bcom (car r) (cdr r)) 'ok))))

    ;; ── has-seat? ───────────────────────────────────────────────────────────
    ((has-seat? aid-prefix)
     (and (hashmap-ref aid-index aid-prefix #f) #t))

    ;; ── register-with-icp! / register-with-kel! ─────────────────────────────
    ;; Witness, then join — the signup a browser makes with a commune in
    ;; reach, as one call, for an AID this gateway has not seen. The seat
    ;; checks run first so a refused seat leaves oobi-host untouched.
    ;; OOBI-HOST may be #f for tests that don't care about the OOBI
    ;; layer; then only the membership is persisted.
    ((register-with-icp! username email aid-prefix icp-alist sigs oobi-host)
     (let ((r (seat-join members aid-index username email aid-prefix #t)))
       (if (and (pair? r) (eq? 'error (car r)))
           r
           (let ((w (if oobi-host
                        (witness-kel! aid-prefix icp-alist sigs (vector) #f oobi-host)
                        (let ((v (verify-self-signed-icp aid-prefix (normalize-vecs icp-alist) sigs)))
                          (if (eq? v #t) 'ok (list 'error v))))))
             (if (eq? w 'ok)
                 (bcom (^signup-agent bcom (car r) (cdr r)) 'ok)
                 w)))))
    ((register-with-kel! username email aid-prefix icp-alist sigs rotations oobi-host)
     (let ((r (seat-join members aid-index username email aid-prefix #t)))
       (if (and (pair? r) (eq? 'error (car r)))
           r
           (let ((w (witness-kel! aid-prefix icp-alist sigs rotations #f oobi-host)))
             (if (eq? w 'ok)
                 (bcom (^signup-agent bcom (car r) (cdr r)) 'ok)
                 w)))))

    ;; ── register-oobi-replies! ───────────────────────────────────────────────
    ;; Follow-up to register-with-icp!: attach the browser-endorsed OKEA
    ;; endpoint replies (/end/role/add + /loc/scheme, framed CESR strings)
    ;; so the served OOBI advertises WHERE the AID is, not just WHO
    ;; (OOBI §3.4 — prerequisite for witness receipting and any resolver
    ;; that needs the AID's service endpoint). Each frame's endorsement
    ;; must verify under the AID's pubkey. Returns 'ok or (list 'error r).
    ;; CURRENT-KEY is the AID's current signing key (latest rot.k[0], or
    ;; the inception key when unrotated) — the prefix alone goes stale
    ;; after rotation. The CALLER reads it from oobi-host and passes it
    ;; in: signup-agent may live in a different vat than oobi-host (the
    ;; gateway's layout keeps the cross-vat boundary on the async write
    ;; path only), so no `$` reads of oobi-host are allowed here. #f
    ;; means the AID isn't registered.
    ((register-oobi-replies! aid-prefix current-key replies oobi-host)
     (let ((replies (normalize-vecs replies)))
       (cond
        ((not (valid-aid? aid-prefix))
         (list 'error "invalid AID prefix"))
        ((not oobi-host)
         (list 'error "no oobi-host configured"))
        ((not (and (vector? replies) (positive? (vector-length replies))))
         (list 'error "replies must be a non-empty vector of framed strings"))
        ((not current-key)
         (list 'error (string-append "AID not registered: " aid-prefix)))
        (else
         (let loop ((i 0))
           (if (= i (vector-length replies))
               (begin
                 (<- oobi-host 'set-replies! aid-prefix replies)
                 (format (current-error-port)
                         "[signup-agent] oobi endpoint replies accepted for ~a\n"
                         (aid-tag aid-prefix))
                 'ok)
               (let ((verdict (verify-oobi-reply current-key
                                                 (vector-ref replies i))))
                 (if (eq? verdict #t)
                     (loop (+ i 1))
                     (list 'error verdict)))))))))

    ;; ── register-rotation! ───────────────────────────────────────────────────
    ;; Append a rotation event to an already-registered AID. OOBI-HOST is
    ;; required (it owns the prior-state lookup needed for validation).
    ;; Returns 'ok or (list 'error reason).
    ((register-rotation! aid-prefix rot-alist sigs oobi-host)
     (cond
      ((not (valid-aid? aid-prefix))
       (list 'error "invalid AID prefix"))
      ((not oobi-host)
       (list 'error "no oobi-host configured"))
      (else
       (let ((entry (and oobi-host ($ oobi-host 'get aid-prefix))))
         (cond
          ((not entry)
           (list 'error (string-append "AID not registered: " aid-prefix)))
          (else
           (let ((verdict (verify-rotation-event aid-prefix entry
                                                  rot-alist sigs)))
             (cond
              ((eq? verdict #t)
               (<- oobi-host 'append-rotation! aid-prefix rot-alist sigs)
               (format (current-error-port)
                       "[signup-agent] rotation accepted for ~a (sn=~a)\n"
                       (aid-tag aid-prefix) (assoc-ref rot-alist "s"))
               'ok)
              (else (list 'error verdict))))))))))

;; ── register-rotations! ──────────────────────────────────────────────────
    ;; Append a run of rotations, in sn order, to an already-registered AID —
    ;; the controller's log has moved on at another commune and this one is
    ;; catching up. Each rot is verified against the state the one before it
    ;; left (the entry as it stands, then the entry plus each accepted rot),
    ;; so a run that breaks at sn k is refused whole and nothing lands. A rot
    ;; is self-verifying — the key it reveals hashes to the prior event's
    ;; commitment and signs the event — so no session is asked for: only
    ;; the controller can author one, whoever forwards it. ENTRY is the
    ;; oobi-host entry as the caller read it (the lobby's `$`).
    ((register-rotations! aid-prefix rotations entry oobi-host)
     (cond
      ((not (valid-aid? aid-prefix))
       (list 'error "invalid AID prefix"))
      ((not oobi-host)
       (list 'error "no oobi-host configured"))
      (else
       (let ((entry (and (pair? entry) entry))
             (rots  (let ((r (normalize-vecs rotations)))
                      (cond ((vector? r) (vector->list r))
                            ((list? r) r)
                            (else #f)))))
         (cond
          ((not entry)
           (list 'error (string-append "AID not registered: " aid-prefix)))
          ((not rots)
           (list 'error "rotations must be a vector of (rot . sigs)"))
          (else
           (let loop ((rs rots) (entry entry) (accepted '()))
             (cond
              ((null? rs)
               (for-each (lambda (r)
                           (<- oobi-host 'append-rotation! aid-prefix (car r) (cdr r)))
                         (reverse accepted))
               (format (current-error-port)
                       "[signup-agent] ~a rotation(s) caught up for ~a\n"
                       (length accepted) (aid-tag aid-prefix))
               'ok)
              (else
               (let ((r (car rs)))
                 (if (not (and (pair? r) (pair? (car r)) (vector? (cdr r))))
                     (list 'error "each rotation must be (rot-alist . sigs-vector)")
                     (let ((v (verify-rotation-event aid-prefix entry (car r) (cdr r))))
                       (if (eq? v #t)
                           (loop (cdr rs)
                                 (cons (cons 'rotations
                                             (append (or (assq-ref entry 'rotations) '())
                                                     (list r)))
                                       (filter (lambda (p) (not (eq? (car p) 'rotations))) entry))
                                 (cons r accepted))
                           (list 'error v))))))))))))))

    ;; ── members ──────────────────────────────────────────────────────────────
    ((members)
     (hashmap-fold
      (lambda (k v acc)
        (cons (list (member-username v)
                    (member-email v)
                    (member-registered-at v)
                    (member-display-name v))
              acc))
      '() members))

    ;; ── member? ──────────────────────────────────────────────────────────────
    ((member? username)
     (and (hashmap-ref members username #f) #t))

    ;; ── get-member ───────────────────────────────────────────────────────────
    ((get-member username)
     (hashmap-ref members username #f))

    ;; ── update-profile! ──────────────────────────────────────────────────────
    ;; Set the mutable profile fields (display-name, email) for an AID's
    ;; member. The handle (username key) stays immutable. Called by an
    ;; authenticated ^lobby-session, which supplies its OWN bound AID — so
    ;; a member can only edit their own profile.
    ((update-profile! aid display-name email)
     (let ((username (hashmap-ref aid-index aid #f)))
       (cond
        ((not username) (list 'error "not a member"))
        ((and (string? email) (not (string=? email "")) (not (valid-email? email)))
         (list 'error (string-append "invalid email: " email)))
        (else
         (let* ((m  (hashmap-ref members username #f))
                (m2 (make-member username
                                 (if (string? email) email (member-email m))
                                 (member-aid m) (member-registered-at m)
                                 (if (string? display-name) display-name
                                     (member-display-name m))))
                (new-members (hashmap-set members username m2)))
           (bcom (^signup-agent bcom new-members aid-index) 'ok))))))

    ;; ── profile ──────────────────────────────────────────────────────────────
    ;; The AID's profile for the settings panel: handle + display-name + email.
    ((profile aid)
     (let ((username (hashmap-ref aid-index aid #f)))
       (and username
            (let ((m (hashmap-ref members username #f)))
              (list (cons 'username     (member-username m))
                    (cons 'display-name (member-display-name m))
                    (cons 'email        (member-email m)))))))

    ;; ── lookup-aid ───────────────────────────────────────────────────────────
    ;; Reverse lookup: AID prefix → username. Used by auth flow in lobby.
    ((lookup-aid aid-prefix)
     (hashmap-ref aid-index aid-prefix #f))

    ;; ── forget! ──────────────────────────────────────────────────────────────
    ;; Erase the link between an AID and a person: the member record (handle,
    ;; email, display name) and the AID→handle index entry go, and the next
    ;; portrait is written without them. The AID's key log is untouched —
    ;; what survives is data about a pseudonym nobody here can resolve
    ;; (docs/planning/legal/gdpr-analysis.md §3.1). The handle is free again.
    ;; Replies 1 when a record went, 0 when none stood: idempotent.
    ((forget! aid)
     (let ((username (hashmap-ref aid-index aid #f)))
       (if username
           (bcom (^signup-agent bcom
                                (hashmap-remove members username)
                                (hashmap-remove aid-index aid))
                 1)
           0)))

    ;; ── member-count ─────────────────────────────────────────────────────────
    ((member-count)
     (hashmap-count members))))

;;; ── Persistence environment ──────────────────────────────────────────────────

(define signup-agent-env
  (make-persistence-env
    `((((sapient-os signup) ^signup-agent) ,^signup-agent))))
