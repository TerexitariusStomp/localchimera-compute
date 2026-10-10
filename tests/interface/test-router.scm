;;; test-router.scm — ^scope-router (multi-scope fan-out backend)
;;;
;;; Verifies:
;;;   - parse-addressed-args splits "@name rest" / "rest"
;;;   - routing: addressed command → named handler
;;;   - default fallback: unaddressed → default handler
;;;   - unknown @name → ('error …)
;;;   - available-commands defers to default
;;;   - wire-output fans out to all handlers
;;;   - args are forwarded with the @addr stripped
;;;
;;; Run from project root:
;;;   guile -L module tests/interface/test-router.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")

(use-modules (playnet test harness)
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (ice-9 match)
             (playnet interface call-context)
             (playnet interface backends router))


;;; ── Stub handler ────────────────────────────────────────────────────────
;;; Records every (cmd, args) call. Returns ('response "tag: cmd args")
;;; so we can tell which handler answered.

(define (^stub-handler bcom tag calls wirings)
  (methods
    ((handle req-ctx cmd args)
     (bcom (^stub-handler bcom tag (cons (list cmd args) calls) wirings)
           (list 'response (format #f "~a: ~a/~a" tag cmd args))))
    ((available-commands) (list (string-append tag "-cmd")))
    ((wire-output sink-ref)
     (bcom (^stub-handler bcom tag calls (cons sink-ref wirings))
           'ok))
    ((calls)    (reverse calls))
    ((wirings)  wirings)
    ((tag)      tag)))


(define test-vat (spawn-vat #:name "test-router"))

(define-values (h-garden h-kitchen h-tools router)
  (with-vat test-vat
    (let* ((g (spawn ^stub-handler "G" '() '()))
           (k (spawn ^stub-handler "K" '() '()))
           (t (spawn ^stub-handler "T" '() '()))
           (r (make-scope-router 'garden
                                 `((garden  . ,g)
                                   (kitchen . ,k)
                                   (tools   . ,t)))))
      (values g k t r))))


;;; ── 1. parse-addressed-args ────────────────────────────────────────────

(display "\n── 1. parse-addressed-args ──\n")

(check "no args → (#f . \"\")"
       (parse-addressed-args "") '(#f . ""))
(check "plain args → (#f . args)"
       (parse-addressed-args "lettuce") '(#f . "lettuce"))
(check "@name alone → (name . \"\")"
       (parse-addressed-args "@garden") '(garden . ""))
(check "@name rest → (name . rest)"
       (parse-addressed-args "@garden lettuce") '(garden . "lettuce"))
(check "leading whitespace tolerated"
       (parse-addressed-args "  @kitchen broth ") '(kitchen . "broth"))
(check "trailing whitespace trimmed in rest"
       (parse-addressed-args "@tools  hammer  ") '(tools . "hammer"))


;;; ── 2. Unaddressed → default handler ───────────────────────────────────

(display "\n── 2. default routing ──\n")

(with-vat test-vat
  (let* ((ctx (make-request-ctx "u1" "ch" #f "/inv"))
         (r   ($ router 'handle ctx "inv" "")))
    (check "default reply tagged G"   (cadr r) "G: inv/"))
  (check "garden saw the call"  (length ($ h-garden  'calls)) 1)
  (check "kitchen untouched"    (length ($ h-kitchen 'calls)) 0)
  (check "tools untouched"      (length ($ h-tools   'calls)) 0))


;;; ── 3. Addressed → named handler ───────────────────────────────────────

(display "\n── 3. @-addressed routing ──\n")

(with-vat test-vat
  (let* ((ctx (make-request-ctx "u1" "ch" #f "/inv @kitchen"))
         (r   ($ router 'handle ctx "inv" "@kitchen")))
    (check "addressed reply tagged K"   (cadr r) "K: inv/"))
  (check "kitchen saw the call"  (length ($ h-kitchen 'calls)) 1)

  ;; @name + extra args → args forwarded, addr stripped
  (let* ((ctx (make-request-ctx "u1" "ch" #f "/inv @tools hammer"))
         (r   ($ router 'handle ctx "inv" "@tools hammer")))
    (check "args forwarded sans @addr"  (cadr r) "T: inv/hammer"))
  (check "tools saw it"  (length ($ h-tools 'calls)) 1))


;;; ── 4. Unknown @name → error ───────────────────────────────────────────

(display "\n── 4. unknown scope ──\n")

(with-vat test-vat
  (let* ((ctx (make-request-ctx "u1" "ch" #f "x"))
         (r   ($ router 'handle ctx "x" "@nope")))
    (check "unknown @name returns error"  (car r) 'error)
    (check "error names the bad scope"
           (and (string-contains (cadr r) "nope") #t) #t)))


;;; ── 5. available-commands defers to default ────────────────────────────

(display "\n── 5. available-commands ──\n")

(with-vat test-vat
  (let ((cmds ($ router 'available-commands)))
    (check "delegates to default handler"  cmds '("G-cmd"))))


;;; ── 6. wire-output fans out to every handler ───────────────────────────

(display "\n── 6. wire-output fan-out ──\n")

(define fake-sink (with-vat test-vat (spawn (lambda (_bcom) (lambda _ #f)))))

(with-vat test-vat
  ($ router 'wire-output fake-sink))

(with-vat test-vat  ;; new turn for the <-np messages to land
  (check "garden  was wired"   (length ($ h-garden  'wirings)) 1)
  (check "kitchen was wired"   (length ($ h-kitchen 'wirings)) 1)
  (check "tools   was wired"   (length ($ h-tools   'wirings)) 1))


;;; ── 7. Introspection ───────────────────────────────────────────────────

(display "\n── 7. introspection ──\n")

(with-vat test-vat
  (check "default-scope reports"   ($ router 'default-scope) 'garden)
  (check "scope-names lists three" (length ($ router 'scope-names)) 3)
  (check "handler-for hit"         (eq? ($ router 'handler-for 'kitchen)
                                        h-kitchen) #t)
  (check "handler-for miss"        ($ router 'handler-for 'ghost) #f))


;;; ── 8. make-scope-router validates default ─────────────────────────────

(display "\n── 8. make-scope-router validation ──\n")

(check-error "default not in alist → error"
             (lambda ()
               (with-vat test-vat
                 (make-scope-router 'ghost
                                    `((garden . ,h-garden))))))


(test-summary!)
