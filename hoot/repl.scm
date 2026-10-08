(use-modules (hoot ffi)
             ((hoot typed-arrays) #:select (bytevector->uint8array))
             (hoot hashtables)
             ((hoot error-handling) #:select (format-exception))
             (ice-9 match)
             (ice-9 receive)
             (goblins)
             ((goblins core) #:select (has-syscaller?))
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             ;; (goblins utils crypto) removed — imports (rnrs bytevectors) which
             ;; Hoot can't compile. Key generation uses JS FFI directly instead.
             (goblins persistence-store local-storage)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins ocapn ids)
             (goblins abstract-types)
             (goblins contrib syrup)
             (goblins actor-lib io)
             (goblins utils hashmap)
             (goblins utils js-data)
             (goblins inbox)
             (fibers channels)
             (fibers conditions)
             (srfi srfi-9)
             (playnet org gplay)
             (playnet lang kanren)
             (playnet lang autocomplete)
             (playnet lang wisp)
             (playnet deprecated ddmrp)
             (playnet ui components)
             (playnet ui federation)
             (playnet ui network)
             (playnet ui calendar)
             ((playnet calendar ical) #:select (events->vcalendar))
             (playnet ui inventory)
             (playnet ui identity)
             (playnet ui map)
             (playnet ui treemap)
             (playnet ui contacts)
             (playnet ui recipes)
             (playnet ui priorities)
             (playnet ui clock)
             (playnet ui federation-solver)
             ;; KERI browser-resident Signify (Phase B)
             ;; Importing crypto-primitives-browser auto-installs the
             ;; FFI backend (noble libs via browser/lib/keri-crypto.js) so
             ;; signify-portable works the moment it's first called.
             (playnet keri crypto-primitives)
             (playnet keri crypto-primitives-browser)
             (playnet keri signify-portable)
             ;; AID ↔ mesh binding: resolve + verify a contact's
             ;; reticulum destination from its served OOBI body.
             ((playnet keri reticulum-binding)
              #:select (oobi-body-mesh-locs verify-oobi-body-binding
                        oobi-body-reticulum-pub reticulum-destination-hash
                        kel-reticulum-pub))
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             ((playnet crypto shamir) #:select (shamir-split))
             ((playnet wire rows) #:select (wire->plain))
             ((playnet utils hex) #:select (bv->hex hex->bv))
             ((rnrs bytevectors) #:select (string->utf8
                                           utf8->string
                                           bytevector?
                                           make-bytevector
                                           bytevector-length
                                           bytevector-u8-ref
                                           bytevector-u8-set!
                                           bytevector-copy!))
             (srfi srfi-11))


(define-foreign document-body
  "document" "body"
  -> (ref null extern))
(define-foreign get-element-by-id
  "document" "getElementById"
  (ref string) -> (ref null extern))
(define-foreign make-text-node
  "document" "createTextNode"
  (ref string) -> (ref null extern))
(define-foreign make-element
  "document" "createElement"
  (ref string) -> (ref null extern))
(define-foreign make-element-ns
  "document" "createElementNS"
  (ref string) (ref string) -> (ref null extern))
(define-foreign %make-tree-walker
  "document" "createTreeWalker"
  (ref null extern) i32 -> (ref null extern))
(define (make-tree-walker root)
  (%make-tree-walker root 5))  ;; 5 = SHOW_ELEMENT(1) | SHOW_TEXT(4)

(define-foreign js-array-length "array" "length"
  (ref null extern) -> i32)
(define-foreign js-array-ref "array" "ref"
  (ref null extern) i32 -> (ref null extern))
(define (js-array->list arr)
  "Convert a JS array (or array-like) extern to a Scheme list of externs."
  (let loop ((i (- (js-array-length arr) 1))
             (acc '()))
    (if (< i 0)
        acc
        (loop (- i 1) (cons (js-array-ref arr i) acc)))))

(define-foreign prevent-default!
  "event" "preventDefault"
  (ref null extern) -> none)
(define-foreign stop-propagation!
  "event" "stopPropagation"
  (ref null extern) -> none)
(define-foreign keyboard-event-key
  "event" "keyboardKey"
  (ref null extern) -> (ref string))
(define-foreign %keyboard-event-shift?
  "event" "keyboardShiftKey"
  (ref null extern) -> i32)
(define (keyboard-event-shift? elem)
  (= (%keyboard-event-shift? elem) 1))
(define-foreign %keyboard-event-ctrl?
  "event" "keyboardCtrlKey"
  (ref null extern) -> i32)
(define (keyboard-event-ctrl? e)
  (= (%keyboard-event-ctrl? e) 1))
(define-foreign %keyboard-event-meta?
  "event" "keyboardMetaKey"
  (ref null extern) -> i32)
(define (keyboard-event-meta? e)
  (= (%keyboard-event-meta? e) 1))
(define (ctrl-or-cmd? event)
  (or (keyboard-event-ctrl? event) (keyboard-event-meta? event)))

(define-foreign element-value
  "element" "value"
  (ref null extern) -> (ref string))
(define-foreign set-element-value!
  "element" "setValue"
  (ref null extern) (ref string) -> none)
(define-foreign %element-checked?
  "element" "checked"
  (ref null extern) -> i32)
(define (element-checked? elem)
  (= (%element-checked? elem) 1))
(define-foreign set-element-checked!
  "element" "setChecked"
  (ref null extern) i32 -> none)
(define-foreign scroll-height
  "element" "scrollHeight"
  (ref null extern) -> f64)
(define-foreign client-width
  "element" "clientWidth"
  (ref null extern) -> f64)
(define-foreign client-height
  "element" "clientHeight"
  (ref null extern) -> f64)
(define-foreign set-scroll-top!
  "element" "setScrollTop"
  (ref null extern) f64 -> none)
(define-foreign append-child!
  "element" "appendChild"
  (ref null extern) (ref null extern) -> (ref null extern))
(define-foreign remove!
  "element" "remove"
  (ref null extern) -> none)
(define-foreign replace-with!
  "element" "replaceWith"
  (ref null extern) (ref null extern) -> none)
(define-foreign set-attribute!
  "element" "setAttribute"
  (ref null extern) (ref string) (ref string) -> none)
(define-foreign remove-attribute!
  "element" "removeAttribute"
  (ref null extern) (ref string) -> none)
(define-foreign add-event-listener!
  "element" "addEventListener"
  (ref null extern) (ref string) (ref null extern) -> none)
(define-foreign remove-event-listener!
  "element" "removeEventListener"
  (ref null extern) (ref string) (ref null extern) -> none)
(define-foreign set-style!
  "element" "setStyle"
  (ref null extern) (ref string) (ref string) -> none)
(define-foreign focus-element!
  "element" "focus"
  (ref null extern) -> none)

(define-foreign current-node
  "treeWalker" "currentNode"
  (ref null extern) -> (ref null extern))
(define-foreign set-current-node!
  "treeWalker" "setCurrentNode"
  (ref null extern) (ref null extern) -> (ref null extern))
(define-foreign next-node!
  "treeWalker" "nextNode"
  (ref null extern) -> (ref null extern))
(define-foreign first-child!
  "treeWalker" "firstChild"
  (ref null extern) -> (ref null extern))
(define-foreign next-sibling!
  "treeWalker" "nextSibling"
  (ref null extern) -> (ref null extern))

;; (The old "ai"/"chat" FFI — a direct OpenRouter XHR with a client-held key —
;; is gone. AI now flows through the gateway lobby: the evaluator suspends at
;; (ai …) via `ai-request` and the resumer below fulfils it over OCapN → key-pool
;; → nano-gpt/TEE. No client key, no direct provider call.)

(define-foreign url-param-get
  "urlParams" "get"
  (ref string) -> (ref string))

(define-foreign url-param-gateway-sref
  "urlParams" "gatewaySref"
  -> (ref string))

;; Universal Commune identity, fetched from /universal-commune.json
;; at page load by repl.js's discoverUcIdentity(). Empty string when
;; the endpoint returned 404 / hasn't loaded yet — the seed flow
;; treats that as "nothing to add".
(define-foreign url-param-uc-aid
  "urlParams" "ucAid"
  -> (ref string))

(define-foreign url-param-uc-oobi
  "urlParams" "ucOobi"
  -> (ref string))

(define-foreign get-location-origin
  "location" "getOrigin"
  -> (ref string))

(define-foreign get-location-hash
  "location" "getHash"
  -> (ref string))

(define-foreign set-location-hash!
  "location" "setHash"
  (ref string) -> none)

(define-foreign event-target-value
  "events" "targetValue"
  (ref null extern) -> (ref string))

(define-foreign event-client-y
  "events" "clientY"
  (ref null extern) -> f64)

(define-foreign event-client-x
  "events" "clientX"
  (ref null extern) -> f64)

(define-foreign event-pointer-id
  "events" "pointerId"
  (ref null extern) -> f64)

(define-foreign event-delta-y
  "events" "deltaY"
  (ref null extern) -> f64)

;;; ── OCapN bridge FFI ────────────────────────────────────────────────────────
;;; Register Scheme callbacks with JS for transcription/express.
(define-foreign ocapn-set-transcribe-callback!
  "ocapn" "setTranscribeCallback"
  (ref extern) -> none)
(define-foreign ocapn-call-callback!
  "ocapn" "callCallback"
  (ref extern) (ref string) -> none)
(define-foreign ocapn-set-express-callback!
  "ocapn" "setExpressCallback"
  (ref extern) -> none)

;;; ── Reticulum FFI ──────────────────────────────────────────────────────────
;;; Browser Reticulum identity via rns-wasm (Rust compiled to WASM).
;;; Each browser gets a real Reticulum destination hash, making it
;;; addressable from mesh devices (LoRa, serial, I2P) via the server bridge.

(define-foreign ret-has-identity?
  "reticulum" "hasIdentity"
  -> i32)
(define-foreign ret-dest-hash-hex
  "reticulum" "destHashHex"
  -> (ref string))
(define-foreign ret-dest-hash
  "reticulum" "destHash"
  -> (ref extern))
(define-foreign ret-public-key
  "reticulum" "publicKey"
  -> (ref extern))
(define-foreign ret-sign
  "reticulum" "sign"
  (ref extern) -> (ref extern))
(define-foreign ret-verify
  "reticulum" "verify"
  (ref extern) (ref extern) -> i32)
;; NOTE: rns identity encrypt/decrypt are deliberately NOT bound here.
;; They were declared-but-never-called for a long time; the at-rest blob
;; crypto uses the `vault` group (AES-GCM under a bran-derived key) so it
;; does not depend on rns-wasm having loaded. `ret-decrypt-hex` below is
;; the one live use — inbound mesh messages.
(define-foreign ret-load-from-seed
  "reticulum" "loadFromSeed"
  (ref extern) -> i32)
(define-foreign ret-revert-to-anonymous
  "reticulum" "revertToAnonymous"
  -> none)
(define-foreign ret-public-key-hex
  "reticulum" "publicKeyHex"
  -> (ref string))
;; Signed announce packet for the bound identity, hex ("" when no
;; identity). The gateway relay-announces it after verifying against
;; the persona's KEL-anchored pubkey.
(define-foreign ret-pack-announce-hex
  "reticulum" "packAnnounceHex"
  -> (ref string))
(define-foreign ret-pack-announce-hex-for
  "reticulum" "packAnnounceHexFor"
  (ref string) (ref string) -> (ref string))
(define-foreign ret-lxmf-dest-hash-hex
  "reticulum" "lxmfDestHashHex"
  -> (ref string))
(define-foreign ret-decrypt-hex
  "reticulum" "decryptHex"
  (ref string) -> (ref string))
(define-foreign ret-lxmf-field
  "reticulum" "lxmfField"
  (ref string) (ref string) -> (ref string))
(define-foreign ret-lxmf-verify-hex
  "reticulum" "lxmfVerifyHex"
  (ref string) (ref string) -> i32)
(define-foreign ret-lxmf-pack-packet-hex
  "reticulum" "lxmfPackPacketHex"
  (ref string) (ref string) (ref string) -> (ref string))

;;; ── WebRTC FFI ─────────────────────────────────────────────────────────────
;;; Peer-to-peer DataChannel connections between browsers.
(define-foreign rtc-create-peer-connection
  "webRTC" "createPeerConnection"
  (ref string) -> (ref extern))
;; ── walkie audio: tracks on the netlayer's existing peer connections ──
(define-foreign rtc-mic-get      "webRTC" "micGet"       (ref extern) -> none)
(define-foreign rtc-mic-enabled  "webRTC" "micEnabled"   i32 -> none)
(define-foreign rtc-add-mic      "webRTC" "addMic"       (ref extern) -> none)
(define-foreign rtc-on-remote-audio "webRTC" "onRemoteAudio"
  (ref extern) (ref string) -> none)
(define-foreign rtc-drop-audio   "webRTC" "dropAudio"    (ref string) -> none)
(define-foreign rtc-create-data-channel
  "webRTC" "createDataChannel"
  (ref extern) (ref string) -> (ref extern))
(define-foreign rtc-create-offer
  "webRTC" "createOffer"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-create-answer
  "webRTC" "createAnswer"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-set-remote-description
  "webRTC" "setRemoteDescription"
  (ref extern) (ref string) -> none)
(define-foreign rtc-add-ice-candidate
  "webRTC" "addIceCandidate"
  (ref extern) (ref string) -> none)
(define-foreign rtc-on-ice-candidate
  "webRTC" "onIceCandidate"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-on-data-channel
  "webRTC" "onDataChannel"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-on-open
  "webRTC" "onOpen"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-on-message
  "webRTC" "onMessage"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-on-close
  "webRTC" "onClose"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-send
  "webRTC" "send"
  (ref extern) (ref extern) -> none)
(define-foreign rtc-close
  "webRTC" "close"
  (ref extern) -> none)
(define-foreign rtc-close-pc
  "webRTC" "closePc"
  (ref extern) -> none)

;;; ── localStorage FFI (for org index persistence) ─────────────────────────
(define-foreign ls-get-item
  "localStorage" "getItem"
  (ref string) -> (ref null string))
(define-foreign ls-set-item
  "localStorage" "setItem"
  (ref string) (ref string) -> none)
(define-foreign ls-remove-item
  "localStorage" "removeItem"
  (ref string) -> none)

;;; ── Clipboard FFI ─────────────────────────────────────────────────────────
(define-foreign clipboard-write!
  "clipboard" "writeText"
  (ref string) -> none)

;;; ── File download FFI ────────────────────────────────────────────────────
(define-foreign download-file
  "file" "download"
  (ref string) (ref string) (ref string) -> none)

;;; ── Key pair persistence FFI ──────────────────────────────────────────────
;;; saveKeyPair: fire-and-forget (async export in JS background)
;;; getPreloadedKeyPair: synchronous (keys pre-loaded by JS before WASM starts)
(define-foreign save-key-pair
  "crypto" "saveKeyPair"
  (ref string) (ref extern) -> none)
(define-foreign get-preloaded-key-pair
  "crypto" "getPreloadedKeyPair"
  (ref string) -> (ref null extern))
(define-foreign %has-preloaded-key-pair
  "crypto" "hasPreloadedKeyPair"
  (ref string) -> i32)
(define (has-preloaded-key-pair? name) (= (%has-preloaded-key-pair name) 1))
(define-foreign delete-key-pair
  "crypto" "deleteKeyPair"
  (ref string) -> none)
;;; Crypto key generation — replaces (goblins utils crypto) which can't compile in Hoot
(define-foreign generate-key-pair
  "crypto" "generateEd25519KeyPair"
  -> (ref extern))
(define-foreign key-pair->public-key
  "crypto" "keyPairPublicKey"
  (ref extern) -> (ref extern))
(define-foreign key-pair->private-key
  "crypto" "keyPairPrivateKey"
  (ref extern) -> (ref extern))
(define-foreign export-key-raw
  "crypto" "exportKey"
  (ref extern) -> (ref extern))

;;; Terminal — xterm.js FFI
(define-foreign term-create
  "terminal" "create"
  (ref null extern) -> (ref null extern))
(define-foreign term-on-data!
  "terminal" "onData"
  (ref null extern) (ref extern) -> none)
(define-foreign term-write!
  "terminal" "write"
  (ref null extern) (ref string) -> none)
(define-foreign term-cols
  "terminal" "getCols"
  (ref null extern) -> i32)
(define-foreign term-rows
  "terminal" "getRows"
  (ref null extern) -> i32)
(define-foreign term-dispose!
  "terminal" "dispose"
  (ref null extern) -> none)
(define-foreign term-fit!
  "terminal" "fit"
  (ref null extern) -> none)

;;; Time FFI — Date.now() returns milliseconds since epoch
(define-foreign date-now
  "time" "now"
  -> f64)

;;; ISO-8601 now with microsecond precision + explicit offset — the KERI
;;; `dt` shape (signify-portable stays clock-free; callers supply dt).
(define-foreign time-iso-now
  "time" "isoNow"
  -> (ref string))

;;; Window timers — setTimeout / setInterval FFI
(define-foreign window-set-timeout
  "window" "setTimeout"
  (ref extern) i32 -> i32)
(define-foreign window-set-interval
  "window" "setInterval"
  (ref extern) i32 -> i32)
(define-foreign window-clear-timeout
  "window" "clearTimeout"
  i32 -> none)
(define-foreign window-clear-interval
  "window" "clearInterval"
  i32 -> none)
(define-foreign window-on-resize
  "window" "onResize"
  (ref extern) -> none)

;;; Notifications — OS + in-app
(define-foreign notif-request-permission!
  "notifications" "requestPermission"
  -> (ref string))
(define-foreign notif-has-permission
  "notifications" "hasPermission"
  -> (ref string))
(define-foreign notif-show!
  "notifications" "show"
  (ref string) (ref string) (ref string) (ref string) -> none)
(define-foreign notif-page-visible?
  "notifications" "isPageVisible"
  -> i32)

;;; Push subscription FFI (async via callbacks)
(define-foreign %push-subscribe!
  "notifications" "subscribePush"
  (ref string) (ref extern) -> none)
(define-foreign %push-get-subscription
  "notifications" "getSubscription"
  (ref extern) -> none)

;;; Visibility — heartbeat triggers
(define-foreign on-visibility-change!
  "visibility" "onVisibilityChange"
  (ref extern) -> none)
(define-foreign on-online!
  "visibility" "onOnline"
  (ref extern) -> none)

;;; Voice-to-text — Web Speech API
(define-foreign %speech-supported?
  "speech" "isSupported"
  -> i32)
(define (speech-supported?) (= (%speech-supported?) 1))
(define-foreign start-listening!
  "speech" "startListening"
  (ref extern) (ref extern) -> none)
(define-foreign stop-listening!
  "speech" "stopListening"
  -> none)
(define-foreign set-express-mode!
  "speech" "setExpressMode"
  i32 -> none)
(define-foreign express-nl!
  "speech" "expressNL"
  (ref string) (ref extern) -> none)

;; ── Geolocation bridge (browser/repl.js) — live-location sharing ─────────────
;; getCurrent/watchStart take a callback invoked with (lat lon) as f64; the
;; planner only ever stores the nearest NAMED place (set-position-latlon snaps).
(define-foreign geo-get-current
  "geolocation" "getCurrent"
  (ref extern) -> none)
(define-foreign geo-watch-start
  "geolocation" "watchStart"
  (ref extern) -> i32)
(define-foreign geo-watch-stop
  "geolocation" "watchStop"
  i32 -> none)

;; ── MapLibre GL bridge — imperative, defined in browser/repl.js. ─────────────
(define-foreign %map-create
  "map" "create"
  (ref null extern) (ref string) f64 f64 f64 i32 -> (ref null extern))
(define-foreign %map-remove
  "map" "remove"
  (ref null extern) -> none)
(define-foreign %map-resize
  "map" "resize"
  (ref null extern) -> none)
(define-foreign %map-set-pitch
  "map" "setPitch"
  (ref null extern) f64 -> none)
(define-foreign %map-set-center
  "map" "setCenter"
  (ref null extern) f64 f64 -> none)
(define-foreign %map-set-zoom
  "map" "setZoom"
  (ref null extern) f64 -> none)
(define-foreign %map-set-projection
  "map" "setProjection"
  (ref null extern) (ref string) -> none)
(define-foreign %map-make-marker
  "map" "makeMarker"
  (ref null extern) (ref null extern) f64 f64 -> (ref null extern))
(define-foreign %map-marker-remove
  "map" "markerRemove"
  (ref null extern) -> none)
(define-foreign %map-fit-bounds
  "map" "fitBounds"
  (ref null extern) f64 f64 f64 f64 i32 -> none)
(define-foreign %map-on
  "map" "on"
  (ref null extern) (ref string) (ref extern) -> none)
(define-foreign %map-get-zoom
  "map" "getZoom"
  (ref null extern) -> f64)

;;; ── Routing FFI (serve-static /route → local Valhalla) ──────────────────────
;;; %map-draw-route accepts either a bare coords array or the full routing
;;; result JSON (it reads .coordinates), so Scheme pipes the fetch result
;;; straight through — no JSON parsing on the Hoot side.
(define-foreign %map-draw-route
  "map" "drawRoute"
  (ref null extern) (ref string) (ref string) (ref string) i32 -> none)
(define-foreign %map-clear-route
  "map" "clearRoute"
  (ref null extern) (ref string) -> none)
;; routing.fetch(fromLat,fromLng,toLat,toLng,profile,via,cb) — cb receives
;; the normalised result as a JSON string (engine/coordinates/maneuvers/…).
(define-foreign %routing-fetch
  "routing" "fetch"
  f64 f64 f64 f64 (ref string) (ref string) (ref extern) -> none)
;; GET url as text — cb(body) on 2xx, cb("") on failure. Used to fetch
;; a contact's /oobi/{aid} body for mesh-endpoint resolution.
(define-foreign %oobi-fetch-text
  "oobiFetch" "fetchText"
  (ref string) (ref extern) -> none)
;; cb("lat,lng") on a geolocation fix, cb("") on denial/timeout.
(define-foreign %routing-locate
  "routing" "locate"
  (ref extern) -> none)
(define-foreign %map-get-center
  "map" "getCenter"
  (ref null extern) -> (ref string))
;; Display helpers — return human strings so Hoot never parses JSON.
(define-foreign %route-summary-line
  "routing" "summaryLine"
  (ref string) -> (ref string))
(define-foreign %route-maneuvers-text
  "routing" "maneuversText"
  (ref string) -> (ref string))
(define-foreign %route-bounds
  "routing" "bounds"
  (ref string) -> (ref string))
;; UI word → Valhalla costing — THE one mapping, owned by repl.js.
(define-foreign %route-costing-of
  "routing" "costingOf"
  (ref string) -> (ref string))
;; Trace: collect the journey as actually walked/ridden (geolocation watch),
;; map-match it on arrival (same-origin /trace → Valhalla trace_route).
(define-foreign %routing-trace-start
  "routing" "traceStart"
  -> none)
(define-foreign %routing-trace-stop
  "routing" "traceStop"
  -> none)
(define-foreign %routing-trace-elapsed
  "routing" "traceElapsedMin"
  -> f64)
(define-foreign %routing-trace-match
  "routing" "traceMatch"
  (ref string) (ref extern) -> none)

(define procedure->external/cached
  (let ((cache (make-hashtable)))
    (lambda (proc)
      (or (hashtable-ref cache proc)
          (let ((f (procedure->external proc)))
            (hashtable-set! cache proc f)
            f)))))

(define (add-event-listener!/wrap elem name proc)
  (add-event-listener! elem name (procedure->external/cached proc)))
(define (remove-event-listener!/wrap elem name proc)
  (remove-event-listener! elem name (procedure->external/cached proc)))

(define (set-attribute!* elem name val)
  (if (string=? name "checked")
      ;; Special case for input 'checked' attribute.  Instead of
      ;; setting an attribute, we set the property.  It's a hack,
      ;; but fine for this little demo.
      (set-element-checked! elem (if val 1 0))
      (set-attribute! elem name val)))

;;; ── SXML Composition Guide ─────────────────────────────────────────────
;;;
;;; The entire UI is SXML — S-expression HTML. Every DOM element is a list:
;;;
;;;   "hello"                              → text node
;;;   (div "hello")                        → <div>hello</div>
;;;   (div (@ (class "red")) "hello")      → <div class="red">hello</div>
;;;   (span (@ (click ,handler)) "go")     → clickable span
;;;   (input (@ (id "x") (type "text")))   → text input
;;;
;;; Event handlers are Scheme procedures attached as attributes:
;;;   (click ,(lambda (e) ...))            → click handler
;;;   (keydown ,(lambda (e) ...))          → key handler
;;;   (input ,(lambda (e) ...))            → input change handler
;;;
;;; Conditional children — use ,@ with if:
;;;   ,@(if show? (list `(span "visible")) '())
;;;
;;; Dynamic lists — use ,@ with map:
;;;   ,@(map (lambda (item) `(li ,item)) items)
;;;
;;; VDOM constraint: the virtual DOM diffs children by position, not key.
;;; Variable-length lists (like log entries) should NOT be followed by
;;; fixed elements as siblings within the same parent. Instead, separate
;;; them into sibling containers (see render-repl for the canonical pattern).
;;;
;;; To render custom interactive elements in the REPL log:
;;;   (log-append! `(div (input (@ (id "my-input")))
;;;                      (span (@ (click ,(lambda (e)
;;;                                         (display (element-value
;;;                                                    (get-element-by-id "my-input"))))))
;;;                            "submit")))

(define (attr-value? x)
  (or (string? x) (boolean? x)))

(define *svg-ns* "http://www.w3.org/2000/svg")
(define *svg-tags*
  '(svg g path circle rect line polyline polygon text defs marker title
    ellipse use clipPath mask pattern image foreignObject
    linearGradient radialGradient stop tspan textPath))

(define (svg-tag? tag)
  (memq tag *svg-tags*))

;; Track whether we're inside an SVG subtree for nested element creation.
(define *in-svg* #f)

(define (sxml->dom exp)
  (match exp
    ((? string? str)
     (make-text-node str))
    (((? symbol? tag) . body)
     (let* ((entering-svg (and (not *in-svg*) (eq? tag 'svg)))
            (use-ns (or *in-svg* (eq? tag 'svg)))
            (elem (if use-ns
                      (make-element-ns *svg-ns* (symbol->string tag))
                      (make-element (symbol->string tag)))))
       (define (add-children children)
         (let ((prev-svg *in-svg*))
           (when entering-svg (set! *in-svg* #t))
           (for-each (lambda (child)
                       (append-child! elem (sxml->dom child)))
                     children)
           (set! *in-svg* prev-svg)))
       (match body
         ((('@ . attrs) . children)
          (for-each (lambda (attr)
                      (match attr
                        (((? symbol? name) (? attr-value? val))
                         (set-attribute!* elem
                                          (symbol->string name)
                                          val))
                        (((? symbol? name) (? procedure? proc))
                         (let ((name* (symbol->string name)))
                           (add-event-listener!/wrap elem name* proc)))))
                    attrs)
          (add-children children))
         (children (add-children children)))
       elem))))

(define (virtual-dom-render root old new)
  (define (attrs+children exp)
    (match exp
      ((('@ . attrs) . children)
       (values attrs children))
      (children
       (values '() children))))
  (define (find-attr attrs name)
    (match attrs
      (() #f)
      ((attr . rest)
       (match attr
         ((name* val)
          (if (eq? name name*)
              val
              (find-attr rest name)))))))
  (define (update-attrs node old-attrs new-attrs)
    (for-each
     (lambda (attr)
       (match attr
         ((name val)
          (let ((name-str (symbol->string name)))
            (match (find-attr old-attrs name)
              ;; No existing attr/listener, add new one.
              (#f
               (match val
                 ((? attr-value?)
                  (set-attribute!* node name-str val))
                 ((? procedure?)
                  (add-event-listener!/wrap node name-str val))))
              ;; Replace old attr or listener with new.
              (old-val
               (match val
                 ((? attr-value?)
                  (unless (equal? old-val val)
                    (set-attribute!* node name-str val)))
                 ((? procedure?)
                  (unless (eq? old-val val)
                    (remove-event-listener!/wrap node name-str old-val)
                    (add-event-listener!/wrap node name-str val))))))))))
     new-attrs)
    ;; Delete old attrs that aren't in new.
    (for-each
     (lambda (attr)
       (match attr
         ((name val)
          (let ((name-str (symbol->string name)))
            (match (find-attr new-attrs name)
              (#f
               (match val
                 ((? attr-value?)
                  (remove-attribute! node name-str))
                 ((? procedure?)
                  (remove-event-listener!/wrap node name-str val))))
              (_ #t))))))
     old-attrs))
  (let ((walker (make-tree-walker root)))
    (first-child! walker)
    (let loop ((parent root)
               (old old)
               (new new))
      (match old
        (#f
         ;; It's the first render, so clear out whatever might be
         ;; in the actual DOM and render the entire tree.  No
         ;; diffing necessary.
         (let loop ((node (current-node walker)))
           (unless (external-null? node)
             (let ((next (next-sibling! walker)))
               (remove! node)
               (loop next))))
         (append-child! parent (sxml->dom new)))
        ((? string?)
         ;; Replace text node with either a new text node if the
         ;; text has changed, or an element subtree if the text
         ;; has been replaced by an element.
         (unless (and (string? new) (string=? old new))
           (let ((new-node (sxml->dom new)))
             (replace-with! (current-node walker) new-node)
             (set-current-node! walker new-node))))
        (((? symbol? old-tag) . old-rest)
         (let-values (((old-attrs old-children)
                       (attrs+children old-rest)))
           (match new
             ((? string?)
              ;; Old node was an element, but the new node is a
              ;; string, so replace the element subtree with a
              ;; text node.
              (let ((new-text (make-text-node new)))
                (replace-with! (current-node walker) new-text)
                (set-current-node! walker new-text)))
             (((? symbol? new-tag) . new-rest)
              (let-values (((new-attrs new-children)
                            (attrs+children new-rest)))
                (cond
                 ;; The element tag is the same, so modify the
                 ;; inner contents of the element if necessary.
                 ((eq? old-tag new-tag)
                  (let ((parent (current-node walker))
                        (prev-svg *in-svg*))
                    (when (svg-tag? old-tag) (set! *in-svg* #t))
                    (update-attrs parent old-attrs new-attrs)
                    (first-child! walker)
                    (let child-loop ((old old-children)
                                     (new new-children))
                      (match old
                        (()
                         ;; The old child list is empty, so
                         ;; diffing stops here.  All remaining
                         ;; children in the new list are fresh
                         ;; elements that need to be added.
                         (for-each
                          (lambda (new)
                            (append-child! parent (sxml->dom new)))
                          new))
                        ((old-child . old-rest)
                         (match new
                           ;; The new child list is empty, so any
                           ;; remaining children in the old child
                           ;; list need to be removed, including
                           ;; the current one.
                           (()
                            (let rem-loop ((node (current-node walker)))
                              (unless (external-null? node)
                                (let ((next (next-sibling! walker)))
                                  (remove! node)
                                  (rem-loop next)))))
                           ;; Recursively diff old and new child
                           ;; elements.
                           ((new-child . new-rest)
                            (loop parent old-child new-child)
                            (next-sibling! walker)
                            (child-loop old-rest new-rest))))))
                    (set-current-node! walker parent)
                    (set! *in-svg* prev-svg)))
                 ;; New element tag is different than the old
                 ;; one, so replace the entire element subtree.
                 (else
                  (let ((new-node (sxml->dom new)))
                    (replace-with! (current-node walker) new-node)
                    (set-current-node! walker new-node)))))))))))))

(define *current-vdom* #f)

(define (vdom-root-attrs vdom)
  "Extract the (@ ...) attribute form from a VDOM root, or #f."
  (and (pair? vdom)
       (pair? (cdr vdom))
       (let ((second (cadr vdom)))
         (and (pair? second) (eq? (car second) '@) second))))

;; render-now! does the actual VDOM diff. Never call this directly from
;; inside a vat's turn — use refresh! (which auto-defers when needed).
(define (render-now!)
  (let* ((new-vdom (render))
         ;; Force full re-render when root structure changes shape
         ;; (e.g. outer↔ide mode switch). Positional diff can't
         ;; reconcile fundamentally different child layouts.
         (old (if (and *current-vdom*
                       (not (equal? (vdom-root-attrs *current-vdom*)
                                    (vdom-root-attrs new-vdom))))
                  #f
                  *current-vdom*)))
    (set! *in-svg* #f)              ;; reset before each diff
    (set! *current-vdom* new-vdom)  ;; set BEFORE diff — if diff crashes, next render diffs correctly
    (virtual-dom-render (document-body) old new-vdom)))

;; Cached external callback for setTimeout — avoids re-allocating the
;; FFI wrapper on every deferred refresh.
(define *deferred-refresh-cb*
  (procedure->external (lambda () (render-now!))))

;; refresh! is the universal "redraw the UI" entry point. It auto-detects
;; whether it's being called from inside a vat's turn (via Goblins'
;; has-syscaller?) and defers the render to a fresh JS tick if so.
;;
;; Why: render touches every org's vat via (with-vat vat ...). When called
;; from inside another vat (e.g. an `on` handler running in *ocapn-vat*),
;; (with-vat <other-vat> ...) returns a promise instead of a value, and
;; that promise lands inside the SXML tree where the VDOM diff at line
;; ~561 chokes on it ("value failed to match" / #<local-promise>).
;; Deferring via setTimeout(0) escapes the vat turn, so the cross-vat
;; with-vat calls execute synchronously and return real values.
;;
;; Callers don't need to think about this — just call (refresh!) from
;; anywhere (DOM event handlers, vat methods, on-handler callbacks).
(define (refresh!)
  (if (has-syscaller?)
      (window-set-timeout *deferred-refresh-cb* 0)
      (render-now!)))

;; Wrap macros as procedures for base-bindings (required by Hoot)
(define %+ +) (define %- -) (define %* *) (define %/ /)
(define %> >) (define %< <) (define %= =) (define %>= >=) (define %<= <=)
(define %abs abs) (define %max max) (define %min min)
(define %modulo modulo) (define %remainder remainder) (define %expt expt)
(define %zero? zero?) (define %positive? positive?) (define %negative? negative?)
(define %even? even?) (define %odd? odd?)
(define %eqv? eqv?) (define %char? char?)
(define %write write)
(define %string=? string=?) (define %string<? string<?) (define %string>? string>?)
(define %string-ref string-ref)
(define %sqrt sqrt) (define %floor floor) (define %ceiling ceiling) (define %round round)
(define %cadr cadr) (define %caddr caddr) (define %cddr cddr) (define %caar caar) (define %cdar cdar)
(define (%filter pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (%filter pred (cdr lst))))
        (else (%filter pred (cdr lst)))))
(define (%fold proc init lst)
  (if (null? lst) init
      (%fold proc (proc (car lst) init) (cdr lst))))
(define (%find pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) (car lst))
        (else (%find pred (cdr lst)))))

;; Split into small chunks to avoid Hoot quasiquote size limits
(define base-bindings
  (append
   `((+ . ,%+) (- . ,%-)  (* . ,%*) (/ . ,%/)
     (> . ,%>) (< . ,%<)  (= . ,%=) (>= . ,%>=) (<= . ,%<=)
     (abs . ,%abs) (max . ,%max) (min . ,%min)
     (modulo . ,%modulo) (remainder . ,%remainder) (expt . ,%expt))
   `((sqrt . ,%sqrt) (floor . ,%floor) (ceiling . ,%ceiling) (round . ,%round)
     (not . ,not) (equal? . ,equal?) (eq? . ,eq?) (eqv? . ,%eqv?)
     (cons . ,cons) (car . ,car) (cdr . ,cdr)
     (cadr . ,%cadr) (caddr . ,%caddr) (cddr . ,%cddr) (caar . ,%caar) (cdar . ,%cdar))
   `((list . ,list) (append . ,append) (reverse . ,reverse) (length . ,length)
     (map . ,map) (for-each . ,for-each) (filter . ,%filter) (fold . ,%fold)
     (assoc . ,assoc) (member . ,member) (apply . ,apply))
   `((null? . ,null?) (pair? . ,pair?) (list? . ,list?)
     (number? . ,number?) (string? . ,string?) (symbol? . ,symbol?)
     (procedure? . ,procedure?) (boolean? . ,boolean?) (char? . ,%char?)
     (zero? . ,%zero?) (positive? . ,%positive?) (negative? . ,%negative?)
     (even? . ,%even?) (odd? . ,%odd?))
   `((string-append . ,string-append) (string-length . ,string-length)
     (substring . ,substring) (string-ref . ,%string-ref)
     (string=? . ,%string=?) (string<? . ,%string<?) (string>? . ,%string>?)
     (string->symbol . ,string->symbol) (symbol->string . ,symbol->string)
     (string->number . ,string->number) (number->string . ,number->string))
   `((display . ,display) (newline . ,newline) (write . ,%write)
     (void . ,(lambda () (if #f #f))))
   ;; AI keys + model live server-side now (the gateway key-pool). These remain
   ;; only to answer the old muscle-memory with a helpful note instead of an
   ;; "unbound variable" error.
   `((set-api-key! . ,(lambda _ "AI is gateway-served now — no client API key is needed."))
     (set-ai-model! . ,(lambda _ "Model selection is gateway-side now.")))
   ;; miniKanren — relational logic programming
   ;; fresh, conde, run*, run are special forms in the evaluator
   `((== . ,==) (succeed . ,succeed) (fail . ,fail)
     (appendo . ,appendo) (membero . ,membero))
   ;; System self-description — the org can query its own capabilities
   `((system-forms . ,(list
      '(modify! name value) '(enact! validator-expr)
      '(rollback! version) '(defexpressor name key)
      '(as sealer body) '(ai prompt) '(ai-eval prompt)
      '(ask "natural language query")
      '(run* (q) goals ...) '(fresh (vars ...) goals ...)
      '(conde (goals ...) ...) '(== a b)
      '(membero x lst) '(appendo l r out)
      '(show-history) '(show-expressors) '(public-key))))))

;;; ── AI via the gateway (no client key/model state) ────────────────────────
;;; The evaluator's (ai …)/(ai-eval …) forms suspend at their completion via
;;; `ai-request` (see gplay.scm). This resumer fulfils that request over OCapN:
;;; it runs in the ORG'S OWN VAT (the abort happened there), sends the completion
;;; to the gateway lobby, and resumes the captured continuation `k` from the
;;; `on` callback — which Goblins runs in that SAME vat, so there is no cross-vat
;;; resume. The seat's session routes to the key-pool → nano-gpt/TEE within
;;; its budget. `k` returns via the sink installed by `evaluate-to-sink`, so
;;; the REPL shows the result when it arrives. Model #f lets the gateway pick
;;; its default (the TEE model).
(set-ai-resumer!
 (lambda (k system user model)
   (cond
    (*keri-session*
     (on (<- *keri-session* 'ai-complete system user (if (string? model) model #f))
         (lambda (completion) (k (if (string? completion) completion "")))
         #:catch (lambda _ (k "(the gateway could not answer)"))))
    (*lobby* (k "(sign in to ask the commons' AI — it answers from a seat)"))
    (else (k "(no gateway connection — AI is unavailable offline)")))
   #f))                                 ; immediate return; real result via the sink

;;; ── String utilities (Hoot lacks string-prefix?/suffix?/trim-both) ──────

(define (%starts-with? str prefix)
  (and (>= (string-length str) (string-length prefix))
       (string=? (substring str 0 (string-length prefix)) prefix)))

(define (%ends-with? str suffix)
  (let ((slen (string-length str)) (xlen (string-length suffix)))
    (and (>= slen xlen)
         (string=? (substring str (- slen xlen) slen) suffix))))

(define (%trim str)
  (let* ((len (string-length str))
         (start (let lp ((i 0))
                  (if (and (< i len) (memv (string-ref str i) '(#\space #\newline #\tab #\return)))
                      (lp (+ i 1)) i)))
         (end (let lp ((i (- len 1)))
                (if (and (>= i start) (memv (string-ref str i) '(#\space #\newline #\tab #\return)))
                    (lp (- i 1)) (+ i 1)))))
    (substring str start end)))

;;; ── AI context formatter ────────────────────────────────────────────────

(define (format-binding pair ref)
  (let ((name (car pair)) (val (cdr pair)))
    (string-append "  " (symbol->string name) " = "
      (cond
        ((procedure? val) (string-append "<procedure " (symbol->string name) ">"))
        (($ ref 'expressor? val)
         (string-append "<expressor " (symbol->string (or ($ ref 'expressor-name val) '?)) ">"))
        (else (call-with-output-string (lambda (p) (%write val p))))))))

(define (format-history-entry entry ref)
  (string-append
    "  v" (number->string (car entry))
    " [" (symbol->string (or ($ ref 'expressor-name (cadr entry)) '?))
    "]: " (call-with-output-string (lambda (p) (%write (caddr entry) p)))))

(define (%join-lines lst)
  (if (null? lst) ""
      (let lp ((rest (cdr lst)) (acc (car lst)))
        (if (null? rest) acc (lp (cdr rest) (string-append acc "\n" (car rest)))))))

(define (format-org-state ref)
  "Org state without preamble — used for per-expressor prompt override."
  (let* ((bindings ($ ref 'bindings))
         (history ($ ref 'history))
         (exp-name (or ($ ref 'expressor-name ($ ref 'current-expressor)) '?))
         (recent (let ((h (reverse history)))
                   (if (> (length h) 10) (list-tail h (- (length h) 10)) h))))
    (string-append
      "Current expressor (identity): " (symbol->string exp-name) "\n\n"
      "Bindings:\n" (%join-lines (map (lambda (b) (format-binding b ref)) bindings))
      "\n\nRecent history:\n" (%join-lines (map (lambda (e) (format-history-entry e ref)) recent))
      "\n\nAvailable special forms:\n"
      "  (modify! 'name value)          create/update a governed binding\n"
      "  (enact! validator-expr)        install a new validator rule\n"
      "  (rollback! version)            revert to a prior state\n"
      "  (defexpressor name key)        create an identity\n"
      "  (as sealer body)               act under an identity\n"
      "  (ai prompt)                    ask AI\n"
      "  (ai-eval prompt)               AI generates + evaluates code\n"
      "\n"
      "miniKanren relational queries:\n"
      "  (run* (q) goal ...)            find all values of q satisfying goals\n"
      "  (fresh (x y) goal ...)         introduce logic variables\n"
      "  (conde (g ...) (g ...) ...)    disjunction (OR)\n"
      "  (== a b)                       unification\n"
      "  (membero x lst)               x is a member of lst\n"
      "  (appendo l r out)             out is l appended to r\n"
      "\n"
      "The org's bindings are queryable as data. Bindings stored via modify!\n"
      "can include SXML (S-expression HTML) for rendering UI widgets.\n"
      "Example: (modify! 'ui-widgets '((div \"hello world\")))\n")))

(define (format-org-context ref)
  (string-append
    "You are an AI inside playnet, a Scheme-based system for programmable organizations.\n\n"
    (format-org-state ref)))

;;; ── AI handlers ─────────────────────────────────────────────────────────

(define (strip-code-fences str)
  (let* ((s (%trim str))
         (s (cond ((%starts-with? s "```scheme") (substring s 9 (string-length s)))
                  ((%starts-with? s "```scm")    (substring s 6 (string-length s)))
                  ((%starts-with? s "```")       (substring s 3 (string-length s)))
                  (else s)))
         (s (if (%ends-with? s "```") (substring s 0 (- (string-length s) 3)) s)))
    (%trim s)))

(define (expressor-config org expressor-id key-suffix)
  "Look up a per-expressor config binding (e.g. ai-gov:prompt). Returns #f if not found."
  (let ((exp-name ($ org 'expressor-name expressor-id)))
    (and exp-name
         (let* ((config-key (string->symbol
                              (string-append (symbol->string exp-name)
                                             ":" (symbol->string key-suffix))))
                (entry (assq config-key ($ org 'bindings))))
           (and entry (cdr entry))))))

;; The AI handlers build the prompt, then hand the completion to `ai-request`,
;; which suspends the evaluator to the gateway resumer (above). No client key.
(define (web-ai-query prompt org expressor-id)
  (let* ((custom-prompt (expressor-config org expressor-id 'prompt))
         (custom-model  (expressor-config org expressor-id 'model))
         (system-prompt (if custom-prompt
                            (string-append custom-prompt "\n\n" (format-org-state org))
                            (format-org-context org))))
    (ai-request system-prompt prompt (if (string? custom-model) custom-model #f))))

(define (web-ai-query-and-eval prompt org expressor-id)
  (let* ((custom-prompt (expressor-config org expressor-id 'prompt))
         (custom-model  (expressor-config org expressor-id 'model))
         (ctx (string-append
               (if custom-prompt
                   (string-append custom-prompt "\n\n" (format-org-state org))
                   (format-org-context org))
               "\n\nIMPORTANT: Respond with ONLY a single valid Scheme "
               "S-expression, nothing else. No explanation, no markdown, no prose. "
               "Just the raw expression.\n\n"
               "Use (modify! 'name value) to create or update bindings.\n"
               "Use (run* (q) goals...) for relational queries over data.\n"
               "Use (fresh (x y) goals...) to introduce logic variables.\n"
               "Use (conde (g...) (g...)) for alternatives.\n"
               "Use (== a b) for unification, (membero x lst) for membership.\n"
               "Store SXML for UI: (modify! 'ui-widgets '((div \"content\")))\n"
               "\n"
               "Examples:\n"
               "  (modify! 'greeting \"hello world\")\n"
               "  (begin (modify! 'a 1) (modify! 'b 2))\n"
               "  (run* (q) (membero q '(1 2 3)))\n"))
         (response (ai-request ctx prompt (if (string? custom-model) custom-model #f))))
    (read (open-input-string (strip-code-fences response)))))

(set-ai-handler! web-ai-query)
(set-ai-eval-handler! web-ai-query-and-eval)

;;; ── Persistence registry ──────────────────────────────────────────────────
;;; Shared registry for cross-vat reference resolution (e.g. controllers).
(define *registry-vat* (spawn-vat))
(define *persistence-registry*
  (with-vat *registry-vat* (spawn ^persistence-registry)))

;;; ── Org management ────────────────────────────────────────────────────────
;;; Every org entry: (name vat ref inbox incanter key-pair refs . log)
;;; refs: ^ref-store actor holding alist of (org-name . controller)

(define *orgs* '())
(define *pending-joins* '()) ;; alist: (joiner-name target-name sub-unsealer msg-id identity)
(define *mode* 'outer)
(define *view* 'home)  ;; 'home, 'federation, 'surface, 'calendar, 'inventory, 'map, 'contacts, 'recipes, 'priorities, or 'identity

;; Surface (reproduction-labour treemap) zoom path: root → … → focus.
(define *surface-path* (list *playnet-tree*))
;; Measured pixel size of the surface frame, so the SVG fills exactly (no
;; letterbox, no stretch). Seeded with a sane default; corrected after mount.
(define *surface-w* 1500)
(define *surface-h* 820)
;; Header toggles: simple↔detailed, social↔individual, time↔priority.
(define *surface-detail?* #f)
(define *surface-individual?* #f)
(define *surface-priority?* #f)
;; axis lens (only meaningful at the federation): #f = activities, #t = categories.
(define *surface-categories?* #f)
;; sidebar mode: #f = voice/credit panels, #t = plan-history panel for the focus.
(define *surface-history?* #f)
;; When set to a leaf node, the surface shows the geographic map for that leaf's
;; offers *in place* (instead of switching to the map tab).
(define *surface-map-leaf* #f)

;;; ── Map tab state ───────────────────────────────────────────────────────────
(define *map-instance* #f)
(define *map-selected* #f)
(define *map-globe?* #t)
(define *map-show-3d?* #f)
(define *map-show-terrain?* #f)
(define *map-clustering?* #t)
(define *map-fab-open?* #f)
(define *map-search-query* "")
(define *map-search-results* '())
(define *current-org-name* #f)

;;; ── Priority tree state ────────────────────────────────────────────────────
(define *prio-tree* #f)
(define *prio-path* '())
(define *prio-current-id* #f)
(define *prio-resizing?* #f)
(define *prio-resize-start-y* 0)
(define *prio-touch-start-time* 0)
(define *prio-editing-id* #f)
(define *prio-delete-mode?* #f)

;;; ── Identity (KERI) state ──────────────────────────────────────────────────
;;; Browser-resident Signify (Phase B): keys live ONLY in this browser.
;;; *keri-secret* holds the signing keypair record for the session.
;;; On reload it's #f and the user must re-enter the bran to re-derive.
;;;
;;; Persistence: a *hint* (aid + name + email) is stored in localStorage
;;; under "pn.id.hint". It carries no secret material — losing it
;;; doesn't compromise the identity, finding it doesn't grant access.
;;; Format: "aid|name|email" (pipe-delimited; pipe is invalid in all
;;; three fields).
(define *keri-identity* #f)        ;; alist or #f if no identity created yet
(define *keri-contacts* '())       ;; list of contact alists
(define *contacts-error* #f)       ;; error string from add form, or #f
(define *contacts-adding?* #f)     ;; loading flag while resolving an OOBI
(define *keri-creating?* #f)       ;; loading flag during identity creation
(define *keri-connecting?* #f)     ;; loading flag during OOBI resolution
(define *keri-error* #f)           ;; error message string or #f
(define *keri-secret* #f)          ;; <ed25519-keypair> in memory only
(define *keri-icp-alist* #f)       ;; the ICP we built (for re-presenting)
(define *keri-sigs* #f)            ;; vector of CESR sigs over the ICP
(define *keri-unlocking?* #f)      ;; loading flag during passcode unlock
(define *keri-authenticating?* #f) ;; loading flag during auth round-trip
(define *keri-rotating?* #f)       ;; loading flag during rotation
(define *keri-recovering?* #f)     ;; loading flag during recovery
(define *keri-recover-mode?* #f)   ;; #t = show recover form instead of create
(define *keri-credentials* '())    ;; list of ACDC alists held by this AID
(define *keri-creds-loading?* #f)
(define *keri-cred-watcher* #f)    ;; browser-side actor ref for push updates
(define *keri-bran* #f)            ;; in-memory bran for rotation derivation
(define *keri-rotation-sn* 0)      ;; current rotation index (0 = inception)
(define *keri-bran-reveal* #f)     ;; bran string to show once after creation
(define *keri-show-recovery?* #f)  ;; #t = show recovery info overlay
(define *keri-show-shamir?* #f)    ;; #t = show social recovery panel
;;; *keri-session* is the ocap returned by ^lobby on successful
;;; keri-authenticate. It's bound server-side to the authenticated AID;
;;; we use it for privileged calls (rotate-aid, list-credentials,
;;; open-terminal, get-mailbox, governance cast/delegation). It's #f
;;; when not authenticated and after rotation (rotation invalidates
;;; the prior signing key the session was anchored to, so we
;;; re-authenticate with the new key on next privileged action).
(define *keri-session* #f)
;;; *identity-dropdown-open?* controls the top-right identity overlay.
;;; Identity is no longer a tab; it's a persistent button + dropdown
;;; anchored to the action bar. Recovery is a sub-mode of the dropdown
;;; (via *keri-recover-mode?*), not a separate top-level form.
(define *identity-dropdown-open?* #f)
;;; *donate-open?* toggles the Monero donation panel under the
;;; bottom button strip (Source / Public chat / Donate XMR).
(define *donate-open?* #f)
;;; *donate-trocador-loaded?* flips to #t when the iframe fires `load`.
;;; *donate-trocador-failed?* flips to #t if `load` hasn't fired within
;;; the timeout (default 8s), revealing the direct-XMR fallback.
(define *donate-trocador-loaded?* #f)
(define *donate-trocador-failed?* #f)
(define *donate-trocador-timer* 0)
;;; *identity-panel-tab* selects which sub-section is visible in the
;;; dropdown when an active identity is loaded: 'identity | 'credentials
;;; | 'connections | 'security.
(define *identity-panel-tab* 'identity)

(define %keri-id-key "pn.id.hint")

(define (split-pipe s)
  "Split S on '|' chars. Returns the list of parts."
  (let* ((n (string-length s)))
    (let loop ((i 0) (parts '()) (start 0))
      (cond
       ((>= i n)
        (reverse (cons (substring s start n) parts)))
       ((char=? #\| (string-ref s i))
        (loop (+ i 1) (cons (substring s start i) parts) (+ i 1)))
       (else
        (loop (+ i 1) parts start))))))

(define* (save-keri-identity-hint! aid name email #:optional (k0 #f))
  "Persist a non-secret hint for the current identity. Bran is NEVER
   stored; only the public AID (the icp's saidified `i`), the
   user-typed name/email, and the inception key k0 — which unlock
   compares against the bran-derived key (the E-AID itself is a SAID
   and can't be re-derived from the bran alone)."
  (ls-set-item %keri-id-key
               (string-append aid "|" name "|" email
                              (if k0 (string-append "|" k0) ""))))

(define (load-keri-identity-hint!)
  "Populate *keri-identity* from localStorage if a hint exists.
   Sets status to 'locked' since we don't have the secret in memory yet.
   3-part hints predate the E-AID handle (aid WAS k0); 4-part hints
   carry the inception key separately."
  (let ((raw (ls-get-item %keri-id-key)))
    (when (and raw (not (string=? raw "")))
      (let ((parts (split-pipe raw)))
        (when (<= 3 (length parts))
          (let ((aid   (list-ref parts 0))
                (name  (list-ref parts 1))
                (email (list-ref parts 2))
                (k0    (if (= 4 (length parts))
                           (list-ref parts 3)
                           (list-ref parts 0))))
            (set! *keri-identity*
                  `((name   . ,name)
                    (email  . ,email)
                    (prefix . ,aid)
                    (k0     . ,k0)
                    (status . "locked")
                    (witnesses-confirmed . 0)
                    (witnesses-total . 0)
                    (last-rotation . "never")
                    (next-key-ready . #t)))))))))

(define (clear-keri-identity!)
  "Forget the stored hint and the in-memory secret. Bran is also
   zeroed in case rotation kept it around for the session.
   Reverts Reticulum to the anonymous localStorage identity."
  (ls-remove-item %keri-id-key)
  (set! *keri-identity* #f)
  (set! *keri-secret* #f)
  (set! *keri-icp-alist* #f)
  (set! *keri-sigs* #f)
  (set! *keri-bran* #f)
  (set! *keri-bran-reveal* #f)
  (set! *keri-show-recovery?* #f)
  (set! *keri-show-shamir?* #f)
  (set! *keri-rotation-sn* 0)
  (set! *keri-credentials* '())
  (set! *keri-cred-watcher* #f)
  (ls-remove-item %keri-credentials-key)
  (ret-revert-to-anonymous))

;;; ── Contacts persistence ──────────────────────────────────────────────────
;;; Stored as a single localStorage entry under "pn.repl.contacts",
;;; one line per contact, fields tab-separated:
;;;   alias \t prefix \t oobi \t added-at \t note
;;; Tab is invalid in all four typed fields; note is the only free-form
;;; one and we strip tabs on write to keep parsing trivial.

(define %keri-contacts-key "pn.repl.contacts")

(define (string-strip-char s ch)
  (let* ((n (string-length s)))
    (let loop ((i 0) (out '()))
      (cond
       ((>= i n) (list->string (reverse out)))
       ((char=? (string-ref s i) ch) (loop (+ i 1) out))
       (else (loop (+ i 1) (cons (string-ref s i) out)))))))

(define (split-on s ch)
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
       ((>= i n) (reverse (cons (substring s start n) acc)))
       ((char=? (string-ref s i) ch)
        (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
       (else (loop (+ i 1) start acc))))))

(define (contact->line c)
  (let ((alias  (or (assq-ref c 'alias)  ""))
        (prefix (or (assq-ref c 'prefix) ""))
        (oobi   (or (assq-ref c 'oobi)   ""))
        (added  (or (assq-ref c 'added-at) 0))
        (note   (or (assq-ref c 'note)   "")))
    (string-append
     (string-strip-char alias #\tab) "\t"
     (string-strip-char prefix #\tab) "\t"
     (string-strip-char oobi #\tab) "\t"
     (number->string added) "\t"
     (string-strip-char note #\tab))))

(define (line->contact line)
  (let ((parts (split-on line #\tab)))
    (and (>= (length parts) 2)
         `((alias    . ,(list-ref parts 0))
           (prefix   . ,(list-ref parts 1))
           (oobi     . ,(if (>= (length parts) 3) (list-ref parts 2) ""))
           (added-at . ,(if (>= (length parts) 4)
                            (or (string->number (list-ref parts 3)) 0)
                            0))
           (note     . ,(if (>= (length parts) 5) (list-ref parts 4) ""))))))

(define (assq-ref alist key)
  (let ((p (assq key alist))) (and p (cdr p))))

(define (save-keri-contacts!)
  (let ((blob (let loop ((cs *keri-contacts*) (acc ""))
                (cond
                 ((null? cs) acc)
                 ((string=? acc "") (loop (cdr cs) (contact->line (car cs))))
                 (else (loop (cdr cs)
                             (string-append acc "\n" (contact->line (car cs)))))))))
    (ls-set-item %keri-contacts-key blob)))

(define (load-keri-contacts!)
  (let ((raw (ls-get-item %keri-contacts-key)))
    (when (and raw (not (string=? raw "")))
      (let ((lines (split-on raw #\newline)))
        (set! *keri-contacts*
              (let loop ((ls lines) (acc '()))
                (cond
                 ((null? ls) (reverse acc))
                 ((string=? (car ls) "") (loop (cdr ls) acc))
                 (else (let ((c (line->contact (car ls))))
                         (loop (cdr ls) (if c (cons c acc) acc)))))))))))

;;; ── Credential persistence (local-first) ────────────────────────────────
;;; Credentials are stored locally so the user holds their own ACDCs.
;;; The server keeps a backup copy for cross-device recovery.
;;; Sexp serialization via write/read — governance-cred alists round-trip
;;; cleanly through Hoot's write.
;;;
;;; TODO: migrate to IndexedDB for better capacity and per-credential
;;; granularity once we add an IndexedDB FFI layer.

(define %keri-credentials-key "pn.repl.credentials")

(define (save-keri-credentials!)
  (ls-set-item %keri-credentials-key
               (call-with-output-string
                 (lambda (p) (write *keri-credentials* p)))))

(define (load-keri-credentials!)
  ;; with-exception-handler, NOT catch: Hoot's catch traps
  ;; "unimplemented" AT RUNTIME — this runs at boot for any returning
  ;; authenticated user (stored credentials), so a catch here bricked
  ;; the second visit entirely (caught by the mesh e2e).
  (let ((raw (ls-get-item %keri-credentials-key)))
    (when (and raw (not (string=? raw "")))
      (set! *keri-credentials*
            (with-exception-handler
              (lambda (_exn) '())
              (lambda () (read (open-input-string raw)))
              #:unwind? #t)))))

(define (merge-credentials local-creds server-creds)
  "Union by SAID. Server's revocation status wins (it has TEL access)."
  (let ((by-said (make-hash-table)))
    (for-each (lambda (c)
                (let ((s (assq-ref c 'said)))
                  (when s (hash-set! by-said s c))))
              local-creds)
    (for-each (lambda (c)
                (let ((s (assq-ref c 'said)))
                  (when s (hash-set! by-said s c))))
              server-creds)
    (hash-fold (lambda (k v acc) (cons v acc)) '() by-said)))

;;; Seed the contacts list with the Universal Commune entry pulled
;;; from /universal-commune.json (gateway-served). Idempotent: if a
;;; contact with that AID already exists (either from a prior seed
;;; or a user-added one), no-op.
;;;
;;; Called after load-keri-contacts! so user-saved contacts take
;;; precedence; the seed only ADDS, never overwrites.
;;;
;;; Empty AID (endpoint absent or 404) → no-op. The contacts tab
;;; just starts empty, same as today.
(define (seed-universal-commune-contact!)
  (let ((aid  (url-param-uc-aid))
        (oobi (url-param-uc-oobi)))
    (when (and aid (not (string=? aid "")))
      (let ((already? (let loop ((cs *keri-contacts*))
                        (cond
                         ((null? cs) #f)
                         ((equal? aid (assq-ref (car cs) 'prefix)) #t)
                         (else (loop (cdr cs)))))))
        (unless already?
          (set! *keri-contacts*
                (cons `((alias    . "playnet (Universal Commune)")
                        (prefix   . ,aid)
                        (oobi     . ,oobi)
                        (added-at . ,(inexact->exact (floor (date-now))))
                        (note     . "auto-seeded from /universal-commune.json"))
                      *keri-contacts*))
          (save-keri-contacts!))))))

;;; ── Calendar state ──────────────────────────────────────────────────────────
(define *cal-week-start* #f)        ;; epoch-ms anchor (day-aligned); #f = compute from now
(define *cal-view-mode* '3day)      ;; 'day | '3day | 'week | 'month | 'schedule
(define *cal-user-events* '())      ;; user-created events (slot click → modal); persisted
(define *cal-derived-events* '())   ;; events derived from sample store on mutations
(define *cal-people* '())           ;; list of person alists (scope members)
(define *cal-availability* '())     ;; list of availability slot alists
(define *cal-editing-event* #f)     ;; event alist being edited, or #f
(define *cal-editing-avail* #f)     ;; #t when in availability edit mode (drag on grid)
(define *cal-avail-drag* #f)        ;; #f or drag-state alist: (mode dow slot-id start-y orig-sh orig-sm orig-eh orig-em)
(define *cal-avail-next-id* 1)      ;; auto-increment availability slot ID
(define *cal-next-id* 1)            ;; auto-increment event ID
(define *cal-selected-event* #f)    ;; event shown in detail panel (right sidebar)
(define *cal-unscheduled-intents* '()) ;; work intents within the current scope+plan
(define *cal-selected-intent* #f)   ;; intent ID selected for scheduling
;; Scope / plan / acting-as state
(define *active-scope* #f)             ;; currently selected scope id
(define *active-plan* #f)              ;; currently selected plan id (#f = all plans)
(define *acting-as* #f)         ;; currently selected member id (#f = observer)
;; Planner-service capability and snapshot cache.
;; *planner-cap* is the OCapN ref returned by (<- *lobby* 'planner).
;; *scope-list* is the cached list of scopes the cap exposes.
;; *scope-snapshot* is the latest server snapshot for the current scope+plan.
;; *cal-process-context* caches per-process flow lookups for the detail panel.
(define *planner-cap* #f)
(define *scope-list* '())     ;; ((id . X) (name . Y)) for the dropdown
(define *scope-snapshot* #f)
(define *scope-refresh-inflight?* #f)
(define *cal-process-context* '())

;;; ── Inventory tab state ─────────────────────────────────────────────────────
;;; The inventory tab piggy-backs on *active-scope* / *active-plan* / *acting-as*
;;; so switching between calendar and inventory keeps the same scope context.
;;; Selection / drill-down state is local to this tab.
(define *inv-snapshot* #f)            ;; latest inventory-snapshot reply
(define *inv-detail-cache* '())       ;; alist: rid -> resource-detail reply
(define *inv-selected-spec* #f)       ;; spec-id string or #f
(define *inv-selected-resource* #f)   ;; rid string or #f
(define *inv-breadcrumb* '())         ;; list of rid strings (drill stack, oldest first)
(define *inv-active-category* #f)     ;; category URI or #f (= All)
(define *inv-custody-expanded?* #f)   ;; history collapse toggle
(define *inv-view-mode* 'scope)          ;; 'personal or 'scope
(define *inv-refresh-inflight?* #f)
(define *vat* #f)
(define *org* #f)

;; Signup flow state
(define *signup-pending?* #f)  ;; #t while waiting for relay signup-ok/error reply

(define *sidebar-collapsed* #f)
(define *sidebar-selected-org* #f)   ;; string or #f

;;; ── Homepage state (Cycles) ─────────────────────────────────────────────
(define (make-cycle lst)
  (let ((copy (append lst '())))
    (set-cdr! (last-pair copy) copy)
    copy))

(define-syntax-rule (cycle-peek cycle) (car cycle))
(define-syntax-rule (cycle-step! cycle) (set! cycle (cdr cycle)))

(define *genre-cycle* (make-cycle '("A bottom-up game" "An adventure game" "A strategy game" "A role-playing game" "A puzzle game" "A network simulation" "A journalist investigation game" "A street busking rhythm game" "A shamanic ritual" "A mythical creature management game" "A cybernetic quest" "A post-rational media theory game" "A modular jewelry design game" "A cybersecurity challenge" "A spiritual health simulation" "A tantric bliss journey" "A care network builder" "A playful fashion design game" "A character outfit customization game" "A communal living simulation" "A portal opening game" "A ritual fasting challenge" "An exergame" "A magical potion crafting game" "An ancient artifact discovery game" "A spellbook writing game" "A divine nonchalance experience" "A mythical farm simulation" "A festival planning game" "A communal feast organization game" "A magical realist story game" "A spiritual meditation and dancing game" "A yoga and wellness game" "A post-apocalyptic bunkers survival game" "A tree house construction game" "A volcanic island exploration game" "A castle defense strategy game" "A clarification and obfuscation game" "A warp zone discovery game" "A butterfly-wing-iridescence puzzle game" "A subterranean lake adventure" "A bioluminescent slime farming game" "A secret stairway exploration game" "A magical realist narrative game" "A dark matter and nebula exploration game" "A subterranean city builder" "A train-yard management game" "A flea market treasure hunt game" "A library stacks mystery game" "A mythopoetic storytelling game" "A unicorn and narwhal sanctuary game" "A goblet and doubloon collection game" "A gremlin and pixie mischief game" "A ritualistic sauna experience" "A cauldron and potion brewing game" "A holy grail quest" "A fragrance and incense crafting game" "A fairy tale game" "A hyperstitial loom weaving game" "A mythical loom crafting game" "A spellcasting duel game" "A divine intervention and prophecy game" "A secret doors and hidden passageways game" "A digital efficiency optimization game" "A shared subscriptions management game" "A mythical creatures alliance" "A fiscal intermediary strategy game" "An offworld game" "A modular living space design game" "A pirate game" "A cosmic exploration" "An iridescent materials crafting game" "A microtonal game")))
(define *action-cycle* (make-cycle '("erase the boundaries of" "dissolve" "build" "unite" "infiltrate" "discover" "explore" "trade with" "mutually stake with" "lead the rebels in" "make peace with" "investigate" "rename" "collect gold from" "collect crystals from" "mine concepts from" "align" "click on" "match" "throw" "toss" "fire pellets at" "control" "touch" "stack" "guess" "memorize" "rotate" "swap" "slide" "avoid" "drag and drop" "tickle" "race" "challenge" "collect" "draw" "unlock" "cook" "break" "solve puzzles involving" "collect" "juggle" "script" "cast" "direct" "invest" "bet" "undersee" "inspire" "motivate" "prioritize" "align" "counter-espionage" "innovate" "design" "evaluate" "test" "envelope" "overwhelm" "teleport" "curate" "instigate" "perturb" "mismanage" "prune" "fertilize" "catalyze" "ritualize" "enact" "decree" "prophecizes" "sabotage" "legislate" "imbue" "invoke" "evoke" "derive" "metabolize" "breed" "feed" "pet" "touch" "summon" "visit" "dream" "conjure" "redeems" "envelop" "extoll" "tweak" "eviscerate" "re-position" "re-locate" "invite" "celebrate" "deals (in)" "trick" "mimic" "reflect" "echoe" "imposterize" "dupe" "anoint" "marry" "reconcile" "reimagine")))
(define *things-cycle* (make-cycle '("nations" "castles" "cities" "strongholds" "towers" "dungeons" "citadels" "kingdoms" "unknown worlds" "other worlds" "parallel worlds" "other dimensions" "alien worlds" "heaven" "hell" "houses" "apartments" "mythological places" "historical places" "islands" "sanctuaries" "temples" "ruins" "factories" "caves" "gems" "diamonds" "gold nuggets" "bricks" "bubbles" "squares" "triangles" "treasure" "blobs" "kitchen appliances" "nondescript fruits" "animals" "birds" "baby animals" "farm animals" "elementals" "exotic fruits" "sentient plants" "your friends" "shapes" "jewels" "letters" "words" "numbers" "tokens" "coins" "eggs" "hats" "candy" "chocolate" "shoes" "gnomes" "fairies" "elves" "fools" "wizards" "princes" "princesses" "priestesses" "the holy grail" "goblets" "doubloons" "hyperstitial looms" "unicorns" "narwhals" "yetis" "golems" "gremlins" "moss people" "pixies" "blocks" "cubes" "asteroids" "stars" "balls" "spheres" "magnets" "riddles" "vibes" "ancient objects" "wands" "divine nonchalance" "staffs" "spellbooks" "tomes" "maps" "poems" "item-set bonuses" "capes" "sewing kits" "print-ons" "heeleys" "charms and enchantments" "temporary and non-Temporary Tattoos" "stuffed animals" "satchels" "robes" "scepters" "candles" "fragrances" "zests" "qualia" "creams and ointments" "potions" "test tubes" "vials" "cauldrons" "alpha" "goblets" "incense" "tents" "containers" "dwellings" "abodes" "bunkers" "community spaces" "caves" "tree houses" "hypermedia" "sailboats" "playgrounds" "volcanic islands" "castles" "clubs" "venues" "bridges" "secret wardrobes" "farms" "ecovillages" "cottages" "mountains" "springs" "wells" "rivers" "creeks" "liminal spaces" "fountains" "oases" "waterFalls" "glaciers")))
(define *goals-cycle* (make-cycle '("to \"win\"" "in the name of love" "as an end in itself" "to win points" "to surpass the highscore" "to unlock bonus items" "to issue tokens" "to unlock the next level" "to create thriving community" "to manage resources effectively" "to protect the realm" "to open new portals" "to reconstruct reality" "for economic space agency" "for a later present" "to care for one another" "to enter our bliss bodies" "to find the others" "to revel in the beauty of every moment" "to dance organizations into existence" "to explore qualia" "to go where no one has ever gone before" "to defy the odds" "to witness more miracles" "to unite enchantment and majesty" "because reality is our art" "to make divine interventions redundant")))

(define *P-cycle* (make-cycle '("P" "p" "℘" "𝒫" "𝓅" "" "𝖕" "Ρ" "ρ" "Р" "р" "⍴" "Ᵽ" "ᖘ" "ᑸ" "ᑹ" "Ⓟ" "Ꝑ" "ꝑ" "Ꝓ" "ꝓ")))
(define *L-cycle* (make-cycle '("L" "l" "ℒ" "ℓ" "𝓛" "𝓁" "𝔏" "𝖑" "Լ" "լ" "ʟ" "ɭ" "Ĺ" "Ļ" "Ľ" "Ŀ" "Ł" "ł" "ɫ" "ɬ" "Ꮮ" "Ⅼ" "ⅼ")))
(define *A-cycle* (make-cycle '("A" "a" "Á" "á" "À" "à" "â" "Ä" "ä" "Å" "å" "Ā" "ā" "Ă" "ă" "Ą" "ą" "Ⱥ" "ⱥ" "∀" "Α" "α" "А" "а" "Ⴀ" "@" "ɑ" "ɒ" "Ⰰ")))
(define *Y-cycle* (make-cycle '("Y" "y" "Ý" "ý" "Ÿ" "ÿ" "Ŷ" "ŷ" "Ȳ" "ȳ" "Υ" "Ү" "ү" "Ұ" "ұ" "ʏ" "ɏ" "𝓨" "𝒴" "𝓨")))
(define *N-cycle* (make-cycle '("N" "n" "Ñ" "ñ" "Ň" "ň" "Ń" "ń" "Ņ" "ņ" "Ŋ" "ŋ" "Ƞ" "ɴ" "Ν" "ɲ" "Ɲ" "ɳ" "ℕ" "𝒩" "𝓃" "𝓝" "" "𝕟" "𝖭" "𝐍" "𝐧" "𝑁" "𝑛")))
(define *E-cycle* (make-cycle '("E" "e" "É" "é" "È" "è" "Ê" "ê" "Ë" "ë" "Ē" "ē" "Ĕ" "ĕ" "Ė" "ė" "Ę" "ę" "Ě" "ě" "Ε" "ε" "Е" "е" "Ё" "ё" "Э" "э" "ℰ" "𝓔" "" "𝔼" "𝕰")))
(define *T-cycle* (make-cycle '("T" "t" "Ť" "ť" "Ţ" "ţ" "Ṫ" "ṫ" "Ŧ" "ŧ" "Τ" "τ" "Т" "т" "Ŧ" "ʇ" "ʈ" "Ⱦ")))

(define (homepage-step!)
  (cycle-step! *genre-cycle*) (cycle-step! *action-cycle*)
  (cycle-step! *things-cycle*) (cycle-step! *goals-cycle*)
  (cycle-step! *P-cycle*) (cycle-step! *L-cycle*) (cycle-step! *A-cycle*)
  (cycle-step! *Y-cycle*) (cycle-step! *N-cycle*) (cycle-step! *E-cycle*)
  (cycle-step! *T-cycle*))

;;; ── Countdown — 3-week cycle, emoji clock ────────────────────────────────

(define *mystical-emojis*
  #("🔮" "🌙" "⚡️" "🧙‍♂️" "🔥" "🌟" "🌈" "🦄" "🧚‍♀️" "🌕"
    "🌑" "🪄" "✨" "☄️" "💫" "👽" "👾" "🛸" "🧞‍♂️" "🧞‍♀️"
    "🧜‍♂️" "🧜‍♀️" "🧝‍♂️" "🧝‍♀️" "🌌" "🌠" "🎇" "🎆" "🧙‍♀️" "🧚‍♂️"
    "🐉" "🐲" "🧸" "🧿" "🪬" "🕉️" "☯️" "🔆" "🌅" "🌄"
    "🏞️" "🏰" "🎠" "🎢" "🔱" "⚛️" "💖" "💗" "💓" "💞"
    "💕" "💟" "❣️" "❤️‍🔥" "❤️‍🩹" "❤️" "🌹" "🌸" "🌺" "🏵️"
    "💐" "💮" "💍" "👑" "🧡" "💛" "💚" "💙" "💜" "🤍"
    "🤎" "🖤" "💝" "💘" "💌" "🪽"))

(define *digit-emojis*
  #("0️⃣" "1️⃣" "2️⃣" "3️⃣" "4️⃣" "5️⃣" "6️⃣" "7️⃣" "8️⃣" "9️⃣"))

(define (mystical-ref n)
  (vector-ref *mystical-emojis* (modulo n (vector-length *mystical-emojis*))))

(define (render-countdown)
  "Compute remaining time in the current 3-week cycle and render as emoji."
  (let* ((reference-ms 1704067200000.0) ;; Jan 1 2024 00:00 UTC
         (cycle-ms     1814400000.0)     ;; 3 weeks in ms
         (now-ms       (date-now))
         (elapsed-ms   (- now-ms reference-ms))
         (in-cycle-ms  (- elapsed-ms (* (floor (/ elapsed-ms cycle-ms)) cycle-ms)))
         (remaining-ms (- cycle-ms in-cycle-ms))
         (secs         (inexact->exact (floor (/ remaining-ms 1000.0))))
         (days         (quotient secs 86400))
         (hours        (quotient (modulo secs 86400) 3600))
         (minutes      (quotient (modulo secs 3600) 60))
         (seconds      (modulo secs 60))
         (sec-str      (if (>= seconds 10)
                           (string-append
                             (vector-ref *digit-emojis* (quotient seconds 10))
                             (vector-ref *digit-emojis* (modulo seconds 10)))
                           (vector-ref *digit-emojis* seconds))))
    (string-append (mystical-ref days) ":"
                   (mystical-ref hours) ":"
                   (mystical-ref minutes) ":"
                   sec-str)))

(define (render-homepage)
  `(div (@ (class "homepage-content"))
        (div (@ (class "playnet-header"))
             (p (span (@ (id "P")) ,(cycle-peek *P-cycle*))
                (span (@ (id "L")) ,(cycle-peek *L-cycle*))
                (span (@ (id "A")) ,(cycle-peek *A-cycle*))
                (span (@ (id "Y")) ,(cycle-peek *Y-cycle*))
                (span (@ (id "N")) ,(cycle-peek *N-cycle*))
                (span (@ (id "E")) ,(cycle-peek *E-cycle*))
                (span (@ (id "T")) ,(cycle-peek *T-cycle*))))
        (div (@ (class "main-content"))
             (div (@ (id "box"))
                  (div (span (@ (id "genre")) ,(cycle-peek *genre-cycle*)))
                  (div "where we")
                  (div (span (@ (id "action")) ,(cycle-peek *action-cycle*)))
                  (div (span (@ (id "things")) ,(cycle-peek *things-cycle*)))
                  (div (span (@ (id "goals")) ,(cycle-peek *goals-cycle*)))))
        (div (@ (class "button-container"))
             (div (@ (class "bottom-buttons"))
                  (a (@ (href "https://radicle.network/nodes/rosa.radicle.xyz/rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ") (class "btn source")) "Source")
                  (a (@ (href "https://smp8.simplex.im/g#fEgKZbx2ELpqdN1XV3az6E_-qzcASSm-PyxD2n0J_Fo") (class "btn chat")) "Public chat")
                  (span (@ (class "btn donate")
                           (click ,(lambda (e)
                                     (set! *donate-open?* (not *donate-open?*))
                                     (when *donate-open?*
                                       (set! *donate-trocador-loaded?* #f)
                                       (set! *donate-trocador-failed?* #f)
                                       (unless (zero? *donate-trocador-timer*)
                                         (window-clear-timeout *donate-trocador-timer*))
                                       (set! *donate-trocador-timer*
                                             (window-set-timeout
                                              (procedure->external
                                               (lambda ()
                                                 (unless *donate-trocador-loaded?*
                                                   (set! *donate-trocador-failed?* #t)
                                                   (refresh!))))
                                              8000)))
                                     (refresh!))))
                        "Donate")))
        ,(if *donate-open?* (render-donate-panel) "")
        (div (@ (id "countdown")) ,(render-countdown))))

;;; ── Donate panel ──────────────────────────────────────────────────────────
;;; Monero address for the server's wallet. The QR SVG is pre-generated at
;;; build time with `qrencode -t SVG -l M -m 2 monero:<address>?recipient_name=playnet`
;;; → browser/assets/icons/donate-monero.svg. No client-side QR library or server-side
;;; encoder required; the address rarely changes, regen on rotation.

(define %donate-monero-address
  "49AS5K3BKdw8mGrTkP4psGd8CsaSWE6aQ6QsPW45xQBPDBzCZjAopGBPLibwtut86HaiZiPyyc5YcSQ1ydysdqMSADmVCJR")

;; Trocador AnonPay widget URL: USD-denominated, ETH→XMR by default, $50 preset,
;; transparent bg so it blends with .donate-panel-inner. Trocador's form won't
;; let `is_donation=True` coexist with `fiat_equiv` — so the button reads "Pay",
;; not "Donate". We prefer the USD denomination + coin picker over the wording.
(define %donate-trocador-url
  (string-append
   "https://trocador.app/anonpay/"
   "?ticker_to=xmr&network_to=Mainnet"
   "&address=" %donate-monero-address
   "&simple_mode=True"
   "&fiat_equiv=USD&amount=50.0"
   "&name=Playnet&description=Donation"
   "&ticker_from=eth&network_from=ERC20"
   "&bgcolor=00000000"))

(define (render-donate-panel)
  `(div (@ (class "donate-panel"))
        (div (@ (class "donate-panel-inner"))
             (div (@ (class "donate-trocador-wrap"))
                  ,@(if *donate-trocador-loaded?*
                        '()
                        '((div (@ (class "donate-loading"))
                               (div (@ (class "donate-spinner")))
                               (div (@ (class "donate-loading-text"))
                                    "loading widget…"))))
                  (iframe (@ (class ,(if *donate-trocador-loaded?*
                                         "donate-trocador"
                                         "donate-trocador donate-trocador-hidden"))
                             (src ,%donate-trocador-url)
                             (width "310")
                             (height "350")
                             (scrolling "no")
                             (title "Trocador AnonPay — swap any coin to XMR")
                             (load ,(lambda (e)
                                      (set! *donate-trocador-loaded?* #t)
                                      (set! *donate-trocador-failed?* #f)
                                      (refresh!))))))
             ,@(if *donate-trocador-failed?*
                   `((div (@ (class "donate-or")) "widget unreachable — send XMR directly")
                     (div (@ (class "donate-qr-wrap"))
                          (img (@ (class "donate-qr")
                                  (src "assets/icons/donate-monero.svg")
                                  (alt "Scan to donate XMR to the playnet server wallet"))))
                     (div (@ (class "donate-address-row"))
                          (code (@ (class "donate-address")) ,%donate-monero-address))
                     (div (@ (class "donate-actions"))
                          (span (@ (class "btn donate-action")
                                   (click ,(lambda (e)
                                             (with-exception-handler
                                               (lambda (_exn) #f)
                                               (lambda () (clipboard-write! %donate-monero-address))
                                               #:unwind? #t))))
                                "copy address")))
                   '())
             (div (@ (class "donate-actions"))
                  (span (@ (class "btn donate-action donate-close")
                           (click ,(lambda (e)
                                     (set! *donate-open?* #f)
                                     (refresh!))))
                        "close")))))

(define *expressor-filter* #f)       ;; symbol or #f — filter history by expressor name

;; Control panel state
(define *show-new-org-form* #f)
(define *show-signup-form* #f)
(define *confirm-delete-org* #f)     ;; org name string or #f
(define *show-join-form* #f)
(define *listening?* #f)
(define *expressing?* #f)  ;; #t during voice→NL→Scheme express flow
(define *pending-transcript* #f)  ;; transcript awaiting input/ask choice
(define *syntax-mode* 'wisp)  ;; 'lisp or 'wisp
(define *terminal-active?* #f)
(define *terminal-obj* #f)   ;; xterm.js extern ref

;; Voice-to-text callbacks
(define (on-speech-result transcript)
  (let ((input (get-element-by-id "expression")))
    (set-element-value! input
      (string-append (element-value input)
                     (if (string=? (element-value input) "") "" " ")
                     transcript))
    (set! *listening?* #f)
    (refresh!)))

;; Voice→ask: record speech, transcribe, wrap in (ask "...") and eval
(define (on-ask-speech-result transcript)
  (set! *listening?* #f)
  (let ((trimmed (%trim transcript)))
    (unless (string=? trimmed "")
      (eval! (string-append "(ask \"" trimmed "\")"))))
  (refresh!))

(define (on-speech-end)
  (set! *listening?* #f)
  (set! *expressing?* #f)
  (refresh!))

;; Express callbacks — NL→Scheme result goes into input for review
(define (on-express-result expr)
  (let ((input (get-element-by-id "expression")))
    (set-element-value! input expr)
    (set! *listening?* #f)
    (set! *expressing?* #f)
    (refresh!)))

(define (toggle-listening!)
  (if *listening?*
      (begin (stop-listening!)
             (set! *listening?* #f))
      (begin (set-express-mode! 0)
             (start-listening!
               (procedure->external on-speech-result)
               (procedure->external on-speech-end))
             (set! *listening?* #t))))

(define (toggle-ask-listening!)
  "Telegram-style: tap to record, tap to stop. Transcript → (ask \"...\")."
  (if *listening?*
      (begin (stop-listening!)
             (set! *listening?* #f))
      (begin (set-express-mode! 0)
             (start-listening!
               (procedure->external on-ask-speech-result)
               (procedure->external on-speech-end))
             (set! *listening?* #t))))

;; Unified mic: record, then offer two options (dictate vs ask).
(define (on-pending-speech-result transcript)
  (set! *listening?* #f)
  (let ((trimmed (%trim transcript)))
    (set! *pending-transcript* (and (not (string=? trimmed "")) trimmed)))
  (refresh!))

(define (toggle-mic!)
  (cond
    (*listening?*
     (stop-listening!)
     (set! *listening?* #f))
    (else
     (set! *pending-transcript* #f)
     (set-express-mode! 0)
     (start-listening!
       (procedure->external on-pending-speech-result)
       (procedure->external on-speech-end))
     (set! *listening?* #t))))

(define (commit-pending-as-input!)
  (let ((t *pending-transcript*))
    (set! *pending-transcript* #f)
    (when t
      (let ((input (get-element-by-id "expression")))
        (set-element-value! input
          (string-append (element-value input)
                         (if (string=? (element-value input) "") "" " ")
                         t)))))
  (refresh!))

(define (commit-pending-as-ask!)
  (let ((t *pending-transcript*))
    (set! *pending-transcript* #f)
    (when t (eval! (string-append "(ask \"" t "\")"))))
  (refresh!))

(define (dismiss-pending!)
  (set! *pending-transcript* #f)
  (refresh!))

(define (toggle-expressing!)
  "Voice→NL→Scheme: record speech, transcribe, convert to S-expression."
  (if *listening?*
      (begin (stop-listening!)
             (set! *listening?* #f)
             (set! *expressing?* #f))
      (begin (set-express-mode! 1)
             (set! *expressing?* #t)
             (start-listening!
               (procedure->external on-express-result)
               (procedure->external on-speech-end))
             (set! *listening?* #t))))

(define (do-express-text! text)
  "Convert natural language text to S-expression via OCapN gateway, put in input."
  (express-nl! text
    (procedure->external
     (lambda (expr)
       (let ((input (get-element-by-id "expression")))
         (set-element-value! input expr)
         (log-append! `(span (@ (class "info-text"))
                              ,(string-append "expressed: " text "\n")))
         (refresh!))))))

(define (toggle-syntax-mode!)
  (set! *syntax-mode* (if (eq? *syntax-mode* 'lisp) 'wisp 'lisp))
  (ls-set-item "pn.repl.syntax" (symbol->string *syntax-mode*))
  (update-code-viewer!)
  (refresh!)
  (scroll-to-bottom!))

(define (open-terminal!)
  "Open an xterm.js terminal connected to the server via OCapN."
  (set! *terminal-active?* #t)
  (set! *code-viewer-content* "")  ;; hide code viewer
  (refresh!)
  ;; Mount xterm.js into the rendered container
  (let ((mount (get-element-by-id "xterm-mount")))
    (when mount
      (let ((tobj (term-create mount)))
        (set! *terminal-obj* tobj)
        ;; Wire keystrokes → terminal session actor
        (term-on-data! tobj
          (procedure->external
            (lambda (data)
              (when *terminal-cap*
                (with-vat *ocapn-vat*
                  (<-np *terminal-cap* 'write data))))))
        ;; Request PTY from gateway
        (when *lobby*
          (let ((pk-str (with-vat *vat*
                          (call-with-output-string
                            (lambda (p) (write ($ *org* 'public-key) p))))))
            (with-vat *ocapn-vat*
              (on (<- *lobby* 'open-terminal pk-str *user-inbox*)
                  (lambda (result)
                    (if (and (pair? result) (eq? (car result) 'error))
                        (begin
                          (log-append! `(span (@ (class "error-text"))
                                              ,(string-append "Terminal error: "
                                                              (cadr result) "\n")))
                          (set! *terminal-active?* #f)
                          (refresh!))
                        (begin
                          (set! *terminal-cap* result)
                          (log-append! `(span (@ (class "result-text"))
                                              "Terminal session opened.\n"))
                          (refresh!))))))))))))

(define (close-terminal!)
  "Close the terminal session."
  (when *terminal-obj*
    (term-dispose! *terminal-obj*)
    (set! *terminal-obj* #f))
  (when *terminal-cap*
    (with-vat *ocapn-vat*
      (<-np *terminal-cap* 'close))
    (set! *terminal-cap* #f))
  (set! *terminal-active?* #f)
  (update-code-viewer!)
  (refresh!))

(define (org-entry-name e) (list-ref e 0))
(define (org-entry-vat e) (list-ref e 1))
(define (org-entry-ref e) (list-ref e 2))
(define (org-entry-inbox e) (list-ref e 3))
(define (org-entry-incanter e) (list-ref e 4))
(define (org-entry-key-pair e) (list-ref e 5))
(define (org-entry-refs e) (list-ref e 6))
(define (org-entry-controllers e)
  (with-vat (org-entry-vat e) ($ (org-entry-refs e) 'get)))
(define (org-entry-log e) (list-tail e 7))

(define (org-save!)
  (when *current-org-name*
    (let ((old (org-lookup *current-org-name*)))
      (when old
        (let ((entry (append (list *current-org-name*
                                   *vat* *org*
                                   (org-entry-inbox old)
                                   (org-entry-incanter old)
                                   (org-entry-key-pair old)
                                   (org-entry-refs old))
                             *log*)))
          (set! *orgs*
            (cons entry
                  (let loop ((lst *orgs*))
                    (cond ((null? lst) '())
                          ((string=? (car (car lst)) *current-org-name*) (loop (cdr lst)))
                          (else (cons (car lst) (loop (cdr lst)))))))))))))

(define (org-set-controllers! name controllers)
  "Update the controllers alist via the ^ref-store actor."
  (let ((entry (org-lookup name)))
    (when entry
      (with-vat (org-entry-vat entry)
        ($ (org-entry-refs entry) 'set! controllers)))))

(define (org-lookup name)
  (let loop ((lst *orgs*))
    (cond ((null? lst) #f)
          ((string=? (caar lst) name) (car lst))
          (else (loop (cdr lst))))))

;;; ── Org index persistence ────────────────────────────────────────────────
;;; Stores org names + serialized key material in localStorage["pn.repl.orgs"].
;;; Per-org Goblins state is stored by make-local-storage-store in separate keys.

(define (save-org-index!)
  "Persist the list of org names to localStorage as comma-separated string."
  (ls-set-item "pn.repl.orgs"
    (let loop ((names (map org-entry-name *orgs*)) (acc ""))
      (if (null? names) acc
          (loop (cdr names)
                (if (string=? acc "") (car names)
                    (string-append acc "," (car names))))))))

(define (load-org-index)
  "Load org names from localStorage. Returns list of strings or '()."
  (let ((raw (ls-get-item "pn.repl.orgs")))
    (if (or (not raw) (string=? raw "")) '()
        ;; Split comma-separated string into list
        (let loop ((s raw) (acc '()))
          (let ((comma (string-index s #\,)))
            (if comma
                (loop (substring s (+ comma 1))
                      (cons (substring s 0 comma) acc))
                (reverse (cons s acc))))))))

(define (display-code str)
  "Convert S-expression string for display in current syntax mode."
  (if (eq? *syntax-mode* 'wisp)
      (sexp->wisp-string str)
      str))

(define (cmd-line command description)
  "Render a command line with inline coloring: command in accent, description dim.
   Returns a thunk so display-code re-evaluates on each render (wisp/lisp toggle)."
  (lambda ()
    `(span (span (@ (class "accent-text")) ,(display-code command))
           (span (@ (class "dim-text"))    ,description) "\n")))

(define *log*
  (list
    `(span (@ (class "title-text"))   "playnet\n")
    `(span (@ (class "tagline-text")) "less work, more play\n")
    `(span (@ (class "tagline-text")) "that's the politics\n\n")
    `(span (@ (class "info-text"))
           ,(string-append
              "A self-evolving commons — identity, memory, and\n"
              "self-modification as symbolic expressions (s-exprs) all the way down.\n\n"))
    `(span (@ (class "dim-text"))
           "────────────────────────────────────────────────\n\n")
    (cmd-line "  (make-org \"my-org\")" "   create a world")
    (cmd-line "  (enter! \"my-org\")"   "     step inside")
    (cmd-line "  (help)"              "               the rest")
    `(span "\n")))

(define *outer-log* *log*)
(define *outer-vat* #f)
(define *outer-org* #f)

(define (log-append! . lines)
  (set! *log* (append *log* lines)))

(define (current-prompt)
  ;; Inner-mode prompt looks like "my-org[genesis]> ".
  ;;
  ;; The expressor lookup is a synchronous `$` call into the org's vat,
  ;; so it must be wrapped in `with-vat *vat*`. But render can be triggered
  ;; from another vat (e.g. ^user-inbox in *ocapn-vat* receives a
  ;; presence-update and calls refresh!), and `with-vat` across vats is
  ;; ASYNC — it returns a Goblins promise, not the value. Passing that
  ;; promise to `symbol->string` used to crash. Guard with a symbol? check;
  ;; show "?" while the cross-vat call is in flight.
  (if (eq? *mode* 'outer)
      "playnet> "
      (let ((result (with-vat *vat*
                      ($ *org* 'expressor-name ($ *org* 'current-expressor)))))
        (string-append *current-org-name* "["
          (cond
            ((symbol? result) (symbol->string result))
            ((string? result) result)
            (else "?"))
          "]> "))))

;;; ── History ring ──────────────────────────────────────────────────────────

(define *history* '())
(define *history-index* -1)

(define (history-push! str)
  (set! *history* (cons str *history*))
  (set! *history-index* -1))

(define (history-ref index)
  (if (or (< index 0) (>= index (length *history*)))
      #f
      (let loop ((lst *history*) (i 0))
        (if (= i index) (car lst) (loop (cdr lst) (+ i 1))))))

;;; ── Paren balance ─────────────────────────────────────────────────────────

(define *paren-depth* 0)

;;; ── Autocomplete state ─────────────────────────────────────────────────────

(define *current-suggestion* "")

(define (compute-paren-depth str)
  (let loop ((i 0) (depth 0) (in-string? #f))
    (if (>= i (string-length str))
        depth
        (let ((ch (string-ref str i)))
          (cond
           (in-string?
            (cond
             ((char=? ch #\") (loop (+ i 1) depth #f))
             ((char=? ch #\\) (loop (+ i 2) depth #t))
             (else (loop (+ i 1) depth #t))))
           ((char=? ch #\") (loop (+ i 1) depth #t))
           ((char=? ch #\() (loop (+ i 1) (+ depth 1) #f))
           ((char=? ch #\)) (loop (+ i 1) (- depth 1) #f))
           (else (loop (+ i 1) depth #f)))))))

;;; ── Code viewer ──────────────────────────────────────────────────────────

(define *base-binding-names*
  (map car base-bindings))

(define (base-binding? name)
  (memq name *base-binding-names*))

(define (serialize-org-code ref)
  "Serialize the current org state as readable Scheme code."
  (let* ((bindings ($ ref 'bindings))
         (user-bindings (%filter (lambda (pair) (not (base-binding? (car pair)))) bindings))
         (history ($ ref 'history))
         (vexpr ($ ref 'validator-expr))
         (expressors (unique-expressors history ref))
         (recent (let ((h (reverse history)))
                   (if (> (length h) 10) (list-tail h (- (length h) 10)) h)))
         (port (open-output-string)))
    ;; User-defined bindings
    (unless (null? user-bindings)
      (display ";;; bindings\n" port)
      (for-each (lambda (pair)
                  (let ((val (cdr pair)))
                    (cond
                      ((procedure? val)
                       (display ";; " port)
                       (display (symbol->string (car pair)) port)
                       (display " = <procedure>\n" port))
                      (($ ref 'expressor? val)
                       (display ";; " port)
                       (display (symbol->string (car pair)) port)
                       (display " = <expressor>\n" port))
                      (else
                       (display "(modify! '" port)
                       (display (symbol->string (car pair)) port)
                       (display " " port)
                       (write val port)
                       (display ")\n" port)))))
                user-bindings)
      (newline port))
    ;; Validator
    (unless (equal? vexpr '(lambda (e n v pre post) #t))
      (display ";;; validator\n" port)
      (display "(enact! " port)
      (write vexpr port)
      (display ")\n\n" port))
    ;; Expressors
    (when (> (length expressors) 1)
      (display ";;; expressors\n" port)
      (for-each (lambda (exp-id)
                  (let ((name (or ($ ref 'expressor-name exp-id) '?)))
                    (display (string-append ";; " (symbol->string name) "\n") port)))
                expressors)
      (newline port))
    ;; History (skip the initial entry)
    (let ((meaningful (if (and (not (null? recent))
                               (equal? (caddr (car recent)) '(quote initial)))
                          (cdr recent)
                          recent)))
      (unless (null? meaningful)
        (display ";;; history\n" port)
        (for-each (lambda (entry)
                    (display (string-append ";; v" (number->string (car entry))
                               " [" (symbol->string (or ($ ref 'expressor-name (cadr entry)) '?))
                               "] ") port)
                    (write (caddr entry) port)
                    (newline port))
                  meaningful)))
    (get-output-string port)))

(define *code-viewer-content* "")

(define (update-code-viewer!)
  "Serialize current org and store for VDOM rendering."
  (if (and *org* *vat*)
      (with-exception-handler
        (lambda (exn) (set! *code-viewer-content* ""))
        (lambda ()
          (let ((sexp-str (with-vat *vat* (serialize-org-code *org*))))
            (set! *code-viewer-content*
              (if (eq? *syntax-mode* 'wisp)
                  (sexp->wisp-string sexp-str)
                  sexp-str))))
        #:unwind? #t)
      (set! *code-viewer-content* "")))

;;; ── Evaluation ────────────────────────────────────────────────────────────

(define %invalid (cons 'invalid 'expression))
(define (read* port)
  (with-exception-handler (lambda (exn) %invalid)
    (lambda () (read port))
    #:unwind? #t))

(define (eval-play! exp)
  (let ((output (open-output-string)))
    (with-exception-handler
      (lambda (exn)
        (let ((out-str (get-output-string output)))
          (unless (string=? out-str "")
            (log-append! `(span (@ (class "output-text")) ,out-str))))
        (let ((err-port (open-output-string)))
          (format-exception exn err-port)
          (let ((err-str (get-output-string err-port)))
            (log-append! `(span (@ (class "error-text")) ,err-str))
            ;; Log the error to the org's print log
            (with-vat *vat*
              ($ *org* 'log-expression!
                 ($ *org* 'head-version)
                 ($ *org* 'current-expressor)
                 exp
                 (string-append "error: " err-str))))))
      (lambda ()
        (parameterize ((current-output-port output))
          (with-vat *vat*
            (let ((result (evaluate exp *org* '() ($ *org* 'current-expressor))))
              (let ((out-str (get-output-string output)))
                (unless (string=? out-str "")
                  (log-append! `(span (@ (class "output-text")) ,out-str))))
              (let ((result-str
                     (if (eq? result (if #f #f))
                         ""
                         (let ((p (open-output-string)))
                           (if (string? result) (display result p) (write result p))
                           (get-output-string p)))))
                (unless (string=? result-str "")
                  (let ((rs result-str))
                    (log-append! (lambda () `(span (@ (class "result-text"))
                                                    ,(string-append "=> " (display-code rs) "\n"))))))

                ;; Log to the org's print log
                ($ *org* 'log-expression!
                   ($ *org* 'head-version)
                   ($ *org* 'current-expressor)
                   exp
                   result-str))))))
      #:unwind? #t)
    ;; Update code viewer after evaluation (outside with-vat to avoid nesting)
    (update-code-viewer!)))

(define (do-enter! name)
  (let ((org (org-lookup name)))
    (when (and org (not (and *current-org-name* (string=? name *current-org-name*))))
      (org-save!)
      (when (eq? *mode* 'outer)
        (set! *outer-log* *log*)
        (set! *outer-vat* *vat*)
        (set! *outer-org* *org*))
      (set! *mode* 'inner)
      (set! *current-org-name* name)
      (set! *vat* (org-entry-vat org))
      (set! *org* (org-entry-ref org))
      (set! *log* (let ((l (org-entry-log org)))
                    (if (null? l) (list) l)))
      (set! *sidebar-selected-org* name)
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "Entering org '" name "'.\n")))
      (register-all-keys!)
      (announce-presence!)
      ;; Update code viewer when entering org
      (update-code-viewer!))))

(define (do-exit!)
  (when (eq? *mode* 'inner)
    (org-save!)
    (set! *mode* 'outer)
    (set! *vat* *outer-vat*)
    (set! *org* *outer-org*)
    (set! *log* *outer-log*)
    (let ((name *current-org-name*))
      (set! *current-org-name* #f)
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "Left org '" name "'.\n")))
      ;; Clear code viewer when exiting org
      (set! *code-viewer-content* ""))))

;;; ── Extracted command procedures (callable from REPL and UI) ─────────────

(define (make-fallback-org name base-bindings pk)
  "Create a non-persistent org when Goblins persistence fails in Hoot/WASM."
  (let ((vat (spawn-vat #:name name)))
    (with-vat vat
      (let ((org (make-initial-org base-bindings #:public-key pk)))
        (receive (warden incanter) (spawn-warding-pair)
          (let ((inbox (spawn ^org-inbox org '() 0 warden incanter))
                (refs (spawn ^ref-store '())))
            (values vat org inbox incanter refs)))))))

(define (do-make-org! name)
  (if (org-lookup name)
      (log-append!
       `(span (@ (class "error-text"))
              ,(string-append "Org already exists: " name "\n")))
      (let* ((kp (generate-key-pair))
             (pk (key-pair->public-key kp))
             (store (make-local-storage-store
                     (string-append "playnet-" name))))
        (receive (vat org inbox incanter refs)
          (make-persistent-org name base-bindings store
                               #:public-key pk
                               #:persistence-registry
                               *persistence-registry*)
          (let* ((p (open-output-string))
                 (_ (write pk p))
                 (s (get-output-string p))
                 (pk-display (if (> (string-length s) 50)
                                 (string-append (substring s 0 50) "...")
                                 s)))
            (set! *orgs*
                  (cons (list name vat org inbox incanter kp refs)
                        *orgs*))
            (set! *sidebar-selected-org* name)
            (save-key-pair name kp)
            (save-org-index!)
            (log-append!
             `(span (@ (class "result-text"))
                    ,(string-append
                      "Created org: " name
                      "\n  key: " pk-display "\n"))))))))

(define (do-delete-org! name)
  (if (org-lookup name)
      (begin
        (when (and *current-org-name* (string=? name *current-org-name*)) (do-exit!))
        (set! *orgs* (let loop ((lst *orgs*))
          (cond ((null? lst) '())
                ((string=? (caar lst) name) (loop (cdr lst)))
                (else (cons (car lst) (loop (cdr lst)))))))
        (when (and *sidebar-selected-org* (string=? name *sidebar-selected-org*))
          (set! *sidebar-selected-org* #f))
        (ls-remove-item (string-append "playnet-" name))
        (delete-key-pair name)
        (save-org-index!)
        (log-append! `(span (@ (class "result-text")) ,(string-append "Deleted org: " name "\n"))))
      (log-append! `(span (@ (class "error-text")) ,(string-append "Unknown org: " name "\n")))))

(define (do-export-ssh-key!)
  (if (not (eq? *mode* 'inner))
      (log-append! `(span (@ (class "error-text")) "Enter an org first.\n"))
      (let* ((pk (with-vat *vat* ($ *org* 'public-key)))
             (pk-str (call-with-output-string (lambda (p) (write pk p)))))
        (log-append!
          `(span (@ (class "result-text"))
                 ,(string-append
                    "Your playnet public key (use this as your SSH public key):\n"
                    "  " pk-str "\n\n"
                    "Paste it during (signup!) or send it to an administrator.\n"))))))

;; Legacy SSH-pubkey signup. Dormant — its action-bar button is hidden
;; (see render-action-bar's commented note). The supported signup
;; surface is the KERI flow in the top-right identity dropdown
;; (do-keri-create!). Kept callable from the REPL so a future
;; redeploy-driven user-provisioning path can re-enable it without
;; resurrecting code. See docs/keri/IMPLEMENTATION.md item #5 for the
;; AID-only philosophy that supersedes this.
(define (do-signup! username email)
  (cond
    ((not (eq? *mode* 'inner))
     (log-append! `(span (@ (class "error-text"))
                         "Enter an org first.\n")))
    ((not *lobby*)
     (log-append! `(span (@ (class "error-text"))
                         "Not connected to gateway.\n")))
    (*signup-pending?*
     (log-append! `(span (@ (class "info-text"))
                         "Signup already in progress...\n")))
    (else
     (let* ((pk     (with-vat *vat* ($ *org* 'public-key)))
            (pk-str (call-with-output-string (lambda (p) (write pk p)))))
       (set! *signup-pending?* #t)
       (with-vat *ocapn-vat*
         (on (<- *lobby* 'signup username email pk-str)
             (lambda (result)
               (set! *signup-pending?* #f)
               (if (eq? result 'ok)
                   (log-append! `(span (@ (class "result-text"))
                     ,(string-append
                        "Account registered!\n"
                        "  Check your email for connection details.\n"
                        "  Run (export-ssh-key) to get your SSH public key.\n"
                        "  Then: guix deploy deploy/guix/machines.scm\n")))
                   (log-append! `(span (@ (class "error-text"))
                     ,(string-append "Signup failed: "
                                     (if (pair? result) (cadr result) "unknown error")
                                     "\n"))))
               (refresh!))
             #:catch
             (lambda (err)
               (set! *signup-pending?* #f)
               (log-append! `(span (@ (class "error-text"))
                                   ,(string-append "Signup error: "
                                                   (call-with-output-string
                                                     (lambda (p) (write err p)))
                                                   "\n")))
               (refresh!))))
       (log-append!
         `(span (@ (class "info-text"))
                ,(string-append
                   "Signup request sent for '" username "'...\n"
                   "Waiting for server confirmation.\n")))))))

(define (do-join-org! target-name)
  (if (not *current-org-name*)
      (log-append! `(span (@ (class "error-text"))
                          "Must be inside an org to join another.\n"))
      (let ((target (org-lookup target-name)))
        (if (not target)
            (log-append! `(span (@ (class "error-text"))
                                ,(string-append "Unknown org: " target-name "\n")))
            (let* ((target-vat (org-entry-vat target))
                   (target-inbox (org-entry-inbox target))
                   (my-pk (with-vat *vat* ($ *org* 'public-key))))
              (with-vat target-vat
                (receive (sub-sealer sub-unsealer sub-sealed?)
                  (spawn-sealer-triplet)
                  (let* ((my-identity
                          (spawn (lambda (bcom)
                            (methods
                             [(name) (string->symbol *current-org-name*)]
                             [(subscription-sealer) sub-sealer]
                             [(subscription-unsealer) sub-unsealer]
                             [(public-key) my-pk]))))
                         (msg-id ($ target-inbox 'submit
                                    `(request-membership ,*current-org-name*)
                                    my-identity)))
                    (set! *pending-joins*
                      (cons (list *current-org-name* target-name
                                 sub-unsealer msg-id my-identity)
                            *pending-joins*))
                    (log-append! `(span (@ (class "result-text"))
                                        ,(string-append *current-org-name*
                                                        " requested to join " target-name
                                                        " (msg-id: "
                                                        (number->string msg-id) ").\n")))))))))))

(define (do-approve-member! msg-id name)
  (if (not *current-org-name*)
      (log-append! `(span (@ (class "error-text"))
                          "Must be inside an org to approve members.\n"))
      (let* ((current (org-lookup *current-org-name*))
             (inbox (org-entry-inbox current))
             (incanter (org-entry-incanter current))
             (pending (let loop ((lst *pending-joins*))
                        (cond ((null? lst) #f)
                              ((and (string=? (list-ref (car lst) 1) *current-org-name*)
                                    (string=? (list-ref (car lst) 0) name))
                               (car lst))
                              (else (loop (cdr lst)))))))
        (if (not pending)
            (log-append! `(span (@ (class "error-text"))
                                ,(string-append "No pending join for: " name "\n")))
            (begin
              (let* ((sub-unsealer (list-ref pending 2))
                     (applicant-identity (list-ref pending 4))
                     (applicant-pk (with-vat (org-entry-vat current)
                                    ($ applicant-identity 'public-key))))
                (with-vat (org-entry-vat current)
                  (let* ((sealed-controller
                          (approve-membership inbox incanter msg-id *org*
                                              (string->symbol name)
                                              applicant-pk
                                              applicant-identity))
                         (controller ($ sub-unsealer sealed-controller)))
                    (let ((joiner (org-lookup name)))
                      (when joiner
                        (org-set-controllers! name
                          (cons (cons *current-org-name* controller)
                                (org-entry-controllers joiner))))))))
              (set! *pending-joins*
                (let loop ((lst *pending-joins*))
                  (cond ((null? lst) '())
                        ((and (string=? (list-ref (car lst) 0) name)
                              (string=? (list-ref (car lst) 1) *current-org-name*))
                         (loop (cdr lst)))
                        (else (cons (car lst) (loop (cdr lst)))))))
              (log-append! `(span (@ (class "result-text"))
                                  ,(string-append "Approved '" name "'.\n"))))))))

;;; ── Natural language query engine ──────────────────────────────────────────
;;; Hoot-compatible NL parser + miniKanren executor + narration.
;;; Translates domain phrases into planning queries and explains results.

(define (%char-downcase c)
  (let ((n (char->integer c)))
    (if (and (>= n 65) (<= n 90))
        (integer->char (+ n 32))
        c)))

(define (%string-downcase str)
  (let* ((len (string-length str))
         (out (make-string len)))
    (let loop ((i 0))
      (if (= i len) out
          (begin (string-set! out i (%char-downcase (string-ref str i)))
                 (loop (+ i 1)))))))

(define (%string-split str ch)
  "Split STR on character CH. Hoot-compatible."
  (let ((len (string-length str)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
        ((= i len)
         (reverse (if (= start i) acc
                      (cons (substring str start i) acc))))
        ((char=? (string-ref str i) ch)
         (loop (+ i 1) (+ i 1)
               (if (= start i) acc
                   (cons (substring str start i) acc))))
        (else (loop (+ i 1) start acc))))))

(define (%tokenize phrase)
  "Split phrase into lowercase tokens. Numbers become integers."
  (map (lambda (w)
         (let ((n (string->number w)))
           (if n n (%string-downcase w))))
       (%string-split phrase #\space)))

(define (%words-match? tokens words)
  "Do TOKENS start with WORDS? Returns remaining tokens or #f."
  (let loop ((ts tokens) (ws words))
    (cond
      ((null? ws) ts)
      ((null? ts) #f)
      ((string=? (if (string? (car ts)) (car ts) "") (car ws))
       (loop (cdr ts) (cdr ws)))
      (else #f))))

(define (%parse-ask-query tokens facts)
  "Pattern-match TOKENS against known question frames.
   Returns (goal-type spec-id qty) or #f. FACTS used for spec resolution."
  (define (resolve-spec word)
    "Find a spec-id whose name matches WORD (case-insensitive)."
    (let loop ((fs facts))
      (if (null? fs) #f
          (let ((f (car fs)))
            (if (and (pair? f) (eq? (car f) 'spec-name)
                     (string=? (%string-downcase (list-ref f 2))
                               (if (string? word) word "")))
                (list-ref f 1)
                (loop (cdr fs)))))))
  (define (spec-at tokens)
    "Resolve the first token as a spec. Returns (spec-id . remaining) or #f."
    (and (pair? tokens)
         (let ((sid (resolve-spec (car tokens))))
           (and sid (cons sid (cdr tokens))))))
  (define (qty-spec-at tokens)
    "Parse <qty> <spec> or just <spec>. Returns (spec-id qty . remaining) or #f."
    (cond
      ((and (pair? tokens) (number? (car tokens)) (pair? (cdr tokens)))
       (let ((sid (resolve-spec (cadr tokens))))
         (and sid (list sid (car tokens)))))
      ((pair? tokens)
       (let ((sid (resolve-spec (car tokens))))
         (and sid (list sid #f))))
      (else #f)))
  ;; Try each question frame
  (or
    ;; demand: "how do we make <qty> <spec>" | "make <spec>" | "produce <spec>"
    (let ((rest (or (%words-match? tokens '("how" "do" "we" "make"))
                    (%words-match? tokens '("how" "to" "make"))
                    (%words-match? tokens '("make"))
                    (%words-match? tokens '("plan"))
                    (%words-match? tokens '("produce")))))
      (and rest (let ((qs (qty-spec-at rest)))
                  (and qs `(demand ,(car qs) ,(cadr qs))))))
    ;; inventory: "how much <spec> do we have" | "inventory of <spec>"
    (let ((rest (%words-match? tokens '("how" "much"))))
      (and rest (let ((sa (spec-at rest)))
                  (and sa (%words-match? (cdr sa) '("do" "we" "have"))
                       `(inventory ,(car sa) #f)))))
    (let ((rest (%words-match? tokens '("inventory" "of"))))
      (and rest (let ((sa (spec-at rest)))
                  (and sa `(inventory ,(car sa) #f)))))
    (let ((rest (%words-match? tokens '("stock"))))
      (and rest (let ((sa (spec-at rest)))
                  (and sa `(inventory ,(car sa) #f)))))
    ;; provenance: "what is needed for <spec>" | "what goes into <spec>"
    (let ((rest (or (%words-match? tokens '("what" "is" "needed" "for"))
                    (%words-match? tokens '("what" "goes" "into"))
                    (%words-match? tokens '("inputs" "for")))))
      (and rest (let ((sa (spec-at rest)))
                  (and sa `(provenance ,(car sa) #f)))))
    ;; destination: "what can we make from <spec>" | "what uses <spec>"
    (let ((rest (or (%words-match? tokens '("what" "can" "we" "make" "from"))
                    (%words-match? tokens '("what" "can" "we" "make" "with"))
                    (%words-match? tokens '("what" "uses")))))
      (and rest (let ((sa (spec-at rest)))
                  (and sa `(destination ,(car sa) #f)))))
    ;; recipes: "show recipes for <spec>" | "recipes for <spec>"
    (let ((rest (or (%words-match? tokens '("show" "recipes" "for"))
                    (%words-match? tokens '("recipes" "for")))))
      (and rest (let ((sa (spec-at rest)))
                  (and sa `(recipes ,(car sa) #f)))))))

(define (%spec-word facts spec-id)
  "Look up human name for SPEC-ID in facts."
  (let loop ((fs facts))
    (if (null? fs) spec-id
        (let ((f (car fs)))
          (if (and (pair? f) (eq? (car f) 'spec-name)
                   (equal? (list-ref f 1) spec-id))
              (%string-downcase (list-ref f 2))
              (loop (cdr fs)))))))

(define (do-ask! phrase)
  "Parse a natural language phrase and execute as a planning query."
  (with-exception-handler
    (lambda (exn)
      (let ((err-port (open-output-string)))
        (format-exception exn err-port)
        (log-append! `(span (@ (class "error-text"))
                            ,(get-output-string err-port)))))
    (lambda ()
      (with-vat *vat*
        (let* ((tokens (%tokenize phrase))
               ;; Get planning facts from the org's bindings
               (org-facts (let ((bf (evaluate 'planning-facts *org* '()
                                      ($ *org* 'current-expressor))))
                            (if (pair? bf) bf '())))
               (parsed (%parse-ask-query tokens org-facts)))
          (if (not parsed)
              (log-append! `(span (@ (class "error-text"))
                                  ,(string-append "I don't understand: " phrase "\n"
                                     "Try: make <item>, what is needed for <item>,\n"
                                     "     how much <item> do we have, recipes for <item>\n")))
              (begin
                (log-append! `(span (@ (class "info-text"))
                                    ,(string-append "→ " (let ((p (open-output-string)))
                                                           (write parsed p)
                                                           (get-output-string p)) "\n")))
                (match parsed
                  (('inventory spec-id _)
                   ;; Run inventory query via miniKanren
                   (let* ((query-expr `(run* (q)
                            (fresh (rid qty loc contained-in)
                              (membero (list 'inventory rid ,spec-id qty loc contained-in)
                                       (quote ,org-facts))
                              (== q (list qty loc)))))
                          (results (evaluate query-expr *org* '()
                                    ($ *org* 'current-expressor))))
                     (if (null? results)
                         (log-append! `(span (@ (class "output-text"))
                                            "No inventory found.\n"))
                         (for-each (lambda (r)
                           (log-append! `(span (@ (class "result-text"))
                                               ,(string-append
                                                  "  " (number->string (car r))
                                                  " at " (cadr r) "\n"))))
                           results))))
                  (('recipes spec-id _)
                   (let* ((query-expr `(run* (q)
                            (fresh (rid name)
                              (membero (list 'recipe rid name ,spec-id)
                                       (quote ,org-facts))
                              (== q (list rid name)))))
                          (results (evaluate query-expr *org* '()
                                    ($ *org* 'current-expressor))))
                     (if (null? results)
                         (log-append! `(span (@ (class "output-text"))
                                            "No recipes found.\n"))
                         (for-each (lambda (r)
                           (log-append! `(span (@ (class "result-text"))
                                               ,(string-append
                                                  "  " (cadr r) " (" (car r) ")\n"))))
                           results))))
                  (('provenance spec-id _)
                   ;; Find what specs are consumed to produce this spec
                   (let* ((query-expr `(run* (q)
                            (fresh (rid rname pid pid2 pids qty qty2 unit unit2
                                    action action2 rf rf2 fid fid2)
                              (membero (list 'recipe rid rname ,spec-id)
                                       (quote ,org-facts))
                              (membero (list 'chain rid pids)
                                       (quote ,org-facts))
                              (membero (list 'flow pid 'input q qty unit action rf fid)
                                       (quote ,org-facts)))))
                          (results (evaluate query-expr *org* '()
                                    ($ *org* 'current-expressor))))
                     (if (null? results)
                         (log-append! `(span (@ (class "output-text"))
                                            "No inputs found.\n"))
                         (for-each (lambda (spec)
                           (log-append! `(span (@ (class "result-text"))
                                               ,(string-append
                                                  "  needs "
                                                  (%spec-word org-facts spec) "\n"))))
                           results))))
                  (('destination spec-id _)
                   ;; Find what specs can be produced from this spec
                   (let* ((query-expr `(run* (q)
                            (fresh (rid rname out pid pids qty unit action rf fid)
                              (membero (list 'flow pid 'input ,spec-id qty unit action rf fid)
                                       (quote ,org-facts))
                              (membero (list 'chain rid pids)
                                       (quote ,org-facts))
                              (membero (list 'recipe rid rname out)
                                       (quote ,org-facts))
                              (== q out))))
                          (results (evaluate query-expr *org* '()
                                    ($ *org* 'current-expressor))))
                     (if (null? results)
                         (log-append! `(span (@ (class "output-text"))
                                            "No outputs found.\n"))
                         (for-each (lambda (spec)
                           (log-append! `(span (@ (class "result-text"))
                                               ,(string-append
                                                  "  produces "
                                                  (%spec-word org-facts spec) "\n"))))
                           results))))
                  (('demand spec-id qty)
                   (let ((q (if (number? qty) qty 1))
                         (sw (%spec-word org-facts spec-id)))
                     (log-append! `(span (@ (class "output-text"))
                                         ,(string-append
                                            "Planning " (number->string q) " " sw "...\n")))
                     ;; Check inventory first
                     (let* ((inv-expr `(run* (q)
                              (fresh (rid qty loc contained-in)
                                (membero (list 'inventory rid ,spec-id qty loc contained-in)
                                         (quote ,org-facts))
                                (== q (list qty loc)))))
                            (inv (evaluate inv-expr *org* '()
                                   ($ *org* 'current-expressor))))
                       (if (pair? inv)
                           (let ((total (apply + (map car inv))))
                             (log-append! `(span (@ (class "result-text"))
                                                 ,(string-append
                                                    "  inventory: " (number->string total)
                                                    " available\n")))
                             (if (>= total q)
                                 (log-append! `(span (@ (class "result-text"))
                                                     ,(string-append
                                                        "  → satisfied from inventory\n")))
                                 (begin
                                   (log-append! `(span (@ (class "output-text"))
                                                       ,(string-append
                                                          "  → need " (number->string (- q total))
                                                          " more, checking recipes...\n")))
                                   ;; Show recipes that produce this
                                   (let* ((rec-expr `(run* (q)
                                            (fresh (rid name)
                                              (membero (list 'recipe rid name ,spec-id)
                                                       (quote ,org-facts))
                                              (== q name))))
                                          (recipes (evaluate rec-expr *org* '()
                                                     ($ *org* 'current-expressor))))
                                     (for-each (lambda (r)
                                       (log-append! `(span (@ (class "result-text"))
                                                           ,(string-append
                                                              "  → can produce via: " r "\n"))))
                                       recipes)))))
                           (log-append! `(span (@ (class "output-text"))
                                               "  no inventory, checking recipes...\n"))))))
                  (_ (log-append! `(span (@ (class "output-text"))
                                         ,(string-append "Parsed: "
                                            (let ((p (open-output-string)))
                                              (write parsed p)
                                              (get-output-string p)) "\n"))))))))))
    #:unwind? #t))

(define (handle-command exp)
  (match exp
    (('make-org (? string? name))
     (do-make-org! name)
     #t)
    (('enter! (? string? name))
     (let ((org (org-lookup name)))
       (if org
           (do-enter! name)
           (log-append! `(span (@ (class "error-text"))
                               ,(string-append "Unknown org: " name "\n")))))
     #t)
    ('(exit!)
     (if (eq? *mode* 'inner)
         (do-exit!)
         (log-append! `(span (@ (class "error-text")) "Not inside an org.\n")))
     #t)
    ('(list-orgs)
     (if (null? *orgs*)
         (log-append! `(span (@ (class "output-text")) "No orgs created yet.\n"))
         (log-append! `(span (@ (class "output-text"))
                             ,(string-append "Orgs:\n"
                                (let loop ((lst *orgs*) (acc ""))
                                  (if (null? lst) acc
                                      (loop (cdr lst)
                                            (string-append acc "  " (caar lst) "\n"))))))))
     #t)
    (('delete-org (? string? name))
     (do-delete-org! name)
     #t)

    ('(export-ssh-key)
     (do-export-ssh-key!)
     #t)

    ('(signup!)
     (cond
       ((not (eq? *mode* 'inner))
        (log-append! `(span (@ (class "error-text"))
                            "Enter an org first: (make-org \"me\") then (enter! \"me\")\n")))
       ((not *lobby*)
        (log-append! `(span (@ (class "error-text"))
                            "Not connected to gateway. Cannot send signup request.\n")))
       (*signup-pending?*
        (log-append! `(span (@ (class "info-text"))
                            "Signup already in progress. Waiting for server reply...\n")))
       (else
        (log-append!
          `(span (@ (class "info-text"))
                 ,(string-append
                    "── Account Registration ────────────────────────\n"
                    "  Enter your desired username and email, then submit.\n"
                    "  Your org's key will be used as your SSH credential.\n\n"
                    "  Usage: (signup! \"username\" \"email@example.com\")\n")))))
     #t)

    (('signup! (? string? username) (? string? email))
     (do-signup! username email)
     #t)

    ;; ── Donate: show this node's Monero address ──
    ;; Public, unauthenticated. The address belongs to whoever deployed
    ;; this gateway — donations go directly to their hosting wallet.
    ('(donate)
     (cond
       ((not (and *lobby* *connected?*))
        (log-append! `(span (@ (class "error-text"))
                            "Not connected to gateway.\n")))
       (else
        (with-vat *ocapn-vat*
          (on (<- *lobby* 'donation-address)
              (lambda (addr)
                (if (and addr (string? addr))
                    (log-append!
                     `(span (@ (class "info-text"))
                            ,(string-append
                              "── Support this node ─────────────────────────\n"
                              "  Monero donations to the operator of this gateway:\n\n"
                              "  " addr "\n\n"
                              "  (Paid directly to whoever is covering this node's\n"
                              "   hosting costs — no intermediary, no project treasury.)\n")))
                    (log-append!
                     `(span (@ (class "info-text"))
                            "This node has no donation wallet configured.\n"))))
              #:catch
              (lambda (err)
                (log-append!
                 `(span (@ (class "error-text"))
                        ,(string-append
                          "Donation address lookup failed: "
                          (call-with-output-string
                            (lambda (p) (write err p)))
                          "\n"))))))))
     #t)

    ;; ── Express: natural language → Scheme ──

    (('express (? string? text))
     (if (and *lobby* *connected?*)
         (begin
           (do-express-text! text)
           (log-append! `(span (@ (class "info-text"))
                                "Converting to Scheme expression...\n")))
         (log-append! `(span (@ (class "error-text"))
                              "Not connected to relay. Use (ai-eval \"...\") with your own API key.\n")))
     #t)

    ;; ── Cross-org commands ──

    (('join-org (? string? target-name))
     (do-join-org! target-name)
     #t)

    (('approve-member (? number? msg-id) (? string? name))
     (do-approve-member! msg-id name)
     #t)

    ;; act-in — evaluate in another org (local or remote)
    ;; Target can be a string (local org name) or a symbol (looked up → pubkey)
    (('act-in target-expr body-expr)
     (if (not *current-org-name*)
         (log-append! `(span (@ (class "error-text"))
                             "Must be inside an org to act-in another.\n"))
         (let* ((current (org-lookup *current-org-name*))
                ;; Resolve target: if it's a string, use directly.
                ;; If it's a symbol, evaluate it in the org to get a value.
                (target-val (cond
                             ((string? target-expr) target-expr)
                             ((symbol? target-expr)
                              (with-vat *vat*
                                (evaluate target-expr *org* '()
                                          ($ *org* 'current-expressor))))
                             (else target-expr)))
                ;; Check if it's a public key (list starting with 'public-key)
                (is-pubkey? (and (pair? target-val)
                                (eq? (car target-val) 'public-key))))
           (cond
            ;; Target is a public key → introduce via OCapN lobby, then send direct
            ((and is-pubkey? *lobby*)
             (let ((expr-str (call-with-output-string (lambda (p) (write body-expr p)))))
               ;; For now, log the expression. Full P2P messaging requires
               ;; the target to be online and registered by display name.
               ;; TODO: integrate with ^presence 'introduce for direct OCapN P2P
               (log-append! `(span (@ (class "info-text"))
                                   ,(string-append "Sent: " expr-str "\n")))))
            ;; Target is a public key but no gateway
            ((and is-pubkey? (not *lobby*))
             (log-append! `(span (@ (class "error-text"))
                                 "Not connected to gateway.\n")))
            ;; Target is a string — try local controller
            ((string? target-val)
             (let* ((controllers (org-entry-controllers current))
                    (entry (assoc target-val controllers)))
               (if entry
                   (let ((controller (cdr entry))
                         (target (org-lookup target-val)))
                     (with-exception-handler
                       (lambda (exn)
                         (let ((err-port (open-output-string)))
                           (format-exception exn err-port)
                           (log-append! `(span (@ (class "error-text"))
                                               ,(get-output-string err-port)))))
                       (lambda ()
                         ;; The sink runs INSIDE the ai-prompt, so if evaluation
                         ;; suspends at (ai …) and resumes in a later turn (the
                         ;; gateway answering), the result is displayed then —
                         ;; not lost to an early return. A plain expression with
                         ;; no (ai …) resolves the sink synchronously.
                         (define (display-result result)
                           (unless (eq? result (if #f #f))
                             (let ((result-port (open-output-string)))
                               (if (string? result)
                                   (display result result-port)
                                   (write result result-port))
                               (let ((rs (get-output-string result-port)))
                                 (log-append! (lambda () `(span (@ (class "result-text"))
                                                                  ,(string-append "=> " (display-code rs) "\n"))))))))
                         (with-vat (org-entry-vat target)
                           ($ controller 'evaluate-to-sink body-expr display-result))))
                       #:unwind? #t)
                   (log-append! `(span (@ (class "error-text"))
                                       ,(string-append "No controller for: " target-val "\n"))))))
            ;; Unknown target type
            (else
             (log-append! `(span (@ (class "error-text"))
                                 "act-in target must be an org name or a public key.\n"))))))
     #t)

    ('(help)
     (log-append!
       `(span (@ (class "dim-text"))
              "\n────────────────────────────────────────────────\n\n")

       `(span (@ (class "heading-text")) "Getting Started\n\n")
       (cmd-line "  (make-org \"name\")" "      create a local org")
       (cmd-line "  (enter! \"name\")"   "        enter it")
       (cmd-line "  (exit!)"           "               leave current org")
       (cmd-line "  (list-orgs)"       "           show all orgs")
       `(span "\n")

       `(span (@ (class "heading-text")) "Inside an Org\n\n")
       `(span (@ (class "info-text"))
              ,(string-append
                 "Every action has an identity, every change is\n"
                 "remembered, and the rules for changing the rules\n"
                 "are subject to the rules.\n\n"))
       (cmd-line "  (defexpressor 'me \"key\")"              "   create identity")
       (cmd-line "  (as me (modify! 'proposal \"idea\"))"     " act as identity")
       (cmd-line "  (enact! (lambda (e n v pre post) ...))" " add a rule")
       (cmd-line "  (show-history)"                         "                ledger")
       (cmd-line "  (show-expressors)"                      "             identities")
       (cmd-line "  (rollback! 2)"                          "                 undo")
       `(span "\n")

       `(span (@ (class "heading-text")) "AI\n\n")
       (cmd-line "  (set-api-key! \"sk-or-...\")"  "   OpenRouter key")
       (cmd-line "  (set-ai-model! \"openai/gpt-4o\")" " optional")
       (cmd-line "  (ai \"what is the budget?\")"   "    ask AI")
       (cmd-line "  (ai-eval \"create a greeting\")" "  AI writes + runs code")
       `(span "\n")

       `(span (@ (class "heading-text")) "Cross-Org\n\n")
       (cmd-line "  (public-key)"                    "              this org's key")
       (cmd-line "  (join-org \"name\")"               "         request to join")
       (cmd-line "  (approve-member 0 \"alice\")"      "    approve")
       (cmd-line "  (act-in \"name\" (modify! 'x 1))" " act remotely")
       `(span "\n")

       `(span (@ (class "heading-text")) "Signup & SSH\n\n")
       (cmd-line "  (signup! \"user\" \"email@x.com\")" " request account")
       (cmd-line "  (export-ssh-key)"               "            show SSH key")
       `(span (@ (class "info-text"))
              "  After signup: ssh user@<server>\n\n")

       `(span (@ (class "heading-text")) "Language Forms\n\n")
       `(span (@ (class "info-text"))
              ,(string-append
                 "define, lambda, let, let*, letrec, named let,\n"
                 "begin, if, cond, case, and, or, when, unless, do,\n"
                 "quote. Lambdas capture bindings but adopt their\n"
                 "caller's identity — logic and authority are separate.\n\n"))

       `(span (@ (class "heading-text")) "SXML UI\n\n")
       (cmd-line "  (div (@ (class \"box\")) \"content\")"  "")
       (cmd-line "  (span (@ (click handler)) \"clickable\")" "")
       (cmd-line "  (input (@ (id \"x\") (type \"text\")))" "")
       `(span (@ (class "info-text"))
              ,(string-append
                 "\n"
                 "UI composed from S-expressions can be appended\n"
                 "to the log and rendered as live DOM elements.\n\n")))
     #t)

    ;; ── Natural language query ────────────────────────────────────────────
    (('ask (? string? phrase))
     (if (not (eq? *mode* 'inner))
         (log-append! `(span (@ (class "error-text"))
                             "Enter an org first.\n"))
         (do-ask! phrase))
     #t)

    (_ #f)))

(define (eval! str)
  (let* ((prompt (current-prompt))
         (effective-str (if (eq? *syntax-mode* 'wisp)
                            (wisp->sexp-string str)
                            str))
         (sexp-str effective-str))
    (log-append! `(span (@ (class "prompt-text")) ,prompt)
                 (lambda () `(span (@ (class "input-text"))
                                   ,(string-append (display-code sexp-str) "\n"))))
    (history-push! str)
    (let ((port (open-input-string effective-str)))
      (let loop ()
        (let ((exp (read* port)))
        (cond
         ((eof-object? exp) (if #f #f))
         ((eq? exp %invalid)
          (log-append! `(span (@ (class "error-text")) "invalid expression\n"))
          (loop))
         ;; Check for org management commands first
         ((handle-command exp) (loop))
         ;; In inner mode, use the playnet evaluator
         ((eq? *mode* 'inner)
          (eval-play! exp)
          (loop))
         ;; In outer mode, prompt user to enter an org
         (else
          (log-append! `(span (@ (class "info-text"))
                              ,(string-append "Enter an org to evaluate expressions.\n"
                                              "  (make-org \"name\")    create an org\n"
                                              "  (enter! \"name\")      enter it\n")))
          (loop))))))))

;;; ── Auto-resize ───────────────────────────────────────────────────────────

(define (auto-resize event)
  (let ((input (get-element-by-id "expression")))
    (when input
      (set-style! input "height" "auto")
      (set-style! input "height"
                  (string-append (number->string (scroll-height input)) "px")))))

;;; ── Scroll helper ─────────────────────────────────────────────────────────

(define (scroll-to-bottom!)
  (let ((log (get-element-by-id "repl-log")))
    (when log
      (set-scroll-top! log (scroll-height log))
      (let ((expr (get-element-by-id "expression")))
        (when expr (focus-element! expr))))))

;;; ── Event handling ────────────────────────────────────────────────────────

(define (maybe-eval event)
  (let ((key (keyboard-event-key event)))
    (cond
     ((and (string=? key "Enter")
           (not (keyboard-event-shift? event)))
      (prevent-default! event)
      (let* ((input (get-element-by-id "expression"))
             (exp (element-value input)))
        (unless (string=? exp "")
          (set-element-value! input "")
          (set-style! input "height" "auto")
          (set! *current-suggestion* "")
          (eval! exp)
          (refresh!)
          (scroll-to-bottom!))))
     ((and (string=? key "Tab") (not (string=? *current-suggestion* "")))
      (prevent-default! event)
      (let ((input (get-element-by-id "expression")))
        (set-element-value! input (string-append (element-value input) *current-suggestion*))
        (set! *current-suggestion* "")
        (refresh!)))
     ((and (string=? key "Tab") (eq? *syntax-mode* 'wisp))
      (prevent-default! event)
      (let ((input (get-element-by-id "expression")))
        (set-element-value! input (string-append (element-value input) "  "))))
     ((string=? key "ArrowUp")
      (prevent-default! event)
      (when (< (+ *history-index* 1) (length *history*))
        (set! *history-index* (+ *history-index* 1))
        (let ((entry (history-ref *history-index*)))
          (when entry
            (set-element-value! (get-element-by-id "expression") entry)
            (auto-resize event)))))
     ((string=? key "ArrowDown")
      (prevent-default! event)
      (cond
       ((> *history-index* 0)
        (set! *history-index* (- *history-index* 1))
        (let ((entry (history-ref *history-index*)))
          (when entry
            (set-element-value! (get-element-by-id "expression") entry)
            (auto-resize event))))
       ((= *history-index* 0)
        (set! *history-index* -1)
        (set-element-value! (get-element-by-id "expression") "")
        (set-style! (get-element-by-id "expression") "height" "auto")))))))

(define (on-keyup event)
  (let* ((input (get-element-by-id "expression"))
         (str (element-value input))
         (depth (if (eq? *syntax-mode* 'wisp) 0 (compute-paren-depth str))))
    ;; Update paren depth (skip in wisp mode)
    (unless (= depth *paren-depth*)
      (set! *paren-depth* depth))
    ;; Update autocomplete suggestion
    (when (and *org* (eq? *mode* 'inner) (> (string-length str) 0))
      (with-vat *vat*
        (let* ((cursor (string-length str))
               (token (extract-token str cursor))
               (completions (get-completions str cursor *org*)))
          (set! *current-suggestion*
                (if (null? completions)
                    ""
                    (substring (car completions)
                               (string-length token)
                               (string-length (car completions))))))))
    (refresh!)))

;;; ── Sidebar event handlers ───────────────────────────────────────────────

(define (toggle-sidebar! event)
  (set! *sidebar-collapsed* (not *sidebar-collapsed*))
  (refresh!))

(define (sidebar-select-org! name event)
  (set! *sidebar-selected-org* name)
  (set! *expressor-filter* #f)
  (refresh!))

(define (sidebar-enter-org! name event)
  (if (and *current-org-name* (string=? name *current-org-name*))
      (begin (do-exit!) (refresh!) (scroll-to-bottom!))
      (begin (do-enter! name) (refresh!) (scroll-to-bottom!))))

;;; ── Inspector helpers ───────────────────────────────────────────────────

(define (unique-expressors history ref)
  (let loop ((entries history) (seen '()) (result '()))
    (if (null? entries)
        (reverse result)
        (let* ((exp-id (cadr (car entries)))
               (name ($ ref 'expressor-name exp-id)))
          (if (memq name seen)
              (loop (cdr entries) seen result)
              (loop (cdr entries) (cons name seen) (cons exp-id result)))))))

(define (format-value val name ref)
  (cond
    ((procedure? val) (string-append "<proc " (symbol->string name) ">"))
    (($ ref 'expressor? val)
     (string-append "<expressor "
                    (symbol->string (or ($ ref 'expressor-name val) '?)) ">"))
    (else (call-with-output-string (lambda (p) (%write val p))))))

(define (insert-into-repl! text)
  (let ((input (get-element-by-id "expression")))
    (set-element-value! input text)
    (focus-element! input)))

;;; ── Inspector section renderers ─────────────────────────────────────────

(define (render-bindings-section bindings ref)
  `(div (@ (class "section"))
        (div (@ (class "section-header")) "bindings")
        ,@(if (null? bindings)
              (list `(div (@ (class "inspector-row")) "  (empty)"))
              (map (lambda (pair)
                     `(div (@ (class "inspector-row"))
                           (span (@ (class "name clickable")
                                    (click ,(lambda (e) (insert-into-repl! (symbol->string (car pair))))))
                                 ,(symbol->string (car pair)))
                           " "
                           (span (@ (class "value"))
                                 ,(format-value (cdr pair) (car pair) ref))))
                   bindings))))

(define (render-history-section history head-version ref)
  (let* ((branch (ancestor-chain history head-version))
         (filtered (if *expressor-filter*
                       (%filter (lambda (entry)
                                  (eq? ($ ref 'expressor-name (cadr entry))
                                       *expressor-filter*))
                                branch)
                       branch)))
    `(div (@ (class "section"))
          (div (@ (class "section-header"))
               "history"
               ,@(if *expressor-filter*
                     (list `(span (@ (class "filter-badge")
                                     (click ,(lambda (e)
                                               (set! *expressor-filter* #f)
                                               (refresh!))))
                                  ,(string-append " [" (symbol->string *expressor-filter*) " \u00d7]")))
                     '()))
          ,@(if (null? filtered)
                (list `(div (@ (class "inspector-row")) "  (none)"))
                (map (lambda (entry)
                       `(div (@ (class "inspector-row"))
                             (span (@ (class "version clickable")
                                      (click ,(lambda (e)
                                                (insert-into-repl!
                                                  (string-append "(rollback! "
                                                    (number->string (car entry)) ")")))))
                                   ,(string-append "v"
                                      (number->string (car entry))))
                             " "
                             (span (@ (class "expressor-id"))
                                   ,(symbol->string
                                      (or ($ ref 'expressor-name (cadr entry)) '?)))
                             " "
                             (span (@ (class "value"))
                                   ,(call-with-output-string
                                      (lambda (p)
                                        (%write (caddr entry) p))))))
                     filtered)))))

(define (render-expressors-section expressors ref)
  `(div (@ (class "section"))
        (div (@ (class "section-header")) "expressors")
        ,@(if (null? expressors)
              (list `(div (@ (class "inspector-row")) "  (none)"))
              (map (lambda (exp-id)
                     (let ((name (or ($ ref 'expressor-name exp-id) '?)))
                       `(div (@ (class ,(string-append "inspector-row"
                                           (if (and *expressor-filter*
                                                    (eq? name *expressor-filter*))
                                               " active-filter" ""))))
                             (span (@ (class "name clickable")
                                      (click ,(lambda (e)
                                                (if (and *expressor-filter*
                                                         (eq? name *expressor-filter*))
                                                    (set! *expressor-filter* #f)
                                                    (set! *expressor-filter* name))
                                                (refresh!))))
                                   ,(symbol->string name)))))
                   expressors))))

(define (render-validator-section ref)
  (let* ((vexpr ($ ref 'validator-expr))
         (display-text (if (equal? vexpr '(lambda (e n v pre post) #t))
                           "<default>"
                           (call-with-output-string (lambda (p) (%write vexpr p))))))
    `(div (@ (class "section"))
          (div (@ (class "section-header")) "validator")
          (div (@ (class "inspector-row"))
               (span (@ (class "value")) ,display-text)))))

;;; ── UI helpers ───────────────────────────────────────────────────────────

(define (any-blank? strs)
  (and (pair? strs)
       (or (string=? (car strs) "")
           (any-blank? (cdr strs)))))

(define (read-inputs input-specs)
  "Read and trim values from a list of (id placeholder) specs."
  (map (lambda (spec) (%trim (element-value (get-element-by-id (car spec)))))
       input-specs))

(define (render-toggle-form show? set-show! collapsed-label submit-label inputs on-submit)
  "Render a collapsible form. INPUTS is a list of (id placeholder) pairs.
   ON-SUBMIT receives a list of trimmed input values."
  (if show?
      (let ((do-submit (lambda ()
                         (let ((vals (read-inputs inputs)))
                           (unless (any-blank? vals)
                             (on-submit vals)
                             (set-show! #f)
                             (refresh!) (scroll-to-bottom!))))))
        `(div (@ (class "cp-form"))
              ,@(let build ((rest inputs))
                  (if (null? rest) '()
                      (let ((id (car (car rest)))
                            (ph (car (cdr (car rest))))
                            (last? (null? (cdr rest))))
                        (cons `(input (@ (id ,id) (class "cp-input")
                                         (placeholder ,ph)
                                         ,@(if last?
                                               `((keydown ,(lambda (e)
                                                             (when (string=? (keyboard-event-key e) "Enter")
                                                               (prevent-default! e)
                                                               (do-submit)))))
                                               '())))
                              (build (cdr rest))))))
              (div (@ (class "cp-btn-row"))
                   (span (@ (class "cp-btn cp-btn-primary")
                             (click ,(lambda (e) (do-submit))))
                         ,submit-label)
                   (span (@ (class "cp-btn")
                             (click ,(lambda (e) (set-show! #f) (refresh!))))
                         "cancel"))))
      `(span (@ (class "cp-action")
                (click ,(lambda (e) (set-show! #t) (refresh!))))
             ,collapsed-label)))

(define (render-new-org-button)
  (render-toggle-form *show-new-org-form*
    (lambda (v) (set! *show-new-org-form* v))
    "+ new org" "create"
    '(("new-org-input" "org name"))
    (lambda (vals) (do-make-org! (car vals)))))

(define (render-signup-button)
  (render-toggle-form *show-signup-form*
    (lambda (v) (set! *show-signup-form* v))
    "signup" "register"
    '(("signup-username" "username") ("signup-email" "email@example.com"))
    (lambda (vals) (do-signup! (car vals) (car (cdr vals))))))

(define (render-join-form)
  (render-toggle-form *show-join-form*
    (lambda (v) (set! *show-join-form* v))
    "join org" "join"
    '(("join-target-input" "target org name"))
    (lambda (vals) (do-join-org! (car vals)))))

;;; ── Action bar helpers ──────────────────────────────────────────────────

(define (action-button label thunk extra-class)
  "A clickable action bar button. THUNK is called on click, then refresh."
  `(span (@ (class ,(string-append "cp-btn" extra-class))
            (click ,(lambda (e) (thunk) (refresh!) (scroll-to-bottom!))))
         ,label))

(define (eval-button label lisp-cmd wisp-cmd)
  "Action bar button that evaluates a command (syntax-mode aware)."
  (action-button label
    (lambda () (eval! (if (eq? *syntax-mode* 'wisp) wisp-cmd lisp-cmd)))
    ""))

(define (syntax-toggle-button)
  (action-button (if (eq? *syntax-mode* 'wisp) "wisp" "lisp")
    (lambda () (toggle-syntax-mode!))
    (if (eq? *syntax-mode* 'wisp) " cp-btn-primary" "")))

(define (voice-button listening? label-on label-off)
  `(span (@ (class ,(string-append "cp-btn" (if listening? " cp-btn-danger" "")))
            (click ,(lambda (e) (toggle-listening!) (refresh!))))
         ,(if listening? label-on label-off)))

(define (render-online-status)
  `(span (@ (class ,(string-append "cp-status"
                        (if *connected?* " cp-status-connected"
                            " cp-status-disconnected"))))
         ,(if *connected?*
              (if (null? *online-users*)
                  "online"
                  (let loop ((users *online-users*) (acc ""))
                    (if (null? users)
                        (string-append (number->string (length *online-users*))
                                       " online: " acc)
                        (loop (cdr users)
                              (let ((name (if (pair? (car users))
                                              (car (car users)) "?")))
                                (if (string=? acc "") name
                                    (string-append acc ", " name)))))))
              "offline")))

;;; ── Session selectors (scope + acting-as) ──────────────────────────────
;;; Scope and "acting as" are session-level: they span calendar, inventory,
;;; and (informationally) federation. Rendering them in the action-bar
;;; keeps one source of truth and stops each view from re-asking the
;;; question. Views consume *active-scope* / *acting-as* directly;
;;; finer-grained selection (plan within scope) stays in-view.

(define (session-selector id label items current on-change placeholder)
  "Inline dropdown matching the action-bar style. ITEMS is a list of
   alists with 'id and 'name; CURRENT is a string-id or #f."
  (define (opt item)
    (let ((iid (alist-ref item 'id ""))
          (name (alist-ref item 'name "")))
      `(option (@ (value ,iid)
                  ,@(if (equal? iid current) '((selected "selected")) '()))
               ,(if (string=? name "") iid name))))
  `(span (@ (class "session-field"))
         (span (@ (class "session-label")) ,label)
         (select (@ (id ,id)
                    (class "session-select")
                    (change ,on-change))
                 (option (@ (value "")
                            ,@(if current '() '((selected "selected"))))
                         ,placeholder)
                 ,@(map opt items))))

(define (render-session-selectors)
  "Scope + acting-as dropdowns spliced into the action-bar. Only renders
   for scope-anchored tabs and once the scope catalogue is populated.
   Always called from the outer-mode branch of render-action-bar, so
   no need to re-check *mode* here."
  (if (or (not (memq *view* '(federation calendar inventory)))
          (null? *scope-list*))
      '()
      (let ((members (or (and *scope-snapshot*
                              (assq-ref *scope-snapshot* 'members))
                         '())))
        (append
         (list (session-selector "session-scope-select"
                 "scope" *scope-list* *active-scope*
                 (lambda (e) (set-active-scope! (event-target-value e)))
                 "Select a scope…")
               (session-selector "session-acting-as-select"
                 "acting as" members *acting-as*
                 (lambda (e) (set-acting-as! (event-target-value e)))
                 "Observer"))
         ;; live-location toggle — only when acting AS someone (you share YOUR
         ;; position so the planner matches work from where you are).
         (if *acting-as*
             (cons (session-selector "session-location-select"
                     "share location"
                     '(((id . "off")      (name . "Off"))
                       ((id . "here")     (name . "\U0001F4CD I'm here now"))
                       ((id . "live")     (name . "\U0001F6F0 Live"))
                       ((id . "expected") (name . "\U0001F5D3 Expected…")))
                     (symbol->string *location-mode*)
                     (lambda (e) (set-location-mode! (string->symbol (event-target-value e))))
                     "Off")
                   (render-location-expected))    ; per-period place picker, when in 'expected mode
             '())))))

(define (render-session-plan-strip)
  "Plan strip lifted to session level — same reasoning as scope +
   acting-as: it's shared across calendar and inventory and reset
   whenever scope changes, so it belongs above the view, not inside
   each one. Renders only on the tabs that actually consume plans."
  (cond
   ((not (memq *view* '(calendar inventory))) '())
   ((not *active-scope*) '())
   (else
    (let ((plans (or (and *scope-snapshot*
                          (assq-ref *scope-snapshot* 'plans))
                     '())))
      (if (null? plans) '()
          (list (render-plan-bar plans *active-plan* set-active-plan!)))))))


;; The top-right identity button. Label + dot reflect the current
;; identity state (none / locked / active / authenticated). Click
;; toggles the dropdown overlay (rendered separately, see
;; render-identity-dropdown). The button itself anchors the dropdown
;; visually — both share the `.id-btn-anchor` class so CSS can position
;; the dropdown beneath it.
(define (short-aid aid)
  (cond
   ((not (string? aid)) "")
   ((< (string-length aid) 12) aid)
   (else (string-append (substring aid 0 6) "…"
                        (substring aid (- (string-length aid) 4))))))

(define (render-identity-button)
  (let* ((identity *keri-identity*)
         (status (and identity (assq-ref identity 'status)))
         (aid    (and identity (assq-ref identity 'prefix)))
         (label  (cond
                  ((not identity) "Sign in")
                  ((equal? status "locked")
                   (string-append "🔒 unlock " (short-aid aid)))
                  ((equal? status "authenticated")
                   (string-append "🟢 " (short-aid aid)))
                  (else
                   (string-append "🔑 " (short-aid aid)))))
         (cls    (cond
                  ((not identity) "id-btn-anchor id-btn-anchor-cta")
                  ((equal? status "authenticated") "id-btn-anchor id-btn-anchor-auth")
                  (else "id-btn-anchor"))))
    `(span (@ (class ,cls)
              (click ,(lambda (e)
                        (set! *identity-dropdown-open?*
                              (not *identity-dropdown-open?*))
                        (refresh!))))
           ,label)))

(define (render-action-bar)
  `(div (@ (class "action-bar"))
        ,@(if (eq? *mode* 'outer)
              `(,(action-button "+ new org"
                   (lambda () (set! *show-new-org-form* #t)) " cp-btn-primary")
                ;; Session-level scope + acting-as selectors. Render
                ;; inline so the top strip is one row.
                ,@(render-session-selectors)
                ;; SSH-based signup hidden until email/provisioning
                ;; is wired (see docs/keri/IMPLEMENTATION.md §6).
                ;; The KERI identity flow lives in the top-right
                ;; identity button (see render-identity-button); the
                ;; old SSH `do-signup!` + form renderer remain intact
                ;; for re-enablement.
                ;; relay status + wisp/lisp toggle are only relevant
                ;; on the playnet tab (where REPL evaluation happens);
                ;; hide them on federation / calendar / inventory / map.
                ,@(if (eq? *view* 'home)
                      (list (if (and *lobby* *connected?*)
                                `(span (@ (class "cp-status")) "relay: connected")
                                `(span (@ (class "cp-status")) "relay: disconnected"))
                            (syntax-toggle-button))
                      '())
                ,(render-identity-button))
              (list (action-button "exit" (lambda () (do-exit!)) "")
                    (eval-button "history" "(show-history)" "show-history")
                    (eval-button "expressors" "(show-expressors)" "show-expressors")
                    (eval-button "public key" "(public-key)" "public-key")
                    (action-button "ssh key" (lambda () (do-export-ssh-key!)) "")
                    (render-join-form)
                    (action-button "terminal"
                      (lambda ()
                        (if *terminal-active?*
                            (close-terminal!)
                            (open-terminal!)))
                      (if *terminal-active?* " cp-btn-danger" ""))
                    (syntax-toggle-button)
                    (voice-button (and *listening?* (not *expressing?*))
                                  "stop" "voice to text")
                    `(span (@ (class ,(string-append "cp-btn"
                                         (if *expressing?* " cp-btn-danger" "")))
                              (click ,(lambda (e) (toggle-expressing!) (refresh!))))
                           ,(if *expressing?* "stop" "voice to code"))
                    (render-online-status)
                    (render-identity-button)))))

;;; ── Sidebar rendering ──────────────────────────────────────────────────

(define (render-org-item org-pair)
  (let* ((name (car org-pair))
         (selected? (and *sidebar-selected-org*
                         (string=? name *sidebar-selected-org*)))
         (active? (and *current-org-name*
                       (string=? name *current-org-name*))))
    `(div (@ (class ,(string-append "org-item"
                        (if selected? " selected" "")
                        (if active? " active" "")))
             (click ,(lambda (e) (sidebar-select-org! name e))))
          (span (@ (class "org-name"))
                ,(string-append (if active? "> " "  ") name)))))

(define (render-org-list)
  `(div (@ (class "org-list"))
        ,@(if (null? *orgs*)
              (list `(div (@ (class "sidebar-empty"))
                          "No orgs yet.\nClick \"+ new org\" above or use\n(make-org \"name\") in the REPL."))
              (map render-org-item *orgs*))))

(define (render-org-detail-actions name active?)
  `(div (@ (class "inspector-actions"))
        (span (@ (class ,(string-append "cp-btn" (if active? "" " cp-btn-primary")))
                  (click ,(lambda (e) (sidebar-enter-org! name e))))
              ,(if active? "exit" "enter"))
        ,@(if (and *confirm-delete-org*
                   (string=? *confirm-delete-org* name))
              (list `(span (@ (class "cp-confirm")) "delete?")
                    `(span (@ (class "cp-btn cp-btn-danger")
                              (click ,(lambda (e)
                                        (do-delete-org! name)
                                        (set! *confirm-delete-org* #f)
                                        (set! *sidebar-selected-org* #f)
                                        (refresh!) (scroll-to-bottom!))))
                           "yes")
                    `(span (@ (class "cp-btn")
                              (click ,(lambda (e)
                                        (set! *confirm-delete-org* #f)
                                        (refresh!))))
                           "no"))
              (list `(span (@ (class "cp-btn cp-btn-danger")
                              (click ,(lambda (e)
                                        (set! *confirm-delete-org* name)
                                        (refresh!))))
                           "delete")))))

(define (render-org-detail name)
  (let* ((org (or (org-lookup name)
                  (and *current-org-name* (string=? name *current-org-name*)
                       (cons name (cons *vat* (cons *org* '()))))))
         (vat (and org (org-entry-vat org)))
         (ref (and org (org-entry-ref org))))
    (if (not ref) ""
        (with-vat vat
          (let* ((active? (and *current-org-name* (string=? name *current-org-name*)))
                 (bindings ($ ref 'bindings))
                 (history ($ ref 'history))
                 (expressors (unique-expressors history ref)))
            `(div (@ (class "org-detail"))
                  (div (@ (class "detail-header"))
                       (span (@ (class "org-name")) ,name))
                  ,(render-org-detail-actions name active?)
                  ,(render-bindings-section bindings ref)
                  ,(render-validator-section ref)
                  ,(render-history-section history ($ ref 'head-version) ref)
                  ,(render-expressors-section expressors ref)))))))

(define (render-sidebar)
  (if *sidebar-collapsed*
      ""
      `(div (@ (class "sidebar"))
            (div (@ (class "sidebar-header"))
                 (span (@ (class "sidebar-toggle") (click ,toggle-sidebar!))
                       "\u00ab")
                 (span (@ (class "sidebar-title")) " orgs"))
            ,(render-new-org-button)
            ,(render-org-list)
            ,@(if *sidebar-selected-org*
                  (list (render-org-detail *sidebar-selected-org*))
                  '())
            ,@(if *show-signup-form*
                  (list (render-signup-button))
                  '()))))

;;; ── Render ────────────────────────────────────────────────────────────────

(define (paren-indicator)
  (if (eq? *syntax-mode* 'wisp)
      ""
      (cond
       ((= *paren-depth* 0) "")
       ((> *paren-depth* 0)
        (string-append "(" (number->string *paren-depth*) " open)"))
       (else
        (string-append (number->string (- *paren-depth*)) " extra )")))))

(define (render-repl)
  `(div (@ (id "repl") (class "repl repl-text"))
        (div (@ (id "repl-log") (class "log"))
             ,@(map (lambda (e) (if (procedure? e) (e) e)) *log*))
        ,@(if *pending-transcript* (list (render-mic-options)) '())
        (div (@ (class "prompt"))
             ,(current-prompt)
             (textarea (@ (id "expression") (class "repl-text")
                          (rows "1") (keydown ,maybe-eval)
                          (keyup ,on-keyup) (input ,auto-resize)))
             ,@(if (string=? *current-suggestion* "")
                   '()
                   (list `(span (@ (class "ghost-text-suggestion"))
                                ,*current-suggestion*)))
             (span (@ (class "paren-indicator")) ,(paren-indicator))
             (span (@ (class ,(string-append "mic-btn"
                                  (if *listening?* " mic-active" "")))
                      (click ,(lambda (e) (toggle-mic!) (refresh!))))
                   ,(if *listening?* "⏹" "🎤")))))

(define (render-mic-options)
  `(div (@ (class "mic-options"))
        (div (@ (class "mic-option")
                 (click ,(lambda (e) (commit-pending-as-input!))))
             (div (@ (class "mic-option-label")) "🗣 dictate to input")
             (div (@ (class "mic-option-body")) ,*pending-transcript*))
        (div (@ (class "mic-option")
                 (click ,(lambda (e) (commit-pending-as-ask!))))
             (div (@ (class "mic-option-label")) "🎤 ask")
             (div (@ (class "mic-option-body"))
                  ,(string-append "(ask \"" *pending-transcript* "\")")))
        (span (@ (class "mic-option-dismiss")
                  (click ,(lambda (e) (dismiss-pending!))))
              "✕")))

(define (render-tab-bar)
  `(div (@ (class "tab-bar"))
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'home)) " tab-active" "")))
                (click ,(lambda (e)
                          (if (eq? *mode* 'inner)
                              (begin (do-exit!) (set! *view* 'home) (refresh!) (scroll-to-bottom!))
                              (begin (set! *view* 'home) (refresh!))))))
             "playnet")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'federation)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'federation) (refresh!))))
             "federation")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'surface)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'surface) (refresh!))))
             "surface")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'calendar)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (when (not *cal-week-start*)
                            (set! *cal-week-start*
                                  (day-start-ms (inexact->exact (floor (date-now))))))
                          ;; Honour URL hash, then fire an async snapshot
                          ;; fetch from the planner-service. The first
                          ;; render shows whatever's already in the
                          ;; globals; ingest-snapshot! triggers another
                          ;; render once the reply arrives.
                          (parse-cal-hash!)
                          (refresh-scope-snapshot!)
                          (set-location-hash! (cal-hash))
                          (set! *view* 'calendar) (refresh!)
                          (let ((w (get-element-by-id "cal-grid-wrap")))
                            (when w (set-scroll-top! w 480))))))
             "calendar")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'inventory)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'inventory)
                          ;; Inventory shares scope/plan state with the
                          ;; calendar tab. Make sure the scope list is
                          ;; populated and fire an inventory snapshot.
                          (refresh-inventory-snapshot!)
                          (refresh!))))
             "inventory")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'map)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'map)
                          (refresh!)
                          (schedule-map-mount!))))
             "map")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'contacts)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'contacts)
                          (set! *contacts-error* #f)
                          (refresh!))))
             "contacts")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'recipes)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'recipes)
                          (refresh!))))
             "recipes")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'priorities)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (prio-load-tree!)
                          (set! *view* 'priorities)
                          (refresh!))))
             "priorities")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'clock)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'clock)
                          (refresh!))))
             "clock")
        ;; Identity moved out of the tab strip — see render-identity-button
        ;; in the action bar and the dropdown overlay rendered alongside
        ;; the outer view. The identity-tab slot here is intentionally
        ;; empty.
        ,@(map (lambda (org-entry)
                 (let* ((name (org-entry-name org-entry))
                        (active? (and (eq? *mode* 'inner) *current-org-name*
                                      (string=? name *current-org-name*))))
                   `(div (@ (class ,(string-append "tab" (if active? " tab-active" "")))
                            (click ,(lambda (e)
                                      (if active?
                                          (begin (do-exit!) (refresh!) (scroll-to-bottom!))
                                          (begin (do-enter! name) (refresh!) (scroll-to-bottom!))))))
                         ,name)))
               *orgs*)))

(define (render-code-viewer)
  (cond
    (*terminal-active?*
     `(div (@ (id "terminal-container") (class "code-viewer"))
           (div (@ (class "code-viewer-header"))
                "terminal"
                (span (@ (class "cp-btn cp-btn-danger")
                          (click ,(lambda (e) (close-terminal!))))
                      "close"))
           (div (@ (id "xterm-mount") (class "terminal-mount")))))
    ((string=? *code-viewer-content* "")
     `(div))
    (else
     `(div (@ (id "code-viewer") (class "code-viewer"))
           (div (@ (class "code-viewer-header"))
                ,(string-append "organization code ("
                   (if (eq? *syntax-mode* 'wisp) "wisp" "lisp") ")"))
           (pre (@ (id "code-viewer-content") (class "code-viewer-content"))
                ,*code-viewer-content*)))))

(define (render-ui-widgets)
  "Render SXML widgets from the org's ui-widgets binding (governed UI composition)."
  (if (and *org* *vat* (eq? *mode* 'inner))
      (let ((widgets (with-vat *vat*
                       ($ *org* 'lookup-or-false 'ui-widgets))))
        (if (and widgets (pair? widgets))
            `(div (@ (class "ui-widgets")) ,@widgets)
            `(div)))
      `(div)))

;;; ── Federation view sample data ──────────────────────────────────────────────

(define *fed-scopes*
  (list
   `((id . "universal-commune") (parent . #f))
   ;; Mediterranean federations
   `((id . "agri-federation")            (parent . "universal-commune"))
   `((id . "manufacturing-federation")   (parent . "universal-commune"))
   `((id . "maritime-federation")        (parent . "universal-commune"))
   `((id . "horticulture-federation")    (parent . "universal-commune"))
   `((id . "food-processing-federation") (parent . "universal-commune"))
   ;; Frontier Tower federation — tech / culture commune
   `((id . "frontier-tower")             (parent . "universal-commune"))
   ;; Agri communes
   `((id . "commune-grain")    (parent . "agri-federation"))
   `((id . "commune-dairy")    (parent . "agri-federation"))
   `((id . "commune-herder")   (parent . "agri-federation"))
   ;; Manufacturing communes
   `((id . "commune-forge")    (parent . "manufacturing-federation"))
   `((id . "commune-workshop") (parent . "manufacturing-federation"))
   `((id . "commune-textile")  (parent . "manufacturing-federation"))
   ;; Maritime
   `((id . "commune-fisher")   (parent . "maritime-federation"))
   `((id . "commune-salter")   (parent . "maritime-federation"))
   ;; Horticulture
   `((id . "commune-olive")    (parent . "horticulture-federation"))
   `((id . "commune-citrus")   (parent . "horticulture-federation"))
   `((id . "commune-vinyard")  (parent . "horticulture-federation"))
   ;; Food processing
   `((id . "commune-mill")     (parent . "food-processing-federation"))
   `((id . "commune-bakery")   (parent . "food-processing-federation"))
   `((id . "commune-brewery")  (parent . "food-processing-federation"))
   ;; Frontier Tower sub-scopes
   `((id . "ft-coliving")      (parent . "frontier-tower"))
   `((id . "ft-events")        (parent . "frontier-tower"))
   `((id . "ft-robotics")      (parent . "frontier-tower"))
   `((id . "ft-arts")          (parent . "frontier-tower"))))

;;; ── Federation sources ──────────────────────────────────────────────
;;;
;;; The ground truth lives here: each scope's *demands* (what it wants),
;;; its *resources* (what it has), its *commitments* (its plan), and the
;;; federation-wide *trades* (proposed flows between scopes).  Results
;;; — surplus / deficits / fulfillment — are DERIVED from these via the
;;; solver in (playnet ui federation-solver). Don't author results
;;; manually: change a demand, a commitment, or a trade and the graph
;;; will follow.

;; What each scope wants. Spec, quantity, unit. Demands beyond what the
;; local plan + inbound trades cover surface as deficits.
(define *fed-demands*
  '(("commune-grain"
     ((spec . "bread") (qty . 45) (unit . "loaves"))
     ((spec . "salt")  (qty . 20) (unit . "kg"))
     ((spec . "tools") (qty . 8)  (unit . "pcs")))
    ("commune-dairy"
     ((spec . "bread") (qty . 30) (unit . "loaves"))
      ((spec . "tools") (qty . 5)  (unit . "pcs"))
      ((spec . "salt")  (qty . 10) (unit . "kg"))
      ((spec . "wheat") (qty . 100) (unit . "kg"))
      ((spec . "feed")  (qty . 50)  (unit . "kg")))
    ("commune-herder"
     ((spec . "tools") (qty . 6)  (unit . "pcs"))
      ((spec . "bread") (qty . 25) (unit . "loaves"))
      ((spec . "feed")  (qty . 80) (unit . "kg")))
    ("commune-forge"
     ((spec . "bread") (qty . 40) (unit . "loaves"))
      ((spec . "fish")  (qty . 30) (unit . "kg"))
      ((spec . "ore")   (qty . 80) (unit . "kg")))
    ("commune-workshop"
     ((spec . "leather") (qty . 12) (unit . "kg"))
      ((spec . "bread")   (qty . 35) (unit . "loaves"))
      ((spec . "tools")   (qty . 40) (unit . "pcs")))
    ("commune-textile"
     ((spec . "tools") (qty . 4)  (unit . "pcs"))
      ((spec . "bread") (qty . 30) (unit . "loaves"))
      ((spec . "wool")  (qty . 60) (unit . "kg")))
    ("commune-fisher"
     ((spec . "salt")  (qty . 30) (unit . "kg"))
      ((spec . "bread") (qty . 25) (unit . "loaves"))
      ((spec . "tools") (qty . 6)  (unit . "pcs")))
    ("commune-salter"
     ((spec . "bread") (qty . 20) (unit . "loaves"))
      ((spec . "fish")  (qty . 25) (unit . "kg"))
      ((spec . "cloth") (qty . 10) (unit . "m²")))
    ("commune-olive"
     ((spec . "salt")      (qty . 8)  (unit . "kg"))
      ((spec . "bread")     (qty . 18) (unit . "loaves"))
      ((spec . "olive-oil") (qty . 60) (unit . "L")))
    ("commune-citrus"
     ((spec . "bread") (qty . 20) (unit . "loaves"))
      ((spec . "tools") (qty . 4)  (unit . "pcs")))
    ("commune-vinyard"
     ((spec . "tools") (qty . 5)  (unit . "pcs"))
      ((spec . "bread") (qty . 22) (unit . "loaves")))
    ("commune-mill"
     ((spec . "wheat") (qty . 200) (unit . "kg"))
      ((spec . "tools") (qty . 6)   (unit . "pcs")))
    ("commune-bakery"
     ((spec . "dairy") (qty . 20) (unit . "L"))
      ((spec . "salt")  (qty . 12) (unit . "kg"))
      ((spec . "flour") (qty . 80) (unit . "kg")))
    ("commune-brewery"
     ((spec . "grapes") (qty . 120) (unit . "kg"))
      ((spec . "wheat")  (qty . 80)  (unit . "kg"))
      ((spec . "bread")  (qty . 15)  (unit . "loaves")))
    ("ft-coliving"
     ((spec . "bread")  (qty . 60) (unit . "loaves"))
      ((spec . "dairy")  (qty . 40) (unit . "L"))
      ((spec . "fish")   (qty . 30) (unit . "kg"))
      ((spec . "citrus") (qty . 20) (unit . "kg"))
      ((spec . "ale")    (qty . 15) (unit . "L")))
    ("ft-events"
     ((spec . "bread") (qty . 30) (unit . "loaves"))
      ((spec . "wine")  (qty . 25) (unit . "L"))
      ((spec . "ale")   (qty . 20) (unit . "L")))
    ("ft-robotics"
     ((spec . "tools") (qty . 60) (unit . "pcs"))
      ((spec . "ore")   (qty . 35) (unit . "kg"))
      ((spec . "bread") (qty . 25) (unit . "loaves")))
    ("ft-arts"
     ((spec . "cloth") (qty . 8)  (unit . "m²"))
      ((spec . "bread") (qty . 18) (unit . "loaves"))
      ((spec . "wine")  (qty . 10) (unit . "L")))))

(define *fed-trades*
  (list
   ;; Within agri
   `((id . "t1")  (from . "commune-grain")    (to . "commune-dairy")    (spec . "wheat")  (qty . 200))
   `((id . "t2")  (from . "commune-grain")    (to . "commune-herder")   (spec . "feed")   (qty . 60))
   `((id . "t3")  (from . "commune-grain")    (to . "commune-mill")     (spec . "wheat")  (qty . 200))
   ;; Maritime
   `((id . "t4")  (from . "commune-fisher")   (to . "commune-salter")   (spec . "fish")   (qty . 25))
   `((id . "t5")  (from . "commune-salter")   (to . "commune-bakery")   (spec . "salt")   (qty . 50))
   `((id . "t6")  (from . "commune-salter")   (to . "commune-fisher")   (spec . "salt")   (qty . 30))
   ;; Manufacturing chain
   `((id . "t7")  (from . "commune-forge")    (to . "commune-workshop") (spec . "tools")  (qty . 12))
   `((id . "t8")  (from . "commune-herder")   (to . "commune-textile")  (spec . "wool")   (qty . 35))
   `((id . "t9")  (from . "commune-herder")   (to . "commune-workshop") (spec . "leather")(qty . 12))
   ;; Horticulture → food-processing
   `((id . "t10") (from . "commune-olive")    (to . "commune-mill")     (spec . "olive-oil") (qty . 10))
   `((id . "t11") (from . "commune-citrus")   (to . "commune-bakery")   (spec . "citrus") (qty . 30))
   `((id . "t12") (from . "commune-vinyard")  (to . "commune-brewery")  (spec . "grapes") (qty . 120))
   ;; Food-processing internal
   `((id . "t13") (from . "commune-mill")     (to . "commune-bakery")   (spec . "flour")  (qty . 60))
   `((id . "t14") (from . "commune-bakery")   (to . "commune-brewery")  (spec . "bread")  (qty . 15))
   ;; Bakery feeds many communes
   `((id . "t15") (from . "commune-bakery")   (to . "commune-forge")    (spec . "bread")  (qty . 40))
   `((id . "t16") (from . "commune-bakery")   (to . "commune-fisher")   (spec . "bread")  (qty . 25))
   `((id . "t17") (from . "commune-bakery")   (to . "ft-coliving")      (spec . "bread")  (qty . 60))
   ;; Frontier-Tower demand pull from Mediterranean
   `((id . "t18") (from . "commune-dairy")    (to . "ft-coliving")      (spec . "dairy")  (qty . 25))
   `((id . "t19") (from . "commune-fisher")   (to . "ft-coliving")      (spec . "fish")   (qty . 30))
   `((id . "t20") (from . "commune-citrus")   (to . "ft-coliving")      (spec . "citrus") (qty . 20))
   `((id . "t21") (from . "commune-brewery")  (to . "ft-events")        (spec . "wine")   (qty . 25))
   `((id . "t22") (from . "commune-brewery")  (to . "ft-events")        (spec . "ale")    (qty . 20))
   `((id . "t23") (from . "commune-forge")    (to . "ft-robotics")      (spec . "tools")  (qty . 48))
   `((id . "t24") (from . "commune-textile")  (to . "ft-arts")          (spec . "cloth")  (qty . 8))))

;; Kept for reference / fallback; the live *fed-events* is derived
;; below from results + trades by compute-fed-events.
(define %fed-events-manual%
  (list
   ;; Round 0: every commune declares its plan
   `((round . 0) (kind . scope-planned) (scope-id . "commune-grain"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-dairy"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-herder"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-forge"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-workshop"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-textile"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-fisher"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-salter"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-olive"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-citrus"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-vinyard"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-mill"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-bakery"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-brewery"))
   `((round . 0) (kind . scope-planned) (scope-id . "ft-coliving"))
   `((round . 0) (kind . scope-planned) (scope-id . "ft-events"))
   `((round . 0) (kind . scope-planned) (scope-id . "ft-robotics"))
   `((round . 0) (kind . scope-planned) (scope-id . "ft-arts"))
   ;; Round 0: deficits announced
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-dairy")    (spec-id . "wheat")     (qty . 200))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-herder")   (spec-id . "feed")      (qty . 60))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-workshop") (spec-id . "tools")     (qty . 12))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-textile")  (spec-id . "wool")      (qty . 35))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-olive")    (spec-id . "olive-oil") (qty . 15))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-bakery")   (spec-id . "flour")     (qty . 20))
   `((round . 0) (kind . deficit-announced) (scope-id . "ft-coliving")      (spec-id . "bread")     (qty . 60))
   `((round . 0) (kind . deficit-announced) (scope-id . "ft-coliving")      (spec-id . "dairy")     (qty . 25))
   `((round . 0) (kind . deficit-announced) (scope-id . "ft-coliving")      (spec-id . "fish")      (qty . 30))
   `((round . 0) (kind . deficit-announced) (scope-id . "ft-robotics")      (spec-id . "tools")     (qty . 48))
   `((round . 0) (kind . deficit-announced) (scope-id . "ft-robotics")      (spec-id . "ore")       (qty . 35))
   ;; Round 0: surpluses offered
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-grain")    (spec-id . "wheat")     (qty . 670))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-dairy")    (spec-id . "dairy")     (qty . 45))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-herder")   (spec-id . "wool")      (qty . 120))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-fisher")   (spec-id . "fish")      (qty . 262))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-salter")   (spec-id . "salt")      (qty . 475))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-citrus")   (spec-id . "citrus")    (qty . 120))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-vinyard")  (spec-id . "grapes")    (qty . 280))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-textile")  (spec-id . "cloth")     (qty . 80))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-brewery")  (spec-id . "ale")       (qty . 60))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-brewery")  (spec-id . "wine")      (qty . 40))
   ;; Round 1: lateral matches within federations
   `((round . 1) (kind . lateral-match) (scope-id . "commune-grain")   (target-scope-id . "commune-dairy")   (spec-id . "wheat") (qty . 200))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-grain")   (target-scope-id . "commune-herder")  (spec-id . "feed")  (qty . 60))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-fisher")  (target-scope-id . "commune-salter")  (spec-id . "fish")  (qty . 25))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-salter")  (target-scope-id . "commune-bakery")  (spec-id . "salt")  (qty . 50))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-forge")   (target-scope-id . "commune-workshop")(spec-id . "tools") (qty . 12))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-herder")  (target-scope-id . "commune-textile") (spec-id . "wool")  (qty . 35))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-citrus")  (target-scope-id . "commune-bakery")  (spec-id . "citrus") (qty . 30))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-vinyard") (target-scope-id . "commune-brewery") (spec-id . "grapes") (qty . 120))
   ;; Round 2: cross-federation flows (Mediterranean ↔ Frontier Tower)
   `((round . 2) (kind . cross-fed-match) (scope-id . "commune-bakery") (target-scope-id . "ft-coliving") (spec-id . "bread")  (qty . 60))
   `((round . 2) (kind . cross-fed-match) (scope-id . "commune-dairy")  (target-scope-id . "ft-coliving") (spec-id . "dairy")  (qty . 25))
   `((round . 2) (kind . cross-fed-match) (scope-id . "commune-fisher") (target-scope-id . "ft-coliving") (spec-id . "fish")   (qty . 30))
   `((round . 2) (kind . cross-fed-match) (scope-id . "commune-forge")  (target-scope-id . "ft-robotics") (spec-id . "tools")  (qty . 48))
   `((round . 2) (kind . cross-fed-match) (scope-id . "commune-brewery") (target-scope-id . "ft-events")  (spec-id . "wine")   (qty . 25))
   `((round . 2) (kind . cross-fed-match) (scope-id . "commune-textile") (target-scope-id . "ft-arts")    (spec-id . "cloth")  (qty . 8))))

(define *fed-resources*
  (list
   (cons "commune-grain"
         (list `((id . "r1")  (conforms-to . "wheat")    (name . "Wheat Reserve")  (onhand . 670) (unit . "kg"))
               `((id . "r1b") (conforms-to . "seed")     (name . "Seed Bank")      (onhand . 40)  (unit . "kg"))))
   (cons "commune-dairy"
         (list `((id . "r2")  (conforms-to . "dairy")    (name . "Dairy Stock")    (onhand . 45)  (unit . "L"))
               `((id . "r2b") (conforms-to . "cheese")   (name . "Cheese Wheels")  (onhand . 18)  (unit . "wheel"))))
   (cons "commune-herder"
         (list `((id . "r2c") (conforms-to . "wool")     (name . "Wool Stock")     (onhand . 120) (unit . "kg"))
               `((id . "r2d") (conforms-to . "leather")  (name . "Leather Hides")  (onhand . 35)  (unit . "kg"))))
   (cons "commune-forge"
         (list `((id . "r3")  (conforms-to . "tools")    (name . "Tool Stock")     (onhand . 70)  (unit . "pcs"))
               `((id . "r4")  (conforms-to . "ore")      (name . "Iron Ore")       (onhand . 200) (unit . "kg"))
               `((id . "r4b") (conforms-to . "metal")    (name . "Iron Ingots")    (onhand . 50)  (unit . "kg"))))
   (cons "commune-workshop"
         (list `((id . "r11") (conforms-to . "goods")    (name . "Goods Stock")    (onhand . 35)  (unit . "pcs"))
               `((id . "r11b")(conforms-to . "tools")    (name . "Workshop Tools") (onhand . 22)  (unit . "pcs"))))
   (cons "commune-textile"
         (list `((id . "r12") (conforms-to . "cloth")    (name . "Cloth Bolts")    (onhand . 80)  (unit . "m²"))))
   (cons "commune-fisher"
         (list `((id . "r5")  (conforms-to . "fish")     (name . "Fish Stock")     (onhand . 262) (unit . "kg"))))
   (cons "commune-salter"
         (list `((id . "r6")  (conforms-to . "salt")     (name . "Salt Reserve")   (onhand . 475) (unit . "kg"))))
   (cons "commune-olive"
         (list `((id . "r7")  (conforms-to . "olive-oil")(name . "Olive Oil")      (onhand . 45)  (unit . "L"))
               `((id . "r7b") (conforms-to . "olives")   (name . "Fresh Olives")   (onhand . 45)  (unit . "kg"))))
   (cons "commune-citrus"
         (list `((id . "r8")  (conforms-to . "citrus")   (name . "Citrus Fruits")  (onhand . 120) (unit . "kg"))))
   (cons "commune-vinyard"
         (list `((id . "r8b") (conforms-to . "grapes")   (name . "Grape Harvest")  (onhand . 280) (unit . "kg"))))
   (cons "commune-mill"
         (list `((id . "r9")  (conforms-to . "flour")    (name . "Flour Reserve")  (onhand . 180) (unit . "kg"))))
   (cons "commune-bakery"
         (list `((id . "r10") (conforms-to . "bread")    (name . "Bread Stock")    (onhand . 90)  (unit . "loaves"))
               `((id . "r10b")(conforms-to . "dough")    (name . "Dough Batch")    (onhand . 25)  (unit . "kg"))))
   (cons "commune-brewery"
         (list `((id . "r13") (conforms-to . "ale")      (name . "Ale Casks")      (onhand . 60)  (unit . "L"))
               `((id . "r14") (conforms-to . "wine")     (name . "Wine Barrels")   (onhand . 40)  (unit . "L"))))
   (cons "ft-coliving"
         (list `((id . "r15") (conforms-to . "meals")    (name . "Prepared Meals") (onhand . 25)  (unit . "serving"))))
   (cons "ft-events"
         (list `((id . "r16") (conforms-to . "event-tickets") (name . "Event Tickets") (onhand . 90) (unit . "ticket"))))
   (cons "ft-robotics"
         (list `((id . "r17") (conforms-to . "robots")   (name . "Robot Units")    (onhand . 18)  (unit . "unit"))))
   (cons "ft-arts"
         (list `((id . "r18") (conforms-to . "media-content") (name . "Media Pieces") (onhand . 45) (unit . "piece"))))))

(define *fed-spec-names*
  '(;; Agri
    ("wheat" . "Wheat") ("seed" . "Seed") ("feed" . "Feed")
    ("dairy" . "Dairy") ("cheese" . "Cheese")
    ("wool" . "Wool") ("leather" . "Leather")
    ;; Manufacturing
    ("tools" . "Tools") ("ore" . "Iron Ore") ("metal" . "Iron Metal")
    ("goods" . "Goods") ("cloth" . "Cloth")
    ;; Maritime
    ("fish" . "Fish") ("raw-fish" . "Raw Fish") ("salt" . "Salt") ("bait" . "Bait")
    ;; Horticulture
    ("olive-oil" . "Olive Oil") ("olives" . "Olives")
    ("citrus" . "Citrus") ("grapes" . "Grapes")
    ;; Food processing
    ("flour" . "Flour") ("coarse-flour" . "Coarse Flour")
    ("bread" . "Bread") ("dough" . "Dough")
    ("ale" . "Ale") ("wine" . "Wine") ("malt" . "Malt")
    ;; Frontier Tower
    ("meals" . "Meals") ("event-tickets" . "Event Tickets")
    ("robots" . "Robots") ("media-content" . "Media Content")
    ;; Common
    ("labor" . "Labour") ("wheat-raw" . "Raw Wheat") ("raw-milk" . "Raw Milk")
    ("ingots" . "Ingots")))

;; Sample processes and commitments per scope (for network diagrams)
(define *fed-processes*
  `(("commune-grain"    . (((id . "harvest") (name . "Wheat Harvest"))
                            ((id . "thresh")  (name . "Threshing"))))
    ("commune-dairy"    . (((id . "milk")    (name . "Milking"))
                            ((id . "pasteur") (name . "Pasteurize"))))
    ("commune-herder"   . (((id . "graze")   (name . "Grazing"))
                            ((id . "shear")   (name . "Shearing"))
                            ((id . "tan")     (name . "Tanning"))))
    ("commune-forge"    . (((id . "smelt")   (name . "Smelting"))
                            ((id . "forge")   (name . "Forging"))))
    ("commune-workshop" . (((id . "assemble") (name . "Assembly"))
                            ((id . "finish")   (name . "Finishing"))))
    ("commune-textile"  . (((id . "spin")    (name . "Spinning"))
                            ((id . "weave")   (name . "Weaving"))))
    ("commune-fisher"   . (((id . "catch")   (name . "Fishing"))
                            ((id . "prep")    (name . "Filleting"))))
    ("commune-salter"   . (((id . "evap")    (name . "Salt Evaporation"))))
    ("commune-olive"    . (((id . "pick")    (name . "Olive Harvest"))
                            ((id . "press")   (name . "Olive Pressing"))))
    ("commune-citrus"   . (((id . "pick-c")  (name . "Citrus Harvest"))))
    ("commune-vinyard"  . (((id . "tend")    (name . "Vine Tending"))
                            ((id . "pick-g")  (name . "Grape Harvest"))))
    ("commune-mill"     . (((id . "grind")   (name . "Grinding"))
                            ((id . "sift")    (name . "Sifting"))))
    ("commune-bakery"   . (((id . "mix")     (name . "Mixing"))
                            ((id . "bake")    (name . "Baking"))))
    ("commune-brewery"  . (((id . "malt")    (name . "Malting"))
                            ((id . "ferment") (name . "Fermentation"))
                            ((id . "press-w") (name . "Wine Pressing"))))
    ("ft-coliving"      . (((id . "kitchen") (name . "Kitchen Service"))))
    ("ft-events"        . (((id . "prod")    (name . "Event Production"))))
    ("ft-robotics"      . (((id . "design")  (name . "Robot Design"))
                            ((id . "fab")     (name . "Fabrication"))))
    ("ft-arts"          . (((id . "create")  (name . "Media Creation"))))))

(define *fed-commitments*
  `(("commune-grain" . (((id . "cg1") (input-of . "harvest") (resource-conforms-to . "seed") (action . consume) (qty . 50) (unit . "kg"))
                         ((id . "cgw1") (input-of . "harvest") (resource-conforms-to . "labor") (action . work) (effort-qty . 40) (effort-unit . "hr"))
                         ((id . "cg2") (output-of . "harvest") (resource-conforms-to . "wheat-raw") (action . produce) (qty . 600) (unit . "kg"))
                         ((id . "cg3") (input-of . "thresh") (resource-conforms-to . "wheat-raw") (action . consume) (qty . 600) (unit . "kg"))
                         ((id . "cgw2") (input-of . "thresh") (resource-conforms-to . "labor") (action . work) (effort-qty . 16) (effort-unit . "hr"))
                         ((id . "cg4") (output-of . "thresh") (resource-conforms-to . "wheat") (action . produce) (qty . 500) (unit . "kg"))))
    ("commune-dairy" . (((id . "cd1") (input-of . "milk") (resource-conforms-to . "feed") (action . consume) (qty . 30) (unit . "kg"))
                         ((id . "cdw1") (input-of . "milk") (resource-conforms-to . "labor") (action . work) (effort-qty . 20) (effort-unit . "hr"))
                         ((id . "cd2") (output-of . "milk") (resource-conforms-to . "raw-milk") (action . produce) (qty . 80) (unit . "L"))
                         ((id . "cd3") (input-of . "pasteur") (resource-conforms-to . "raw-milk") (action . consume) (qty . 80) (unit . "L"))
                         ((id . "cd4") (output-of . "pasteur") (resource-conforms-to . "dairy") (action . produce) (qty . 75) (unit . "L"))))
    ("commune-forge" . (((id . "cf1") (input-of . "smelt") (resource-conforms-to . "ore") (action . consume) (qty . 200) (unit . "kg"))
                         ((id . "cfw1") (input-of . "smelt") (resource-conforms-to . "labor") (action . work) (effort-qty . 30) (effort-unit . "hr"))
                         ((id . "cf2") (output-of . "smelt") (resource-conforms-to . "ingots") (action . produce) (qty . 100) (unit . "kg"))
                         ((id . "cf3") (input-of . "forge") (resource-conforms-to . "ingots") (action . consume) (qty . 100) (unit . "kg"))
                         ((id . "cfw2") (input-of . "forge") (resource-conforms-to . "labor") (action . work) (effort-qty . 25) (effort-unit . "hr"))
                         ((id . "cf4") (output-of . "forge") (resource-conforms-to . "tools") (action . produce) (qty . 70) (unit . "pcs"))))
    ("commune-fisher" . (((id . "ch1") (input-of . "catch") (resource-conforms-to . "bait") (action . consume) (qty . 5) (unit . "kg"))
                          ((id . "chw1") (input-of . "catch") (resource-conforms-to . "labor") (action . work) (effort-qty . 35) (effort-unit . "hr"))
                          ((id . "ch2") (output-of . "catch") (resource-conforms-to . "raw-fish") (action . produce) (qty . 300) (unit . "kg"))
                          ((id . "ch3") (input-of . "prep") (resource-conforms-to . "raw-fish") (action . consume) (qty . 300) (unit . "kg"))
                          ((id . "ch4") (output-of . "prep") (resource-conforms-to . "fish") (action . produce) (qty . 262) (unit . "kg"))))
    ("commune-mill" . (((id . "cm1") (input-of . "grind") (resource-conforms-to . "wheat") (action . consume) (qty . 200) (unit . "kg"))
                        ((id . "cm2") (output-of . "grind") (resource-conforms-to . "coarse-flour") (action . produce) (qty . 190) (unit . "kg"))
                        ((id . "cm3") (input-of . "sift") (resource-conforms-to . "coarse-flour") (action . consume) (qty . 190) (unit . "kg"))
                        ((id . "cm4") (output-of . "sift") (resource-conforms-to . "flour") (action . produce) (qty . 180) (unit . "kg"))))
    ("commune-bakery" . (((id . "cb1") (input-of . "mix") (resource-conforms-to . "flour") (action . consume) (qty . 100) (unit . "kg"))
                          ((id . "cbw1") (input-of . "mix") (resource-conforms-to . "labor") (action . work) (effort-qty . 6) (effort-unit . "hr"))
                          ((id . "cb2") (output-of . "mix") (resource-conforms-to . "dough") (action . produce) (qty . 95) (unit . "kg"))
                          ((id . "cb3") (input-of . "bake") (resource-conforms-to . "dough") (action . consume) (qty . 95) (unit . "kg"))
                          ((id . "cbw2") (input-of . "bake") (resource-conforms-to . "labor") (action . work) (effort-qty . 10) (effort-unit . "hr"))
                          ((id . "cb4") (output-of . "bake") (resource-conforms-to . "bread") (action . produce) (qty . 90) (unit . "loaves"))))
    ;; ── New scopes ─────────────────────────────────────────────────
    ("commune-herder" . (((id . "ch-graze1") (input-of . "graze") (resource-conforms-to . "feed") (action . consume) (qty . 80) (unit . "kg"))
                          ((id . "ch-grazew") (input-of . "graze") (resource-conforms-to . "labor") (action . work) (effort-qty . 30) (effort-unit . "hr"))
                          ((id . "ch-shear1") (output-of . "shear") (resource-conforms-to . "wool") (action . produce) (qty . 120) (unit . "kg"))
                          ((id . "ch-shearw") (input-of . "shear") (resource-conforms-to . "labor") (action . work) (effort-qty . 24) (effort-unit . "hr"))
                          ((id . "ch-tan1")  (output-of . "tan") (resource-conforms-to . "leather") (action . produce) (qty . 35) (unit . "kg"))))
    ("commune-workshop" . (((id . "cw1") (input-of . "assemble") (resource-conforms-to . "metal") (action . consume) (qty . 40) (unit . "kg"))
                            ((id . "cww1") (input-of . "assemble") (resource-conforms-to . "labor") (action . work) (effort-qty . 28) (effort-unit . "hr"))
                            ((id . "cw2") (output-of . "assemble") (resource-conforms-to . "goods") (action . produce) (qty . 40) (unit . "pcs"))
                            ((id . "cw3") (input-of . "finish") (resource-conforms-to . "leather") (action . consume) (qty . 12) (unit . "kg"))
                            ((id . "cw4") (output-of . "finish") (resource-conforms-to . "goods") (action . produce) (qty . 35) (unit . "pcs"))))
    ("commune-textile" . (((id . "ct1") (input-of . "spin") (resource-conforms-to . "wool") (action . consume) (qty . 60) (unit . "kg"))
                           ((id . "ctw1") (input-of . "spin") (resource-conforms-to . "labor") (action . work) (effort-qty . 28) (effort-unit . "hr"))
                           ((id . "ct2") (output-of . "spin") (resource-conforms-to . "yarn") (action . produce) (qty . 50) (unit . "kg"))
                           ((id . "ct3") (input-of . "weave") (resource-conforms-to . "yarn") (action . consume) (qty . 50) (unit . "kg"))
                           ((id . "ct4") (output-of . "weave") (resource-conforms-to . "cloth") (action . produce) (qty . 80) (unit . "m²"))))
    ("commune-salter" . (((id . "cs1") (input-of . "evap") (resource-conforms-to . "seawater") (action . consume) (qty . 2000) (unit . "L"))
                          ((id . "csw1") (input-of . "evap") (resource-conforms-to . "labor") (action . work) (effort-qty . 40) (effort-unit . "hr"))
                          ((id . "cs2") (output-of . "evap") (resource-conforms-to . "salt") (action . produce) (qty . 475) (unit . "kg"))))
    ("commune-olive" . (((id . "co1") (input-of . "pick") (resource-conforms-to . "labor") (action . work) (effort-qty . 50) (effort-unit . "hr"))
                         ((id . "co2") (output-of . "pick") (resource-conforms-to . "olives") (action . produce) (qty . 50) (unit . "kg"))
                         ((id . "co3") (input-of . "press") (resource-conforms-to . "olives") (action . consume) (qty . 50) (unit . "kg"))
                         ((id . "co4") (output-of . "press") (resource-conforms-to . "olive-oil") (action . produce) (qty . 45) (unit . "L"))))
    ("commune-citrus" . (((id . "cc1") (input-of . "pick-c") (resource-conforms-to . "labor") (action . work) (effort-qty . 60) (effort-unit . "hr"))
                          ((id . "cc2") (output-of . "pick-c") (resource-conforms-to . "citrus") (action . produce) (qty . 120) (unit . "kg"))))
    ("commune-vinyard" . (((id . "cv1") (input-of . "tend") (resource-conforms-to . "labor") (action . work) (effort-qty . 80) (effort-unit . "hr"))
                           ((id . "cv2") (input-of . "pick-g") (resource-conforms-to . "labor") (action . work) (effort-qty . 40) (effort-unit . "hr"))
                           ((id . "cv3") (output-of . "pick-g") (resource-conforms-to . "grapes") (action . produce) (qty . 280) (unit . "kg"))))
    ("commune-brewery" . (((id . "cbr1") (input-of . "malt") (resource-conforms-to . "wheat") (action . consume) (qty . 80) (unit . "kg"))
                           ((id . "cbr2") (output-of . "malt") (resource-conforms-to . "malt") (action . produce) (qty . 70) (unit . "kg"))
                           ((id . "cbr3") (input-of . "ferment") (resource-conforms-to . "malt") (action . consume) (qty . 70) (unit . "kg"))
                           ((id . "cbrw1") (input-of . "ferment") (resource-conforms-to . "labor") (action . work) (effort-qty . 18) (effort-unit . "hr"))
                           ((id . "cbr4") (output-of . "ferment") (resource-conforms-to . "ale") (action . produce) (qty . 60) (unit . "L"))
                           ((id . "cbr5") (input-of . "press-w") (resource-conforms-to . "grapes") (action . consume) (qty . 120) (unit . "kg"))
                           ((id . "cbr6") (output-of . "press-w") (resource-conforms-to . "wine") (action . produce) (qty . 40) (unit . "L"))))
    ("ft-coliving" . (((id . "ftc1") (input-of . "kitchen") (resource-conforms-to . "bread") (action . consume) (qty . 60) (unit . "loaves"))
                       ((id . "ftc2") (input-of . "kitchen") (resource-conforms-to . "dairy") (action . consume) (qty . 25) (unit . "L"))
                       ((id . "ftc3") (input-of . "kitchen") (resource-conforms-to . "fish") (action . consume) (qty . 30) (unit . "kg"))
                       ((id . "ftcw") (input-of . "kitchen") (resource-conforms-to . "labor") (action . work) (effort-qty . 40) (effort-unit . "hr"))
                       ((id . "ftc4") (output-of . "kitchen") (resource-conforms-to . "meals") (action . produce) (qty . 200) (unit . "serving"))))
    ("ft-events" . (((id . "fte1") (input-of . "prod") (resource-conforms-to . "wine") (action . consume) (qty . 25) (unit . "L"))
                     ((id . "fte2") (input-of . "prod") (resource-conforms-to . "ale") (action . consume) (qty . 20) (unit . "L"))
                     ((id . "ftew") (input-of . "prod") (resource-conforms-to . "labor") (action . work) (effort-qty . 60) (effort-unit . "hr"))
                     ((id . "fte3") (output-of . "prod") (resource-conforms-to . "event-tickets") (action . produce) (qty . 90) (unit . "ticket"))))
    ("ft-robotics" . (((id . "ftr1") (input-of . "design") (resource-conforms-to . "labor") (action . work) (effort-qty . 80) (effort-unit . "hr"))
                       ((id . "ftr2") (output-of . "design") (resource-conforms-to . "blueprints") (action . produce) (qty . 18) (unit . "doc"))
                       ((id . "ftr3") (input-of . "fab") (resource-conforms-to . "tools") (action . consume) (qty . 48) (unit . "pcs"))
                       ((id . "ftr4") (input-of . "fab") (resource-conforms-to . "blueprints") (action . consume) (qty . 18) (unit . "doc"))
                       ((id . "ftrw") (input-of . "fab") (resource-conforms-to . "labor") (action . work) (effort-qty . 120) (effort-unit . "hr"))
                       ((id . "ftr5") (output-of . "fab") (resource-conforms-to . "robots") (action . produce) (qty . 18) (unit . "unit"))))
    ("ft-arts" . (((id . "fta1") (input-of . "create") (resource-conforms-to . "cloth") (action . consume) (qty . 8) (unit . "m²"))
                   ((id . "ftaw") (input-of . "create") (resource-conforms-to . "labor") (action . work) (effort-qty . 90) (effort-unit . "hr"))
                   ((id . "fta2") (output-of . "create") (resource-conforms-to . "media-content") (action . produce) (qty . 45) (unit . "piece"))))))

;;; ── Federation derived state ──────────────────────────────────────
;;;
;;; *fed-results* and *fed-events* are computed from the sources above.
;;; Mutating any of the sources at the REPL and re-running these defs
;;; (or just rebuilding) yields a fresh graph. When the real planner
;;; service is wired in, the same shape is returned by its snapshot —
;;; this fallback solver disappears and the UI keeps working unchanged.

(define *fed-results*
  (compute-fed-results *fed-scopes* *fed-demands* *fed-resources*
                       *fed-commitments* *fed-trades*))

(define *fed-events*
  (compute-fed-events *fed-scopes* *fed-results* *fed-trades*))

(define *fed-selected* "")
(define *fed-mode* 'plan)     ;; 'plan or 'observe
(define *fed-flow-ctx* #f)    ;; selected flow context for event recorder
(define *fed-recorded* '())   ;; list of recorded events
(define *fed-log-open?* #f)   ;; event-log sidebar: closed by default

;;; ── Recipes state ───────────────────────────────────────────────────────────
(define *recipes-tab* 'library)        ;; 'library | 'workshop
(define *recipes-search* "")
(define *recipes-prompt* "")
(define *recipes-generated* '())       ;; AI-generated recipe alists (most recent first)
(define *recipes-generating?* #f)
(define *recipes-error* "")

(define (group-commas n)
  "Integer hours with thousands separators, e.g. 10200 -> \"10,200\"."
  (let loop ((s (number->string (inexact->exact (round n)))) (out ""))
    (let ((len (string-length s)))
      (if (<= len 3)
          (if (string=? out "") s (string-append s "," out))
          (loop (substring s 0 (- len 3))
                (let ((tail (substring s (- len 3) len)))
                  (if (string=? out "") tail (string-append tail "," out))))))))

(define (surface-caption focus)
  "The total-labour caption that trails the path, like docs/viz/treemap.html."
  (let* ((total (assq-ref (repro focus) 'total))
         (name  (tm-node-name focus))
         (label (cond ((string=? name "federation") "total social labour-time")
                      ((string=? name "playnet")    "total social time")
                      (else #f))))
    (string-append " · " (if label (string-append label " · ") "")
                   (group-commas total) " h")))

;; Step the surface back one — the default action of clicking the header bar or
;; pressing Escape. From the inline map it returns to the treemap; otherwise it
;; zooms out one level. No-op at the root.
(define (surface-zoom-out!)
  (cond
   (*surface-map-leaf* (set! *surface-map-leaf* #f) (refresh!))
   ((> (length *surface-path*) 1)
    (set! *surface-path* (reverse (cdr (reverse *surface-path*))))
    (refresh!))))

;; A two-state pill toggle; the active side is highlighted in COLOR.
(define (toggle-pill left right active-right? color on-toggle)
  `(div (@ (style ,(string-append "display:inline-flex; border-radius:10px; overflow:hidden; "
                                  "font-size:9px; cursor:pointer; border:1px solid #2a3a3a; margin-left:6px;"))
           ;; don't let toggling bubble up to the header's zoom-out click
           (click ,(lambda (e) (stop-propagation! e) (on-toggle))))
        (span (@ (style ,(string-append "padding:2px 8px; "
                                        (if active-right? "color:#8b9b96;"
                                            (string-append "background:" color "; color:#11181a; font-weight:700;")))))
              ,left)
        (span (@ (style ,(string-append "padding:2px 8px; "
                                        (if active-right?
                                            (string-append "background:" color "; color:#11181a; font-weight:700;")
                                            "color:#8b9b96;"))))
              ,right)))

(define (surface-toggles focus)
  `(div (@ (class "sh-toggles"))
        ;; axis lens — only at the federation (the activities/categories root)
        ,@(if (tm-axis-root? focus)
              (list (toggle-pill "activities" "categories" *surface-categories?* "#7ab0d4"
                                 (lambda () (set! *surface-categories?* (not *surface-categories?*)) (refresh!))))
              '())
        ,(toggle-pill "social" "individual" *surface-individual?* "#7fb46a"
                      (lambda () (set! *surface-individual?* (not *surface-individual?*)) (refresh!)))
        ,(toggle-pill "time" "priority" *surface-priority?* "#b87333"
                      (lambda () (set! *surface-priority?* (not *surface-priority?*)) (refresh!)))
        ,(toggle-pill "simple" "detailed" *surface-detail?* "#6a5fa0"
                      (lambda () (set! *surface-detail?* (not *surface-detail?*)) (refresh!)))))

;; ── 3-bar sidebar: producer voice, consumer voice, credit ──────────────────
;; One horizontal segmented bar each (no nested treemaps). Demo data mirrors
;; docs/viz/treemap.html: producer voice ∝ labour (unequal), consumer voice flatter.
(define *voice-colors*
  '("#2c4a6e" "#4a8a5a" "#b87333" "#6a5fa0" "#5a85b0" "#4a8a87"
    "#3a5a7a" "#7fb46a" "#c88a4a" "#8a7fb0" "#6aaad4" "#5aa097"))

;; A vertical stacked bar that grows to fill its section: one segment per
;; person, height ∝ share, full width. Fills whatever height it's given.
(define (voice-bar caption shares)
  `(div (@ (style "flex:1; min-height:0; display:flex; flex-direction:column; margin-bottom:8px;"))
        (div (@ (style "font-size:10px; color:#9fb8b0; font-style:italic; margin-bottom:2px; flex:0 0 auto;")) ,caption)
        (div (@ (style "flex:1; min-height:0; display:flex; flex-direction:column; border-radius:4px; overflow:hidden;"))
             ,@(let loop ((ss shares) (i 0) (acc '()))
                 (if (null? ss) (reverse acc)
                     (loop (cdr ss) (+ i 1)
                           (cons `(div (@ (style ,(string-append
                                                   "flex:" (number->string (car ss)) " 1 0; "
                                                   "background:" (list-ref *voice-colors* (modulo i 12)) "; "
                                                   "display:flex; align-items:center; padding:0 7px; "
                                                   "color:white; font-size:9px; font-weight:700; "
                                                   "min-height:0; overflow:hidden; border-bottom:1px solid rgba(0,0,0,0.25);")))
                                       ,(string-append "p" (number->string (+ i 1)) " " (number->string (car ss)) "%"))
                                 acc)))))))

(define (credit-bar claimed remaining)
  (let ((total (+ claimed remaining)))
    `(div (@ (style "flex:1; min-height:0; display:flex; flex-direction:column;"))
          (div (@ (style "font-size:10px; color:#9fb8b0; font-style:italic; margin-bottom:2px; flex:0 0 auto;"))
               ,(string-append "credit: " (number->string claimed) "/" (number->string total) " h — K·vₚ"))
          (div (@ (style "flex:1; min-height:0; display:flex; flex-direction:column; border-radius:4px; overflow:hidden;"))
               (div (@ (style ,(string-append "flex:" (number->string claimed) " 1 0; background:#d8b860; "
                                              "color:#1a1a1a; font-weight:700; font-size:10px; padding:0 7px; "
                                              "display:flex; align-items:center; min-height:0; overflow:hidden;")))
                    ,(string-append (number->string claimed) " h claimed"))
               (div (@ (style ,(string-append "flex:" (number->string remaining) " 1 0; background:#8a6a38; "
                                              "color:white; font-size:10px; padding:0 7px; "
                                              "display:flex; align-items:center; min-height:0;")))
                    ,(string-append "remaining " (number->string remaining) " h"))))))

;; ── Plan-history sidebar: plan vs observed, at the current zoom ─────────────
;; A deterministic synthetic history for whatever node is focused — the plan
;; (planned labour) over the last 8 periods and the observed realisation, so
;; the divergence (observed − planned) reads directly off the bars. Stable per
;; node (seeded from its name), so zooming changes the panel to that node's plan.
(define (str-hash s)
  (let loop ((i 0) (h 7))
    (if (>= i (string-length s)) h
        (loop (+ i 1) (modulo (+ (* h 31) (char->integer (string-ref s i))) 100000)))))

(define (intstr x) (number->string (inexact->exact (round x))))

(define (focus-history focus)
  "Eight periods of (planned . observed) labour-hours for FOCUS, deterministic."
  (let* ((rr (repro focus))
         (total (assq-ref rr 'total))
         (cur (if (> total 0) (/ (assq-ref rr 'realized) total) 0.8))
         (seed (str-hash (tm-node-name focus))))
    (let loop ((i 0) (acc '()))
      (if (= i 8) (reverse acc)
          (let* ((plan (* total (+ 0.82 (* i 0.026))))
                 (j (/ (- (modulo (+ seed (* i 53)) 30) 15) 120.0))   ; ±0.125 jitter
                 (s (max 0.50 (min 1.03 (+ cur j (* (- i 7) 0.006)))))
                 (obs (* plan s)))
            (loop (+ i 1) (cons (cons plan obs) acc)))))))

(define (history-sidebar focus)
  (let* ((hist (focus-history focus))
         (nn (length hist))
         (maxv (let lp ((hs hist) (m 1)) (if (null? hs) m (lp (cdr hs) (max m (caar hs))))))
         (W 220) (H 220) (pad 8) (base (- H 14))
         (bw (/ (- W (* 2 pad)) nn))
         (bars (let lp ((hs hist) (i 0) (acc '()))
                 (if (null? hs) (reverse acc)
                     (let* ((p (caar hs)) (o (cdar hs))
                            (x (+ pad (* i bw)))
                            (ph (* (/ p maxv) (- base 8)))
                            (oh (* (/ o maxv) (- base 8))))
                       (lp (cdr hs) (+ i 1)
                           (cons `(g
                                   (rect (@ (x ,(intstr (+ x 1))) (y ,(intstr (- base ph)))
                                            (width ,(intstr (- bw 2))) (height ,(intstr ph))
                                            (fill "#27402f")))                         ; planned (faint)
                                   (rect (@ (x ,(intstr (+ x 1))) (y ,(intstr (- base oh)))
                                            (width ,(intstr (- bw 2))) (height ,(intstr oh))
                                            (fill ,(if (< o p) "#5a9a6a" "#7fb46a"))))) ; observed
                                 acc))))))
         (cur (car (last-pair hist))) (cp (car cur)) (co (cdr cur)) (delta (- co cp)))
    `(div (@ (class "surface-sidebar-body"))
          (div (@ (style "font-size:11px; color:#9fb8b0; font-style:italic; margin-bottom:4px;"))
               ,(string-append "plan vs observed — " (tm-node-name focus)))
          (div (@ (style "flex:1; min-height:0; min-width:0;"))
               (svg (@ (width "100%") (height "100%")
                       (viewBox ,(string-append "0 0 " (number->string W) " " (number->string H)))
                       (preserveAspectRatio "none") (style "display:block;"))
                    ,@bars
                    (line (@ (x1 ,(number->string pad)) (y1 ,(number->string base))
                             (x2 ,(number->string (- W pad))) (y2 ,(number->string base))
                             (stroke "#3a4a4a") (stroke-width "1")))))
          (div (@ (style "font-size:11px; margin-top:6px; color:#bcd; line-height:1.55;"))
               (div (@ (style "display:flex; align-items:center; gap:5px; margin-bottom:2px;"))
                    (span (@ (style "width:10px; height:10px; background:#27402f; display:inline-block;"))) "plan"
                    (span (@ (style "width:10px; height:10px; background:#7fb46a; display:inline-block; margin-left:8px;"))) "observed")
               ,(string-append "now · planned " (intstr cp) " h · observed " (intstr co) " h")
               (div (@ (style ,(string-append "font-weight:700; color:"
                                              (if (< delta 0) "#e89090" "#88d6a0") ";")))
                    ,(string-append "divergence Δ " (intstr delta) " h ("
                                    (intstr (* 100 (/ delta (max 1 cp)))) "%)"))))))

(define (surface-sidebar)
  `(div (@ (class "surface-sidebar-body"))
        ,(voice-bar "producer voice ∝ Lₚ (unequal)"
                    '(6.2 5.8 5.5 5.2 5.0 4.8 4.5 4.3 4.0 3.8 3.5 3.2))
        ,(voice-bar "consumer voice (more equal)"
                    '(4.8 4.6 4.4 4.3 4.2 4.1 4.0 3.9 3.8 3.7 3.6 3.5))
        ,(credit-bar 45 435)))

(define (surface-breadcrumb)
  "The surface header bar (dark, like docs/viz/treemap.html's federation header): a
   clickable path root → … → focus followed by the total caption. Clicking any
   crumb zooms back out to it; a leading ← steps out one level. The view
   toggles sit on the right."
  (let* ((depth (length *surface-path*))
         (focus (car (last-pair *surface-path*)))
         ;; The ← is just an affordance; the click falls through to the bar,
         ;; whose handler zooms out one level (so clicking *anywhere* on the
         ;; header goes back).
         (back (and (> depth 1)
                    `(span (@ (style "color:#efe2fa; margin-right:8px; font-weight:700;")) "←"))))
    (let loop ((path *surface-path*) (prefix '()) (acc '()))
      (if (null? path)
          `(div (@ (class "surface-breadcrumb")
                   (title "click to go back (Esc)")
                   (style "cursor:pointer;")
                   (click ,(lambda (e) (surface-zoom-out!))))
                ;; path (back + crumbs), then caption, then toggles — CSS reorders
                ;; them top→bottom on narrow screens (path / toggles / caption).
                (div (@ (class "sh-path"))
                     ,@(if back (list back) '())
                     ,@(reverse acc)
                     ;; in inline-map mode the focused leaf is the last crumb
                     ,@(if *surface-map-leaf*
                           (list '(span (@ (style "color:#5f7a72; padding:0 5px;")) "/")
                                 `(span (@ (style "color:white; font-weight:700; padding:0 2px;"))
                                        ,(tm-node-name *surface-map-leaf*)))
                           '()))
                (span (@ (class "sh-caption"))
                      ,(if *surface-map-leaf*
                           (string-append " · "
                                          (number->string (length (leaf->markers *surface-map-leaf*)))
                                          " resources near you")
                           (surface-caption focus)))
                ,@(if *surface-map-leaf* '() (list (surface-toggles focus))))
          (let* ((node (car path))
                 (pfx (append prefix (list node)))
                 (last? (null? (cdr path)))
                 ;; A specific crumb jumps straight to that node — stop the click
                 ;; bubbling to the bar's zoom-out-one.
                 (crumb `(span (@ (style ,(string-append
                                           "cursor:pointer; padding:0 2px; font-weight:700;"
                                           (if last? "color:white;" "color:#9fb8b0;")))
                                  (title "zoom here")
                                  (click ,(lambda (e) (stop-propagation! e)
                                                  (set! *surface-map-leaf* #f)   ; close the inline map first
                                                  (set! *surface-path* pfx) (refresh!))))
                               ,(tm-node-name node))))
            (loop (cdr path) pfx
                  (cons crumb (if (null? acc) acc
                                  (cons '(span (@ (style "color:#5f7a72; padding:0 5px;")) "/") acc)))))))))

;; Measure the surface frame; if its pixel size changed, store it and re-render
;; so the SVG fills exactly (no letterbox, no stretch). No-op off the surface.
(define (measure-surface!)
  (let ((frame (get-element-by-id "surface-frame")))
    (when frame
      (let ((w (client-width frame)) (h (client-height frame)))
        (when (and (> w 50) (> h 50)
                   (or (> (abs (- w *surface-w*)) 2)
                       (> (abs (- h *surface-h*)) 2)))
          (set! *surface-w* w)
          (set! *surface-h* h)
          (refresh!))))))

(define *surface-resize-installed?* #f)

;; After the surface mounts, measure it; also install one debounced window
;; resize listener so the SVG re-fits on resize (otherwise it stretches).
(define (schedule-surface-measure!)
  (unless *surface-resize-installed?*
    (set! *surface-resize-installed?* #t)
    (window-on-resize (procedure->external/cached (lambda () (measure-surface!)))))
  (window-set-timeout (procedure->external/cached (lambda () (measure-surface!))) 0))

(define (render-surface-view)
  "The reproduction-labour surface (docs/viz/treemap.html) as SXML/SVG: a navigable
   squarified treemap that fills the frame. The dark breadcrumb bar IS the
   focus's header tab — click a crumb (or ←) to zoom out, a scope to zoom in.
   Every leaf decomposes its required labour by intent; a leaf with offers
   reveals the geographic map via the same (playnet ui map) component."
  (let ((focus (car (last-pair *surface-path*)))
        (map? *surface-map-leaf*))
    ;; Mount maplibre when in inline-map mode; otherwise measure the treemap frame.
    (if map? (schedule-map-mount!) (schedule-surface-measure!))
    `(div (@ (class "surface-view"))
          (div (@ (class "surface-hint"))
               ,(if map?
                    "geographic offers near you · click the header (or Esc) to go back to the surface"
                    "area ∝ social labour-hours · click a scope to zoom in · click the header to zoom out"))
          (div (@ (class "surface-main"))
               ;; left: breadcrumb header + the surface (or, in place, the map)
               (div (@ (class "surface-left"))
                    ,(surface-breadcrumb)
                    (div (@ (id "surface-frame") (class "surface-frame"))
                         ,(if map?
                              (render-map-view)         ; the very same (playnet ui map) view, in place
                              (treemap-surface
                               focus
                               #:width *surface-w* #:height *surface-h*
                               #:detail? *surface-detail?*
                               #:per-capita? *surface-individual?*
                               #:priority? *surface-priority?*
                               #:categories? *surface-categories?*
                               #:on-zoom
                               (lambda (node)
                                 (set! *surface-path* (append *surface-path* (list node)))
                                 (refresh!))
                               #:on-leaf-click
                               (lambda (node)
                                 ;; Open the map *in place* — no tab switch.
                                 (set! *map-marker-data* (leaf->markers node))
                                 (set! *map-selected* #f)
                                 (set! *surface-map-leaf* node)
                                 (refresh!)
                                 (schedule-map-mount!))))))
               ;; right: the sidebar column (hidden while the map is open). Its
               ;; own header — level with the treemap breadcrumb — carries the
               ;; voice/history toggle that swaps the panel below it.
               ,@(if map? '()
                     (list
                      `(div (@ (class "surface-sidebar-col"))
                            (div (@ (class "surface-sidebar-header"))
                                 ,(toggle-pill "voice" "history" *surface-history?* "#5a85b0"
                                               (lambda () (set! *surface-history?* (not *surface-history?*)) (refresh!))))
                            ,(if *surface-history?* (history-sidebar focus) (surface-sidebar)))))))))

(define (render-federation-view)
  "Render the federation planning page with sample data."
  (federation-page
   #:scopes *fed-scopes*
   #:results *fed-results*
   #:trades *fed-trades*
   #:events *fed-events*
   #:resources-by-scope *fed-resources*
   #:spec-names *fed-spec-names*
   #:selected *fed-selected*
   #:on-select (lambda (id e)
                 (stop-propagation! e)
                 (set! *fed-selected*
                       (if (equal? *fed-selected* id) "" id))
                 (refresh!))
   #:on-close-detail (lambda (e)
                       (set! *fed-selected* "")
                       (refresh!))
   #:on-mode-change (lambda (new-mode)
                      (set! *fed-mode* new-mode)
                      (set! *fed-flow-ctx* #f)
                      (refresh!))
   #:on-card-click (lambda (ctx)
                     (set! *fed-flow-ctx* ctx)
                     (refresh!))
   #:mode *fed-mode*
   #:flow-ctx *fed-flow-ctx*
   #:recorded-events *fed-recorded*
   #:processes-by-scope *fed-processes*
   #:commitments-by-scope *fed-commitments*
   #:svg-width 1100
   #:svg-height 720
   #:log-open? *fed-log-open?*
   #:on-toggle-log (lambda ()
                     (set! *fed-log-open?* (not *fed-log-open?*))
                     (refresh!))))

;;; ── Calendar persistence ────────────────────────────────────────────────────

(define (serialize-events events)
  "Serialize events to a localStorage-friendly string.
   Format: id|title|date|sh|sm|eh|em|person|location|color|source|description|status;..."
  (let loop ((evts events) (acc ""))
    (if (null? evts) acc
        (let ((e (car evts)))
          (loop (cdr evts)
                (string-append acc (if (string=? acc "") "" ";")
                  (alist-ref e 'id "") "|"
                  (alist-ref e 'title "") "|"
                  (alist-ref e 'date "") "|"
                  (number->string (alist-ref e 'sh 0)) "|"
                  (number->string (alist-ref e 'sm 0)) "|"
                  (number->string (alist-ref e 'eh 0)) "|"
                  (number->string (alist-ref e 'em 0)) "|"
                  (alist-ref e 'person "") "|"
                  (alist-ref e 'location "") "|"
                  (alist-ref e 'color "#63b3ed") "|"
                  (let ((s (alist-ref e 'source 'event)))
                    (cond ((eq? s 'commitment) "commitment")
                          ((eq? s 'intent) "intent")
                          (else "event"))) "|"
                  (alist-ref e 'description "") "|"
                  (let ((st (alist-ref e 'status 'open)))
                    (cond ((eq? st 'committed) "committed")
                          ((eq? st 'fulfilled) "fulfilled")
                          (else "open"))) "|"
                  (if (alist-ref e 'all-day #f) "1" "0")))))))

(define (split-string s ch)
  "Split string S on character CH. Returns list of substrings."
  (let loop ((s s) (acc '()))
    (let ((idx (string-index s ch)))
      (if idx
          (loop (substring s (+ idx 1))
                (cons (substring s 0 idx) acc))
          (reverse (cons s acc))))))

(define (safe-string->number s)
  (or (string->number s) 0))

(define (deserialize-events raw)
  "Parse serialized events string back to alist list."
  (if (or (not raw) (string=? raw "")) '()
      (let ((records (split-string raw #\;)))
        (filter (lambda (x) x)
         (map
          (lambda (rec)
            (let ((fields (split-string rec #\|)))
              (if (< (length fields) 11) #f
                  (let ((n (length fields)))
                    (list (cons 'id       (list-ref fields 0))
                          (cons 'title    (list-ref fields 1))
                          (cons 'date     (list-ref fields 2))
                          (cons 'sh (safe-string->number (list-ref fields 3)))
                          (cons 'sm  (safe-string->number (list-ref fields 4)))
                          (cons 'eh   (safe-string->number (list-ref fields 5)))
                          (cons 'em    (safe-string->number (list-ref fields 6)))
                          (cons 'person   (list-ref fields 7))
                          (cons 'location (list-ref fields 8))
                          (cons 'color    (list-ref fields 9))
                          (cons 'source   (let ((s (list-ref fields 10)))
                                            (cond ((string=? s "commitment") 'commitment)
                                                  ((string=? s "intent") 'intent)
                                                  (else 'event))))
                          (cons 'description (if (> n 11) (list-ref fields 11) ""))
                          (cons 'status   (if (> n 12)
                                              (let ((s (list-ref fields 12)))
                                                (cond ((string=? s "committed") 'committed)
                                                      ((string=? s "fulfilled") 'fulfilled)
                                                      (else 'open)))
                                              'open))
                          (cons 'all-day  (if (> n 13)
                                              (string=? (list-ref fields 13) "1")
                                              #f)))))))
          records)))))

(define (serialize-people people)
  "Serialize people: id|name|color|visible;..."
  (let loop ((ps people) (acc ""))
    (if (null? ps) acc
        (let ((p (car ps)))
          (loop (cdr ps)
                (string-append acc (if (string=? acc "") "" ";")
                  (alist-ref p 'id "") "|"
                  (alist-ref p 'name "") "|"
                  (alist-ref p 'color "#63b3ed") "|"
                  (if (alist-ref p 'visible #t) "1" "0")))))))

(define (deserialize-people raw)
  (if (or (not raw) (string=? raw "")) '()
      (let ((records (split-string raw #\;)))
        (filter (lambda (x) x)
         (map
          (lambda (rec)
            (let ((fields (split-string rec #\|)))
              (if (< (length fields) 4) #f
                  (list (cons 'id      (list-ref fields 0))
                        (cons 'name    (list-ref fields 1))
                        (cons 'color   (list-ref fields 2))
                        (cons 'visible (string=? (list-ref fields 3) "1"))))))
          records)))))

(define (all-cal-events)
  "Merged view: derived (planner) events first, user-created events second.
   Used by render and any traversal that needs the union."
  (append *cal-derived-events* *cal-user-events*))

(define (save-calendar!)
  ;; Only user-created events are persisted; derived events live in the
  ;; sample store and are reconstructed on demand.
  (ls-set-item "pn.repl.cal-events" (serialize-events *cal-user-events*))
  (ls-set-item "pn.repl.cal-people" (serialize-people *cal-people*)))

(define (load-calendar!)
  (let ((raw-e (ls-get-item "pn.repl.cal-events"))
        (raw-p (ls-get-item "pn.repl.cal-people")))
    (when raw-e (set! *cal-user-events* (deserialize-events raw-e)))
    (when raw-p (set! *cal-people* (deserialize-people raw-p)))
    ;; Set next-id past existing
    (for-each (lambda (e)
                (let* ((id-str (alist-ref e 'id ""))
                       (num (safe-string->number
                             (if (> (string-length id-str) 4)
                                 (substring id-str 4)
                                 "0"))))
                  (when (>= num *cal-next-id*)
                    (set! *cal-next-id* (+ num 1)))))
              *cal-user-events*)))

(define (cal-ensure-person! person-id)
  "Add person to *cal-people* if not already present."
  (when (and (not (string=? person-id ""))
             (not (%find (lambda (p) (equal? (alist-ref p 'id) person-id)) *cal-people*)))
    (set! *cal-people*
          (append *cal-people*
                  (list (list (cons 'id person-id)
                              (cons 'name person-id)
                              (cons 'color (person-color person-id *cal-people*))
                              (cons 'visible #t)))))))

;;; ── Planner client (^planner-service over OCapN) ─────────────────────────
;;;
;;; The browser holds a single capability *planner-cap* obtained from
;;; (<- *lobby* 'planner). All calendar reads + writes go through it.
;;; The planner-service emits plain alists in the same shape that the
;;; existing projection layer (vf-record->grid-event) consumes, so the
;;; render path is unchanged — only the source of the data has moved
;;; from a local sample store to a real ^scope-root in the gateway.

(define (planner-log-error! tag detail)
  "Surface a planner error in the log pane so the user sees it."
  (log-append! `(span (@ (class "error-text"))
                      ,(string-append "[planner " tag "] "
                                      (call-with-output-string
                                        (lambda (p) (write detail p)))
                                      "\n"))))

(define (planner-mutate! method . args)
  "Common shape for fire-and-refresh mutation calls. Checks the cap is
   available and a scope is selected, fires the OCapN call, and refreshes
   the calendar on either success or error so the UI always reflects
   server truth after a click. Server-side error envelopes (error . msg)
   are logged to the user."
  (when (and *planner-cap* *active-scope*)
    (with-vat *ocapn-vat*
      (on (apply <- *planner-cap* method *active-scope* args)
          (lambda (result)
            ;; The planner-service returns (ok . X) or (error . msg).
            ;; Surface errors so the user knows why nothing happened.
            (when (and (pair? result) (eq? (car result) 'error))
              (planner-log-error! (symbol->string method) (cdr result)))
            (refresh-scope-snapshot!))
          #:catch (lambda (err)
                    (planner-log-error! (symbol->string method) err)
                    (refresh-scope-snapshot!))))))

;; The snapshot arrives as the page's rows; this face reads records as alists
;; under kebab symbols, so each row is read back into that shape (wire->plain).
(define (ingest-snapshot! snap)
  "Write a server snapshot into the existing globals so the existing
   projection layer (vf-record->grid-event) keeps working unchanged."
  (when snap
    (let ((members (wire->plain (or (assoc-ref snap "members") '())))
          (intents (wire->plain (or (assoc-ref snap "intents") '())))
          (cmts    (wire->plain (or (assoc-ref snap "commitments") '()))))
      (set! *cal-people* members)
      (set! *cal-unscheduled-intents* intents)
      (set! *cal-derived-events*
            (append (map intent->grid-event intents)
                    (map commitment->grid-event cmts)))
      ;; Populate availability from server-authoritative data when
      ;; acting-as user has availability in the snapshot.
      (when *acting-as*
        (let ((me (%find (lambda (m) (equal? (alist-ref m 'id) *acting-as*))
                          members)))
          (when me
            (let ((avail (alist-ref me 'availability #f)))
              (when (and avail (pair? avail))
                (set! *cal-availability*
                      (let %amap ((rest avail) (acc '()))
                        (if (null? rest) acc
                            (let* ((ds (car rest))
                                   (days (or (alist-ref ds 'days) '()))
                                   (trs  (or (alist-ref ds 'time-ranges) '()))
                                   (slots
                                    (let %amap2 ((dd days) (a2 '()))
                                      (if (null? dd) a2
                                          (let ((dow (or (vf-day->dow (car dd)) 0)))
                                            (%amap2 (cdr dd)
                                                    (append a2
                                                            (map (lambda (tr)
                                                                   (cal-make-avail-slot
                                                                    dow
                                                                    (hhmm->min (or (alist-ref tr 'start) "09:00"))
                                                                    (hhmm->min (or (alist-ref tr 'end) "17:00"))))
                                                                 trs))))))))
                              (%amap (cdr rest) (append acc slots)))))))))
      ;; Clamp acting-as if the user is no longer a scope member
      (when (and *acting-as*
                 (not (%find (lambda (m) (equal? (alist-ref m 'id) *acting-as*))
                             members)))
        (set! *acting-as* #f)))))))

(define (planner-fetch-scope-list!)
  "Populate *scope-list* via the planner cap. If *active-scope* is unset,
   default it to the first scope and chain a snapshot refresh."
  (when *planner-cap*
    (with-vat *ocapn-vat*
      (on (<- *planner-cap* 'scope-list)
          (lambda (scopes)
            (set! *scope-list* (or scopes '()))
            (when (and (not *active-scope*) (pair? *scope-list*))
              (set! *active-scope* (alist-ref (car *scope-list*) 'id #f)))
            (refresh-scope-snapshot!))
          #:catch (lambda (err) #f)))))

(define (refresh-scope-snapshot!)
  "Pull a fresh snapshot for the current scope+plan and re-render on
   reply. Lazily fetches *planner-cap* and *scope-list* the first
   time through; concurrent refreshes are coalesced via the inflight flag."
  (cond
    ((not *planner-cap*)
     (when *lobby*
       (with-vat *ocapn-vat*
         (on (<- *lobby* 'planner)
             (lambda (cap)
               (set! *planner-cap* cap)
               (refresh-scope-snapshot!))
             #:catch (lambda (err) #f)))))
    (*scope-refresh-inflight?* #f)
    ((or (null? *scope-list*) (not *active-scope*))
     (planner-fetch-scope-list!))
    (else
     (set! *scope-refresh-inflight?* #t)
     (with-vat *ocapn-vat*
       (on (<- *planner-cap* 'scope-snapshot *active-scope* *active-plan*)
           (lambda (snap)
             (set! *scope-refresh-inflight?* #f)
             (set! *scope-snapshot* snap)
             (ingest-snapshot! snap)
             (refresh!))
           #:catch
           (lambda (err)
             (set! *scope-refresh-inflight?* #f)
             (refresh!)))))))

(define (planner-knows-id? iid)
  "True if IID matches an intent or commitment in the current snapshot."
  (and *scope-snapshot*
       (or (%find (lambda (i) (equal? (alist-ref i 'id) iid))
                  (or (assq-ref *scope-snapshot* 'intents) '()))
           (%find (lambda (c) (equal? (alist-ref c 'id) iid))
                  (or (assq-ref *scope-snapshot* 'commitments) '())))))

(define (refresh-inventory-snapshot!)
  "Pull a fresh inventory snapshot for the current scope+plan and
   re-render on reply. Mirrors refresh-scope-snapshot! but writes to
   *inv-snapshot* and uses the inventory-snapshot OCapN method.

   Side-effect on success: clears *inv-detail-cache* so cards opened
   from a stale snapshot don't show stale custody data."
  (cond
    ((not *planner-cap*)
     (when *lobby*
       (with-vat *ocapn-vat*
         (on (<- *lobby* 'planner)
             (lambda (cap)
               (set! *planner-cap* cap)
               (refresh-inventory-snapshot!))
             #:catch (lambda (err) #f)))))
    (*inv-refresh-inflight?* #f)
    ((or (null? *scope-list*) (not *active-scope*))
     (planner-fetch-scope-list!))
    (else
     (set! *inv-refresh-inflight?* #t)
     (with-vat *ocapn-vat*
       (on (<- *planner-cap* 'inventory-snapshot *active-scope* *active-plan*)
           (lambda (snap)
             (set! *inv-refresh-inflight?* #f)
             (set! *inv-snapshot* snap)
             (set! *inv-detail-cache* '())
             (refresh!))
           #:catch
           (lambda (err)
             (set! *inv-refresh-inflight?* #f)
             (refresh!)))))))

;;; ── Session-state setters ──────────────────────────────────────────────
;;; Scope, plan, and acting-as are session-level state shared across the
;;; calendar / inventory / federation tabs. The session-bar (rendered at
;;; the top in render-action-bar) calls these to update them; the in-view
;;; plan dropdown calls set-active-plan! for plan changes. Each setter
;;; resets the per-view selection state that becomes stale when the
;;; context shifts, then refreshes the relevant snapshots.

;;; ── Live-location sharing with the planner ──────────────────────────────────
;;; off | here (one getCurrentPosition) | live (watchPosition stream). Either way
;;; only the nearest NAMED place reaches the planner — set-position-latlon snaps
;;; server-side — and it becomes the worker's commute origin (so work is matched
;;; from where you ARE, not your static home). Expected per-period trajectories
;;; use the same set-position with period>0 (a place-picker, a later UI).
(define *location-mode* 'off)        ;; 'off | 'here | 'live
(define *location-watch-id* #f)

(define (on-position lat lon)
  "GPS callback → push the acting-as user's position to the planner (coarsened)."
  (when *acting-as*
    (planner-mutate! 'set-position-latlon *acting-as* 0 lat lon)))

(define (set-location-mode! mode)
  "Switch sharing mode. 'here = one GPS read; 'live = a watch; 'expected = declare
   per-period places (the picker); 'off = stop the watch + clear position."
  (when (and *location-watch-id* (not (eq? mode 'live)))
    (geo-watch-stop *location-watch-id*)
    (set! *location-watch-id* #f))
  (set! *location-mode* mode)
  (cond
    ((not *acting-as*) #f)                          ; nothing to share without a user
    ((eq? mode 'here) (geo-get-current (procedure->external on-position)))
    ((eq? mode 'live)
     (unless *location-watch-id*
       (set! *location-watch-id* (geo-watch-start (procedure->external on-position)))))
    ((eq? mode 'off) (planner-mutate! 'set-position *acting-as* 0 #f)))
    ;; 'expected: no GPS — the per-period picker (render-location-expected) drives it.
  (refresh!))

(define (set-expected-position! period place)
  "Declare where the acting-as user EXPECTS to be at PERIOD (a future day) — the
   planner uses it as the commute origin for that period. Empty clears."
  (when *acting-as*
    (planner-mutate! 'set-position *acting-as* period (if (string=? place "") #f place))))

(define (render-location-expected)
  "Per-period place picker, shown when location mode = 'expected: declare where
   you'll be over the next few days so the planner places future work near you.
   Places come from the scope's locations (scope-snapshot 'locations)."
  (if (not (eq? *location-mode* 'expected)) '()
      (let ((locs (or (and *scope-snapshot* (assq-ref *scope-snapshot* 'locations)) '())))
        (list
         `(div (@ (class "loc-expected"))
               (span (@ (class "loc-expected-label")) "I'll be at:")
               ,@(map
                  (lambda (t)
                    `(div (@ (class "loc-expected-row"))
                          (span (@ (class "loc-expected-day"))
                                ,(if (= t 0) "today" (string-append "+" (number->string t) "d")))
                          (select (@ (id ,(string-append "loc-exp-" (number->string t)))
                                     (change ,(lambda (e) (set-expected-position! t (event-target-value e)))))
                                  (option (@ (value "")) "—")
                                  ,@(map (lambda (loc)
                                           `(option (@ (value ,(alist-ref loc 'id "")))
                                                    ,(alist-ref loc 'name ""))) locs))))
                  '(0 1 2)))))))

(define (set-active-scope! v)
  "Set the session-active scope to V (a scope-id string, or empty for #f).
   Resets plan, acting-as, and inventory-local selection (which become
   meaningless under a new scope), then refreshes both calendar and
   inventory caches so whichever tab the user is on stays current."
  (let ((scope (if (string=? v "") #f v)))
    (set! *active-scope* scope)
    (set! *active-plan* #f)
    (set! *acting-as* #f)
    ;; Inventory-local selection — clear because spec/resource IDs are
    ;; scope-bound and won't resolve under the new scope.
    (set! *inv-selected-spec* #f)
    (set! *inv-selected-resource* #f)
    (set! *inv-breadcrumb* '())
    (set! *inv-detail-cache* '())
    (set! *inv-active-category* #f)
    (set-location-hash! (cal-hash))
    (refresh-scope-snapshot!)
    (refresh-inventory-snapshot!)))

(define (set-active-plan! v)
  "Set the active plan within the current scope."
  (set! *active-plan* (if (string=? v "") #f v))
  (set! *inv-selected-spec* #f)
  (set! *inv-selected-resource* #f)
  (set! *inv-breadcrumb* '())
  (set! *inv-detail-cache* '())
  (set-location-hash! (cal-hash))
  (refresh-scope-snapshot!)
  (refresh-inventory-snapshot!))

(define (set-acting-as! v)
  "Set who the user is acting as within the current scope (a member-id
   string, or empty for the observer / no-one)."
  (set! *acting-as* (if (string=? v "") #f v))
  (refresh!))


(define (planner-fetch-resource-detail! rid)
  "Pull and cache the resource-detail for RID. No-op when cap is
   unavailable, scope is unset, or the rid is already cached."
  (when (and *planner-cap* *active-scope* rid
             (not (assoc rid *inv-detail-cache*)))
    (with-vat *ocapn-vat*
      (on (<- *planner-cap* 'resource-detail *active-scope* rid)
          (lambda (detail)
            (when detail
              (set! *inv-detail-cache*
                    (cons (cons rid detail) *inv-detail-cache*))
              (refresh!)))
          #:catch (lambda (err) #f)))))

(define (planner-fetch-process-context! proc-id)
  "Pull and cache process-context for PROC-ID. No-op if already cached
   or if cap is unavailable."
  (when (and *planner-cap* *active-scope* proc-id
             (not (assoc proc-id *cal-process-context*)))
    (with-vat *ocapn-vat*
      (on (<- *planner-cap* 'process-context *active-scope* proc-id)
          (lambda (ctx)
            (when ctx
              (set! *cal-process-context*
                    (cons (cons proc-id ctx) *cal-process-context*))
              (refresh!)))
          #:catch (lambda (err) #f)))))

(define (planner-accept! iid)
  "Promote an intent to a commitment via the planner. The acting-as
   user becomes the commitment provider."
  (when *acting-as*
    (planner-mutate! 'accept-assignment iid *acting-as*)))

(define (planner-decline! iid)
  "Clear the suggested-provider for an intent. The intent flips to
   'unmatched and another agent can volunteer."
  (planner-mutate! 'decline-assignment iid (or *acting-as* "")))

(define (planner-reject! evt)
  "The popup's REJECT: decline the suggestion (when it points at the
   acting-as user) AND stamp declined willingness for the (skill, cell)
   so a gated re-solve doesn't re-offer this need to them."
  (let ((iid (alist-ref evt 'id ""))
        (sp  (alist-ref evt 'suggested #f)))
    (when (and sp *acting-as* (equal? sp *acting-as*))
      (planner-decline! iid))
    (planner-express-willingness! evt #f)))

(define (planner-express-willingness! intent willing?)
  "The offer-side opt-in: the acting-as user marks (or withdraws) willingness for
   INTENT's need — keyed by their (skill, cell). Over-subscribable, binds nothing.
   Then materialize-willing assigns the willing to the open needs (the race), so
   marking willing immediately surfaces under 'Awaiting your acceptance'; the hour
   budget binds later, at accept (promote-to-commitment)."
  (when (and *acting-as* *planner-cap* *active-scope*)
    (let ((skill (alist-ref intent 'spec ""))
          (cell  (alist-ref intent 'cell "")))
      (with-vat *ocapn-vat*
        (on (<- *planner-cap* 'express-willingness *active-scope* *acting-as* skill cell willing?)
            (lambda (r1)
              (when (and (pair? r1) (eq? (car r1) 'error))
                (planner-log-error! "express-willingness" (cdr r1)))
              ;; chain: assign willing → open needs, then refresh once
              (on (<- *planner-cap* 'materialize-willing *active-scope*)
                  (lambda (r2) (refresh-scope-snapshot!))
                  #:catch (lambda (e)
                            (planner-log-error! "materialize-willing" e)
                            (refresh-scope-snapshot!))))
            #:catch (lambda (e)
                      (planner-log-error! "express-willingness" e)
                      (refresh-scope-snapshot!)))))))

(define (planner-record-effort! cid qty)
  "Build a real EconomicEvent server-side and feed it to the observer.
   The browser sees the result via fulfilled-qty advancing on next snapshot."
  (when *acting-as*
    (planner-mutate! 'record-effort cid *acting-as* qty "hours")))

;;; ── VF temporal helpers ──────────────────────────────────────────────────

(define (vf-day->dow sym)
  "Convert a VF day symbol (monday..sunday) to 0-based DOW (0=Mon)."
  (case sym
    ((monday) 0) ((tuesday) 1) ((wednesday) 2) ((thursday) 3)
    ((friday) 4) ((saturday) 5) ((sunday) 6) (else #f)))

(define (pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))
(define (make-time-range start end) `((start . ,start) (end . ,end)))
(define (make-day-schedule days trs) `((days . ,days) (time-ranges . ,trs)))
(define (make-availability-window tz note ds geo) `((day-schedules . ,ds)))

(define (hhmm->min s)
  "Parse 'HH:MM' to minutes since midnight."
  (if (or (not s) (< (string-length s) 5)) 540
      (let ((h (safe-string->number (substring s 0 2)))
            (m (safe-string->number (substring s 3 5))))
        (+ (* (or h 9) 60) (or m 0)))))

;;; ── Availability push ───────────────────────────────────────────────────
;;; Convert calendar availability slots to a VF AvailabilityWindow and
;;; push to the server. Called after every drag/create/resize operation.

(define *day-symbols* '#(monday tuesday wednesday thursday friday saturday sunday))

(define (cal-availability->vf-window)
  "Convert *cal-availability* to a VF AvailabilityWindow.
   Slots already carry day-symbol and start-time/end-time (HH:MM)."
  (let* ((grouped
          (let loop ((slots *cal-availability*) (acc '()))
            (if (null? slots) acc
                (let* ((s (car slots))
                       (sym (or (alist-ref s 'day-symbol) 'monday))
                       (tr (make-time-range
                            (or (alist-ref s 'start-time) "09:00")
                            (or (alist-ref s 'end-time) "17:00")))
                       (existing (assq sym acc)))
                  (loop (cdr slots)
                        (if existing
                            (map (lambda (g)
                                   (if (eq? (car g) sym)
                                       (cons sym (cons tr (cdr g)))
                                       g))
                                 acc)
                            (cons (list sym tr) acc)))))))
         (day-schedules
          (map (lambda (g)
                 (make-day-schedule (list (car g)) (cdr g)))
               grouped)))
    (make-availability-window #f #f day-schedules #f)))

(define (push-availability!)
  "Push current availability to the server for the acting-as agent."
  (when *acting-as*
    (let ((aw (cal-availability->vf-window)))
      (planner-mutate! 'set-availability *acting-as* aw))))

(define (declare-skill! skill-spec-id)
  "Declare that the acting-as agent holds SKILL-SPEC-ID."
  (when *acting-as*
    (planner-mutate! 'declare-skill *acting-as* skill-spec-id)))

(define (revoke-skill! skill-spec-id)
  "Revoke SKILL-SPEC-ID from the acting-as agent."
  (when *acting-as*
    (planner-mutate! 'revoke-skill *acting-as* skill-spec-id)))

;;; ── Detail panel: process flows + supply chain ────────────────────────────
;;;
;;; Pulls from *cal-process-context* (cached planner replies). The legacy
;;; *fed-commitments* / *fed-processes* fallback is gone — when an event
;;; has a vf-process-id we always ask the planner.

(define (selected-event-process-flows evt)
  (cond
    ((not (and evt (alist-ref evt 'vf-process-id #f))) '())
    (else
     (let* ((proc-id (alist-ref evt 'vf-process-id))
            (cached  (assoc proc-id *cal-process-context*)))
       (if cached
           (or (assq-ref (cdr cached) 'inputs) '())
           '())))))

(define (selected-event-supply-chain evt)
  ;; Phase 2: server returns empty upstream/downstream until recipe-chain
  ;; walking is wired in build-process-context. Render handles ().
  (cond
    ((not (and evt (alist-ref evt 'vf-process-id #f))) '())
    (else
     (let* ((proc-id (alist-ref evt 'vf-process-id))
            (cached  (assoc proc-id *cal-process-context*)))
       (if cached
           (append (or (assq-ref (cdr cached) 'upstream) '())
                   (or (assq-ref (cdr cached) 'downstream) '()))
           '())))))

;;; ── Project intents/commitments onto calendar grid ────────────────────────

(define* (vf-record->grid-event rec
                                #:key (source 'intent)
                                      (default-color "#8b7b96"))
  "Convert a planner record (intent or commitment alist) to a calendar
   event alist consumed by render-event-block.
   SOURCE drives the dashed/solid styling.
   Status is derived from fulfilled-qty vs effort-qty:
     - intent       → open
     - commitment   → committed (default) or fulfilled (if fulfilled-qty
                      has caught up to effort-qty)"
  (let* ((sp     (or (alist-ref rec 'provider #f)
                     (alist-ref rec 'suggested #f)))
         (spn    (alist-ref rec 'suggested-name #f))
         (ms     (alist-ref rec 'match 'unassigned))
         (color  (if sp (person-color sp *cal-people*) default-color))
         (eff    (alist-ref rec 'effort 0))
         (fulf   (alist-ref rec 'done 0))
         (status (cond
                   ((eq? source 'intent) 'open)
                   ((and (eq? source 'commitment) (> eff 0) (>= fulf eff))
                    'fulfilled)
                   ((eq? source 'commitment) 'committed)
                   (else 'open))))
    (list (cons 'id        (alist-ref rec 'id ""))
          (cons 'title     (string-append
                            (alist-ref rec 'proc-name "")
                            ": "
                            (alist-ref rec 'spec "")))
          (cons 'date      (alist-ref rec 'date ""))
          (cons 'sh (alist-ref rec 'sh 9))
          (cons 'sm  (alist-ref rec 'sm 0))
          (cons 'eh   (alist-ref rec 'eh 10))
          (cons 'em    (alist-ref rec 'em 0))
          (cons 'person    (or sp ""))
          (cons 'location  "")
          (cons 'color     color)
          (cons 'source    source)
          (cons 'status    status)
          (cons 'description (alist-ref rec 'scope ""))
          ;; VF metadata for the detail panel
          (cons 'vf-process-id    (alist-ref rec 'proc #f))
          (cons 'vf-action        'work)
          (cons 'vf-resource-spec (alist-ref rec 'spec #f))
          (cons 'vf-effort-qty    (alist-ref rec 'effort 0))
          (cons 'vf-effort-unit   (alist-ref rec 'effort-unit "hr"))
          (cons 'vf-scope         (alist-ref rec 'scope #f))
          (cons 'vf-fulfilled-qty (alist-ref rec 'done 0))
          ;; Assignment metadata (consumed by render-event-detail-panel)
          (cons 'suggested sp)
          (cons 'suggested-name spn)
          (cons 'match ms)
          ;; Willingness metadata — the detail panel's three-way
          ;; response (willing/commit/reject) keys the planner's
          ;; express-willingness by (skill, cell) and reads the
          ;; candidate race for the acting-as user's current status.
          (cons 'spec   (alist-ref rec 'spec #f))
          (cons 'cell            (alist-ref rec 'cell ""))
          (cons 'willing (alist-ref rec 'willing '())))))

(define (intent->grid-event intent)
  (vf-record->grid-event intent #:source 'intent #:default-color "#8b7b96"))

(define (commitment->grid-event cmt)
  (vf-record->grid-event cmt #:source 'commitment #:default-color "#63b3ed"))

;;; ── URL hash sync for scope/plan ──────────────────────────────────────────
;;;
;;; Format: #calendar/<scope-id>/<plan-id>
;;; Example: #calendar/org:meeting/plan-weekly
;;; Plan segment is optional.

(define (cal-hash)
  "Build the URL hash string from current *active-scope* / *active-plan*."
  (cond
    ((and *active-scope* *active-plan*)
     (string-append "#calendar/" *active-scope* "/" *active-plan*))
    (*active-scope*
     (string-append "#calendar/" *active-scope*))
    (else "#calendar")))

(define (parse-cal-hash!)
  "Read the current URL hash and set *active-scope* / *active-plan* if present."
  (let ((h (get-location-hash)))
    (when (and h (> (string-length h) 1))
      ;; Strip leading '#'
      (let* ((bare (substring h 1 (string-length h)))
             (parts (split-string bare #\/)))
        (when (and (pair? parts) (string=? (car parts) "calendar"))
          (let ((rest (cdr parts)))
            (when (pair? rest)
              (let ((scope-seg (car rest)))
                (unless (string=? scope-seg "")
                  (set! *active-scope* scope-seg))))
            (when (and (pair? rest) (pair? (cdr rest)))
              (let ((plan-seg (cadr rest)))
                (unless (string=? plan-seg "")
                  (set! *active-plan* plan-seg))))))))))

;;; ── Cycle event status (dispatches user vs derived) ─────────────────────

(define (cycle-event-status! evt new-status)
  "Status cycle behaviour, dispatched by event source:
     - Derived intent (source=intent): no-op (use Accept/Decline instead).
     - Derived commitment (source=commitment): record the remaining effort
       as a single EconomicEvent via the planner, which advances the
       observer's fulfillment-state.
     - User-created event: update the field on *cal-user-events*, persist."
  (let* ((iid (alist-ref evt 'id ""))
         (src (alist-ref evt 'source 'event)))
    (cond
      ((eq? src 'intent) #f)

      ((eq? src 'commitment)
       (let* ((eff  (alist-ref evt 'vf-effort-qty 0))
              (fulf (alist-ref evt 'vf-fulfilled-qty 0))
              (rem  (max 0 (- eff fulf))))
         (when (> rem 0)
           (planner-record-effort! iid rem))))

      (else
       (set! *cal-user-events*
             (map (lambda (ev)
                    (if (equal? (alist-ref ev 'id) iid)
                        (alist-set ev 'status new-status)
                        ev))
                  *cal-user-events*))
       (set! *cal-selected-event*
             (%find (lambda (ev) (equal? (alist-ref ev 'id) iid))
                    *cal-user-events*))
       (save-calendar!)
       (refresh!)))))

;;; ── Calendar view ───────────────────────────────────────────────────────────

;;; Availability drag helpers — used by the in-grid availability editor.
;;; A slot is an alist with keys: id person day start-hour start-min end-hour end-min.
;;; Drag state is held in *cal-avail-drag*; mode is one of 'create | 'resize-top | 'resize-bot.

(define *cal-hour-px* 60)               ;; must match *hour-height* in (playnet ui calendar)
(define *cal-snap-min* 15)              ;; drag snaps to this minute resolution

(define (cal-snap-mins total-min)
  "Snap TOTAL-MIN to the nearest *cal-snap-min* boundary, clamped to [0, 1440]."
  (let* ((clamped (max 0 (min 1440 total-min)))
         (s *cal-snap-min*))
    (* s (inexact->exact (round (/ clamped s))))))

(define (cal-min->hm total-min)
  "Split TOTAL-MIN into (hour . min)."
  (let* ((h (quotient total-min 60))
         (m (modulo total-min 60)))
    (cons h m)))

(define (cal-find-avail slot-id)
  (and slot-id
       (%find (lambda (s) (equal? (alist-ref s 'id #f) slot-id))
              *cal-availability*)))

(define (cal-update-avail! slot-id updater)
  "Replace the slot whose id matches SLOT-ID with (updater slot)."
  (when slot-id
    (set! *cal-availability*
          (map (lambda (s)
                 (if (equal? (alist-ref s 'id #f) slot-id)
                     (updater s)
                     s))
               *cal-availability*))))

(define (cal-delete-avail! slot-id)
  (when slot-id
    (set! *cal-availability*
          (filter (lambda (s) (not (equal? (alist-ref s 'id #f) slot-id)))
                  *cal-availability*))))

(define (cal-make-avail-slot dow start-min end-min)
  "Create an availability slot as a VF-compatible alist. Internally
   stores the VF TimeRange (HH:MM strings) alongside legacy fields
   for backward-compatible rendering."
  (let* ((id *cal-avail-next-id*)
         (s-hm (cal-min->hm start-min))
         (e-hm (cal-min->hm end-min))
         (start-str (string-append (pad2 (car s-hm)) ":" (pad2 (cdr s-hm))))
         (end-str   (string-append (pad2 (car e-hm)) ":" (pad2 (cdr e-hm)))))
    (set! *cal-avail-next-id* (+ id 1))
    (list (cons 'id id)
          (cons 'person "me")
          (cons 'day dow)
          (cons 'day-symbol (vector-ref *day-symbols* dow))
          (cons 'start-time start-str)
          (cons 'end-time end-str)
          (cons 'sh (car s-hm)) (cons 'sm (cdr s-hm))
          (cons 'eh (car e-hm))   (cons 'em (cdr e-hm)))))

(define (slot-start-min s)
  (+ (* (alist-ref s 'sh 0) 60) (alist-ref s 'sm 0)))
(define (slot-end-min s)
  (+ (* (alist-ref s 'eh 0) 60) (alist-ref s 'em 0)))

(define (cal-set-slot-times s start-min end-min)
  (let ((s-hm (cal-min->hm start-min))
        (e-hm (cal-min->hm end-min)))
    (alist-set
     (alist-set
      (alist-set
       (alist-set s 'sh (car s-hm)) 'sm (cdr s-hm))
      'eh (car e-hm))
     'em (cdr e-hm))))

(define (cal-merge-day-slots! dow)
  "Coalesce overlapping/touching slots for DOW into the smallest disjoint set.
   Each merged group keeps the earliest member's id."
  (let* ((same-day (filter (lambda (s) (= (alist-ref s 'day 0) dow))
                           *cal-availability*))
         (other    (filter (lambda (s) (not (= (alist-ref s 'day 0) dow)))
                           *cal-availability*))
         (sorted (sort same-day
                       (lambda (a b) (< (slot-start-min a) (slot-start-min b))))))
    (let loop ((rest sorted) (cur #f) (cur-s 0) (cur-e 0) (acc '()))
      (cond
       ((null? rest)
        (let ((merged (if cur
                          (reverse (cons (cal-set-slot-times cur cur-s cur-e) acc))
                          (reverse acc))))
          (set! *cal-availability* (append other merged))))
       (else
        (let* ((s (car rest)) (ns (slot-start-min s)) (ne (slot-end-min s)))
          (cond
           ((not cur)            (loop (cdr rest) s ns ne acc))
           ((<= ns cur-e)        (loop (cdr rest) cur cur-s (max cur-e ne) acc))
           (else
            (loop (cdr rest) s ns ne
                  (cons (cal-set-slot-times cur cur-s cur-e) acc))))))))))

(define (cal-merge-all!)
  "Merge overlaps on every day-of-week."
  (for-each cal-merge-day-slots! '(0 1 2 3 4 5 6)))

(define (dow-span lo hi)
  "Inclusive list of integers from LO to HI."
  (let* ((a (min lo hi)) (b (max lo hi)))
    (let build ((i a))
      (if (> i b) '() (cons i (build (+ i 1)))))))

(define (render-calendar-view)
  "Render the calendar page, wiring state to the pure calendar module.
   Reads only — never mutates derived state. Mutations happen in the
   click/change callbacks (and at calendar-tab open time)."
  (let ((ws (or *cal-week-start*
                (day-start-ms (inexact->exact (floor (date-now))))))
        (events (all-cal-events)))
    (calendar-page
     #:anchor-ms ws
     #:view-mode *cal-view-mode*
     #:on-set-view-mode (lambda (mode)
                          (set! *cal-view-mode* mode)
                          (refresh!))
     #:on-pick-day (lambda (ms)
                     (set! *cal-week-start* ms)
                     (set! *cal-view-mode* 'day)
                     (refresh!))
     #:events events
     #:people *cal-people*
     #:availability *cal-availability*
     #:editing-event *cal-editing-event*
     #:editing-availability *cal-editing-avail*
     #:current-time-ms (inexact->exact (floor (date-now)))
     #:unscheduled-intents *cal-unscheduled-intents*
     #:selected-intent-id (and *cal-selected-intent*
                                (alist-ref *cal-selected-intent* 'id #f))
     #:on-select-intent (lambda (intent)
                          (if (and *cal-selected-intent*
                                   (equal? (alist-ref *cal-selected-intent* 'id)
                                           (alist-ref intent 'id)))
                              (set! *cal-selected-intent* #f)
                              (set! *cal-selected-intent* intent))
                          (refresh!))
     #:selected-event *cal-selected-event*
     #:process-commitments
       (if (and *cal-selected-event*
                (alist-ref *cal-selected-event* 'vf-process-id #f))
           ;; Find other events in the same process
           (filter (lambda (ev)
                     (and (not (equal? (alist-ref ev 'id)
                                       (alist-ref *cal-selected-event* 'id)))
                          (equal? (alist-ref ev 'vf-process-id #f)
                                  (alist-ref *cal-selected-event* 'vf-process-id))))
                   events)
           '())
     #:process-flows (selected-event-process-flows *cal-selected-event*)
     #:supply-chain  (selected-event-supply-chain  *cal-selected-event*)
     #:on-event-click (lambda (evt)
                        ;; Always open detail panel
                        (set! *cal-selected-event* evt)
                        (set! *cal-editing-event* #f)
                        ;; Lazily fetch process-context for VF events so the
                        ;; detail panel can render inputs/outputs.
                        (let ((proc-id (alist-ref evt 'vf-process-id #f)))
                          (when proc-id
                            (planner-fetch-process-context! proc-id)))
                        (refresh!))
     #:on-cycle-status (lambda (evt)
                         ;; Cycle VF status: open → committed → fulfilled → open
                         (let ((status (alist-ref evt 'status 'open)))
                           (cond
                            ((eq? status 'open)      (cycle-event-status! evt 'committed))
                            ((eq? status 'committed) (cycle-event-status! evt 'fulfilled))
                            ((eq? status 'fulfilled) (cycle-event-status! evt 'open)))))
     #:on-close-detail (lambda (e)
                         (set! *cal-selected-event* #f)
                         (refresh!))
     #:on-edit-from-detail (lambda (e)
                             (set! *cal-editing-event* *cal-selected-event*)
                             (set! *cal-selected-event* #f)
                             (refresh!))
     #:on-delete-from-detail (lambda (e)
                               ;; Only user-created events can be deleted; derived
                               ;; events are owned by the planner. Check the
                               ;; current snapshot to dispatch.
                               (let ((evt-id (alist-ref *cal-selected-event* 'id "")))
                                 (cond
                                   ((planner-knows-id? evt-id)
                                    ;; Derived — leave it alone, just close the panel
                                    (set! *cal-selected-event* #f)
                                    (refresh!))
                                   (else
                                    (set! *cal-user-events*
                                          (filter (lambda (ev)
                                                    (not (equal? (alist-ref ev 'id) evt-id)))
                                                  *cal-user-events*))
                                    (set! *cal-selected-event* #f)
                                    (save-calendar!)
                                    (refresh!)))))
     #:on-slot-click (lambda (date-str hour)
                       (set! *cal-selected-event* #f)
                       (let ((id (string-append "evt-" (number->string *cal-next-id*))))
                         (if *cal-selected-intent*
                             ;; Two-click scheduling: intent + time slot → VF event
                             (let* ((intent *cal-selected-intent*)
                                    (qty (alist-ref intent 'effort 1))
                                    (end-h (min 23 (+ hour (max 1 (inexact->exact (ceiling qty)))))))
                               (set! *cal-editing-event*
                                     (list (cons 'id id)
                                           (cons 'title (string-append
                                                         (alist-ref intent 'proc-name "Work")
                                                         " (" (alist-ref intent 'spec "") ")"))
                                           (cons 'date date-str)
                                           (cons 'sh hour)
                                           (cons 'sm 0)
                                           (cons 'eh end-h)
                                           (cons 'em 0)
                                           (cons 'person "me")
                                           (cons 'location "")
                                           (cons 'description "")
                                           (cons 'color "#63b3ed")
                                           (cons 'source 'commitment)
                                           (cons 'status 'open)
                                           (cons 'vf-process-id (alist-ref intent 'proc ""))
                                           (cons 'vf-action 'work)
                                           (cons 'vf-resource-spec (alist-ref intent 'spec ""))
                                           (cons 'vf-effort-qty qty)
                                           (cons 'vf-effort-unit (alist-ref intent 'effort-unit "hr"))
                                           (cons 'vf-scope (alist-ref intent 'scope ""))
                                           (cons 'vf-fulfilled-qty 0)))
                               (set! *cal-selected-intent* #f)
                               (refresh!))
                             ;; Normal: create plain event
                             (begin
                               (set! *cal-editing-event*
                                     (list (cons 'id id)
                                           (cons 'title "")
                                           (cons 'date date-str)
                                           (cons 'sh hour)
                                           (cons 'sm 0)
                                           (cons 'eh (min 23 (+ hour 1)))
                                           (cons 'em 0)
                                           (cons 'person "me")
                                           (cons 'location "")
                                           (cons 'description "")
                                           (cons 'color "#63b3ed")
                                           (cons 'source 'event)
                                           (cons 'status 'open)))
                               (refresh!)))))
     #:on-prev (lambda (e)
                 (set! *cal-week-start* (step-anchor *cal-view-mode* ws -1))
                 (refresh!))
     #:on-next (lambda (e)
                 (set! *cal-week-start* (step-anchor *cal-view-mode* ws  1))
                 (refresh!))
     #:on-today (lambda (e)
                  (set! *cal-week-start*
                        (day-start-ms (inexact->exact (floor (date-now)))))
                  (refresh!))
     #:on-toggle-person (lambda (person-id)
                          (set! *cal-people*
                                (map (lambda (p)
                                       (if (equal? (alist-ref p 'id) person-id)
                                           (let ((vis (alist-ref p 'visible #t)))
                                             (map (lambda (pair)
                                                    (if (eq? (car pair) 'visible)
                                                        (cons 'visible (not vis))
                                                        pair))
                                                  p))
                                           p))
                                     *cal-people*))
                          (save-calendar!)
                          (refresh!))
     #:on-toggle-avail-editor (lambda (e)
                                (set! *cal-editing-avail* (not *cal-editing-avail*))
                                (refresh!))
     #:on-save-event (lambda (e)
                       ;; Read values from modal inputs
                       (let* ((title-el (get-element-by-id "cal-evt-title"))
                              (person-el (get-element-by-id "cal-evt-person"))
                              (loc-el (get-element-by-id "cal-evt-location"))
                              (desc-el (get-element-by-id "cal-evt-desc"))
                              (sh-el (get-element-by-id "cal-evt-sh"))
                              (sm-el (get-element-by-id "cal-evt-sm"))
                              (eh-el (get-element-by-id "cal-evt-eh"))
                              (em-el (get-element-by-id "cal-evt-em"))
                              (title (element-value title-el))
                              (person (element-value person-el))
                              (loc (element-value loc-el))
                              (desc (element-value desc-el))
                              (sh (safe-string->number (element-value sh-el)))
                              (sm (safe-string->number (element-value sm-el)))
                              (eh (safe-string->number (element-value eh-el)))
                              (em (safe-string->number (element-value em-el)))
                              (evt-id (alist-ref *cal-editing-event* 'id ""))
                              (evt-date (alist-ref *cal-editing-event* 'date ""))
                              (evt-source (alist-ref *cal-editing-event* 'source 'event))
                              (evt-status (alist-ref *cal-editing-event* 'status 'open)))
                         ;; Ensure person exists in people list
                         (cal-ensure-person! person)
                         (let* ((color (person-color person *cal-people*))
                                (new-evt (list (cons 'id evt-id)
                                              (cons 'title title)
                                              (cons 'date evt-date)
                                              (cons 'sh sh)
                                              (cons 'sm sm)
                                              (cons 'eh eh)
                                              (cons 'em em)
                                              (cons 'person person)
                                              (cons 'location loc)
                                              (cons 'description desc)
                                              (cons 'color color)
                                              (cons 'source evt-source)
                                              (cons 'status evt-status))))
                           ;; Remove old version if exists, add new (user-events only).
                           (set! *cal-user-events*
                                 (cons new-evt
                                       (filter (lambda (ev)
                                                 (not (equal? (alist-ref ev 'id) evt-id)))
                                               *cal-user-events*)))
                           ;; Advance ID counter if this was new
                           (when (>= *cal-next-id*
                                     (safe-string->number
                                      (if (> (string-length evt-id) 4)
                                          (substring evt-id 4) "0")))
                             (set! *cal-next-id* (+ *cal-next-id* 1)))
                           (set! *cal-editing-event* #f)
                           (save-calendar!)
                           (refresh!))))
     #:on-delete-event (lambda (e)
                         (let ((evt-id (alist-ref *cal-editing-event* 'id "")))
                           (set! *cal-user-events*
                                 (filter (lambda (ev)
                                           (not (equal? (alist-ref ev 'id) evt-id)))
                                         *cal-user-events*))
                           (set! *cal-editing-event* #f)
                           (save-calendar!)
                           (refresh!)))
     #:on-cancel-edit (lambda (e)
                        (set! *cal-editing-event* #f)
                        (refresh!))
     #:on-create-avail-start (lambda (e dow hour)
                               ;; Seed a 30-min slot starting at HOUR on DOW
                               ;; and immediately enter resize-bottom drag mode.
                               (let* ((start-min (* hour 60))
                                      (end-min   (+ start-min 30))
                                      (slot      (cal-make-avail-slot dow start-min end-min))
                                      (slot-id   (alist-ref slot 'id #f)))
                                 (set! *cal-availability*
                                       (append *cal-availability* (list slot)))
                                 (set! *cal-avail-drag*
                                       (list (cons 'mode 'resize-bot)
                                             (cons 'slot-id slot-id)
                                             (cons 'start-y (event-client-y e))
                                             (cons 'orig-sh (car (cal-min->hm start-min)))
                                             (cons 'orig-sm (cdr (cal-min->hm start-min)))
                                             (cons 'orig-eh (car (cal-min->hm end-min)))
                                             (cons 'orig-em (cdr (cal-min->hm end-min)))
                                             (cons 'created? #t)))
                                 (refresh!)))
     #:on-resize-avail-start (lambda (e slot-id edge)
                               (let ((slot (cal-find-avail slot-id)))
                                 (when slot
                                   (set! *cal-avail-drag*
                                         (list (cons 'mode (if (eq? edge 'top) 'resize-top 'resize-bot))
                                               (cons 'slot-id slot-id)
                                               (cons 'start-y (event-client-y e))
                                               (cons 'orig-sh (alist-ref slot 'sh 9))
                                               (cons 'orig-sm (alist-ref slot 'sm 0))
                                               (cons 'orig-eh (alist-ref slot 'eh 17))
                                               (cons 'orig-em (alist-ref slot 'em 0))
                                               (cons 'created? #f))))))
     #:on-move-avail-start (lambda (e slot-id)
                             (let ((slot (cal-find-avail slot-id)))
                               (when slot
                                 (set! *cal-avail-drag*
                                       (list (cons 'mode 'move)
                                             (cons 'slot-id slot-id)
                                             (cons 'start-y (event-client-y e))
                                             (cons 'orig-sh (alist-ref slot 'sh 9))
                                             (cons 'orig-sm (alist-ref slot 'sm 0))
                                             (cons 'orig-eh (alist-ref slot 'eh 17))
                                             (cons 'orig-em (alist-ref slot 'em 0))
                                             (cons 'origin-dow (alist-ref slot 'day 0))
                                             (cons 'current-dow (alist-ref slot 'day 0))
                                             (cons 'created? #f))))))
     #:on-spread-avail-start (lambda (e slot-id edge)
                               (let ((slot (cal-find-avail slot-id)))
                                 (when slot
                                   (let ((dow (alist-ref slot 'day 0)))
                                     (set! *cal-avail-drag*
                                           (list (cons 'mode (if (eq? edge 'left)
                                                                 'spread-left
                                                                 'spread-right))
                                                 (cons 'slot-id slot-id)
                                                 (cons 'start-y (event-client-y e))
                                                 (cons 'orig-sh (alist-ref slot 'sh 9))
                                                 (cons 'orig-sm (alist-ref slot 'sm 0))
                                                 (cons 'orig-eh (alist-ref slot 'eh 17))
                                                 (cons 'orig-em (alist-ref slot 'em 0))
                                                 (cons 'origin-dow dow)
                                                 (cons 'current-dow dow)
                                                 (cons 'created? #f)))))))
     #:on-day-hover (lambda (e dow)
                      (when *cal-avail-drag*
                        (let* ((d *cal-avail-drag*)
                               (mode (alist-ref d 'mode 'move))
                               (slot-id (alist-ref d 'slot-id #f))
                               (prev-dow (alist-ref d 'current-dow dow)))
                          (unless (= prev-dow dow)
                            (set! *cal-avail-drag*
                                  (alist-set d 'current-dow dow))
                            ;; Move mode: live-update the slot's day so it
                            ;; visually follows the cursor across columns.
                            (when (eq? mode 'move)
                              (cal-update-avail! slot-id
                                (lambda (s) (alist-set s 'day dow))))
                            (refresh!)))))
     #:on-delete-avail (lambda (e slot-id)
                         (cal-delete-avail! slot-id)
                         (refresh!))
     #:on-avail-drag-move (lambda (e)
                            (when *cal-avail-drag*
                              (let* ((d *cal-avail-drag*)
                                     (mode    (alist-ref d 'mode 'resize-bot))
                                     (slot-id (alist-ref d 'slot-id #f))
                                     (start-y (alist-ref d 'start-y 0))
                                     (orig-sh (alist-ref d 'orig-sh 0))
                                     (orig-sm (alist-ref d 'orig-sm 0))
                                     (orig-eh (alist-ref d 'orig-eh 0))
                                     (orig-em (alist-ref d 'orig-em 0))
                                     (cur-y   (event-client-y e))
                                     (delta-min (inexact->exact
                                                 (round (* (- cur-y start-y)
                                                           (/ 60 *cal-hour-px*)))))
                                     (orig-start (+ (* orig-sh 60) orig-sm))
                                     (orig-end   (+ (* orig-eh 60) orig-em)))
                                (cond
                                 ((eq? mode 'resize-top)
                                  (let* ((new-start (cal-snap-mins
                                                     (min (- orig-end *cal-snap-min*)
                                                          (+ orig-start delta-min))))
                                         (hm (cal-min->hm new-start)))
                                    (cal-update-avail! slot-id
                                      (lambda (s)
                                        (alist-set (alist-set s 'sh (car hm))
                                                   'sm (cdr hm))))))
                                 ((eq? mode 'resize-bot)
                                  (let* ((new-end (cal-snap-mins
                                                   (max (+ orig-start *cal-snap-min*)
                                                        (+ orig-end delta-min))))
                                         (hm (cal-min->hm new-end)))
                                    (cal-update-avail! slot-id
                                      (lambda (s)
                                        (alist-set (alist-set s 'eh (car hm))
                                                   'em (cdr hm))))))
                                 ((eq? mode 'move)
                                  ;; Shift the whole block; clamp the shift so
                                  ;; neither edge leaves [0, 1440].
                                  (let* ((dur (- orig-end orig-start))
                                         (raw-shift (cal-snap-mins (+ orig-start delta-min)))
                                         (new-start (max 0 (min (- 1440 dur) raw-shift)))
                                         (new-end (+ new-start dur))
                                         (s-hm (cal-min->hm new-start))
                                         (e-hm (cal-min->hm new-end)))
                                    (cal-update-avail! slot-id
                                      (lambda (s)
                                        (alist-set
                                         (alist-set
                                          (alist-set
                                           (alist-set s 'sh (car s-hm))
                                           'sm (cdr s-hm))
                                          'eh (car e-hm))
                                         'em (cdr e-hm)))))))
                                (refresh!))))
     #:on-avail-drag-end (lambda (e)
                           (when *cal-avail-drag*
                             (let* ((d       *cal-avail-drag*)
                                    (mode    (alist-ref d 'mode 'move))
                                    (slot-id (alist-ref d 'slot-id #f))
                                    (origin  (alist-ref d 'origin-dow #f))
                                    (current (alist-ref d 'current-dow origin))
                                    (slot    (cal-find-avail slot-id)))
                               (cond
                                ;; Spread: clone the slot's time-range into
                                ;; each dow in [origin, current], then merge.
                                ((and slot
                                      (or (eq? mode 'spread-left)
                                          (eq? mode 'spread-right))
                                      origin current
                                      (not (= origin current)))
                                 (let* ((sm (slot-start-min slot))
                                        (em (slot-end-min slot)))
                                   (for-each
                                    (lambda (dow)
                                      (unless (= dow origin)
                                        (let ((new-slot
                                               (cal-make-avail-slot dow sm em)))
                                          (set! *cal-availability*
                                                (append *cal-availability*
                                                        (list new-slot))))))
                                    (dow-span origin current))
                                   (for-each cal-merge-day-slots!
                                             (dow-span origin current))))
                                ;; Move: target day already updated live, just
                                ;; merge that day to absorb overlaps.
                                ((and slot (eq? mode 'move))
                                 (cal-merge-day-slots!
                                  (alist-ref slot 'day 0)))
                                ;; Resize: merge the slot's day in case the
                                ;; new extent overlaps a neighbour.
                                ((and slot (or (eq? mode 'resize-top)
                                               (eq? mode 'resize-bot)
                                               (eq? mode 'create)))
                                 (cal-merge-day-slots!
                                  (alist-ref slot 'day 0))))
                               (set! *cal-avail-drag* #f)
                               (push-availability!)
                               (refresh!))))
     #:on-record-effort
       (if (and *cal-selected-event*
                (alist-ref *cal-selected-event* 'vf-process-id #f))
           (lambda (e)
             (let* ((qty-el (get-element-by-id "cal-effort-qty"))
                    (qty (if qty-el (safe-string->number (element-value qty-el)) 1))
                    (evt-id (alist-ref *cal-selected-event* 'id ""))
                    (src (alist-ref *cal-selected-event* 'source 'event)))
               (cond
                 ;; Derived commitment — record a real EconomicEvent via
                 ;; the planner. observer.record-event will advance the
                 ;; commitment's fulfillment-state, and the next snapshot
                 ;; will reflect it.
                 ((eq? src 'commitment)
                  (planner-record-effort! evt-id qty))
                 ;; Derived intent — recording effort doesn't apply
                 ((eq? src 'intent) #f)
                 ;; User-created event — local mutation
                 (else
                  (let* ((old-fulfilled (alist-ref *cal-selected-event*
                                                   'vf-fulfilled-qty 0))
                         (new-fulfilled (+ old-fulfilled qty)))
                    (set! *cal-user-events*
                          (map (lambda (ev)
                                 (if (equal? (alist-ref ev 'id) evt-id)
                                     (let ((with-fulf (alist-set ev 'vf-fulfilled-qty
                                                                    new-fulfilled)))
                                       (if (eq? (alist-ref with-fulf 'status 'open) 'open)
                                           (alist-set with-fulf 'status 'committed)
                                           with-fulf))
                                     ev))
                               *cal-user-events*))
                    (set! *cal-selected-event*
                          (%find (lambda (ev) (equal? (alist-ref ev 'id) evt-id))
                                 *cal-user-events*))
                    (save-calendar!)
                    (refresh!))))))
           #f)
     #:stop-prop (lambda (e) (stop-propagation! e))
     #:on-export (lambda (e)
                   ;; Export all events (derived + user) as .ics file
                   (download-file
                    (events->vcalendar (all-cal-events) #:name "playnet calendar")
                    "playnet-calendar.ics"
                    "text/calendar"))
     ;; Scope, plan, and acting-as come in as read-only context (the
     ;; selectors live at the session level above the view).
     #:current-scope *active-scope*
     #:current-plan *active-plan*
     #:current-acting-as *acting-as*
     ;; ── Accept / decline suggested assignment ──
     #:on-accept-assignment
       (lambda (arg)
         (set! *cal-selected-intent* #f)
         (set! *cal-selected-event* #f)
         (planner-accept! (alist-ref arg 'id "")))
     #:on-decline-assignment
       (lambda (arg)
         (set! *cal-selected-intent* #f)
         (set! *cal-selected-event* #f)
         (planner-reject! arg))
     ;; ── Offer-side: express / withdraw willingness for a need ──
     #:on-express-willingness
       (lambda (intent willing?)
         (planner-express-willingness! intent willing?)))))

;;; ── Identity (KERI) view ───────────────────────────────────────────────────

;; Browser-resident-Signify creation: HKDF the bran into a keypair,
;; build a toad=0 ICP, sign it, and ship {aid, icp, sigs} to the lobby
;; via signup-with-icp. Private keys never leave this browser.
(define (do-keri-create! name email bran)
  (cond
   ((or (not name) (string=? "" name))
    (set! *keri-error* "username is required") (refresh!))
   ((or (not email) (string=? "" email))
    (set! *keri-error* "email is required") (refresh!))
   ((or (not bran) (< (string-length bran) 21))
    (set! *keri-error* "passcode must be at least 21 characters") (refresh!))
   ((not *lobby*)
    (set! *keri-error* "not connected to gateway") (refresh!))
   (else
    (set! *keri-creating?* #t)
    (set! *keri-error* #f)
    (refresh!)
    ;; All crypto is sync (noble libs through Hoot FFI), so this runs
    ;; inline without a setTimeout. We wrap in catch in case the FFI
    ;; bridge isn't loaded.
    (let ((kp-result
           (with-exception-handler
             (lambda (exn) (list 'error (format #f "~a" exn)))
             (lambda ()
               (let* ((kp  (bran->signing-keypair bran))
                      (nkp (bran->next-keypair bran))
                      (kq  (public-key->aid-prefix
                            (ed25519-keypair-public kp)))
                      (nq  (next-key-digest
                            (ed25519-keypair-public nkp)))
                      (ret-seed (bran->reticulum-seed bran kq))
                      (_   (ret-load-from-seed
                            (bytevector->uint8array ret-seed)))
                      (ret-pub (ret-public-key-hex))
                      (anchors (if (and (string? ret-pub)
                                        (> (string-length ret-pub) 0))
                                   (list (list (cons "playnet-reticulum-pub"
                                                     ret-pub)))
                                   '())))
                 (call-with-values
                  (lambda () (build-icp #:keys (list kq) #:nkeys (list nq)
                                        #:anchors anchors))
                  (lambda (icp-json _said icp-alist)
                    (let ((sigs (vector (sign-event icp-json kp)))
                          ;; THE AID is the icp's saidified `i` (E-prefix)
                          ;; — the identifier resolvers key their KEL and
                          ;; location dbs by. kq (the inception KEY) goes
                          ;; stale on the first rotation; it only seeds
                          ;; the reticulum identity and the unlock check.
                          (aid  (assoc-ref icp-alist "i"))
                          ;; OKEA endpoint replies: endorse /end/role/add +
                          ;; /loc/scheme with the fresh key (the only moment
                          ;; it is in hand) so the gateway's /oobi/{aid}
                          ;; advertises WHERE this AID is reachable
                          ;; (OOBI §3.4) — the gateway origin we are
                          ;; connected to is exactly that URL. The mesh
                          ;; endpoint rides along as a second /loc/scheme
                          ;; (scheme "reticulum", destination hash as URL):
                          ;; the icp anchors the reticulum PUBKEY; this
                          ;; advertises WHERE on the mesh — both through
                          ;; one BADA-verified channel.
                          (replies
                           (list->vector
                            (oobi-endpoint-replies-for-icp
                             icp-alist
                             (string-append (get-location-origin) "/")
                             kp (time-iso-now)
                             #:extra-locs (reticulum-extra-locs)))))
                      (list 'ok aid kp icp-alist sigs replies))))))
             #:unwind? #t)))
      (cond
       ((eq? 'error (car kp-result))
        (set! *keri-creating?* #f)
        (set! *keri-error* (cadr kp-result))
        (refresh!))
       (else
        ;; Stash the secrets in memory, then send signup-with-icp.
        (let ((aid       (list-ref kp-result 1))
              (kp        (list-ref kp-result 2))
              (icp-alist (list-ref kp-result 3))
              (sigs      (list-ref kp-result 4))
              (replies   (list-ref kp-result 5)))
          (set! *keri-secret* kp)
          (set! *keri-bran* bran)
          (set! *keri-icp-alist* icp-alist)
          (set! *keri-sigs* sigs)
          (set! *keri-rotation-sn* 0)
          (with-vat *ocapn-vat*
            (on (<- *lobby* 'signup-with-icp name email aid icp-alist sigs)
                (lambda (result)
                  (set! *keri-creating?* #f)
                  (cond
                   ((eq? 'ok result)
                    (set! *keri-identity*
                          `((name . ,name)
                            (email . ,email)
                            (prefix . ,aid)
                            (k0 . ,(event-first-key icp-alist))
                            (status . "active")
                            (witnesses-confirmed . 0)
                            (witnesses-total . 0)
                            (last-rotation . "never")
                            (next-key-ready . #t)))
                    (save-keri-identity-hint! aid name email
                                              (event-first-key icp-alist))
                    ;; Follow-up: ship the endorsed endpoint replies so the
                    ;; served OOBI carries them (validated server-side
                    ;; against this AID's key in signup-agent).
                    (on (<- *lobby* 'register-oobi-replies aid replies)
                        (lambda (rrv)
                          (when (eq? 'ok rrv)
                            (log-append!
                             `(span (@ (class "result-text"))
                                    "[keri] OOBI endpoint replies registered\n")))))
                    (set! *keri-bran-reveal* bran)
                    (set! *keri-error* #f)
                    (log-append!
                     `(span (@ (class "result-text"))
                            ,(string-append "[keri] registered AID "
                                            aid "\n"))))
                   (else
                    (set! *keri-error*
                          (string-append "signup failed: "
                                         (if (pair? result)
                                             (cadr result)
                                             "unknown error")))))
                  (refresh!))
                #:catch
                (lambda (err)
                  (set! *keri-creating?* #f)
                  (set! *keri-error*
                        (string-append "signup error: "
                                       (call-with-output-string
                                         (lambda (p) (write err p)))))
                  (refresh!)))))))))))

;; Unlock a stored identity: re-derive the keypair from the passcode
;; and verify its pubkey matches the AID prefix in the hint. If it
;; doesn't match, the bran is wrong (or the hint is corrupt) — surface
;; an error and don't pollute *keri-secret*.
(define (reticulum-extra-locs)
  "The mesh endpoints as an OKEA #:extra-locs alist — the OCapN
   destination (\"reticulum\" . \"reticulum://<dest>\") and the
   store-and-forward mail destination (\"lxmf\" . \"lxmf://<dest>\"),
   both on the ONE bound identity — when the rns-wasm module has one;
   '() otherwise. Framed after the http pair: keripy resolvers
   whitelist tcp/http/https and drop these per-message; playnet
   resolvers verify EVERY advertised destination against the
   KEL-anchored pubkey."
  (with-exception-handler
    (lambda (_exn) '())
    (lambda ()
      (let ((dest (ret-dest-hash-hex))
            (mail (ret-lxmf-dest-hash-hex)))
        (append
         (if (and (string? dest) (positive? (string-length dest)))
             (list (cons "reticulum" (string-append "reticulum://" dest)))
             '())
         (if (and (string? mail) (positive? (string-length mail)))
             (list (cons "lxmf" (string-append "lxmf://" mail)))
             '()))))
    #:unwind? #t))

(define (bind-reticulum-identity! bran k0)
  "Derive a persona-bound Reticulum identity from the KERI bran + the
   inception key K0 and load it into the rns-wasm module, replacing the
   anonymous one. K0 (not the E-AID) labels the seed: it is re-derivable
   from the bran, stable across rotations, and keeps continuity with
   identities created before the E-AID registration handle."
  (when (and (not (zero? (ret-has-identity?)))
             (string? bran) (string? k0))
    (ret-load-from-seed
     (bytevector->uint8array (bran->reticulum-seed bran k0)))))

;;; ── Encrypted server-side backup ────────────────────────────────────────
;;;
;;; The gateway persists a per-AID copy of our credentials so they survive a
;;; browser clear (see `sync-credentials`). That copy used to be PLAINTEXT on
;;; the gateway's disk — the full credential set, including the personhood
;;; attestation and the signed relationship graph, with no erasure path.
;;;
;;; We encrypt it here, before it ever reaches the wire, so the gateway holds
;;; a blob it cannot read on any transport. Note this is NOT transport
;;; security: the session runs over the websocket netlayer and the gateway is
;;; the intended RECIPIENT, so link encryption would hand it the plaintext by
;;; design. The point is what sits on its disk afterwards.
;;;
;;; The key is derived from the BRAN by HKDF under its own info-string, so
;;; the blob is recoverable from bran + AID and from nothing else — no
;;; second, weaker recovery path, and independent of signing-key rotation.
;;;
;;; Cipher is AES-256-GCM via WebCrypto (the `vault` FFI group in repl.js).
;;; Two alternatives were rejected:
;;;   • Reticulum's identity crypto — works, but ties the backup to
;;;     rns-wasm having loaded. Where the mesh module is unavailable the
;;;     backup would silently go stale.
;;;   • The HKDF-keystream construction used by `do-keri-download-backup!`
;;;     — fine for a 21-char bran, but `hkdf-expand` hard-errors above
;;;     255*32 = 8160 bytes, and a credential set can exceed that. HKDF is
;;;     used here for the KEY only, where 32 bytes is never near the cap.
;;;
;;; WebCrypto's encrypt/decrypt are async and Hoot cannot await, so the
;;; result arrives through a callback — hence the CPS shape.
;;;
;;; Serialisation reuses the write/read round-trip already proven by the
;;; localStorage path (`save-keri-credentials!` / `load-keri-credentials!`).

(define-foreign vault-seal
  "vault" "seal" (ref extern) (ref extern) (ref extern) -> none)
(define-foreign vault-open
  "vault" "open" (ref extern) (ref extern) (ref extern) -> none)

(define (blob-key)
  "The AES key for the at-rest backup, or #f when locked (no bran in
   memory means nothing to derive from — we do not fall back to
   plaintext). The derivation itself lives beside its siblings in
   (playnet keri signify-portable), where it is portable and testable —
   see tests/keri/test-bran-derivations.scm."
  (and (string? *keri-bran*) (bran->blob-key *keri-bran*)))

(define (encrypt-blob datum k)
  "Serialise DATUM, encrypt under the derived key, and call K with the
   ciphertext bytevector — or with #f when locked or on failure."
  (let ((key (blob-key)))
    (if (not key)
        (k #f)
        (let ((text (call-with-output-string (lambda (p) (write datum p)))))
          (vault-seal
           (bytevector->uint8array key)
           (bytevector->uint8array (string->utf8 text))
           (procedure->external
            (lambda (out)
              (let ((bv (uint8array->bytevector out)))
                (k (and (positive? (bytevector-length bv)) bv))))))))))

(define (decrypt-blob payload k)
  "Inverse of `encrypt-blob`; calls K with the datum or #f. A plain list
   is passed through unchanged — server copies written before this change
   are unencrypted, so an existing backup still loads."
  (let ((key (blob-key)))
    (cond
     ((list? payload) (k payload))          ; legacy plaintext backup
     ((or (not (bytevector? payload)) (not key)) (k #f))
     (else
      (vault-open
       (bytevector->uint8array key)
       (bytevector->uint8array payload)
       (procedure->external
        (lambda (out)
          (let ((bv (uint8array->bytevector out)))
            (k (and (positive? (bytevector-length bv))
                    (with-exception-handler
                      (lambda (_exn) #f)
                      (lambda () (read (open-input-string (utf8->string bv))))
                      #:unwind? #t)))))))))))

(define (do-keri-unlock! bran)
  (cond
   ((or (not bran) (< (string-length bran) 21))
    (set! *keri-error* "passcode must be at least 21 characters") (refresh!))
   ((not *keri-identity*)
    (set! *keri-error* "no stored identity to unlock") (refresh!))
   (else
    (set! *keri-unlocking?* #t)
    (set! *keri-error* #f)
    (refresh!)
    (let ((result
           (with-exception-handler
             (lambda (exn) (list 'error (format #f "~a" exn)))
             (lambda ()
               (let* ((kp  (bran->signing-keypair bran))
                      (aid (public-key->aid-prefix
                            (ed25519-keypair-public kp))))
                 (list 'ok kp aid)))
             #:unwind? #t)))
      (set! *keri-unlocking?* #f)
      (cond
       ((eq? 'error (car result))
        (set! *keri-error* (cadr result))
        (refresh!))
       (else
        (let* ((kp           (list-ref result 1))
               (derived-k0   (list-ref result 2))
               (stored-aid   (assq-ref *keri-identity* 'prefix))
               ;; The hint's k0 is what the bran re-derives; the E-AID
               ;; prefix is a SAID over the whole icp and can't be
               ;; recomputed from the bran alone. Legacy hints have no
               ;; k0 field — there the prefix WAS the inception key.
               (stored-k0    (or (assq-ref *keri-identity* 'k0)
                                 stored-aid)))
          (cond
           ((not (equal? derived-k0 stored-k0))
            (set! *keri-error* "wrong passcode for this identity")
            (refresh!))
           (else
            (set! *keri-secret* kp)
            (set! *keri-bran* bran)
            ;; Reticulum seed binds to bran+k0 (both stable across
            ;; rotations; k0 keeps continuity with identities created
            ;; before the E-AID handle).
            (bind-reticulum-identity! bran derived-k0)
            ;; Fetch the server's record so we know the rotation level.
            (when *lobby*
              (with-vat *ocapn-vat*
                (on (<- *lobby* 'fetch-icp stored-aid)
                    (lambda (entry-raw)
                      (let ((entry (denormalize-syrup entry-raw)))
                       (when (pair? entry)
                        (let ((rots (assq-ref entry 'rotations)))
                          (set! *keri-rotation-sn*
                                (if (pair? rots) (length rots) 0))
                          (set! *keri-icp-alist* (assq-ref entry 'icp))
                          ;; If a rotation has happened, derive the
                          ;; current signing key (which is rotation-sn
                          ;; deep into the chain).
                          (when (positive? *keri-rotation-sn*)
                            (set! *keri-secret*
                                  (bran->rotation-keypair
                                   bran *keri-rotation-sn*)))))))
                    #:catch (lambda (_) #f))))
            (set! *keri-identity*
                  (map (lambda (p)
                         (if (eq? 'status (car p)) (cons 'status "active") p))
                       *keri-identity*))
            (refresh!))))))))))

;; Auth round-trip: ask the lobby for a nonce, sign it, post back.
;; Promotes status to "authenticated" on success.
(define (do-keri-authenticate!)
  (cond
   ((not *keri-secret*)
    (set! *keri-error* "unlock the identity first") (refresh!))
   ((not *lobby*)
    (set! *keri-error* "not connected to gateway") (refresh!))
   (else
    (let ((aid (assq-ref *keri-identity* 'prefix))
          (kp  *keri-secret*))
      (set! *keri-authenticating?* #t)
      (set! *keri-error* #f)
      (refresh!)
      (with-vat *ocapn-vat*
        (on (<- *lobby* 'keri-challenge aid)
            (lambda (nonce)
              (cond
               ((not (string? nonce))
                (set! *keri-authenticating?* #f)
                (set! *keri-error* "no nonce returned from gateway")
                (refresh!))
               (else
                (let* ((sig-bv  (sign-bytes (string->utf8 nonce) kp))
                       (sig-q64 (cesr-bytes->qb64 "0B" sig-bv)))
                  (with-vat *ocapn-vat*
                    (on (<- *lobby* 'keri-authenticate aid sig-q64 nonce)
                        (lambda (result)
                          (set! *keri-authenticating?* #f)
                          (cond
                           ;; Success now returns (list 'ok session-cap).
                           ;; The session cap is bound server-side to this
                           ;; AID — we stash it for all subsequent
                           ;; privileged calls (rotate-aid, list-credentials,
                           ;; governance methods, etc.).
                           ((and (pair? result) (eq? 'ok (car result)))
                            (set! *keri-session* (cadr result))
                            (set! *keri-identity*
                                  (map (lambda (p)
                                         (if (eq? 'status (car p))
                                             (cons 'status "authenticated")
                                             p))
                                       *keri-identity*))
                            (log-append!
                             `(span (@ (class "result-text"))
                                    ,(string-append "[keri] authenticated as "
                                                    aid "\n")))
                            ;; Auto-close the dropdown on success.
                            (set! *identity-dropdown-open?* #f)
                            ;; Pull credentials + contacts (initial sync).
                            (do-keri-fetch-credentials!)
                            (do-keri-pull-contacts!)
                            ;; Register for push updates (deltas only after this).
                            (do-keri-watch-credentials!)
                            ;; Relay-announce: ship a freshly-signed
                            ;; announce so the gateway can broadcast
                            ;; this persona's mesh destination while
                            ;; the session is alive.
                            (do-keri-relay-announce!))
                           (else
                            (set! *keri-error*
                                  (string-append "auth failed: result="
                                                 (call-with-output-string
                                                  (lambda (p) (write result p)))))))
                          (refresh!))
                        #:catch
                        (lambda (err)
                          (set! *keri-authenticating?* #f)
                          (set! *keri-error*
                                (format #f "auth error: ~a" err))
                          (refresh!))))))))
            #:catch
            (lambda (err)
              (set! *keri-authenticating?* #f)
              (set! *keri-error*
                    (format #f "challenge error: ~a" err))
              (refresh!))))))))

;; Rotation: derive the next signing keypair from the in-memory bran,
;; build a rot event referencing the prior SAID, sign with the new
;; key (the one being revealed), post to the gateway. On success,
;; advance *keri-secret* and *keri-rotation-sn*.
(define (do-keri-rotate!)
  (cond
   ((not *keri-secret*)
    (set! *keri-error* "unlock the identity first") (refresh!))
   ((not *keri-bran*)
    (set! *keri-error* "passcode not in memory — unlock again") (refresh!))
   ((not *lobby*)
    (set! *keri-error* "not connected to gateway") (refresh!))
   (else
    (let ((aid (assq-ref *keri-identity* 'prefix)))
      (set! *keri-rotating?* #t)
      (set! *keri-error* #f)
      (refresh!)
      (with-vat *ocapn-vat*
        (on (<- *lobby* 'fetch-icp aid)
            (lambda (entry)
              (cond
               ((not (pair? entry))
                (set! *keri-rotating?* #f)
                (set! *keri-error* "AID not found on server")
                (refresh!))
               (else
                (do-keri-rotate-with-entry! aid entry))))
            #:catch
            (lambda (err)
              (set! *keri-rotating?* #f)
              (set! *keri-error* (format #f "fetch-icp error: ~a" err))
              (refresh!))))))))

;; Server values arrive with conses/vectors wrapped as syrup tagged
;; records. Walk the value tree, turning <tagged 'pair (a b)> back
;; into (cons a b) and <tagged 'vec data> back into a Scheme vector.
(define (denormalize-syrup x)
  (cond
   ((and (tagged? x) (eq? 'pair (tagged-label x)))
    (let ((d (tagged-data x)))
      (cons (denormalize-syrup (car d))
            (denormalize-syrup (cadr d)))))
   ((and (tagged? x) (eq? 'vec (tagged-label x)))
    (list->vector (map denormalize-syrup (tagged-data x))))
   ((pair? x)
    (cons (denormalize-syrup (car x)) (denormalize-syrup (cdr x))))
   ((vector? x)
    (list->vector (map denormalize-syrup (vector->list x))))
   (else x)))

;; The controller keeps what it writes: the dial's spine holds this
;; identity's KEL under pn.id.kel (ordered JSON — see
;; hoot/day-boot.scm "the KEL"), and a rotation made here is an event in
;; that log. Append it when the stored log is this AID's; a browser whose
;; log is elsewhere or absent has nothing to extend, and its next unlock
;; fetches the entry from the gateway once and keeps it from then on.
(define (kel-note-rotation! aid rot-alist sigs)
  (let ((raw (ls-get-item "pn.id.kel")))
    (when (and (string? raw) (positive? (string-length raw)))
      (with-exception-handler
       (lambda (_) #f)
       (lambda ()
         (let* ((kel  (json-read-ordered raw))
                (icp  (assoc-ref kel "icp"))
                (rots (assoc-ref kel "rotations")))
           (when (and (pair? icp) (equal? (assoc-ref icp "i") aid) (vector? rots))
             (ls-set-item
              "pn.id.kel"
              (scm->json-canonical
               (map (lambda (p)
                      (if (equal? (car p) "rotations")
                          (cons "rotations"
                                (list->vector
                                 (append (vector->list rots)
                                         (list `(("rot" . ,rot-alist) ("sigs" . ,sigs))))))
                          p))
                    kel))))))
       #:unwind? #t))))

(define (do-keri-rotate-with-entry! aid entry-raw)
  ;; Server tells us where in the rotation chain we are. Compute the
  ;; next sn, derive new signing + new next, build, sign, post.
  (let* ((entry (denormalize-syrup entry-raw))
         (rots (or (assq-ref entry 'rotations) '()))
         (current-sn (length rots))      ;; how many rots already exist
         (next-sn    (+ 1 current-sn))   ;; sn of the rot we're about to write
         (prior      (if (pair? rots)
                         (car (car (reverse rots)))
                         (assq-ref entry 'icp)))
         (prior-said (assoc-ref prior "d"))
         (bran       *keri-bran*)
         ;; The new signing key was committed in the previous event's `n`.
         ;; In our chain that key is bran->rotation-keypair(sn=next-sn).
         (new-kp     (bran->rotation-keypair bran next-sn))
         ;; And the *next* next-key is one further on.
         (new-nkp    (bran->rotation-keypair bran (+ next-sn 1)))
         (kq         (public-key->aid-prefix
                      (ed25519-keypair-public new-kp)))
         (nq         (next-key-digest
                      (ed25519-keypair-public new-nkp)))
         ;; Retrofit the AID↔mesh binding for personas that predate the
         ;; playnet-reticulum-pub anchor: if no event in the KEL carries
         ;; it yet, seal the pubkey into THIS rotation — verifiers read
         ;; the latest anchor across the KEL, so the binding (and mesh
         ;; /loc/scheme verification) lights up from here on.
         (kel        (cons (assq-ref entry 'icp) (map car rots)))
         (ret-pub    (with-exception-handler
                       (lambda (_exn) "")
                       (lambda () (ret-public-key-hex))
                       #:unwind? #t))
         (anchors    (if (and (not (kel-reticulum-pub kel))
                              (string? ret-pub)
                              (= 128 (string-length ret-pub)))
                         `((("playnet-reticulum-pub" . ,ret-pub)))
                         '())))
    (call-with-values
     (lambda ()
       (build-rot aid prior-said
                  #:keys (list kq) #:nkeys (list nq) #:sn next-sn
                  #:anchors anchors))
     (lambda (rot-json _rot-said rot-alist)
       (let ((sigs (vector (sign-event rot-json new-kp))))
         ;; Rotation requires an authenticated session — the cap is
         ;; bound to this AID, so the server doesn't need to trust an
         ;; aid parameter from the wire.
         (cond
          ((not *keri-session*)
           (set! *keri-rotating?* #f)
           (set! *keri-error* "authenticate first (rotation requires a session)")
           (refresh!))
          (else
           (with-vat *ocapn-vat*
             (on (<- *keri-session* 'rotate-aid rot-alist sigs)
                 (lambda (result)
                   (set! *keri-rotating?* #f)
                   (cond
                    ((eq? 'ok result)
                     (kel-note-rotation! aid rot-alist sigs)
                     ;; Promote the new keypair into our session.
                     ;; Rotation invalidates the prior signing key the
                     ;; session was anchored to, so we drop the cap
                     ;; and force re-authentication on the next
                     ;; privileged action.
                     (set! *keri-secret* new-kp)
                     (set! *keri-rotation-sn* next-sn)
                     (set! *keri-session* #f)
                     (set! *keri-identity*
                           (map (lambda (p)
                                  (cond
                                   ((eq? 'last-rotation (car p))
                                    (cons 'last-rotation
                                          (string-append "sn=" (number->string
                                                                next-sn))))
                                   ;; Demote status; re-auth needed.
                                   ((eq? 'status (car p))
                                    (cons 'status "active"))
                                   (else p)))
                                *keri-identity*))
                     (set! *keri-error* #f)
                     (log-append!
                      `(span (@ (class "result-text"))
                             ,(string-append "[keri] rotated to sn="
                                             (number->string next-sn) "\n")))
                     ;; The key state moved, so the endpoint authorization
                     ;; must move with it: re-ship the OKEA replies endorsed
                     ;; with the rotated-TO key, referencing the rot as the
                     ;; establishment event. The server verifies them under
                     ;; the AID's current key (which is now new-kp).
                     (let ((rot-replies
                            (list->vector
                             (oobi-endpoint-replies-for-rot
                              rot-alist
                              (string-append (get-location-origin) "/")
                              new-kp (time-iso-now)
                              #:extra-locs (reticulum-extra-locs)))))
                       (on (<- *lobby* 'register-oobi-replies aid rot-replies)
                           (lambda (rrv)
                             (when (eq? 'ok rrv)
                               (log-append!
                                `(span (@ (class "result-text"))
                                       "[keri] OOBI endpoint replies re-endorsed\n")))))))
                    (else
                     (set! *keri-error*
                           (string-append "rotation failed: "
                                          (if (pair? result)
                                              (cadr result)
                                              "unknown")))))
                   (refresh!))
                 #:catch
                 (lambda (err)
                   (set! *keri-rotating?* #f)
                   (set! *keri-error* (format #f "rotate error: ~a" err))
                   (refresh!)))))))))))

;; Cross-device recovery: user types AID (the E-prefix the server keys
;; by) + bran. Fetch the server's stored ICP for that AID, then verify
;; the bran is right by comparing the bran-derived inception key against
;; the fetched icp.k[0] — the E-AID itself is a SAID over the whole icp
;; and can't be re-derived locally before the fetch. Persist a hint,
;; mark active.

(define (keri-recover-finish! typed-aid bran kp entry-raw)
  ;; ENTRY is the alist from lobby 'fetch-icp. Cross-Hoot syrup
  ;; encodes conses as <tagged 'pair> and vectors as <tagged 'vec>,
  ;; so normalize before assq-ref / vector? touch the data.
  (let* ((entry (denormalize-syrup entry-raw))
         (icp (assq-ref entry 'icp))
         (k   (assoc-ref icp "k"))
         (k0  (cond ((vector? k) (and (positive? (vector-length k))
                                      (vector-ref k 0)))
                    (else #f)))
         (derived-k0 (public-key->aid-prefix (ed25519-keypair-public kp)))
         (rots (or (assq-ref entry 'rotations) '()))
         (sn   (if (pair? rots) (length rots) 0)))
    (cond
     ((not (equal? k0 derived-k0))
      (set! *keri-error*
            "wrong passcode for this AID (derived key does not match its ICP)"))
     (else
      ;; If rotation has happened, advance to the current signing key.
      (set! *keri-secret*
            (if (positive? sn)
                (bran->rotation-keypair bran sn)
                kp))
      (set! *keri-bran* bran)
      (set! *keri-icp-alist* icp)
      (set! *keri-rotation-sn* sn)
      (bind-reticulum-identity! bran k0)
      (set! *keri-identity*
            `((name   . "recovered")
              (email  . "")
              (prefix . ,typed-aid)
              (k0     . ,k0)
              (status . "active")
              (witnesses-confirmed . 0)
              (witnesses-total . 0)
              (last-rotation
               . ,(if (positive? sn)
                      (string-append "sn=" (number->string sn))
                      "never"))
              (next-key-ready . #t)))
      (save-keri-identity-hint! typed-aid "recovered" "" k0)
      (set! *keri-recover-mode?* #f)
      (log-append!
       `(span (@ (class "result-text"))
              ,(string-append "[keri] recovered AID " typed-aid "\n")))))))

(define (do-keri-recover! typed-aid bran)
  (cond
   ((or (not typed-aid) (< (string-length typed-aid) 44))
    (set! *keri-error* "AID must be 44+ chars (E… prefix)")
    (refresh!))
   ((or (not bran) (< (string-length bran) 21))
    (set! *keri-error* "passcode must be at least 21 characters")
    (refresh!))
   ((not *lobby*)
    (set! *keri-error* "not connected to gateway")
    (refresh!))
   (else
    (set! *keri-recovering?* #t)
    (set! *keri-error* #f)
    (refresh!)
    (let ((kp-result
           (with-exception-handler
             (lambda (exn) (list 'error (format #f "~a" exn)))
             (lambda () (list 'ok (bran->signing-keypair bran)))
             #:unwind? #t)))
      (cond
       ((eq? 'error (car kp-result))
        (set! *keri-recovering?* #f)
        (set! *keri-error* (cadr kp-result))
        (refresh!))
       (else
        ;; The bran check happens AFTER the fetch (keri-recover-finish!
        ;; compares the derived key against the fetched icp.k[0]) — the
        ;; E-AID is a SAID and can't be re-derived from the bran alone.
        (let ((kp (list-ref kp-result 1)))
          (with-vat *ocapn-vat*
            (on (<- *lobby* 'fetch-icp typed-aid)
                (lambda (entry)
                  (set! *keri-recovering?* #f)
                  (cond
                   ((not (pair? entry))
                    (set! *keri-error* "AID not registered on this server"))
                   (else
                    (keri-recover-finish! typed-aid bran kp entry)))
                  (refresh!))
                #:catch
                (lambda (err)
                  (set! *keri-recovering?* #f)
                  (set! *keri-error*
                        (format #f "fetch-icp error: ~a" err))
                  (refresh!)))))))))))

;; Fetch credentials from server, merge with local cache, persist both.
;; Local-first: on error (offline), keeps local credentials as-is.
(define (apply-fetched-credentials! backup-creds server-creds)
  "Union the fetched credential lists into *keri-credentials* by SAID, persist
   locally, and re-push the (encrypted) backup. BACKUP-CREDS is our own
   zero-knowledge backup (restore-of-record); SERVER-CREDS is the gateway's
   by-holder holdings (what it issued or witnesses)."
  (set! *keri-creds-loading?* #f)
  (let* ((m1     (merge-credentials *keri-credentials*
                                    (if (list? backup-creds) backup-creds '())))
         (merged (merge-credentials m1
                                    (if (list? server-creds) server-creds '()))))
    (set! *keri-credentials* merged)
    (save-keri-credentials!)
    (do-keri-push-credentials!)
    (refresh!)))

(define (do-keri-fetch-credentials!)
  (when (and *keri-session* *keri-identity*)
    (set! *keri-creds-loading?* #t)
    (refresh!)
    (with-vat *ocapn-vat*
      ;; The restore-of-record is OUR encrypted, zero-knowledge backup:
      ;; list-credential-backups → decrypt-blob (which also passes a legacy
      ;; plaintext list through, so pre-encryption backups still load, and an
      ;; absent backup decrypts to '()). Then union in list-credentials — the
      ;; gateway's OWN by-holder holdings — so server-issued creds are kept and
      ;; a truly-fresh account still seeds from the server. Before this, the
      ;; fetch read only list-credentials and the encrypted backup was written
      ;; but never read back — a one-way archive that defeated the encryption.
      (on (<- *keri-session* 'list-credential-backups)
          (lambda (backup-payload)
            (decrypt-blob
             backup-payload
             (lambda (backup-creds)
               (on (<- *keri-session* 'list-credentials)
                   (lambda (server-creds)
                     (apply-fetched-credentials! backup-creds server-creds))
                   #:catch
                   (lambda (_)
                     (apply-fetched-credentials! backup-creds '()))))))
          #:catch
          (lambda (_)
            (set! *keri-creds-loading?* #f)
            (refresh!))))))

(define (do-keri-pull-contacts!)
  (when *keri-session*
    (with-vat *ocapn-vat*
      (on (<- *keri-session* 'list-contacts)
          (lambda (server-contacts)
            (when (and (list? server-contacts) (pair? server-contacts))
              (set! *keri-contacts* server-contacts)
              (save-keri-contacts!)
              (refresh!)))
          #:catch (lambda (_) #f)))))

(define (do-keri-push-contacts!)
  (when *keri-session*
    (with-vat *ocapn-vat*
      (on (<- *keri-session* 'sync-contacts *keri-contacts*)
          (lambda (_) #f)
          #:catch (lambda (_) #f)))))

(define (do-keri-push-credentials!)
  (when *keri-session*
    ;; The key comes from the bran, which is in memory whenever the user is
    ;; unlocked — and every path that reaches here went through unlock to
    ;; get a session. Locked (or a seal failure) means no push rather than
    ;; a plaintext push: sending it in the clear would re-create the very
    ;; exposure this exists to close. Local credentials are unaffected
    ;; either way — `save-keri-credentials!` still writes localStorage.
    (encrypt-blob
     *keri-credentials*
     (lambda (blob)
       (if (not blob)
           (mesh-log! "credential backup skipped — locked, nothing to encrypt with")
           (with-vat *ocapn-vat*
             (on (<- *keri-session* 'sync-credentials blob)
                 (lambda (_) #f)
                 #:catch (lambda (_) #f))))))))

;; Relay-announce: the browser signs the announce (only it holds the
;; persona's identity key); the gateway verifies it against the
;; KEL-anchored pubkey and broadcasts it on the mesh. Best-effort —
;; gateways without a reticulum netlayer decline and we stay quiet.
(define (mesh-log! text)
  (log-append! `(span (@ (class "result-text")) ,(string-append text "\n"))))

(define (do-keri-relay-announce!)
  ;; Both destinations of the one identity: OCapN traffic + LXMF mail.
  (when *keri-session*
    (for-each
     (lambda (label pkt)
       (when (and (string? pkt) (positive? (string-length pkt)))
         (with-vat *ocapn-vat*
           (on (<- *keri-session* 'relay-announce! pkt)
               (lambda (rv)
                 (when (eq? 'ok rv)
                   (mesh-log! (string-append "[reticulum] " label
                                             " announce relayed"))))
               #:catch (lambda (_e) #f)))))
     '("ocapn" "lxmf")
     (with-exception-handler
       (lambda (_exn) '("" ""))
       (lambda () (list (ret-pack-announce-hex)
                        (ret-pack-announce-hex-for "lxmf" "delivery")))
       #:unwind? #t))
    ;; And collect anything the mesh left for us while we were away.
    (do-keri-drain-mesh!)))

;; Inbound mesh mail. Deliveries are ciphertext only this browser can
;; open (the gateway never could): decrypt, parse the LXMF fields, and
;; attribute the sender by deriving each verified contact's
;; lxmf.delivery destination from their binding-verified pub — a match
;; lets us verify the message SIGNATURE under that pub too. Verified
;; mail toasts; unattributed mail is shown but marked.
(define (lxmf-sender-of source-hex)
  "The contact alist whose verified pub derives SOURCE-HEX as its
   lxmf.delivery destination, or #f."
  (let loop ((cs *keri-contacts*))
    (and (pair? cs)
         (let* ((prefix (or (assq-ref (car cs) 'prefix) ""))
                (mesh   (contact-mesh-of prefix))
                (pub    (and (pair? mesh) (= 3 (length mesh))
                             (caddr mesh))))
           (if (and (string? pub) (= 128 (string-length pub))
                    (string=? source-hex
                               (reticulum-destination-hash
                                (hex->bv pub)
                                #:app "lxmf" #:aspects '("delivery"))))
               (car cs)
               (loop (cdr cs)))))))

(define (lxmf-receive! payload)
  (let ((plain (ret-decrypt-hex payload)))
    (if (zero? (string-length plain))
        (mesh-log! "[lxmf] delivery kept as ciphertext (decrypt failed)")
        (let* ((source  (ret-lxmf-field plain "source"))
               (title   (ret-lxmf-field plain "title"))
               (content (ret-lxmf-field plain "content"))
               (sender  (lxmf-sender-of source))
               (pub     (and sender
                             (caddr (contact-mesh-of
                                     (assq-ref sender 'prefix)))))
               (signed? (and pub (= 1 (ret-lxmf-verify-hex plain pub))))
               (from    (cond
                         (signed? (or (assq-ref sender 'alias) "contact"))
                         (sender  "contact (SIGNATURE FAILED)")
                         (else    (string-append "unknown sender " source)))))
          (mesh-log! (string-append "[lxmf] mail from " from
                                    (if (zero? (string-length title))
                                        "" (string-append ": " title))))
          (show-toast! (if signed? 'info 'warning)
                       (string-append "mesh mail — " from)
                       (if (zero? (string-length content)) title content))))))

(define (do-keri-drain-mesh!)
  (when *keri-session*
    (with-vat *ocapn-vat*
      (on (<- *keri-session* 'drain-mesh-mailbox)
          (lambda (boxes-raw)
            (for-each
             (lambda (box)
               (when (vector? (cdr box))
                 (for-each lxmf-receive! (vector->list (cdr box)))))
             (denormalize-syrup boxes-raw)))
          #:catch (lambda (_e) #f)))))

;; Which contact the mail compose form targets (#f = closed).
(define *mail-compose-to* #f)

(define (do-contact-mail-toggle! c)
  (set! *mail-compose-to*
        (if (and *mail-compose-to*
                 (equal? (assq-ref *mail-compose-to* 'prefix)
                         (assq-ref c 'prefix)))
            #f
            c))
  (refresh!))

(define (do-contact-mail-send!)
  (when *mail-compose-to*
    (let* ((title-el   (get-element-by-id "contact-mail-title"))
           (content-el (get-element-by-id "contact-mail-content"))
           (title   (if title-el   (or (element-value title-el)   "") ""))
           (content (if content-el (or (element-value content-el) "") "")))
      (do-contact-send-mail! *mail-compose-to* title content)
      (set! *mail-compose-to* #f)
      (refresh!))))

;; Outbound mesh mail: composed, signed, and encrypted HERE (the
;; gateway relays ciphertext it cannot read, gated to DATA packets).
(define (do-contact-send-mail! c title content)
  (let* ((prefix (or (assq-ref c 'prefix) ""))
         (mesh   (contact-mesh-of prefix))
         (pub    (and (pair? mesh) (= 3 (length mesh)) (caddr mesh))))
    (cond
     ((not *keri-session*)
      (mesh-log! "[lxmf] authenticate first"))
     ((or (not (string? pub)) (zero? (string-length pub)))
      (mesh-log! "[lxmf] resolve + verify the contact's mesh endpoint first"))
     (else
      (let ((pkt (ret-lxmf-pack-packet-hex pub title content)))
        (if (zero? (string-length pkt))
            (mesh-log! "[lxmf] compose failed")
            (with-vat *ocapn-vat*
              (on (<- *keri-session* 'send-mesh-packet! pkt)
                  (lambda (rv)
                    (mesh-log!
                     (if (eq? 'ok rv)
                         (string-append "[lxmf] mail sent to "
                                        (or (assq-ref c 'alias) prefix))
                         "[lxmf] send declined by gateway")))
                  #:catch
                  (lambda (_e)
                    (mesh-log! "[lxmf] send failed (gateway error)"))))))))))

(define (do-keri-watch-credentials!)
  "Register a watcher with the server so new credentials are pushed
   over the existing WebSocket. After the initial list-credentials
   pull, only deltas flow — no polling."
  (when (and *keri-session* *ocapn-vat* (not *keri-cred-watcher*))
    (with-vat *ocapn-vat*
      (let ((watcher (spawn (lambda (_bcom)
                              (methods
                               ((on-credential cred)
                                (let ((existing (map (lambda (c) (assq-ref c 'said))
                                                     *keri-credentials*)))
                                  (unless (member (assq-ref cred 'said) existing)
                                    (set! *keri-credentials*
                                          (cons cred *keri-credentials*))
                                    (save-keri-credentials!)
                                    (do-keri-push-credentials!)
                                    (notify-event!
                                     `((kind . ipex-grant)
                                       (schema . ,(or (assq-ref cred 'schema) ""))
                                       (issuer . ,(or (assq-ref cred 'issuer) ""))
                                       (said . ,(or (assq-ref cred 'said) ""))))
                                    (refresh!)))))))))
        (set! *keri-cred-watcher* watcher)
        (on (<- *keri-session* 'watch-credentials watcher)
            (lambda (_) #f)
            #:catch (lambda (_) #f))))))

(define (do-keri-export-credentials!)
  (when (and *keri-credentials* (pair? *keri-credentials*) *keri-identity*)
    (let* ((aid    (or (assq-ref *keri-identity* 'prefix) "unknown"))
           (name   (or (assq-ref *keri-identity* 'name) "unnamed"))
           (lines  (map (lambda (cred)
                          (let ((schema  (or (assq-ref cred 'schema) "?"))
                                (said    (or (assq-ref cred 'said) ""))
                                (issuer  (or (assq-ref cred 'issuer) ""))
                                (revoked (assq-ref cred 'revoked?)))
                            (string-append
                             "  {\n"
                             "    \"schema\": \"" (if (symbol? schema) (symbol->string schema) schema) "\",\n"
                             "    \"said\": \"" said "\",\n"
                             "    \"issuer\": \"" issuer "\",\n"
                             "    \"holder\": \"" aid "\",\n"
                             "    \"revoked\": " (if revoked "true" "false") "\n"
                             "  }")))
                        *keri-credentials*))
           (body   (string-append
                    "{\n"
                    "  \"holder\": \"" aid "\",\n"
                    "  \"name\": \"" name "\",\n"
                    "  \"exported\": \"" "2026-05-23" "\",\n"
                    "  \"credentials\": [\n"
                    (let join ((ls lines) (acc ""))
                      (cond ((null? ls) acc)
                            ((null? (cdr ls)) (string-append acc (car ls)))
                            (else (join (cdr ls)
                                        (string-append acc (car ls) ",\n")))))
                    "\n  ]\n"
                    "}\n"))
           (fname  (string-append "playnet-credentials-"
                                  (substring aid 0 (min 12 (string-length aid)))
                                  ".json")))
      (download-file body fname "application/json"))))

(define (do-keri-download-backup!)
  "Download an encrypted backup of the bran. The user picks a password
   which derives the encryption key via HKDF. The file can be imported
   on any device to recover the identity."
  (when (and *keri-bran* *keri-identity*)
    (let* ((aid  (or (assq-ref *keri-identity* 'prefix) "unknown"))
           (bran-bv (string->utf8 *keri-bran*))
           (password (element-value (get-element-by-id "id-bran-input"))))
      (cond
       ((or (not password) (< (string-length password) 8))
        (set! *keri-error* "enter a backup password (8+ chars) in the passcode field")
        (refresh!))
       (else
        (let* ((key-bv (hkdf #:ikm (string->utf8 password)
                             #:info (string->utf8 "playnet:backup:v1")
                             #:length 32))
               (nonce   (keri-crypto-random-bytes 24))
               (stream  (hkdf #:ikm key-bv #:salt nonce
                              #:info (string->utf8 "playnet:vault:stream")
                              #:length (bytevector-length bran-bv)))
               (mac-key (hkdf #:ikm key-bv #:salt nonce
                              #:info (string->utf8 "playnet:vault:mac")
                              #:length 32))
               (ct      (let ((out (make-bytevector (bytevector-length bran-bv))))
                          (let xor! ((i 0))
                            (when (< i (bytevector-length bran-bv))
                              (bytevector-u8-set! out i
                                (logxor (bytevector-u8-ref bran-bv i)
                                        (bytevector-u8-ref stream i)))
                              (xor! (+ i 1))))
                          out))
               (tag-in  (let ((buf (make-bytevector (+ 24 (bytevector-length ct)))))
                          (bytevector-copy! nonce 0 buf 0 24)
                          (bytevector-copy! ct 0 buf 24 (bytevector-length ct))
                          buf))
               (tag     (keri-crypto-hmac-sha256 mac-key tag-in))




               (body   (string-append
                        "(playnet-backup 1\n"
                        "  (aid   \"" aid "\")\n"
                        "  (nonce \"" (bv->hex nonce) "\")\n"
                        "  (ct    \"" (bv->hex ct) "\")\n"
                        "  (tag   \"" (bv->hex tag) "\"))\n"))
               (fname  (string-append "playnet-backup-"
                                      (substring aid 0 (min 12 (string-length aid)))
                                      ".scm")))
          (download-file body fname "application/x-scheme")
          (set! *keri-error* #f)
          (refresh!)))))))

(define (do-keri-split-shares!)
  "Split bran into Shamir shares locally and send them to the server
   for storage. Each share is addressed to a contact's AID."
  (when (and *keri-bran* *keri-identity* *keri-session*
             (pair? *keri-contacts*))
    (let* ((threshold-el (get-element-by-id "shamir-threshold-input"))
           (threshold-str (and threshold-el (element-value threshold-el)))
           (threshold (if (and threshold-str (not (string=? threshold-str "")))
                          (string->number threshold-str)
                          2))
           (n (length *keri-contacts*))
           (aid (or (assq-ref *keri-identity* 'prefix) "")))
      (cond
       ((< n 2)
        (set! *keri-error* "need at least 2 contacts for social recovery")
        (refresh!))
       ((or (not threshold) (< threshold 2) (> threshold n))
        (set! *keri-error*
              (string-append "threshold must be 2-" (number->string n)))
        (refresh!))
       (else
        (let* ((bran-bv (string->utf8 *keri-bran*))
               (shares  (shamir-split bran-bv threshold n))
               (holders (map (lambda (c) (or (assq-ref c 'prefix) ""))
                             *keri-contacts*))
               (payload (map (lambda (share holder)
                               (list (cons 'holder holder)
                                     (cons 'index (car share))
                                     (cons 'threshold (cadr share))
                                     (cons 'share (bv->hex (caddr share)))))
                             shares holders)))
          (with-vat *ocapn-vat*
            (on (<- *keri-session* 'store-shamir-shares aid threshold payload)
                (lambda (result)
                  (if (eq? 'ok result)
                      (begin
                        (set! *keri-error* #f)
                        (set! *keri-show-shamir?* #f)
                        (log-append!
                         `(span (@ (class "result-text"))
                                ,(format #f "[keri] split into ~a shares (threshold ~a)\n"
                                         n threshold))))
                      (set! *keri-error*
                            (format #f "share storage failed: ~a" result)))
                  (refresh!))
                #:catch
                (lambda (err)
                  (set! *keri-error* (format #f "shamir error: ~a" err))
                  (refresh!))))))))))

;; Body of the identity dropdown. Same SXML the old full-page tab used,
;; just rendered inside a positioned panel (see render-identity-dropdown
;; below) instead of as a top-level view.
(define (render-identity-page-body)
  (identity-page
   #:identity *keri-identity*
   #:contacts *keri-contacts*
   #:creating? *keri-creating?*
   #:connecting? *keri-connecting?*
   #:unlocking? *keri-unlocking?*
   #:authenticating? *keri-authenticating?*
   #:recovering? *keri-recovering?*
   #:recover-mode? *keri-recover-mode?*
   #:credentials *keri-credentials*
   #:creds-loading? *keri-creds-loading?*
   #:error *keri-error*
   #:bran-reveal *keri-bran-reveal*
   #:show-recovery-info? *keri-show-recovery?*
   #:on-create
     (lambda (e)
       (let ((name  (element-value (get-element-by-id "id-name-input")))
             (email (element-value (get-element-by-id "id-email-input")))
             (bran  (element-value (get-element-by-id "id-bran-input"))))
         (do-keri-create! name email bran)))
   #:on-unlock
     (lambda (e)
       (let ((bran (element-value (get-element-by-id "id-bran-input"))))
         (do-keri-unlock! bran)))
   #:on-forget
     (lambda (e)
       (clear-keri-identity!)
       (set! *keri-error* #f)
       (refresh!))
   #:on-authenticate
     (lambda (e) (do-keri-authenticate!))
   #:on-connect
     (lambda (e)
       (set! *keri-error*
             "contact-by-link not yet wired in browser-resident mode")
       (refresh!))
   #:on-rotate
     (lambda (e) (do-keri-rotate!))
   #:on-recover-toggle
     (lambda (e)
       (set! *keri-recover-mode?* (not *keri-recover-mode?*))
       (set! *keri-error* #f)
       (refresh!))
   #:on-recover
     (lambda (e)
       (let ((aid  (element-value (get-element-by-id "id-aid-input")))
             (bran (element-value (get-element-by-id "id-bran-input"))))
         (do-keri-recover! aid bran)))
   #:on-refresh-creds
     (lambda (e) (do-keri-fetch-credentials!))
   #:on-bran-dismiss
     (lambda (e)
       (set! *keri-bran-reveal* #f)
       (refresh!))
   #:on-export-creds
     (lambda (e) (do-keri-export-credentials!))
   #:on-show-recovery
     (lambda (e)
       (set! *keri-show-recovery?* #t)
       (refresh!))
   #:on-close-recovery
     (lambda (e)
       (set! *keri-show-recovery?* #f)
       (refresh!))
   #:show-shamir? *keri-show-shamir?*
   #:on-download-backup
     (lambda (e) (do-keri-download-backup!))
   #:on-show-shamir
     (lambda (e)
       (set! *keri-show-shamir?* #t)
       (refresh!))
   #:on-close-shamir
     (lambda (e)
       (set! *keri-show-shamir?* #f)
       (refresh!))
   #:on-split-shares
     (lambda (e) (do-keri-split-shares!))))

;; The dropdown overlay: backdrop (closes on click) + positioned panel
;; containing the identity page body. Rendered conditionally on
;; *identity-dropdown-open?* from render(); always present in the DOM
;; tree at the same position so VDOM diff is stable.
(define (render-identity-dropdown)
  (if (not *identity-dropdown-open?*)
      ""
      `(div (@ (class "id-dropdown-root"))
            (div (@ (class "id-dropdown-backdrop")
                    (click ,(lambda (e)
                              (set! *identity-dropdown-open?* #f)
                              (refresh!)))))
            (div (@ (class "id-dropdown"))
                 ,(render-identity-page-body)))))

(define (render-inventory-view)
  "Render the inventory tab. Reads only — mutations live in the click
   callbacks below. Inventory shares *active-scope* / *active-plan* /
   *acting-as* with the calendar so switching tabs preserves the
   scope context the user is currently working in."
  (let* ((snap *inv-snapshot*)
         (detail (and *inv-selected-resource*
                      (let ((p (assoc *inv-selected-resource*
                                      *inv-detail-cache*)))
                        (and p (cdr p))))))
    (inventory-page
     #:snapshot snap
     ;; Scope, plan, and acting-as flow in as read-only context (the
     ;; selectors live at the session level above the view).
     #:current-scope *active-scope*
     #:current-plan *active-plan*
     #:current-acting-as *acting-as*
     #:view-mode *inv-view-mode*
     #:selected-spec-id *inv-selected-spec*
     #:selected-resource-id *inv-selected-resource*
     #:detail detail
     #:breadcrumb *inv-breadcrumb*
     #:custody-expanded? *inv-custody-expanded?*
     #:active-category *inv-active-category*
     #:on-toggle-view-mode
       (lambda (mode)
         (set! *inv-view-mode* mode)
         ;; Clear selection when switching views — the selected spec/resource
         ;; may not exist in the other view.
         (set! *inv-selected-spec* #f)
         (set! *inv-selected-resource* #f)
         (set! *inv-breadcrumb* '())
         (refresh!))
     #:on-select-category
       (lambda (uri)
         (set! *inv-active-category* uri)
         ;; Drop a stale spec selection if it's no longer in the filter.
         (when *inv-selected-spec*
           (let* ((specs (or (and *inv-snapshot*
                                  (assq-ref *inv-snapshot* 'specs))
                             '()))
                  (sel (%find (lambda (s)
                                (equal? (assq-ref s 'id) *inv-selected-spec*))
                              specs))
                  (cats (and sel (or (assq-ref sel 'categories) '()))))
             (unless (or (not uri)
                         (and cats (member uri cats)))
               (set! *inv-selected-spec* #f)
               (set! *inv-selected-resource* #f)
               (set! *inv-breadcrumb* '()))))
         (refresh!))
     #:on-select-spec
       (lambda (sid)
         (set! *inv-selected-spec* sid)
         (set! *inv-selected-resource* #f)
         (set! *inv-breadcrumb* '())
         (refresh!))
     #:on-select-resource
       (lambda (rid)
         (set! *inv-selected-resource* rid)
         ;; Drill stack: append, don't reset, so children push deeper.
         (unless (and (pair? *inv-breadcrumb*)
                      (equal? (car (reverse *inv-breadcrumb*)) rid))
           (set! *inv-breadcrumb* (append *inv-breadcrumb* (list rid))))
         (set! *inv-custody-expanded?* #f)
         (planner-fetch-resource-detail! rid)
         (refresh!))
     #:on-pop-breadcrumb
       (lambda (rid)
         (let loop ((rest *inv-breadcrumb*) (acc '()))
           (cond
             ((null? rest)
              (set! *inv-breadcrumb* (reverse acc)))
             ((equal? (car rest) rid)
              (set! *inv-breadcrumb* (reverse (cons rid acc)))
              (set! *inv-selected-resource* rid)
              (planner-fetch-resource-detail! rid))
             (else
              (loop (cdr rest) (cons (car rest) acc)))))
         (set! *inv-custody-expanded?* #f)
         (refresh!))
     #:on-toggle-custody
       (lambda ()
         (set! *inv-custody-expanded?* (not *inv-custody-expanded?*))
         (refresh!))
     #:on-clear-selection
       (lambda ()
         (cond
           (*inv-selected-resource*
            ;; Pop one level back, or close detail if at top
            (set! *inv-breadcrumb*
                  (if (pair? *inv-breadcrumb*)
                      (reverse (cdr (reverse *inv-breadcrumb*)))
                      '()))
            (set! *inv-selected-resource*
                  (and (pair? *inv-breadcrumb*)
                       (car (reverse *inv-breadcrumb*))))
            (when *inv-selected-resource*
              (planner-fetch-resource-detail! *inv-selected-resource*)))
           (else
            (set! *inv-selected-spec* #f)))
         (set! *inv-custody-expanded?* #f)
         (refresh!)))))

;;; ── Recipes view ────────────────────────────────────────────────────────────
;;;
;;; Ported from ~/Programs/planner/src/routes/recipes/+page.svelte. The
;;; library tab shows the built-in starter recipes; the workshop tab
;;; turns a natural-language prompt into a ValueFlows recipe via the gateway
;;; lobby's 'ai-complete (→ key-pool → nano-gpt/TEE). The model is asked for a
;;; Scheme s-expression (not JSON) so we can parse it with `read`.

;; parse a completion into a recipe + update the workshop state. Runs in the
;; `on` callback (a later turn); guarded so a bad parse is a friendly error.
(define (recipes-accept-completion! response)
  (with-exception-handler
    (lambda (_exn)
      (set! *recipes-error* "Generation failed — try again.")
      (set! *recipes-generating?* #f)
      (refresh!))
    (lambda ()
      (let* ((cleaned (strip-code-fences (if (string? response) response "")))
             (form    (read (open-input-string cleaned)))
             (recipe  (recipe-from-sexp form)))
        (cond
         (recipe
          (set! *recipes-generated* (cons (cons '(active . #t) recipe) *recipes-generated*))
          (set! *recipes-prompt* "")
          (set! *recipes-error* ""))
         (else
          (set! *recipes-error* "AI response wasn't a valid recipe alist. Try rephrasing.")))
        (set! *recipes-generating?* #f)
        (refresh!)))
    #:unwind? #t))

(define (recipes-trigger-generate!)
  "Read the prompt textarea, ask the gateway for a recipe, and — when it
   answers — parse it and prepend it to *recipes-generated*."
  (let* ((el     (get-element-by-id "rec-prompt"))
         (prompt (if el (element-value el) "")))
    (cond
     ((or (not prompt) (string=? prompt ""))
      (set! *recipes-error* "Type a prompt first.")
      (refresh!))
     ((not *lobby*)
      (set! *recipes-error* "No gateway connection — recipe generation needs the gateway.")
      (refresh!))
     (else
      (set! *recipes-prompt* prompt)
      (set! *recipes-generating?* #t)
      (set! *recipes-error* "")
      (refresh!)
      ;; async: the lobby answers in a later turn; the `on` callback (in
      ;; *ocapn-vat*) parses it and refreshes. #f model → gateway default (TEE).
      (with-vat *ocapn-vat*
        (on (<- *lobby* 'ai-complete recipe-generation-system-prompt prompt #f)
            recipes-accept-completion!
            #:catch
            (lambda _
              (set! *recipes-error* "The gateway could not answer — try again.")
              (set! *recipes-generating?* #f)
              (refresh!))))))))

(define (recipes-toggle-active! recipe)
  "Flip the (active . _) cell on a generated recipe."
  (let ((rid (alist-ref recipe 'id "")))
    (set! *recipes-generated*
          (map (lambda (r)
                 (if (equal? (alist-ref r 'id "") rid)
                     (cons (cons 'active (not (alist-ref r 'active #t)))
                           (filter (lambda (p) (not (eq? (car p) 'active))) r))
                     r))
               *recipes-generated*))))

(define (render-recipes-view)
  (recipes-page
   #:tab           *recipes-tab*
   #:search        *recipes-search*
   #:prompt        *recipes-prompt*
   #:generating?   *recipes-generating?*
   #:error-msg     *recipes-error*
   #:generated     *recipes-generated*
   #:on-set-tab    (lambda (t) (set! *recipes-tab* t) (refresh!))
   #:on-search-input
     (lambda ()
       (let ((el (get-element-by-id "rec-search")))
         (when el
           (set! *recipes-search* (element-value el))
           (refresh!))))
   #:on-generate   (lambda () (recipes-trigger-generate!))
   #:on-pick-example
     (lambda (ex)
       (set! *recipes-prompt* ex)
       (refresh!))
   #:on-toggle-active
     (lambda (r) (recipes-toggle-active! r) (refresh!))))


;;; ── Priority tree view ─────────────────────────────────────────────────────

(define %prio-storage-key "pn.repl.priorities")

(define (prio-save-tree!)
  (when *prio-tree*
    (ls-set-item %prio-storage-key
                 (call-with-output-string (lambda (p) (write *prio-tree* p))))))

(define (prio-load-tree!)
  (when (not *prio-tree*)
    (let ((raw (ls-get-item %prio-storage-key)))
      (if (and (string? raw) (not (string=? raw "")))
          (let ((tree (with-exception-handler
                        (lambda (exn) #f)
                        (lambda () (read (open-input-string raw)))
                        #:unwind? #t)))
            (when tree
              (set! *prio-tree* tree)
              (set! *prio-current-id* (alist-ref tree 'id))
              (set! *prio-path* (list (alist-ref tree 'id)))))
          (let ((root-id (crypto-random-uuid)))
            (set! *prio-tree*
                  `((id . ,root-id) (name . "Priorities") (type . root)
                    (children . ())))
            (set! *prio-current-id* root-id)
            (set! *prio-path* (list root-id))
            (prio-save-tree!))))))

(define (prio-zoom-into! id)
  (set! *prio-path* (append *prio-path* (list id)))
  (set! *prio-current-id* id))

(define (prio-zoom-out!)
  (when (> (length *prio-path*) 1)
    (set! *prio-path* (reverse (cdr (reverse *prio-path*))))
    (set! *prio-current-id* (car (reverse *prio-path*)))))

(define (prio-zoom-to! id)
  (let loop ((rest *prio-path*) (acc '()))
    (cond
      ((null? rest) #f)
      ((equal? (car rest) id)
       (set! *prio-path* (reverse (cons id acc)))
       (set! *prio-current-id* id))
      (else (loop (cdr rest) (cons (car rest) acc))))))

(define (prio-find-node tree id)
  (cond
   ((not tree) #f)
   ((equal? (alist-ref tree 'id "") id) tree)
   (else
    (let loop ((kids (alist-ref tree 'children '())))
      (cond
       ((null? kids) #f)
       ((prio-find-node (car kids) id) => (lambda (x) x))
       (else (loop (cdr kids))))))))

(define (alist-set alist key val)
  (cons (cons key val)
        (filter (lambda (p) (not (eq? key (car p)))) alist)))

(define (prio-update-in-tree tree id updater)
  (cond
   ((not tree) #f)
   ((equal? (alist-ref tree 'id "") id) (updater tree))
   (else
    (alist-set tree 'children
               (map (lambda (kid) (prio-update-in-tree kid id updater))
                    (alist-ref tree 'children '()))))))

(define (prio-remove-from-tree tree id)
  (cond
   ((not tree) #f)
   (else
    (alist-set tree 'children
               (let loop ((kids (alist-ref tree 'children '())) (acc '()))
                 (cond
                  ((null? kids) (reverse acc))
                  ((equal? (alist-ref (car kids) 'id "") id)
                   (loop (cdr kids) acc))
                  (else
                   (loop (cdr kids)
                         (cons (prio-remove-from-tree (car kids) id) acc)))))))))

(define (prio-add-child! parent-id name)
  (let* ((new-id (crypto-random-uuid))
         (parent (prio-find-node *prio-tree* parent-id))
         (siblings (if parent (alist-ref parent 'children '()) '()))
         (avg-pts (if (null? siblings) 100
                      (quotient (let lp ((ss siblings) (acc 0))
                                  (if (null? ss) acc
                                      (lp (cdr ss)
                                          (+ acc (alist-ref (car ss) 'points 10)))))
                                (length siblings))))
         (new-node `((id . ,new-id) (name . ,name) (type . node)
                     (points . ,avg-pts) (children . ())
                     (contributors . ()) (anti-contributors . ()))))
    (set! *prio-tree*
          (prio-update-in-tree *prio-tree* parent-id
                               (lambda (n)
                                 (alist-set n 'children
                                            (append (alist-ref n 'children '())
                                                    (list new-node))))))
    (prio-save-tree!)))

(define (prio-delete-node! id)
  (set! *prio-tree* (prio-remove-from-tree *prio-tree* id))
  (prio-save-tree!))

(define (prio-rename-node! id new-name)
  (set! *prio-tree*
        (prio-update-in-tree *prio-tree* id
                             (lambda (n) (alist-set n 'name new-name))))
  (prio-save-tree!))

(define (prio-update-points! id new-points)
  (set! *prio-tree*
        (prio-update-in-tree *prio-tree* id
                             (lambda (n)
                               (alist-set n 'points (max 1 (inexact->exact (round new-points))))))))

(define (render-priorities-view)
  (priorities-page
   #:tree *prio-tree*
   #:current-id *prio-current-id*
   #:path *prio-path*
   #:resizing-id *prio-resizing?*
   #:editing-id *prio-editing-id*
   #:delete-mode? *prio-delete-mode?*
   #:on-zoom-in (lambda (id) (prio-zoom-into! id) (refresh!))
   #:on-zoom-out (lambda () (prio-zoom-out!) (refresh!))
   #:on-zoom-to (lambda (id) (prio-zoom-to! id) (refresh!))
   #:on-add-node (lambda ()
                   (prio-add-child! *prio-current-id* "New Priority")
                   (set! *prio-delete-mode?* #f)
                   (refresh!))
   #:on-delete (lambda (id)
                 (prio-delete-node! id)
                 (refresh!))
   #:on-rename (lambda (id new-name)
                 (prio-rename-node! id new-name)
                 (set! *prio-editing-id* #f)
                 (refresh!))
   #:on-toggle-delete
     (lambda ()
       (set! *prio-delete-mode?* (not *prio-delete-mode?*))
       (set! *prio-editing-id* #f)
       (refresh!))
   #:on-pointer-down
     (lambda (e id)
       (set! *prio-resizing?* id)
       (set! *prio-resize-start-y* (event-client-y e))
       (set! *prio-touch-start-time* (date-now)))
   #:on-pointer-move
     (lambda (e id)
       (when *prio-resizing?*
         (let* ((cur-y (event-client-y e))
                (dy (- *prio-resize-start-y* cur-y))
                (elapsed (- (date-now) *prio-touch-start-time*)))
           (when (and (> (abs dy) 4) (> elapsed 150))
             (let* ((node (prio-find-node *prio-tree* *prio-resizing?*))
                    (cur-pts (if node (alist-ref node 'points 10) 10))
                    (rate (* dy 0.003))
                    (max-rate (* cur-pts 0.05))
                    (clamped (max (- max-rate) (min max-rate rate)))
                    (new-pts (+ cur-pts clamped)))
               (prio-update-points! *prio-resizing?* new-pts)
               (refresh!))))))
   #:on-pointer-up
     (lambda (e id)
       (let* ((dy (abs (- (event-client-y e) *prio-resize-start-y*)))
              (elapsed (- (date-now) *prio-touch-start-time*))
              (was-resize (and *prio-resizing?* (> dy 10) (> elapsed 150))))
         (set! *prio-resizing?* #f)
         (cond
           (was-resize
            (prio-save-tree!)
            (refresh!))
           ;; Short tap on a node with children → zoom in
           ((and (< elapsed 300) (< dy 10)
                 (let ((nd (prio-find-node *prio-tree* id)))
                   (and nd (not (null? (alist-ref nd 'children '()))))))
            (prio-zoom-into! id)
            (refresh!))
           ;; Short tap on leaf → do nothing (or could start edit)
           (else
            (refresh!)))))
   #:on-edit-start
     (lambda (id)
       (unless *prio-delete-mode?*
         (set! *prio-editing-id* id)
         (refresh!)))
   #:on-edit-commit
     (lambda (e id)
       (let ((key (keyboard-event-key e)))
         (cond
           ((equal? key "Enter")
            (let ((val (event-target-value e)))
              (when (and (string? val) (not (string=? val "")))
                (prio-rename-node! id val)))
            (set! *prio-editing-id* #f)
            (refresh!))
           ((equal? key "Escape")
            (set! *prio-editing-id* #f)
            (refresh!)))))))


;;; ── Journey (Valhalla routing) ──────────────────────────────────────────────
;;; Route from the user to a selected marker. The Valhalla round-trip lives in
;;; JS (routing.fetch → serve-static /route proxy → local Valhalla); Scheme
;;; pipes the result JSON straight back to the map layer (%map-draw-route) and
;;; keeps only display strings — no JSON parsing on the Hoot side. Origin is
;;; the user's geolocation when granted, the map center otherwise. The journey
;;; survives tab switches: state stays here, the line is redrawn on remount.

(define *journey* #f)   ;; alist: dest dest-name origin profile json summary turns

(define (journey-ref key default)
  (let ((p (and (pair? *journey*) (assq key *journey*))))
    (if p (cdr p) default)))

(define (parse-latlng-str s)
  "\"lat,lng\" → (lat . lng), or #f."
  (let ((parts (string-split (or s "") #\,)))
    (and (= 2 (length parts))
         (let ((lat (string->number (car parts)))
               (lng (string->number (cadr parts))))
           (and lat lng (cons lat lng))))))

(define (marker-display-name mk)
  (let ((p (and (pair? (gsm-capacity mk)) (assq 'name (gsm-capacity mk)))))
    (if p (cdr p) "destination")))

(define (journey-fit! json)
  (let ((b (map string->number (string-split (%route-bounds json) #\,))))
    (when (and (= 4 (length b)) (not (memq #f b)) *map-instance*)
      (apply (lambda (w s e n) (%map-fit-bounds *map-instance* w s e n 80))
             b))))

(define (journey-draw! json)
  (when *map-instance*
    (%map-draw-route *map-instance* "journey" json "#4ea1ff" 5)))

(define (journey-redraw!)
  "Re-paint the stored route after a map remount (layers die with the
   instance; the journey doesn't)."
  (let ((json (journey-ref 'json #f)))
    (when json (journey-draw! json))))

(define (journey-fetch! origin mk profile)
  (%routing-fetch
   (car origin) (cdr origin) (gsm-lat mk) (gsm-lng mk) profile ""
   (procedure->external
    (lambda (json)
      (journey-draw! json)
      (journey-fit! json)
      (set! *journey*
            ;; lifecycle fields (commitment/done/divergence) survive a
            ;; refetch — switching mode pills after "i'll go" must not
            ;; resurrect the button or permit a double-commit
            (append
             `((dest      . ,mk)
               (dest-name . ,(marker-display-name mk))
               (origin    . ,origin)
               (profile   . ,profile)
               (json      . ,json)
               (summary   . ,(%route-summary-line json))
               (turns     . ,(filter (lambda (s) (not (string=? s "")))
                                     (string-split (%route-maneuvers-text json)
                                                   #\newline))))
             (filter (lambda (kv) (memq (car kv) '(commitment done divergence)))
                     (or *journey* '()))))
      (refresh!)))))

(define (journey-start! mk)
  "Route to MK — geolocation fix when granted, map center otherwise.
   Keeps the profile already chosen on a previous journey."
  (%routing-locate
   (procedure->external
    (lambda (fix)
      (let ((origin (or (parse-latlng-str fix)
                        (and *map-instance*
                             (parse-latlng-str
                              (%map-get-center *map-instance*))))))
        (when origin
          (journey-fetch! origin mk (journey-ref 'profile "foot"))))))))

(define (journey-set-profile! p)
  (let ((origin (journey-ref 'origin #f))
        (mk     (journey-ref 'dest #f)))
    (when (and origin mk) (journey-fetch! origin mk p))))

;;; ── the journey's chat: stratum-stamped, filtered read-side ─────────────────
;;; Topics are generic strings; the journey's own commitment id is the first
;;; one this panel opens. Strata (public/willing/committed/satisfied) are
;;; resolved from the plan SERVER-side and stamped per message — what the
;;; author WAS when they spoke; the chips here are pure read-side selection.

(define *chat-topic*  #f)
(define *chat-msgs*   '())
(define *chat-strata* '("public" "willing" "committed" "satisfied"))
(define *chat-filter* '("public" "willing" "committed" "satisfied"))
(define *chat-show-notes?* #t)   ; the transcript dimension (kind="note")

(define (chat-open! topic)
  (set! *chat-topic* topic)
  (set! *chat-msgs* '())
  (when (and topic *planner-cap* *active-scope*)
    (with-vat *ocapn-vat*
      (on (<- *planner-cap* 'chat-history *active-scope* topic)
          (lambda (res)
            (when (and (pair? res) (eq? 'ok (car res)) (vector? (cdr res)))
              (set! *chat-msgs* (vector->list (cdr res)))
              (refresh!)))
          #:catch (lambda errs #f))
      ;; live: the gateway <-np's our inbox on every post to this topic
      (when *user-inbox*
        (on (<- *planner-cap* 'chat-watch *active-scope* topic *user-inbox*)
            (lambda _ #f) #:catch (lambda errs #f))))))

(define (chat-close!)
  (set! *chat-topic* #f)
  (set! *chat-msgs* '()))

(define (chat-send!)
  (let* ((el (get-element-by-id "chat-input"))
         (body (if el (element-value el) "")))
    (when (and *chat-topic* *planner-cap* *active-scope* (journey-agent)
               (> (string-length body) 0))
      (with-vat *ocapn-vat*
        (on (<- *planner-cap* 'chat-post *active-scope* *chat-topic*
                (journey-agent) body)
            (lambda (res) (chat-open! *chat-topic*))
            #:catch (lambda errs #f))))))

;; the walkie: hold-to-talk on the OPEN channel. The mic records, the lobby's
;; Whisper transcribes, and the transcript posts as a note — burst-voice over
;; ANY transport (it's just a chat message), the note its permanent record.
(define *walkie-on?* #f)
;; THE shared record: a spoken utterance becomes a note on the open channel,
;; whatever gesture spoke it. Voice is ephemeral; the note is the record.
(define (walkie-post-note! transcript)
  (let ((body (%trim transcript)))
    (when (and *chat-topic* *planner-cap* *active-scope* (journey-agent)
               (> (string-length body) 0))
      (with-vat *ocapn-vat*
        (on (<- *planner-cap* 'chat-post *active-scope* *chat-topic*
                (journey-agent) body "note")
            (lambda (res) (chat-open! *chat-topic*))
            #:catch (lambda errs #f)))))
  (refresh!))
;; THE speak gesture: record → note (every chat). And if you've joined live
;; audio, the mic also transmits while you speak — same gesture, context
;; decides the delivery. One button, not two; the note is always the record.
(define (walkie-toggle!)
  (if *walkie-on?*
      (begin (stop-listening!)
             (when *walkie-joined?* (rtc-mic-enabled 0))   ; stop transmitting
             (set! *walkie-on?* #f))
      (begin (set-express-mode! 0)
             (when *walkie-joined?* (rtc-mic-enabled 1))   ; live while speaking
             (start-listening!
               (procedure->external walkie-post-note!)
               (procedure->external
                (lambda ()
                  (when *walkie-joined?* (rtc-mic-enabled 0))
                  (set! *walkie-on?* #f) (refresh!))))
             (set! *walkie-on?* #t)))
  (refresh!))

(define (chat-toggle! stratum)
  (set! *chat-filter*
        (if (member stratum *chat-filter*)
            (filter (lambda (s) (not (string=? s stratum))) *chat-filter*)
            (cons stratum *chat-filter*)))
  (refresh!))

(define (network-channel-topic)
  (and *active-scope* (string-append "walkie:" *active-scope*)))

;; idle map state: a launcher for the scope-wide walkie + the channel itself
(define (network-idle-extra)
  (let ((topic (network-channel-topic)))
    (cond
     ((not topic) #f)
     ((equal? *chat-topic* topic)
      `(div (@ (class "network-channel"))
            (div (@ (class "panel-section-title"))
                 "📻 the network"
                 (span (@ (class "panel-close")
                          (click ,(lambda (e) (chat-close!) (refresh!)))) " ×"))
            ;; the co-present LIVE layer is a one-time MEMBERSHIP toggle (mic
            ;; permission); riding the WebRTC peer mesh already standing for
            ;; OCapN P2P. Speaking itself is the one 🎙 in the chat row below —
            ;; it transmits live while you're joined, and notes either way.
            (div (@ (class "walkie-live"))
                 ,(if *walkie-joined?*
                      `(span (@ (class "walkie-join on")
                               (click ,(lambda (e) (walkie-leave!))))
                             "📡 live audio on — leave")
                      `(span (@ (class "walkie-join")
                               (click ,(lambda (e) (walkie-join!))))
                             "📡 join live audio")))
            ,(chat-panel)))
     (else
      `(div (@ (class "network-open"))
            (span (@ (class "network-open-btn")
                     (click ,(lambda (e) (chat-open! topic) (refresh!))))
                  "📻 join the network channel"))))))

(define (chat-panel)
  (and *chat-topic*
       `(div (@ (class "journey-chat"))
          (div (@ (class "chat-chips"))
               ,@(map (lambda (st)
                        `(span (@ (class ,(string-append
                                           "chat-chip s-" st
                                           (if (member st *chat-filter*) " on" "")))
                                  (click ,(lambda (e) (chat-toggle! st))))
                               ,st))
                      *chat-strata*)
               ;; transcript: an orthogonal dimension — hide/show voice notes
               (span (@ (class ,(string-append "chat-chip s-transcript"
                                  (if *chat-show-notes?* " on" "")))
                        (title "voice-note transcripts")
                        (click ,(lambda (e)
                                  (set! *chat-show-notes?* (not *chat-show-notes?*))
                                  (refresh!))))
                     "📝 transcript"))
          (div (@ (class "chat-list"))
               ,@(let ((shown (%filter (lambda (m)
                                         (and (member (alist-ref m 'stratum "public")
                                                      *chat-filter*)
                                              ;; transcript is its own dimension:
                                              ;; a note shows only when notes are on
                                              (or *chat-show-notes?*
                                                  (not (equal? (alist-ref m 'kind "text")
                                                               "note")))))
                                       *chat-msgs*)))
                   (if (null? shown)
                       (list `(div (@ (class "chat-empty")) "no messages yet"))
                       (map (lambda (m)
                              `(div (@ (class "chat-msg"))
                                 (span (@ (class ,(string-append
                                                   "chat-auth s-"
                                                   (alist-ref m 'stratum "public")))
                                          (title ,(string-append
                                                   "spoke as "
                                                   (alist-ref m 'stratum "public"))))
                                       ,(let ((a (alist-ref m 'author "?")))
                                          (if (> (string-length a) 10)
                                              (substring a 0 10) a)))
                                 (span (@ (class "chat-body"))
                                       ,(if (equal? (alist-ref m 'kind "text") "note")
                                            "📝 " "")
                                       ,(alist-ref m 'body ""))))
                            shown))))
          (div (@ (class "chat-row"))
               (span (@ (class ,(string-append "chat-walkie"
                                  (if *walkie-on?* " on" "")
                                  (if *walkie-joined?* " live" "")))
                        (title ,(if *walkie-joined?*
                                    "speak — live to the channel, and noted"
                                    "speak — transcribed to a note"))
                        (click ,(lambda (e) (walkie-toggle!))))
                     ,(if *walkie-on?* "■" "🎙"))
               (input (@ (id "chat-input") (placeholder "say something…")))
               (span (@ (class "chat-send") (click ,(lambda (e) (chat-send!))))
                     "↩")))))

(define (journey-clear!)
  (chat-close!)
  (%routing-trace-stop)
  (when *map-instance*
    (%map-clear-route *map-instance* "journey")
    (%map-clear-route *map-instance* "trace"))
  (set! *journey* #f)
  (refresh!))

;;; ── Journey → VF records: the observed arc-time table starts breathing ──────
;;; "i'll go" turns the routed journey into a Commitment + pickup event on the
;;; gateway (planner-service 'journey-begin); "arrived" records the dropoff
;;; that fulfills it. The events carry the ride process id ("ride.{agent}.
;;; {mode}", mode = a Valhalla costing via THE one mapping in repl.js), so the
;;; observer pairs them, times them, and the planner's transport coefficients
;;; learn from this very trip. Origin is "geo:lat,lng" (recorded faithfully;
;;; prices an arc once it corresponds to a located place); destination is the
;;; marker's location key.

(define (journey-agent)
  (or *acting-as*
      (and (pair? *keri-identity*) (alist-ref *keri-identity* 'prefix #f))))

(define (journey-places)
  "(from . to) place strings for the active journey, or #f when the
   destination has no location key — an empty place would feed junk
   arc keys into the observed table, so no key ⇒ no lifecycle buttons."
  (let ((mk (journey-ref 'dest #f)) (origin (journey-ref 'origin #f)))
    (and mk origin
         (let ((to (gsm-location-key mk)))
           (and (string? to) (not (string=? to ""))
                (cons (string-append "geo:" (number->string (car origin))
                                     "," (number->string (cdr origin)))
                      to))))))

(define (journey-commitable?)
  (and *journey* *planner-cap* *active-scope* (journey-agent)
       (journey-places) #t))

(define (journey-commit!)
  (let ((places (journey-places)) (agent (journey-agent)))
    (when (and places agent (journey-commitable?))
      (let ((mode (%route-costing-of (journey-ref 'profile "foot"))))
        (with-vat *ocapn-vat*
          (on (<- *planner-cap* 'journey-begin *active-scope* agent
                  (car places) (cdr places) mode)
              (lambda (res)
                (when (and (pair? res) (eq? (car res) 'ok))
                  (set! *journey*
                        (cons (cons 'commitment (alist-ref (cdr res) 'commitment #f))
                              *journey*))
                  (chat-open! (alist-ref (cdr res) 'commitment #f))
                  (%routing-trace-start)
                  (refresh!)))
              #:catch (lambda errs #f)))))))

(define (journey-divergence-line)
  "\"actual ~N min · planned …\" — the plan/observed Δ in one line, the same
   fact the dropoff event just carried to the table."
  (let ((actual (inexact->exact (round (%routing-trace-elapsed))))
        (planned (journey-ref 'summary "")))
    (string-append "actual ~" (number->string actual) " min · planned " planned)))

(define (journey-arrive!)
  (let ((cid (journey-ref 'commitment #f))
        (places (journey-places)) (agent (journey-agent)))
    (when (and cid places agent *planner-cap* *active-scope*)
      (let ((mode (%route-costing-of (journey-ref 'profile "foot"))))
        (with-vat *ocapn-vat*
          (on (<- *planner-cap* 'journey-end *active-scope* agent cid
                  (car places) (cdr places) mode)
              (lambda (res)
                (when (and (pair? res) (eq? (car res) 'ok))
                  (set! *journey*
                        (cons '(done . #t)
                              (cons (cons 'divergence (journey-divergence-line))
                                    *journey*)))
                  ;; map-match the collected trace: the road actually taken,
                  ;; drawn warm beside the plan's blue
                  (%routing-trace-match
                   (journey-ref 'profile "foot")
                   (procedure->external
                    (lambda (json)
                      (when (and (string? json)
                                 (> (string-length json) 0)
                                 *map-instance*)
                        (%map-draw-route *map-instance* "trace" json "#ffb454" 4))
                      (refresh!))))
                  (refresh!)))
              #:catch (lambda errs #f)))))))

;;; ── Clock view ──────────────────────────────────────────────────────────────
;;; The social-time dial (playnet ui clock). Zoom 0 = your day, 1 =
;;; everyone's; a two-finger pinch on the dial moves between them —
;;; fingers together zooms OUT from yourself to society, spreading them
;;; zooms back in to you. Wheel and the slider do the same on desktop.
(define *clock-zoom* 0.0)
(define *clock-pointers* '())     ;; alist: pointerId -> (x . y)
(define *clock-pinch-base* #f)    ;; (start-distance . start-zoom) while 2 fingers down

(define (clock-pointer-upsert! id pos)
  (set! *clock-pointers*
        (cons (cons id pos)
              (filter (lambda (p) (not (= (car p) id))) *clock-pointers*))))

(define (clock-pinch-distance)
  (let* ((a (cdr (car *clock-pointers*)))
         (b (cdr (cadr *clock-pointers*)))
         (dx (- (car a) (car b)))
         (dy (- (cdr a) (cdr b))))
    (sqrt (+ (* dx dx) (* dy dy)))))

(define (clock-set-zoom! z)
  (set! *clock-zoom* (max 0.0 (min 1.0 z)))
  ;; keep the slider thumb in sync with pinch/wheel zoom: the VDOM only
  ;; rewrites the value ATTRIBUTE, which a range input ignores once the
  ;; user has touched it — set the live property directly
  (let ((el (get-element-by-id "clock-zoom-slider")))
    (when el
      (set-element-value!
       el (number->string (inexact->exact (round (* *clock-zoom* 100)))))))
  (refresh!))

(define (render-clock-view)
  (clock-surface
   #:zoom *clock-zoom*
   #:on-pointer-down
   (lambda (e)
     (prevent-default! e)
     (clock-pointer-upsert! (event-pointer-id e)
                            (cons (event-client-x e) (event-client-y e)))
     (when (>= (length *clock-pointers*) 2)
       (set! *clock-pinch-base* (cons (clock-pinch-distance) *clock-zoom*))))
   #:on-pointer-move
   (lambda (e)
     (when (assv (event-pointer-id e) *clock-pointers*)
       (clock-pointer-upsert! (event-pointer-id e)
                              (cons (event-client-x e) (event-client-y e)))
       (when (and *clock-pinch-base* (>= (length *clock-pointers*) 2))
         (let* ((d0 (car *clock-pinch-base*))
                (z0 (cdr *clock-pinch-base*))
                (d (clock-pinch-distance)))
           (when (> d0 1.0)
             ;; fingers together (d < d0) -> zoom out toward society
             (clock-set-zoom! (+ z0 (* 1.5 (- 1.0 (/ d d0))))))))))
   #:on-pointer-up
   (lambda (e)
     (set! *clock-pointers*
           (filter (lambda (p) (not (= (car p) (event-pointer-id e))))
                   *clock-pointers*))
     (when (< (length *clock-pointers*) 2)
       (set! *clock-pinch-base* #f)))
   #:on-wheel
   (lambda (e)
     (prevent-default! e)
     ;; wheel down = zoom out to society, up = back to you
     (clock-set-zoom! (+ *clock-zoom*
                         (if (> (event-delta-y e) 0.0) 0.06 -0.06))))
   #:on-slider
   (lambda (e)
     (let ((v (string->number (event-target-value e))))
       (when v (clock-set-zoom! (/ v 100.0)))))))

;;; ── Map view ────────────────────────────────────────────────────────────────
(define (render-map-view)
  (map-view #:selected *map-selected*
            #:on-close (lambda (e) (set! *map-selected* #f) (refresh!))
            #:on-marker-click (lambda (m) (set! *map-selected* m) (refresh!))
            #:on-toggle-globe
              (lambda (e)
                (set! *map-globe?* (not *map-globe?*))
                (when *map-instance*
                  (%map-set-projection *map-instance*
                                       (if *map-globe?* "globe" "mercator")))
                (refresh!))
            #:on-toggle-3d
              (lambda (e)
                (set! *map-show-3d?* (not *map-show-3d?*))
                (when *map-instance*
                  (%map-set-pitch *map-instance* (if *map-show-3d?* 70.0 0.0)))
                (refresh!))
            #:on-toggle-terrain
              (lambda (e)
                (set! *map-show-terrain?* (not *map-show-terrain?*))
                (refresh!))
            #:on-toggle-clustering
              (lambda (e)
                (set! *map-clustering?* (not *map-clustering?*))
                (populate-map-markers!)
                (refresh!))
            #:on-toggle-fab
              (lambda (e)
                (set! *map-fab-open?* (not *map-fab-open?*))
                (refresh!))
            #:on-search
              (lambda (e)
                (let* ((el (get-element-by-id "map-search"))
                       (v  (if el (element-value el) "")))
                  (set! *map-search-query* (or v ""))
                  (set! *map-search-results* (map-search-markers v))
                  (refresh!)
                  (let ((el2 (get-element-by-id "map-search")))
                    (when el2 (focus-element! el2)))))
            #:on-search-clear
              (lambda (e)
                (set! *map-search-query* "")
                (set! *map-search-results* '())
                (refresh!))
            #:on-result-click
              (lambda (m)
                (set! *map-selected* m)
                ;; Clear search so the panel switches to the detail view
                ;; of the picked capacity instead of staying on results.
                (set! *map-search-query* "")
                (set! *map-search-results* '())
                ;; Pan the map to the chosen marker.
                (when *map-instance*
                  (%map-set-center *map-instance* (gsm-lng m) (gsm-lat m))
                  (%map-set-zoom *map-instance* 10.0))
                (refresh!))
            #:globe?         *map-globe?*
            #:show-3d?       *map-show-3d?*
            #:show-terrain?  *map-show-terrain?*
            #:clustering?    *map-clustering?*
            #:fab-open?      *map-fab-open?*
            #:search-query   *map-search-query*
            #:search-results *map-search-results*
            #:journey        *journey*
            #:on-route       (lambda (mk) (journey-start! mk))
            #:on-journey-profile (lambda (p) (journey-set-profile! p))
            #:on-journey-clear   (lambda (e) (journey-clear!))
            ;; gateway-connected + scoped ⇒ the journey can become VF records
            #:on-journey-commit  (and (journey-commitable?)
                                      (lambda (e) (journey-commit!)))
            #:on-journey-arrive  (and (journey-commitable?)
                                      (lambda (e) (journey-arrive!)))
            #:journey-extra      (and *journey* (chat-panel))
            #:idle-extra         (network-idle-extra)))

;;; ── Contacts view ───────────────────────────────────────────────────────────
;;; Browser-resident contact list: a contact is a resolved OOBI we've
;;; chosen to remember. Verification against witnesses / KEL ingestion
;;; happens server-side; the browser persists alias + AID + OOBI URL
;;; locally so the user has a stable address book across reloads.
;;;
;;; "Add contact" pulls the AID from the OOBI URL path and stores the
;;; entry. A fuller flow would POST to the gateway's resolve-oobi cap
;;; and wait for the operation to settle — wired in when the gateway
;;; surface is ready (see the deferred-phase note in render-identity-
;;; page-body).

(define (do-contact-add!)
  (let* ((alias-el (get-element-by-id "contact-alias-input"))
         (oobi-el  (get-element-by-id "contact-oobi-input"))
         (note-el  (get-element-by-id "contact-note-input"))
         (alias (if alias-el (or (element-value alias-el) "") ""))
         (oobi  (if oobi-el  (or (element-value oobi-el)  "") ""))
         (note  (if note-el  (or (element-value note-el)  "") ""))
         (aid   (parse-oobi-aid oobi)))
    (cond
     ((string=? oobi "")
      (set! *contacts-error* "OOBI URL is required") (refresh!))
     ((not aid)
      (set! *contacts-error* "could not extract an AID from that URL")
      (refresh!))
     ((find-contact-by-prefix aid)
      (set! *contacts-error* "a contact with that AID already exists")
      (refresh!))
     (else
      (set! *keri-contacts*
            (append *keri-contacts*
                    (list `((alias    . ,alias)
                            (prefix   . ,aid)
                            (oobi     . ,oobi)
                            (added-at . ,(inexact->exact (floor (date-now))))
                            (note     . ,note)))))
      (save-keri-contacts!)
      (do-keri-push-contacts!)
      (set! *contacts-error* #f)
      (when alias-el (set-element-value! alias-el ""))
      (when oobi-el  (set-element-value! oobi-el ""))
      (when note-el  (set-element-value! note-el ""))
      (refresh!)))))

(define (find-contact-by-prefix p)
  (let loop ((cs *keri-contacts*))
    (cond
     ((null? cs) #f)
     ((equal? p (assq-ref (car cs) 'prefix)) (car cs))
     (else (loop (cdr cs))))))

(define (do-contact-delete! c)
  (set! *keri-contacts*
        (let loop ((cs *keri-contacts*) (acc '()))
          (cond
           ((null? cs) (reverse acc))
           ((eq? (car cs) c) (loop (cdr cs) acc))
           (else (loop (cdr cs) (cons (car cs) acc))))))
  (save-keri-contacts!)
  (do-keri-push-contacts!)
  (refresh!))

(define (do-contact-copy! aid)
  ;; navigator.clipboard.writeText returns a Promise; fire and forget.
  ;; If clipboard isn't available, silently no-op — surfacing an error
  ;; would be noisier than the value of the action.
  ;; (with-exception-handler, not catch — Hoot leaves catch
  ;; unimplemented at runtime.)
  (with-exception-handler
    (lambda (_exn) #f)
    (lambda () (clipboard-write! aid))
    #:unwind? #t))

;; Per-contact mesh resolution state: prefix → (dest . verdict-string).
;; Session-only (not persisted) — the OOBI is the source of truth and a
;; re-resolve is one fetch; caching destinations across sessions would
;; just let them go stale across the contact's rotations.
(define *contact-mesh* '())

(define (contact-mesh-of prefix)
  (let ((p (assoc prefix *contact-mesh*)))
    (and p (cdr p))))

(define (do-contact-resolve-mesh! c)
  "Fetch the contact's served OOBI body and resolve + verify its mesh
   endpoints: every advertised destination must derive from the pubkey
   the contact's icp anchored (verify-oobi-body-binding). On `verified`
   the entry also carries the anchored pub (hex) — what mail compose
   encrypts to and inbound verification checks signatures under."
  (let ((prefix (or (assq-ref c 'prefix) ""))
        (oobi   (or (assq-ref c 'oobi)   "")))
    (when (and (not (string=? prefix "")) (not (string=? oobi "")))
      (set! *contact-mesh*
            (cons (cons prefix (list "" "resolving…" ""))
                  (alist-remove prefix *contact-mesh*)))
      (refresh!)
      (%oobi-fetch-text
       oobi
       (procedure->external
        (lambda (body)
          (let ((entry
                 (if (string=? body "")
                     (list "" "OOBI unreachable" "")
                     (let* ((locs (oobi-body-mesh-locs body))
                            (mesh (assoc-ref locs "reticulum")))
                       (if (not mesh)
                           (list "" "no mesh endpoint advertised" "")
                           (let ((v   (verify-oobi-body-binding body))
                                 (pub (oobi-body-reticulum-pub body)))
                             (list mesh
                                   (cond
                                    ((eq? v #t)         "verified")
                                    ((eq? v 'no-anchor) "unverified (icp predates anchor)")
                                    (else "MISMATCH — do not trust"))
                                   (if (and (eq? v #t) pub)
                                       (bv->hex pub)
                                       ""))))))))
            (set! *contact-mesh*
                  (cons (cons prefix entry)
                        (alist-remove prefix *contact-mesh*)))
            (refresh!))))))))

(define (alist-remove key alist)
  (filter (lambda (p) (not (equal? (car p) key))) alist))

(define (render-contacts-view)
  (contacts-page
   #:contacts  *keri-contacts*
   #:error-msg *contacts-error*
   #:adding?   *contacts-adding?*
   #:on-add    (lambda (e) (do-contact-add!))
   #:on-copy   (lambda (aid) (do-contact-copy! aid))
   #:on-delete (lambda (c) (do-contact-delete! c))
   #:on-mesh   (lambda (c) (do-contact-resolve-mesh! c))
   #:mesh-of   contact-mesh-of
   #:on-mail   (lambda (c) (do-contact-mail-toggle! c))
   #:on-mail-send (lambda (e) (do-contact-mail-send!))
   #:mail-to   *mail-compose-to*
   #:on-refresh (lambda (e)
                  ;; No-op for now: contacts live in localStorage.
                  ;; Gateway sync hook lands when the OOBI-resolve cap
                  ;; is exposed via OCapN — same surface as connect.
                  (load-keri-contacts!)
                  (refresh!))))

;;; Demo marker data — placeholder until commitment-slot data is wired.
;;; Each entry: (name emoji lng lat provider slot-count). We build
;;; <grouped-slot-marker> records on demand inside populate-map-markers!.
(define *demo-marker-seeds*
  '(("Agricultural Training" "🚜" -60.6505  -32.9442 "Demo User" 2)
    ("Cooperative Bakery"    "🥖"  -1.5491   47.2184 "Demo User" 1)
    ("Legal Aid"             "⚖️"   139.6917  35.6895 "Demo User" 2)
    ("Mountain Trail"        "🥾"  -71.5375  -33.0245 "Demo User" 1)
    ("Marine Research"       "🐟"  -57.5759  -38.0055 "Demo User" 3)
    ("Construction Tools"    "🔨"  121.4737   31.2304 "Demo User" 1)
    ("Youth Sports"          "⚽"  3.3792    6.5244  "Demo User" 1)
    ("Warm Clothing"         "🧥"  37.6173   55.7558 "Demo User" 1)
    ("Agroforestry"          "🌳"  77.5946   12.9716 "Demo User" 1)
    ("Artisan Market"        "🎨"  -56.1645  -34.9011 "Demo User" 2)
    ;; Inside the routing engine's tileset (Bulgaria) — clicking "route here"
    ;; from a Sofia-area origin draws real streets, and 🚌 real metro legs.
    ("Sofia Tool Library"    "🛠️"  23.3219   42.6977 "Demo User" 2)
    ("Lozenets Repair Café"  "☕"  23.3792   42.6506 "Demo User" 1)
    ;; Near the SF-reporting dev origin — testable once the SF extract is tiled.
    ("SF Tool Library"       "🧰"  -122.4530 37.7702 "Demo User" 2)
    ("Berlin Repair Café"    "🔧"  13.4045   52.5219 "Demo User" 2)))

(define *map-marker-data* '())  ;; list of <grouped-slot-marker> records

(define (build-demo-markers!)
  "Materialise *demo-marker-seeds* into <grouped-slot-marker> records and
   store them in *map-marker-data*. Idempotent — only rebuilds if empty."
  (when (null? *map-marker-data*)
    (set! *map-marker-data*
          (map (lambda (seed)
                 (let* ((name  (list-ref seed 0))
                        (emoji (list-ref seed 1))
                        (lng   (list-ref seed 2))
                        (lat   (list-ref seed 3))
                        (prov  (list-ref seed 4))
                        (nslot (list-ref seed 5))
                        (slots (make-demo-slots emoji name nslot))
                        (cap   `((name . ,name) (emoji . ,emoji))))
                   (make-grouped-slot-marker
                    name cap slots lng lat 'coordinates prov name)))
               *demo-marker-seeds*))))

(define (make-demo-slots emoji name n)
  "Build a list of n stub slot alists for a demo capacity."
  (let loop ((i 0) (acc '()))
    (if (= i n)
        (reverse acc)
        (loop (+ i 1)
              (cons `((name . ,name) (emoji . ,emoji)) acc)))))

(define *map-markers* '())  ;; alist: (id . maplibre-marker-extern)

(define (clear-map-markers!)
  (for-each (lambda (pair) (%map-marker-remove (cdr pair))) *map-markers*)
  (set! *map-markers* '()))

;;; ── String helpers — %char-downcase and %string-downcase live earlier in
;;; this file; only %string-contains? is new here.
(define (%string-contains? hay needle)
  (let ((hn (string-length hay)) (nn (string-length needle)))
    (if (= nn 0) #t
        (let loop ((i 0))
          (cond
           ((> (+ i nn) hn) #f)
           ((string=? (substring hay i (+ i nn)) needle) #t)
           (else (loop (+ i 1))))))))

;;; ── Search ─────────────────────────────────────────────────────────────────
(define (map-search-markers query)
  "Substring (case-insensitive) match on capacity name + provider."
  (let ((needle (%string-downcase (or query ""))))
    (if (string=? needle "")
        '()
        (filter
         (lambda (m)
           (let* ((cap (gsm-capacity m))
                  (name (let ((p (and (pair? cap) (assq 'name cap))))
                          (if p (cdr p) "")))
                  (prov (or (gsm-provider m) "")))
             (or (%string-contains? (%string-downcase name) needle)
                 (%string-contains? (%string-downcase prov) needle))))
         *map-marker-data*))))

;;; ── Clustering ─────────────────────────────────────────────────────────────
;;; Ported from docs/free-assoc/src/lib/components/Map.svelte createClusters.
;;; Bucket markers by lat/lng cells of size clusterRadius / 2^(zoom-1).
;;; Single-marker buckets stay individual; multi-marker buckets become
;;; cluster-markers with the centroid as their position.

(define *cluster-radius* 50.0)
(define *cluster-max-zoom* 16.0)
(define *map-zoom* 1.8)

(define (compute-clusters markers zoom)
  (cond
   ((or (not *map-clustering?*)
        (> zoom *cluster-max-zoom*)
        (null? markers))
    markers)
   (else
    ;; Use integer zoom for expt — Hoot's expt with a fractional
    ;; exponent isn't reliable. Floors zoom; at zoom 1 bucket size is
    ;; the full cluster-radius (no halving yet).
    (let* ((z (max 1 (inexact->exact (floor zoom))))
           (distance (/ *cluster-radius* (expt 2 (- z 1))))
           (buckets (make-hashtable)))
      (for-each
       (lambda (m)
         (let* ((kl (inexact->exact (floor (+ 0.5 (/ (gsm-lat m) distance)))))
                (kg (inexact->exact (floor (+ 0.5 (/ (gsm-lng m) distance)))))
                (key (string-append (number->string kl) "_"
                                    (number->string kg)))
                (existing (or (hashtable-ref buckets key) '())))
           (hashtable-set! buckets key (cons m existing))))
       markers)
      (let loop ((keys (hashtable-keys buckets)) (acc '()))
        (if (null? keys)
            acc
            (let* ((k (car keys))
                   (bucket (hashtable-ref buckets k)))
              (if (null? (cdr bucket))
                  (loop (cdr keys) (cons (car bucket) acc))
                  (let* ((n (length bucket))
                         (sum-lat (apply + (map gsm-lat bucket)))
                         (sum-lng (apply + (map gsm-lng bucket)))
                         (avg-lat (/ sum-lat n))
                         (avg-lng (/ sum-lng n))
                         (total-slots
                          (apply + (map (lambda (m)
                                          (length (gsm-slots m)))
                                        bucket))))
                    (loop (cdr keys)
                          (cons (make-cluster-marker
                                 (string-append "cluster_" k)
                                 avg-lng avg-lat bucket total-slots n)
                                acc)))))))))))

(define (render-marker-to-map! m)
  "Build the DOM for a grouped-slot or cluster marker, hand it to
   maplibre, and stash the maplibre handle in *map-markers*."
  (let* ((sxml (marker-sxml m
                            (lambda (e)
                              (set! *map-selected* m)
                              (refresh!))))
         (el     (sxml->dom sxml))
         (lng    (if (cluster-marker? m) (cm-lng m) (gsm-lng m)))
         (lat    (if (cluster-marker? m) (cm-lat m) (gsm-lat m)))
         (id     (if (cluster-marker? m) (cm-id m)  (gsm-id m)))
         (handle (%map-make-marker *map-instance* el lng lat)))
    (set! *map-markers* (cons (cons id handle) *map-markers*))))

(define (populate-map-markers!)
  "Compute clusters for the current zoom and render the resulting marker
   set onto the map. Idempotent — tears down existing maplibre markers
   first. Call this whenever zoom changes or *map-marker-data* changes."
  (when *map-instance*
    (build-demo-markers!)
    (clear-map-markers!)
    (set! *map-zoom* (%map-get-zoom *map-instance*))
    (let ((visible (compute-clusters *map-marker-data* *map-zoom*)))
      (for-each render-marker-to-map! visible))))

(define (install-map-zoom-listener!)
  "Recluster on zoomend. Idempotent — installs at most once per mount."
  (when *map-instance*
    (%map-on *map-instance* "zoomend"
             (procedure->external/cached
              (lambda (e) (populate-map-markers!))))))

(define (ensure-map-mounted!)
  (let ((container (get-element-by-id "playnet-map")))
    (when container
      (if *map-instance*
          (%map-resize *map-instance*)
          (begin
            (set! *map-instance*
                  (%map-create container
                               "https://basemaps.cartocdn.com/gl/voyager-gl-style/style.json"
                               20.0 20.0 1.8
                               (if *map-globe?* 1 0)))
            ;; Globe must be set AFTER construction in maplibre 4.x.
            (when (and *map-instance* *map-globe?*)
              (%map-set-projection *map-instance* "globe"))))
      (window-set-timeout
       (procedure->external/cached
        (lambda ()
          (when *map-instance*
            (%map-resize *map-instance*)
            (install-map-zoom-listener!)
            (populate-map-markers!)
            (journey-redraw!))))
       120))))

(define (unmount-map!)
  (when *map-instance*
    (let ((m *map-instance*))
      ;; Null the global *first* so any listener callbacks that fire
      ;; during m.remove() see a #f instance and short-circuit.
      (set! *map-instance* #f)
      (set! *map-selected* #f)
      (clear-map-markers!)
      (%map-remove m))))

(define (schedule-map-mount!)
  (window-set-timeout
   (procedure->external/cached (lambda () (ensure-map-mounted!)))
   0))

(define (render)
  ;; Tear down the maplibre instance whenever we render a non-map view.
  ;; m.remove() is synchronous and fires JS teardown events that can
  ;; re-enter the vat mid-turn — defer to a setTimeout 0 so render
  ;; finishes cleanly first.
  (when (and *map-instance* (not (eq? *view* 'map)) (not *surface-map-leaf*))
    (window-set-timeout
     (procedure->external/cached (lambda () (unmount-map!)))
     0))
  (if (eq? *mode* 'outer)
      ;; Outer mode: single column, no IDE chrome.
      ;; The playnet REPL strip (log + prompt) only renders on the
      ;; "playnet" tab (*view* = 'home). Dashboard / federation /
      ;; calendar / inventory get clean full-height views. Identity is
      ;; no longer a view \u2014 it's an always-available dropdown anchored
      ;; in the action bar.
      `(div (@ (class "outer"))
            ,(render-tab-bar)
            ,(render-action-bar)
            ,@(render-session-plan-strip)
            ,(cond
              ((eq? *view* 'federation) (render-federation-view))
              ((eq? *view* 'surface) (render-surface-view))
              ((eq? *view* 'calendar) (render-calendar-view))
              ((eq? *view* 'inventory) (render-inventory-view))
              ((eq? *view* 'map) (render-map-view))
              ((eq? *view* 'contacts) (render-contacts-view))
              ((eq? *view* 'recipes) (render-recipes-view))
              ((eq? *view* 'priorities) (render-priorities-view))
              ((eq? *view* 'clock) (render-clock-view))
              (else (render-homepage)))
            ,@(if (eq? *view* 'home) (list (render-repl)) '())
            ,(render-identity-dropdown)
            ,(render-toasts))
      ;; Inner mode: full IDE with sidebar + code viewer
      `(div (@ (class "ide"))
            ,(render-sidebar)
            (div (@ (class "main"))
                 ,@(if *sidebar-collapsed*
                       (list `(span (@ (class "expand-tab")
                                       (click ,toggle-sidebar!))
                                    "\u00bb"))
                       '())
                 ,(render-tab-bar)
                 ,(render-action-bar)
                 ,(render-ui-widgets)
                 ,(render-repl))
            ,(render-code-viewer)
            ,(render-identity-dropdown)
            ,(render-toasts))))

(define (global-keydown event)
  (let ((key (keyboard-event-key event)))
    (cond
     ;; Escape on the surface zooms out one level.
     ((and (string=? key "Escape") (eq? *mode* 'outer) (eq? *view* 'surface))
      (prevent-default! event) (surface-zoom-out!))
     ((and (string=? key "e") (ctrl-or-cmd? event))
      (prevent-default! event) (toggle-sidebar! event))
     ((and (string=? key "l") (ctrl-or-cmd? event))
      (prevent-default! event) (set! *log* '())
      (when (eq? *mode* 'outer) (set! *outer-log* '()))
      (when (eq? *mode* 'inner) (org-save!))
      (refresh!) (scroll-to-bottom!))
     ((and (string=? key "k") (ctrl-or-cmd? event))
      (prevent-default! event) (focus-element! (get-element-by-id "expression"))))))

;;; ── Restore syntax mode preference ─────────────────────────────────────────
(let ((saved-mode (ls-get-item "pn.repl.syntax")))
  (when (and saved-mode (string=? saved-mode "lisp"))
    (set! *syntax-mode* 'lisp)))

;;; ── Restore persisted KERI identity hint ──────────────────────────────────
;;; This happens BEFORE org restoration because identity-aware code
;;; downstream may check *keri-identity*.
(load-keri-identity-hint!)
(load-keri-contacts!)
(load-keri-credentials!)
(seed-universal-commune-contact!)

;;; ── Restore persisted orgs from localStorage ──────────────────────────────
(let ((index (load-org-index)))
  (for-each
   (lambda (name)
     (when (string? name)
       (let* ((kp (if (has-preloaded-key-pair? name)
                      (get-preloaded-key-pair name)
                      (generate-key-pair)))
              (store (make-local-storage-store (string-append "playnet-" name))))
         (receive (vat org inbox incanter refs)
           (make-persistent-org name base-bindings store
                                #:persistence-registry *persistence-registry*)
           (set! *orgs* (cons (list name vat org inbox incanter kp refs) *orgs*))))))
   index)
  (unless (null? *orgs*)
    (set! *log* (cons `(span (@ (class "result-text"))
                             ,(string-append "Restored "
                                             (number->string (length *orgs*))
                                             " org(s) from browser storage.\n"))
                      *log*))))

;;; ── Restore calendar data ──────────────────────────────────────────────────
(load-calendar!)
;; Seed default availability + next-id if first load.
(when (null? *cal-user-events*)
  (set! *cal-availability*
        (map (lambda (day)
               (cal-make-avail-slot day (* 9 60) (* 17 60)))
             '(0 1 2 3 4)))
  (set! *cal-next-id* 100))

(refresh!)
(add-event-listener!/wrap (document-body) "keydown" global-keydown)

;;; ── Animation timer ─────────────────────────────────────────────────────
;;; Steps the signshifting cycles; render() calls render-homepage which
;;; reads the current cycle state. VDOM diff patches only changed text nodes.
;; Only step + refresh on the homepage view. Refreshing on other
;; outer views (identity / federation / calendar / inventory) wipes
;; uncontrolled form inputs during VDOM diff — e.g. typed AID prefix
;; in the recover form would vanish on the next 1s tick.
(let ((timer-callback (procedure->external
                       (lambda ()
                         (when (and (eq? *mode* 'outer)
                                    (eq? *view* 'home))
                           (homepage-step!)
                           (refresh!))))))
  (window-set-interval timer-callback 1000))


;;; ── OCapN gateway connection ────────────────────────────────────────────
;;; Connects to the playnet OCapN gateway via WebSocket CapTP.
;;; The lobby sturdyref is the single entry point for all services.

(define *connected?* #f)    ;; #t after OCapN lobby is live
(define *online-users* '()) ;; list of display names from ^presence
(define *lobby* #f)         ;; live reference to the gateway's ^lobby actor
(define *terminal-cap* #f)  ;; live reference to current ^terminal-session
(define *ocapn-vat* #f)     ;; vat for OCapN operations
(define *mycapn* #f)        ;; OCapN mycapn actor ref

;;; ── Toast notifications ────────────────────────────────────────────────
(define *toasts* '())
(define *toast-counter* 0)

(define* (show-toast! type title body #:optional (tag #f))
  (set! *toast-counter* (+ *toast-counter* 1))
  (let ((id *toast-counter*))
    ;; Replace existing toast with same tag (dedup)
    (when (and tag (not (string=? tag "")))
      (set! *toasts* (filter (lambda (t) (not (equal? (list-ref t 4) tag)))
                             *toasts*)))
    (set! *toasts* (cons (list id type title body (or tag "")) *toasts*))
    (refresh!)
    (window-set-timeout
     (procedure->external
      (lambda ()
        (set! *toasts* (filter (lambda (t) (not (= (car t) id))) *toasts*))
        (refresh!)))
     5000)))

(define (dismiss-toast! id)
  (set! *toasts* (filter (lambda (t) (not (= (car t) id))) *toasts*))
  (refresh!))

(define (render-toasts)
  (if (or (not (pair? *toasts*)) (null? *toasts*))
      '(span)
      `(div (@ (class "toast-container"))
            ,@(map (lambda (toast)
                     (let ((id    (list-ref toast 0))
                           (type  (list-ref toast 1))
                           (title (list-ref toast 2))
                           (body  (list-ref toast 3)))
                       `(div (@ (class ,(string-append "toast toast-"
                                                       (symbol->string type)))
                                (click ,(lambda (e) (dismiss-toast! id))))
                             (div (@ (class "toast-title")) ,title)
                             ,(if (and body (not (string=? body "")))
                                  `(div (@ (class "toast-body")) ,body)
                                  '(span)))))
                   *toasts*))))

(define* (notify! type title body #:optional (tag "") (url ""))
  "Show a notification — toast if page is focused, OS notification if
   backgrounded. Tag-based dedup: same tag replaces previous."
  (if (= (notif-page-visible?) 1)
      (show-toast! type title body tag)
      (notif-show! title (or body "") (or tag "") (or url ""))))

;;; ── Browser-side template interpolation (Hoot-compatible) ──────────────

(define (render-tpl tpl event)
  "Replace {field} placeholders in TPL with values from EVENT alist."
  (let loop ((s tpl) (out ""))
    (let ((i (string-index s #\{)))
      (if (not i)
          (string-append out s)
          (let ((j (string-index s #\} i)))
            (if (not j)
                (string-append out s)
                (let* ((field (string->symbol (substring s (+ i 1) j)))
                       (val (assq-ref event field))
                       (str (cond ((not val) "?")
                                  ((string? val) val)
                                  ((symbol? val) (symbol->string val))
                                  ((number? val) (number->string val))
                                  (else (call-with-output-string
                                          (lambda (p) (write val p)))))))
                  (loop (substring s (+ j 1))
                        (string-append out (substring s 0 i) str)))))))))

(define (notify-event! event)
  "Look up a browser-side notification template for EVENT alist and
   call notify!. For events that arrive via watchers/inbox."
  (let ((kind (assq-ref event 'kind)))
    (case kind
      ((ipex-grant)
       (notify! 'normal
                (render-tpl "Credential received" event)
                (render-tpl "{schema} from {issuer}" event)
                (render-tpl "ipex-grant-{said}" event)))
      ((direct-message)
       (notify! 'info
                (render-tpl "Message from {from-name}" event)
                (render-tpl "{content}" event)
                (render-tpl "msg-{from-name}" event)))
      (else
       (notify! 'info "playnet"
                (render-tpl "{kind}: {detail}" event) "")))))

;;; ── Reconnection state ─────────────────────────────────────────────────
(define *reconnecting?* #f)
(define *reconnect-attempts* 0)
(define *probe-pending?* #f)

;; The gateway sturdyref — auto-discovered from entry-points.json by
;; repl.js before WASM loads.  Override with ?gateway= URL param.
;; No hardcoded URLs or placeholders — everything comes from the JSON.
(define *gateway-sref* (url-param-gateway-sref))

;;; ── WebRTC peer-to-peer state ──────────────────────────────────────────
;;;
;;; *webrtc-peers* is an alist of (name . #(pc dc state)):
;;;   pc    — RTCPeerConnection (JS extern)
;;;   dc    — RTCDataChannel (JS extern), #f until open
;;;   state — 'connecting | 'open | 'closed

(define *webrtc-peers* '())
(define *ice-config*
  "{\"iceServers\":[{\"urls\":\"stun:stun.l.google.com:19302\"}]}")

(define (webrtc-peer-ref name)
  "Look up a WebRTC peer entry by name, or #f."
  (let ((entry (assoc name *webrtc-peers*)))
    (if entry (cdr entry) #f)))

(define (webrtc-peer-set! name entry)
  "Set or update a WebRTC peer entry. When the walkie is live, equip the pc
   with the mic + remote-audio sink — both primitives are idempotent, so no
   bookkeeping is needed: the single funnel is also the single equip point."
  (set! *webrtc-peers*
        (cons (cons name entry)
              (filter (lambda (p) (not (string=? (car p) name)))
                      *webrtc-peers*)))
  (when (and *walkie-joined?* (vector? entry))
    (walkie-equip-pc! (vector-ref entry 0) name)))

(define (webrtc-peer-remove! name)
  "Remove a WebRTC peer entry (and its audio sink, if any)."
  (rtc-drop-audio name)
  (set! *webrtc-peers*
        (filter (lambda (p) (not (string=? (car p) name)))
                *webrtc-peers*)))

;;; ── ^user-inbox — receives messages from the gateway ───────────────────

(define (^user-inbox _bcom)
  (methods
   ;; Presence broadcast from ^presence actor
   ((presence-update users)
    (set! *online-users* (if (list? users) users '()))
    (refresh!))

   ;; Direct message from another user (via introduce + <-np)
   ((new-message from-name content)
    (log-append! `(span (@ (class "output-text"))
                        ,(string-append "<" from-name "> "
                                        (call-with-output-string
                                          (lambda (p) (write content p)))
                                        "\n")))
    (notify-event! `((kind . direct-message)
                     (from-name . ,from-name)
                     (content . ,(call-with-output-string
                                   (lambda (p) (write content p))))))
    (refresh!))

   ;; Terminal output from server PTY
   ((term-data data)
    (when *terminal-obj*
      (term-write! *terminal-obj* data)))

   ;; Terminal session closed by server
   ((term-closed)
    (when *terminal-obj*
      (term-dispose! *terminal-obj*)
      (set! *terminal-obj* #f))
    (set! *terminal-cap* #f)
    (set! *terminal-active?* #f)
    (log-append! `(span (@ (class "info-text"))
                        "Terminal session closed.\n"))
    (update-code-viewer!)
    (refresh!))

   ;; A live chat message for the topic we're watching (gateway <-np).
   ;; The message is a denormalized alist; append iff it's the open topic
   ;; and not already shown (history + live can race on our own post).
   ((chat-message topic msg)
    (when (and *chat-topic* *active-scope*
               (equal? topic (string-append *active-scope* "/" *chat-topic*)))
      (let* ((m (if (vector? msg) (vector->list msg) msg))
             (id (and (pair? m) (assq-ref m 'id))))
        (unless (and id (%find (lambda (x) (equal? (assq-ref x 'id) id)) *chat-msgs*))
          (set! *chat-msgs* (append *chat-msgs* (list m)))
          (refresh!)))))

   ;; WebRTC signaling message from another peer (relayed by gateway)
   ((webrtc-signal from-name signal-type signal-data)
    (if *webrtc-netlayer*
        ;; Phase 2: forward to the OCapN netlayer actor
        (<-np *webrtc-netlayer* 'handle-signal from-name signal-type signal-data)
        ;; Phase 1 fallback: handle directly
        (match signal-type
          ('offer       (handle-webrtc-offer! from-name signal-data))
          ('answer      (handle-webrtc-answer! from-name signal-data))
          ('ice-candidate (handle-webrtc-ice! from-name signal-data))
          (_ #f))))

   ;; Notification from server (KERI events, planner alerts, etc.)
   ((notify type title body . rest)
    (let ((opts (if (pair? rest) (car rest) '())))
      (notify! type title body
               (or (assq-ref opts 'tag) "")
               (or (assq-ref opts 'url) ""))))))


(define *user-inbox* #f)  ;; our inbox actor ref (passed to gateway for callbacks)

;;; ── Helper: call lobby method with error handling ──────────────────────

(define (lobby-call method . args)
  "Call a lobby method, catching errors."
  (when (and *lobby* *ocapn-vat*)
    (with-vat *ocapn-vat*
      (on (apply <- *lobby* method args)
          (lambda (result) result)
          #:catch
          (lambda (err)
            (log-append! `(span (@ (class "error-text"))
                                ,(string-append "Gateway error: "
                                                (call-with-output-string
                                                  (lambda (p) (write err p)))
                                                "\n")))
            (refresh!))))))

(define (announce-presence!)
  "Announce our display name to the gateway. Prefer the authenticated
   session cap — its announce also seeds the notification recipient
   registry with our AID (per-identity routing); the bare lobby is the
   anonymous fallback when we have no session yet."
  (when (and *lobby* *current-org-name* *user-inbox*)
    (with-vat *ocapn-vat*
      (on (<- (or *keri-session* *lobby*) 'announce *current-org-name* *user-inbox*)
          (lambda (users)
            (set! *online-users* (if (list? users) users '()))
            ;; Install WebRTC netlayer if not yet installed
            (when (and *mycapn* (not *webrtc-netlayer*))
              (let ((nl (spawn ^webrtc-netlayer *lobby* *current-org-name*)))
                (set! *webrtc-netlayer* nl)
                (<-np *mycapn* 'install-netlayer nl)
                (log-append! `(span (@ (class "info-text"))
                                    "WebRTC netlayer installed — P2P ready.\n"))))
            (refresh!))))))

(define (register-all-keys!)
  "No-op in OCapN mode — keys are not registered separately."
  #f)

(define-foreign crypto-random-uuid
  "crypto" "randomUUID"
  -> (ref string))

(define (device-id)
  (let ((stored (ls-get-item "pn.device.id")))
    (if (and (string? stored) (not (string=? stored "")))
        stored
        (let ((id (crypto-random-uuid)))
          (ls-set-item "pn.device.id" id)
          id))))

(define (register-push-subscription! vapid-key)
  "Subscribe to Web Push using VAPID-KEY and register with the gateway."
  (when (and (not (string=? vapid-key ""))
             (string=? (notif-has-permission) "granted")
             *lobby*)
    (let ((dev-id (device-id)))
      (%push-get-subscription
       (procedure->external
        (lambda (existing-json)
          ;; Prefer the session cap so the push binding is keyed to our
          ;; AID in the recipient registry; fall back to the bare lobby.
          (if (and (string? existing-json) (not (string=? existing-json "")))
              (with-vat *ocapn-vat*
                (<-np (or *keri-session* *lobby*) 'register-push dev-id existing-json))
              (%push-subscribe!
               vapid-key
               (procedure->external
                (lambda (new-json)
                  (when (and (string? new-json) (not (string=? new-json "")))
                    (with-vat *ocapn-vat*
                      (<-np (or *keri-session* *lobby*) 'register-push dev-id new-json)))))))))))))


;;; ── ^webrtc-captp-io — CapTP message I/O over a DataChannel ────────────
;;;
;;; Follows the same pattern as ^websocket-captp-io from Goblins:
;;; wraps a DataChannel in a ^read-write-io actor, provides
;;; read-message (Syrup decode) and write-message (Syrup encode).
;;;
(define-record-type <datachannel>
  (wrap-datachannel extern deq-ch)
  datachannel?
  (extern unwrap-datachannel)
  (deq-ch datachannel-deq-ch))

(define (open-datachannel dc-extern)
  "Wrap a JS DataChannel extern in a <datachannel> record with
   an async delivery channel for incoming messages."
  (define-values (enq-ch deq-ch stopped?)
    (spawn-delivery-agent))
  (define (on-message data)
    (put-message enq-ch (array-buffer->bytevector data)))
  (define (on-close)
    (put-message enq-ch the-eof-object)
    (signal-condition! stopped?))
  (rtc-on-message dc-extern (procedure->external on-message))
  (rtc-on-close dc-extern (procedure->external on-close))
  (wrap-datachannel dc-extern deq-ch))

(define (close-datachannel dc)
  (rtc-close (unwrap-datachannel dc)))

(define (datachannel-send dc data)
  (rtc-send (unwrap-datachannel dc)
            (bytevector->uint8-array data)))

(define (datachannel-receive dc)
  (get-message (datachannel-deq-ch dc)))

(define (^webrtc-captp-io _bcom dc)
  "CapTP message I/O actor over a WebRTC DataChannel.
   Provides read-message and write-message matching the interface
   that CapTP expects from a netlayer connection."
  (let ((io (spawn ^read-write-io dc #:cleanup close-datachannel)))
    (methods
     ((read-message unmarshallers)
      (<- io 'read
          (lambda (dc)
            (let ((data (datachannel-receive dc)))
              (if (eof-object? data)
                  the-eof-object
                  (syrup-decode data #:unmarshallers unmarshallers))))))
     ((write-message msg marshallers)
      (<-np io 'write
            (lambda (dc)
              (let ((bv (syrup-encode msg #:marshallers marshallers)))
                (datachannel-send dc bv)
                #t)))))))

;;; ── walkie audio: rides the netlayer's peer mesh (glare/ICE already done)
;;; The mic is one shared track, equipped onto each peer connection AT
;;; CREATION (so it rides the initial offer — no renegotiation). PTT just
;;; toggles its `enabled`. Remote tracks play through a per-peer <audio>.
;;; This is the CO-PRESENT layer; the burst→transcript walkie (chat notes)
;;; is the mesh-wide one. NOTE: peers connected before you acquire the mic
;;; won't carry your voice until they reconnect — a v1 limit (no manual
;;; renegotiation yet).
(define *walkie-joined?* #f)
(define (walkie-equip-pc! pc name)
  "If the mic is live, add it to PC and route PC's remote audio to a sink."
  (when *walkie-joined?*
    (rtc-add-mic pc)
    (rtc-on-remote-audio pc name)))
(define (walkie-join!)
  "Acquire the mic (permission prompt), then future peer connections carry
   audio. PTT stays silent until held."
  (rtc-mic-get
   (procedure->external
    (lambda (ok)
      (set! *walkie-joined?* (= ok 1))
      (refresh!)))))
;; leave the live layer: silence the mic, drop the membership. The note
;; record is unaffected — speaking still notes; it just stops transmitting.
(define (walkie-leave!)
  (rtc-mic-enabled 0)
  (set! *walkie-joined?* #f)
  (refresh!))

;;; ── ^webrtc-netlayer — OCapN netlayer over WebRTC DataChannels ─────────
;;;
;;; A proper OCapN netlayer that spawn-mycapn can use.  After the gateway
;;; lobby is enlivened over WebSocket, this netlayer is installed via
;;; (<- mycapn 'install-netlayer webrtc-nl).
;;;
;;; Signaling (SDP offer/answer + ICE candidates) flows through the
;;; gateway's lobby 'signal method.  Data flows directly over WebRTC
;;; DataChannels (DTLS-encrypted, peer-to-peer).
;;;
;;; Peer identity is the display name (from ^presence announce).
;;; Peer location: (make-ocapn-peer 'webrtc display-name hints)

(define *webrtc-netlayer* #f)  ;; set after install

(define (^webrtc-netlayer _bcom lobby-ref our-name)
  "Spawn a WebRTC netlayer.
   lobby-ref: live reference to the gateway's ^lobby actor (for signaling).
   our-name: our display name (peer identity for WebRTC)."
  (define-values (conn-establisher-vow conn-establisher-resolver)
    (spawn-promise-and-resolver))
  (define our-location
    (make-ocapn-peer 'webrtc our-name (hashmap)))

  ;; Pending incoming connections: name -> (pc event-ch)
  ;; When a remote peer sends an offer, we create a PeerConnection,
  ;; do the answer dance, and when the DataChannel opens, we wrap it
  ;; in ^webrtc-captp-io and call the conn-establisher.
  (define *pending-incoming* '())

  (define (signal-peer! target-name signal-type signal-data)
    "Send a signaling message to a remote peer via the gateway."
    (<-np lobby-ref 'signal target-name our-name signal-type signal-data))

  (define (setup-ice! pc target-name)
    "Forward local ICE candidates to the target peer."
    (rtc-on-ice-candidate
     pc
     (procedure->external
      (lambda (candidate-json)
        (signal-peer! target-name 'ice-candidate candidate-json)))))

  (define (handle-incoming-offer! from-name sdp-json)
    "Handle an SDP offer from a remote peer wanting to connect."
    ;; Glare: lexicographically greater name is always the offerer.
    (unless (string>? our-name from-name)
      (let ((pc (rtc-create-peer-connection *ice-config*)))
        ;; Track this pending connection
        (set! *pending-incoming*
              (cons (cons from-name pc) *pending-incoming*))

        (setup-ice! pc from-name)

        ;; When remote creates a DataChannel, we receive it here
        (rtc-on-data-channel
         pc
         (procedure->external
          (lambda (dc-extern)
            ;; Wait for DataChannel to open, then wrap and notify CapTP
            (rtc-on-open
             dc-extern
             (procedure->external
              (lambda ()
                (let ((dc (open-datachannel dc-extern))
                      (remote-peer (make-ocapn-peer 'webrtc from-name (hashmap))))
                  ;; Notify CapTP of the new incoming connection
                  (<-np conn-establisher-vow
                        (spawn ^webrtc-captp-io dc)
                        #f)
                  ;; Also update Phase 1 state for UI
                  (webrtc-peer-set! from-name
                                    (vector pc dc-extern 'open))
                  (log-append!
                   `(span (@ (class "info-text"))
                          ,(string-append "WebRTC connected to "
                                          from-name ".\n")))
                  (refresh!))))))))

        ;; Set remote description and create answer
        (rtc-set-remote-description pc sdp-json)
        (rtc-create-answer
         pc
         (procedure->external
          (lambda (answer-json)
            (signal-peer! from-name 'answer answer-json)))))))

  (define (handle-incoming-answer! from-name sdp-json)
    "Handle an SDP answer — complete outgoing connection handshake."
    (let ((entry (webrtc-peer-ref from-name)))
      (when entry
        (rtc-set-remote-description (vector-ref entry 0) sdp-json))))

  (define (handle-incoming-ice! from-name candidate-json)
    "Handle an incoming ICE candidate."
    (let ((entry (webrtc-peer-ref from-name)))
      (when entry
        (rtc-add-ice-candidate (vector-ref entry 0) candidate-json)))
    ;; Also check pending incoming connections
    (let ((pending (assoc from-name *pending-incoming*)))
      (when pending
        (rtc-add-ice-candidate (cdr pending) candidate-json))))

  (methods
   ((netlayer-name) 'webrtc)

   ((self-location? other)
    (and (eq? (ocapn-peer-transport other) 'webrtc)
         (equal? (ocapn-peer-designator other) our-name)))

   ((our-location) our-location)

   ((setup conn-establisher)
    (<-np conn-establisher-resolver 'fulfill conn-establisher))

   ((connect-to remote-peer)
    ;; Initiate an outgoing WebRTC connection to a remote peer
    (match remote-peer
      (($ <ocapn-peer> 'webrtc target-name _)
       ;; Glare: only the greater name initiates
       (if (string>? our-name target-name)
           ;; We are the offerer
           (let ((pc (rtc-create-peer-connection *ice-config*)))
             (webrtc-peer-set! target-name (vector pc #f 'connecting))
             (setup-ice! pc target-name)

             ;; Create the DataChannel (offerer creates it)
             (let ((dc-extern (rtc-create-data-channel pc "ocapn")))
               (rtc-on-open
                dc-extern
                (procedure->external
                 (lambda ()
                   (let ((dc (open-datachannel dc-extern)))
                     (webrtc-peer-set! target-name
                                       (vector pc dc-extern 'open))
                     (log-append!
                      `(span (@ (class "info-text"))
                             ,(string-append "WebRTC connected to "
                                             target-name ".\n")))
                     (refresh!)
                     ;; Fulfill: tell CapTP about the new connection
                     (<-np conn-establisher-vow
                           (spawn ^webrtc-captp-io dc)
                           remote-peer)))))

               ;; Create and send the SDP offer
               (rtc-create-offer
                pc
                (procedure->external
                 (lambda (offer-json)
                   (signal-peer! target-name 'offer offer-json))))))
           ;; We are not the offerer — send an offer-request so the
           ;; remote peer (who has the greater name) initiates.
           (signal-peer! target-name 'offer-request "")))
      (($ <ocapn-peer> transport _ _)
       (error "mismatched netlayer" transport 'webrtc))))

   ;; Handle signaling messages forwarded from ^user-inbox
   ((handle-signal from-name signal-type signal-data)
    (match signal-type
      ('offer         (handle-incoming-offer! from-name signal-data))
      ('answer        (handle-incoming-answer! from-name signal-data))
      ('ice-candidate (handle-incoming-ice! from-name signal-data))
      ('offer-request
       ;; Remote peer wants us to offer (we must be the greater name).
       ;; Initiate the connection from our side.
       (when (string>? our-name from-name)
         (let ((pc (rtc-create-peer-connection *ice-config*)))
           (webrtc-peer-set! from-name (vector pc #f 'connecting))
           (setup-ice! pc from-name)
           (let ((dc-extern (rtc-create-data-channel pc "ocapn")))
             (rtc-on-open
              dc-extern
              (procedure->external
               (lambda ()
                 (let ((dc (open-datachannel dc-extern))
                       (remote-peer (make-ocapn-peer 'webrtc from-name (hashmap))))
                   (webrtc-peer-set! from-name (vector pc dc-extern 'open))
                   (log-append!
                    `(span (@ (class "info-text"))
                           ,(string-append "WebRTC connected to "
                                           from-name ".\n")))
                   (refresh!)
                   (<-np conn-establisher-vow
                         (spawn ^webrtc-captp-io dc)
                         remote-peer)))))
             (rtc-create-offer
              pc
              (procedure->external
               (lambda (offer-json)
                 (signal-peer! from-name 'offer offer-json))))))))
      (_ #f)))))

(define (on-connected! lobby-ref msg)
  "Common post-connect setup for both initial and reconnect."
  (set! *lobby* lobby-ref)
  (set! *connected?* #t)
  (log-append! `(span (@ (class "result-text"))
                      ,(string-append msg "\n")))
  (on (<- lobby-ref 'who)
      (lambda (users)
        (set! *online-users* (if (list? users) users '()))
        (refresh!)))
  (on (<- lobby-ref 'planner)
      (lambda (cap)
        (set! *planner-cap* cap)
        (planner-fetch-scope-list!))
      #:catch (lambda (err) #f))
  (when *current-org-name*
    (announce-presence!))
  (when (string=? (notif-has-permission) "default")
    (notif-request-permission!))
  (on (<- lobby-ref 'vapid-public-key)
      (lambda (vk)
        (when (and (string? vk) (not (string=? vk "")))
          (register-push-subscription! vk)))
      #:catch (lambda (err) #f))
  (refresh!))

;; Set up OCapN vat + WebSocket netlayer + mycapn
(set! *ocapn-vat* (spawn-vat #:name "ocapn"))

(let ((ws-netlayer (with-vat *ocapn-vat*
                     (spawn ^websocket-netlayer))))

  (set! *mycapn* (with-vat *ocapn-vat*
                   (spawn-mycapn ws-netlayer)))

  ;; Create our inbox actor
  (set! *user-inbox* (with-vat *ocapn-vat*
                       (spawn ^user-inbox)))

  ;; Register OCapN callbacks for JS speech/express
  (ocapn-set-transcribe-callback!
   (procedure->external
    (lambda (audio-b64 on-result)
      (when *lobby*
        (with-vat *ocapn-vat*
          (on (<- *lobby* 'transcribe audio-b64)
              (lambda (transcript)
                (ocapn-call-callback! on-result
                                      (if (string? transcript) transcript "")))
              #:catch
              (lambda errs
                (ocapn-call-callback! on-result ""))))))))

  (ocapn-set-express-callback!
   (procedure->external
    (lambda (nl-text on-result)
      (when *lobby*
        (with-vat *ocapn-vat*
          (on (<- *lobby* 'express nl-text)
              (lambda (expr)
                (ocapn-call-callback! on-result
                                      (if (string? expr) expr "")))
              #:catch
              (lambda errs
                (ocapn-call-callback! on-result ""))))))))

  ;; Enliven the gateway sturdyref (skip if not configured)
  (if (or (not (string? *gateway-sref*))
          (string=? *gateway-sref* ""))
      (begin
        (log-append! `(span (@ (class "info-text"))
                            "No gateway configured — running local-only.\n"))
        (refresh!))
      (begin
        (log-append! `(span (@ (class "info-text"))
                            "Connecting to OCapN gateway...\n"))
        (refresh!)
        (with-vat *ocapn-vat*
          (on (<- *mycapn* 'enliven (string->ocapn-id *gateway-sref*))
              (lambda (lobby-ref)
                (on-connected! lobby-ref
                               "Connected to OCapN gateway. Create an org and enter it."))
              #:catch
              (lambda (err)
                (log-append! `(span (@ (class "error-text"))
                                    ,(string-append "Could not connect to gateway: "
                                                    (call-with-output-string
                                                      (lambda (p) (write err p)))
                                                    "\n")))
                (refresh!)))))))

;;; ── Visibility-aware heartbeat + reconnection ──────────────────────────

(define (gateway-reconnect!)
  (when (not *reconnecting?*)
    (set! *reconnecting?* #t)
    (set! *connected?* #f)
    (set! *lobby* #f)
    (set! *planner-cap* #f)
    (set! *terminal-cap* #f)
    (refresh!)
    (let ((delay (min 30000 (* 1000 (expt 2 *reconnect-attempts*)))))
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "Reconnecting in "
                                          (number->string (quotient delay 1000))
                                          "s...\n")))
      (refresh!)
      (window-set-timeout
       (procedure->external
        (lambda ()
          (set! *reconnect-attempts* (+ *reconnect-attempts* 1))
          (let ((ws-nl (with-vat *ocapn-vat*
                         (spawn ^websocket-netlayer))))
            (set! *mycapn* (with-vat *ocapn-vat*
                             (spawn-mycapn ws-nl)))
            (with-vat *ocapn-vat*
              (on (<- *mycapn* 'enliven (string->ocapn-id *gateway-sref*))
                  (lambda (lobby-ref)
                    (set! *reconnecting?* #f)
                    (set! *reconnect-attempts* 0)
                    (on-connected! lobby-ref "Reconnected to gateway."))
                  #:catch
                  (lambda (err)
                    (set! *reconnecting?* #f)
                    (gateway-reconnect!)))))))
       delay))))

(define (heartbeat-probe!)
  (when (and *lobby* *connected?* (not *reconnecting?*) (not *probe-pending?*))
    (set! *probe-pending?* #t)
    (let ((timed-out? #t))
      (window-set-timeout
       (procedure->external
        (lambda ()
          (when timed-out?
            (set! *probe-pending?* #f)
            (gateway-reconnect!))))
       3000)
      (with-vat *ocapn-vat*
        (on (<- *lobby* 'who)
            (lambda (result)
              (set! timed-out? #f)
              (set! *probe-pending?* #f)
              (set! *online-users* (if (list? result) result '()))
              (refresh!))
            #:catch
            (lambda (err)
              (set! timed-out? #f)
              (set! *probe-pending?* #f)
              (gateway-reconnect!)))))))

(on-visibility-change!
 (procedure->external
  (lambda (visible?)
    (when (= visible? 1)
      (heartbeat-probe!)))))

(on-online!
 (procedure->external
  (lambda ()
    (heartbeat-probe!))))

;;; ── WebRTC peer-to-peer connection management ─────────────────────────
;;;
;;; After connecting to the gateway via WebSocket, browsers can establish
;;; direct WebRTC DataChannel connections for P2P messaging.  The gateway
;;; relays only signaling (SDP offers/answers, ICE candidates).
;;;
;;; Glare resolution: when both peers try to connect simultaneously,
;;; the peer whose name is lexicographically greater is the offerer.
;;; If a peer receives an offer but already sent one and is the "greater"
;;; name, it ignores the incoming offer.

(define (setup-ice-forwarding! pc target-name)
  "Forward local ICE candidates to the target peer via the gateway."
  (rtc-on-ice-candidate
   pc
   (procedure->external
    (lambda (candidate-json)
      (when *lobby*
        (with-vat *ocapn-vat*
          (<-np *lobby* 'signal target-name *current-org-name*
                'ice-candidate candidate-json)))))))

(define (setup-data-channel-handlers! dc peer-name)
  "Wire up open/message/close handlers for a DataChannel."
  (rtc-on-open
   dc
   (procedure->external
    (lambda ()
      (let ((entry (webrtc-peer-ref peer-name)))
        (when entry
          (webrtc-peer-set! peer-name (vector (vector-ref entry 0) dc 'open))))
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "WebRTC connected to " peer-name ".\n")))
      (refresh!))))

  (rtc-on-message
   dc
   (procedure->external
    (lambda (data)
      ;; For now, log received binary messages as text.
      ;; Phase 2 will route these through OCapN CapTP.
      (log-append! `(span (@ (class "output-text"))
                          ,(string-append "[webrtc:" peer-name "] data received\n")))
      (refresh!))))

  (rtc-on-close
   dc
   (procedure->external
    (lambda ()
      (webrtc-peer-remove! peer-name)
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "WebRTC disconnected from " peer-name ".\n")))
      (refresh!)))))

(define (establish-webrtc! target-name)
  "Initiate a WebRTC connection to target-name.
   Creates a PeerConnection, DataChannel, and sends an SDP offer
   through the gateway's signaling relay."
  (when (and *lobby* *current-org-name*
             (not (webrtc-peer-ref target-name)))
    ;; Glare check: only the lexicographically greater name initiates
    (when (string>? *current-org-name* target-name)
      (let ((pc (rtc-create-peer-connection *ice-config*)))
        (webrtc-peer-set! target-name (vector pc #f 'connecting))

        ;; Forward ICE candidates to remote peer
        (setup-ice-forwarding! pc target-name)

        ;; Create the DataChannel (offerer creates it)
        (let ((dc (rtc-create-data-channel pc "ocapn")))
          (setup-data-channel-handlers! dc target-name)

          ;; Create and send the SDP offer
          (rtc-create-offer
           pc
           (procedure->external
            (lambda (offer-json)
              (when *lobby*
                (with-vat *ocapn-vat*
                  (<-np *lobby* 'signal target-name *current-org-name*
                        'offer offer-json)))))))))))

(define (handle-webrtc-offer! from-name sdp-json)
  "Handle an incoming SDP offer — create answer and send it back."
  ;; Glare: if we are the greater name, we should be the offerer — ignore.
  (unless (string>? *current-org-name* from-name)
    (let ((existing (webrtc-peer-ref from-name)))
      ;; Clean up any stale connection
      (when existing
        (rtc-close-pc (vector-ref existing 0))
        (webrtc-peer-remove! from-name)))

    (let ((pc (rtc-create-peer-connection *ice-config*)))
      (webrtc-peer-set! from-name (vector pc #f 'connecting))

      ;; Forward ICE candidates
      (setup-ice-forwarding! pc from-name)

      ;; Listen for the DataChannel (answerer receives it)
      (rtc-on-data-channel
       pc
       (procedure->external
        (lambda (dc)
          (let ((entry (webrtc-peer-ref from-name)))
            (when entry
              (webrtc-peer-set! from-name (vector pc dc 'connecting))))
          (setup-data-channel-handlers! dc from-name))))

      ;; Set remote description (the offer) and create answer
      (rtc-set-remote-description pc sdp-json)
      (rtc-create-answer
       pc
       (procedure->external
        (lambda (answer-json)
          (when *lobby*
            (with-vat *ocapn-vat*
              (<-np *lobby* 'signal from-name *current-org-name*
                    'answer answer-json)))))))))

(define (handle-webrtc-answer! from-name sdp-json)
  "Handle an incoming SDP answer — complete the handshake."
  (let ((entry (webrtc-peer-ref from-name)))
    (when entry
      (rtc-set-remote-description (vector-ref entry 0) sdp-json))))

(define (handle-webrtc-ice! from-name candidate-json)
  "Handle an incoming ICE candidate."
  (let ((entry (webrtc-peer-ref from-name)))
    (when entry
      (rtc-add-ice-candidate (vector-ref entry 0) candidate-json))))

(define (webrtc-send! target-name data)
  "Send data over an open WebRTC DataChannel to target-name.
   Returns #t on success, #f if no open connection."
  (let ((entry (webrtc-peer-ref target-name)))
    (if (and entry (eq? (vector-ref entry 2) 'open))
        (begin (rtc-send (vector-ref entry 1) data) #t)
        #f)))

(define (webrtc-disconnect! target-name)
  "Close a WebRTC connection to target-name."
  (let ((entry (webrtc-peer-ref target-name)))
    (when entry
      (when (vector-ref entry 1)
        (rtc-close (vector-ref entry 1)))
      (rtc-close-pc (vector-ref entry 0))
      (webrtc-peer-remove! target-name))))
