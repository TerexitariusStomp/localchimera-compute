;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-paths.scm — deployment layout resolution
;;;
;;; Guards the precedence rules in (playnet utils paths) and the
;;; provider-name derivation in (playnet fleet paths). Both are resolved
;;; at CALL time rather than module-init, so each check below sets the
;;; environment after the modules are already loaded — which is the
;;; property under test as much as the paths themselves.
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-paths.scm

(use-modules (playnet test harness)
             (playnet utils paths)
             (playnet fleet paths))

(define (with-env alist thunk)
  "Run THUNK with ALIST applied to the environment, restoring after.
Applied in order, so a later pair wins — write the clearing set first."
  (let ((saved (map (lambda (p) (cons (car p) (getenv (car p)))) alist)))
    (for-each (lambda (p)
                (if (cdr p) (setenv (car p) (cdr p)) (unsetenv (car p))))
              alist)
    (let ((r (thunk)))
      (for-each (lambda (p)
                  (if (cdr p) (setenv (car p) (cdr p)) (unsetenv (car p))))
                saved)
      r)))

(define %clear
  '(("PLAYNET_DATA_DIR" . #f)
    ("PLAYNET_SPORESTACK_TOKEN_FILE" . #f)
    ("PLAYNET_VPSBG_TOKEN_FILE" . #f)))

;;; ── playnet-data-dir ─────────────────────────────────────────────────────

(with-env %clear
  (lambda ()
    (check "data-dir falls back to the packaged default"
           (equal? "/var/lib/playnet" (playnet-data-dir)))
    (check "explicit override beats the default"
           (equal? "/opt/x" (playnet-data-dir "/opt/x")))))

(with-env (append %clear '(("PLAYNET_DATA_DIR" . "/srv/pn")))
  (lambda ()
    (check "PLAYNET_DATA_DIR beats the default"
           (equal? "/srv/pn" (playnet-data-dir)))
    ;; A component handed its own directory keeps it: the environment
    ;; describes the deployment, the argument describes this caller.
    (check "explicit override beats PLAYNET_DATA_DIR"
           (equal? "/opt/x" (playnet-data-dir "/opt/x")))))

;;; #:default is the "runnable with nothing configured" fallback — a
;;; relative directory a developer can write to without root. It must sit
;;; BELOW the environment, or a component carrying one would ignore the
;;; deployment and scatter state across two directories.

(with-env %clear
  (lambda ()
    (check "#:default replaces the packaged default"
           (equal? "data" (playnet-data-dir #:default "data")))
    (check "state-file passes #:default through"
           (equal? "data/chat.log"
                   (state-file "chat.log" #:default "data")))))

(with-env (append %clear '(("PLAYNET_DATA_DIR" . "/srv/pn")))
  (lambda ()
    (check "PLAYNET_DATA_DIR outranks #:default"
           (equal? "/srv/pn" (playnet-data-dir #:default "data")))
    (check "an explicit override still outranks both"
           (equal? "/opt/x" (playnet-data-dir "/opt/x" #:default "data")))))

;;; ── state-file ───────────────────────────────────────────────────────────

(with-env %clear
  (lambda ()
    (check "state-file joins onto the data dir"
           (equal? "/var/lib/playnet/thing.txt" (state-file "thing.txt")))
    (check "state-file honours a data-dir argument"
           (equal? "/opt/x/thing.txt"
                   (state-file "thing.txt" #:data-dir "/opt/x")))
    (check "an unset #:env is simply skipped"
           (equal? "/var/lib/playnet/thing.txt"
                   (state-file "thing.txt" #:env "PLAYNET_NO_SUCH_VAR")))))

(with-env '(("PLAYNET_THING_FILE" . "/tmp/elsewhere.txt")
            ("PLAYNET_DATA_DIR"   . "/srv/pn"))
  (lambda ()
    ;; The single-file override outranks every directory-level setting —
    ;; that is what lets one file move without relocating a deployment.
    (check "#:env outranks PLAYNET_DATA_DIR"
           (equal? "/tmp/elsewhere.txt"
                   (state-file "thing.txt" #:env "PLAYNET_THING_FILE")))
    (check "#:env outranks an explicit data-dir"
           (equal? "/tmp/elsewhere.txt"
                   (state-file "thing.txt" #:data-dir "/opt/x"
                               #:env "PLAYNET_THING_FILE")))))

;;; ── provider-token-file ──────────────────────────────────────────────────

(with-env %clear
  (lambda ()
    (check "token file is named after the provider"
           (equal? "/var/lib/playnet/sporestack-token.txt"
                   (provider-token-file "sporestack")))
    ;; Derived, not enumerated: a provider with no entry anywhere still
    ;; gets a location and an override.
    (check "an unknown provider resolves too"
           (equal? "/var/lib/playnet/vpsbg-token.txt"
                   (provider-token-file "vpsbg")))
    (check "provider token file honours a data-dir argument"
           (equal? "/opt/x/sporestack-token.txt"
                   (provider-token-file "sporestack" "/opt/x")))))

(with-env (append %clear '(("PLAYNET_SPORESTACK_TOKEN_FILE" . "/tmp/ss.txt")))
  (lambda ()
    (check "the per-provider override is honoured"
           (equal? "/tmp/ss.txt" (provider-token-file "sporestack")))
    ;; The env var names ONE provider's file. A shared override would
    ;; silently point two providers at one another's credentials.
    (check "one provider's override leaves the others alone"
           (equal? "/var/lib/playnet/vpsbg-token.txt"
                   (provider-token-file "vpsbg")))
    (check "the override outranks a data-dir argument"
           (equal? "/tmp/ss.txt" (provider-token-file "sporestack" "/opt/x")))))

;;; A hyphenated provider name still yields a legal variable name.
(with-env '(("PLAYNET_MY_HOST_TOKEN_FILE" . "/tmp/mh.txt"))
  (lambda ()
    (check "hyphens in a provider name become underscores"
           (equal? "/tmp/mh.txt" (provider-token-file "my-host")))))

(test-summary!)
