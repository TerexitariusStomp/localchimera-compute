;;; module/playnet/mcp.scm — MCP server as a Goblins capability actor
;;;
;;; Tools are capability actors passed at construction time.
;;; Possession IS access — no ACL list, no dynamic tool registration.
;;; To add tools, create a new ^mcp-server with the extended tools list.
;;; To restrict, pass an attenuated server with fewer tools.
;;;
;;; Both ^tool-cap and ^mcp-server are define-actor for persistence.

(define-module (playnet mcp)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet org)
  #:use-module (playnet gplay)
  #:use-module (playnet capabilities)
  #:use-module (ice-9 receive)
  #:use-module (srfi srfi-1)
  #:export (^tool-cap
            ^mcp-server
            mcp-server-methods
            make-tool-cap
            make-mcp-server
            make-playnet-mcp-server))

;;; ── ^tool-cap ────────────────────────────────────────────────────────────────
;;; A single MCP tool as a capability actor.
;;;   name: string tool identifier
;;;   description: string for LLM context
;;;   handler: a procedure (lambda (args) ...) where args is an alist
;;;   read-only?: boolean — hints whether this tool mutates state
;;;
;;; Persistence: name, description, read-only? survive round-trip.
;;; The handler is NOT serializable — on restore it becomes a stub
;;; that errors until re-registered.  This matches the pattern of
;;; ^output-port (which restores to current-output-port).

(define-actor (^tool-cap bcom name description handler read-only?)
  #:version 1
  #:portrait
  (lambda () (list name description read-only?))
  #:restore
  (lambda (version rname rdesc rro?)
    (spawn ^tool-cap rname rdesc
           (lambda (args)
             (error "Tool handler not restored — re-register tool" rname))
           rro?))
  (methods
   [(call args)        (handler args)]
   [(name)             name]
   [(description)      description]
   [(read-only?)       read-only?]
   [(schema)
    `((name        . ,name)
      (description . ,description)
      (read-only   . ,read-only?))]))

(define* (make-tool-cap vat name description handler #:key (read-only? #f))
  "Convenience: spawn a ^tool-cap in VAT."
  (with-vat vat (spawn ^tool-cap name description handler read-only?)))

;;; ── ^mcp-server ──────────────────────────────────────────────────────────────
;;; MCP server as a capability actor.
;;;   tools: alist of (name . ^tool-cap-ref)
;;;
;;; Possession IS access — no dynamic registration from outside.
;;; To add tools, create a new ^mcp-server with the extended tools list.
;;; To restrict, pass an attenuated server with fewer tools.
;;;
;;; Persistence: tools is an alist of (string . actor-ref) — fully serializable.
;;;
;;; Extensible via (extend-methods (mcp-server-methods tools) ...) pattern
;;; from Mandy/ActivityPub-on-Goblins — build server variants without
;;; duplicating base behavior.

(define (mcp-server-methods tools)
  "Base method table for MCP servers. Reusable via extend-methods:

   (extend-methods (mcp-server-methods tools)
     ((list-resources) ...)
     ((read-resource uri) ...))"
  (methods
   [(list-tools)
    (map (lambda (t) ($ (cdr t) 'schema)) tools)]
   [(call name args)
    (let ((tool (assoc name tools)))
      (if tool
          ($ (cdr tool) 'call args)
          (error "Unknown tool" name)))]
   [(get-tool name)
    (let ((t (assoc name tools)))
      (and t (cdr t)))]
   [(tool-names)
    (map car tools)]))

(define-actor (^mcp-server bcom tools)
  #:version 1
  (mcp-server-methods tools))

(define (make-mcp-server vat . tool-pairs)
  "Convenience: (make-mcp-server vat name1 tool1 name2 tool2 ...)
   tool-pairs: alternating name string and ^tool-cap actor ref"
  (let loop ((pairs tool-pairs) (acc '()))
    (if (null? pairs)
        (with-vat vat (spawn ^mcp-server (reverse acc)))
        (loop (cddr pairs)
              (cons (cons (car pairs) (cadr pairs)) acc)))))

;;; ── Standard playnet tools factory ──────────────────────────────────────────────

(define* (make-playnet-mcp-server vat org
                                #:key
                                (allow-eval? #f)
                                (allow-modify? #f)
                                (allow-history? #t)
                                (allow-bindings? #t))
  "Build a standard MCP server for playnet interaction.
   Capabilities are gated by keyword flags — start minimal, add as needed.

   allow-eval?     — evaluate arbitrary Scheme in the org (powerful!)
   allow-modify?   — call (modify! name value) on ungoverned names
   allow-history?  — read org history (read-only)
   allow-bindings? — read org bindings (read-only)"
  (let* ((ref (org-ref org))
         (v   (org-vat org)))
    (apply make-mcp-server v
           (append
            (if allow-bindings?
                (list "playnet-bindings"
                      (make-tool-cap v
                        "playnet-bindings"
                        "List all current bindings in the org"
                        (lambda (_args)
                          (format #f "~s" ($ ref 'bindings)))
                        #:read-only? #t))
                '())
            (if allow-history?
                (list "playnet-history"
                      (make-tool-cap v
                        "playnet-history"
                        "Show recent org history entries"
                        (lambda (args)
                          (let* ((n (or (assoc-ref args "count") 10))
                                 (h ($ ref 'history))
                                 (len (length h))
                                 (start (max 0 (- len n))))
                            (format #f "~s" (drop h start))))
                        #:read-only? #t))
                '())
            (if allow-eval?
                (list "playnet-eval"
                      (make-tool-cap v
                        "playnet-eval"
                        "Evaluate a Scheme expression in the org. Returns the result."
                        (lambda (args)
                          (let* ((expr-str (assoc-ref args "expression"))
                                 (result (evaluate
                                          (call-with-input-string expr-str read)
                                          ref '()
                                          ($ ref 'current-expressor))))
                            (format #f "~s" result)))
                        #:read-only? #f))
                '())
            (if allow-modify?
                (list "playnet-modify"
                      (make-tool-cap v
                        "playnet-modify"
                        "Set a binding in the org: (modify! name value)"
                        (lambda (args)
                          (let ((name (string->symbol (assoc-ref args "name")))
                                (value-str (assoc-ref args "value")))
                            (evaluate
                             `(modify! ',name ,(call-with-input-string value-str read))
                             ref '()
                             ($ ref 'current-expressor))
                            "ok"))
                        #:read-only? #f))
                '())))))
