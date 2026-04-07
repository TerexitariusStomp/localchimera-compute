;;; module/weave/browser.scm — Weave WASM entry point
;;;
;;; Compiled to weave/weave.wasm via:
;;;   guild compile-wasm -L module --bundle -o weave/weave.wasm module/weave/browser.scm
;;;
;;; Loaded by weave/weave.js via:
;;;   await Scheme.load_main("weave.wasm", { user_imports: {...} })
;;;
;;; Structure mirrors browser/repl.scm: FFI bindings → actors → render loop.

(use-modules (hoot ffi)
             (ice-9 match)
             (srfi srfi-9)
             (goblins)
             (goblins actor-lib methods)
             (weave ui ffi)   ; shared DOM bindings; also imported by (weave ui join)
             (weave ui join)
             (weave ui room))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 1: Console + DOM FFI bindings (from weave.js user_imports)
;;; ═══════════════════════════════════════════════════════════════════════════
;;;
;;; DEBUGGING NOTE — the JS/Scheme error boundary
;;; ───────────────────────────────────────────────
;;; JS exceptions thrown inside async JS functions DO NOT propagate into
;;; Scheme as Scheme exceptions. Hoot's Scheme call stack and the Wasm/JS
;;; exception systems are separate. A try/catch or with-exception-handler in
;;; Scheme will NOT catch an error thrown by, e.g., livekit.connect.
;;;
;;; Pattern for handling async JS errors:
;;;   1. JS wraps async ops in try/catch and calls _callbacks.onError(src, msg)
;;;   2. Scheme's `on-livekit-error` receives the error and updates UI state
;;;   3. Use (console-error "msg") from Scheme to write diagnostics to DevTools
;;;
;;; For synchronous FFI calls that can fail, JS returns a sentinel string:
;;;   "ERR:HTTP-<status>" | "ERR:NET" | "ERR:PARSE"
;;; Scheme checks: (string-prefix? "ERR:" resp-str)

;; ── Console (Scheme → browser DevTools) ──────────────────────────────────────
(define-foreign console-log   "console" "log"   (ref string) -> none)
(define-foreign console-warn  "console" "warn"  (ref string) -> none)
(define-foreign console-error "console" "error" (ref string) -> none)

;; Convenience: log a label + value by converting to string
;; (debug-log "state" *screen*) → console.log "[weave] state: room"
(define (debug-log label val)
  (console-log (string-append label ": " (if (string? val) val (object->string val)))))

;; DOM — document
;; (get-element-by-id is provided by (weave ui ffi) so it can be shared with
;; (weave ui join) without tripping Hoot's library-group cross-module check.)
(define-foreign document-body    "document" "body"          -> (ref null extern))
(define-foreign make-text-node   "document" "createTextNode" (ref string) -> (ref null extern))
(define-foreign make-element     "document" "createElement"  (ref string) -> (ref null extern))
(define-foreign make-element-ns  "document" "createElementNS" (ref string) (ref string) -> (ref null extern))
(define-foreign %make-tree-walker "document" "createTreeWalker" (ref null extern) i32 -> (ref null extern))
(define (make-tree-walker root) (%make-tree-walker root 5))

;; DOM — events
;; (prevent-default! is provided by (weave ui ffi).)
(define-foreign stop-propagation!     "event" "stopPropagation" (ref null extern) -> none)
(define-foreign keyboard-event-key    "event" "keyboardKey"      (ref null extern) -> (ref string))

;; DOM — element
;; (element-value and set-element-value! are provided by (weave ui ffi).)
(define-foreign append-child!         "element" "appendChild"     (ref null extern) (ref null extern) -> (ref null extern))
(define-foreign remove!               "element" "remove"          (ref null extern) -> none)
(define-foreign replace-with!         "element" "replaceWith"     (ref null extern) (ref null extern) -> none)
(define-foreign set-attribute!        "element" "setAttribute"    (ref null extern) (ref string) (ref string) -> none)
(define-foreign remove-attribute!     "element" "removeAttribute" (ref null extern) (ref string) -> none)
(define-foreign add-event-listener!   "element" "addEventListener" (ref null extern) (ref string) (ref null extern) -> none)
(define-foreign remove-event-listener! "element" "removeEventListener" (ref null extern) (ref string) (ref null extern) -> none)
(define-foreign set-style!            "element" "setStyle"        (ref null extern) (ref string) (ref string) -> none)
(define-foreign focus-element!        "element" "focus"           (ref null extern) -> none)

;; TreeWalker
(define-foreign current-node    "treeWalker" "currentNode"    (ref null extern) -> (ref null extern))
(define-foreign set-current-node! "treeWalker" "setCurrentNode" (ref null extern) (ref null extern) -> (ref null extern))
(define-foreign next-node!      "treeWalker" "nextNode"       (ref null extern) -> (ref null extern))
(define-foreign first-child!    "treeWalker" "firstChild"     (ref null extern) -> (ref null extern))
(define-foreign next-sibling!   "treeWalker" "nextSibling"    (ref null extern) -> (ref null extern))

;; Fetch (for token API calls)
(define-foreign %fetch-json "fetch" "postJSON"
  (ref string) (ref string) -> (ref string))
;; weave.js bridges async fetch to synchronous by calling back into WASM

;; URL params
(define-foreign url-param-get "urlParams" "get"
  (ref string) -> (ref string))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 2: LiveKit FFI bindings
;;; ═══════════════════════════════════════════════════════════════════════════

;; Connect / disconnect
(define-foreign %livekit-connect "livekit" "connect"
  (ref string) (ref string) (ref null extern) -> none)
;; livekit.connect(url, token, callbackObj) — async, fires callbacks on events

(define-foreign livekit-disconnect "livekit" "disconnect"
  -> none)

;; Local tracks
(define-foreign %livekit-enable-camera  "livekit" "enableCamera"  -> none)
(define-foreign %livekit-disable-camera "livekit" "disableCamera" -> none)
(define-foreign %livekit-enable-mic     "livekit" "enableMic"     -> none)
(define-foreign %livekit-disable-mic    "livekit" "disableMic"    -> none)
(define-foreign %livekit-share-screen   "livekit" "shareScreen"   -> none)
(define-foreign %livekit-stop-screen    "livekit" "stopScreenShare" -> none)

;; Track attachment (attach LiveKit track element to a DOM container)
(define-foreign livekit-attach-track "livekit" "attachTrack"
  (ref null extern) (ref string) -> none)
;; livekit.attachTrack(track, tile-id) — finds the tile div and appends the element

(define-foreign livekit-detach-track "livekit" "detachTrack"
  (ref null extern) -> none)

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 3: Virtual DOM (copied from browser/repl.scm)
;;; ═══════════════════════════════════════════════════════════════════════════

(define (attr-value? x) (or (string? x) (boolean? x)))

(define (set-attribute!* elem name val)
  (if (boolean? val)
      (if val
          (set-attribute! elem name name)
          (remove-attribute! elem name))
      (set-attribute! elem name val)))

(define (add-event-listener!/wrap elem name proc)
  (add-event-listener! elem name proc))

(define *svg-ns* "http://www.w3.org/2000/svg")
(define *svg-tags*
  '(svg g path circle rect line polyline polygon text defs marker
    ellipse use clipPath mask pattern image foreignObject))
(define (svg-tag? tag) (memq tag *svg-tags*))
(define *in-svg* #f)

(define (sxml->dom exp)
  (match exp
    ((? string? str) (make-text-node str))
    (((? symbol? tag) . body)
     (let* ((entering-svg (and (not *in-svg*) (eq? tag 'svg)))
            (use-ns (or *in-svg* (eq? tag 'svg)))
            (elem (if use-ns
                      (make-element-ns *svg-ns* (symbol->string tag))
                      (make-element (symbol->string tag)))))
       (define (add-children children)
         (let ((prev-svg *in-svg*))
           (when entering-svg (set! *in-svg* #t))
           (for-each (lambda (child) (append-child! elem (sxml->dom child))) children)
           (set! *in-svg* prev-svg)))
       (match body
         ((('@ . attrs) . children)
          (for-each (lambda (attr)
                      (match attr
                        (((? symbol? name) (? attr-value? val))
                         (set-attribute!* elem (symbol->string name) val))
                        (((? symbol? name) (? procedure? proc))
                         (add-event-listener!/wrap elem (symbol->string name) proc))))
                    attrs)
          (add-children children))
         (children (add-children children)))
       elem))))

;; Virtual DOM diff/patch — full implementation from repl.scm
(define (virtual-dom-render parent old new)
  (cond
   ((equal? old new) (if #f #f))

   ;; New tree where there was nothing
   ((not old)
    (let ((parent-node (or parent (document-body))))
      (let loop ((children (if (and (pair? new) (symbol? (car new)))
                               (list new)
                               (if (list? new) new (list new)))))
        (unless (null? children)
          (append-child! parent-node (sxml->dom (car children)))
          (loop (cdr children))))))

   ;; Both are strings
   ((and (string? old) (string? new))
    (unless (equal? old new)
      (let ((walker (make-tree-walker parent)))
        (let loop ()
          (let ((node (next-node! walker)))
            (when node
              (replace-with! node (make-text-node new))))))))

   ;; Both are elements — diff them
   ((and (pair? old) (pair? new)
         (symbol? (car old)) (symbol? (car new))
         (eq? (car old) (car new)))
    ;; Attributes: handled by re-render (simple approach for MVP)
    ;; Children: recurse positionally
    (let* ((old-children (if (and (pair? (cdr old))
                                  (pair? (cadr old))
                                  (eq? (caar (cdr old)) '@))
                             (cddr old)
                             (cdr old)))
           (new-children (if (and (pair? (cdr new))
                                  (pair? (cadr new))
                                  (eq? (caar (cdr new)) '@))
                             (cddr new)
                             (cdr new)))
           (walker (make-tree-walker parent))
           (first-child (first-child! walker)))
      (let loop ((oc old-children) (nc new-children) (current first-child))
        (cond
         ;; More new children than old: append
         ((and (null? oc) (not (null? nc)))
          (for-each (lambda (child)
                      (append-child! parent (sxml->dom child)))
                    nc))
         ;; More old than new: remove extras
         ((and (not (null? oc)) (null? nc))
          (when current
            (let ((next (next-sibling! walker)))
              (remove! current)
              (loop (cdr oc) '() next))))
         ;; Both have children: recurse
         ((and (not (null? oc)) (not (null? nc)) current)
          (if (equal? (car oc) (car nc))
              (loop (cdr oc) (cdr nc) (next-sibling! walker))
              (begin
                (replace-with! current (sxml->dom (car nc)))
                (loop (cdr oc) (cdr nc) (next-sibling! walker)))))
         (else (if #f #f))))))

   ;; Different type or tag: replace entirely
   (else
    (let ((new-node (sxml->dom new)))
      (let ((walker (make-tree-walker parent)))
        (let ((child (first-child! walker)))
          (if child
              (replace-with! child new-node)
              (append-child! parent new-node))))))))

(define *current-vdom* #f)

(define (refresh!)
  (let* ((new-vdom (*render*))
         (old (if (and *current-vdom*
                       (let ((old-tag (and (pair? *current-vdom*) (car *current-vdom*)))
                             (new-tag (and (pair? new-vdom) (car new-vdom))))
                         (not (eq? old-tag new-tag))))
                  #f
                  *current-vdom*)))
    (set! *in-svg* #f)
    (set! *current-vdom* new-vdom)
    (virtual-dom-render (document-body) old new-vdom)))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 4: Application state
;;; ═══════════════════════════════════════════════════════════════════════════

;; Mutable application state (Sprint 2 keeps set! for clarity;
;; Sprint 3 will thread state through Goblins actor bcom transitions).

(define *screen*          'join)   ; 'join | 'connecting | 'room | 'breakout-moving | 'error
(define *room-id*         "")      ; current LiveKit room id
(define *meeting-id*      "")      ; server-side meeting id (Sprint 2+)
(define *local-id*        "")      ; LiveKit identity
(define *display-name*    "")
(define *role*            'participant)
(define *participants*    '())     ; list of (identity display-name)
(define *audio-muted*     #f)
(define *video-muted*     #f)
(define *error-msg*       "")
(define *in-breakout*     #f)      ; #t when participant is in a breakout room
(define *help-pending*    '())     ; host-side: list of pending help signals
(define *breakout-overview* '())   ; host-side: breakout room cards

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 5: Render function
;;; ═══════════════════════════════════════════════════════════════════════════

(define (*render*)
  (case *screen*
    ((join)
     (render-join-screen
      (lambda (name role room-id)
        (set! *display-name* name)
        (set! *role* (string->symbol role))
        (set! *room-id* room-id)
        (set! *screen* 'connecting)
        (refresh!)
        ;; Fetch token and connect
        (do-join! name role room-id))))

    ((connecting)
     (render-connection-overlay 'connecting))

    ((breakout-moving)
     (render-connection-overlay 'moving))

    ((room)
     (render-room
      *participants* *local-id* *role*
      *audio-muted* *video-muted*
      *in-breakout* *meeting-id*
      ;; Audio mute toggle
      (lambda (e)
        (set! *audio-muted* (not *audio-muted*))
        (if *audio-muted*
            (%livekit-disable-mic)
            (%livekit-enable-mic))
        (refresh!))
      ;; Video mute toggle
      (lambda (e)
        (set! *video-muted* (not *video-muted*))
        (if *video-muted*
            (%livekit-disable-camera)
            (%livekit-enable-camera))
        (refresh!))
      ;; Screen share
      (lambda (e)
        (%livekit-share-screen))
      ;; Leave
      (lambda (e)
        (livekit-disconnect)
        (set! *screen* 'join)
        (set! *participants* '())
        (set! *in-breakout* #f)
        (refresh!))
      ;; Help (participants in breakout) — POST /api/meetings/:id/help
      (lambda (e)
        (unless (string-null? *meeting-id*)
          (%fetch-json
           (string-append "/api/meetings/" *meeting-id* "/help")
           (string-append "{\"identity\":\"" *local-id*
                          "\",\"room_id\":\"" *room-id* "\"}"))))))

    ((error)
     `(div (@ (class "error-screen"))
        (h2 "Connection error")
        (p ,*error-msg*)
        (button (@ (click ,(lambda (e)
                             (set! *screen* 'join)
                             (set! *error-msg* "")
                             (refresh!))))
          "Back to Join")))))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 6: Join flow (fetch token → connect to LiveKit)
;;; ═══════════════════════════════════════════════════════════════════════════

(define (do-join! display-name role room-id)
  "Fetch a token from the Weave server and connect to LiveKit.
   If this is a new meeting (no existing meeting-id), creates a meeting first.
   %fetch-json is synchronous from Scheme's perspective (XHR bridge in weave.js)."
  ;; Ensure a meeting exists for this room — create one if not yet joined.
  ;; The server returns "meeting_id:<mid>|room_id:<rid>" (pipe-encoded).
  (when (string-null? *meeting-id*)
    (let* ((m-resp (%fetch-json "/api/meetings"
                                (string-append "{\"name\":\"" room-id "\"}"))))
      (unless (string-prefix? "ERR:" m-resp)
        ;; Parse first pipe segment: "meeting_id:<id>"
        (let* ((parts (string-split m-resp #\|))
               (first (car parts)))
          (if (string-prefix? "meeting_id:" first)
              (set! *meeting-id* (substring first 11))
              (console-warn (string-append "Unexpected meeting response: " m-resp)))))))

  (let* ((body (string-append
                "{\"identity\":\"" display-name
                "\",\"role\":\"" role
                "\",\"display_name\":\"" display-name "\"}"))
         (url      (string-append "/api/rooms/" room-id "/token"))
         (resp-str (%fetch-json url body)))
    (if (string-prefix? "ERR:" resp-str)
        (begin
          (console-error (string-append "Token fetch failed: " resp-str))
          (set! *error-msg*
            (cond
             ((string-prefix? "ERR:HTTP-404" resp-str) "Room not found — check the room ID.")
             ((string-prefix? "ERR:HTTP-" resp-str)    (string-append "Server error: " resp-str))
             ((string=? resp-str "ERR:NET")             "Could not reach server — is Weave running?")
             (else                                       (string-append "Join failed: " resp-str))))
          (set! *screen* 'error)
          (refresh!))
        (let* ((parts    (string-split resp-str #\|))
               (token    (list-ref parts 0))
               (lk-url   (list-ref parts 1))
               (identity (list-ref parts 2)))
          (console-log (string-append "Joining room " room-id " as " identity))
          (set! *local-id* identity)
          (set! *in-breakout* #f)
          ;; Add ourselves to participants list
          (set! *participants* (list (list identity display-name)))
          ;; Connect LiveKit — on-livekit-error fires if this fails
          (%livekit-connect lk-url token #f)
          ;; Enable camera + mic by default (non-observers)
          ;; on-livekit-error handles permission denial
          (unless (string=? role "observer")
            (%livekit-enable-camera)
            (%livekit-enable-mic))
          (set! *screen* 'room)
          (refresh!)))))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 7: LiveKit event callbacks (called from weave.js)
;;; ═══════════════════════════════════════════════════════════════════════════

;; These procedures are called by weave.js when LiveKit fires events.
;; weave.js holds references to these as WASM-exported functions.

(define (on-participant-connected identity display-name)
  "Called when a remote participant joins the LiveKit room."
  (set! *participants*
    (cons (list identity display-name) *participants*))
  (refresh!))

(define (on-participant-disconnected identity)
  "Called when a remote participant leaves the LiveKit room."
  (set! *participants*
    (filter (lambda (p) (not (string=? (car p) identity)))
            *participants*))
  (refresh!))

(define (on-connection-quality-changed identity quality-str)
  "Called when connection quality changes. For Sprint 1: no-op."
  (if #f #f))

(define (on-disconnected)
  "Called when the local participant disconnects unexpectedly.
   If we're mid-transfer (*screen* = breakout-moving), the disconnect is expected."
  (unless (eq? *screen* 'breakout-moving)
    (set! *screen* 'error)
    (set! *error-msg* "Disconnected from room. Please rejoin.")
    (refresh!)))

(define (on-livekit-error source message)
  "Called by JS when an async LiveKit operation throws.
   SOURCE is a string like 'livekit.connect'; MESSAGE is the JS error message.
   JS exceptions cannot be caught by Scheme's with-exception-handler — this
   callback is the only way Scheme learns about async JS failures."
  (console-error (string-append "LiveKit error [" source "]: " message))
  (cond
   ;; Connect failure → show error screen
   ((string=? source "livekit.connect")
    (set! *screen* 'error)
    (set! *error-msg* (string-append "Could not connect to meeting room: " message))
    (refresh!))
   ;; Camera/mic failures → log only (non-fatal; user can retry)
   ((or (string=? source "livekit.enableCamera")
        (string=? source "livekit.enableMic"))
    ;; UI remains in room; user sees their tile is dark/muted
    (if #f #f))
   ;; Screen share denial — user cancelled the picker, not an error
   ((string=? source "livekit.shareScreen")
    (if #f #f))
   ;; Catch-all: log and show non-blocking notice
   (else
    (console-warn (string-append "Unhandled async error [" source "]: " message)))))

(define (on-data-received msg)
  "Called when a LiveKit data channel message arrives.
   Sprint 2 messages:
     move:<room-id>  — move to a different room (host dispatch / recall)
     help:ack        — host acknowledged a help signal"
  (cond
   ;; Room transfer message
   ((string-prefix? "move:" msg)
    (let ((target-room-id (substring msg 5)))
      (unless (string=? target-room-id *room-id*)
        (do-move-to-room! target-room-id))))

   ;; Help acknowledgement
   ((string=? msg "help:ack")
    ;; Could show a brief notification; for now just no-op
    (if #f #f))

   (else (if #f #f))))

(define (do-move-to-room! target-room-id)
  "Disconnect from the current room and reconnect to TARGET-ROOM-ID.
   Used for breakout dispatch and recall."
  (set! *screen* 'breakout-moving)
  (refresh!)
  ;; Disconnect from current room (on-disconnected will fire but we guard it)
  (livekit-disconnect)
  ;; Fetch a new token for the target room
  (let* ((body (string-append
                "{\"identity\":\"" *display-name*
                "\",\"role\":\"" (symbol->string *role*)
                "\",\"display_name\":\"" *display-name* "\"}"))
         (url      (string-append "/api/rooms/" target-room-id "/token"))
         (resp-str (%fetch-json url body)))
    (if (string-prefix? "ERR:" resp-str)
        (begin
          (console-error (string-append "Breakout token fetch failed: " resp-str))
          (set! *error-msg* (string-append "Could not move to breakout room: " resp-str))
          (set! *screen* 'error)
          (refresh!))
        (let* ((parts    (string-split resp-str #\|))
               (token    (list-ref parts 0))
               (lk-url   (list-ref parts 1))
               (identity (list-ref parts 2)))
          (set! *room-id*   target-room-id)
          (set! *local-id*  identity)
          (set! *participants* (list (list identity *display-name*)))
          ;; Determine if we're now in a breakout or back in main
          (set! *in-breakout*
            (not (string-suffix? "-main" (or target-room-id ""))))
          (%livekit-connect lk-url token #f)
          (unless (eq? *role* 'observer)
            (%livekit-enable-camera)
            (%livekit-enable-mic))
          (set! *screen* 'room)
          (refresh!)))))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 8: Entry point
;;; ═══════════════════════════════════════════════════════════════════════════

;; Register LiveKit callbacks with the JS host so it can call back into WASM.
;; weave.js stores these references in _callbacks.
;; Signature: joined left quality disconnected data error
(define-foreign register-callbacks! "weave" "registerCallbacks"
  (ref null extern) (ref null extern) (ref null extern) (ref null extern)
  (ref null extern) (ref null extern) -> none)

;; Synchronous GET/DELETE helpers for meeting API calls
(define-foreign %weave-get-json    "weave" "getJSON"    (ref string) -> (ref string))
(define-foreign %weave-delete-json "weave" "deleteJSON" (ref string) -> (ref string))

;; Initial render
(set! *current-vdom* #f)
(refresh!)

;; Register event callbacks (6: joined left quality disconnected data error)
(register-callbacks!
 on-participant-connected
 on-participant-disconnected
 on-connection-quality-changed
 on-disconnected
 on-data-received
 on-livekit-error)
