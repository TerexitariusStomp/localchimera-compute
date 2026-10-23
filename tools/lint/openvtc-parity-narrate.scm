#!/usr/bin/env -S guile --no-auto-compile -e main -s
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; openvtc-parity-narrate.scm — tools/lint/openvtc-parity-check.sh, plus a plain-
;;; English summary of the flagged commits from our own AI infra.
;;;
;;; The check itself stays a deterministic git diff (openvtc-parity-check.sh)
;;; — no LLM in the trust path, nothing here can make it miss or invent a
;;; commit. This wrapper only adds a narration pass on top of that ground
;;; truth, via the same key-pool/nano-gpt stack the rest of playnet uses
;;; (playnet key-pool / playnet ai llm) — not a third-party agent, not a
;;; hosted routine. Best-effort: no API_KEYS, an API failure, or an empty
;;; flagged list all fall through to "raw output only" and exit 0. A check
;;; that could not run (no route upstream, a pin upstream has lost) exits with
;;; the check's own status, so the weekly log names the failure.
;;;
;;; Run (from the repo root, same as openvtc-parity-check.sh assumes):
;;;   guile --no-auto-compile -L module tools/lint/openvtc-parity-narrate.scm
;;; Env: API_KEYS/OPENROUTER_KEYS, API_PROVIDER (nano-gpt default), AI_MODEL
;;;      — same variables (playnet ai bridge) reads, so one export covers both.

(use-modules (ice-9 popen) (ice-9 textual-ports) (ice-9 format) (ice-9 regex)
             (srfi srfi-11) (srfi srfi-13)
             (goblins) (playnet ai key-pool) (playnet ai llm))

(define (read-all-output port)
  "The pipe's whole output and its exit status, as two values."
  (let* ((s (get-string-all port))
         (status (close-pipe port)))
    (values s (or (status:exit-val status) 1))))

;; Same provider dispatch as (playnet ai bridge)'s env-provider — duplicated
;; rather than imported because that binding is private to the gplay bridge
;; and this tool has no gplay dependency to justify pulling the module in.
(define (env-provider)
  (let ((name (or (getenv "API_PROVIDER") "nano-gpt")))
    (cond ((string=? name "nano-gpt")   (nano-gpt-provider))
          ((string=? name "openrouter") (openrouter-provider))
          ((string=? name "openai")     (openai-provider))
          ((string=? name "generic")
           (generic-provider (or (getenv "API_BASE_URL") "")))
          (else (nano-gpt-provider)))))

(define (flagged-count report)
  (let ((m (string-match "([0-9]+) of ([0-9]+) commit\\(s\\) flagged" report)))
    (and m (string->number (match:substring m 1)))))

(define (failure-reason key args)
  "One line for a caught exception: an `error` call's own message and irritants
(the upstream's explanation rides there), else the key and arguments."
  (catch #t
    (lambda ()
      (if (and (eq? key 'misc-error) (pair? args) (pair? (cdr args)) (pair? (cddr args)))
          (apply format #f (cadr args) (caddr args))
          (format #f "~a ~s" key args)))
    (lambda _ (format #f "~a" key))))

(define (narrate report keys)
  (catch #t
    (lambda ()
      (let* ((vat  (spawn-vat #:name "openvtc-parity-narrate"))
             (pool (with-vat vat (spawn-key-pool keys #:provider (env-provider))))
             (system "You summarize upstream OSS commit diffs for a Guile Scheme \
project that hand-ports OpenVTC's (Rust) credential/trust logic into KERI ACDCs. \
Given a list of upstream commits flagged as touching credential/trust-relevant \
code, write a short (5-10 line) plain-English summary: what changed, grouped by \
theme, and which ones sound most likely to need a matching change on the KERI/ACDC \
side. Do not invent commits not in the input. Do not recommend specific code \
edits — that's a human audit's job, not yours.")
             (messages (vector `((role . "system") (content . ,system))
                                `((role . "user") (content . ,report)))))
        ;; The completion runs inside the vat and its failure is caught THERE:
        ;; an error that leaves a vat goes through Goblins' error printer, which
        ;; fails on its own (stack-ref) and hides what the upstream said.
        (let ((outcome (with-vat vat
                         (catch #t
                           (lambda ()
                             (cons 'ok (do-completion pool messages %default-completion-model)))
                           (lambda (key . args)
                             (cons 'failed (failure-reason key args)))))))
          (if (eq? (car outcome) 'ok)
              (cdr outcome)
              (begin
                (format (current-error-port)
                        "openvtc-parity-narrate: AI narration skipped (~a)\n" (cdr outcome))
                #f)))))
    (lambda (key . args)
      (format (current-error-port) "openvtc-parity-narrate: AI narration skipped (~a ~a)\n" key args)
      #f)))

;; A Tor-routed host — the box — has no clearnet resolver, and its gateway
;; runs as `torsocks guile` for that reason. This job takes the same route: with
;; no direct answer for the upstream host and a torsocks to hand, it re-executes
;; itself once under torsocks, so the fetch and the completion both have a way out.
(define %torified-flag "PLAYNET_PARITY_TORIFIED")

(define (direct-route?)
  (catch #t
    (lambda () (pair? (getaddrinfo "github.com" "443")))
    (lambda _ #f)))

(define (find-torsocks)
  (or (search-path (string-split (or (getenv "PATH") "") #\:) "torsocks")
      (let ((sys "/run/current-system/profile/bin/torsocks"))
        (and (file-exists? sys) sys))))

(define (maybe-torify! script)
  (unless (or (getenv %torified-flag) (direct-route?))
    (let ((torsocks (find-torsocks)))
      (when torsocks
        (setenv %torified-flag "1")
        (execl torsocks torsocks (readlink "/proc/self/exe")
               "--no-auto-compile" "-L" "module" script)))))

(define (main args)
  (maybe-torify! (car args))
  (let*-values (((report check-exit)
                 (read-all-output (open-input-pipe "tools/lint/openvtc-parity-check.sh 2>&1"))))
    (unless (zero? check-exit)
      ;; A check that could not run is a failure of the job, and says so: the
      ;; weekly log holds a report or a named error, never a quiet nothing.
      (display report)
      (format #t "\nopenvtc-parity: the check exited ~a — no report this run\n" check-exit)
      (exit check-exit))
    (narrate-and-print report)))

(define (narrate-and-print report)
  (let* ((keys (let ((k (or (getenv "API_KEYS") (getenv "OPENROUTER_KEYS") "")))
                 (if (string=? k "") #f k)))
         (n (flagged-count report)))
    (display report)
    (cond
     ((or (not n) (= n 0)) #t)  ; nothing flagged (or the line didn't parse) — raw output is enough
     ((not keys)
      (format #t "\n(no API_KEYS configured — AI narration skipped, ~a flagged commit(s) above)\n" n))
     (else
      (let ((summary (narrate report keys)))
        (when summary
          (format #t "\n--- AI narration (~a, best-effort, not the source of truth) ---\n~a\n"
                  (or (getenv "API_PROVIDER") "nano-gpt") summary)))))
    (exit 0)))
(main (command-line))
