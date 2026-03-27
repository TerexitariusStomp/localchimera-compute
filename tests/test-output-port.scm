;;; test-output-port.scm — tests for ^output-port capability and org IO wiring
;;; Run with:  guile -L module tests/test-output-port.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg gplay)
             (xorg org)
             (xorg capabilities)
             (goblins))

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

(define (ev expr org)
  (with-vat (org-vat org)
    (evaluate expr (org-ref org) '() ($ (org-ref org) 'current-expressor))))

(display "== Output Port Capability Tests ==\n")

;;; ── 1. Default make-org still has working display/write/format/newline ───

(display "\n-- 1. default org has working IO --\n")

(let ((org (make-org "test-default-io")))
  ;; display, write, newline, format should all be bound
  (check "display is bound" (procedure? (ev 'display org)) #t)
  (check "write is bound"   (procedure? (ev 'write org))   #t)
  (check "newline is bound" (procedure? (ev 'newline org)) #t)
  (check "format is bound"  (procedure? (ev 'format org))  #t))

;;; ── 2. String-port output cap routes output there, not stdout ──────────

(display "\n-- 2. string-port output cap --\n")

(let* ((str-port (open-output-string))
       (org (make-org "test-string-io" #:output str-port)))
  ;; display inside org should write to str-port
  (ev '(display "hello") org)
  (check "display routes to string port"
         (get-output-string str-port) "hello")
  ;; write also goes there
  (ev '(write 42) org)
  (check "write routes to string port"
         (get-output-string str-port) "hello42")
  ;; newline
  (ev '(newline) org)
  (check "newline routes to string port"
         (get-output-string str-port) "hello42\n")
  ;; format
  (ev '(format "~a+~a" 1 2) org)
  (check "format routes to string port"
         (get-output-string str-port) "hello42\n1+2"))

;;; ── 3. Two orgs with different output caps don't cross-contaminate ──────

(display "\n-- 3. no cross-contamination --\n")

(let* ((port-a (open-output-string))
       (port-b (open-output-string))
       (org-a (make-org "org-a" #:output port-a))
       (org-b (make-org "org-b" #:output port-b)))
  (ev '(display "AAA") org-a)
  (ev '(display "BBB") org-b)
  (check "org-a output isolated" (get-output-string port-a) "AAA")
  (check "org-b output isolated" (get-output-string port-b) "BBB"))

;;; ── 4. Backward compat: (make-org "name") still works ─────────────────

(display "\n-- 4. backward compatibility --\n")

(let ((org (make-org "compat-test")))
  (ev '(define x 42) org)
  (check "define works in default org" (ev 'x org) 42)
  (ev '(modify! 'y 99) org)
  (check "modify! works in default org" (ev 'y org) 99))

;;; ── 5. make-org with custom bindings still works ───────────────────────

(display "\n-- 5. custom bindings + output --\n")

(let* ((str-port (open-output-string))
       (custom-bindings `((+ . ,+) (- . ,-) (* . ,*)
                          (cons . ,cons) (car . ,car) (cdr . ,cdr)
                          (list . ,list) (null? . ,null?)
                          (void . ,(lambda () (if #f #f)))))
       (org (make-org "custom-bind" custom-bindings #:output str-port)))
  (ev '(display (+ 1 2)) org)
  (check "custom bindings + output cap work together"
         (get-output-string str-port) "3"))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
(exit (if (zero? fail-count) 0 1))
