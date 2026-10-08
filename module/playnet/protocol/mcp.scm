;;; module/playnet/protocol/mcp.scm — the doors as MCP tools, from the declaration
;;;
;;; One tool per door with an HTTP form: the tool name is `object.name`, the
;;; input schema is the door's argument list as one JSON Schema object (the
;;; same object the OpenAPI operation carries, built here so the two cannot
;;; disagree), and the description is the door's doc line with its topic and
;;; audience. Two readers: tools/protocol-emit.scm writes the committed
;;; browser/api/mcp-tools.json, and (playnet gateway mcp-door) answers
;;; `tools/list` with the same vector live.

(define-module (playnet protocol mcp)
  #:use-module (playnet protocol)
  #:use-module (playnet protocol shapes)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (%mcp-protocol-version door-input-schema tool-name tool-name->door
            mcp-tool mcp-tools mcp-server-info))

;; the MCP protocol revision this server speaks (initialize answers it)
(define %mcp-protocol-version "2025-06-18")

(define (door-input-schema door)
  "The door's arguments as one JSON Schema object: properties in head order,
each carrying its shape's fragment, the argument's own description, and
x-playnet-shape; required lists the positional ones."
  (let* ((entries (door-arg-shapes door))          ; ((name shape required?) …)
         (props (map (lambda (e)
                       (let ((doc (arg-doc (car e))))
                         (cons (symbol->string (car e))
                               (append (shape-schema (cadr e))
                                       (if (and doc (not (assq 'description (shape-schema (cadr e)))))
                                           `((description . ,doc))
                                           '())
                                       `((x-playnet-shape . ,(symbol->string (cadr e))))))))
                     entries))
         (required (filter-map (lambda (e) (and (caddr e) (symbol->string (car e)))) entries)))
    `((type . "object")
      (properties . ,(if (null? props) '() props))
      ,@(if (null? required) '() `((required . ,(list->vector required))))
      (additionalProperties . #f))))

(define (tool-name d) (format #f "~a.~a" (door-object d) (door-name d)))

(define (tool-name->door name)
  "The door behind MCP tool NAME (`object.name`), or #f."
  (let ((i (string-index name #\.)))
    (and i
         (let ((object (string->symbol (substring name 0 i)))
               (door (string->symbol (substring name (+ i 1)))))
           (and (memq object '(lobby session planner))
                (door-ref object door))))))

(define (mcp-tool d)
  `((name . ,(tool-name d))
    (title . ,(format #f "~a: ~a" (door-topic d) (door-name d)))
    (description . ,(format #f "~a [~a; callable by ~a]"
                            (if (string-null? (door-doc d)) (symbol->string (door-name d)) (door-doc d))
                            (door-topic d) (door-audience d)))
    (inputSchema . ,(door-input-schema d))
    (annotations . ((readOnlyHint . ,(and (memq (door-topic d) '(knowledge)) #t))
                    (openWorldHint . #f)))
    (x-playnet-auth . ,(symbol->string (door-auth d)))
    (x-playnet-topic . ,(symbol->string (door-topic d)))
    (x-playnet-http . ,(format #f "/api/~a/~a" (door-object d) (door-name d)))))

(define (mcp-tools)
  "Every HTTP-form door as an MCP tool, in declaration order, as a vector."
  (list->vector (map mcp-tool (filter door-http? %doors))))

(define (mcp-server-info)
  `((name . "playnet gateway")
    (title . "playnet gateway doors")
    (version . ,(number->string %protocol-version))))
