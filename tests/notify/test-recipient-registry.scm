;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-recipient-registry.scm — Phase 2 of the unified router: the
;;; AID → channels registry that makes the system multi-recipient.
;;;
;;; Run: guile -L module tests/notify/test-recipient-registry.scm

(use-modules (playnet test harness)
             (playnet notify recipient)
             (goblins)
             (goblins vat)
             (srfi srfi-1))

(define AID-A "EAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
(define AID-B "EBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

(display "\n── channel taxonomy + severity ──\n")
(check "email is durable"    (durable-kind? 'email) #t)
(check "telegram is durable" (durable-kind? 'telegram) #t)
(check "browser is NOT durable" (durable-kind? 'browser) #f)
(check "browser is live"     (live-kind? 'browser) #t)
(check "push is live"        (live-kind? 'push) #t)
(check "alert >= info"       (severity>=? 'alert 'info) #t)
(check "info NOT >= alert"   (severity>=? 'info 'alert) #f)
(check "normal >= normal"    (severity>=? 'normal 'normal) #t)

(display "\n── registry actor ──\n")
(define vat (spawn-vat))
(with-vat vat
  (define reg (spawn ^recipient-registry '()))

  ;; unknown AID: empty bindings, default prefs
  (check "unknown aid has no bindings" ($ reg 'bindings-for AID-A) '())
  (check "unknown aid is not known"    ($ reg 'known? AID-A) #f)
  (check "unknown aid gets default prefs" (prefs? ($ reg 'prefs-for AID-A)) #t)

  ;; bind a browser + email + telegram channel to AID-A
  ($ reg 'bind AID-A 'browser 'inbox-ref-a 'terse)
  ($ reg 'bind AID-A 'email "hiro@playnet.earth" 'rich)
  ($ reg 'bind AID-A 'telegram 12345 'markdown)
  (check "aid-A now known" ($ reg 'known? AID-A) #t)
  (check "aid-A has 3 bindings" (length ($ reg 'bindings-for AID-A)) 3)

  ;; binding is idempotent on kind+ctx (re-bind email with new style)
  ($ reg 'bind AID-A 'email "hiro@playnet.earth" 'terse)
  (check "re-binding same kind+ctx does not duplicate"
         (length ($ reg 'bindings-for AID-A)) 3)
  (let ((email-b (find (lambda (b) (eq? (binding-kind b) 'email))
                       ($ reg 'bindings-for AID-A))))
    (check "re-bind updated the style" (binding-style email-b) 'terse))

  ;; a second recipient is independent
  ($ reg 'bind AID-B 'push "device-xyz" 'terse)
  (check "aid-B independent" (length ($ reg 'bindings-for AID-B)) 1)
  (check "two recipients tracked" ($ reg 'count) 2)

  ;; unbind a single channel
  ($ reg 'unbind AID-A 'telegram 12345)
  (check "unbind removed one binding" (length ($ reg 'bindings-for AID-A)) 2)

  ;; unbind-kind drops all of a kind (e.g. browser disconnected)
  ($ reg 'bind AID-A 'browser 'inbox-ref-a2 'terse) ; a second browser tab
  (check "aid-A has 2 browser + email now" (length ($ reg 'bindings-for AID-A)) 3)
  ($ reg 'unbind-kind AID-A 'browser)
  (check "unbind-kind dropped both browser bindings"
         (length ($ reg 'bindings-for AID-A)) 1)
  (check "remaining binding is the email"
         (binding-kind (car ($ reg 'bindings-for AID-A))) 'email)

  ;; prefs round-trip
  ($ reg 'set-prefs AID-A (make-prefs '(buffer-status ipex-apply) 'alert #f '()))
  (let ((p ($ reg 'prefs-for AID-A)))
    (check "prefs enabled-kinds stored" (prefs-enabled-kinds p) '(buffer-status ipex-apply))
    (check "prefs min-severity stored"  (prefs-min-severity p) 'alert))

  (display "\n── durable-table snapshot (persistence) ──\n")
  ;; AID-A now has only an email binding (durable); AID-B only push (live)
  (let ((snap ($ reg 'durable-table)))
    (check "snapshot includes AID-A (has durable email)"
           (and (assoc-ref snap AID-A) #t) #t)
    (check "snapshot EXCLUDES AID-B (push is live-only)"
           (assoc-ref snap AID-B) #f)))

(test-summary!)
