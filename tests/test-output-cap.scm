;;; test-output-cap.scm — tests for output capability wiring
;;; Run with: guile -L module tests/test-output-cap.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet org)
             (playnet gplay)
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

(display "== Output Capability Tests ==\n")

;;; ── 1. make-open-org works ──────────────────────────────────────────────────

(display "\n-- 1. make-open-org creates a functional org --\n")

(let ((org (make-open-org "test-open")))
  (check "org created" (org? org) #t)
  (check "org name" (org-name org) "test-open")
  (with-vat (org-vat org)
    (let ((ref (org-ref org)))
      (evaluate '(modify! 'x 42) ref '() ($ ref 'current-expressor))
      (check "can set and read binding" (evaluate 'x ref '() ($ ref 'current-expressor)) 42))))

;;; ── 2. Custom output cap routes to string port ─────────────────────────────

(display "\n-- 2. custom output cap routes to string port --\n")

(let* ((str-port (open-output-string))
       (vat (spawn-vat))
       (org (with-vat vat
              (let ((out-cap (spawn ^output-port str-port)))
                (make-org "test-custom-output" vat out-cap default-validator default-base-bindings)))))
  (with-vat vat
    (let ((ref (org-ref org)))
      (evaluate '(display "hello") ref '() ($ ref 'current-expressor))
      (evaluate '(display " world") ref '() ($ ref 'current-expressor))))
  (check "output routed to string port"
         (get-output-string str-port)
         "hello world"))

;;; ── 3. newline and format route through cap ────────────────────────────────

(display "\n-- 3. newline routes through output cap --\n")

(let* ((str-port (open-output-string))
       (vat (spawn-vat))
       (org (with-vat vat
              (let ((out-cap (spawn ^output-port str-port)))
                (make-org "test-newline" vat out-cap default-validator default-base-bindings)))))
  (with-vat vat
    (let ((ref (org-ref org)))
      (evaluate '(display "line1") ref '() ($ ref 'current-expressor))
      (evaluate '(newline) ref '() ($ ref 'current-expressor))
      (evaluate '(display "line2") ref '() ($ ref 'current-expressor))))
  (check "newline in output"
         (get-output-string str-port)
         "line1\nline2"))

;;; ── 4. write routes through cap ────────────────────────────────────────────

(display "\n-- 4. write routes through output cap --\n")

(let* ((str-port (open-output-string))
       (vat (spawn-vat))
       (org (with-vat vat
              (let ((out-cap (spawn ^output-port str-port)))
                (make-org "test-write" vat out-cap default-validator default-base-bindings)))))
  (with-vat vat
    (let ((ref (org-ref org)))
      (evaluate '(write "quoted") ref '() ($ ref 'current-expressor))))
  (check "write produces quoted output"
         (get-output-string str-port)
         "\"quoted\""))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
(exit (if (zero? fail-count) 0 1))
