;;; voice/quorum.scm — a scope's own word on how far real quorum must
;;; reach before its governance acts bind.
;;;
;;; `admit-commune`/`admit-commune-remote`/`merge-with`/`split`/
;;; `rejoin-federation` (scope.scm) — and now `accept-socialization`/
;;; `accept-reimbursement` — each accept an OPTIONAL `'ratification SAID`:
;;; when supplied, it must point at a closed, threshold-passed `^ballot`'s
;;; ratification ACDC (verify-ratification!, scope.scm) naming this exact
;;; act. Left unsupplied, none of them refuse — a bare gov-cap (self-
;;; mintable by any member today) is enough, which is docs/playnet.typ's
;;; "producers recognise... weighted by labour-voice ALONE" in name only.
;;;
;;; This is the policy a scope sets to close that gap FOR ITSELF: once
;;; `require-ratification` is true, scope.scm's `require-ratification!`
;;; helper refuses any of those acts that arrive without a passing
;;; ratification, instead of silently accepting gov-cap alone. Off by
;;; default — every scope that has never called `set-governance-policy!`
;;; keeps exactly today's behaviour, unchanged.
;;;
;;; Same shape as first-person/personhood-policy.scm: an explicit value wins, else the
;;; scope's own plan-store meta row "governance-policy", else the default
;;; here. Written through ^scope's gov-cap-gated `set-governance-policy!`;
;;; every reader reads the row fresh, so a change binds the next act
;;; without a restart.

(define-module (playnet voice quorum)
  #:use-module (playnet utils governed-row)
  #:use-module (srfi srfi-1)
  #:export (governance-policy *governance-policy-defaults* *governed-dials* policy-dials))

;; the rows the engine takes as solve keywords, in the order the service hands
;; them: policy key → engine keyword
(define *governed-dials*
  '((voice-tau . #:voice-tau) (pref-bound . #:pref-bound) (emp-rho . #:emp-rho)
    (kappa . #:kappa) (want-as-cap . #:want-as-cap) (stock-draw-hours . #:stock-draw-hours)))

(define (policy-dials plan-store)
  "The governed dials of PLAN-STORE's scope as one keyword list, every row
   read fresh (a change binds the next solve): (#:voice-tau τ #:pref-bound β …)."
  (append-map (lambda (d) (list (cdr d) (governance-policy plan-store (car d)))) *governed-dials*))

(define *governance-policy-defaults*
  '((require-ratification . #f)
    ;; ── THE ONE REGISTRY OF GOVERNED NUMBERS ──────────────────────────────
    ;; Every dial the engine reads at solve time and a scope may set lives
    ;; here with its default; the planner service reads each row for every
    ;; solve (service.scm `policy-kw`) and hands it to the engine as a
    ;; keyword, so the engine's own global is a per-solve setting and never
    ;; a process-wide state some caller once wrote. A dial's default here
    ;; equals the engine's (tests/economy/test-governance-policy.scm pins
    ;; the two), so a scope with no policy row solves as the engine does.
    ;; the voice field's bound (docs/planning/voice/voice-follows-work.md): how
    ;; far a producer stance may re-weigh an hour of a way of working, 0 ≤ τ < 1.
    ;; 0 is today — every solve reads the plan as if no stance stood.
    (voice-tau . 0.0)
    ;; the who rail's bound β (engine `*pref-bound*`, the egalitarian matching
    ;; principle): a private skill preference is read clamped to [−β, β]
    (pref-bound . 1.0)
    ;; EMP congestion weight ρ (engine `*emp-rho*`): small ⇒ equalize among equals
    (emp-rho . 0.05)
    ;; κ (solver `*kappa*`): the free-time weight, what an hour of the
    ;; plan's labour costs the objective
    (kappa . 0.02)
    ;; quantity as a cap (engine `*want-as-cap?*`, quantity-as-a-cap.md): a
    ;; citizen's own want emitted as a cap term pulled by its mass alone
    (want-as-cap . #t)
    ;; the barrier residue's weight (engine `*stock-draw-hours*`): how dearly
    ;; a scope holds a drawn stock past what is asked, in hours per unit
    (stock-draw-hours . 1.0)))

(define* (governance-policy plan-store key #:optional (explicit #f))
  "The governed value for KEY: EXPLICIT when given, else the plan-store's
   governance-policy row, else the default."
  (governed-row plan-store "governance-policy" *governance-policy-defaults* key explicit))
