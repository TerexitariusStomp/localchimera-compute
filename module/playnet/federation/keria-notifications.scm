;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/federation/keria-notifications.scm — KERIA notification polling + dispatch
;;;
;;; This is the event bus for all async KERI activity. Nothing works without it:
;;; multi-sig confirmations, credential offers, IPEX grants — all arrive here.
;;;
;;; Ported from Veridian's keriaNotificationService.ts with mobile-specific
;;; concerns removed. Runs as a Guile fiber.
;;;
;;; Routes handled:
;;;   /multisig/icp        — group inception invite (someone wants us in a group)
;;;   /multisig/exn        — group exchange (join authorization, credential ops)
;;;   /multisig/rpy        — group reply (end-role authorization)
;;;   /exn/ipex/apply      — credential request from a holder
;;;   /exn/ipex/offer      — credential offer (response to our apply)
;;;   /exn/ipex/agree      — holder agreed to our offer
;;;   /exn/ipex/grant      — credential issuance to us
;;;   /exn/remotesign/ixn/req — remote signing request
;;;
;;; Retry: failed notifications are retried with exponential backoff.
;;; Outbound filtering: notifications for exchanges we initiated are skipped.
;;;
;;; Parity: notification routes match signify-ts 0.3.0 (commit ebc0f0f)
;;; src/keri/app/notifying.ts. Handlers themselves are playnet-specific
;;; (no upstream equivalent — signify-ts is a client library, not a
;;; server). The IPEX route names are protocol-level, defined in
;;; IPEX.md §3 Table 1. See docs/keri/SIGNIFY-PARITY.md.

(define-module (playnet federation keria-notifications)
  #:use-module (playnet keri bridge)
  #:use-module (playnet keri credentials)
  #:use-module (playnet federation ipex-policy)
  #:use-module ((playnet keri inception) #:select (gateway-controller-aid-name))
  #:use-module ((playnet keys exchange)
                #:select (current-pending-grants governance-cred->wire))
  #:use-module ((playnet keri signify)
                #:select (saidify-block %saidplaceholder))
  #:use-module (playnet federation scope-graph)
  #:use-module (playnet keys keria-store)
  ;; cred-said accessor for the governance-cred alist returned by
  ;; acdc-store queries (different from acdc-said which reads the
  ;; ACDC's "d" field).
  #:use-module ((playnet keri acdc) #:select (cred-said))
  #:use-module (goblins)
  #:use-module (fibers)
  #:use-module (ice-9 format)
  ;; uri-encode is used in handle-multisig-rpy when forwarding the AID
  ;; into KERIA's /addEndRole path. Without this import the handler
  ;; throws "Unbound variable: uri-encode" — the catch wrapper swallows
  ;; it and pushes the notification onto the exponential-backoff retry
  ;; queue indefinitely.
  #:use-module (web uri)
  #:use-module ((playnet keri signify-portable) #:select (array-first))
  #:export (set-notification-callback!
            install-default-handlers!
            start-notification-poller!
            stop-notification-poller!
            register-notification-handler!
            register-credential-watcher!
            unregister-credential-watcher!
            notification-route/multisig-icp
            notification-route/multisig-exn
            notification-route/multisig-rpy
            notification-route/ipex-apply
            notification-route/ipex-offer
            notification-route/ipex-agree
            notification-route/ipex-grant
            notification-route/ipex-admit
            notification-route/remote-sign))

;;; ── Route constants ──────────────────────────────────────────────────────────

(define notification-route/multisig-icp    "/multisig/icp")
(define notification-route/multisig-exn    "/multisig/exn")
(define notification-route/multisig-rpy    "/multisig/rpy")
(define notification-route/ipex-apply      "/exn/ipex/apply")
(define notification-route/ipex-offer      "/exn/ipex/offer")
(define notification-route/ipex-agree      "/exn/ipex/agree")
(define notification-route/ipex-grant      "/exn/ipex/grant")
(define notification-route/ipex-admit      "/exn/ipex/admit")
(define notification-route/remote-sign     "/exn/remotesign/ixn/req")

;;; ── Backoff schedule (from Veridian) ─────────────────────────────────────────
;;; Seconds: 1, 2.5, 5, 10, 30, 60, 300, 900

(define %backoff-schedule #(1 2.5 5 10 30 60 300 900))

(define (backoff-delay attempt)
  (let ((n (vector-length %backoff-schedule)))
    (vector-ref %backoff-schedule (min (- attempt 1) (- n 1)))))

;;; ── Handler registry ─────────────────────────────────────────────────────────
;;;
;;; Handlers are registered per route. Multiple handlers per route supported.
;;; Each handler: (lambda (route said notification-alist) ...)

(define *handlers* '())   ; alist of route → (handler ...)

(define (register-notification-handler! route handler)
  "Register HANDLER for notifications on ROUTE.
   handler = (lambda (route said notification-alist) ...).
   Multiple handlers per route are called in registration order."
  (let ((existing (assoc route *handlers*)))
    (if existing
        (set-cdr! existing (append (cdr existing) (list handler)))
        (set! *handlers* (cons (list route handler) *handlers*)))))

;;; ── User notification callback ──────────────────────────────────────────────
;;;
;;; Gateway wires this at boot to route IPEX events to the browser via
;;; ^presence.notify → ^output-sink → ^browser-adapter → notify!.

(define *notification-callback* #f)

(define (set-notification-callback! cb)
  "Set the callback for user-facing notifications.
   cb = (lambda (event-alist) ...) where event-alist has at minimum a 'kind key."
  (set! *notification-callback* cb))

(define (%user-notify! event-alist)
  "Send a structured event to the notification system. The adapter
   handles all formatting — handlers just describe what happened."
  (when *notification-callback*
    (catch #t
      (lambda () (*notification-callback* event-alist))
      (lambda _ #f))))

;;; ── Credential watcher registry ─────────────────────────────────────────────
;;;
;;; Browser sessions register a callback ref via the lobby session's
;;; watch-credentials method. When the notification poller admits a
;;; credential, %notify-credential-watchers! pushes the governance-cred
;;; to all watchers registered for the holder's AID. This is the push
;;; half of the pull+push sync — the pull (list-credentials) happens
;;; once on auth; after that, only deltas flow.

(define *credential-watchers* (make-hash-table))

(define (register-credential-watcher! aid-prefix watcher-ref)
  (let ((existing (hash-ref *credential-watchers* aid-prefix '())))
    (hash-set! *credential-watchers* aid-prefix
               (cons watcher-ref existing))))

(define (unregister-credential-watcher! aid-prefix watcher-ref)
  (let ((existing (hash-ref *credential-watchers* aid-prefix '())))
    (hash-set! *credential-watchers* aid-prefix
               (filter (lambda (w) (not (eq? w watcher-ref))) existing))))

(define (%notify-credential-watchers! holder-aid gov-cred)
  (let ((watchers (hash-ref *credential-watchers* holder-aid '())))
    (for-each
     (lambda (w)
       (catch #t
         (lambda () (<- w 'on-credential gov-cred))
         (lambda (key . args)
           (log-err "credential watcher push failed: ~a ~a" key args))))
     watchers)))

(define (dispatch-notification route said note)
  "Call all registered handlers for ROUTE."
  (let ((handlers (assoc-ref *handlers* route)))
    (when handlers
      (for-each (lambda (h)
                  (catch #t
                    (lambda () (h route said note))
                    (lambda (key . args)
                      (log-err "handler error [~a]: ~a ~a" route key args))))
                handlers))))

;;; ── State ────────────────────────────────────────────────────────────────────

(define *running* #f)
(define *poll-interval* 2)        ; seconds, matches Veridian's 2000ms
(define *failed* (make-hash-table)) ; said → attempt-count

;;; ── Logging ──────────────────────────────────────────────────────────────────

(define (log! fmt . args)
  (apply format (current-error-port)
         (string-append "[notifications] " fmt "\n") args)
  (force-output (current-error-port)))

(define (log-err fmt . args)
  (apply format (current-error-port)
         (string-append "[notifications] ERROR " fmt "\n") args)
  (force-output (current-error-port)))

;;; ── Outbound filter ──────────────────────────────────────────────────────────
;;;
;;; Skip notifications for exchanges we initiated.
;;; Fetch our local AID list; if exn.i is one of ours, skip.

(define *local-aid-prefixes* #f)

(define (refresh-local-aids!)
  "Re-fetch the local AID prefix list from KERIA. Returns the fresh list,
   or '() on transport failure (cache is left unchanged on error)."
  (catch #t
    (lambda ()
      (let ((fresh (map (lambda (a) (assoc-ref a "prefix"))
                        (keri-as-list (keri-list-aids)))))
        (set! *local-aid-prefixes* fresh)
        fresh))
    (lambda _ (or *local-aid-prefixes* '()))))

(define (outbound-exchange? note)
  "Returns #t if this notification is for an exchange we sent.
   Lazy-refreshes the cache on a miss so newly-created local AIDs
   aren't falsely classified as remote senders."
  (let ((sender (assoc-path note "a" "exn" "i")))
    (and sender
         (or (and *local-aid-prefixes*
                  (member sender *local-aid-prefixes*))
             (member sender (refresh-local-aids!)))
         #t)))

;;; ── Single notification processor ───────────────────────────────────────────

(define (process-notification note)
  "Process one notification. Returns #t on success, #f on failure."
  (let* ((a     (assoc-ref note "a"))
         (route (and a (assoc-ref a "r")))
         (said  (and a (assoc-ref a "d")))
         (nid   (assoc-ref note "i")))
    (cond
     ((not route)
      (log! "skipping notification with no route: ~a" nid)
      #t)
     ((outbound-exchange? note)
      ;; Silently skip — we sent this exchange, not for us to process
      (keri-mark-notification-read nid)
      #t)
     (else
      (catch #t
        (lambda ()
          (dispatch-notification route said note)
          (keri-mark-notification-read nid)
          #t)
        (lambda (key . args)
          (log-err "processing ~a [~a]: ~a ~a" route said key args)
          #f))))))

;;; ── Retry queue ──────────────────────────────────────────────────────────────

(define (maybe-retry note)
  "Track failed notification for retry with exponential backoff."
  (let* ((a    (assoc-ref note "a"))
         (said (and a (assoc-ref a "d")))
         (nid  (assoc-ref note "i")))
    (when said
      (let ((attempts (1+ (hash-ref *failed* said 0))))
        (hash-set! *failed* said attempts)
        (let ((delay (backoff-delay attempts)))
          (log! "will retry ~a in ~as (attempt ~a)" said delay attempts)
          ;; Schedule retry via fiber sleep
          (spawn-fiber
           (lambda ()
             (sleep delay)
             (catch #t
               (lambda ()
                 (when (process-notification note)
                   (hash-remove! *failed* said)))
               (lambda _ #f)))))))))

;;; ── Poll loop ────────────────────────────────────────────────────────────────

(define* (poll-loop #:key (start-index 0))
  "Main notification poll loop. Runs inside a fiber.
   Fetches batches of 24, processes each, advances index."
  (let loop ((idx start-index))
    (unless (not *running*)
      (let ((batch
             (catch #t
               (lambda ()
                 (keri-list-notifications #:start idx #:end (+ idx 24)))
               (lambda (key . args)
                 ;; Network error — try reconnect, keep index
                 (log-err "poll error: ~a ~a" key args)
                 (catch #t
                   (lambda () (keri-connect! (getenv "KERIA_BRAN")))
                   (lambda _ #f))
                 #f))))
        (let* ((notes    (keri-as-list batch))
               (next-idx (if (null? notes) idx (+ idx (length notes)))))
          (for-each
           (lambda (note)
             (unless (process-notification note)
               (maybe-retry note)))
           notes)
          (sleep *poll-interval*)
          (loop next-idx))))))

;;; ── Built-in protocol handlers ───────────────────────────────────────────────
;;;
;;; These are wired in automatically by install-default-handlers!
;;; They handle the KERI protocol mechanics that must always run.
;;; Application-level handlers (credential UI, etc.) register separately.

;;; /multisig/rpy — end-role authorization confirmation
;;;
;;; When we get this, another group member is requesting we confirm their
;;; agent endpoint authorization. We fetch the request, validate, and respond.

(define (handle-multisig-rpy route said note)
  (catch #t
   (lambda ()
    (let* ((requests (keri-get-group-requests said))
           (req      (array-first requests)))
      (unless req
        (log-err "multisig/rpy: no group request found for ~a" said)
        (error "No group request"))
      (let* ((exn-data   (assoc-ref req "exn"))
             (group-aid  (assoc-path exn-data "a" "gid"))
             (rpy-block  (assoc-path exn-data "e" "rpy"))
             (rpy-route  (and rpy-block (assoc-ref rpy-block "r"))))
        ;; Only handle /end/role/add — the agent endpoint authorization
        (when (equal? rpy-route "/end/role/add")
          (let* ((rpy-attrs (assoc-ref rpy-block "a"))
                 (role      (assoc-ref rpy-attrs "role"))
                 (eid       (assoc-ref rpy-attrs "eid"))
                 (dt        (assoc-ref rpy-block "dt")))
            ;; Apply the end-role locally and send confirmation exchange
            (let ((op (POST (string-append "/identifiers/"
                                           (uri-encode group-aid)
                                           "/addEndRole")
                            `(("role" . ,role)
                              ("eid"  . ,eid)
                              ("dt"   . ,dt)))))
              (keri-wait-operation op #:timeout 30)
              (log! "multisig/rpy: applied end-role ~a for ~a" role group-aid)))))))
   (lambda (key . args)
     (log-err "multisig/rpy: ~a ~a" key args))))

;;; /exn/remotesign/ixn/req — remote signing request
;;;
;;; Someone is asking us to co-sign by anchoring a payload SAID into our KEL
;;; via an interaction event, then replying with the ixn sequence number.
;;;
;;; Protocol:
;;;   1. Validate the request: payload SAID must match content
;;;   2. Create ixn anchoring the payload SAID
;;;   3. Send /remotesign/ixn/ref exchange back with ixn sequence number

(define (handle-remote-sign route said note)
  (catch #t
   (lambda ()
    (let* ((exn-msg    (keri-get-exchange said))
           (exn-data   (assoc-ref exn-msg "exn"))
           (payload    (assoc-ref exn-data "a"))
           (sender-aid (assoc-ref exn-data "i"))
           (recip-aid  (assoc-ref exn-data "rp"))
           (payload-said (assoc-ref payload "d")))
      ;; Step 1: Validate payload SAID
      ;; (Full SAID verification requires computing Blake3 hash of payload —
      ;;  KERIA verifies this internally; we trust the fetch for now)
      (unless payload-said
        (log! "remotesign: no SAID in payload, ignoring")
        (error "No SAID in remote sign payload"))
      ;; Step 2: Create interaction event anchoring the payload SAID
      (let* ((ixn-op  (keri-interact recip-aid `(("d" . ,payload-said))))
             (ixn-done (keri-wait-operation ixn-op #:timeout 30))
             (ixn-sn   (assoc-ref ixn-done "sn")))   ; sequence number
        ;; Step 3: Send /remotesign/ixn/ref back to requester. Note: the
        ;; bridge's keri-submit-exchange takes positional + keyword args
        ;; (aid-name route #:recipient #:payload …); the earlier shape
        ;; was a single alist that would have errored on arity. The
        ;; route lives under /ipex/ in the bridge's URL path, so the
        ;; "ref" suffix here is the path tail per signify-ts convention.
        (keri-submit-exchange recip-aid "ref"
                              #:recipient sender-aid
                              #:payload `(("sn"  . ,ixn-sn)
                                          ("req" . ,said))
                              #:rec (list sender-aid))
        (log! "remotesign: anchored ~a, sent ref (sn=~a)" payload-said ixn-sn))))
   (lambda (key . args)
     (log-err "remotesign: ~a ~a" key args))))

;;; ── IPEX handlers (IPEX.md §3 Table 1) ──────────────────────────────────────
;;;
;;; Inbound IPEX policy is in (playnet federation ipex-policy). The handler here
;;; only does protocol mechanics: fetch the exchange body, idempotency-guard,
;;; consult policy, then admit + mirror — or spurn. Per IPEX.md §3 we MUST
;;; spurn on reject; silent mark-read is non-conformant and leaves the
;;; counter-party waiting.

(define (%aid-name-for issuee)
  "Local KERIA AID-name to sign the admit/spurn under. Today only this
   gateway's own controller AID is registered with KERIA; scope-issued
   credentials reach us addressed to scope AIDs but the only local key we
   can route through is the controller's. Phase-3 will give each scope
   its own registered name; until then the controller's name is the only
   correct answer. The scope-graph's `get-aid-name` is consulted first so
   that when Phase-3 lands no notification-side change is needed."
  (let ((g (current-scope-graph)))
    (or (and g (in-graph-vat (lambda () ($ g 'get-aid-name issuee))))
        (gateway-controller-aid-name))))

(define (%spurn-quietly rejecter-aid-name target-said recipient-aid reason)
  "Send an IPEX spurn. Wraps in catch — if the spurn itself fails (e.g.
   KERIA offline), log and move on; the inbound notification is already
   marked-read by process-notification's success path."
  (catch #t
    (lambda ()
      (keri-wait-operation
       (acdc-spurn rejecter-aid-name target-said recipient-aid)))
    (lambda (key . args)
      (log-err "spurn for ~a failed: ~a ~a" target-said key args)))
  (log! "ipex: spurned ~a (~a)" target-said reason))

(define (%already-admitted? cred-said)
  "True iff KERIA already holds the credential locally — replayed
   notification, or our prior admit succeeded."
  (catch #t
    (lambda () (and (keri-get-credential cred-said) #t))
    (lambda _ #f)))

(define (%mirror-and-hook! policy acdc issuee)
  "Wrap the inbound ACDC in KERIA's sad/status shell, normalize via the
   single ACDC→governance-cred converter, mirror into the holder scope's
   store if local, fire the policy's post-admit hook, and push to any
   browser sessions watching this holder's AID."
  (let* ((gov-cred (keria-cred->governance-cred
                    `(("sad" . ,acdc) ("status" . "issued"))))
         (store    ((grant-policy-admit-into policy) issuee))
         (hook     (grant-policy-post-admit-hook policy)))
    (when (and gov-cred store)
      (in-graph-vat (lambda () (<- store 'issue-idempotent gov-cred))))
    (when (and hook gov-cred)
      (hook gov-cred (current-scope-graph)))
    (when gov-cred
      (%notify-credential-watchers! issuee gov-cred))))

(define (handle-ipex-grant route said note)
  (let* ((exn-msg (keri-get-exchange said))
         (acdc    (ipex-exn-acdc exn-msg)))
    (cond
     ((not acdc)
      (log-err "ipex/grant: ~a missing acdc embed (exn.e.acdc / exn.a.acdc)" said))
     (else
      (let* ((issuer    (ipex-exn-sender exn-msg))
             (issuee    (acdc-holder acdc))
             (schema    (acdc-schema acdc))
             (cred-said (acdc-said acdc))
             (claims    (acdc-claims acdc))
             (local     (%aid-name-for issuee))
             (reject!   (lambda (reason)
                          (%spurn-quietly local said issuer reason))))
        (cond
         ((not (and issuer schema cred-said issuee))
          (log-err "ipex/grant: malformed acdc in ~a" said))
         ((%already-admitted? cred-said)
          (log! "ipex/grant: ~a already admitted; skipping" cred-said))
         (else
          (let ((policy (lookup-grant-policy schema)))
            (cond
             ((not policy)
              (reject! (format #f "unknown schema ~a" schema)))
             ((not ((grant-policy-expected-issuer? policy)
                    issuer issuee claims))
              (reject! (format #f "issuer ~a not permitted for ~a"
                               issuer schema)))
             (else
              (keri-wait-operation (acdc-admit local said))
              (%mirror-and-hook! policy acdc issuee)
              (log! "ipex/grant: admitted ~a (~a) from ~a → ~a"
                    cred-said schema issuer issuee)))))))))))

;; ── apply / offer / agree (pull flow) ──────────────────────────────
;;
;; All three handlers share the catch-and-log shape with handle-ipex-grant,
;; reuse %spurn-quietly + %aid-name-for, and consult the same policy
;; machinery for the same trust answers. The only verb-specific bit is
;; the decision + action: apply → find+offer-or-spurn; offer → decide
;; agree-or-spurn; agree → grant the credential we previously offered.
;;
;; What signify gives us: outbound acdc-apply/offer/agree/grant wrappers
;; (in credentials.scm). What it doesn't: any auto-respond logic —
;; that's our policy table.

(define (%log-and-catch label thunk)
  (catch #t thunk
    (lambda (key . args)
      (log-err "~a: ~a ~a" label key args))))

;; --- apply: a holder requests a credential from us ----------------

(define (handle-ipex-apply route said note)
  (%log-and-catch
   "ipex/apply"
   (lambda ()
     (let* ((exn       (keri-get-exchange said))
            (payload   (assoc-path exn "exn" "a"))
            ;; Schema can arrive under "schema" (our `acdc-apply` shape)
            ;; or "s" (signify's). Accept both.
            (schema    (and payload
                            (or (assoc-ref payload "schema")
                                (assoc-ref payload "s"))))
            (requester (ipex-exn-sender exn))
            (recipient (ipex-exn-recipient exn))
            (local     (%aid-name-for recipient))
            (finder    (current-credential-finder))
            (cred      (and finder schema requester (finder schema requester))))
       (cond
        ((not finder)
         (%spurn-quietly local said requester
                         "no credential-finder configured"))
        ((not (and schema requester))
         (%spurn-quietly local said requester
                         "malformed apply (missing schema or sender)"))
        ((not cred)
         (%spurn-quietly local said requester
                         (format #f "no credential for schema ~a" schema)))
        (else
         ;; cred is a governance-cred alist (symbol-keyed) from the
         ;; acdc-store's by-schema query; pull the SAID via cred-said,
         ;; not acdc-said (acdc-said reads the "d" field of a raw ACDC).
         (keri-wait-operation
          (acdc-offer local requester said (cred-said cred)))
         (%user-notify! `((kind . ipex-apply) (recipient . ,recipient)
                         (requester . ,requester)
                         (schema . ,schema) (said . ,said)))
         (log! "ipex/apply: offered ~a (~a) → ~a"
               (cred-said cred) schema requester)))))))

;; --- offer: an issuer offers us a credential in response to our apply --

(define (handle-ipex-offer route said note)
  (%log-and-catch
   "ipex/offer"
   (lambda ()
     (let* ((exn       (keri-get-exchange said))
            (issuer    (ipex-exn-sender exn))
            (recipient (ipex-exn-recipient exn))
            (local     (%aid-name-for recipient)))
       (cond
        ((not (issuer-has-resolvable-kel? issuer recipient '()))
         (%spurn-quietly local said issuer
                         (format #f "issuer ~a not trusted" issuer)))
        (else
         (keri-wait-operation (acdc-agree local issuer said))
         (%user-notify! `((kind . ipex-offer) (recipient . ,recipient)
                         (issuer . ,issuer) (said . ,said)))
         (log! "ipex/offer: agreed ~a from ~a" said issuer)))))))

;; --- agree: holder accepted our offer; ship the credential -------

(define (handle-ipex-agree route said note)
  (%log-and-catch
   "ipex/agree"
   (lambda ()
     (let* ((agree-exn  (keri-get-exchange said))
            ;; Spec shape: the offer being agreed-to rides exn.p; tolerate
            ;; the legacy a.offer location for old producers.
            (offer-said (or (assoc-path agree-exn "exn" "p")
                            (assoc-path agree-exn "exn" "a" "offer")))
            (offer-exn  (and (string? offer-said)
                             (not (string-null? offer-said))
                             (keri-get-exchange offer-said)))
            (cred-said  (and offer-exn (assoc-path offer-exn "exn" "a" "acdc")))
            (holder     (ipex-exn-sender agree-exn))
            (recipient  (ipex-exn-recipient agree-exn))
            (local      (%aid-name-for recipient)))
       (cond
        ((not cred-said)
         (log-err "ipex/agree: ~a referenced no acdc in its offer" said))
        (else
         ;; The spec-complete grant needs KERIA's /credentials export
         ;; (sad+iss+anc). A LOCALLY-issued governance credential — the
         ;; very thing the apply-side finder offers out of the local
         ;; stores — was never in KERIA's registry, so that export
         ;; fails; grant it from the local store instead, embedding its
         ;; wire projection the way scope-grant-body already does (same
         ;; documented divergence: no iss/anc, playnet receivers read
         ;; the exn's own embed).
         (catch #t
           (lambda () (keri-wait-operation (acdc-grant local cred-said holder)))
           (lambda (key . args)
             (let* ((find (current-credential-finder-by-said))
                    (cred (and find (find cred-said))))
               (if (not cred)
                   (apply throw key args)
                   (begin
                     (keri-wait-operation
                      (keri-submit-exchange local "grant"
                                            #:recipient holder
                                            #:payload (list (cons "m" ""))
                                            #:embeds (saidify-block
                                                      (list (cons "d" %saidplaceholder)
                                                            (cons "acdc" (governance-cred->wire cred))))
                                            #:rec (list holder)))
                     (log! "ipex/agree: granted ~a from the local store (not in KERIA)"
                           cred-said))))))
         (%user-notify! `((kind . ipex-agree) (recipient . ,recipient)
                         (holder . ,holder)
                         (cred-said . ,cred-said) (said . ,said)))
         (log! "ipex/agree: granted ~a → ~a" cred-said holder)))))))

;; /exn/ipex/admit — recipient acknowledges a grant we sent. We use
;; this to clear matching pending-grants entries eagerly (rather than
;; waiting for the next drain tick to discover the grant succeeded).
;;
;; IPEX.md §3 Table 1: admit anchors the grant it accepts via the exn
;; `p` (prior) field. But what we actually queued was the CREDENTIAL
;; said (the ACDC's SAID), not the grant exn SAID. So we fetch the
;; admit exn, read exn.p (the grant exn SAID; tolerate the legacy
;; a.grant location), then fetch *that* exn to reach its embedded
;; acdc SAID — which is what our pending entries key on. One extra
;; round-trip; only fires on successful delivery, so the cost
;; amortises.

(define (handle-ipex-admit route said note)
  (let ((q (current-pending-grants)))
    (when q
      (catch #t
        (lambda ()
          (let* ((admit-exn  (keri-get-exchange said))
                 (grant-said (let ((p (assoc-path admit-exn "exn" "p")))
                               (if (and (string? p) (not (string-null? p)))
                                   p
                                   (assoc-path admit-exn "exn" "a" "grant"))))
                 (grant-exn  (and grant-said (keri-get-exchange grant-said)))
                 (acdc       (and grant-exn (ipex-exn-acdc grant-exn)))
                 (cred-said  (and acdc (acdc-said acdc))))
            ;; Fire-and-forget cleanup; we don't await the vow. The
            ;; actor logs match-counts when > 0.
            (when cred-said
              (in-graph-vat
               (lambda () (<- q 'confirm-delivered! cred-said)))
              (%user-notify! `((kind . ipex-admit) (cred-said . ,cred-said)
                               (said . ,said))))))
        (lambda (key . args)
          (log-err "ipex/admit: ~a ~a" key args))))))

;;; Install protocol handlers on startup

(define (install-default-handlers!)
  "Register built-in KERI protocol handlers.
   Call once after start-notification-poller!."
  (register-notification-handler! notification-route/multisig-rpy
                                   handle-multisig-rpy)
  (register-notification-handler! notification-route/remote-sign
                                   handle-remote-sign)
  ;; IPEX (IPEX.md §3 Table 1). NOTE: we deliberately do NOT register a
  ;; handler for /exn/ipex/spurn — spurn is terminal per spec; the
  ;; dispatcher's no-match branch correctly does nothing. Registering one
  ;; risks a ping-pong with a peer who also spurns.
  (install-default-grant-policies!)
  (register-notification-handler! notification-route/ipex-grant
                                   handle-ipex-grant)
  (register-notification-handler! notification-route/ipex-apply
                                   handle-ipex-apply)
  (register-notification-handler! notification-route/ipex-offer
                                   handle-ipex-offer)
  (register-notification-handler! notification-route/ipex-agree
                                   handle-ipex-agree)
  (register-notification-handler! notification-route/ipex-admit
                                   handle-ipex-admit)
  (log! "default handlers installed"))

;;; ── Start / stop ─────────────────────────────────────────────────────────────

(define* (start-notification-poller! #:optional (start-index 0)
                                     #:key
                                     (scope-graph #f)
                                     (graph-vat   #f))
  "Start the notification poller in a background fiber.
   Call after keri-connect!. Returns immediately.

   #:scope-graph and #:graph-vat land in the GLOBAL registry
   (scope-graph.scm) so IPEX handlers can reach the topology actor from
   any thread or fiber — the globals replaced the parameters this used
   to re-bind precisely because fibers don't inherit dynamic state."
  (set! *running* #t)
  (set! *local-aid-prefixes* #f)   ; refresh on start
  (when scope-graph (current-scope-graph scope-graph))
  (when graph-vat   (current-graph-vat   graph-vat))
  (spawn-fiber
   (lambda ()
     (poll-loop #:start-index start-index)))
  (log! "poller started"))

(define (stop-notification-poller!)
  "Stop the notification poller."
  (set! *running* #f)
  (log! "poller stopped"))
