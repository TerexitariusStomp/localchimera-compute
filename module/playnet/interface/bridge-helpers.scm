;;; module/playnet/interface/bridge-helpers.scm — shared chat-bridge plumbing
;;;
;;; The Telegram and Matrix bridges (and any future chat surface) all
;;; need the same three pieces:
;;;
;;;   1. A channel-manager whose factory creates a fresh ^scope-handler
;;;      per channel, against a locally-spawned scope-root + ^org-stub.
;;;      Used when the bridge runs standalone for testing.
;;;
;;;   2. A channel-manager that hands out a *shared* far-ref to a
;;;      remote ^scope-handler (the one the gateway exports via OCapN
;;;      sturdyref) and a fresh local sink per channel. Alert fan-out
;;;      from the remote backend is deliberately not wired — only
;;;      command/response flows over OCapN.
;;;
;;;   3. A dispatch entry point: given a (channel-id, channel-name,
;;;      transport-context) triple plus the parsed (user-id, text),
;;;      look up or create the channel, bind the transport once, and
;;;      hand the input to the channel.
;;;
;;; Each bridge supplies its own transport-specific bits — the
;;; channel-id format ("tg-…" / "mx-…"), the display-name format,
;;; and the opaque transport context (chat_id / room_id) — and reuses
;;; the wiring here.

(define-module (playnet interface bridge-helpers)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (goblins ocapn ids)
  #:use-module (goblins ocapn captp)
  #:use-module (goblins ocapn netlayer websocket)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (playnet interface backends scope)
  #:use-module (playnet interface output-sink)
  #:use-module (playnet interface channel-manager)
  #:use-module (playnet interface org-stub)
  #:use-module (playnet interface flow)
  #:use-module (playnet scope root)
  #:export (build-local-channel-mgr
            build-remote-channel-mgr
            dispatch-to-channel!
            make-shared-flow-registry
            make-flow-runner-factory))


;;; ── Flow plumbing ──────────────────────────────────────────────────────────
;;;
;;; A single ^flow-registry is shared across all channels created by a
;;; given bridge. The factory hands each channel its own ^flow-runner
;;; backed by that registry, so each channel keeps its own per-user
;;; flow sessions but draws from the same set of named flows.

(define (make-shared-flow-registry vat flows)
  "Spawn a ^flow-registry in VAT and register every flow in FLOWS
   (a list of <flow> records). Returns the registry ref."
  (with-vat vat
    (let ((reg (spawn ^flow-registry (hashmap))))
      (for-each (lambda (f) ($ reg 'register f)) flows)
      reg)))

(define (make-flow-runner-factory vat registry)
  "Return a (channel-id) → ^flow-runner factory suitable for passing
   to ^channel-manager. Each call spawns a fresh runner sharing REGISTRY."
  (lambda (_channel-id)
    (with-vat vat
      (spawn ^flow-runner registry (hashmap)))))


;;; ── Local backend ──────────────────────────────────────────────────────────

(define* (build-local-channel-mgr bridge-vat scope-vat scope-name
                                  #:key (flow-runner-factory #f))
  "Spawn a fresh scope-root + ^org-stub in scope-vat, return a
   channel-manager whose factory builds a ^scope-handler per channel.
   #:flow-runner-factory (channel-id) → ^flow-runner is optional."
  (let* ((scope-ref (with-vat scope-vat (spawn-scope-root scope-name)))
         (org-ref   (with-vat scope-vat (spawn ^org-stub))))
    (with-vat bridge-vat
      (spawn ^channel-manager
             (hashmap)
             (lambda (_name)
               (with-vat scope-vat
                 (make-scope-handler scope-ref org-ref)))
             flow-runner-factory))))


;;; ── Remote backend (OCapN sturdyref) ───────────────────────────────────────

(define* (build-remote-channel-mgr bridge-vat sref-file log!
                                   #:key (flow-runner-factory #f))
  "Stand up an OCapN client mycapn, enliven the scope-handler sturdyref
   from SREF-FILE, and return a channel-manager whose factory hands
   back the same shared backend with a fresh local sink per channel.
   LOG! is the bridge's logger procedure."
  (let* ((ocapn-vat (spawn-vat #:name "bridge-ocapn"))
         (mycapn
          (with-vat ocapn-vat
            (let ((nl (spawn ^websocket-netlayer
                             #:host "127.0.0.1"
                             #:port 0
                             #:encrypted? #f)))
              (spawn-mycapn nl))))
         (uri (string-trim-both
               (call-with-input-file sref-file get-string-all)))
         (sref (string->ocapn-id uri))
         ;; <- returns a vow; channels use async <- to talk to it,
         ;; so we can store the vow as the backend ref directly.
         (backend-far
          (with-vat ocapn-vat (<- mycapn 'enliven sref))))
    (log! "  [bridge] enlivening backend: ~a~%" uri)
    (with-vat bridge-vat
      (spawn ^channel-manager
             (hashmap)
             (lambda (_name)
               (let ((sink (with-vat bridge-vat
                             (spawn ^output-sink
                                    #f #f
                                    passthrough-formatter
                                    '()))))
                 (values backend-far sink)))
             flow-runner-factory))))


;;; ── Dispatch ───────────────────────────────────────────────────────────────

(define (ensure-channel! channel-mgr adapter
                         channel-id channel-name transport-context
                         log!)
  "Find or create the channel for CHANNEL-ID. On creation, bind the
   transport once with TRANSPORT-CONTEXT (the opaque destination key
   the adapter understands — chat_id, room_id, etc.). Returns the
   ^channel ref or #f on failure."
  (let ((existing ($ channel-mgr 'get-channel channel-id)))
    (or existing
        (let ((created ($ channel-mgr 'create-channel
                          channel-id channel-name)))
          (match created
            (('error . _)
             (log! "  [bridge] create-channel failed: ~a~%" created)
             #f)
            (chan
             ($ chan 'bind-transport adapter transport-context)
             chan))))))

(define (dispatch-to-channel! bridge-vat channel-mgr adapter
                              channel-id channel-name transport-context
                              user-id text
                              log!)
  "Route a parsed inbound message into the channel pipeline. Idempotent
   on channel creation — first message in a chat creates and binds the
   channel, subsequent messages reuse it."
  (with-vat bridge-vat
    (let ((chan (ensure-channel! channel-mgr adapter
                                 channel-id channel-name transport-context
                                 log!)))
      (when chan
        ($ chan 'handle-input user-id text)))))
