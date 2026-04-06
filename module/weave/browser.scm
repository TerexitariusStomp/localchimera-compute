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
             (weave ui join)
             (weave ui room))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 1: DOM FFI bindings (from weave.js user_imports)
;;; ═══════════════════════════════════════════════════════════════════════════

;; DOM — document
(define-foreign document-body    "document" "body"          -> (ref null extern))
(define-foreign get-element-by-id "document" "getElementById" (ref string) -> (ref null extern))
(define-foreign make-text-node   "document" "createTextNode" (ref string) -> (ref null extern))
(define-foreign make-element     "document" "createElement"  (ref string) -> (ref null extern))
(define-foreign make-element-ns  "document" "createElementNS" (ref string) (ref string) -> (ref null extern))
(define-foreign %make-tree-walker "document" "createTreeWalker" (ref null extern) i32 -> (ref null extern))
(define (make-tree-walker root) (%make-tree-walker root 5))

;; DOM — events
(define-foreign prevent-default!      "event" "preventDefault"  (ref null extern) -> none)
(define-foreign stop-propagation!     "event" "stopPropagation" (ref null extern) -> none)
(define-foreign keyboard-event-key    "event" "keyboardKey"      (ref null extern) -> (ref string))

;; DOM — element
(define-foreign element-value         "element" "value"           (ref null extern) -> (ref string))
(define-foreign set-element-value!    "element" "setValue"        (ref null extern) (ref string) -> none)
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
;;; Section 4: Application state (Goblins actor)
;;; ═══════════════════════════════════════════════════════════════════════════

(define *app-vat* (spawn-vat #:name "weave-browser"))

;; Application state actor
(define (^app-state bcom)
  "Holds all mutable UI state. bcom transitions to next state."
  (define state
    `((screen       . join)       ; 'join | 'connecting | 'room | 'error
      (room-id      . "")
      (local-id     . "")         ; LiveKit identity
      (display-name . "")
      (role         . participant)
      (participants . ())         ; list of (identity display-name)
      (audio-muted  . #f)
      (video-muted  . #f)
      (error-msg    . "")))

  (methods
   ((get key) (assq-ref state key))
   ((get-all) state)

   ((set! key val)
    (bcom (^app-state bcom)
          ;; Return new actor with updated state
          ;; (actor becomes the new state after bcom)
          ))

   ;; Transitions
   ((set-connecting! room-id)
    (bcom (^app-state bcom)))   ; placeholder — see note below

   ((set-room! local-id display-name role)
    (bcom (^app-state bcom)))

   ((add-participant! identity display-name)
    (bcom (^app-state bcom)))

   ((remove-participant! identity)
    (bcom (^app-state bcom)))

   ((toggle-audio!)
    (bcom (^app-state bcom)))

   ((toggle-video!)
    (bcom (^app-state bcom)))

   ((set-error! msg)
    (bcom (^app-state bcom)))))

;; NOTE: Goblins bcom replaces the actor's behavior with a new closure.
;; The pattern above is correct but state threading needs to be explicit.
;; The idiomatic approach: store state as a hashmap and use bcom to swap it.
;; Full implementation below uses a simpler mutable approach for Sprint 1.

;; Sprint 1 uses direct mutable state (set!) for simplicity.
;; Sprint 2 will migrate to proper Goblins actor state threading.
(define *screen*       'join)
(define *room-id*      "")
(define *local-id*     "")
(define *display-name* "")
(define *role*         'participant)
(define *participants* '())  ; list of (identity . display-name)
(define *audio-muted*  #f)
(define *video-muted*  #f)
(define *error-msg*    "")

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

    ((room)
     (render-room
      *participants* *local-id* *role*
      *audio-muted* *video-muted*
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
        (refresh!))))

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
   This calls back into JS via %fetch-json, which is synchronous from Scheme's
   perspective (weave.js bridges the Promise to a sync callback)."
  (let* ((body (string-append
                "{\"identity\":\"" display-name
                "\",\"role\":\"" role
                "\",\"display_name\":\"" display-name "\"}"))
         (url  (string-append "/api/rooms/" room-id "/token"))
         (resp-str (%fetch-json url body)))
    (if (string-null? resp-str)
        (begin
          (set! *error-msg* "Failed to contact server — is Weave running?")
          (set! *screen* 'error)
          (refresh!))
        (begin
          ;; Parse "token|livekit_url|identity" (simplified encoding from weave.js)
          (let* ((parts      (string-split resp-str #\|))
                 (token      (list-ref parts 0))
                 (lk-url     (list-ref parts 1))
                 (identity   (list-ref parts 2)))
            (set! *local-id* identity)
            ;; Add ourselves to participants
            (set! *participants* (list (list identity display-name)))
            ;; Connect LiveKit — callbacks fire as participants join/leave/tracks appear
            (%livekit-connect lk-url token #f)
            ;; Enable camera + mic by default (non-observers)
            (unless (string=? role "observer")
              (%livekit-enable-camera)
              (%livekit-enable-mic))
            (set! *screen* 'room)
            (refresh!))))))

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
  "Called when the local participant disconnects unexpectedly."
  (set! *screen* 'error)
  (set! *error-msg* "Disconnected from room. Please rejoin.")
  (refresh!))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; Section 8: Entry point
;;; ═══════════════════════════════════════════════════════════════════════════

;; Register LiveKit callbacks with the JS host so it can call back into WASM.
;; weave.js stores these references in window._weaveCallbacks.
(define-foreign register-callbacks! "weave" "registerCallbacks"
  (ref null extern) (ref null extern) (ref null extern) (ref null extern) -> none)

;; Initial render
(set! *current-vdom* #f)
(refresh!)

;; Register event callbacks
(register-callbacks!
 on-participant-connected
 on-participant-disconnected
 on-connection-quality-changed
 on-disconnected)
