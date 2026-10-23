;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-ai-async-evaluator.scm — the delimited-continuation AI seam in the org
;;; evaluator. Proves the evaluator can suspend at an AI completion and resume
;;; either synchronously (server: value returns normally) or LATER (browser: the
;;; result flows out through the resumed continuation) — without CPS-converting
;;; the ~60 synchronous special forms.
;;;
;;; Run: guile -L module tests/org/test-ai-async-evaluator.scm

(use-modules (playnet test harness)
             (playnet org gplay)
             (ice-9 format))

;; the handlers below ignore the org; a bare symbol stands in for it.
(define org 'org)
(define (run expr) (call-with-ai-prompt (lambda () (evaluate expr org '() 'me))))

;;; ─── 1. a synchronous handler that never suspends (server path) ────────────
;;; The prompt is installed but nothing aborts → value returns normally.
(set-ai-handler! (lambda (prompt org exp) (string-append "sync:" prompt)))
(display "\n── a non-suspending (server-style) handler returns normally ──\n")
(check "(ai …) with a synchronous handler returns its value inline"
       (run '(ai "hello")) "sync:hello")

;;; ─── 2. handler suspends via ai-request; resumer resumes IMMEDIATELY ───────
;;; This is the server resumer shape: fulfil + (k result) in the same turn, so
;;; call-with-ai-prompt still returns the final value synchronously.
(set-ai-handler! (lambda (prompt org exp) (ai-request "SYS" prompt #f)))
(set-ai-resumer! (lambda (k system user model) (k (string-append "completed:" user))))
(display "\n── ai-request + synchronous resume returns the completion inline ──\n")
(check "the abort round-trips and the completion comes back as the value"
       (run '(ai "world")) "completed:world")
(check "the resumer saw the user prompt built by the form"
       (run '(ai "again")) "completed:again")

;;; ─── 3. DEFERRED resume (the browser path) ─────────────────────────────────
;;; The resumer stashes k and returns a sentinel NOW (as an async gateway call
;;; would); the real result is delivered later by resuming k — and it flows out
;;; as k's return value, exactly where the caller's `on` callback would receive
;;; it. The ~60 untouched synchronous forms run inside the resumed continuation.
(define stash #f)
(set-ai-resumer! (lambda (k system user model) (set! stash (cons k user)) '<pending>))
(display "\n── a deferred resumer suspends now, delivers the value later ──\n")
(define immediate (run '(ai "later")))
(check "call-with-ai-prompt returns the pending sentinel immediately" immediate '<pending>)
;; …the gateway responds in a later turn…
(define delivered ((car stash) (string-append "async:" (cdr stash))))
(check "resuming the stashed continuation delivers the final value" delivered "async:later")

;;; ─── 4. ai-eval suspends at the completion, then parses + evaluates it ─────
;;; The completion (a string of Scheme) is parsed AFTER resume, inside the
;;; synchronous continuation — proving post-completion evaluation composes with
;;; the suspend point. The resumer returns "42"; ai-eval reads + evaluates it.
(set-ai-eval-handler!
 (lambda (prompt org exp) (call-with-input-string (ai-request "SYS" prompt #f) read)))
(set-ai-resumer! (lambda (k system user model) (k "42")))
(display "\n── ai-eval: suspend, then parse + evaluate the completion ──\n")
(check "(ai-eval …) reads and evaluates the resumed completion"
       (run '(ai-eval "give me a number")) 42)

;;; ─── 5. no resumer + a suspending handler → honest error (fail-closed) ─────
(set! stash #f)
(set-ai-resumer! #f)
(set-ai-handler! (lambda (prompt org exp) (ai-request "SYS" prompt #f)))
(display "\n── a suspend with no resumer installed errors, not hangs ──\n")
(check-pred "aborting with no resumer raises rather than silently hanging"
            (catch #t (lambda () (run '(ai "x")) #f) (lambda _ #t)))

(display "\n")
(test-summary!)
