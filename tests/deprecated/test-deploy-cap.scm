;;; test-deploy-cap.scm — tests for deployment capability
;;; Run with: guile -L module tests/test-deploy-cap.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg services)
             (goblins)
             (goblins actor-lib methods))

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

(display "== Deploy Capability Tests ==\n")

(define test-vat (spawn-vat))

;;; ── 1. make-deploy-cap creates cap with config path ─────────────────────────

(display "\n-- 1. deploy cap creation --\n")

(let ((tmp (tmpnam)))
  (let ((port (open-output-file tmp)))
    (display "(list (machine ...))" port)
    (close-port port))
  (let ((cap (make-deploy-cap test-vat tmp)))
    (with-vat test-vat
      (check "config path stored" ($ cap 'config) tmp)))
  (delete-file tmp))

;;; ── 2. Deploy raises error if file modified ─────────────────────────────────

(display "\n-- 2. deploy detects file modification --\n")

(let ((tmp (tmpnam)))
  (let ((port (open-output-file tmp)))
    (display "original content" port)
    (close-port port))
  (let ((cap (make-deploy-cap test-vat tmp)))
    ;; Modify the file after cap creation — different content, different size
    (let ((port (open-output-file tmp)))
      (display "MODIFIED content that is a completely different length and text" port)
      (close-port port))
    (with-vat test-vat
      (check-error "deploy raises on modified file" ($ cap 'deploy))))
  (delete-file tmp))

;;; ── 3. Cap is pre-bound to exactly one file ─────────────────────────────────

(display "\n-- 3. cap is pre-bound to one file --\n")

(let* ((tmp1 (tmpnam))
       (tmp2 (tmpnam)))
  (let ((port (open-output-file tmp1)))
    (display "config-a" port)
    (close-port port))
  (let ((port (open-output-file tmp2)))
    (display "config-b" port)
    (close-port port))
  (let ((cap1 (make-deploy-cap test-vat tmp1))
        (cap2 (make-deploy-cap test-vat tmp2)))
    (with-vat test-vat
      (check "cap1 bound to tmp1" ($ cap1 'config) tmp1)
      (check "cap2 bound to tmp2" ($ cap2 'config) tmp2)
      ;; Each cap is independent
      (check "different caps, different paths"
             (not (equal? ($ cap1 'config) ($ cap2 'config))) #t)))
  (delete-file tmp1)
  (delete-file tmp2))

;;; ── 4. Unmodified file passes hash check (but guix deploy will fail) ────────

(display "\n-- 4. unmodified file passes hash check --\n")

(let ((tmp (tmpnam)))
  (let ((port (open-output-file tmp)))
    (display "(machines ...)" port)
    (close-port port))
  (let ((cap (make-deploy-cap test-vat tmp)))
    ;; Deploy will pass the hash check but fail at system* "guix" "deploy"
    ;; since guix isn't available in test environment — that's the error we catch
    (with-vat test-vat
      (let ((result (catch #t
                      (lambda () ($ cap 'deploy) 'deployed)
                      (lambda (key . args)
                        ;; If error mentions "Config modified" then hash check failed
                        ;; If error is something else (guix not found), hash check passed
                        (if (and (pair? args)
                                 (string? (car args))
                                 (string-contains (car args) "Config modified"))
                            'hash-mismatch
                            'hash-ok-deploy-failed)))))
        ;; We expect hash-ok (guix not found) or deployed
        (check "unmodified file passes hash check"
               (and (memv result '(deployed hash-ok-deploy-failed)) #t) #t))))
  (delete-file tmp))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
(exit (if (zero? fail-count) 0 1))
