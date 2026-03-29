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
             (xorg gplay)
             (xorg autocomplete)
             (xorg wisp)
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
(define-foreign make-tree-walker
  "document" "createTreeWalker"
  (ref null extern) -> (ref null extern))

(define-foreign prevent-default!
  "event" "preventDefault"
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

(define-foreign relay-send-later
  "relay" "sendLater"
  (ref extern) (ref string) -> none)

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

(define (attr-value? x)
  (or (string? x) (boolean? x)))

(define (sxml->dom exp)
  (match exp
    ((? string? str)
     (make-text-node str))
    (((? symbol? tag) . body)
     (let ((elem (make-element (symbol->string tag))))
       (define (add-children children)
         (for-each (lambda (child)
                     (append-child! elem (sxml->dom child)))
                   children))
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
                  (let ((parent (current-node walker)))
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
                    (set-current-node! walker parent)))
                 ;; New element tag is different than the old
                 ;; one, so replace the entire element subtree.
                 (else
                  (replace-with! (current-node walker)
                                 (sxml->dom new)))))))))))))

(define *current-vdom* #f)
(define (refresh!)
  (let ((new-vdom (render)))
    (virtual-dom-render (document-body) *current-vdom* new-vdom)
    (set! *current-vdom* new-vdom)))

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
     (set-ai-model! . ,web-set-ai-model!))))

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
      "\n\nAvailable special forms: (modify! 'name value), (enact! validator-expr), "
      "(rollback! version), (defexpressor name key), (as expressor-id expr), "
      "(ai prompt), (ai-eval prompt), "
      "(show-history), (show-expressors), (lambda (args ...) body), "
      "(if test then else), (quote expr).\n")))

(define (format-org-context ref)
  (string-append
    "You are an AI inside xorg, a Scheme-based system for programmable organizations.\n\n"
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
               "Use (modify! 'name value) to create or update bindings. "
               "Use string literals for text values (\"hello\"), not quoted symbols. "
               "Example: (modify! 'greeting \"hello world\")\n"
               "Example: (modify! 'budget 50000)\n"
               "For multiple changes: (begin (modify! 'a 1) (modify! 'b 2))"))
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
(define *current-org-name* #f)
(define *vat* #f)
(define *org* #f)

;; Signup flow state
(define *signup-pending?* #f)  ;; #t while waiting for relay signup-ok/error reply

(define *sidebar-collapsed* #f)
(define *sidebar-selected-org* #f)   ;; string or #f
(define *expressor-filter* #f)       ;; symbol or #f — filter history by expressor name

;; Control panel state
(define *show-new-org-form* #f)
(define *show-signup-form* #f)
(define *confirm-delete-org* #f)     ;; org name string or #f
(define *show-join-form* #f)
(define *listening?* #f)
(define *expressing?* #f)  ;; #t during voice→NL→Scheme express flow
(define *syntax-mode* 'lisp)  ;; 'lisp or 'wisp

;; Voice-to-text callbacks
(define (on-speech-result transcript)
  (let ((input (get-element-by-id "expression")))
    (set-element-value! input
      (string-append (element-value input)
                     (if (string=? (element-value input) "") "" " ")
                     transcript))
    (set! *listening?* #f)
    (refresh!)))

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
  "Convert natural language text to S-expression via relay, put in input."
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
  (ls-set-item "xorg-syntax-mode" (symbol->string *syntax-mode*))
  (update-code-viewer!)
  (refresh!)
  (scroll-to-bottom!))

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
;;; Stores org names + serialized key material in localStorage["xorg-index"].
;;; Per-org Goblins state is stored by make-local-storage-store in separate keys.

(define (save-org-index!)
  "Persist the list of org names to localStorage as comma-separated string."
  (ls-set-item "xorg-index"
    (let loop ((names (map org-entry-name *orgs*)) (acc ""))
      (if (null? names) acc
          (loop (cdr names)
                (if (string=? acc "") (car names)
                    (string-append acc "," (car names))))))))

(define (load-org-index)
  "Load org names from localStorage. Returns list of strings or '()."
  (let ((raw (ls-get-item "xorg-index")))
    (if (or (not raw) (string=? raw "")) '()
        ;; Split comma-separated string into list
        (let loop ((s raw) (acc '()))
          (let ((comma (string-index s #\,)))
            (if comma
                (loop (substring s (+ comma 1))
                      (cons (substring s 0 comma) acc))
                (reverse (cons s acc))))))))

(define *log*
  (list `(span (@ (class "result-text"))
               ,(string-append
                 "\n"
                 " ██╗  ██╗ ██████╗ ██████╗  ██████╗ \n"
                 " ╚██╗██╔╝██╔═══██╗██╔══██╗██╔════╝ \n"
                 "  ╚███╔╝ ██║   ██║██████╔╝██║  ███╗\n"
                 "  ██╔██╗ ██║   ██║██╔══██╗██║   ██║\n"
                 " ██╔╝ ██╗╚██████╔╝██║  ██║╚██████╔╝\n"
                 " ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝\n"
                 "\n"))
        `(span (@ (class "info-text"))
               ,(string-append
                 "An organization is a program that writes itself.\n"
                 "This is a metacircular substrate for programmable\n"
                 "organizations — identity, memory, and self-modification.\n"
                 "Built on Spritely Goblins with capability-based security.\n"
                 "\n"
                 "── Getting Started ──────────────────────────────\n"
                 "\n"
                 "  (make-org \"alpha\")   create a local org\n"
                 "  (enter! \"alpha\")     enter it\n"
                 "  (exit!)              leave current org\n"
                 "  (list-orgs)          show all orgs\n"
                 "\n"
                 "── Inside an Org ───────────────────────────────\n"
                 "\n"
                 "Every action has an identity, every change is\n"
                 "remembered, and the rules for changing the rules\n"
                 "are subject to the rules.\n"
                 "\n"
                 "Create identities (returns a private sealer):\n"
                 "  (define alice (defexpressor 'alice \"alice-key\"))\n"
                 "  (define bob (defexpressor 'bob \"bob-key\"))\n"
                 "\n"
                 "Act as an identity (requires the sealer):\n"
                 "  (as alice (modify! 'proposal \"fund the commons\"))\n"
                 "  (as bob (modify! 'seconded #t))\n"
                 "\n"
                 "Enact a rule (must accept itself to take effect):\n"
                 "  (enact! (lambda (expressor name value pre post)\n"
                 "            (not (equal? value #f))))\n"
                 "\n"
                 "Inspect:\n"
                 "  (show-history)       versioned ledger\n"
                 "  (show-expressors)    all known identities\n"
                 "  proposal             look up any binding\n"
                 "\n"
                 "Rollback:\n"
                 "  (rollback! 2)\n"
                 "\n"
                 "── AI ─────────────────────────────────────────\n"
                 "\n"
                 "First, set your OpenRouter API key:\n"
                 "  (set-api-key! \"sk-or-...\")\n"
                 "  (set-ai-model! \"openai/gpt-4o\")   ; optional\n"
                 "\n"
                 "Then use AI anywhere inside an org:\n"
                 "  (ai \"what is the budget?\")         ask AI\n"
                 "  (ai-eval \"create a greeting\")      AI generates + executes code\n"
                 "\n"
                 "AI expressors — config lives as org bindings:\n"
                 "  (define ai (defexpressor 'ai \"ai-key\"))\n"
                 "  (as ai (modify! 'ai:prompt \"You govern wisely.\"))\n"
                 "  (as ai (ai-eval \"propose a budget\"))  ; uses ai:prompt\n"
                 "  (modify! 'ai:prompt \"Be cautious.\")   ; change AI behavior\n"
                 "\n"
                 "── Cross-Org ──────────────────────────────────\n"
                 "\n"
                 "Store another org's public key, then reference\n"
                 "it by name (unquoted) — no string needed:\n"
                 "  (define alpha (public-key))         your own key\n"
                 "  (define beta-key '(public-key ...)) another org's key\n"
                 "\n"
                 "  (join-org \"alpha\")                   request to join local\n"
                 "  (approve-member 0 \"alice\")           approve member\n"
                 "  (act-in \"alpha\" (modify! 'x 1))     act in local org\n"
                 "  (act-in beta-key (modify! 'x 1))    act in remote org\n"
                 "  (public-key)                        show this org's key\n"
                 "\n"
                 "── Signup & SSH ───────────────────────────────\n"
                 "\n"
                 "Register an account on the xorg server:\n"
                 "  (signup! \"user\" \"email@example.com\") request account\n"
                 "  (export-ssh-key)                    show your SSH key\n"
                 "\n"
                 "After signup, you can: ssh user@SERVER_IP\n"
                 "The server is a Guix System machine — pushing to\n"
                 "main auto-deploys the ENTIRE operating system.\n"
                 "\n"
                 "── Language Forms ──────────────────────────────\n"
                 "\n"
                 "define, lambda, let, let*, letrec, named let,\n"
                 "begin, if, cond, case, and, or, when, unless, do,\n"
                 "quote. Lambdas capture bindings but adopt their\n"
                 "caller's identity — logic and authority are separate.\n"
                 "\n"))))

(define *outer-log* *log*)
(define *outer-vat* #f)
(define *outer-org* #f)

(define (log-append! . lines)
  (set! *log* (append *log* lines)))

(define (current-prompt)
  (if (eq? *mode* 'outer)
      "xorg> "
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
                  (display "(modify! '" port)
                  (display (symbol->string (car pair)) port)
                  (display " " port)
                  (let ((val (cdr pair)))
                    (cond
                      ((procedure? val)
                       (display "<procedure>" port))
                      (($ ref 'expressor? val)
                       (display (string-append "<expressor:"
                                 (symbol->string (or ($ ref 'expressor-name val) '?)) ">") port))
                      (else (write val port))))
                  (display ")\n" port))
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
                  (log-append! `(span (@ (class "result-text"))
                                      ,(string-append "=> " result-str "\n"))))
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
      (set! *log* (org-entry-log org))
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

(define (do-make-org! name)
  (if (org-lookup name)
      (log-append! `(span (@ (class "error-text"))
                          ,(string-append "Org already exists: " name "\n")))
      (let* ((kp (generate-key-pair))
             (pk (key-pair->public-key kp))
             (store (make-local-storage-store (string-append "xorg-" name))))
        (receive (vat org inbox incanter refs)
          (make-persistent-org name base-bindings store
                               #:public-key pk
                               #:persistence-registry *persistence-registry*)
          (let ((pk-display (let ((p (open-output-string)))
                              (write pk p)
                              (let ((s (get-output-string p)))
                                (if (> (string-length s) 50)
                                    (string-append (substring s 0 50) "...")
                                    s)))))
            (set! *orgs* (cons (list name vat org inbox incanter kp refs) *orgs*))
            (set! *sidebar-selected-org* name)
            (save-key-pair name kp)
            (save-org-index!)
            (log-append! `(span (@ (class "result-text"))
                                ,(string-append "Created org: " name "\n  key: " pk-display "\n"))))))))

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
        (ls-remove-item (string-append "xorg-" name))
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
                    "Your xorg public key (use this as your SSH public key):\n"
                    "  " pk-str "\n\n"
                    "Paste it during (signup!) or send it to an administrator.\n"))))))

(define (do-signup! username email)
  (cond
    ((not (eq? *mode* 'inner))
     (log-append! `(span (@ (class "error-text"))
                         "Enter an org first.\n")))
    ((not *ws*)
     (log-append! `(span (@ (class "error-text"))
                         "Not connected to relay.\n")))
    (*signup-pending?*
     (log-append! `(span (@ (class "info-text"))
                         "Signup already in progress...\n")))
    (else
     (let* ((pk     (with-vat *vat* ($ *org* 'public-key)))
            (pk-str (call-with-output-string (lambda (p) (write pk p))))
            (msg    (call-with-output-string
                      (lambda (p)
                        (write (list 'signup username email pk-str) p)))))
       (set! *signup-pending?* #t)
       (ws-send *ws* msg)
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
       ((not *ws*)
        (log-append! `(span (@ (class "error-text"))
                            "Not connected to relay. Cannot send signup request.\n")))
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
     (if (and *ws* *connected?*)
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
            ;; Target is a public key → send over relay
            ((and is-pubkey? *ws*)
             (let* ((expr-str (call-with-output-string (lambda (p) (write body-expr p))))
                    (pk-str (call-with-output-string (lambda (p) (write target-val p))))
                    (my-pk-str (call-with-output-string
                                (lambda (p)
                                  (write (with-vat *vat* ($ *org* 'public-key)) p))))
                    (msg (call-with-output-string
                           (lambda (p)
                             (write `(to ,pk-str (from ,my-pk-str ,body-expr)) p)))))
               (relay-send-later *ws* msg)
               (log-append! `(span (@ (class "info-text"))
                                   ,(string-append "Sent: " expr-str "\n")))))
            ;; Target is a public key but no relay
            ((and is-pubkey? (not *ws*))
             (log-append! `(span (@ (class "error-text"))
                                 "Not connected to relay. Add ?relay=ws://... to URL.\n")))
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
                                 (log-append! `(span (@ (class "result-text"))
                                                     ,(string-append "=> " (get-output-string result-port) "\n"))))))))
                       #:unwind? #t))
                   (log-append! `(span (@ (class "error-text"))
                                       ,(string-append "No controller for: " target-val "\n"))))))
            ;; Unknown target type
            (else
             (log-append! `(span (@ (class "error-text"))
                                 "act-in target must be an org name or a public key.\n"))))))
     #t)

    (_ #f)))

(define (eval! str)
  (log-append! `(span (@ (class "prompt-text")) ,(current-prompt))
               `(span (@ (class "input-text")) ,(string-append str "\n")))
  (history-push! str)
  (let* ((effective-str (if (eq? *syntax-mode* 'wisp)
                            (wisp->sexp-string str)
                            str))
         (port (open-input-string effective-str)))
    (let loop ()
      (let ((exp (read* port)))
        (cond
         ((eof-object? exp) (if #f #f))
         ((eq? exp %invalid)
          (log-append! `(span (@ (class "error-text")) "invalid expression\n"))
          (loop))
         ;; Check for org management commands first
         ((handle-command exp) (loop))
         ;; In inner mode, use the xorg evaluator
         ((eq? *mode* 'inner)
          (eval-play! exp)
          (loop))
         ;; In outer mode, prompt user to enter an org
         (else
          (log-append! `(span (@ (class "info-text"))
                              ,(string-append "Enter an org to evaluate expressions.\n"
                                              "  (make-org \"name\")    create an org\n"
                                              "  (enter! \"name\")      enter it\n")))
          (loop)))))))

;;; ── Auto-resize ───────────────────────────────────────────────────────────

(define (auto-resize event)
  (let ((input (get-element-by-id "expression")))
    (set-style! input "height" "auto")
    (set-style! input "height"
                (string-append (number->string (scroll-height input)) "px"))
    (scroll-to-bottom!)))

;;; ── Scroll helper ─────────────────────────────────────────────────────────

(define (scroll-to-bottom!)
  (let ((log (get-element-by-id "repl-log")))
    (set-scroll-top! log (scroll-height log))
    (focus-element! (get-element-by-id "expression"))))

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

;;; ── Control panel render functions ───────────────────────────────────────

(define (render-new-org-button)
  (if *show-new-org-form*
      `(div (@ (class "cp-form"))
            (input (@ (id "new-org-input") (class "cp-input")
                      (placeholder "org name")
                      (keydown ,(lambda (e)
                                  (let ((key (keyboard-event-key e)))
                                    (when (string=? key "Enter")
                                      (prevent-default! e)
                                      (let ((name (%trim (element-value
                                                           (get-element-by-id "new-org-input")))))
                                        (unless (string=? name "")
                                          (do-make-org! name)
                                          (set! *show-new-org-form* #f)
                                          (refresh!) (scroll-to-bottom!)))))))))
            (div (@ (class "cp-btn-row"))
                 (span (@ (class "cp-btn cp-btn-primary")
                           (click ,(lambda (e)
                                     (let ((name (%trim (element-value
                                                          (get-element-by-id "new-org-input")))))
                                       (unless (string=? name "")
                                         (do-make-org! name)
                                         (set! *show-new-org-form* #f)
                                         (refresh!) (scroll-to-bottom!))))))
                       "create")
                 (span (@ (class "cp-btn")
                           (click ,(lambda (e)
                                     (set! *show-new-org-form* #f)
                                     (refresh!))))
                       "cancel")))
      `(div (@ (class "cp-action")
               (click ,(lambda (e)
                         (set! *show-new-org-form* #t)
                         (refresh!))))
            "+ new org")))

(define (render-signup-button)
  (if *show-signup-form*
      `(div (@ (class "cp-form"))
            (input (@ (id "signup-username") (class "cp-input")
                      (placeholder "username")))
            (input (@ (id "signup-email") (class "cp-input")
                      (placeholder "email@example.com")
                      (keydown ,(lambda (e)
                                  (when (string=? (keyboard-event-key e) "Enter")
                                    (prevent-default! e)
                                    (let ((u (%trim (element-value
                                                      (get-element-by-id "signup-username"))))
                                          (em (%trim (element-value
                                                       (get-element-by-id "signup-email")))))
                                      (unless (or (string=? u "") (string=? em ""))
                                        (do-signup! u em)
                                        (set! *show-signup-form* #f)
                                        (refresh!) (scroll-to-bottom!))))))))
            (div (@ (class "cp-btn-row"))
                 (span (@ (class "cp-btn cp-btn-primary")
                           (click ,(lambda (e)
                                     (let ((u (%trim (element-value
                                                       (get-element-by-id "signup-username"))))
                                           (em (%trim (element-value
                                                        (get-element-by-id "signup-email")))))
                                       (unless (or (string=? u "") (string=? em ""))
                                         (do-signup! u em)
                                         (set! *show-signup-form* #f)
                                         (refresh!) (scroll-to-bottom!))))))
                       "register")
                 (span (@ (class "cp-btn")
                           (click ,(lambda (e)
                                     (set! *show-signup-form* #f)
                                     (refresh!))))
                       "cancel")))
      `(span (@ (class "cp-action")
                (click ,(lambda (e)
                          (set! *show-signup-form* #t)
                          (refresh!))))
             "signup")))

(define (render-join-form)
  (if *show-join-form*
      `(div (@ (class "cp-form"))
            (input (@ (id "join-target-input") (class "cp-input")
                      (placeholder "target org name")
                      (keydown ,(lambda (e)
                                  (when (string=? (keyboard-event-key e) "Enter")
                                    (prevent-default! e)
                                    (let ((target (%trim (element-value
                                                           (get-element-by-id "join-target-input")))))
                                      (unless (string=? target "")
                                        (do-join-org! target)
                                        (set! *show-join-form* #f)
                                        (refresh!) (scroll-to-bottom!))))))))
            (div (@ (class "cp-btn-row"))
                 (span (@ (class "cp-btn cp-btn-primary")
                           (click ,(lambda (e)
                                     (let ((target (%trim (element-value
                                                            (get-element-by-id "join-target-input")))))
                                       (unless (string=? target "")
                                         (do-join-org! target)
                                         (set! *show-join-form* #f)
                                         (refresh!) (scroll-to-bottom!))))))
                       "join")
                 (span (@ (class "cp-btn")
                           (click ,(lambda (e)
                                     (set! *show-join-form* #f)
                                     (refresh!))))
                       "cancel")))
      `(span (@ (class "cp-action")
                (click ,(lambda (e)
                          (set! *show-join-form* #t)
                          (refresh!))))
             "join org")))

(define (render-action-bar)
  `(div (@ (class "action-bar"))
        ,@(if (eq? *mode* 'outer)
              (append
               (list `(span (@ (class "cp-btn cp-btn-primary")
                                (click ,(lambda (e)
                                          (set! *show-new-org-form* #t)
                                          (refresh!))))
                             "+ new org")
                     (if (and *ws* *connected?*)
                         `(span (@ (class "cp-btn")
                                   (click ,(lambda (e)
                                             (set! *show-signup-form* #t)
                                             (refresh!))))
                                "signup")
                         `(span (@ (class "cp-status")) "relay: disconnected")))
               (list `(span (@ (class ,(string-append "cp-btn" (if (eq? *syntax-mode* 'wisp) " cp-btn-primary" "")))
                                (click ,(lambda (e) (toggle-syntax-mode!))))
                             ,(if (eq? *syntax-mode* 'wisp) "wisp" "lisp")))
               (if #t  ;; always show mic — unsupported browsers fail gracefully via onerror
                   (list `(span (@ (class ,(string-append "cp-btn" (if *listening?* " cp-btn-danger" "")))
                                   (click ,(lambda (e) (toggle-listening!) (refresh!))))
                                ,(if *listening?* "stop" "mic")))
                   '()))
              (append
               (list `(span (@ (class "cp-btn")
                                (click ,(lambda (e) (do-exit!) (refresh!) (scroll-to-bottom!))))
                             "exit")
                     `(span (@ (class "cp-btn")
                                (click ,(lambda (e)
                                          (eval! (if (eq? *syntax-mode* 'wisp)
                                                     "show-history" "(show-history)"))
                                          (refresh!) (scroll-to-bottom!))))
                             "history")
                     `(span (@ (class "cp-btn")
                                (click ,(lambda (e)
                                          (eval! (if (eq? *syntax-mode* 'wisp)
                                                     "show-expressors" "(show-expressors)"))
                                          (refresh!) (scroll-to-bottom!))))
                             "expressors")
                     `(span (@ (class "cp-btn")
                                (click ,(lambda (e)
                                          (eval! (if (eq? *syntax-mode* 'wisp)
                                                     "public-key" "(public-key)"))
                                          (refresh!) (scroll-to-bottom!))))
                             "public key")
                     `(span (@ (class "cp-btn")
                                (click ,(lambda (e) (do-export-ssh-key!) (refresh!) (scroll-to-bottom!))))
                             "ssh key")
                     (render-join-form))
               (list `(span (@ (class ,(string-append "cp-btn" (if (eq? *syntax-mode* 'wisp) " cp-btn-primary" "")))
                                (click ,(lambda (e) (toggle-syntax-mode!))))
                             ,(if (eq? *syntax-mode* 'wisp) "wisp" "lisp")))
               (list `(span (@ (class ,(string-append "cp-btn" (if (and *listening?* (not *expressing?*)) " cp-btn-danger" "")))
                                (click ,(lambda (e) (toggle-listening!) (refresh!))))
                             ,(if (and *listening?* (not *expressing?*)) "stop" "mic"))
                     `(span (@ (class ,(string-append "cp-btn" (if *expressing?* " cp-btn-danger" "")))
                                (click ,(lambda (e) (toggle-expressing!) (refresh!))))
                             ,(cond (*expressing?* "stop")
                                    (else "express"))))
               (list `(span (@ (class ,(string-append "cp-status"
                                          (if *connected?* " cp-status-connected"
                                              " cp-status-disconnected"))))
                             ,(if *connected?*
                                  (if (null? *online-users*)
                                      "online"
                                      (let loop ((users *online-users*) (acc ""))
                                        (if (null? users)
                                            (string-append
                                             (number->string (length *online-users*))
                                             " online: " acc)
                                            (let ((name (if (pair? (car users))
                                                            (car (car users)) "?")))
                                              (loop (cdr users)
                                                    (if (string=? acc "")
                                                        name
                                                        (string-append acc ", " name)))))))
                                  "offline")))))))

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
             ,@*log*
             (div (@ (class "prompt"))
                  ,(current-prompt)
                  (textarea (@ (id "expression") (class "repl-text")
                               (rows "1") (keydown ,maybe-eval)
                               (keyup ,on-keyup) (input ,auto-resize)))
                  ,@(if (string=? *current-suggestion* "")
                        '()
                        (list `(span (@ (class "ghost-text-suggestion"))
                                     ,*current-suggestion*)))
                  (span (@ (class "paren-indicator")) ,(paren-indicator))))))

(define (render-tab-bar)
  `(div (@ (class "tab-bar"))
        (div (@ (class ,(string-append "tab" (if (eq? *mode* 'outer) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!) (refresh!) (scroll-to-bottom!)))))
             "xorg")
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
  (if (string=? *code-viewer-content* "")
      `(div)
      `(div (@ (id "code-viewer") (class "code-viewer"))
            (div (@ (class "code-viewer-header"))
                 ,(string-append "organization code ("
                    (if (eq? *syntax-mode* 'wisp) "wisp" "lisp") ")"))
            (pre (@ (id "code-viewer-content") (class "code-viewer-content"))
                 ,*code-viewer-content*))))

(define (render)
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
             ,(render-repl))
        ,(render-code-viewer)))

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
(let ((saved-mode (ls-get-item "xorg-syntax-mode")))
  (when (and saved-mode (string=? saved-mode "wisp"))
    (set! *syntax-mode* 'wisp)))

;;; ── Restore persisted orgs from localStorage ──────────────────────────────
(let ((index (load-org-index)))
  (for-each
   (lambda (name)
     (when (string? name)
       (let* ((kp (if (has-preloaded-key-pair? name)
                      (get-preloaded-key-pair name)
                      (generate-key-pair)))
              (store (make-local-storage-store (string-append "xorg-" name))))
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

(refresh!)
(add-event-listener!/wrap (document-body) "keydown" global-keydown)

;;; ── WebSocket relay connection ──────────────────────────────────────────
;;; One connection per client. Registers all orgs' pubkeys.

(define *ws* #f)            ;; WebSocket connection
(define *connected?* #f)    ;; #t after connected
(define *online-users* '()) ;; list of (name pk-prefix) from relay presence

(define (register-all-keys!)
  "Send all local orgs' public keys to the relay."
  (when (and *ws* *connected?*)
    (let ((keys (map (lambda (e) (key-pair->public-key (org-entry-key-pair e))) *orgs*)))
      (unless (null? keys)
        (ws-send *ws* (call-with-output-string
                        (lambda (p) (write `(register-keys ,keys) p))))))))

(define (announce-presence!)
  "Announce our display name to the relay."
  (when (and *ws* *connected?* *current-org-name*)
    (ws-send *ws* (call-with-output-string
                    (lambda (p) (write `(announce ,*current-org-name*) p))))))

(define (request-who!)
  "Ask the relay who is online."
  (when (and *ws* *connected?*)
    (ws-send *ws* "(who)")))

(define-foreign ws-open
  "webSocket" "new"
  (ref string) -> (ref extern))
(define-foreign ws-send
  "webSocket" "send"
  (ref extern) (ref string) -> none)
(define-foreign ws-on-open!
  "webSocket" "setOnOpen"
  (ref extern) (ref extern) -> none)
(define-foreign ws-on-message!
  "webSocket" "setOnMessage"
  (ref extern) (ref extern) -> none)
(define-foreign ws-on-close!
  "webSocket" "setOnClose"
  (ref extern) (ref extern) -> none)

(define *relay-url*
  (let ((param (url-param-get "relay")))
    (if (and (string? param) (> (string-length param) 0))
        param
        "wss://xorg-relay.fly.dev")))

;; Auto-connect to relay (default: xorg-relay.fly.dev, override with ?relay=ws://...)
;; Registration happens later when user enters an org (in do-enter!)
(when (and (string? *relay-url*) (> (string-length *relay-url*) 0))
  (let ((ws (ws-open *relay-url*)))
    (set! *ws* ws)

    (ws-on-open! ws
      (procedure->external
       (lambda ()
         (set! *connected?* #t)
         (log-append! `(span (@ (class "result-text"))
                             "Connected to relay. Create an org and enter it.\n"))
         (request-who!)
         (when *current-org-name* (announce-presence!))
         (refresh!))))

    (ws-on-message! ws
      (procedure->external
       (lambda (data)
         ;; Try to parse the message as a Scheme expression
         (let ((msg (with-exception-handler
                      (lambda (e) #f)
                      (lambda () (read (open-input-string data)))
                      #:unwind? #t)))
           (match msg
             ;; Signup confirmation from relay/signup-agent
             ('(signup-ok)
              (set! *signup-pending?* #f)
              (log-append! `(span (@ (class "result-text"))
                ,(string-append
                   "✓ Account registered!\n"
                   "  Check your email for connection details.\n"
                   "  Run (export-ssh-key) to get your SSH public key.\n"
                   "  Then: guix deploy deploy/guix/machines.scm\n"))))

             ;; Signup error from relay/signup-agent
             (('signup-error (? string? reason))
              (set! *signup-pending?* #f)
              (log-append! `(span (@ (class "error-text"))
                ,(string-append "Signup failed: " reason "\n"))))

             ;; Presence update — list of online users
             (('presence users)
              (set! *online-users* (if (list? users) users '())))

             ;; Who response
             (('who-list users)
              (set! *online-users* (if (list? users) users '())))

             ;; Anything else — log as relay message
             (_
              (log-append! `(span (@ (class "output-text"))
                                  ,(string-append "relay: " data "\n"))))))
         (refresh!))))

    (ws-on-close! ws
      (procedure->external
       (lambda ()
         (set! *connected?* #f)
         (log-append! `(span (@ (class "error-text"))
                             "Disconnected from relay.\n"))
         (refresh!))))

    (log-append! `(span (@ (class "info-text"))
                        ,(string-append "Connecting to relay...\n")))
    (refresh!)))
