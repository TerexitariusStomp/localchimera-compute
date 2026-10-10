;;; test-notify-router.scm — Phase 3 of the unified router: resolve a
;;; recipient's channels, gate by prefs, dedup across channels, render
;;; each channel in its own style, hand off to the dumb adapters.
;;;
;;; The routing decision (`plan-sends') is pure, so it's tested directly.
;;; A small actor smoke test exercises the ^notify-router shell + fan-out.
;;;
;;; Run: guile -L module tests/notify/test-notify-router.scm

(use-modules (playnet test harness)
             (playnet notify router)
             (playnet notify recipient)
             (playnet notify rendered)
             (goblins)
             (goblins actor-lib methods)
             (goblins vat)
             (srfi srfi-1))

(define AID-A "EAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
(define AID-B "EBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

;; A rich buffer alert (red zone -> alert severity).
(define buf
  '((kind . buffer-status) (spec-id . "tomato") (zone . red)
    (onhand . 3) (tor . 5) (toy . 10) (tog . 20)))
;; A low-severity demand shift (info).
(define adu
  '((kind . adu-shift) (spec-id . "corn") (direction . up) (change-pct . 12)))

;; Fake adapter refs (plan-sends only needs identity, not real actors).
(define adapters '((browser . browser-ref)
                   (email   . email-ref)
                   (telegram . telegram-ref)))

;; Three channels, three styles.
(define bindings
  (list (make-binding 'browser  'inbox-a  'terse)
        (make-binding 'email    "hiro@playnet.earth" 'rich)
        (make-binding 'telegram 42       'markdown)))

(define (send-adapters sends) (map car sends))
(define (send-for kind sends)
  (find (lambda (s) (eq? (car s) (assq-ref adapters kind))) sends))

(display "\n── plan-sends: fan-out to every channel, each in its style ──\n")
(call-with-values
  (lambda () (plan-sends adapters '() AID-A buf bindings (default-prefs)))
  (lambda (sends recent status)
    (check "status delivered" status 'delivered)
    (check "one send per bound channel" (length sends) 3)
    (check "browser + email + telegram all targeted"
           (sort (map (lambda (s) (car s)) sends)
                 (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
           '(browser-ref email-ref telegram-ref))
    ;; severity is canonical (alert) on EVERY channel, regardless of style
    (check "browser carries canonical alert severity"
           (rendered-type (caddr (send-for 'browser sends))) 'alert)
    (check "email carries canonical alert severity"
           (rendered-type (caddr (send-for 'email sends))) 'alert)
    ;; but presentation differs per style
    (check "browser body is terse"
           (rendered-body (caddr (send-for 'browser sends)))
           "tomato: 3 on hand (red zone)")
    (check "email title is the rich override"
           (rendered-title (caddr (send-for 'email sends)))
           "Buffer alert: tomato")
    (check "dedup memory now holds the tag"
           (member (cons AID-A "buffer-tomato") recent) (list (cons AID-A "buffer-tomato")))))

(display "\n── cross-channel dedup (suppress duplicates) ──\n")
(call-with-values
  (lambda () (plan-sends adapters (list (cons AID-A "buffer-tomato"))
                         AID-A buf bindings (default-prefs)))
  (lambda (sends recent status)
    (check "second fire of same tag is suppressed" status 'suppressed-duplicate)
    (check "no sends on a duplicate" (length sends) 0)))

(display "\n── prefs gate: kind opt-out + severity floor ──\n")
;; enabled-kinds excludes adu-shift
(call-with-values
  (lambda () (plan-sends adapters '() AID-A adu bindings
                         (make-prefs '(buffer-status) 'info #f '())))
  (lambda (sends recent status)
    (check "kind not in enabled-kinds is suppressed" status 'suppressed-by-prefs)))
;; min-severity = alert drops the info-level adu-shift
(call-with-values
  (lambda () (plan-sends adapters '() AID-A adu bindings
                         (make-prefs #t 'alert #f '())))
  (lambda (sends recent status)
    (check "below min-severity is suppressed" status 'suppressed-by-prefs)))
;; but the alert-level buffer passes an alert floor
(call-with-values
  (lambda () (plan-sends adapters '() AID-A buf bindings
                         (make-prefs #t 'alert #f '())))
  (lambda (sends recent status)
    (check "at/above min-severity passes" status 'delivered)))

(display "\n── no binding for a kind we lack an adapter for is skipped ──\n")
(call-with-values
  (lambda () (plan-sends '((browser . browser-ref))  ; only browser adapter known
                         '() AID-A buf bindings (default-prefs)))
  (lambda (sends recent status)
    (check "only the channel with a known adapter is sent" (length sends) 1)
    (check "and it is the browser" (car (car sends)) 'browser-ref)))

(display "\n── actor shell + scope fan-out (dedup threaded across members) ──\n")
(define vat (spawn-vat))
(with-vat vat
  (define reg (spawn ^recipient-registry '()))
  ($ reg 'bind AID-A 'browser 'inbox-a 'terse)
  ($ reg 'bind AID-B 'browser 'inbox-b 'terse)
  ;; a real (if inert) adapter so the router's <-np deliver has a target
  (define mock-adapter (spawn (lambda (_b) (methods ((deliver ctx r) 'ok)))))
  (define router (spawn ^notify-router reg `((browser . ,mock-adapter)) '()))
  ;; scope fan-out to two members
  ($ router 'notify-scope (list AID-A AID-B) buf)
  (check "dedup memory holds both members' tags after fan-out"
         ($ router 'dedup-count) 2)
  ;; a repeat scope fire is fully deduped
  ($ router 'notify-scope (list AID-A AID-B) buf)
  (check "repeat fan-out adds no new dedup entries"
         ($ router 'dedup-count) 2)
  ;; forget one, it can fire again
  ($ router 'forget AID-A "buffer-tomato")
  (check "forget removed one dedup entry" ($ router 'dedup-count) 1))

(display "\n── fallback: unbound recipient → legacy sink (cutover safety net) ──\n")
(with-vat vat
  (define reg2 (spawn ^recipient-registry '()))   ; empty: no bindings for anyone
  (define fallback-sink
    (spawn (lambda (_b) (methods ((print ev) 'ok)))))
  (define router2
    (spawn ^notify-router reg2 '((browser . browser-ref)) '() fallback-sink))
  ;; AID with no bindings → hands off to the fallback sink (status is the
  ;; synchronous proof; the <-np to the sink itself is eventual).
  (check "notify on an unbound recipient returns 'fell-back"
         ($ router2 'notify AID-A buf) 'fell-back)
  (check "fallback did NOT record a dedup tag (only real deliveries do)"
         ($ router2 'dedup-count) 0))

(test-summary!)
