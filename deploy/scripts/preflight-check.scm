#!/usr/bin/env -S guile -L module
!#
;;; deploy/scripts/preflight-check.scm — pre-deploy validation
;;;
;;; Validates the entire playnet configuration before running guix deploy.
;;; Checks every secret, config file, service reachability, and dependency.
;;; Reports a clear pass/fail for each item so the operator knows exactly
;;; what's missing.
;;;
;;; Usage:
;;;   guile -L module deploy/scripts/preflight-check.scm
;;;
;;; Exit code 0 = all checks passed, safe to deploy.
;;; Exit code 1 = one or more checks failed — fix before deploying.

(use-modules (ice-9 format)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 popen)
             (ice-9 ftw)
             (srfi srfi-1)
             (web client)
             (web response)
             (rnrs bytevectors)
             (json))

;;; ── Harness ──────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)
(define warn-count 0)

(define (ok label)
  (set! pass-count (+ 1 pass-count))
  (format #t "  ✓ ~a~%" label))

(define (fail label reason)
  (set! fail-count (+ 1 fail-count))
  (format #t "  ✗ ~a — ~a~%" label reason))

(define (warn label reason)
  (set! warn-count (+ 1 warn-count))
  (format #t "  ⚠ ~a — ~a~%" label reason))

(define* (check-file label path #:key (required? #t))
  (cond
   ((file-exists? path) (ok (format #f "~a (~a)" label path)))
   (required? (fail label (format #f "~a not found" path)))
   (else (warn label (format #f "~a not found (optional)" path)))))

(define (check-file-nonempty label path)
  (cond
   ((not (file-exists? path))
    (fail label (format #f "~a not found" path)))
   (else
    (let ((content (call-with-input-file path get-string-all)))
      (if (string-null? (string-trim-both content))
          (fail label (format #f "~a is empty" path))
          (ok (format #f "~a (~a)" label path)))))))

(define (check-env-in-secrets label var-name secrets-path)
  (if (not (file-exists? secrets-path))
      (fail label (format #f "secrets.scm not found — can't check ~a" var-name))
      (let ((content (call-with-input-file secrets-path get-string-all)))
        (if (string-contains content var-name)
            (let ((line (find (lambda (l)
                                (and (string-contains l var-name)
                                     (string-contains l "setenv")))
                              (string-split content #\newline))))
              (if (and line
                       (let ((val-start (string-contains line "\"")))
                         (and val-start
                              (let* ((rest (substring line (+ val-start 1)))
                                     (val-end (string-index rest #\")))
                                (and val-end
                                     (let ((next-quote (string-index (substring rest (+ val-end 1)) #\")))
                                       (and next-quote
                                            (> (- next-quote 0) 0)
                                            (not (string-null?
                                                  (string-trim-both
                                                   (substring rest (+ val-end 2)
                                                              (+ val-end 1 next-quote))))))))))))
                  (ok (format #f "~a set in secrets.scm" label))
                  (warn label (format #f "~a appears empty in secrets.scm" var-name))))
            (fail label (format #f "~a not found in secrets.scm" var-name))))))

(define (check-port-reachable label host port)
  (catch #t
    (lambda ()
      (let ((s (socket PF_INET SOCK_STREAM 0)))
        (connect s AF_INET (inet-pton AF_INET host) port)
        (close-port s)
        (ok (format #f "~a (~a:~a reachable)" label host port))))
    (lambda _
      (warn label (format #f "~a:~a not reachable (service may not be running yet)" host port)))))

(define (check-command label cmd)
  (let ((status (system (format #f "which ~a > /dev/null 2>&1" cmd))))
    (if (zero? status)
        (ok (format #f "~a (command: ~a)" label cmd))
        (fail label (format #f "~a not found in PATH" cmd)))))

(define (check-guix-package label pkg)
  (let* ((pipe (open-pipe* OPEN_READ "guix" "package" "-A" (format #f "^~a$" pkg)))
         (line (read-line pipe))
         (status (close-pipe pipe)))
    (if (and (not (eof-object? line)) (string-contains line pkg))
        (ok (format #f "~a (guix package: ~a)" label pkg))
        (warn label (format #f "~a not in guix package list" pkg)))))

;;; ── Config paths ─────────────────────────────────────────────────────

(define %deploy-dir
  (let ((script-dir (dirname (current-filename))))
    (dirname script-dir)))

(define %secrets     (string-append %deploy-dir "/secrets.scm"))
(define %secrets-age (string-append %deploy-dir "/secrets.scm.age"))
(define %age-key     (string-append %deploy-dir "/.age-key.txt"))
(define %machines    (string-append %deploy-dir "/machines.scm"))
(define %desired     (string-append %deploy-dir "/desired-fleet.scm"))
(define %hosts       (string-append %deploy-dir "/hosts.scm"))
(define %providers   (string-append %deploy-dir "/providers/"))

;;; ── Checks ───────────────────────────────────────────────────────────

(format #t "~%═══ playnet preflight check ═══~%~%")

;; ── Core deploy files ─────────────────────────────────────────────
(format #t "── Deploy files ──~%")
(check-file "machines.scm" %machines)
(check-file "secrets.scm (plaintext)" %secrets #:required? #f)
(check-file "secrets.scm.age (encrypted)" %secrets-age #:required? #f)

(when (and (not (file-exists? %secrets))
           (not (file-exists? %secrets-age)))
  (fail "secrets" "neither secrets.scm nor secrets.scm.age found — copy from .example"))

(check-file "age key" %age-key #:required? #f)

(let ((providers (scandir %providers)))
  (if (and providers (any (lambda (f) (string-suffix? ".scm" f))
                          providers))
      (ok "provider config found")
      (fail "provider config" "no .scm files in deploy/providers/")))

;; ── Secrets content ───────────────────────────────────────────────
(format #t "~%── Secrets ──~%")
(when (file-exists? %secrets)
  (for-each
   (lambda (pair)
     (check-env-in-secrets (car pair) (cdr pair) %secrets))
   '(("Monero wallet password"  . "MONERO_WALLET_PASSWORD")
     ("Monero RPC password"     . "MONERO_RPC_PASSWORD")
     ("Monero wallet seed"      . "MONERO_WALLET_SEED")
     ("SporeStack token"        . "SPORESTACK_TOKEN")
     ("LUKS passphrase"         . "PLAYNET_LUKS_PASSPHRASE")
     ("Mosquitto password"      . "MOSQUITTO_PASSWORD")
     ("KERIA passcode"          . "KERIA_PASSCODE")
     ("API keys"                . "API_KEYS"))))

;; ── Stale secrets detection ──────────────────────────────────────
(format #t "~%── Stale secrets ──~%")
;; Check for secrets files in unexpected locations. A stale copy of
;; secrets.scm outside the expected path is a plaintext credential leak.
(for-each
 (lambda (path)
   (when (and (file-exists? path)
              (not (equal? (canonicalize-path path)
                           (canonicalize-path %secrets))))
     (fail "STALE SECRETS FILE"
           (format #f "~a exists — contains plaintext credentials. DELETE IT." path))))
 (list (string-append %deploy-dir "/guix/secrets.scm")
       (string-append %deploy-dir "/../secrets.scm")))

(let ((secrets-bak (string-append %secrets ".bak")))
  (when (file-exists? secrets-bak)
    (fail "STALE SECRETS BACKUP"
          (format #f "~a exists — shred it." secrets-bak))))

;; ── KERI witness safety ──────────────────────────────────────────
(format #t "~%── KERI witnesses ──~%")
(let ((keria-svc (string-append %deploy-dir "/guix/keria-service.scm")))
  (if (file-exists? keria-svc)
      (let ((content (call-with-input-file keria-svc get-string-all)))
        (cond
         ((string-contains content "witness\" \"demo\"")
          (fail "DEMO WITNESSES"
                "keria-service.scm uses 'kli witness demo' — these have KNOWN PRIVATE KEYS from the keripy source. Anyone can forge KEL receipts. Switch to 'kli witness start' with custom-generated keys for production."))
         ((not (string-contains content "\"witness\" \"start\""))
          (fail "WITNESS START MISSING"
                "keria-service.scm doesn't invoke 'kli witness start' — witnesses won't run."))
         ((not (string-contains content "kli init"))
          (fail "WITNESS KEYGEN MISSING"
                "keria-service.scm starts witnesses but never runs 'kli init' — keystore won't be generated, witnesses will fail to start."))
         (else
          (ok "witnesses use custom keys (kli init + kli witness start)")))
        ;; Verify witness keystores exist on this machine if we're
        ;; running on the deployed server (best-effort — directory may
        ;; be elsewhere on operator workstation). The expected count
        ;; comes from the provider config's `witnesses` field if set,
        ;; else the canonical 6. Below the toad-table floor of 4 the
        ;; quorum is meaningless, so we warn rather than just count.
        (let* ((ks-dir "/var/lib/playnet/keria/ks")
               (provider-file (getenv "PLAYNET_PROVIDER"))
               (expected-count
                (or (and provider-file (file-exists? provider-file)
                         (let ((cfg (primitive-load provider-file)))
                           (let ((ws (assq-ref cfg 'witnesses)))
                             (and ws (length ws)))))
                    6)))
          (when (file-exists? ks-dir)
            (let ((entries (scandir ks-dir
                                    (lambda (n)
                                      (not (member n '("." "..")))))))
              (cond
               ((not entries)
                (warn "witness keystores"
                      "couldn't read /var/lib/playnet/keria/ks"))
               ((>= (length entries) expected-count)
                (ok (format #f "witness keystores present (~a found, ~a expected)"
                            (length entries) expected-count))
                (when (< (length entries) 4)
                  (warn "witness quorum"
                        (format #f "~a witnesses on this host — federation needs ≥4 across all hosts for a meaningful toad quorum (see %toad-table)"
                                (length entries)))))
               (else
                (warn "witness keystores"
                      (format #f "~a keystores found, ~a expected — first deploy will generate the rest"
                              (length entries) expected-count))))))))
      (warn "keria-service.scm" "not found")))

;; ── Fleet config ──────────────────────────────────────────────────
(format #t "~%── Fleet ──~%")
(check-file "desired-fleet.scm" %desired #:required? #f)
(check-file "hosts.scm" %hosts #:required? #f)

(when (file-exists? %desired)
  (catch #t
    (lambda ()
      (let ((hosts (primitive-load %desired)))
        (if (and (list? hosts) (pair? hosts))
            (ok (format #f "desired-fleet.scm loads (~a hosts)" (length hosts)))
            (warn "desired-fleet.scm" "loads but is empty"))))
    (lambda (key . args)
      (fail "desired-fleet.scm" (format #f "fails to load: ~a ~a" key args)))))

(when (file-exists? %hosts)
  (catch #t
    (lambda ()
      (let ((hosts (primitive-load %hosts)))
        (if (and (list? hosts) (pair? hosts))
            (ok (format #f "hosts.scm loads (~a materialized)" (length hosts)))
            (ok "hosts.scm loads (empty — no hosts provisioned yet)"))))
    (lambda (key . args)
      (fail "hosts.scm" (format #f "fails to load: ~a ~a" key args)))))

;; ── Commands ──────────────────────────────────────────────────────
(format #t "~%── Required commands ──~%")
(for-each
 (lambda (cmd) (check-command cmd cmd))
 '("guix" "guile" "ssh" "ssh-keyscan" "mosquitto_pub" "mosquitto_sub" "age" "git"))

;; ── Guix packages ─────────────────────────────────────────────────
(format #t "~%── Guix packages ──~%")
(for-each
 (lambda (pkg) (check-guix-package pkg pkg))
 '("monero" "mosquitto" "age"))

;; ── Service reachability (localhost) ──────────────────────────────
(format #t "~%── Service ports (localhost) ──~%")
(check-port-reachable "Mosquitto MQTT" "127.0.0.1" 1883)
(check-port-reachable "monero-wallet-rpc" "127.0.0.1" 18082)
(check-port-reachable "monerod RPC" "127.0.0.1" 18081)
(check-port-reachable "KERIA agent" "127.0.0.1" 3901)
(check-port-reachable "KERIA boot" "127.0.0.1" 3902)
(check-port-reachable "Wallet-service WS" "127.0.0.1" 9091)
(check-port-reachable "Gateway WS" "127.0.0.1" 9090)

;; ── File permissions ──────────────────────────────────────────────
(format #t "~%── File permissions ──~%")
(for-each
 (lambda (pair)
   (let ((label (car pair)) (path (cdr pair)))
     (if (file-exists? path)
         (let* ((st (stat path))
                (mode (stat:perms st)))
           (if (<= mode #o600)
               (ok (format #f "~a mode ~3,'0o" label mode))
               (warn label (format #f "~a has mode ~3,'0o (expected ≤ 0600)" path mode))))
         #f)))  ; skip if file doesn't exist
 '(("secrets.scm"        . "deploy/secrets.scm")
   ("age key"             . "deploy/.age-key.txt")
   ("wallet password"     . "/var/lib/playnet/monero/wallet-password.txt")
   ("RPC login"           . "/var/lib/playnet/monero/rpc-login.txt")
   ("SporeStack token"    . "/var/lib/playnet/sporestack-token.txt")
   ("MQTT password"       . "/var/lib/playnet/mosquitto/mqtt-password.txt")))

;; ── Git status ────────────────────────────────────────────────────
(format #t "~%── Git ──~%")
(let* ((pipe (open-pipe* OPEN_READ "git" "status" "--porcelain"))
       (lines (let loop ((acc '()))
                (let ((l (read-line pipe)))
                  (if (eof-object? l) (reverse acc) (loop (cons l acc)))))))
  (close-pipe pipe)
  (let ((uncommitted (filter (lambda (l)
                               (and (> (string-length l) 0)
                                    (not (string-prefix? "??" l))))
                             lines)))
    (if (null? uncommitted)
        (ok "no uncommitted changes")
        (warn "uncommitted changes"
              (format #f "~a modified file(s)" (length uncommitted))))))

(let* ((pipe (open-pipe* OPEN_READ "git" "log" "--oneline" "rad/main..HEAD"))
       (lines (let loop ((acc '()))
                (let ((l (read-line pipe)))
                  (if (eof-object? l) (reverse acc) (loop (cons l acc)))))))
  (close-pipe pipe)
  (if (null? lines)
      (ok "in sync with rad/main")
      (warn "unpushed commits"
            (format #f "~a commit(s) ahead of rad/main" (length lines)))))

;; ── Reproducibility ───────────────────────────────────────────────
(format #t "~%── Reproducibility ──~%")

(let* ((pipe (open-pipe* OPEN_READ "guix" "describe" "--format=recutils"))
       (content (get-string-all pipe)))
  (close-pipe pipe)
  (if (string-contains content "commit:")
      (ok "guix channels pinned (guix describe shows commit hashes)")
      (warn "guix channels" "could not verify channel pinning")))

(check-file "channels.scm" (string-append %deploy-dir "/guix/channels.scm") #:required? #f)

;; ── Summary ───────────────────────────────────────────────────────

(format #t "~%═══════════════════════════════════════~%")
(format #t "  ✓ ~a passed   ⚠ ~a warnings   ✗ ~a failed~%"
        pass-count warn-count fail-count)
(format #t "═══════════════════════════════════════~%~%")

(cond
 ((> fail-count 0)
  (format #t "FIX THE FAILURES ABOVE BEFORE DEPLOYING.~%~%")
  (exit 1))
 ((> warn-count 0)
  (format #t "Warnings are non-blocking but review them.~%~%")
  (exit 0))
 (else
  (format #t "All clear — safe to deploy.~%~%")
  (exit 0)))
