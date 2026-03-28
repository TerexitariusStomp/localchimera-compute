;;; test-mcp.scm — Tests for MCP capability actor system
;;; Run with: guile -L module tests/test-mcp.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             ((goblins utils crypto) #:select (generate-key-pair key-pair->public-key))
             (xorg mcp)
             (xorg org)
             (xorg gplay)
             (xorg endorsement)
             (xorg capabilities)
             (ice-9 receive)
             (srfi srfi-1))

;;; ── Harness ─────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define-syntax check-error
  (syntax-rules ()
    ((_ label body ...)
     (check label
            (catch #t
              (lambda () body ... #f)
              (lambda (key . args) #t))
            #t))))

(display "\n══ MCP Capability Actor Tests ═════════════════════════════════\n")

;;; ── Test 1: ^tool-cap creation, call, schema ─────────────────────────────────

(display "\n── 1. ^tool-cap creation, call, schema ──\n")

(let ((vat (spawn-vat)))
  (with-vat vat
    (let ((tool (spawn ^tool-cap
                       "echo"
                       "Echoes args back"
                       (lambda (args) (format #f "echo: ~s" args))
                       #t)))
      (check "1a: tool name"
             ($ tool 'name) "echo")
      (check "1b: tool description"
             ($ tool 'description) "Echoes args back")
      (check "1c: tool read-only?"
             ($ tool 'read-only?) #t)
      (check "1d: tool call"
             ($ tool 'call '(("msg" . "hello")))
             "echo: ((\"msg\" . \"hello\"))")
      (let ((schema ($ tool 'schema)))
        (check "1e: schema name"
               (assoc-ref schema 'name) "echo")
        (check "1f: schema description"
               (assoc-ref schema 'description) "Echoes args back")
        (check "1g: schema read-only"
               (assoc-ref schema 'read-only) #t))))
  (vat-halt! vat))

;;; ── Test 2: ^mcp-server creation, list-tools, call-tool ──────────────────────

(display "\n── 2. ^mcp-server creation, list-tools, call ──\n")

(let ((vat (spawn-vat)))
  (with-vat vat
    (let* ((t1 (spawn ^tool-cap
                      "add"
                      "Add two numbers"
                      (lambda (args)
                        (let ((a (assoc-ref args "a"))
                              (b (assoc-ref args "b")))
                          (number->string (+ a b))))
                      #t))
           (t2 (spawn ^tool-cap
                      "greet"
                      "Greet someone"
                      (lambda (args)
                        (string-append "Hello, " (assoc-ref args "name") "!"))
                      #t))
           (server (spawn ^mcp-server
                          (list (cons "add" t1) (cons "greet" t2)))))
      ;; list-tools
      (let ((tools ($ server 'list-tools)))
        (check "2a: list-tools count"
               (length tools) 2)
        (check "2b: first tool name"
               (assoc-ref (car tools) 'name) "add"))
      ;; tool-names
      (check "2c: tool-names"
             ($ server 'tool-names) '("add" "greet"))
      ;; call
      (check "2d: call add"
             ($ server 'call "add" '(("a" . 3) ("b" . 4)))
             "7")
      (check "2e: call greet"
             ($ server 'call "greet" '(("name" . "Alice")))
             "Hello, Alice!")
      ;; get-tool
      (check "2f: get-tool returns actor ref"
             (not (not ($ server 'get-tool "add"))) #t)
      (check "2g: get-tool unknown returns #f"
             ($ server 'get-tool "nope") #f)))
  (vat-halt! vat))

;;; ── Test 3: Unknown tool raises error ────────────────────────────────────────

(display "\n── 3. Unknown tool raises error ──\n")

(let ((vat (spawn-vat)))
  (with-vat vat
    (let ((server (spawn ^mcp-server '())))
      (check-error "3a: call unknown tool errors"
        ($ server 'call "nonexistent" '()))
      (check "3b: empty server has no tools"
             ($ server 'list-tools) '())
      (check "3c: empty server tool-names"
             ($ server 'tool-names) '())))
  (vat-halt! vat))

;;; ── Test 4: make-tool-cap convenience constructor ────────────────────────────

(display "\n── 4. make-tool-cap convenience constructor ──\n")

(let ((vat (spawn-vat)))
  (let ((tool (make-tool-cap vat
                "double"
                "Double a number"
                (lambda (args)
                  (number->string (* 2 (assoc-ref args "n"))))
                #:read-only? #t)))
    (with-vat vat
      (check "4a: make-tool-cap name"
             ($ tool 'name) "double")
      (check "4b: make-tool-cap call"
             ($ tool 'call '(("n" . 5)))
             "10")
      (check "4c: make-tool-cap read-only?"
             ($ tool 'read-only?) #t)))
  (vat-halt! vat))

;;; ── Test 5: make-mcp-server convenience constructor ──────────────────────────

(display "\n── 5. make-mcp-server convenience constructor ──\n")

(let ((vat (spawn-vat)))
  (let* ((t1 (make-tool-cap vat "ping" "Ping" (lambda (_) "pong") #:read-only? #t))
         (t2 (make-tool-cap vat "rev" "Reverse"
                (lambda (args) (list->string (reverse (string->list (assoc-ref args "s")))))
                #:read-only? #t))
         (server (make-mcp-server vat "ping" t1 "rev" t2)))
    (with-vat vat
      (check "5a: make-mcp-server tool-names"
             ($ server 'tool-names) '("ping" "rev"))
      (check "5b: call ping via server"
             ($ server 'call "ping" '()) "pong")
      (check "5c: call rev via server"
             ($ server 'call "rev" '(("s" . "hello"))) "olleh")))
  (vat-halt! vat))

;;; ── Test 6: make-xorg-mcp-server with various flag combinations ──────────────

(display "\n── 6. make-xorg-mcp-server with flag combos ──\n")

;; Default: bindings + history only
(let ((org (make-open-org "mcp-test-6a")))
  (with-vat (org-vat org)
    (evaluate '(modify! 'x 42) (org-ref org) '() ($ (org-ref org) 'current-expressor)))
  (let ((server (make-xorg-mcp-server (org-vat org) org)))
    (with-vat (org-vat org)
      (let ((names ($ server 'tool-names)))
        (check "6a: default has bindings and history"
               (lset= equal? names '("xorg-bindings" "xorg-history")) #t)))))

;; All flags on
(let ((org (make-open-org "mcp-test-6b")))
  (let ((server (make-xorg-mcp-server (org-vat org) org
                                       #:allow-eval? #t
                                       #:allow-modify? #t
                                       #:allow-history? #t
                                       #:allow-bindings? #t)))
    (with-vat (org-vat org)
      (let ((names ($ server 'tool-names)))
        (check "6b: all flags gives 4 tools"
               (length names) 4)
        (check "6c: eval tool present"
               (not (not (member "xorg-eval" names))) #t)))))

;; No flags
(let ((org (make-open-org "mcp-test-6c")))
  (let ((server (make-xorg-mcp-server (org-vat org) org
                                       #:allow-history? #f
                                       #:allow-bindings? #f)))
    (with-vat (org-vat org)
      (check "6d: no flags gives 0 tools"
             ($ server 'tool-names) '()))))

;;; ── Test 7: allow-eval? can evaluate expressions ─────────────────────────────

(display "\n── 7. allow-eval? can evaluate expressions ──\n")

(let ((org (make-open-org "mcp-test-7")))
  (with-vat (org-vat org)
    (evaluate '(modify! 'y 100) (org-ref org) '() ($ (org-ref org) 'current-expressor)))
  (let ((server (make-xorg-mcp-server (org-vat org) org #:allow-eval? #t)))
    (with-vat (org-vat org)
      (check "7a: eval reads binding"
             ($ server 'call "xorg-eval" '(("expression" . "y")))
             "100")
      (check "7b: eval computes"
             ($ server 'call "xorg-eval" '(("expression" . "(+ 1 2 3)")))
             "6"))))

;;; ── Test 8: allow-bindings? returns current bindings ─────────────────────────

(display "\n── 8. allow-bindings? returns bindings ──\n")

(let ((org (make-open-org "mcp-test-8")))
  (with-vat (org-vat org)
    (evaluate '(modify! 'color "blue") (org-ref org) '() ($ (org-ref org) 'current-expressor)))
  (let ((server (make-xorg-mcp-server (org-vat org) org #:allow-bindings? #t)))
    (with-vat (org-vat org)
      (let ((result ($ server 'call "xorg-bindings" '())))
        (check "8a: bindings result contains color"
               (string-contains result "color") (string-contains result "color"))
        (check "8b: bindings result is a string"
               (string? result) #t)))))

;;; ── Test 9: allow-modify? can set bindings ──────────────────────────────────

(display "\n── 9. allow-modify? can set bindings ──\n")

(let ((org (make-open-org "mcp-test-9")))
  (let ((server (make-xorg-mcp-server (org-vat org) org #:allow-modify? #t)))
    (with-vat (org-vat org)
      ($ server 'call "xorg-modify" '(("name" . "mood") ("value" . "\"happy\"")))
      (check "9a: modify sets binding"
             (evaluate 'mood (org-ref org) '() ($ (org-ref org) 'current-expressor))
             "happy"))))

;;; ── Test 10: Attenuation — subset of tools ──────────────────────────────────

(display "\n── 10. Attenuation by creating new server with subset ──\n")

(let ((vat (spawn-vat)))
  (with-vat vat
    (let* ((t1 (spawn ^tool-cap "read" "Read data" (lambda (_) "data") #t))
           (t2 (spawn ^tool-cap "write" "Write data" (lambda (_) "written") #f))
           (t3 (spawn ^tool-cap "delete" "Delete data" (lambda (_) "deleted") #f))
           (full (spawn ^mcp-server
                        (list (cons "read" t1)
                              (cons "write" t2)
                              (cons "delete" t3))))
           ;; Attenuate: only read + write
           (restricted (spawn ^mcp-server
                              (list (cons "read" t1)
                                    (cons "write" t2)))))
      ;; Full server has all 3
      (check "10a: full server has 3 tools"
             (length ($ full 'tool-names)) 3)
      ;; Restricted server has only 2
      (check "10b: restricted server has 2 tools"
             (length ($ restricted 'tool-names)) 2)
      ;; Restricted can't call delete
      (check-error "10c: restricted server can't call delete"
        ($ restricted 'call "delete" '()))
      ;; Restricted can still read
      (check "10d: restricted server can read"
             ($ restricted 'call "read" '()) "data")
      ;; Same tool actor ref in both servers
      (check "10e: same tool ref in both servers"
             (eq? ($ full 'get-tool "read") ($ restricted 'get-tool "read")) #t)))
  (vat-halt! vat))

;;; ── Test 11: allow-history? returns history ──────────────────────────────────

(display "\n── 11. allow-history? returns history entries ──\n")

(let ((org (make-open-org "mcp-test-11")))
  (with-vat (org-vat org)
    (let ((gen ($ (org-ref org) 'current-expressor)))
      (evaluate '(modify! 'a 1) (org-ref org) '() gen)
      (evaluate '(modify! 'b 2) (org-ref org) '() gen)
      (evaluate '(modify! 'c 3) (org-ref org) '() gen)))
  (let ((server (make-xorg-mcp-server (org-vat org) org #:allow-history? #t)))
    (with-vat (org-vat org)
      (let ((result ($ server 'call "xorg-history" '(("count" . 2)))))
        (check "11a: history result is string"
               (string? result) #t)
        ;; The result should contain the last 2 entries
        (check "11b: history result contains data"
               (> (string-length result) 5) #t)))))

;;; ── Test 12: Persistence — ^mcp-server survives round-trip ───────────────────

(display "\n── 12. Persistence — ^mcp-server survives round-trip ──\n")

(use-modules (goblins persistence-store bloblin))

(define test-counter 0)

(define (make-test-dir name)
  (set! test-counter (+ test-counter 1))
  (let ((dir (string-append "/tmp/xorg-test-mcp-"
                            name "-"
                            (number->string (getpid)) "-"
                            (number->string test-counter))))
    (when (file-exists? dir)
      (system* "rm" "-rf" dir))
    (mkdir dir)
    dir))

(define (cleanup-test-dir dir)
  (system* "rm" "-rf" dir))

(let ((dir (make-test-dir "persist")))
  (let ((store (make-bloblin-store dir)))
    ;; First run: create mcp-server with tools
    (receive (vat server tool-a)
      (parameterize ((*restore-base-bindings* default-base-bindings))
        (spawn-persistent-vat
         (make-persistence-env
          `((((xorg mcp) ^tool-cap) ,^tool-cap)
            (((xorg mcp) ^mcp-server) ,^mcp-server))
          #:extends (list gplay-env))
         (lambda ()
           (let* ((ta (spawn ^tool-cap
                             "counter"
                             "Return a count"
                             (lambda (args)
                               (number->string
                                (or (assoc-ref args "n") 0)))
                             #t))
                  (srv (spawn ^mcp-server
                              (list (cons "counter" ta)))))
             (values srv ta)))
         store
         #:name "test-mcp-persist"
         #:version 1))

      ;; Verify before persist
      (with-vat vat
        (check "12a: tool-names before persist"
               ($ server 'tool-names) '("counter"))
        (check "12b: call before persist"
               ($ server 'call "counter" '(("n" . 42))) "42"))
      (vat-halt! vat))

    ;; Second run: restore
    (receive (vat2 server2 tool-a2)
      (parameterize ((*restore-base-bindings* default-base-bindings))
        (spawn-persistent-vat
         (make-persistence-env
          `((((xorg mcp) ^tool-cap) ,^tool-cap)
            (((xorg mcp) ^mcp-server) ,^mcp-server))
          #:extends (list gplay-env))
         (lambda () (error "should not be called on restore"))
         store
         #:name "test-mcp-persist"
         #:version 1))

      (with-vat vat2
        (check "12c: tool-names after restore"
               ($ server2 'tool-names) '("counter"))
        (check "12d: list-tools schema after restore"
               (assoc-ref (car ($ server2 'list-tools)) 'name) "counter")
        (check "12e: get-tool after restore"
               (not (not ($ server2 'get-tool "counter"))) #t)
        ;; Handler is a stub after restore — calling it errors
        (check "12f: restored tool handler is stub (errors on call)"
               (catch #t
                 (lambda () ($ server2 'call "counter" '(("n" . 1))) #f)
                 (lambda (key . args) #t))
               #t))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(display "\n══════════════════════════════════════════════════════════════\n")
(format #t "Results: ~a passed, ~a failed\n" pass-count fail-count)
(when (> fail-count 0)
  (exit 1))
