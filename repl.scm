(use-modules (hoot eval)
             (hoot ffi)
             (hoot hashtables)
             ((hoot error-handling) #:select (format-exception))
             (ice-9 match)
             (repl-environment)
             (xorg play)
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

(define procedure->external/cached
  (let ((cache (make-weak-key-hashtable)))
    (lambda (proc)
      (or (weak-key-hashtable-ref cache proc)
          (let ((f (procedure->external proc)))
            (weak-key-hashtable-set! cache proc f)
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
     (void . ,(lambda () (if #f #f)))
     (env-history . ,env-history) (env-bindings . ,env-bindings))
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

(define (format-binding pair)
  (let ((name (car pair)) (val (cdr pair)))
    (string-append "  " (symbol->string name) " = "
      (cond
        ((procedure? val) (string-append "<procedure " (symbol->string name) ">"))
        ((expressor? val) (string-append "<expressor " (symbol->string (or (expressor-name val) '?)) ">"))
        (else (call-with-output-string (lambda (p) (%write val p))))))))

(define (format-history-entry entry)
  (string-append
    "  v" (number->string (history-version entry))
    " [" (symbol->string (or (expressor-name (history-expressor entry)) '?))
    "]: " (call-with-output-string (lambda (p) (%write (history-expr entry) p)))))

(define (%join-lines lst)
  (if (null? lst) ""
      (let lp ((rest (cdr lst)) (acc (car lst)))
        (if (null? rest) acc (lp (cdr rest) (string-append acc "\n" (car rest)))))))

(define (format-env-context env)
  (let* ((bindings (env-bindings env))
         (history (env-history env))
         (exp-name (or (expressor-name (env-expressor env)) '?))
         (recent (let ((h (reverse history)))
                   (if (> (length h) 10) (list-tail h (- (length h) 10)) h))))
    (string-append
      "You are an AI inside xorg, a Scheme-based system for programmable organizations.\n\n"
      "Current expressor: " (symbol->string exp-name) "\n\n"
      "Bindings:\n" (%join-lines (map format-binding bindings))
      "\n\nRecent history:\n" (%join-lines (map format-history-entry recent))
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

(define (web-ai-query prompt env)
  (unless *ai-api-key* (error "No API key. Use (set-api-key! \"sk-or-...\")"))
  (ai-chat (format-env-context env) prompt *ai-api-key* *ai-model*))

(define (web-ai-query-and-eval prompt env)
  (unless *ai-api-key* (error "No API key. Use (set-api-key! \"sk-or-...\")"))
  (let* ((ctx (string-append (format-env-context env)
               "\n\nIMPORTANT: Respond with ONLY a single valid Scheme "
               "S-expression. No explanation, no markdown. "
               "Example: (modify! 'greeting \"hello\")"))
         (response (ai-chat ctx prompt *ai-api-key* *ai-model*)))
    (read (open-input-string (strip-code-fences response)))))

(set-ai-handler! web-ai-query)
(set-ai-eval-handler! web-ai-query-and-eval)

;;; ── Org management ────────────────────────────────────────────────────────

(define hoot-env (repl-environment))

(define *orgs* '())
(define *mode* 'outer)
(define *current-org-name* #f)
(define *env* (make-initial-env base-bindings))

(define *sidebar-collapsed* #f)
(define *sidebar-selected-org* #f)   ;; string or #f

(define (org-save!)
  (when *current-org-name*
    (set! *orgs*
      (cons (cons *current-org-name* *env*)
            (let loop ((lst *orgs*))
              (cond ((null? lst) '())
                    ((string=? (caar lst) *current-org-name*) (loop (cdr lst)))
                    (else (cons (car lst) (loop (cdr lst))))))))))

(define (org-lookup name)
  (let loop ((lst *orgs*))
    (cond ((null? lst) #f)
          ((string=? (caar lst) name) (car lst))
          (else (loop (cdr lst))))))

(define *log*
  (list `(span (@ (class "info-text"))
               ,(string-append
                 "Welcome to meta-org!\n"
                 "\n"
                 "An organization is a program that writes itself.\n"
                 "This is a metacircular substrate for programmable\n"
                 "organizations — identity, memory, and self-modification.\n"
                 "\n"
                 "── Getting Started ──────────────────────────────\n"
                 "\n"
                 "  (make-org \"alpha\")   create an org\n"
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
                 "Create identities:\n"
                 "  (defexpressor 'alice \"alice-key\")\n"
                 "  (defexpressor 'bob \"bob-key\")\n"
                 "\n"
                 "Act as an identity:\n"
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
                 "── Language Forms ──────────────────────────────\n"
                 "\n"
                 "define, lambda, let, let* (named let), letrec,\n"
                 "begin, if, cond, case, and, or, when, unless, do,\n"
                 "quote. Lambdas capture bindings but adopt their\n"
                 "caller's identity — logic and authority are separate.\n"
                 "\n"
                 "── AI Agent ────────────────────────────────────\n"
                 "\n"
                 "An AI can participate as a governed expressor.\n"
                 "It sees your bindings, history, and identity.\n"
                 "Its actions pass through validators like any other.\n"
                 "\n"
                 "  (set-api-key! \"sk-or-...\")   set OpenRouter key\n"
                 "  (set-ai-model! \"...\")        change model\n"
                 "  (ai \"what should we do?\")    ask, get text back\n"
                 "  (ai-eval \"set x to 42\")      AI writes code, it runs\n"
                 "\n"))))

(define (log-append! . lines)
  (set! *log* (append *log* lines)))

(define (current-prompt)
  (if (eq? *mode* 'outer)
      "meta-org> "
      (string-append "play[" (symbol->string (or (expressor-name (env-expressor *env*)) '?)) "]> ")))

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
          (let ((result (evaluate exp *env*)))
            (let ((out-str (get-output-string output)))
              (unless (string=? out-str "")
                (log-append! `(span (@ (class "output-text")) ,out-str))))
            (if (env? result)
                (begin (set! *env* result) (org-save!))
                (let ((result-port (open-output-string)))
                  (write result result-port)
                  (log-append! `(span (@ (class "result-text"))
                                      ,(string-append "=> " (get-output-string result-port) "\n"))))))))
      #:unwind? #t)))

(define (do-enter! name)
  (let ((org (org-lookup name)))
    (when org
      (org-save!)
      (set! *mode* 'inner)
      (set! *current-org-name* name)
      (set! *env* (cdr org))
      (set! *sidebar-selected-org* name)
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "Entering org '" name "'.\n"))))))

(define (do-exit!)
  (when (eq? *mode* 'inner)
    (org-save!)
    (set! *mode* 'outer)
    (let ((name *current-org-name*))
      (set! *current-org-name* #f)
      (log-append! `(span (@ (class "info-text"))
                          ,(string-append "Left org '" name "'.\n"))))))

(define (handle-command exp)
  (match exp
    (('make-org (? string? name))
     (if (org-lookup name)
         (log-append! `(span (@ (class "error-text"))
                             ,(string-append "Org already exists: " name "\n")))
         (begin
           (set! *orgs* (cons (cons name (make-initial-env base-bindings)) *orgs*))
           (set! *sidebar-selected-org* name)
           (log-append! `(span (@ (class "result-text"))
                               ,(string-append "Created org: " name "\n")))))
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
         ;; In inner mode, use the meta-org evaluator
         ((eq? *mode* 'inner)
          (eval-play! exp)
          (loop))
         ;; In outer mode, use Hoot's R7RS eval
         (else
          (let ((output (open-output-string)))
            (with-exception-handler
              (lambda (exn)
                (let ((err-port (open-output-string)))
                  (format-exception exn err-port)
                  (log-append! `(span (@ (class "error-text"))
                                      ,(get-output-string err-port)))))
              (lambda ()
                (parameterize ((current-output-port output))
                  (call-with-values
                    (lambda () (eval exp hoot-env))
                    (lambda vals
                      (let ((out-str (get-output-string output)))
                        (unless (string=? out-str "")
                          (log-append! `(span (@ (class "output-text")) ,out-str))))
                      (for-each
                        (lambda (val)
                          (let ((p (open-output-string)))
                            (write val p)
                            (log-append! `(span (@ (class "result-text"))
                                                ,(string-append "=> " (get-output-string p) "\n")))))
                        vals)))))
              #:unwind? #t))
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
          (eval! exp)
          (refresh!)
          (scroll-to-bottom!))))
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
    (unless (= depth *paren-depth*)
      (set! *paren-depth* depth)
      (refresh!))))

;;; ── Sidebar event handlers ───────────────────────────────────────────────

(define (toggle-sidebar! event)
  (set! *sidebar-collapsed* (not *sidebar-collapsed*))
  (refresh!))

(define (sidebar-select-org! name event)
  (set! *sidebar-selected-org* name)
  (refresh!))

(define (sidebar-enter-org! name event)
  (if (and *current-org-name* (string=? name *current-org-name*))
      (begin (do-exit!) (refresh!) (scroll-to-bottom!))
      (begin (do-enter! name) (refresh!) (scroll-to-bottom!))))

;;; ── Inspector helpers ───────────────────────────────────────────────────

(define (unique-expressors history)
  (let loop ((entries history) (seen '()) (result '()))
    (if (null? entries)
        (reverse result)
        (let* ((exp (history-expressor (car entries)))
               (name (expressor-name exp)))
          (if (memq name seen)
              (loop (cdr entries) seen result)
              (loop (cdr entries) (cons name seen) (cons exp result)))))))

(define (format-value val name)
  (cond
    ((procedure? val) (string-append "<proc " (symbol->string name) ">"))
    ((expressor? val) (string-append "<expressor "
                        (symbol->string (or (expressor-name val) '?)) ">"))
    (else (call-with-output-string (lambda (p) (%write val p))))))

;;; ── Inspector section renderers ─────────────────────────────────────────

(define (render-bindings-section bindings)
  `(div (@ (class "section"))
        (div (@ (class "section-header")) "bindings")
        ,@(if (null? bindings)
              (list `(div (@ (class "inspector-row")) "  (empty)"))
              (map (lambda (pair)
                     `(div (@ (class "inspector-row"))
                           (span (@ (class "name"))
                                 ,(symbol->string (car pair)))
                           " "
                           (span (@ (class "value"))
                                 ,(format-value (cdr pair) (car pair)))))
                   bindings))))

(define (render-history-section history)
  `(div (@ (class "section"))
        (div (@ (class "section-header")) "history")
        ,@(if (null? history)
              (list `(div (@ (class "inspector-row")) "  (none)"))
              (map (lambda (entry)
                     `(div (@ (class "inspector-row"))
                           (span (@ (class "version"))
                                 ,(string-append "v"
                                    (number->string (history-version entry))))
                           " "
                           (span (@ (class "expressor-id"))
                                 ,(symbol->string
                                    (or (expressor-name
                                          (history-expressor entry)) '?)))
                           " "
                           (span (@ (class "value"))
                                 ,(call-with-output-string
                                    (lambda (p)
                                      (%write (history-expr entry) p))))))
                   history))))

(define (render-expressors-section expressors)
  `(div (@ (class "section"))
        (div (@ (class "section-header")) "expressors")
        ,@(if (null? expressors)
              (list `(div (@ (class "inspector-row")) "  (none)"))
              (map (lambda (exp)
                     `(div (@ (class "inspector-row"))
                           (span (@ (class "name"))
                                 ,(symbol->string
                                    (or (expressor-name exp) '?)))))
                   expressors))))

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
  (let* ((org (org-lookup name))
         (env (if org (cdr org)
                  (if (and *current-org-name* (string=? name *current-org-name*))
                      *env* #f))))
    (if (not env) ""
        (let* ((active? (and *current-org-name* (string=? name *current-org-name*)))
               (bindings (env-bindings env))
               (history (env-history env))
               (expressors (unique-expressors history)))
          `(div (@ (class "org-detail"))
                (div (@ (class "detail-header"))
                     (span (@ (class "org-name")) ,name)
                     (span (@ (class "org-action")
                               (click ,(lambda (e) (sidebar-enter-org! name e))))
                           ,(if active? "exit" "enter")))
                ,(render-bindings-section bindings)
                ,(render-history-section history)
                ,(render-expressors-section expressors))))))

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
             (span (@ (class "paren-indicator")) ,(paren-indicator)))))

(define (render)
  `(div (@ (class "ide"))
        ,(render-sidebar)
        (div (@ (class "main"))
             ,@(if *sidebar-collapsed*
                   (list `(span (@ (class "expand-tab")
                                   (click ,toggle-sidebar!))
                                "\u00bb"))
                   '())
             ,(render-repl))))

(refresh!)
