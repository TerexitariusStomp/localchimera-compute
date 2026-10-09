;;; tests/keri/test-signup-disabled-gate.scm — PLAYNET_DISABLE_REAL_SIGNUP
;;; refuses identity-creating doors, leaves witnessing/seat-checking alone.
;;;
;;; A GDPR-deferral switch (see docs/planning/legal/gdpr-analysis.md), checked
;;; by gateway/lobby.scm's real-signup-enabled?. The var is set here, once,
;;; before any vat is spawned — mutating the process environment once vat
;;; threads are running is unspecified behavior in Guile, so this lives in its
;;; own file rather than toggling mid-test in test-lobby-seat-gate.scm.

(setenv "PLAYNET_DISABLE_REAL_SIGNUP" "1")

(use-modules (playnet test harness)
             (playnet identity fixture)
             ((playnet planner knowledge law product) #:select (product-feature feature-doors))
             (goblins)
             (srfi srfi-1))

(define-values (kp0 kp1 icp-json icp-said icp-alist aid icp-sigs)
  (test-identity "disabled-gate-passcode-21ch"))
(define-values (gateway-vat signup-vat signup-agent oobi-host lobby settle)
  (lobby-fixture))

(format #t "~%=== identity-creating doors, disabled ===~%")

(let ((r (settle (with-vat gateway-vat
                   ($ lobby 'signup "whoever" "" "" "")))))
  (check "signup refused while disabled"
         (and (pair? r) (eq? 'error (car r))))
  (check "…reason says disabled, not some other validation failure"
         (and (pair? r) (string? (cadr r)) (string-contains (cadr r) "disabled"))))

(let ((r (settle (with-vat gateway-vat
                   ($ lobby 'signup-with-icp "whoever" "" aid icp-alist icp-sigs)))))
  (check "signup-with-icp refused while disabled"
         (and (pair? r) (eq? 'error (car r)) (string-contains (cadr r) "disabled"))))

(let ((r (settle (with-vat gateway-vat
                   ($ lobby 'signup-with-kel "whoever" "" aid icp-alist icp-sigs (vector))))))
  (check "signup-with-kel refused while disabled"
         (and (pair? r) (eq? 'error (car r)) (string-contains (cadr r) "disabled"))))

(let ((r (settle (with-vat gateway-vat ($ lobby 'join "whoever" "" aid)))))
  (check "join refused while disabled"
         (and (pair? r) (eq? 'error (car r)) (string-contains (cadr r) "disabled"))))

(format #t "~%=== witnessing and seat-checking, unaffected ===~%")

(check "witness-kel still works — not an identity-creating door"
       (eq? 'ok (settle (with-vat gateway-vat
                          ($ lobby 'witness-kel aid icp-alist icp-sigs (vector))))))
(check "has-seat still works, and the refused join above never seated it"
       (not (settle (with-vat gateway-vat ($ lobby 'has-seat aid)))))

(format #t "~%=== the gate and the declaration name the same doors ===~%")

;; The four wrappers in lobby.scm and the four `#:feature account-creation`
;; declarations in protocol.scm are the same set, held here so neither can
;; drift: a fifth identity-creating door declared without a wrapper, or a
;; wrapper on a door the product's law does not list, fails this.
(check "the product feature account-creation reads off exactly the doors this file proves refused"
       (lset= equal?
              (feature-doors (product-feature 'account-creation))
              '((lobby . signup) (lobby . signup-with-icp)
                (lobby . signup-with-kel) (lobby . join))))

(test-summary!)
