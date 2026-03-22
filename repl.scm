(use-modules (hoot ffi)
             (hoot hashtables)
             ((hoot error-handling) #:select (format-exception))
             (ice-9 match)
             (ice-9 receive)
             (fibers channels)
             (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer fake)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (xorg gplay)
             (xorg autocomplete)
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
                  (remove-event-listener! node name-str val))))
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
(define *ai-model* "openai/gpt-4o-mini")

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

(define (format-org-context ref)
  (let* ((bindings ($ ref 'bindings))
         (history ($ ref 'history))
         (exp-name (or ($ ref 'expressor-name ($ ref 'current-expressor)) '?))
         (recent (let ((h (reverse history)))
                   (if (> (length h) 10) (list-tail h (- (length h) 10)) h))))
    (string-append
      "You are an AI inside xorg, a Scheme-based system for programmable organizations.\n\n"
      "Current expressor: " (symbol->string exp-name) "\n\n"
      "Bindings:\n" (%join-lines (map (lambda (b) (format-binding b ref)) bindings))
      "\n\nRecent history:\n" (%join-lines (map (lambda (e) (format-history-entry e ref)) recent))
      "\n\nSpecial forms: (modify! 'name value), (enact! validator), "
      "(rollback! version), (defexpressor name key), (as id expr), "
      "(show-history), (show-expressors), (lambda (args) body), "
      "(if test then else), (quote expr).\n")))

;;; ── AI handlers ─────────────────────────────────────────────────────────

(define (strip-code-fences str)
  (let* ((s (%trim str))
         (s (cond ((%starts-with? s "```scheme") (substring s 9 (string-length s)))
                  ((%starts-with? s "```scm")    (substring s 6 (string-length s)))
                  ((%starts-with? s "```")       (substring s 3 (string-length s)))
                  (else s)))
         (s (if (%ends-with? s "```") (substring s 0 (- (string-length s) 3)) s)))
    (%trim s)))

(define (web-ai-query prompt org)
  (unless *ai-api-key* (error "No API key. Use (set-api-key! \"sk-or-...\")"))
  (ai-chat (format-org-context org) prompt *ai-api-key* *ai-model*))

(define (web-ai-query-and-eval prompt org)
  (unless *ai-api-key* (error "No API key. Use (set-api-key! \"sk-or-...\")"))
  (let* ((ctx (string-append (format-org-context org)
               "\n\nIMPORTANT: Respond with ONLY a single valid Scheme "
               "S-expression. No explanation, no markdown. "
               "Example: (modify! 'greeting \"hello\")"))
         (response (ai-chat ctx prompt *ai-api-key* *ai-model*)))
    (read (open-input-string (strip-code-fences response)))))

(set-ai-handler! web-ai-query)
(set-ai-eval-handler! web-ai-query-and-eval)

;;; ── OCapN network ────────────────────────────────────────────────────────

(define ocapn-vat (spawn-vat #:name "OCapN"))

(define fake-network
  (with-vat ocapn-vat
    (spawn ^fake-network)))

;; Network state
(define *mycapn* #f)        ;; MyCapN node (set after connect)
(define *net-vat* #f)       ;; Vat where mycapn lives
(define *connected?* #f)    ;; #t after successfully connecting
(define *remote-inbox* #f)  ;; Remote org's inbox (set after auto-connect)

;;; ── Org management ────────────────────────────────────────────────────────
;;; Every org entry: (name vat ref inbox incanter key-pair controllers . log)
;;; controllers: alist of (org-name . controller)

(define *orgs* '())
(define *pending-joins* '()) ;; alist: (joiner-name target-name sub-unsealer msg-id identity)
(define *mode* 'outer)
(define *current-org-name* #f)
(define *vat* #f)
(define *org* #f)

(define *sidebar-collapsed* #f)
(define *sidebar-selected-org* #f)   ;; string or #f
(define *expressor-filter* #f)       ;; symbol or #f — filter history by expressor name

(define (org-entry-name e) (list-ref e 0))
(define (org-entry-vat e) (list-ref e 1))
(define (org-entry-ref e) (list-ref e 2))
(define (org-entry-inbox e) (list-ref e 3))
(define (org-entry-incanter e) (list-ref e 4))
(define (org-entry-key-pair e) (list-ref e 5))
(define (org-entry-controllers e) (list-ref e 6))
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
                                   (org-entry-controllers old))
                             *log*)))
          (set! *orgs*
            (cons entry
                  (let loop ((lst *orgs*))
                    (cond ((null? lst) '())
                          ((string=? (car (car lst)) *current-org-name*) (loop (cdr lst)))
                          (else (cons (car lst) (loop (cdr lst)))))))))))))

(define (org-set-controllers! name controllers)
  "Update the controllers alist for an org."
  (set! *orgs*
    (map (lambda (e)
           (if (string=? (car e) name)
               (append (list (list-ref e 0) (list-ref e 1) (list-ref e 2)
                             (list-ref e 3) (list-ref e 4) (list-ref e 5)
                             controllers)
                       (list-tail e 7))
               e))
         *orgs*)))

(define (org-lookup name)
  (let loop ((lst *orgs*))
    (cond ((null? lst) #f)
          ((string=? (caar lst) name) (car lst))
          (else (loop (cdr lst))))))

(define *log*
  (list `(span (@ (class "info-text"))
               ,(string-append
                 "Welcome to xorg!\n"
                 "\n"
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
                 "  (enact! (lambda (expressor name value old new)\n"
                 "            (not (equal? value #f))))\n"
                 "\n"
                 "Inspect:\n"
                 "  (show-history)       versioned ledger\n"
                 "  (show-expressors)    all known identities\n"
                 "  proposal             look up any binding\n"
                 "\n"
                 "Rollback (replays with original identities):\n"
                 "  (rollback! 2)\n"
                 "\n"
                 "── Cross-Org ──────────────────────────────────\n"
                 "\n"
                 "Local (same browser):\n"
                 "  (join-org \"alpha\")                 request to join\n"
                 "  (approve-member 0 \"alice\")         approve member\n"
                 "  (act-in \"alpha\" (modify! 'x 1))   act in another org\n"
                 "  (public-key)                       show this org's key\n"
                 "\n"
                 "Remote (connect to server):\n"
                 "  (connect \"ocapn://ws:...\")         join server org\n"
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
          (set! *code-viewer-content* (with-vat *vat* (serialize-org-code *org*))))
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
          (log-append! `(span (@ (class "error-text"))
                              ,(get-output-string err-port)))))
      (lambda ()
        (parameterize ((current-output-port output))
          (with-vat *vat*
            (let ((result (evaluate exp *org* '() ($ *org* 'current-expressor))))
              (let ((out-str (get-output-string output)))
                (unless (string=? out-str "")
                  (log-append! `(span (@ (class "output-text")) ,out-str))))
              (unless (eq? result (if #f #f))
                (let ((result-port (open-output-string)))
                  (if (string? result)
                      (display result result-port)
                      (write result result-port))
                  (log-append! `(span (@ (class "result-text"))
                                      ,(string-append "=> " (get-output-string result-port) "\n")))))))))
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

(define (handle-command exp)
  (match exp
    (('make-org (? string? name))
     (if (org-lookup name)
         (log-append! `(span (@ (class "error-text"))
                             ,(string-append "Org already exists: " name "\n")))
         (let* ((kp (generate-key-pair))
                (pk (key-pair->public-key kp))
                (vat (spawn-vat))
                (result (with-vat vat
                          (let* ((org (make-initial-org base-bindings #:public-key pk))
                                 (triple (receive (warden incanter)
                                           (spawn-warding-pair)
                                           (let ((inbox (spawn ^org-inbox org '() 0 warden incanter)))
                                             (list org inbox incanter)))))
                            triple)))
                (ref (list-ref result 0))
                (inbox (list-ref result 1))
                (incanter (list-ref result 2))
                (pk-display (let ((p (open-output-string)))
                              (write pk p)
                              (let ((s (get-output-string p)))
                                (if (> (string-length s) 50)
                                    (string-append (substring s 0 50) "...")
                                    s)))))
           (set! *orgs* (cons (list name vat ref inbox incanter kp '()) *orgs*))
           (set! *sidebar-selected-org* name)
           (log-append! `(span (@ (class "result-text"))
                               ,(string-append "Created org: " name "\n  key: " pk-display "\n")))))
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
     (if (org-lookup name)
         (begin
           (when (and *current-org-name* (string=? name *current-org-name*)) (do-exit!))
           (set! *orgs* (let loop ((lst *orgs*))
             (cond ((null? lst) '())
                   ((string=? (caar lst) name) (loop (cdr lst)))
                   (else (cons (car lst) (loop (cdr lst)))))))
           (when (and *sidebar-selected-org* (string=? name *sidebar-selected-org*))
             (set! *sidebar-selected-org* #f))
           (log-append! `(span (@ (class "result-text")) ,(string-append "Deleted org: " name "\n"))))
         (log-append! `(span (@ (class "error-text")) ,(string-append "Unknown org: " name "\n"))))
     #t)
    ;; ── Cross-org commands ──

    ;; join-org — from inside an org, request to join another
    (('join-org (? string? target-name))
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
                                                           (number->string msg-id) ").\n"))))))))))
     #t)

    ;; approve-member — approve a pending membership request
    (('approve-member (? number? msg-id) (? string? name))
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
                     ;; Store controller on the joiner's org
                     (let ((joiner (org-lookup name)))
                       (when joiner
                         (org-set-controllers! name
                           (cons (cons *current-org-name* controller)
                                 (org-entry-controllers joiner)))))))
                 (set! *pending-joins*
                   (let loop ((lst *pending-joins*))
                     (cond ((null? lst) '())
                           ((and (string=? (list-ref (car lst) 0) name)
                                 (string=? (list-ref (car lst) 1) *current-org-name*))
                            (loop (cdr lst)))
                           (else (cons (car lst) (loop (cdr lst)))))))
                 (log-append! `(span (@ (class "result-text"))
                                     ,(string-append "Approved '" name "'.\n")))))))
     #t)

    ;; act-in — evaluate in another org through a controller
    (('act-in (? string? target-name) body-expr)
     (if (not *current-org-name*)
         (log-append! `(span (@ (class "error-text"))
                             "Must be inside an org to act-in another.\n"))
         (let* ((current (org-lookup *current-org-name*))
                (controllers (org-entry-controllers current))
                (entry (assoc target-name controllers)))
           (if (not entry)
               (log-append! `(span (@ (class "error-text"))
                                   ,(string-append "No controller for: " target-name
                                                   ". Join and get approved first.\n")))
               (let ((controller (cdr entry))
                     (target (org-lookup target-name)))
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
                   #:unwind? #t)))))
     #t)

    ;; connect — connect to a server-hosted org via websocket sturdyref
    ;; Does everything: creates websocket, enlivens sturdyref, submits membership
    (('connect (? string? sref-str))
     (if (not *current-org-name*)
         (log-append! `(span (@ (class "error-text"))
                             "Must be inside an org to connect.\n"))
         (let ((sref (string->ocapn-id sref-str))
               (my-pk (with-vat *vat* ($ *org* 'public-key)))
               (my-name *current-org-name*)
               (net-vat (spawn-vat #:name "network")))
           (set! *net-vat* net-vat)
           (with-vat net-vat
             (let* ((netlayer (spawn ^websocket-netlayer))
                    (mycapn (spawn-mycapn netlayer)))
               (set! *mycapn* mycapn)
               (on (<- mycapn 'enliven sref)
                   (lambda (remote-inbox)
                     (receive (sub-sealer sub-unsealer sub-sealed?)
                       (spawn-sealer-triplet)
                       (let ((my-identity
                              (spawn (lambda (bcom)
                                (methods
                                 [(name) (string->symbol my-name)]
                                 [(subscription-sealer) sub-sealer]
                                 [(subscription-unsealer) sub-unsealer]
                                 [(public-key) my-pk])))))
                         (on (<- remote-inbox 'submit
                                  `(request-membership ,my-name)
                                  my-identity)
                             (lambda (msg-id)
                               (set! *pending-joins*
                                 (cons (list my-name "remote"
                                            sub-unsealer msg-id my-identity)
                                       *pending-joins*))
                               (set! *connected?* #t)
                               (log-append! `(span (@ (class "result-text"))
                                                   ,(string-append "Connected! Membership request submitted (msg-id: "
                                                                   (number->string msg-id) ").\n"
                                                                   "Ask server admin to (approve " (number->string msg-id) " \"" my-name "\").\n")))
                               (refresh!)))))))))
           (log-append! `(span (@ (class "info-text"))
                               "Connecting to server...\n"))))
     #t)

    ;; join-server — submit membership to the auto-connected remote org
    ('(join-server)
     (cond
      ((not *current-org-name*)
       (log-append! `(span (@ (class "error-text"))
                           "Must be inside an org.\n")))
      ((not *remote-inbox*)
       (log-append! `(span (@ (class "error-text"))
                           "Not connected to a server. Add ?sref=... to the URL.\n")))
      (else
       (let ((my-pk (with-vat *vat* ($ *org* 'public-key)))
             (my-name *current-org-name*))
         (with-vat *net-vat*
           (receive (sub-sealer sub-unsealer sub-sealed?)
             (spawn-sealer-triplet)
             (let ((my-identity
                    (spawn (lambda (bcom)
                      (methods
                       [(name) (string->symbol my-name)]
                       [(subscription-sealer) sub-sealer]
                       [(subscription-unsealer) sub-unsealer]
                       [(public-key) my-pk])))))
               (on (<- *remote-inbox* 'submit
                        `(request-membership ,my-name)
                        my-identity)
                   (lambda (msg-id)
                     (set! *pending-joins*
                       (cons (list my-name "server"
                                  sub-unsealer msg-id my-identity)
                             *pending-joins*))
                     (log-append! `(span (@ (class "result-text"))
                                         ,(string-append "Membership request submitted (msg-id: "
                                                         (number->string msg-id) ").\n"
                                                         "Ask server admin: (approve " (number->string msg-id) " \"" my-name "\")\n")))
                     (refresh!)))))))))
     #t)

    (_ #f)))

(define (eval! str)
  (log-append! `(span (@ (class "prompt-text")) ,(current-prompt))
               `(span (@ (class "input-text")) ,(string-append str "\n")))
  (history-push! str)
  (let ((port (open-input-string str)))
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
                (string-append (number->string (scroll-height input)) "px"))))

;;; ── Scroll helper ─────────────────────────────────────────────────────────

(define (scroll-to-bottom!)
  (let ((repl (get-element-by-id "repl")))
    (set-scroll-top! repl (scroll-height repl))))

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
         (depth (compute-paren-depth str)))
    ;; Update paren depth
    (unless (= depth *paren-depth*)
      (set! *paren-depth* depth))
    ;; Update autocomplete suggestion
    (when (and *org* (eq? *mode* 'inner))
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
                          "No orgs yet.\nUse (make-org \"name\") to create one."))
              (map render-org-item *orgs*))))

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
                       (span (@ (class "org-name")) ,name)
                       (span (@ (class "org-action")
                                 (click ,(lambda (e) (sidebar-enter-org! name e))))
                             ,(if active? "exit" "enter"))
                       (span (@ (class "org-action org-delete")
                                 (click ,(lambda (e)
                                           (when (and *current-org-name* (string=? name *current-org-name*))
                                             (do-exit!))
                                           (set! *orgs* (let loop ((lst *orgs*))
                                             (cond ((null? lst) '())
                                                   ((string=? (caar lst) name) (loop (cdr lst)))
                                                   (else (cons (car lst) (loop (cdr lst)))))))
                                           (set! *sidebar-selected-org* #f)
                                           (refresh!))))
                             "delete"))
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
            ,(render-org-list)
            ,@(if *sidebar-selected-org*
                  (list (render-org-detail *sidebar-selected-org*))
                  '()))))

;;; ── Render ────────────────────────────────────────────────────────────────

(define (paren-indicator)
  (cond
   ((= *paren-depth* 0) "")
   ((> *paren-depth* 0)
    (string-append "(" (number->string *paren-depth*) " open)"))
   (else
    (string-append (number->string (- *paren-depth*)) " extra )"))))

(define (render-repl)
  `(div (@ (id "repl") (class "repl repl-text"))
        (div (@ (class "log")) ,@*log*)
        (div (@ (class "prompt"))
             ,(current-prompt)
             (textarea (@ (id "expression") (class "repl-text")
                          (rows "1") (keydown ,maybe-eval)
                          (keyup ,on-keyup) (input ,auto-resize)))
             ,@(if (string=? *current-suggestion* "")
                   '()
                   (list `(span (@ (class "ghost-text-suggestion"))
                                ,*current-suggestion*)))
             (span (@ (class "paren-indicator")) ,(paren-indicator)))))

(define (render-tab-bar)
  `(div (@ (class "tab-bar"))
        (div (@ (class ,(string-append "tab" (if (eq? *mode* 'outer) " tab-active" "")))
                (click ,(lambda (e)
                          (when (eq? *mode* 'inner) (do-exit!) (refresh!) (scroll-to-bottom!)))))
             "outer")
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
            (div (@ (class "code-viewer-header")) "organization code")
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

(refresh!)
(add-event-listener!/wrap (document-body) "keydown" global-keydown)

;;; ── Auto-connect to server if sturdyref is in URL ─────────────────────────
(let ((sref-str (url-param-get "sref")))
  (when (and (string? sref-str) (> (string-length sref-str) 0))
    (log-append! `(span (@ (class "info-text"))
                        ,(string-append "Auto-connecting to server...\n")))
    (let ((net-vat (spawn-vat #:name "network")))
      (set! *net-vat* net-vat)
      (with-vat net-vat
        (let* ((netlayer (spawn ^websocket-netlayer))
               (mycapn (spawn-mycapn netlayer))
               (sref (string->ocapn-id sref-str)))
          (set! *mycapn* mycapn)
          (on (<- mycapn 'enliven sref)
              (lambda (remote-inbox)
                (set! *connected?* #t)
                ;; Store the remote inbox globally for join-org to use
                (set! *remote-inbox* remote-inbox)
                (log-append! `(span (@ (class "result-text"))
                                    "Connected to server org!\nUse (join-org) to request membership.\n"))
                (refresh!))))))))
