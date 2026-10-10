;;; first-person/personhood-policy.scm — the ecosystem's word on how a person is recognised.
;;;
;;; Four numbers govern enrollment, and they are the ECOSYSTEM's to set, not a
;;; caller's argument and not a founder's discretion per stranger:
;;;
;;;   enrollment-k     how many verified witnesses must sign that they met
;;;                    the candidate — the FPP trust-triangle shape at 2
;;;   witness-cap      how many enrollments one witness may sign within
;;;                    witness-window — the Sybil bound that replaces a
;;;                    gatekeeper: nobody can mint persons faster than this
;;;   witness-window   the cap's window, seconds
;;;   ceremony-ttl     how long an ask collects before it lapses, seconds
;;;
;;; The shape is planner/legal/policy.scm's: an explicit value wins, else the
;;; ecosystem scope-root's plan-store meta row "personhood-policy", else the
;;; default here. A governor writes the row through ^scope's gov-cap-gated
;;; set-personhood-policy! (scope.scm); every reader — the request door, the
;;; witness gate, the expiry sweep — reads it fresh, so a change binds the
;;; next act without a restart.
;;;
;;; `effective-k` is what a ceremony actually asks: the policy's k clamped to
;;; the verified population, so a commune of one enrolls its second with one
;;; witness and grows into two — the first person is the operator's seed
;;; (founders.txt), never a deadlock.

(define-module (playnet keri first-person personhood-policy)
  #:use-module (playnet utils governed-row)
  #:export (personhood-policy *personhood-policy-defaults* effective-k))

(define *personhood-policy-defaults*
  `((enrollment-k   . 2)
    (witness-cap    . 10)
    (witness-window . ,(* 30 24 3600))
    (ceremony-ttl   . ,(* 30 24 3600))))

(define* (personhood-policy plan-store key #:optional (explicit #f))
  "The governed value for KEY: EXPLICIT when given, else the plan-store's
   personhood-policy row, else the default."
  (governed-row plan-store "personhood-policy" *personhood-policy-defaults* key explicit))

(define (effective-k k verified-count)
  "The quorum a ceremony asks: K clamped to the VERIFIED-COUNT of people who
   could sign, never below one."
  (max 1 (min k (max 1 verified-count))))
