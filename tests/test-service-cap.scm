;;; test-service-cap.scm — tests for service capability attenuation
;;; Run with: guile -L module tests/test-service-cap.scm

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

;;; ── Mock service cap ────────────────────────────────────────────────────────

(define test-vat (spawn-vat))

(define (^mock-service bcom name)
  "Mock service cap that returns action symbols instead of calling herd."
  (methods
   [(start)   'started]
   [(stop)    'stopped]
   [(restart) 'restarted]
   [(status)  (string-append name " is running")]
   [(name)    name]))

;;; ── 1. Full cap allows everything ──────────────────────────────────────────

(display "\n-- 1. full cap allows all actions --\n")

(with-vat test-vat
  (let ((cap (spawn ^mock-service "nginx")))
    (check "start works" ($ cap 'start) 'started)
    (check "stop works" ($ cap 'stop) 'stopped)
    (check "restart works" ($ cap 'restart) 'restarted)
    (check "status works" ($ cap 'status) "nginx is running")
    (check "name works" ($ cap 'name) "nginx")))

;;; ── 2. Attenuated cap restricts to allowed actions ─────────────────────────

(display "\n-- 2. attenuated cap restricts actions --\n")

(with-vat test-vat
  (let* ((full-cap (spawn ^mock-service "nginx"))
         (read-only (spawn ^attenuated-service-cap full-cap '(status name))))
    (check "status allowed" ($ read-only 'status) "nginx is running")
    (check "name allowed" ($ read-only 'name) "nginx")
    (check-error "start blocked" ($ read-only 'start))
    (check-error "stop blocked" ($ read-only 'stop))
    (check-error "restart blocked" ($ read-only 'restart))))

;;; ── 3. Start-only cap ──────────────────────────────────────────────────────

(display "\n-- 3. start-only cap --\n")

(with-vat test-vat
  (let* ((full-cap (spawn ^mock-service "postgres"))
         (start-only (spawn ^attenuated-service-cap full-cap '(start))))
    (check "start allowed" ($ start-only 'start) 'started)
    (check-error "stop blocked" ($ start-only 'stop))
    (check-error "status blocked" ($ start-only 'status))))

;;; ── 4. attenuate-service-cap convenience ────────────────────────────────────

(display "\n-- 4. attenuate-service-cap convenience function --\n")

(let* ((full-cap (with-vat test-vat (spawn ^mock-service "redis")))
       (limited (attenuate-service-cap test-vat full-cap 'start 'status)))
  (with-vat test-vat
    (check "start via convenience" ($ limited 'start) 'started)
    (check "status via convenience" ($ limited 'status) "redis is running")
    (check-error "stop blocked via convenience" ($ limited 'stop))))

;;; ── 5. Empty attenuation blocks everything ──────────────────────────────────

(display "\n-- 5. empty attenuation blocks everything --\n")

(with-vat test-vat
  (let* ((full-cap (spawn ^mock-service "memcached"))
         (empty-cap (spawn ^attenuated-service-cap full-cap '())))
    (check-error "start blocked" ($ empty-cap 'start))
    (check-error "stop blocked" ($ empty-cap 'stop))
    (check-error "status blocked" ($ empty-cap 'status))
    (check-error "name blocked" ($ empty-cap 'name))))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
(exit (if (zero? fail-count) 0 1))
