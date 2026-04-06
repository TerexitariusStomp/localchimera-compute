(use-modules (hoot ffi)
             (hoot hashtables)
             ((hoot error-handling) #:select (format-exception))
             (ice-9 match)
             (ice-9 receive)
             (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             ;; (goblins utils crypto) removed — imports (rnrs bytevectors) which
             ;; Hoot can't compile. Key generation uses JS FFI directly instead.
             (goblins persistence-store local-storage)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins ocapn ids)
             (goblins contrib syrup)
             (goblins actor-lib io)
             (goblins utils hashmap)
             (goblins utils js-data)
             (goblins inbox)
             (fibers channels)
             (fibers conditions)
             (srfi srfi-9)
             (playnet gplay)
             (playnet kanren)
             (playnet autocomplete)
             (playnet wisp)
             (playnet ddmrp)
             (playnet ui components)
             (playnet ui dashboard)
             (playnet ui charts)
             (playnet ui federation)
             (playnet ui network)
             (playnet ui calendar)
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

(define-foreign ai-chat
  "ai" "chat"
  (ref string) (ref string) (ref string) (ref string) -> (ref string))

(define-foreign url-param-get
  "urlParams" "get"
  (ref string) -> (ref string))

;;; ── OCapN bridge FFI ────────────────────────────────────────────────────────
;;; Register Scheme callbacks with JS for transcription/express.
(define-foreign ocapn-set-transcribe-callback!
  "ocapn" "setTranscribeCallback"
  (ref extern) -> none)
(define-foreign ocapn-set-express-callback!
  "ocapn" "setExpressCallback"
  (ref extern) -> none)

;;; ── WebRTC FFI ─────────────────────────────────────────────────────────────
;;; Peer-to-peer DataChannel connections between browsers.
(define-foreign rtc-create-peer-connection
  "webRTC" "createPeerConnection"
  (ref string) -> (ref extern))
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
  '(svg g path circle rect line polyline polygon text defs marker
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

(define (refresh!)
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
   `((set-api-key! . ,web-set-api-key!)
     (set-ai-model! . ,web-set-ai-model!))
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

;;; ── AI state ─────────────────────────────────────────────────────────────

(define *ai-api-key* #f)
(define *ai-model* "google/gemini-3-flash-preview")

(define (web-set-api-key! key)
  (set! *ai-api-key* key))

(define (web-set-ai-model! model)
  (set! *ai-model* model))

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

(define (web-ai-query prompt org expressor-id)
  (unless *ai-api-key* (error "No API key. Use (set-api-key! \"sk-or-...\")"))
  (let* ((custom-prompt (expressor-config org expressor-id 'prompt))
         (custom-model  (expressor-config org expressor-id 'model))
         (system-prompt (if custom-prompt
                            (string-append custom-prompt "\n\n" (format-org-state org))
                            (format-org-context org))))
    (ai-chat system-prompt prompt *ai-api-key* (or custom-model *ai-model*))))

(define (web-ai-query-and-eval prompt org expressor-id)
  (unless *ai-api-key* (error "No API key. Use (set-api-key! \"sk-or-...\")"))
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
         (response (ai-chat ctx prompt *ai-api-key* (or custom-model *ai-model*))))
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
(define *view* 'home)  ;; 'home, 'dashboard, 'federation, or 'calendar
(define *current-org-name* #f)

;;; ── Calendar state ──────────────────────────────────────────────────────────
(define *cal-week-start* #f)        ;; epoch-ms of Monday 00:00; #f = compute from now
(define *cal-events* '())           ;; list of event alists
(define *cal-people* '())           ;; list of person alists
(define *cal-availability* '())     ;; list of availability slot alists
(define *cal-editing-event* #f)     ;; event alist being edited, or #f
(define *cal-editing-avail* #f)     ;; #t when editing availability panel
(define *cal-next-id* 1)            ;; auto-increment event ID
(define *cal-selected-event* #f)    ;; event shown in detail panel (right sidebar)
(define *cal-unscheduled-intents* '()) ;; work intents from planner not yet scheduled
(define *cal-selected-intent* #f)   ;; intent ID selected for scheduling
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
(define *goals-cycle* (make-cycle '("to \"win\"" "in the name of love" "as an end in itself" "to win points" "to surpass the highscore" "to unlock bonus items" "to issue tokens" "to unlock the next level" "to create thriving community" "to manage resources effectively" "to protect the realm" "to open new portals" "to reconstruct reality" "for economic space agency" "for a post-capitalist present" "to care for one another" "to enter our bliss bodies" "to find the others" "to revel in the beauty of every moment" "to dance organizations into existence" "to explore qualia" "to go where no one has ever gone before" "to defy the odds" "to witness more miracles" "to unite enchantment and majesty" "because reality is our art" "to make divine interventions redundant")))

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
                  (a (@ (href "https://github.com/interplaynetary/playnet") (class "btn github")) "Source")
                  (a (@ (href "https://opencollective.com/playnet") (class "btn discord")) "Donate"))
             (div (@ (class "bottom-buttons"))
                  (a (@ (href "https://drive.google.com/drive/folders/13XTRKXTwQggeQ2hBx4eLBZ2Favi4-I9n?usp=sharing") (class "btn playdrive")) "Playdrive")
                  (a (@ (href "https://calendar.google.com/calendar/u/0?cid=NmJjYThlM2E4OTU2NTc3ZjFkNzg4ZGZhYmNjYzk1MTk0YTI5ZThiMjljZWU5NzM1OGY4NWFhZWY1OGI0ZTFkOEBncm91cC5jYWxlbmRhci5nb29nbGUuY29t") (class "btn calendar")) "Calendar")
                  (a (@ (href "https://playnet.gitbook.io/docs/") (class "btn docs")) "Docs")))
        (div (@ (id "countdown")) ,(render-countdown))))

(define *expressor-filter* #f)       ;; symbol or #f — filter history by expressor name

;; Control panel state
(define *show-new-org-form* #f)
(define *show-signup-form* #f)
(define *confirm-delete-org* #f)     ;; org name string or #f
(define *show-join-form* #f)
(define *listening?* #f)
(define *expressing?* #f)  ;; #t during voice→NL→Scheme express flow
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
  (ls-set-item "playnet-syntax-mode" (symbol->string *syntax-mode*))
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
;;; Stores org names + serialized key material in localStorage["playnet-index"].
;;; Per-org Goblins state is stored by make-local-storage-store in separate keys.

(define (save-org-index!)
  "Persist the list of org names to localStorage as comma-separated string."
  (ls-set-item "playnet-index"
    (let loop ((names (map org-entry-name *orgs*)) (acc ""))
      (if (null? names) acc
          (loop (cdr names)
                (if (string=? acc "") (car names)
                    (string-append acc "," (car names))))))))

(define (load-org-index)
  "Load org names from localStorage. Returns list of strings or '()."
  (let ((raw (ls-get-item "playnet-index")))
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
  (if (eq? *mode* 'outer)
      "playnet> "
      (string-append *current-org-name* "["
        (symbol->string
          (or (with-vat *vat* ($ *org* 'expressor-name ($ *org* 'current-expressor))) '?))
        "]> ")))

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
                         (with-vat (org-entry-vat target)
                           (let ((result ($ controller 'evaluate body-expr)))
                             (unless (eq? result (if #f #f))
                               (let ((result-port (open-output-string)))
                                 (if (string? result)
                                     (display result result-port)
                                     (write result result-port))
                                 (let ((rs (get-output-string result-port)))
                                   (log-append! (lambda () `(span (@ (class "result-text"))
                                                                    ,(string-append "=> " (display-code rs) "\n"))))))))))
                       #:unwind? #t))
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
              "  After signup: ssh user@SERVER_IP\n\n")

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

(define (render-action-bar)
  `(div (@ (class "action-bar"))
        ,@(if (eq? *mode* 'outer)
              (list (action-button "+ new org"
                      (lambda () (set! *show-new-org-form* #t)) " cp-btn-primary")
                    (if (and *lobby* *connected?*)
                        (action-button "signup"
                          (lambda () (set! *show-signup-form* #t)) "")
                        `(span (@ (class "cp-status")) "relay: disconnected"))
                    (syntax-toggle-button)
                    (voice-button *listening?* "stop" "mic"))
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
                    (render-online-status)))))

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
                      (click ,(lambda (e) (toggle-ask-listening!) (refresh!))))
                   ,(if *listening?* "⏹" "🎤")))))

(define (render-tab-bar)
  `(div (@ (class "tab-bar"))
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'home)) " tab-active" "")))
                (click ,(lambda (e)
                          (if (eq? *mode* 'inner)
                              (begin (do-exit!) (set! *view* 'home) (refresh!) (scroll-to-bottom!))
                              (begin (set! *view* 'home) (refresh!))))))
             "playnet")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'dashboard)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'dashboard) (refresh!))))
             "dashboard")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'federation)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (set! *view* 'federation) (refresh!))))
             "federation")
        (div (@ (class ,(string-append "tab" (if (and (eq? *mode* 'outer) (eq? *view* 'calendar)) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!))
                          (when (not *cal-week-start*)
                            (set! *cal-week-start* (week-start-ms (inexact->exact (floor (date-now))))))
                          (set! *cal-unscheduled-intents* (extract-work-intents))
                          (set! *view* 'calendar) (refresh!)
                          (let ((w (get-element-by-id "cal-grid-wrap")))
                            (when w (set-scroll-top! w 480))))))
             "calendar")
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

;;; ── Dashboard view ──────────────────────────────────────────────────────────

(define *sample-planning-rows*
  (list
   `((spec-id . "flour") (spec-name . "Flour") (open-supply . 50)
     (onhand . 35) (qualified-demand . 20) (nfp . 65)
     (zone . green) (priority . 0.72) (recommended-qty . #f) (action . none))
   `((spec-id . "sugar") (spec-name . "Sugar") (open-supply . 10)
     (onhand . 8) (qualified-demand . 25) (nfp . -7)
     (zone . red) (priority . -0.12) (recommended-qty . 60) (action . replenish))
   `((spec-id . "butter") (spec-name . "Butter") (open-supply . 20)
     (onhand . 18) (qualified-demand . 15) (nfp . 23)
     (zone . yellow) (priority . 0.38) (recommended-qty . 40) (action . replenish))))

(define *sample-buffer-entries*
  (list
   `((buffer-zone . ((tor . 15) (toy . 30) (tog . 50) (dlt-days . 5)))
     (onhand . 35) (spec-name . "Flour"))
   `((buffer-zone . ((tor . 10) (toy . 25) (tog . 40) (dlt-days . 3)))
     (onhand . 8) (spec-name . "Sugar"))
   `((buffer-zone . ((tor . 12) (toy . 28) (tog . 45) (dlt-days . 4)))
     (onhand . 42) (spec-name . "Butter"))))

(define *sample-signal-entries*
  (list
   `((signal-id . "sig-abc123") (spec-id . "sugar-spec") (recommended-qty . 60)
     (approved-qty . 55) (fulfilled . 30) (due-date . "2026-04-05")
     (late . #f) (over-fulfilled . #f) (qty-diff . -5))
   `((signal-id . "sig-def456") (spec-id . "flour-spec") (recommended-qty . 40)
     (approved-qty . 40) (fulfilled . 40) (due-date . "2026-03-28")
     (late . #t) (over-fulfilled . #f) (qty-diff . 0))))

(define *sample-exceptions*
  (list
   `((order-id . "ord-98765ab") (date . "2026-03-30") (domain . execution)
     (duration . 2) (due-date . "2026-04-01"))
   `((order-id . "ord-12345cd") (date . "2026-03-29") (domain . planning)
     (duration . #f) (due-date . #f))))

(define *sample-health-entries*
  (let loop ((i 0) (acc '()))
    (if (= i 30) (reverse acc)
        (let* ((pct (+ 30 (* 40 (/ (+ 1 (sin (* i 0.3))) 2))))
               (zone (cond ((<= pct 33) 'red)
                           ((<= pct 66) 'yellow)
                           ((<= pct 100) 'green)
                           (else 'excess)))
               (date (string-append "2026-03-" (if (< (+ i 1) 10)
                                                    (string-append "0" (number->string (+ i 1)))
                                                    (number->string (+ i 1))))))
          (loop (+ i 1) (cons `((date . ,date) (pct . ,pct) (zone . ,zone)) acc))))))

(define (render-dashboard)
  "Render the DDMRP dashboard view with sample data."
  `(div (@ (class "dashboard-view"))
     (div (@ (class "dashboard-header"))
       (span (@ (class "dashboard-title")) "DDOM Dashboard")
       (span (@ (class "dashboard-subtitle")) "Demand Driven Operating Model"))
     ,(ddom-dashboard
       #:planning-rows *sample-planning-rows*
       #:signal-entries *sample-signal-entries*
       #:buffer-entries *sample-buffer-entries*
       #:exception-entries *sample-exceptions*
       #:today-str "2026-03-31")
     ,(buffer-health-run-chart
       *sample-health-entries*
       '((tor . 15) (toy . 30) (tog . 50))
       #:title "Buffer Health — Flour (30 days)")))

;;; ── Federation view sample data ──────────────────────────────────────────────

(define *fed-scopes*
  (list
   `((id . "universal-commune") (parent . #f))
   `((id . "agri-federation") (parent . "universal-commune"))
   `((id . "manufacturing-federation") (parent . "universal-commune"))
   `((id . "maritime-federation") (parent . "universal-commune"))
   `((id . "horticulture-federation") (parent . "universal-commune"))
   `((id . "food-processing-federation") (parent . "universal-commune"))
   ;; Agri communes
   `((id . "commune-grain") (parent . "agri-federation"))
   `((id . "commune-dairy") (parent . "agri-federation"))
   ;; Manufacturing communes
   `((id . "commune-forge") (parent . "manufacturing-federation"))
   `((id . "commune-workshop") (parent . "manufacturing-federation"))
   ;; Maritime
   `((id . "commune-fisher") (parent . "maritime-federation"))
   `((id . "commune-salter") (parent . "maritime-federation"))
   ;; Horticulture
   `((id . "commune-olive") (parent . "horticulture-federation"))
   `((id . "commune-citrus") (parent . "horticulture-federation"))
   ;; Food processing
   `((id . "commune-mill") (parent . "food-processing-federation"))
   `((id . "commune-bakery") (parent . "food-processing-federation"))))

(define *fed-results*
  `(("commune-grain" (surplus-qty . 670) (deficit-count . 0) (total-orig . 0) (total-short . 0) (has-deficits . #f)
     (deficits) (surplus ((spec . "wheat") (qty . 670)))
     (demand-intents ((spec . "bread") (qty . 45) (unit . "loaves"))
                     ((spec . "salt") (qty . 20) (unit . "kg"))))
    ("commune-dairy" (surplus-qty . 0) (deficit-count . 2) (total-orig . 100) (total-short . 30) (has-deficits . #t)
     (deficits ((spec . "wheat") (shortfall . 30) (original . 100) (resolved-at "commune-grain"))
               ((spec . "feed") (shortfall . 0) (original . 50) (resolved-at "commune-grain")))
     (surplus)
     (demand-intents ((spec . "bread") (qty . 30) (unit . "loaves"))
                     ((spec . "tools") (qty . 5) (unit . "pcs"))))
    ("commune-forge" (surplus-qty . 50) (deficit-count . 0) (total-orig . 0) (total-short . 0) (has-deficits . #f)
     (deficits) (surplus ((spec . "tools") (qty . 50))))
    ("commune-workshop" (surplus-qty . 0) (deficit-count . 1) (total-orig . 40) (total-short . 10) (has-deficits . #t)
     (deficits ((spec . "tools") (shortfall . 10) (original . 40) (resolved-at "commune-forge")))
     (surplus))
    ("commune-fisher" (surplus-qty . 262) (deficit-count . 0) (total-orig . 0) (total-short . 0) (has-deficits . #f)
     (deficits) (surplus ((spec . "fish") (qty . 262))))
    ("commune-salter" (surplus-qty . 475) (deficit-count . 0) (total-orig . 0) (total-short . 0) (has-deficits . #f)
     (deficits) (surplus ((spec . "salt") (qty . 475))))
    ("commune-olive" (surplus-qty . 0) (deficit-count . 1) (total-orig . 60) (total-short . 15) (has-deficits . #t)
     (deficits ((spec . "olive-oil") (shortfall . 15) (original . 60) (resolved-at)))
     (surplus))
    ("commune-citrus" (surplus-qty . 0) (deficit-count . 0) (total-orig . 30) (total-short . 0) (has-deficits . #f)
     (deficits) (surplus ((spec . "citrus") (qty . 30))))
    ("commune-mill" (surplus-qty . 0) (deficit-count . 0) (total-orig . 50) (total-short . 0) (has-deficits . #f)
     (deficits) (surplus))
    ("commune-bakery" (surplus-qty . 0) (deficit-count . 1) (total-orig . 80) (total-short . 20) (has-deficits . #t)
     (deficits ((spec . "flour") (shortfall . 20) (original . 80) (resolved-at "commune-mill")))
     (surplus))))

(define *fed-trades*
  (list
   `((id . "t1") (from . "commune-grain") (to . "commune-dairy") (spec . "wheat") (qty . 200))
   `((id . "t2") (from . "commune-fisher") (to . "commune-salter") (spec . "fish") (qty . 25))
   `((id . "t3") (from . "commune-salter") (to . "commune-bakery") (spec . "salt") (qty . 50))
   `((id . "t4") (from . "commune-olive") (to . "commune-mill") (spec . "olive-oil") (qty . 10))
   `((id . "t5") (from . "commune-forge") (to . "commune-workshop") (spec . "tools") (qty . 12))
   `((id . "t6") (from . "commune-citrus") (to . "commune-bakery") (spec . "citrus") (qty . 30))))

(define *fed-events*
  (list
   `((round . 0) (kind . scope-planned) (scope-id . "commune-grain"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-dairy"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-forge"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-fisher"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-salter"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-olive"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-citrus"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-mill"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-bakery"))
   `((round . 0) (kind . scope-planned) (scope-id . "commune-workshop"))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-dairy") (spec-id . "wheat") (qty . 200))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-workshop") (spec-id . "tools") (qty . 12))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-olive") (spec-id . "olive-oil") (qty . 15))
   `((round . 0) (kind . deficit-announced) (scope-id . "commune-bakery") (spec-id . "flour") (qty . 20))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-grain") (spec-id . "wheat") (qty . 670))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-fisher") (spec-id . "fish") (qty . 262))
   `((round . 0) (kind . surplus-offered) (scope-id . "commune-salter") (spec-id . "salt") (qty . 475))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-grain") (target-scope-id . "commune-dairy") (spec-id . "wheat") (qty . 200))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-fisher") (target-scope-id . "commune-salter") (spec-id . "fish") (qty . 25))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-salter") (target-scope-id . "commune-bakery") (spec-id . "salt") (qty . 50))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-forge") (target-scope-id . "commune-workshop") (spec-id . "tools") (qty . 12))
   `((round . 1) (kind . lateral-match) (scope-id . "commune-citrus") (target-scope-id . "commune-bakery") (spec-id . "citrus") (qty . 30))))

(define *fed-resources*
  (list
   (cons "commune-grain" (list `((id . "r1") (conforms-to . "wheat") (name . "Wheat Reserve") (onhand . 670) (unit . "kg"))))
   (cons "commune-dairy" (list `((id . "r2") (conforms-to . "dairy") (name . "Dairy Stock") (onhand . 45) (unit . "L"))))
   (cons "commune-forge" (list `((id . "r3") (conforms-to . "tools") (name . "Tool Stock") (onhand . 70) (unit . "pcs"))
                                `((id . "r4") (conforms-to . "ore") (name . "Iron Ore") (onhand . 200) (unit . "kg"))))
   (cons "commune-fisher" (list `((id . "r5") (conforms-to . "fish") (name . "Fish Stock") (onhand . 262) (unit . "kg"))))
   (cons "commune-salter" (list `((id . "r6") (conforms-to . "salt") (name . "Salt Reserve") (onhand . 475) (unit . "kg"))))
   (cons "commune-olive" (list `((id . "r7") (conforms-to . "olive-oil") (name . "Olive Oil") (onhand . 45) (unit . "L"))))
   (cons "commune-citrus" (list `((id . "r8") (conforms-to . "citrus") (name . "Citrus Fruits") (onhand . 120) (unit . "kg"))))
   (cons "commune-mill" (list `((id . "r9") (conforms-to . "flour") (name . "Flour Reserve") (onhand . 180) (unit . "kg"))))
   (cons "commune-bakery" (list `((id . "r10") (conforms-to . "bread") (name . "Bread Stock") (onhand . 90) (unit . "loaves"))))
   (cons "commune-workshop" (list `((id . "r11") (conforms-to . "goods") (name . "Goods Stock") (onhand . 35) (unit . "pcs"))))))

(define *fed-spec-names*
  '(("wheat" . "Wheat") ("dairy" . "Dairy") ("tools" . "Tools") ("ore" . "Iron Ore")
    ("fish" . "Fish") ("salt" . "Salt") ("olive-oil" . "Olive Oil") ("citrus" . "Citrus")
    ("flour" . "Flour") ("bread" . "Bread") ("goods" . "Goods")))

;; Sample processes and commitments per scope (for network diagrams)
(define *fed-processes*
  `(("commune-grain" . (((id . "harvest") (name . "Wheat Harvest"))
                         ((id . "thresh") (name . "Threshing"))))
    ("commune-dairy" . (((id . "milk") (name . "Milking"))
                         ((id . "pasteur") (name . "Pasteurize"))))
    ("commune-forge" . (((id . "smelt") (name . "Smelting"))
                         ((id . "forge") (name . "Forging"))))
    ("commune-fisher" . (((id . "catch") (name . "Fishing"))
                          ((id . "prep") (name . "Filleting"))))
    ("commune-mill" . (((id . "grind") (name . "Grinding"))
                        ((id . "sift") (name . "Sifting"))))
    ("commune-bakery" . (((id . "mix") (name . "Mixing"))
                          ((id . "bake") (name . "Baking"))))))

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
                          ((id . "cb4") (output-of . "bake") (resource-conforms-to . "bread") (action . produce) (qty . 90) (unit . "loaves"))))))

(define *fed-selected* "")
(define *fed-mode* 'plan)     ;; 'plan or 'observe
(define *fed-flow-ctx* #f)    ;; selected flow context for event recorder
(define *fed-recorded* '())   ;; list of recorded events

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
   #:svg-height 720))

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
                  (number->string (alist-ref e 'start-hour 0)) "|"
                  (number->string (alist-ref e 'start-min 0)) "|"
                  (number->string (alist-ref e 'end-hour 0)) "|"
                  (number->string (alist-ref e 'end-min 0)) "|"
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
                          (cons 'start-hour (safe-string->number (list-ref fields 3)))
                          (cons 'start-min  (safe-string->number (list-ref fields 4)))
                          (cons 'end-hour   (safe-string->number (list-ref fields 5)))
                          (cons 'end-min    (safe-string->number (list-ref fields 6)))
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

(define (save-calendar!)
  (ls-set-item "playnet-cal-events" (serialize-events *cal-events*))
  (ls-set-item "playnet-cal-people" (serialize-people *cal-people*)))

(define (load-calendar!)
  (let ((raw-e (ls-get-item "playnet-cal-events"))
        (raw-p (ls-get-item "playnet-cal-people")))
    (when raw-e (set! *cal-events* (deserialize-events raw-e)))
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
              *cal-events*)))

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

(define (extract-work-intents)
  "Extract unscheduled work intents from federation commitment data."
  (let loop ((scopes *fed-commitments*) (acc '()))
    (if (null? scopes) (reverse acc)
        (let* ((scope-entry (car scopes))
               (scope-name (car scope-entry))
               (commitments (cdr scope-entry))
               ;; Find processes for this scope
               (scope-procs (let ((p (assoc scope-name *fed-processes* equal?)))
                              (if p (cdr p) '())))
               (work-intents
                (filter (lambda (c) (eq? (alist-ref c 'action #f) 'work))
                        commitments))
               (intent-alists
                (map (lambda (c)
                       (let* ((proc-id (alist-ref c 'input-of ""))
                              (proc (%find (lambda (p) (equal? (alist-ref p 'id) proc-id))
                                          scope-procs))
                              (proc-name (if proc (alist-ref proc 'name proc-id) proc-id)))
                         (list (cons 'id (alist-ref c 'id ""))
                               (cons 'process-name proc-name)
                               (cons 'process-id proc-id)
                               (cons 'resource-spec (alist-ref c 'resource-conforms-to ""))
                               (cons 'effort-qty (alist-ref c 'effort-qty 0))
                               (cons 'effort-unit (alist-ref c 'effort-unit "hr"))
                               (cons 'scope scope-name))))
                     work-intents)))
          (loop (cdr scopes) (append acc intent-alists))))))

(define (cycle-event-status! evt new-status)
  "Cycle a VF event's status, persist, and show detail panel."
  (let ((evt-id (alist-ref evt 'id "")))
    (set! *cal-events*
          (map (lambda (ev)
                 (if (equal? (alist-ref ev 'id) evt-id)
                     (map (lambda (pair)
                            (if (eq? (car pair) 'status)
                                (cons 'status new-status)
                                pair))
                          ev)
                     ev))
               *cal-events*))
    ;; Also show the detail panel for the updated event
    (set! *cal-selected-event*
          (%find (lambda (ev) (equal? (alist-ref ev 'id) evt-id))
                 *cal-events*))
    (save-calendar!)
    (refresh!)))

;;; ── Calendar view ───────────────────────────────────────────────────────────

(define (render-calendar-view)
  "Render the calendar page, wiring state to the pure calendar module."
  (let ((ws (or *cal-week-start*
                (week-start-ms (inexact->exact (floor (date-now)))))))
    (calendar-page
     #:week-start-ms ws
     #:events *cal-events*
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
                   *cal-events*)
           '())
     #:process-flows
       (if (and *cal-selected-event*
                (alist-ref *cal-selected-event* 'vf-process-id #f))
           ;; Get all commitments for this process from federation data
           (let* ((proc-id (alist-ref *cal-selected-event* 'vf-process-id))
                  (scope (alist-ref *cal-selected-event* 'vf-scope ""))
                  (scope-cmts (let ((s (assoc scope *fed-commitments* equal?)))
                                (if s (cdr s) '())))
                  ;; Filter to this process's commitments
                  (proc-cmts (filter (lambda (c)
                                       (or (equal? (alist-ref c 'input-of #f) proc-id)
                                           (equal? (alist-ref c 'output-of #f) proc-id)))
                                     scope-cmts)))
             (map (lambda (c)
                    (let* ((is-input (alist-ref c 'input-of #f))
                           (act (alist-ref c 'action 'consume))
                           (spec (alist-ref c 'resource-conforms-to ""))
                           (qty (or (alist-ref c 'qty 0)
                                    (alist-ref c 'effort-qty 0)))
                           (unit (or (alist-ref c 'unit "")
                                     (alist-ref c 'effort-unit ""))))
                      (list (cons 'spec spec)
                            (cons 'qty qty)
                            (cons 'unit unit)
                            (cons 'action act)
                            (cons 'is-input (if is-input #t #f)))))
                  proc-cmts))
           '())
     #:supply-chain
       (if (and *cal-selected-event*
                (alist-ref *cal-selected-event* 'vf-process-id #f))
           ;; Find upstream (processes that output what this consumes)
           ;; and downstream (processes that consume what this outputs)
           (let* ((proc-id (alist-ref *cal-selected-event* 'vf-process-id))
                  (scope (alist-ref *cal-selected-event* 'vf-scope ""))
                  (scope-cmts (let ((s (assoc scope *fed-commitments* equal?)))
                                (if s (cdr s) '())))
                  (scope-procs (let ((p (assoc scope *fed-processes* equal?)))
                                 (if p (cdr p) '())))
                  ;; Inputs to this process (what it consumes)
                  (inputs (filter (lambda (c)
                                    (and (equal? (alist-ref c 'input-of #f) proc-id)
                                         (not (eq? (alist-ref c 'action #f) 'work))))
                                  scope-cmts))
                  ;; Outputs from this process
                  (outputs (filter (lambda (c)
                                     (equal? (alist-ref c 'output-of #f) proc-id))
                                   scope-cmts))
                  ;; Find upstream: processes that produce what we consume
                  (upstream
                   (filter (lambda (x) x)
                    (map (lambda (inp)
                           (let* ((spec (alist-ref inp 'resource-conforms-to ""))
                                  ;; Find commitment that outputs this spec
                                  (producer (%find (lambda (c)
                                                     (and (alist-ref c 'output-of #f)
                                                          (equal? (alist-ref c 'resource-conforms-to "") spec)))
                                                   scope-cmts))
                                  (up-proc-id (and producer (alist-ref producer 'output-of #f)))
                                  (up-proc (%find (lambda (p) (equal? (alist-ref p 'id) up-proc-id))
                                                  scope-procs)))
                             (if up-proc
                                 (list (cons 'direction 'up)
                                       (cons 'process (alist-ref up-proc 'name ""))
                                       (cons 'spec spec)
                                       (cons 'scope ""))
                                 #f)))
                         inputs)))
                  ;; Find downstream: processes that consume what we produce
                  (downstream
                   (filter (lambda (x) x)
                    (map (lambda (outp)
                           (let* ((spec (alist-ref outp 'resource-conforms-to ""))
                                  ;; Find commitment that inputs this spec in another process
                                  (consumer (%find (lambda (c)
                                                     (and (alist-ref c 'input-of #f)
                                                          (not (equal? (alist-ref c 'input-of #f) proc-id))
                                                          (equal? (alist-ref c 'resource-conforms-to "") spec)))
                                                   scope-cmts))
                                  (down-proc-id (and consumer (alist-ref consumer 'input-of #f)))
                                  (down-proc (%find (lambda (p) (equal? (alist-ref p 'id) down-proc-id))
                                                    scope-procs)))
                             (if down-proc
                                 (list (cons 'direction 'down)
                                       (cons 'process (alist-ref down-proc 'name ""))
                                       (cons 'spec spec)
                                       (cons 'scope ""))
                                 #f)))
                         outputs))))
             (append upstream downstream))
           '())
     #:on-event-click (lambda (evt)
                        (let ((source (alist-ref evt 'source 'event))
                              (status (alist-ref evt 'status 'open)))
                          (cond
                           ;; VF open → committed
                           ((and (or (eq? source 'intent) (eq? source 'commitment))
                                 (eq? status 'open))
                            (cycle-event-status! evt 'committed))
                           ;; VF committed → fulfilled
                           ((and (or (eq? source 'intent) (eq? source 'commitment))
                                 (eq? status 'committed))
                            (cycle-event-status! evt 'fulfilled))
                           ;; VF fulfilled → back to open (loop)
                           ((and (or (eq? source 'intent) (eq? source 'commitment))
                                 (eq? status 'fulfilled))
                            (cycle-event-status! evt 'open))
                           ;; Non-VF: open detail panel
                           (else
                            (set! *cal-selected-event* evt)
                            (set! *cal-editing-event* #f)
                            (refresh!)))))
     #:on-close-detail (lambda (e)
                         (set! *cal-selected-event* #f)
                         (refresh!))
     #:on-edit-from-detail (lambda (e)
                             (set! *cal-editing-event* *cal-selected-event*)
                             (set! *cal-selected-event* #f)
                             (refresh!))
     #:on-delete-from-detail (lambda (e)
                               (let ((evt-id (alist-ref *cal-selected-event* 'id "")))
                                 (set! *cal-events*
                                       (filter (lambda (ev)
                                                 (not (equal? (alist-ref ev 'id) evt-id)))
                                               *cal-events*))
                                 (set! *cal-selected-event* #f)
                                 (save-calendar!)
                                 (refresh!)))
     #:on-slot-click (lambda (date-str hour)
                       (set! *cal-selected-event* #f)
                       (let ((id (string-append "evt-" (number->string *cal-next-id*))))
                         (if *cal-selected-intent*
                             ;; Two-click scheduling: intent + time slot → VF event
                             (let* ((intent *cal-selected-intent*)
                                    (qty (alist-ref intent 'effort-qty 1))
                                    (end-h (min 23 (+ hour (max 1 (inexact->exact (ceiling qty)))))))
                               (set! *cal-editing-event*
                                     (list (cons 'id id)
                                           (cons 'title (string-append
                                                         (alist-ref intent 'process-name "Work")
                                                         " (" (alist-ref intent 'resource-spec "") ")"))
                                           (cons 'date date-str)
                                           (cons 'start-hour hour)
                                           (cons 'start-min 0)
                                           (cons 'end-hour end-h)
                                           (cons 'end-min 0)
                                           (cons 'person "me")
                                           (cons 'location "")
                                           (cons 'description "")
                                           (cons 'color "#63b3ed")
                                           (cons 'source 'commitment)
                                           (cons 'status 'open)
                                           (cons 'vf-process-id (alist-ref intent 'process-id ""))
                                           (cons 'vf-action 'work)
                                           (cons 'vf-resource-spec (alist-ref intent 'resource-spec ""))
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
                                           (cons 'start-hour hour)
                                           (cons 'start-min 0)
                                           (cons 'end-hour (min 23 (+ hour 1)))
                                           (cons 'end-min 0)
                                           (cons 'person "me")
                                           (cons 'location "")
                                           (cons 'description "")
                                           (cons 'color "#63b3ed")
                                           (cons 'source 'event)
                                           (cons 'status 'open)))
                               (refresh!)))))
     #:on-prev-week (lambda (e)
                      (set! *cal-week-start* (- ws 604800000))
                      (refresh!))
     #:on-next-week (lambda (e)
                      (set! *cal-week-start* (+ ws 604800000))
                      (refresh!))
     #:on-today (lambda (e)
                  (set! *cal-week-start*
                        (week-start-ms (inexact->exact (floor (date-now)))))
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
                                              (cons 'start-hour sh)
                                              (cons 'start-min sm)
                                              (cons 'end-hour eh)
                                              (cons 'end-min em)
                                              (cons 'person person)
                                              (cons 'location loc)
                                              (cons 'description desc)
                                              (cons 'color color)
                                              (cons 'source evt-source)
                                              (cons 'status evt-status))))
                           ;; Remove old version if exists, add new
                           (set! *cal-events*
                                 (cons new-evt
                                       (filter (lambda (ev)
                                                 (not (equal? (alist-ref ev 'id) evt-id)))
                                               *cal-events*)))
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
                           (set! *cal-events*
                                 (filter (lambda (ev)
                                           (not (equal? (alist-ref ev 'id) evt-id)))
                                         *cal-events*))
                           (set! *cal-editing-event* #f)
                           (save-calendar!)
                           (refresh!)))
     #:on-cancel-edit (lambda (e)
                        (set! *cal-editing-event* #f)
                        (refresh!))
     #:on-save-availability (lambda (e)
                              ;; Read availability form values
                              (set! *cal-availability*
                                    (let build ((day 0) (acc '()))
                                      (if (= day 7) (reverse acc)
                                          (let* ((sh-el (get-element-by-id
                                                         (string-append "avail-sh-" (number->string day))))
                                                 (eh-el (get-element-by-id
                                                         (string-append "avail-eh-" (number->string day))))
                                                 (sh (if sh-el (safe-string->number (element-value sh-el)) 9))
                                                 (eh (if eh-el (safe-string->number (element-value eh-el)) 17)))
                                            (build (+ day 1)
                                                   (if (< sh eh)
                                                       (cons (list (cons 'person "me")
                                                                   (cons 'day day)
                                                                   (cons 'start-hour sh)
                                                                   (cons 'start-min 0)
                                                                   (cons 'end-hour eh)
                                                                   (cons 'end-min 0))
                                                             acc)
                                                       acc))))))
                              (set! *cal-editing-avail* #f)
                              (save-calendar!)
                              (refresh!))
     #:on-cancel-availability (lambda (e)
                                (set! *cal-editing-avail* #f)
                                (refresh!))
     #:on-record-effort
       (if (and *cal-selected-event*
                (alist-ref *cal-selected-event* 'vf-process-id #f))
           (lambda (e)
             (let* ((qty-el (get-element-by-id "cal-effort-qty"))
                    (qty (if qty-el (safe-string->number (element-value qty-el)) 1))
                    (evt-id (alist-ref *cal-selected-event* 'id ""))
                    (old-fulfilled (alist-ref *cal-selected-event* 'vf-fulfilled-qty 0))
                    (new-fulfilled (+ old-fulfilled qty)))
               ;; Update the event's fulfilled qty
               (set! *cal-events*
                     (map (lambda (ev)
                            (if (equal? (alist-ref ev 'id) evt-id)
                                (map (lambda (pair)
                                       (cond ((eq? (car pair) 'vf-fulfilled-qty)
                                              (cons 'vf-fulfilled-qty new-fulfilled))
                                             ;; Auto-mark committed if still open
                                             ((and (eq? (car pair) 'status)
                                                   (eq? (cdr pair) 'open))
                                              (cons 'status 'committed))
                                             (else pair)))
                                     ev)
                                ev))
                          *cal-events*))
               ;; Update selected event to reflect change
               (set! *cal-selected-event*
                     (%find (lambda (ev) (equal? (alist-ref ev 'id) evt-id))
                            *cal-events*))
               (save-calendar!)
               (refresh!)))
           #f)
     #:stop-prop (lambda (e) (stop-propagation! e))
     #:on-export (lambda (e)
                   ;; Export all events as .ics file
                   (let* ((ical-header "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//playnet//calendar//EN\r\n")
                          (ical-footer "END:VCALENDAR\r\n")
                          (body (let loop ((evts *cal-events*) (acc ""))
                                  (if (null? evts) acc
                                      (loop (cdr evts)
                                            (string-append acc (event->ical (car evts))))))))
                     (download-file
                      (string-append ical-header body ical-footer)
                      "playnet-calendar.ics"
                      "text/calendar"))))))

(define (render)
  (if (eq? *mode* 'outer)
      ;; Outer mode: single column, no IDE chrome
      `(div (@ (class "outer"))
            ,(render-tab-bar)
            ,(render-action-bar)
            ,(cond
              ((eq? *view* 'dashboard) (render-dashboard))
              ((eq? *view* 'federation) (render-federation-view))
              ((eq? *view* 'calendar) (render-calendar-view))
              (else (render-homepage)))
            ,(render-repl))
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
            ,(render-code-viewer))))

(define (global-keydown event)
  (let ((key (keyboard-event-key event)))
    (cond
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
(let ((saved-mode (ls-get-item "playnet-syntax-mode")))
  (when (and saved-mode (string=? saved-mode "lisp"))
    (set! *syntax-mode* 'lisp)))

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
;; Seed sample data if calendar is empty (first load)
(when (null? *cal-events*)
  (let* ((now-ms (inexact->exact (floor (date-now))))
         (ws (week-start-ms now-ms))
         (mon (date-parts->date-string (epoch-ms->date-parts ws)))
         (tue (date-parts->date-string (epoch-ms->date-parts (+ ws 86400000))))
         (wed (date-parts->date-string (epoch-ms->date-parts (+ ws (* 2 86400000)))))
         (thu (date-parts->date-string (epoch-ms->date-parts (+ ws (* 3 86400000)))))
         (fri (date-parts->date-string (epoch-ms->date-parts (+ ws (* 4 86400000))))))
    (set! *cal-events*
          (list ;; All-day event
                (list (cons 'id "evt-0") (cons 'title "Sprint Week 14")
                      (cons 'date mon) (cons 'start-hour 0) (cons 'start-min 0)
                      (cons 'end-hour 0) (cons 'end-min 0) (cons 'person "alice")
                      (cons 'location "") (cons 'color "#a8e6cf")
                      (cons 'source 'event) (cons 'all-day #t)
                      (cons 'status 'open) (cons 'description ""))
                (list (cons 'id "evt-1") (cons 'title "Planning sync")
                      (cons 'date mon) (cons 'start-hour 9) (cons 'start-min 0)
                      (cons 'end-hour 10) (cons 'end-min 0) (cons 'person "alice")
                      (cons 'location "Room A") (cons 'color "#63b3ed") (cons 'source 'event))
                (list (cons 'id "evt-2") (cons 'title "Code review")
                      (cons 'date mon) (cons 'start-hour 14) (cons 'start-min 0)
                      (cons 'end-hour 15) (cons 'end-min 30) (cons 'person "bob")
                      (cons 'location "") (cons 'color "#f6ad55") (cons 'source 'event))
                (list (cons 'id "evt-3") (cons 'title "Standup")
                      (cons 'date tue) (cons 'start-hour 9) (cons 'start-min 30)
                      (cons 'end-hour 10) (cons 'end-min 0) (cons 'person "alice")
                      (cons 'location "") (cons 'color "#63b3ed") (cons 'source 'event))
                (list (cons 'id "evt-4") (cons 'title "Design session")
                      (cons 'date wed) (cons 'start-hour 11) (cons 'start-min 0)
                      (cons 'end-hour 12) (cons 'end-min 30) (cons 'person "carol")
                      (cons 'location "Studio") (cons 'color "#b794f4") (cons 'source 'event))
                ;; VF work commitment: threshing labor
                (list (cons 'id "evt-5") (cons 'title "Threshing (labor)")
                      (cons 'date wed) (cons 'start-hour 9) (cons 'start-min 0)
                      (cons 'end-hour 17) (cons 'end-min 0) (cons 'person "alice")
                      (cons 'location "") (cons 'color "#63b3ed")
                      (cons 'source 'commitment) (cons 'status 'open)
                      (cons 'description "Threshing wheat for commune-grain")
                      (cons 'vf-process-id "thresh") (cons 'vf-action 'work)
                      (cons 'vf-resource-spec "labor") (cons 'vf-effort-qty 8)
                      (cons 'vf-effort-unit "hr") (cons 'vf-scope "commune-grain")
                      (cons 'vf-fulfilled-qty 4))
                (list (cons 'id "evt-6") (cons 'title "Threshing (labor)")
                      (cons 'date thu) (cons 'start-hour 9) (cons 'start-min 0)
                      (cons 'end-hour 17) (cons 'end-min 0) (cons 'person "bob")
                      (cons 'location "") (cons 'color "#f6ad55")
                      (cons 'source 'commitment) (cons 'status 'open)
                      (cons 'description "Threshing wheat for commune-grain")
                      (cons 'vf-process-id "thresh") (cons 'vf-action 'work)
                      (cons 'vf-resource-spec "labor") (cons 'vf-effort-qty 8)
                      (cons 'vf-effort-unit "hr") (cons 'vf-scope "commune-grain")
                      (cons 'vf-fulfilled-qty 0))
                (list (cons 'id "evt-7") (cons 'title "Federation call")
                      (cons 'date fri) (cons 'start-hour 10) (cons 'start-min 0)
                      (cons 'end-hour 11) (cons 'end-min 0) (cons 'person "carol")
                      (cons 'location "Video") (cons 'color "#b794f4") (cons 'source 'event)
                      (cons 'status 'open) (cons 'description ""))))
    (set! *cal-people*
          (list (list (cons 'id "alice") (cons 'name "Alice") (cons 'color "#63b3ed") (cons 'visible #t))
                (list (cons 'id "bob") (cons 'name "Bob") (cons 'color "#f6ad55") (cons 'visible #t))
                (list (cons 'id "carol") (cons 'name "Carol") (cons 'color "#b794f4") (cons 'visible #t))))
    (set! *cal-availability*
          (list (list (cons 'person "me") (cons 'day 0) (cons 'start-hour 9) (cons 'start-min 0) (cons 'end-hour 17) (cons 'end-min 0))
                (list (cons 'person "me") (cons 'day 1) (cons 'start-hour 9) (cons 'start-min 0) (cons 'end-hour 17) (cons 'end-min 0))
                (list (cons 'person "me") (cons 'day 2) (cons 'start-hour 9) (cons 'start-min 0) (cons 'end-hour 17) (cons 'end-min 0))
                (list (cons 'person "me") (cons 'day 3) (cons 'start-hour 9) (cons 'start-min 0) (cons 'end-hour 17) (cons 'end-min 0))
                (list (cons 'person "me") (cons 'day 4) (cons 'start-hour 9) (cons 'start-min 0) (cons 'end-hour 17) (cons 'end-min 0))))
    (set! *cal-next-id* 8)
    (save-calendar!)))

(refresh!)
(add-event-listener!/wrap (document-body) "keydown" global-keydown)

;;; ── Animation timer ─────────────────────────────────────────────────────
;;; Steps the signshifting cycles; render() calls render-homepage which
;;; reads the current cycle state. VDOM diff patches only changed text nodes.
(let ((timer-callback (procedure->external
                       (lambda ()
                         (when (eq? *mode* 'outer)
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

;; The gateway sturdyref — override with ?gateway= URL param
(define *gateway-sref*
  (let ((param (url-param-get "gateway")))
    (if (and (string? param) (> (string-length param) 0))
        param
        ;; Default — update this after first gateway deploy
        "ocapn://PLACEHOLDER.websocket/s/PLACEHOLDER?url=ws%3A%2F%2FSERVER_IP%3A9090")))

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
  "Set or update a WebRTC peer entry."
  (set! *webrtc-peers*
        (cons (cons name entry)
              (filter (lambda (p) (not (string=? (car p) name)))
                      *webrtc-peers*))))

(define (webrtc-peer-remove! name)
  "Remove a WebRTC peer entry."
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
          (_ #f))))))

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
  "Announce our display name to the gateway."
  (when (and *lobby* *current-org-name* *user-inbox*)
    (with-vat *ocapn-vat*
      (on (<- *lobby* 'announce *current-org-name* *user-inbox*)
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
                (on-result transcript))
              #:catch
              (lambda (err)
                (on-result ""))))))))

  (ocapn-set-express-callback!
   (procedure->external
    (lambda (nl-text on-result)
      (when *lobby*
        (with-vat *ocapn-vat*
          (on (<- *lobby* 'express nl-text)
              (lambda (expr)
                (on-result expr))
              #:catch
              (lambda (err)
                (on-result ""))))))))

  ;; Enliven the gateway sturdyref
  (log-append! `(span (@ (class "info-text"))
                      "Connecting to OCapN gateway...\n"))
  (refresh!)

  (with-vat *ocapn-vat*
    (on (<- *mycapn* 'enliven (string->ocapn-id *gateway-sref*))
        (lambda (lobby-ref)
          (set! *lobby* lobby-ref)
          (set! *connected?* #t)
          (log-append! `(span (@ (class "result-text"))
                              "Connected to OCapN gateway. Create an org and enter it.\n"))
          ;; Request initial presence
          (on (<- lobby-ref 'who)
              (lambda (users)
                (set! *online-users* (if (list? users) users '()))
                (refresh!)))
          (when *current-org-name*
            (announce-presence!))
          (refresh!))
        #:catch
        (lambda (err)
          (log-append! `(span (@ (class "error-text"))
                              ,(string-append "Could not connect to gateway: "
                                              (call-with-output-string
                                                (lambda (p) (write err p)))
                                              "\n")))
          (refresh!)))))

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
