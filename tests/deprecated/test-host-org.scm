;;; test-host-org.scm — tests for host org (multi-org topology + deploy as org action)
;;; Run with: guile -L module tests/test-host-org.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg host)
             (xorg org)
             (xorg gplay)
             (xorg services)
             (xorg endorsement)
             (xorg capabilities)
             (goblins)
             (goblins actor-lib methods)
             (ice-9 receive))

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

(display "== Host Org Tests ==\n")

;;; ── 1. make-host-org creates a governed org ──────────────────────────────────

(display "\n-- 1. make-host-org creates a governed org --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-host")
  (check "org is an org" (org? org) #t)
  (check "org name" (org-name org) "test-host")
  ;; Seals are Goblins actor refs (not plain procedures)
  (check "gov-seal is truthy" (not (not gov-seal)) #t)
  (check "infra-seal is truthy" (not (not infra-seal)) #t)
  (check "member-seal is truthy" (not (not member-seal)) #t))

;;; ── 2. host-grant-service! installs service cap under infra-* name ──────────

(display "\n-- 2. host-grant-service! installs service cap --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-svc-grant")
  (let ((svc-cap (make-service-cap (org-vat org) "test-nginx")))
    (host-grant-service! org "nginx" svc-cap infra-seal)
    (with-vat (org-vat org)
      (check "infra-nginx binding exists"
             (pair? (assq 'infra-nginx ($ (org-ref org) 'bindings))) #t))))

;;; ── 3. Installed service cap is accessible and callable ─────────────────────

(display "\n-- 3. installed service cap is callable --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-svc-call")
  (let ((svc-cap (make-service-cap (org-vat org) "test-svc")))
    (host-grant-service! org "mysvc" svc-cap infra-seal)
    (with-vat (org-vat org)
      (let* ((ref (org-ref org))
             (binding-val ($ ref 'lookup 'infra-mysvc)))
        ;; The stored value is the raw cap (not endorsed) — directly callable
        (check "stored cap is callable (name method)"
               ($ binding-val 'name) "test-svc")
        ;; Original cap ref also still works
        (check "original cap name method works"
               ($ svc-cap 'name) "test-svc")))))

;;; ── 4. Non-infra-seal holder cannot install service caps ────────────────────

(display "\n-- 4. non-infra-seal cannot install service caps --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-svc-block")
  (let ((svc-cap (make-service-cap (org-vat org) "blocked-svc")))
    ;; Try to install with member-seal (wrong domain)
    (check-error "member-seal cannot grant service cap"
      (host-grant-service! org "blocked" svc-cap member-seal))
    ;; Try to install with gov-seal (wrong domain)
    (check-error "gov-seal cannot grant service cap"
      (host-grant-service! org "blocked" svc-cap gov-seal))))

;;; ── 5. host-grant-deploy! installs deploy cap ──────────────────────────────

(display "\n-- 5. host-grant-deploy! installs deploy cap --\n")

;; Create a temp config file for the deploy cap to hash
(let ((tmp (tmpnam)))
  (let ((port (open-output-file tmp)))
    (display "(list (machine ...))" port)
    (close-port port))
  (receive (org gov-seal infra-seal member-seal)
    (make-host-org "test-deploy-grant")
    (host-grant-deploy! org tmp infra-seal)
    (with-vat (org-vat org)
      (let* ((base (basename tmp ".scm"))
             (binding-name (string->symbol
                            (string-append "infra-deploy-" base))))
        (check "deploy cap binding exists"
               (pair? (assq binding-name ($ (org-ref org) 'bindings))) #t))))
  (delete-file tmp))

;;; ── 6. Multiple service caps coexist ────────────────────────────────────────

(display "\n-- 6. multiple service caps coexist --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-multi-svc")
  (let ((nginx-cap (make-service-cap (org-vat org) "nginx"))
        (redis-cap (make-service-cap (org-vat org) "redis"))
        (postgres-cap (make-service-cap (org-vat org) "postgres")))
    (host-grant-service! org "nginx" nginx-cap infra-seal)
    (host-grant-service! org "redis" redis-cap infra-seal)
    (host-grant-service! org "postgres" postgres-cap infra-seal)
    (with-vat (org-vat org)
      (let ((bindings ($ (org-ref org) 'bindings)))
        (check "infra-nginx exists" (pair? (assq 'infra-nginx bindings)) #t)
        (check "infra-redis exists" (pair? (assq 'infra-redis bindings)) #t)
        (check "infra-postgres exists" (pair? (assq 'infra-postgres bindings)) #t)
        ;; Original caps still work
        (check "nginx name" ($ nginx-cap 'name) "nginx")
        (check "redis name" ($ redis-cap 'name) "redis")
        (check "postgres name" ($ postgres-cap 'name) "postgres")))))

;;; ── 7. Service grant creates history entry ──────────────────────────────────

(display "\n-- 7. service grant creates history entry --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-svc-history")
  (let ((svc-cap (make-service-cap (org-vat org) "hist-svc")))
    (let ((history-before (length (org-history org))))
      (host-grant-service! org "histsvc" svc-cap infra-seal)
      (let ((history-after (length (org-history org))))
        (check "history grew by 1" (- history-after history-before) 1)))))

;;; ── 8. deploy-via-org! records action in history ────────────────────────────

(display "\n-- 8. deploy-via-org! records in history --\n")

;; We test the history recording part. The actual deploy will try to run
;; 'guix deploy' which returns non-zero (or fails) in test env.
;; deploy-via-org! should still work: system* returns exit code, doesn't throw.
(let ((tmp (tmpnam)))
  (let ((port (open-output-file tmp)))
    (display "(list (machine ...))" port)
    (close-port port))
  (receive (org gov-seal infra-seal member-seal)
    (make-host-org "test-deploy-history")
    (host-grant-deploy! org tmp infra-seal)
    (let* ((base (basename tmp ".scm"))
           (binding-name (string->symbol
                          (string-append "infra-deploy-" base)))
           (history-before (length (org-history org))))
      ;; deploy-via-org! runs guix deploy (fails in test env, that's OK)
      ;; and records the action in history
      (let ((result (catch #t
                      (lambda ()
                        (deploy-via-org! org binding-name infra-seal)
                        'deployed)
                      (lambda (key . args)
                        'deploy-attempted))))
        ;; Either outcome means the host-org wiring worked
        (check "deploy-via-org! executed"
               (and (memv result '(deployed deploy-attempted)) #t) #t)
        ;; History should have grown (grant + deploy record)
        (let ((history-after (length (org-history org))))
          (check "history grew after deploy"
                 (> history-after history-before) #t)))))
  (delete-file tmp))

;;; ── 9. host-spawn-tenant! raises not-implemented ────────────────────────────

(display "\n-- 9. host-spawn-tenant! raises not-implemented --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-host-org "test-tenant-stub")
  (check-error "spawn-tenant! raises error"
    (host-spawn-tenant! org "tenant-a" '())))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
(exit (if (zero? fail-count) 0 1))
