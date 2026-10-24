;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-ai-async-controller.scm — the browser's exact AI path, proven server-side.
;;;
;;; The browser calls ($ controller 'evaluate-to-sink expr sink), where (ai …)
;;; suspends to the gateway and the result is delivered to `sink` when the
;;; completion arrives in a LATER turn. Here we spawn a real ^expressor-controller
;;; and drive that path with a DEFERRED resumer (stash k, resume later) — exactly
;;; what the gateway `on` callback does — so we validate it where Guile can run it.
;;;
;;; Run: guile -L module tests/org/test-ai-async-controller.scm

(use-modules (localchimera test harness)
             (localchimera org gplay)
             (goblins) (goblins vat) (ice-9 format))

(define base `((+ . ,+) (list . ,list)))
(define vat (spawn-vat))

;;; ─── 1. no (ai …): the sink is delivered synchronously ────────────────────
(display "\n── evaluate-to-sink with a plain expr delivers the value at once ──\n")
(with-vat vat
  (let* ((org  (make-initial-org base))
         (pair (create-expressor-pair org 'bob "bob-key"))
         (controller (cdr pair))
         (delivered 'none))
    ($ controller 'evaluate-to-sink '(+ 1 2) (lambda (v) (set! delivered v)))
    (check "a non-AI expression resolves the sink synchronously" delivered 3)))

;;; ─── 2. (ai …) with a DEFERRED resumer: sink fires only on resume ─────────
;;; This is the browser: the completion arrives in a later turn; until then the
;;; sink has NOT run, and evaluate-to-sink has already returned.
(display "\n── (ai …) suspends; the sink fires when the deferred resume lands ──\n")
(with-vat vat
  (let* ((org  (make-initial-org base))
         (pair (create-expressor-pair org 'carol "carol-key"))
         (controller (cdr pair))
         (delivered 'none)
         (stash #f))
    ;; handler builds a prompt then suspends via ai-request (like web-ai-query)
    (set-ai-handler! (lambda (prompt org exp) (ai-request "SYSTEM" prompt #f)))
    ;; resumer stashes k (as the gateway `on` callback would) — no immediate resume
    (set-ai-resumer! (lambda (k system user model) (set! stash (cons k user)) #f))

    ($ controller 'evaluate-to-sink '(ai "make me a plan")
       (lambda (v) (set! delivered v)))
    (check "before the gateway answers, the sink has NOT been called"
           delivered 'none)

    ;; …the gateway responds in a later turn: resume the captured continuation…
    ((car stash) (string-append "PLAN for: " (cdr stash)))
    (check "resuming the continuation delivers the completion to the sink"
           delivered "PLAN for: make me a plan")))

;;; ─── 3. ai-eval through the controller: parse + evaluate after resume ─────
(display "\n── ai-eval: the resumed completion is parsed and evaluated ──\n")
(with-vat vat
  (let* ((org  (make-initial-org base))
         (pair (create-expressor-pair org 'dave "dave-key"))
         (controller (cdr pair))
         (delivered 'none)
         (stash #f))
    (set-ai-eval-handler!
     (lambda (prompt org exp) (call-with-input-string (ai-request "S" prompt #f) read)))
    (set-ai-resumer! (lambda (k system user model) (set! stash k) #f))
    ($ controller 'evaluate-to-sink '(ai-eval "give a number")
       (lambda (v) (set! delivered v)))
    (check "ai-eval sink is pending until resume" delivered 'none)
    ((car (list stash)) "1234")          ; the gateway's "completion" is Scheme text
    (check "the resumed completion is read + evaluated, then sunk" delivered 1234)))

(display "\n")
(test-summary!)
