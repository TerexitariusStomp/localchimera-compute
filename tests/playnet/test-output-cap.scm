;;; test-output-cap.scm — tests for output capability wiring
;;; Run with: guile -L module tests/test-output-cap.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet test harness))
(use-modules (playnet org)
             (playnet org gplay)
             (goblins))

;;; ── Helper ──────────────────────────────────────────────────────────────────
(define (ev expr org)
  (with-vat (org-vat org)
    (evaluate expr (org-ref org) '() ($ (org-ref org) 'current-expressor))))

(display "== Output Capability Tests ==\n")

;;; ── 1. make-open-org works ──────────────────────────────────────────────────

(display "\n-- 1. make-open-org creates a functional org --\n")

(let ((org (make-open-org "test-open")))
  (check "org created" (org? org) #t)
  (check "org name" (org-name org) "test-open")
  (ev '(modify! 'x 42) org)
  (check "can set and read binding" (ev 'x org) 42))

;;; ── 2. Custom output cap routes to string port ─────────────────────────────

(display "\n-- 2. custom output cap routes to string port --\n")

(let* ((str-port (open-output-string))
       (org (make-org "test-custom-output" #:output str-port)))
  (ev '(display "hello") org)
  (ev '(display " world") org)
  (check "output routed to string port"
         (get-output-string str-port)
         "hello world"))

;;; ── 3. newline and format route through cap ────────────────────────────────

(display "\n-- 3. newline routes through output cap --\n")

(let* ((str-port (open-output-string))
       (org (make-org "test-newline" #:output str-port)))
  (ev '(display "line1") org)
  (ev '(newline) org)
  (ev '(display "line2") org)
  (check "newline in output"
         (get-output-string str-port)
         "line1\nline2"))

;;; ── 4. write routes through cap ────────────────────────────────────────────

(display "\n-- 4. write routes through output cap --\n")

(let* ((str-port (open-output-string))
       (org (make-org "test-write" #:output str-port)))
  (ev '(write "quoted") org)
  (check "write produces quoted output"
         (get-output-string str-port)
         "\"quoted\""))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
