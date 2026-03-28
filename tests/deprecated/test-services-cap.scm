;;; test-services-cap.scm — tests for attenuated service caps and single-config deployer
;;; Run with:  guile -L module tests/test-services-cap.scm

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

(display "== Service Capability Tests ==\n")

;;; ── Test vat ─────────────────────────────────────────────────────────────────

(define test-vat (spawn-vat))

;;; ── 1. Attenuated service cap allows permitted actions ──────────────────

(display "\n-- 1. attenuated service allows permitted actions --\n")

(with-vat test-vat
  (define action-log '())

  (define mock-control
    (lambda (action service-name)
      (set! action-log (cons (list action service-name) action-log))
      (string-append (symbol->string action) " ok")))

  (let* ((base-cap (spawn ^service-capability "nginx" mock-control))
         (limited-cap (spawn ^attenuated-service base-cap '(start status))))
    ;; start should work
    (let ((result ($ limited-cap 'start)))
      (check "start allowed on limited cap" result "start ok"))
    ;; status should work
    (let ((result ($ limited-cap 'status)))
      (check "status allowed on limited cap" result "status ok"))))

;;; ── 2. Attenuated service cap blocks unpermitted actions ────────────────

(display "\n-- 2. attenuated service blocks unpermitted actions --\n")

(with-vat test-vat
  (define mock-control-2
    (lambda (action service-name)
      (string-append (symbol->string action) " ok")))

  (let* ((base-cap (spawn ^service-capability "nginx" mock-control-2))
         (limited-cap (spawn ^attenuated-service base-cap '(start status))))
    ;; stop should fail
    (check-error "stop blocked on start-only cap"
      ($ limited-cap 'stop))
    ;; restart should fail
    (check-error "restart blocked on start-only cap"
      ($ limited-cap 'restart))))

;;; ── 3. make-attenuated-service-cap convenience ─────────────────────────

(display "\n-- 3. make-attenuated-service-cap convenience --\n")

;; Create base cap inside the vat, then use convenience from outside
(define base-cap-for-3
  (with-vat test-vat
    (spawn ^service-capability "relay"
           (lambda (action service-name) "ok"))))

(let ((att-cap (make-attenuated-service-cap test-vat base-cap-for-3 '(status))))
  (with-vat test-vat
    (check "status works via convenience" ($ att-cap 'status) "ok")
    (check-error "start blocked via convenience"
      ($ att-cap 'start))))

;;; ── 4. Single-config deployer deploys when file unchanged ──────────────

(display "\n-- 4. single-config deployer succeeds when unchanged --\n")

;; Create a temp file for testing
(define test-config-path
  (string-append %project-root "/tests/tmp-test-config.scm"))

(with-output-to-file test-config-path
  (lambda () (display "(define machines '())\n")))

(define deploy-called #f)
(define deploy-path-received #f)

(let ((deployer (make-single-config-deployer
                 test-vat test-config-path
                 (lambda (path)
                   (set! deploy-called #t)
                   (set! deploy-path-received path)
                   'deployed))))
  (with-vat test-vat
    (let ((result ($ deployer 'deploy)))
      (check "deploy succeeds when file unchanged" result 'deployed)
      (check "deploy called" deploy-called #t)
      (check "deploy received correct path"
             deploy-path-received test-config-path)
      (check "config-path accessor"
             ($ deployer 'config-path) test-config-path))))

;;; ── 5. Single-config deployer rejects modified file ─────────────────────

(display "\n-- 5. single-config deployer rejects modified file --\n")

;; Re-create file with known content
(with-output-to-file test-config-path
  (lambda () (display "(define machines '(original))\n")))

;; Create a deployer, then modify the file
(let ((deployer (make-single-config-deployer
                 test-vat test-config-path
                 (lambda (path) 'should-not-reach))))
  ;; Modify the file after authorization
  (with-output-to-file test-config-path
    (lambda () (display "(define machines '(modified!))\n")))
  ;; Deploy should fail
  (with-vat test-vat
    (check-error "deploy fails when file modified"
      ($ deployer 'deploy))))

;; Clean up temp file
(when (file-exists? test-config-path)
  (delete-file test-config-path))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
(exit (if (zero? fail-count) 0 1))
