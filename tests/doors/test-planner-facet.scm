;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/doors/test-planner-facet.scm — the planner facet the lobby hands out
;;;
;;; The anonymous ^lobby answers (planner) with a facet, not the service. The
;;; planner-service has no per-method access check, so the raw capability lets
;;; any connection settle payouts, add scopes or move the solve vat
;;; (docs/planning/audits/protocol-inventory-2026-09-12.md §1c). What this pins:
;;;   • a public door forwards, arguments and reply intact;
;;;   • a door outside %planner-public-doors is an error, and the service
;;;     never hears it;
;;;   • the lobby's (planner) is the facet, and it stays #f when the lobby
;;;     was spawned without a planner-service.
;;;
;;; Run: guile -L module -L tests tests/doors/test-planner-facet.scm

(use-modules (localchimera test harness)
             (localchimera doors lobby)
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (ice-9 regex)
             (ice-9 rdelim)
             ((srfi srfi-1) #:select (filter delete-duplicates)))

(define vat (spawn-vat))

;; A planner double that records every message it receives.
(define (^recording-planner _bcom)
  (define seen '())
  (methods
   ((seen) (reverse seen))
   ((scope-list) (set! seen (cons 'scope-list seen)) '(("id" . "uc")))
   ((resource-detail scope resource) (set! seen (cons (list 'resource-detail scope resource) seen)) 'detailed)
   ((settle-payout scope id txid store) (set! seen (cons 'settle-payout seen)) 'SETTLED)
   ((add-scope! id) (set! seen (cons 'add-scope! seen)) 'ADDED)))

(define planner #f)
(define facet #f)
(define lobby #f)
(define lobby-without #f)

(with-vat vat
  (set! planner (spawn ^recording-planner))
  (set! facet   (spawn ^planner-facet planner))
  ;; ^lobby's positional tail: signup-agent ai-svc presence terminal-svc
  ;; mailbox-mgr planner-service wallet-policy governance-svc
  (set! lobby         (spawn ^lobby #f #f #f #f #f planner #f #f))
  (set! lobby-without (spawn ^lobby #f #f #f #f #f #f      #f #f)))

;; A forwarded reply lands a turn later than the send: hook the promise in
;; one with-vat, read the value after further turns have flushed the queue.
(define (settle p)
  (let ((v 'unsettled))
    (with-vat vat (on p (lambda (x) (set! v x))))
    (let loop ((n 0))
      (when (and (eq? v 'unsettled) (< n 10))
        (with-vat vat #t)
        (loop (+ n 1))))
    v))

(display "\n── 1. Public doors forward ──\n")

(define scopes-p (with-vat vat (<- facet 'scope-list)))
(check "scope-list reaches the service and its reply comes back"
       (equal? '(("id" . "uc")) (settle scopes-p)))
(define detail-p (with-vat vat (<- facet 'resource-detail "uc" "res:1")))
(check "resource-detail forwards with its arguments"
       (eq? 'detailed (settle detail-p)))
(check "the service saw exactly those two messages, in order"
       (equal? '(scope-list (resource-detail "uc" "res:1")) (with-vat vat ($ planner 'seen))))

(display "\n── 2. Everything else is refused before the service ──\n")

(define settle-r (with-vat vat ($ facet 'settle-payout "uc" "p1" "tx" #f)))
(check "settle-payout is an error from the facet"
       (and (pair? settle-r) (eq? 'error (car settle-r))))
(define add-r (with-vat vat ($ facet 'add-scope! "evil")))
(check "add-scope! is an error from the facet"
       (and (pair? add-r) (eq? 'error (car add-r))))
(check "the service never heard either"
       (equal? '(scope-list (resource-detail "uc" "res:1")) (with-vat vat ($ planner 'seen))))
(check "a door that names the acting agent is not public: claim goes through the session"
       (let ((r (with-vat vat ($ facet 'claim "uc" "res:1" 2 "EAnyone" #f))))
         (and (pair? r) (eq? 'error (car r)))))
(check "the allowlist names no boot, admin or payout-runner door"
       (not (or (memq 'settle-payout %planner-public-doors)
                (memq 'add-scope! %planner-public-doors)
                (memq 'set-solve-vat! %planner-public-doors)
                (memq 'move-scope! %planner-public-doors)
                (memq 'due-payouts %planner-public-doors))))

(display "\n── 3. The lobby hands out the facet ──\n")

(define handed (with-vat vat ($ lobby 'planner)))
(check "(planner) is not the service itself" (not (eq? handed planner)))
(define via-lobby-p (with-vat vat (<- handed 'scope-list)))
(check "what the lobby hands out forwards a public door"
       (equal? '(("id" . "uc")) (settle via-lobby-p)))
(define via-lobby-bad (with-vat vat ($ handed 'settle-payout "uc" "p1" "tx" #f)))
(check "and refuses a private one"
       (and (pair? via-lobby-bad) (eq? 'error (car via-lobby-bad))))
(check "a lobby spawned without a planner-service hands out #f"
       (eq? #f (with-vat vat ($ lobby-without 'planner))))

(display "\n── 4. The allowlist covers every door the browser apps send ──\n")

;; Static: each `(<- *planner* 'door …)` in day-boot.scm and each
;; `(<- *planner-cap* 'door …)` in repl.scm names a public door. A door the
;; browser starts sending that is not listed here would fail live with
;; "not a public door"; this catches it at `make test` instead.
(define (planner-doors-sent file var)
  (let* ((src (call-with-input-file file read-string))
         (rx (make-regexp (string-append (regexp-quote var) " '([a-z!?-]+)"))))
    (let loop ((start 0) (acc '()))
      (let ((m (regexp-exec rx src start)))
        (if m
            (loop (match:end m) (cons (string->symbol (match:substring m 1)) acc))
            (delete-duplicates acc))))))

;; day-boot.scm only: hoot/repl.scm is the legacy app with no session, and
;; the four acting-as doors it still sends to the planner are refused there
;; by design (2026-09-13) — a session is what carries an acting AID.
(define sent (planner-doors-sent "hoot/day-boot.scm" "*planner*"))
(define missing (filter (lambda (d) (not (memq d %planner-public-doors))) sent))
(check "day-boot.scm sends at least five distinct planner doors (the regex sees them)"
       (> (length (delete-duplicates sent)) 5))
(check (string-append "every door they send is public"
                      (if (null? missing) "" (format #f " — missing: ~a" missing)))
       (null? missing))

(test-summary!)
