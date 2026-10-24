;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/keri/bridge.scm — Guile↔KERIA HTTP bridge
;;;
;;; Thin wrapper around KERIA's REST API. All identity ops go through here.
;;; Passcode (bran) is a 21-char CESR salt that derives all signing keys —
;;; no traditional passwords. All crypto materials are CESR qb64 strings.
;;;
;;; KERIA ports (from docker-compose):
;;;   3901 — agent API (normal operations)
;;;   3902 — connect/boot API
;;;   3903 — boot API
;;;
;;; Usage:
;;;   (use-modules (localchimera keri bridge))
;;;   (keri-boot! "my-agent" "mysecretpasscode21x")
;;;   (keri-connect! "mysecretpasscode21x")
;;;   (keri-create-aid "alice" #:toad 2 #:witnesses (keri-default-witnesses))

(define-module (localchimera keri bridge)
  #:use-module ((srfi srfi-1) #:select (any))
  #:use-module (ice-9 format)
  #:use-module ((localchimera utils clock) #:select ((now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (ice-9 match)
  #:use-module (web client)
  #:use-module (web http)              ; declare-opaque-header!
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  ;; A wait inside a vat turn yields the scheduler: see keri-pause.
  #:use-module ((fibers scheduler) #:select (current-scheduler))
  #:use-module ((fibers timers) #:select ((sleep . fibers-sleep)))
  ;; Verification flows route through (localchimera keri citizen-sig), which
  ;; dispatches via the keri-crypto backend. Bridge no longer touches
  ;; (goblins utils crypto) directly.
  #:use-module ((localchimera keri cesr)
                #:select (cesr-bytes->qb64 cesr-qb64->bytes b64url-encode b64url-decode))
  #:use-module ((localchimera keri citizen-sig)
                #:select (verify-said-signature))
  #:use-module (localchimera keri signify)
  #:re-export (cesr-bytes->qb64 cesr-qb64->bytes
               controller->aid-signing-keypair
               ed25519-keypair-public sign-bytes)
  #:export (keri-boot!
            keri-connect!
            keri-agent-url
            keri-boot-url
            keri-set-urls!
            keri-default-witnesses

            ;; Identifiers
            keri-create-aid
            keri-get-aid
            keri-add-end-role
            keri-get-keystate
            keri-rotate-keys
            keri-list-aids
            keri-get-aid-members

            ;; OOBI / contacts
            keri-url-status
            keri-resolve-oobi
            keri-get-contact
            keri-list-contacts
            keri-delete-contact

            ;; Multi-sig
            keri-create-group
            keri-get-group-aid

            ;; Credentials (ACDC)
            keri-list-credentials
            keri-get-credential
            keri-delete-credential

            ;; Notifications
            keri-list-notifications
            keri-mark-notification-read

            ;; Operations (async polling + listing)
            keri-get-operation
            keri-wait-operation
            keri-op-name-said
            keri-list-operations
            keri-get-state
            keri-list-oobis
            keri-peer-status

            ;; Exchanges (IPEX + multi-sig)
            keri-get-exchange
            keri-submit-exchange
            keri-submit-multisig-exchange
            keri-submit-scope-exchange

            ;; Config + witnesses
            keri-get-config

            ;; Interaction events (ixn) — anchor data to KEL
            keri-interact

            ;; Exchanges — list + group requests
            keri-list-exchanges
            keri-get-group-requests

            ;; TEL state — real-time revocation check
            keri-get-tel-state

            ;; Signature verification.
            ;; CESR helpers (cesr-bytes->qb64, cesr-qb64->bytes) live in
            ;; (localchimera keri cesr) and are re-exported above for back-compat.
            keri-verify-signature

            ;; Connection state
            keri-connected?

            ;; Internal HTTP helpers (used by credentials.scm)
            keri-request GET POST DELETE

            ;; Reply-shape normalizer
            keri-as-list

            ;; Nested-assoc-ref helper
            assoc-path))

;;; ── Config ─────────────────────────────────────────────────────────────────

;; 127.0.0.1, NOT "localhost": the production gateway runs under
;; torsocks, which rejects the resolver lookup a hostname forces
;; ("Connection to a local address ... might be a TCP DNS query") —
;; every KERIA call from the box gateway silently failed. Literal
;; loopback IPs skip resolution; torsocks exempts 127.0.0.0/8.
(define *keria-agent-url* "http://127.0.0.1:3901")
;; 3903, not 3902 — 3902 is KERIA's --http port (unauthenticated agent
;; HTTP API for OOBI resolution), not /boot. See keria-service.scm.
(define *keria-boot-url*  "http://127.0.0.1:3903")
;; Signify auth context: holds signing keypair, controller AID, agent
;; AID (set after /boot). #f means no auth headers attached — that's
;; the right shape for the very first /boot call.
(define *signify-ctx*     #f)

(define (keri-connected?)
  "Returns #t if a Signify context is established (keri-boot! or keri-connect! succeeded)."
  (and *signify-ctx* #t))

(define (keri-agent-url) *keria-agent-url*)
(define (keri-boot-url)  *keria-boot-url*)
(define (keri-set-urls! agent-url boot-url)
  "Override the KERIA URLs. For testing against a mock server."
  (set! *keria-agent-url* agent-url)
  (set! *keria-boot-url*  boot-url))

;;; Tell guile's (web http) parser not to break on Signify structured
;;; fields. Without these, request-construction errors out on
;;; Signature-Input / Signature header values that contain quoted
;;; strings or colons.
(declare-opaque-header! "signify-resource")
(declare-opaque-header! "signify-timestamp")
(declare-opaque-header! "signature-input")
(declare-opaque-header! "signature")

;;; KERIA's POST /credentials/query sets a non-standard response header
;;;   Content-Range: credentials <skip>-<end>/<limit>
;;; whose range unit is "credentials", not "bytes". Guile's default
;;; Content-Range parser accepts only the "bytes" unit and raises
;;; `bad-header` while READING the response — before keri-request ever
;;; sees the body. Declaring it opaque lets the value pass through as a
;;; plain string so credential listing (used by ^keria-acdc-store sync!)
;;; returns normally.
(declare-opaque-header! "content-range")

;;; The paginated collection endpoints (`GET /notifications`, and KERIA's
;;; range-based listings generally) take a REQUEST `Range: notes=start-end`
;;; header whose range unit is "notes", not "bytes". Guile's default `range`
;;; parser/validator only accepts "bytes" and would reject the outbound
;;; header. Declaring it opaque lets us send the value as a plain string.
(declare-opaque-header! "range")

;; content-type/accept are NOT declared opaque here, unlike range above:
;; declare-header! is process-wide mutable state, and content-type/accept
;; are used by everything in this process that speaks HTTP (witness-
;; publisher, the telegram/matrix adapters, monero/rpc-digest, every
;; mock-server test) — forcing them opaque here would break every one
;; of those call sites' own header writing, not just KERI's. Instead,
;; json-header-value below adapts to whichever shape the process's
;; CURRENT declaration accepts, so keri-request works regardless of
;; load order without mutating shared state.
(define (json-header-value name symbol-shape)
  "Guile's native content-type/accept shape is a symbol-list, e.g.
   '(application/json) — but (localchimera utils http-auth) redeclares both
   headers process-wide to require a plain string, for its own JSON-API
   callers, and whichever module happens to load last wins for the
   whole process. Probe what's valid right now instead of hardcoding
   either shape: every KERI GET/POST failed content-type validation the
   moment both conventions disagreed — invisible until KERIA_BRAN was
   set for the first time, since none of this code ran before that."
  (if (valid-header? name symbol-shape)
      symbol-shape
      "application/json"))

;; Default witness set (from Veridian keria-config; override via env or explicit args)
(define (keri-default-witnesses)
  (let ((env (getenv "KERI_WITNESS_OOBIS")))
    (if env
        (string-split env #\,)
        '())))  ; populated at deploy time from keria-config/witnesses/

;;; ── HTTP helpers ────────────────────────────────────────────────────────────

(define (log! fmt . args)
  (apply format (current-error-port) (string-append "[keri] " fmt "\n") args)
  (force-output (current-error-port)))

(define (->json obj)
  (scm->json-string obj))

(define (parse-response body)
  (if (and body (not (string-null? body)))
      (json-string->scm body)
      '()))

(define (assoc-path obj . keys)
  "Walk OBJ down the alist path KEYS, returning the leaf value or #f
   if any link is missing (or any intermediate node isn't a pair).
   Example: `(assoc-path note \"a\" \"r\")` reads as `note.a.r`,
   replacing the chained `(assoc-ref (assoc-ref note \"a\") \"r\")`
   that recurs in 10+ KERIA-payload sites across the keri layer.
   #f-safe at every level — callers don't need a per-link guard."
  (let loop ((obj obj) (keys keys))
    (cond
     ((null? keys) obj)
     ((not (pair? obj)) #f)
     (else (loop (assoc-ref obj (car keys)) (cdr keys))))))

(define (keri-as-list x)
  "Normalize a KERIA reply slot to a list. JSON arrays parse as vectors
   under guile-json (and also under signify-portable's canonical
   emitter), but some KERIA endpoints return already-list-shaped
   payloads, and missing keys come back as #f. Treating all three
   uniformly hides nine ad-hoc `(if (vector? …) (vector->list …) …)`
   inlinings that were drifting in their fallback semantics."
  (cond ((vector? x) (vector->list x))
        ((pair? x)   x)
        (else        '())))

(define (keria-port url)
  "A non-blocking socket to URL. Every Goblins vat runs on one fibers
   scheduler, so a read on a blocking socket inside an actor turn stalls
   every vat in the process for as long as KERIA takes; on a non-blocking
   port the read suspends this fiber and the other vats keep turning
   (measured 2026-09-13: door and dial waits of 10–30 s came from this).
   Outside a fibers scheduler Guile's default port waiter polls, so the
   request behaves as a blocking one did."
  (let ((sock (open-socket-for-uri url)))
    (fcntl sock F_SETFL (logior O_NONBLOCK (fcntl sock F_GETFL)))
    sock))

(define* (keri-request method path #:key (body #f) (base *keria-agent-url*)
                       (extra-headers '()))
  "Make an HTTP request to KERIA. Returns parsed JSON or raises error.

   Once *signify-ctx* is populated (after keri-boot!), every request
   carries the 4 RFC 9421 Signify-* headers signing (@method, @path,
   signify-resource, signify-timestamp) with our derived Ed25519 key.
   /boot itself runs before the ctx is set, so it bypasses Signify
   auth — body-signing is the only auth on /boot.

   EXTRA-HEADERS — additional request headers (alist of (name . value)),
   e.g. a `Range` header for the paginated collection endpoints. These
   are NOT part of the signed set (only @method/@path/signify-* are
   signed), so they don't affect auth — keep the signed `path` query-free."
  (let* ((url (string-append base path))
         (sig-headers (if *signify-ctx*
                          (sign-request *signify-ctx* method path)
                          '()))
         (headers `((content-type . ,(json-header-value 'content-type '(application/json)))
                    (accept . ,(json-header-value 'accept '((application/json))))
                    ,@extra-headers
                    ,@sig-headers))
         (body-bv (if body
                      (string->utf8 (->json body))
                      #f)))
    (log! "~a ~a" method url)
    (call-with-values
      (lambda ()
        (http-request url
                      #:port (keria-port url)
                      #:keep-alive? #f
                      #:method method
                      #:headers headers
                      #:body body-bv
                      ;; http-request's auto-decode path inspects the
                      ;; response's PARSED content-type via (car type) —
                      ;; (localchimera utils http-auth) redeclares content-type's
                      ;; parser process-wide to return a raw string instead
                      ;; of Guile's structured (type . params) shape (for
                      ;; its own JSON-API callers), so (car "application/json")
                      ;; crashes with "expecting pair" on EVERY KERI response,
                      ;; independent of anything this module sends. We
                      ;; already decode the body ourselves below (bytevector
                      ;; or string), so skip the auto-decode entirely.
                      #:decode-body? #f))
      (lambda (response body)
        (let ((status (response-code response))
              (body-str (cond
                         ((not body) "")
                         ((string? body) body)
                         ((bytevector? body) (utf8->string body))
                         (else ""))))
          (if (< status 300)
              (parse-response body-str)
              (error (format #f "KERIA ~a ~a → ~a: ~a" method url status body-str))))))))

(define* (GET path #:key (base *keria-agent-url*))
  (keri-request 'GET path #:base base))

(define* (POST path body #:key (base *keria-agent-url*))
  (keri-request 'POST path #:body body #:base base))

(define* (DELETE path #:key (base *keria-agent-url*))
  (keri-request 'DELETE path #:base base))

;;; ── Agent lifecycle ─────────────────────────────────────────────────────────

(define (keri-boot! agent-name bran)
  "Enroll a new KERIA agent under the controller AID derived from the
   passcode. Only call once per (bran, KERIA-instance) pair.

   Wire shape (per signify-ts Controller.boot):
     POST {boot-url}/boot
     body = { icp, sig, stem, pidx=0, tier=\"low\" }

   - icp is the parsed inception event whose SAID is the controller AID.
   - sig is the 'AA'-prefixed indexed Ed25519 sig over the serialized icp.
   - No Signify-auth headers on /boot itself: body-signing IS the auth.

   If KERIA returns 409 (agent already exists for this controller),
   this is idempotent success — the ctx is still set up and subsequent
   authed calls work. That matches signify-ts's boot-then-connect flow.

   Builds the Signify context as a side effect — subsequent
   keri-request calls auto-attach Signify-* headers.

   AGENT-NAME is recorded by KERIA for human reference; not load-bearing
   for the protocol. The controller AID is fully determined by BRAN."
  (let* ((ctx  (make-signify-context bran))
         (body (boot-body ctx)))
    ;; Don't set *signify-ctx* yet — /boot must go un-signed.
    (let ((response
           (catch #t
             (lambda ()
               (POST "/boot"
                     `(("name" . ,agent-name) ,@body)
                     #:base *keria-boot-url*))
             (lambda (key . args)
               (let ((msg (format #f "~a" args)))
                 (cond
                  ;; 409: agent already exists. Idempotent — pick up
                  ;; its state via /agent/<controller-aid> after we
                  ;; flip *signify-ctx* on below.
                  ((string-contains msg " 409:")
                   (log! "/boot: agent already exists for controller ~a — continuing"
                         (signify-context-aid ctx))
                   '())
                  (else
                   (apply throw key args))))))))
      ;; Real KERIA returns the AGENT's inception event as a flat alist
      ;; (type 'dip' = delegated inception). Fields we care about:
      ;;   .i  — agent AID (put in Signify-Resource for agent-endpoint requests)
      ;;   .di — delegator AID (= our controller AID, echoed back)
      ;; The 409-continue path instead returns the GET /agent body whose
      ;; agent AID sits at .agent.i — the same shape keri-connect! reads.
      ;; (An earlier fallback here read .controller.state.i, which is the
      ;; CONTROLLER's AID, silently storing the wrong identity for
      ;; agent-end-role authorization.)
      (let* ((agent-aid (or (assoc-ref response "i")
                            (and=> (assoc-ref response "agent")
                                   (lambda (a) (assoc-ref a "i"))))))
        (when agent-aid
          (set-signify-context-agent-aid! ctx agent-aid)))
      ;; Turn on Signify auth for everything else.
      (set! *signify-ctx* ctx)
      ;; The 409-continue path returned no body, so fulfil the pickup the
      ;; comment above promises: probe /agent/<controller> exactly as
      ;; keri-connect! does (auth is on now). Without this the context
      ;; carries no agent AID and agent-end-role authorization — the step
      ;; that makes IPEX deliverable to KERIA-held AIDs — sends an empty
      ;; eid that keripy rejects with "Empty material".
      (unless (signify-context-agent-aid ctx)
        (let* ((probe (catch #t
                        (lambda ()
                          (GET (string-append
                                "/agent/"
                                (uri-encode (signify-context-aid ctx)))))
                        (lambda _ '())))
               (aa    (or (assoc-ref probe "i")
                          (and (pair? probe)
                               (and=> (assoc-ref probe "agent")
                                      (lambda (a) (assoc-ref a "i")))))))
          (when aa (set-signify-context-agent-aid! ctx aa))))
      response)))

(define (keri-connect! bran)
  "Reconnect to an existing KERIA agent enrolled under BRAN.

   Wire shape (per signify-ts Controller.connect):
     GET {agent-url}/agent/<controller-aid>
   with the 4 Signify-* headers.

   The endpoint lives on the AGENT port (3901), not /boot. KERIA
   responds with the agent-state record whose .i is the agent AID."
  (let* ((ctx (make-signify-context bran)))
    ;; Set ctx FIRST so the GET attaches Signify-auth headers.
    (set! *signify-ctx* ctx)
    (let* ((path     (string-append "/agent/"
                                    (uri-encode (signify-context-aid ctx))))
           (response (catch #t
                       (lambda () (GET path))
                       (lambda (key . args)
                         (log! "/agent/<aid> probe failed: ~a ~a" key args)
                         '()))))
      (let* ((agent-aid (or (assoc-ref response "i")
                            (and (pair? response)
                                 (and=> (assoc-ref response "agent")
                                        (lambda (a) (assoc-ref a "i")))))))
        (when agent-aid
          (set-signify-context-agent-aid! ctx agent-aid)))
      response)))

;;; ── Identifiers (AID management) ────────────────────────────────────────────

(define* (keri-create-aid name #:key (toad 0) (witnesses '()))
  "Create a new AID (Autonomic Identifier) via Signify salty mode.

   Keys are derived deterministically from the controller + AID name.
   Idempotent: if the AID already exists in KERIA, returns its current
   state instead of raising (matches keri-boot!'s 409 handling)."
  (call-with-values
    (lambda ()
      (identifier-body name *signify-ctx*
                       #:toad toad #:witnesses witnesses))
    (lambda (body _kp)
      (catch #t
        (lambda () (POST "/identifiers" body))
        (lambda (key . args)
          (let ((msg (format #f "~a" args)))
            (if (string-contains msg "already incepted")
                (begin
                  (log! "AID ~a already exists — returning current state" name)
                  (keri-get-aid name))
                (apply throw key args))))))))

(define (keri-get-aid name)
  "Fetch current state of an AID by name."
  (GET (string-append "/identifiers/" (uri-encode name))))

(define (keri-list-aids)
  "List all local AIDs."
  (GET "/identifiers"))

(define* (keri-add-end-role aid-name role eid)
  "Add an endpoint role to an AID via a signed reply event.
   Signify body: {rpy, sigs} where rpy is a /end/role/add reply."
  (POST (string-append "/identifiers/" (uri-encode aid-name) "/endroles")
        (end-role-body *signify-ctx* aid-name role eid)))

(define (keri-get-keystate aid-prefix)
  "Get current key state for an AID prefix."
  (GET (string-append "/keystate/" (uri-encode aid-prefix))))

(define* (keri-rotate-keys name #:key (adds '()) (cuts '()))
  "Rotate keys for an AID via a signed rotation event.
   Signify body: {rot, sigs, salty}.

   Posts to /identifiers/{name}/events — KERIA's event endpoint, which
   dispatches on the body's `rot`/`ixn`/`submit` key. (PUT /identifiers/{name}
   is the *rename* endpoint in KERIA 0.4.0 — it expects a new `name` and 400s
   a rotation body with \"new name is required\".)"
  (keri-request 'POST (string-append "/identifiers/" (uri-encode name) "/events")
                #:body (rotation-body *signify-ctx* name
                                      #:cuts cuts #:adds adds)))

(define (keri-get-aid-members name)
  "List members of a multi-sig group AID."
  (GET (string-append "/identifiers/" (uri-encode name) "/members")))

;;; ── Config ───────────────────────────────────────────────────────────────────
;;;
;;; GET /config returns the KERIA agent config including iurls (witness OOBIs).
;;; This is the authoritative source of the witness set — parse it to get
;;; witness EIDs and calculate the signing threshold (toad).

(define (keri-get-config)
  "Fetch KERIA agent config. Returns alist including 'iurls' (witness OOBI list)."
  (GET "/config"))

;;; ── Interaction events (ixn) ─────────────────────────────────────────────────
;;;
;;; An interaction event (ixn) anchors data to the KEL without rotating keys.
;;; Used for: remote signing, ACDC issuance anchoring, general data timestamping.
;;; The seal = alist with keys "d" (SAID of data being anchored).

(define (keri-interact aid-name seal)
  "Create an interaction event anchoring SEAL data into the KEL.
   Signify body: {ixn, sigs} — client-built IXN signed with AID's key."
  (let* ((ctrl-kp (signify-context-keypair *signify-ctx*))
         (aid-kp  (controller->aid-signing-keypair ctrl-kp aid-name))
         (aid-data (keri-get-aid aid-name))
         (prefix   (assoc-ref aid-data "prefix"))
         (state    (assoc-ref aid-data "state"))
         (last-d   (or (and state (assoc-ref state "d"))
                       (assoc-ref aid-data "d")))
         (next-sn  (%aid-next-sn state aid-data))
         (anchor   (vector seal)))
    (call-with-values
      (lambda () (build-ixn prefix last-d anchor #:sn next-sn))
      (lambda (json _said alist)
        (POST (string-append "/identifiers/" (uri-encode aid-name) "/ixn")
              (list (cons "ixn"  alist)
                    (cons "sigs" (vector (sign-event json aid-kp)))))))))

;;; ── Exchange list + group requests ──────────────────────────────────────────
;;;
;;; List exchanges with optional route/AID filters — used for inception status.
;;; Group requests are fetched separately via /groups/{id}/request.

(define* (keri-list-exchanges #:key (route #f) (group-aid #f) (skip 0) (limit 24))
  "List exchange messages with optional filters.
   route     — filter by route, e.g. \"/multisig/icp\"
   group-aid — filter by group AID (a.gid field)"
  (let ((params
         (string-concatenate
          (list (format #f "?skip=~a&limit=~a" skip limit)
                (if route (string-append "&filter=-r=" (uri-encode route)) "")
                (if group-aid (string-append "&filter=-a-gid=" (uri-encode group-aid)) "")))))
    (GET (string-append "/exchanges" params))))

(define (keri-get-group-requests group-said)
  "Fetch group exchange requests by exchange SAID.
   Used to process /multisig/rpy and /multisig/icp notifications."
  (GET (string-append "/groups/" (uri-encode group-said) "/request")))


;;; ── TEL state — real-time revocation check ───────────────────────────────────
;;;
;;; TEL (Transaction Event Log) tracks credential issuance/revocation events.
;;; The TEL state endpoint gives the authoritative revocation status,
;;; more reliable than the credential metadata (which may be stale).
;;;
;;; Returns alist with "et" (event type): "iss" = issued, "rev" = revoked.

(define (keri-get-tel-state registry-aid credential-said)
  "Get TEL state for a credential — authoritative revocation check.
   registry-aid    — the TEL registry AID (credential.sad.ri)
   credential-said — the credential's SAID (credential.sad.d)
   Returns alist with 'et' field: \"iss\" = issued, \"rev\" = revoked."
  (GET (string-append "/registries/"
                      (uri-encode registry-aid)
                      "/credentials/"
                      (uri-encode credential-said)
                      "/state")))

;;; ── OOBI / contacts ─────────────────────────────────────────────────────────
;;;
;;; OOBI = Out-of-Band Introduction. Format:
;;;   /oobi/{AID}/agent/{endpoint-AID}
;;;   /.well-known/keri/oobi/{AID}
;;; Resolving an OOBI discovers and verifies a remote AID via witnesses.

(define* (keri-resolve-oobi oobi-url #:key (alias #f))
  "Resolve an OOBI URL, creating a verified contact. Returns operation alist.
   alias = friendly name for the contact.

   Signify-ts-compatible wire shape:
     POST /oobis
     body = { url, oobialias? }
   KERIA responds with an operation; poll via keri-wait-operation.

   The pre-Signify bridge POSTed {oobi, alias} to /contacts — that
   path is gone in current KERIA (returns 405). /oobis is the
   authenticated endpoint signify-ts uses."
  (POST "/oobis"
        `(("url" . ,oobi-url)
          ,@(if alias `(("oobialias" . ,alias)) '()))))

(define (keri-get-contact aid-prefix)
  "Get contact details by AID prefix."
  (GET (string-append "/contacts/" (uri-encode aid-prefix))))

(define (keri-list-contacts)
  "List all known contacts (resolved OOBIs)."
  (GET "/contacts"))

(define (keri-delete-contact aid-prefix)
  "Delete a contact."
  (DELETE (string-append "/contacts/" (uri-encode aid-prefix))))

;;; ── Multi-sig ───────────────────────────────────────────────────────────────
;;;
;;; Group creation flow:
;;;   1. Each member creates their own AID first (keri-create-aid)
;;;   2. Members exchange OOBIs (keri-resolve-oobi)
;;;   3. Initiator calls keri-create-group with member prefixes + threshold
;;;   4. Each member signs via exchange messages (/multisig/icp route)
;;;   5. Group AID active once threshold signatures collected

(define* (keri-create-group name member-aid-name member-prefixes keys ndigs
                             #:key
                             (signing-threshold 1)
                             (rotation-threshold 1)
                             (toad 0)
                             (witnesses '()))
  "Create a multi-sig group AID via signed signify-ts body.

   name             — local name for the group AID
   member-aid-name  — local name of the CALLING member's personal AID
   member-prefixes  — ordered list of all member AID prefixes
   keys             — ordered list of all member signing keys qb64
   ndigs            — ordered list of all member next-key digests qb64

   Body: {name, icp, sigs, group: {mhab, keys, ndigs}, smids, rmids, salty}.
   Calling member signs at their index; other members co-sign via
   /multisig/icp exchanges."
  (POST "/identifiers"
        (group-body *signify-ctx* name member-aid-name member-prefixes keys ndigs
                    #:signing-threshold signing-threshold
                    #:rotation-threshold rotation-threshold
                    #:toad toad
                    #:witnesses witnesses)))

(define (keri-get-group-aid name)
  "Get current state of a group AID."
  (keri-get-aid name))

;;; ── Credentials (ACDC) ──────────────────────────────────────────────────────
;;;
;;; ACDC structure: {v, d (SAID), i (issuer AID), ri (registry), s (schema SAID),
;;;                  a {d, i (issuee AID), dt, ...claims}}
;;; Issuance uses IPEX protocol: issuer sends /exn/ipex/grant,
;;; holder responds /ipex/admit.
;;; Revocation posted to TEL (Transaction Event Log) by issuer.

(define* (keri-list-credentials #:key (skip 0) (limit 25) (filter #f))
  "List credentials via POST /credentials/query — KERIA's list route.

   A bare GET /credentials is NOT served by KERIA (0.4.0): there is no
   collection GET, only POST /credentials/query (mongo-style), so a GET
   falls through to the authenticated catch-all and returns 401.

   filter = an alist of field→value (mongo-style query) folded into the
   query's `filter` object; omitted ⇒ KERIA defaults filter to {} (all
   credentials). `sort` is likewise left to KERIA's default. Returns the
   credential array (each a full ACDC dict with `sad`, `status`, …)."
  (POST "/credentials/query"
        `(,@(if (and filter (pair? filter)) `(("filter" . ,filter)) '())
          ("skip"  . ,skip)
          ("limit" . ,limit))))

(define (keri-get-credential said)
  "Fetch a credential by its SAID (Self-Addressing Identifier)."
  (GET (string-append "/credentials/" (uri-encode said))))

(define (keri-delete-credential said)
  "Delete a credential from local store."
  (DELETE (string-append "/credentials/" (uri-encode said))))

;;; ── Notifications ───────────────────────────────────────────────────────────
;;;
;;; Notification routes:
;;;   /multisig/icp        — group inception invite
;;;   /multisig/exn        — group exchange (admit, grant, etc.)
;;;   /exn/ipex/apply      — credential request from holder
;;;   /exn/ipex/offer      — credential offer
;;;   /exn/ipex/grant      — credential issuance to holder
;;;   /local/acdc/revoked  — credential revoked (local event)

(define* (keri-list-notifications #:key (start 0) (end 24))
  "Fetch notifications in index range [start, end].

   KERIA paginates `GET /notifications` via a `Range: notes=start-end`
   header (signify-ts convention), NOT query params — and a query string
   would corrupt the signed `@path` (→ 401). The response carries
   `Content-Range: notes start-end/total` (handled by the opaque-header
   declaration above)."
  (keri-request 'GET "/notifications"
                #:extra-headers
                `((range . ,(format #f "notes=~a-~a" start end)))))

(define (keri-mark-notification-read notification-id)
  "Mark a notification as read."
  (POST (string-append "/notifications/" (uri-encode notification-id) "/mark") '()))

;;; ── Operations (async polling) ──────────────────────────────────────────────
;;;
;;; All KERIA create/rotate/credential ops are async.
;;; They return an operation alist with a "name" key.
;;; Poll keri-get-operation until ("done" . #t).

(define (keri-get-operation op-name)
  "Get operation status. Check (assoc-ref result \"done\") for completion."
  (GET (string-append "/operations/" (uri-encode op-name))))

(define (keri-list-operations)
  "List ALL pending/in-progress KERIA operations. Each entry has
   \"name\", \"done\", \"metadata\", and (when done) \"response\". An
   OOBI resolution that's been pending for >10s indicates a stuck
   escrow — the issuer's witnesses aren't reachable from this gateway."
  (GET "/operations"))

(define (keri-get-state aid-prefix)
  "Get KERIA's known key-state for AID-PREFIX. Returns the keystate
   alist on success; signals an error on 404. 404 means the AID has
   never had its OOBI successfully resolved (the silent escrow drop
   case: grants from this peer arrived but KERIA couldn't verify them
   so they were dropped after the 10s escrow timeout)."
  (GET (string-append "/states/" (uri-encode aid-prefix))))

(define (keri-list-oobis)
  "List configured OOBI URLs known to the agent. Each entry has
   \"oobi\" (the URL) and \"alias\" (the AID name it's registered for).
   Useful for confirming that a peer's witness reachability config is
   in place before debugging delivery failures."
  (GET "/oobis"))

(define* (keri-peer-status aid-prefix #:key (stale-after-s 10))
  "Composite peer-reachability check for AID-PREFIX. Returns an alist:
     (resolved? . #t/#f)  — does KERIA have a verified keystate for AID?
     (pending-ops . N)    — KERIA operations referencing AID that are
                            still in-progress (an OOBI resolution older
                            than STALE-AFTER-S is the silent-escrow-
                            drop symptom).
     (oobi-known? . #t/#f)— is there a registered OOBI for AID?
   This is the answer to 'why aren't grants from peer X landing?' that
   capability #8 needs — no upstream keripy patch required."
  (let* ((resolved?
          (catch #t
            (lambda () (and (keri-get-state aid-prefix) #t))
            (lambda _ #f)))
         (ops (catch #t (lambda () (keri-list-operations)) (lambda _ '())))
         (pending-for-aid
          (filter
           (lambda (op)
             (let ((meta (or (assoc-ref op "metadata") '())))
               (and (not (assoc-ref op "done"))
                    (or (equal? aid-prefix (assoc-ref op "name"))
                        (equal? aid-prefix (assoc-ref meta "aid"))
                        (equal? aid-prefix (assoc-ref meta "pre"))))))
           (if (list? ops) ops '())))
         (oobis (catch #t (lambda () (keri-list-oobis)) (lambda _ '())))
         (oobi-known?
          (and (list? oobis)
               (any (lambda (o)
                      (equal? aid-prefix (assoc-ref o "alias")))
                    oobis))))
    `((resolved?    . ,resolved?)
      (pending-ops  . ,(length pending-for-aid))
      (oobi-known?  . ,oobi-known?))))

(define (keri-pause seconds)
  "Wait SECONDS. Inside a fibers scheduler this suspends only the calling
   fiber, so the other vats keep turning while an operation completes
   (the same rule keria-port states for the socket read: one scheduler
   runs every vat, and a thread-level sleep in a turn stalls them all —
   measured 2026-09-22 as a gateway spending ~15 s of every 16 in
   usleep while it drained deferred grants). Outside a scheduler, which
   is where the bridge's own tests run it, it is the plain thread sleep."
  (if (current-scheduler)
      (fibers-sleep seconds)
      (usleep (inexact->exact (round (* seconds 1e6))))))

(define (keri-url-status url)
  "The HTTP status code a GET on URL returns, or #f when nothing answers.
   A cheap question to ask before handing URL to KERIA as an OOBI: KERIA
   keeps a resolve of a 404 open until its caller's timeout, while this
   answers in one round trip. Read over the same non-blocking port as
   every KERIA request, so a vat turn asking it stays cooperative."
  (catch #t
    (lambda ()
      (call-with-values
          (lambda ()
            (http-request url
                          #:port (keria-port url)
                          #:keep-alive? #f
                          #:method 'GET
                          #:decode-body? #f))
        (lambda (response body) (response-code response))))
    (lambda _ #f)))

(define* (keri-wait-operation op #:key (timeout 30) (interval 0.5))
  "Poll until operation is done or timeout (seconds). Returns final op
   alist. Each poll is INTERVAL apart, via keri-pause, so a waiting vat
   turn shares the scheduler with the rest of the gateway."
  (let ((op-name (assoc-ref op "name"))
        (deadline (+ (clock-now) timeout)))   ; an instant: seconds on the one clock
    (let loop ()
      (let ((result (keri-get-operation op-name)))
        (cond
         ((assoc-ref result "done") result)
         ((> (clock-now) deadline)
          (error (format #f "KERIA operation ~a timed out after ~as" op-name timeout)))
         (else
          (keri-pause interval)
          (loop)))))))

(define (keri-op-name-said op)
  "The SAID a KERIA operation commits to, read from its NAME.

   KERIA names long-running operations `<type>.<SAID>` — `credential.E…`,
   `exchange.E…`, `witness.E…`, etc. Since a CESR SAID is base64url (no
   `.`), the last dot is always the type/SAID separator, so the suffix is
   the SAID regardless of operation type. Returns #f if OP has no usable
   name. This is the version-independent fallback for the SAID extractors
   (metadata/response fields are nicer when present but vary by KERIA build)."
  (and=> (assoc-ref op "name")
         (lambda (n)
           (and (string? n)
                (let ((dot (string-rindex n #\.)))
                  (and dot (substring n (+ dot 1))))))))

;;; ── Exchanges (IPEX) ────────────────────────────────────────────────────────

(define (keri-get-exchange said)
  "Fetch an exchange message by SAID."
  (GET (string-append "/exchanges/" (uri-encode said))))

(define* (keri-submit-exchange aid-name route
                               #:key (recipient "") (payload '())
                               (embeds '()) (atc "") (prior "") (rec '()))
  "Submit a signed IPEX exchange to POST /identifiers/{name}/ipex/{route-tail}.
   Builds an EXN event client-side, signs it, posts {exn, sigs, atc, rec}.
   ATC carries the pathed-material attachments for any embeds; PRIOR is
   the exn `p` — the SAID of the exchange this one answers."
  (let ((body (exchange-body *signify-ctx* aid-name
                             (string-append "/ipex/" route)
                             #:recipient recipient #:payload payload
                             #:embeds embeds #:atc atc #:prior prior
                             #:rec rec)))
    (POST (string-append "/identifiers/" (uri-encode aid-name)
                         "/ipex/" route)
          body)))

(define (keri-submit-multisig-exchange aid-name route payload)
  "Submit a signed exchange for multi-sig coordination (/multisig/* routes).
   Unlike IPEX exchanges, these go to /exchanges (the generic exchange
   endpoint) and use the multi-sig route namespace. NOTE: this rail is
   strictly GROUP coordination — keripy's Multiplexor drops any /multisig/*
   exn without embeds and requires payload gid membership, so it cannot
   carry a directed message (see personhood/witness-relay.scm, which is
   where cross-gateway witnessing rides instead)."
  (let ((body (exchange-body *signify-ctx* aid-name route
                             #:payload payload)))
    (POST "/exchanges" body)))

(define (keri-submit-scope-exchange transport-aid-name route body)
  "POST a pre-built IPEX exchange body to KERIA, routing through a
   local signify identifier (TRANSPORT-AID-NAME) but with the exn
   signed by a scope-owned keypair (i.e. body's exn.i is an external
   AID that signify doesn't manage). KERIA's IPEX endpoints accept
   external senders — they validate only that the `rec` recipients
   are in the local kever database (verified per KERIA source at
   keria/app/ipexing.py); the signature verification happens on the
   receiving side against the issuer's KEL via OOBI.

   ROUTE is the IPEX verb (\"grant\", \"admit\", \"spurn\", etc.).
   The URL is /identifiers/{transport-aid-name}/ipex/{route}, same
   surface keri-submit-exchange uses for signify-managed AIDs — only
   the body's signer differs.

   For the deploy scenario this means: gateway-A's localchimera-governance
   serves as the transport AID, but the IPEX grant inside is signed
   by federation X's scope keypair. Gateway-B verifies that signature
   against X's KEL (fetched via the OOBI X has already published)."
  (POST (string-append "/identifiers/" (uri-encode transport-aid-name)
                       "/ipex/" route)
        body))

;;; ── Signature verification ──────────────────────────────────────────────────
;;;
;;; Two paths, one verifier:
;;;
;;;   D/B-prefix AIDs  → the prefix IS the pubkey; verify locally.
;;;   E-prefix / group → look up k[0] via KERIA's /keystate/{aid},
;;;                      then verify locally against that.
;;;
;;; Both paths funnel into (localchimera keri citizen-sig) verify-said-signature,
;;; which routes through the keri-crypto backend (goblins crypto on server,
;;; noble-ed25519 in the browser).

(define (keri-verify-signature aid-prefix message-str signature-qb64)
  "Verify SIGNATURE-QB64 (CESR qb64, 0B-prefix) is a valid Ed25519
   signature over MESSAGE-STR's UTF-8 bytes by the current signing
   key of AID-PREFIX. Returns #t / #f without raising on bad sigs;
   raises only on KERIA HTTP errors (E-prefix path)."
  (cond
   ;; D/B-prefix → the prefix already carries the pubkey.
   ((and (string? aid-prefix)
         (positive? (string-length aid-prefix))
         (let ((c (string-ref aid-prefix 0)))
           (or (char=? c #\D) (char=? c #\B))))
    (verify-said-signature message-str signature-qb64 aid-prefix))
   ;; E-prefix / group AID → look up the current key via KERIA, then
   ;; reuse the same local verifier against it. This mirrors what KERI
   ;; verifiers do conceptually: resolve k[0], verify under it.
   (else
    (let* ((keystate    (keri-get-keystate aid-prefix))
           (keys        (assoc-ref keystate "k"))
           (pubkey-qb64 (if (vector? keys) (vector-ref keys 0) (car keys))))
      (verify-said-signature message-str signature-qb64 pubkey-qb64)))))


;;; ── Notification poll loop ──────────────────────────────────────────────────

(define* (keri-poll-notifications handler #:key (interval 2) (start-index 0))
  "Continuously poll KERIA notifications and dispatch to handler.
   handler = procedure taking (route said notification-alist).
   Runs forever; call in a fiber or thread.

   Routes: /multisig/icp, /exn/ipex/grant, /exn/ipex/apply, /local/acdc/revoked"
  (let loop ((idx start-index))
    (let* ((batch (keri-list-notifications #:start idx #:end (+ idx 24)))
           (notes (keri-as-list batch))
           (next-idx (if (null? notes) idx (+ idx (length notes)))))
      (for-each
       (lambda (note)
         (let ((route (assoc-path note "a" "r"))
               (said  (assoc-path note "a" "d")))
           (catch #t
             (lambda () (handler route said note))
             (lambda (key . args)
               (log! "notification handler error: ~a ~a" key args)))))
       notes)
      (sleep interval)
      (loop next-idx))))
