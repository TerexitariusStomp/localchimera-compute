;;; module/playnet/boot/notify.scm — every way this commune reaches a person: the alert sink, presence, push, email, the router over them.
;;;
;;; The scope handler off meeting-scope is what the chat surfaces reach over
;;; OCapN; its sink receives every planner alert via ^tee-alert-store and
;;; hands it to ^presence, so alerts flow to the browser when a user
;;; connects. The sink's formatter is the ONE render point for the channel:
;;; every downstream adapter (browser transport + push doorbell) is dumb from
;;; there on. The unified router (docs/notifications/UNIFIED-ROUTER.md)
;;; delivers per recipient over the same adapters.

(define-module (playnet boot notify)
  #:use-module ((playnet boot site) #:select (data-path log!))
  #:use-module ((playnet gateway presence) #:select (^presence))
  #:use-module ((playnet identity contact-points) #:select (make-contact-point-desk))
  #:use-module ((playnet interface adapters browser) #:select (^browser-adapter))
  #:use-module ((playnet interface adapters email) #:select (^email-adapter email-transport?))
  #:use-module ((playnet interface backends scope) #:select (make-scope-handler))
  #:use-module ((playnet interface org-stub) #:select (^org-stub))
  #:use-module ((playnet keri cesr) #:select (b64url-encode))
  #:use-module ((playnet federation keria-notifications) #:select (set-notification-callback!))
  #:use-module ((playnet notify recipient) #:select (^recipient-registry datum->recipient-table recipient-table->datum))
  #:use-module ((playnet notify registry) #:select (notification-formatter))
  #:use-module ((playnet notify rendered) #:select (rendered-notification))
  #:use-module ((playnet notify router) #:select (^notify-router))
  #:use-module ((playnet push adapter) #:select (^push-adapter ^push-subscription-store))
  #:use-module ((playnet push crypto) #:select (vapid-public-key-bytes))
  #:use-module ((playnet push vapid) #:select (load-or-generate-vapid-key!))
  #:use-module ((playnet utils paths) #:select (playnet-data-dir))
  #:use-module ((goblins utils hashmap) #:select (hashmap))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (<notify> notify? notify-vapid-key notify-vapid-public-b64 notify-push-store
            notify-push-adapter notify-telegram-backend notify-alert-sink notify-browser-adapter
            notify-presence notify-recipient-registry notify-email-adapter notify-router
            notify-contact-desk spawn-notifications!))

(define-record-type <notify>
  (make-notify vapid-key vapid-public-b64 push-store push-adapter telegram-backend alert-sink
               browser-adapter presence recipient-registry email-adapter router contact-desk)
  notify?
  (vapid-key          notify-vapid-key)          ; the Web Push signing key
  (vapid-public-b64   notify-vapid-public-b64)   ; its public half, as the browser subscribes with it
  (push-store         notify-push-store)         ; ^push-subscription-store
  (push-adapter       notify-push-adapter)       ; ^push-adapter over it
  (telegram-backend   notify-telegram-backend)   ; the scope handler the chat bridge enlivens
  (alert-sink         notify-alert-sink)         ; every planner alert, rendered terse
  (browser-adapter    notify-browser-adapter)    ; ^browser-adapter
  (presence           notify-presence)           ; ^presence: who is connected, the legacy broadcast path
  (recipient-registry notify-recipient-registry) ; the AID-keyed channels people confirmed
  (email-adapter      notify-email-adapter)      ; ^email-adapter, or #f without a transport
  (router             notify-router)             ; ^notify-router over the adapters
  (contact-desk       notify-contact-desk))      ; where a presented contact point waits for its code

(define* (spawn-notifications! #:key gateway-vat planner-vat meeting-scope)
  "The notification layer: the adapters in GATEWAY-VAT, the scope handler and
its sink in PLANNER-VAT off MEETING-SCOPE, the IPEX callback routed through
it. The <notify> record of what the lobby and the sessions reach."
  ;; ── VAPID key for Web Push ──────────────────────────────────────────
  (define vapid-key (load-or-generate-vapid-key! (playnet-data-dir)))
  (define vapid-public-b64
    (b64url-encode (vapid-public-key-bytes vapid-key)))
  ;; push-store must precede push-adapter (it reads it) — keep the
  ;; subscription store defined before the adapter that spawns over it.
  (define push-store
    (with-vat gateway-vat
      (spawn ^push-subscription-store '())))

  (define push-adapter
    (with-vat gateway-vat
      (spawn ^push-adapter vapid-key push-store)))

  (define (push-doorbell rendered)
    "Ring the doorbell — send a Web Push preview when alerts queue
     offline. The sink hands us a rendered notification (see
     notification-formatter); the push adapter puts it on the wire."
    (<-np push-adapter 'deliver #f rendered))

  (define-values (telegram-backend alert-sink)
    (with-vat planner-vat
      (let-values (((handler sink) (make-scope-handler meeting-scope
                                                       (spawn ^org-stub))))
        ;; The ONE render point for this channel: event alist -> a
        ;; rendered `terse' notification. Every downstream adapter
        ;; (browser transport + push doorbell) is dumb from here on.
        ($ sink 'set-formatter (notification-formatter 'terse))
        ($ sink 'set-doorbell push-doorbell)
        (values handler sink))))

  (log! "  [gateway] telegram-backend + alert-sink spawned~%")

  (define browser-adapter
    (with-vat gateway-vat (spawn ^browser-adapter)))

  (define presence-actor
    (with-vat gateway-vat
      (spawn ^presence (hashmap) alert-sink browser-adapter)))

  ;; ── Unified notification router (docs/notifications/UNIFIED-ROUTER.md)
  ;; The AID-keyed recipient registry (seeded by the lobby SESSION's
  ;; AID-aware announce/register-push) and the router over it. The
  ;; router renders per-channel and delivers via the dumb adapters.
  ;; The registry's durable channels (the addresses people confirmed)
  ;; are kept in one file: read at boot, written each time one is bound
  ;; or withdrawn. Withdrawing a channel rewrites the file without it.
  (define recipients-file (data-path "recipients.scm"))
  (define (keep-recipients! durable-table)
    (let ((tmp (string-append recipients-file ".tmp")))
      (call-with-output-file tmp
        (lambda (p) (write (recipient-table->datum durable-table) p) (newline p)))
      (rename-file tmp recipients-file)))
  (define recipient-registry
    (with-vat gateway-vat
      (spawn ^recipient-registry
             (datum->recipient-table
              (catch #t
                (lambda () (if (file-exists? recipients-file)
                               (call-with-input-file recipients-file read)
                               '()))
                (lambda _ '())))
             keep-recipients!)))

  ;; Email is a channel of this commune when a mail handed to the adapter
  ;; goes somewhere: a relay the box names (PLAYNET_SMTP_HOST, with its
  ;; account's password to hand), a sendmail on the path, or
  ;; PLAYNET_MAIL_DIR (interface/adapters/email.scm).
  (define email-adapter
    (and (email-transport?) (with-vat gateway-vat (spawn ^email-adapter))))

  (define notify-router
    (with-vat gateway-vat
      (spawn ^notify-router recipient-registry
             `((browser . ,browser-adapter)
               (push    . ,push-adapter)
               ,@(if email-adapter `((email . ,email-adapter)) '()))
             '()
             alert-sink)))   ; legacy sink = fallback for unbound recipients

  ;; The desk a presented contact point waits at while its code travels
  ;; to the address itself (identity/contact-points.scm). Its channels
  ;; are the durable kinds this commune delivers on.
  (define contact-desk
    (make-contact-point-desk
     (if email-adapter
         `((email . ,(lambda (ctx title body)
                       (<-np email-adapter 'deliver ctx
                             (rendered-notification 'info title body "confirm-contact-point")))))
         '())))
  (log! "  [gateway] contact points: delivers on ~a~%" (contact-desk 'delivers))

  ;; Wire IPEX notification callback → router (per-recipient) → dumb
  ;; adapters. Events carry a 'recipient AID (the local user the event
  ;; is for); we route to that AID's bound channels. Events WITHOUT a
  ;; recipient (or before a session has seeded a browser binding) fall
  ;; back to the legacy presence → sink → browser path so nothing is
  ;; dropped during the browser-side cutover.
  (set-notification-callback!
   (lambda (event-alist)
     (let ((recipient (assq-ref event-alist 'recipient)))
       (if recipient
           ;; Per-recipient: router delivers to that AID's channels,
           ;; or falls back to the legacy sink if it has none bound.
           (<-np notify-router 'notify recipient event-alist)
           ;; No recipient AID on the event → legacy broadcast path.
           (<-np presence-actor 'notify-event event-alist)))))
  (make-notify vapid-key vapid-public-b64 push-store push-adapter telegram-backend alert-sink
               browser-adapter presence-actor recipient-registry email-adapter notify-router
               contact-desk))
