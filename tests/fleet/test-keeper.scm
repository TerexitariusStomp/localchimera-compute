;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-keeper.scm — a recorded host, carried to a running one
;;;
;;; What has to hold:
;;;
;;;   - only a host that asks ('auto) is touched, and only once it has an address
;;;   - the install — it erases a disk — runs ONCE per host, whatever happens
;;;   - the host is promoted only after its initrd took the passphrase AND
;;;     the booted system then answered
;;;   - a bootstrapped host that reboots is unlocked again
;;;
;;; Run:  guile -L module tests/fleet/test-keeper.scm

(use-modules (localchimera test harness)
             (localchimera fleet child)
             (localchimera fleet keeper)
             (localchimera fleet records)
             (srfi srfi-1))

(define %dir (format #f "/tmp/localchimera-test-keeper-~a" (getpid)))
(system* "rm" "-rf" %dir)
(mkdir %dir #o700)

(define (want name mode)
  (desired-host #:name name #:flavor "f" #:provider "p" #:bootstrap-mode mode))
(define* (recorded name ipv4 #:optional (state 'pending))
  (materialized-host #:name name #:machine-id (string-append "m-" name)
                     #:ipv4 ipv4 #:provider "p" #:flavor "f" #:created-at 0
                     #:bootstrap-state state))

(define desired (list (want "auto-1" 'auto) (want "manual-1" 'manual)
                      (want "auto-2" 'auto) (want "old-1" 'auto)
                      (want "noaddr" 'auto)))
(define hosts (list (recorded "auto-1" "203.0.113.1")
                    (recorded "manual-1" "203.0.113.2")
                    (recorded "auto-2" "203.0.113.3")
                    (recorded "old-1" "203.0.113.4" 'bootstrapped)
                    (recorded "noaddr" #f)))

(define %installs '())
(define %install-fails '())
(define %promoted '())
(define %verdicts '())                  ; name → verdict for this tick
(define %unlock-asked '())

(define (tick!)
  (set! %unlock-asked '())
  (keeper-tick! %dir desired hosts
                #:install! (lambda (m dir)
                             (let ((name (materialized-host-name m)))
                               (set! %installs (cons name %installs))
                               (when (member name %install-fails)
                                 (error "the target refused the connection"))
                               #t))
                #:unlock! (lambda (name address)
                            (set! %unlock-asked (cons name %unlock-asked))
                            (or (assoc-ref %verdicts name) 'unreachable))
                #:promote! (lambda (m)
                             (set! %promoted
                                   (cons (materialized-host-name m) %promoted)))))

;;; ── Tick 1: installs ──────────────────────────────────────────────────────

(set! %install-fails '("auto-2"))
(define r1 (tick!))

(check "the hosts that ask, and have an address, are installed — no others"
       (lset= equal? '("auto-1" "auto-2") %installs))
(check "each got its secrets before its install ran"
       (and (child-passphrase %dir "auto-1") (child-initrd-host-key-pub %dir "auto-1") #t))
(check "a manual host has no record here at all"
       (not (file-exists? (child-dir %dir "manual-1"))))
(check "a host bootstrapped before the keeper is left to whoever holds its key"
       (and (not (child-state %dir "old-1")) (not (member "old-1" %installs))))
(check "one install succeeded, one failed, and the record says which"
       (and (eq? 'installed (child-state %dir "auto-1"))
            (eq? 'install-failed (child-state %dir "auto-2"))
            (equal? 'install-failed (assoc-ref r1 "auto-2"))))

;;; ── The install runs once ─────────────────────────────────────────────────

(set! %install-fails '())
(tick!) (tick!)
(check "a failed install is never run again by the keeper"
       (= 1 (count (lambda (n) (equal? n "auto-2")) %installs)))
(check "nor is a finished one"
       (= 1 (count (lambda (n) (equal? n "auto-1")) %installs)))

(set-child-state! %dir "auto-3" 'installing)
(let ((desired (cons (want "auto-3" 'auto) desired))
      (hosts (cons (recorded "auto-3" "203.0.113.9") hosts)))
  (keeper-tick! %dir desired hosts
                #:install! (lambda _ (set! %installs (cons "auto-3" %installs)))
                #:unlock! (lambda _ 'unreachable) #:promote! (lambda _ #t)))
(check "an install cut short by a restart is marked failed, and not rerun"
       (and (eq? 'install-failed (child-state %dir "auto-3"))
            (not (member "auto-3" %installs))))

;;; ── Unlock, then promote ──────────────────────────────────────────────────

(check "while the host is still rebooting, nothing is promoted"
       (and (null? %promoted) (eq? 'installed (child-state %dir "auto-1"))))

;; The booted Debian still answers at the address before the reboot lands.
(set! %verdicts '(("auto-1" . not-waiting)))
(tick!)
(check "another system answering BEFORE any unlock promotes nothing"
       (and (null? %promoted) (eq? 'installed (child-state %dir "auto-1"))))

(set! %verdicts '(("auto-1" . refused)))
(tick!)
(check "a refused passphrase promotes nothing"
       (and (null? %promoted) (eq? 'installed (child-state %dir "auto-1"))))

(set! %verdicts '(("auto-1" . unlocked)))
(tick!)
(check "the initrd takes the passphrase: unlocked, still unpromoted"
       (and (null? %promoted) (eq? 'unlocked (child-state %dir "auto-1"))))

(set! %verdicts '())
(tick!)
(check "while the system boots (unreachable), still unpromoted" (null? %promoted))

(set! %verdicts '(("auto-1" . not-waiting)))
(tick!)
(check "the booted system answers: promoted, once"
       (and (equal? '("auto-1") %promoted)
            (eq? 'bootstrapped (child-state %dir "auto-1"))))
(tick!)
(check "later ticks promote nothing more" (equal? '("auto-1") %promoted))

;;; ── A reboot, months later ────────────────────────────────────────────────

(set! %verdicts '(("auto-1" . unlocked)))
(let ((r (tick!)))
  (check "a bootstrapped host waiting in its initrd is unlocked again"
         (and (equal? 'unlocked (assoc-ref r "auto-1"))
              (eq? 'bootstrapped (child-state %dir "auto-1"))
              (equal? '("auto-1") %promoted))))
(check "a failed host is never offered a passphrase"
       (not (member "auto-2" %unlock-asked)))

;;; ── No installer on the box ───────────────────────────────────────────────

(let ((waiting (list (recorded "bare-1" "203.0.113.20")))
      (asked '()))
  (keeper-tick! %dir (list (want "bare-1" 'auto)) waiting
                #:install! (lambda (m dir) (set! asked (cons 'install asked)) #t)
                #:unlock! (lambda (name address) 'unreachable)
                #:promote! (lambda (m) #t)
                #:installer-ready? (lambda () #f))
  (check "with no installer the host waits: nothing runs, nothing is recorded"
         (and (null? asked)
              (not (child-state %dir "bare-1"))
              (not (file-exists? (child-dir %dir "bare-1")))))
  (keeper-tick! %dir (list (want "bare-1" 'auto)) waiting
                #:install! (lambda (m dir) (set! asked (cons 'install asked)) #t)
                #:unlock! (lambda (name address) 'unreachable)
                #:promote! (lambda (m) #t)
                #:installer-ready? (lambda () #t))
  (check "once an installer exists, the same host is installed"
         (and (equal? '(install) asked)
              (eq? 'installed (child-state %dir "bare-1")))))

(system* "rm" "-rf" %dir)
(test-summary!)
