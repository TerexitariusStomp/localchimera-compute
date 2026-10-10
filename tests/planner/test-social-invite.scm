;;; test-social-invite.scm — the social-invite round-trip over the planner
;;; service: alice invites bob to a (non-work) event; bob's snapshot surfaces it
;;; under `proposals` (proposed-to filter); carol (not whitelisted) neither sees
;;; nor can accept it; bob accepts → a commitment appears for both.
;;;
;;; Run:  guile --no-auto-compile -L module tests/planner/test-social-invite.scm

(use-modules ((playnet wire rows) #:select (wire->plain))   ; a door's rows, read back as alists
             (playnet test harness)
             (playnet scope root)
             (playnet doors service)
             ((playnet utils clock) #:select (now instant->civil days->seconds))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

;; the invite is for TOMORROW evening: an invite is a question, and the wire
;; carries only questions that still stand — a fixed past date would test that
;; dead invites ride, which is the opposite of the law
(define tomorrow (instant->civil (+ (now) (days->seconds 1)) "%Y-%m-%d"))

(define (aref a k) (let ((p (and (pair? a) (assq k a)))) (and p (cdr p))))

(define vat (spawn-vat))
(with-vat vat
  (define scope (spawn-scope-root "invite-test"))
  (define svc   (spawn ^planner-service (hashmap-set (hashmap) "s1" scope)))

  ;; alice invites bob to "boardgames" (18:00–19:00)
  (define r ($ svc 'invite-contact "s1" "alice" "bob" "boardgames"
               (string-append tomorrow "T18:00:00")
               (string-append tomorrow "T19:00:00")))
  (check "invite-contact returns ok" (eq? 'ok (car r)))
  (define pid (aref (cdr r) 'proposal))
  (check "invite has a proposal id" (and (string? pid) #t))

  ;; bob's snapshot surfaces it under proposals (proposed-to includes bob)
  (define props-bob (or (aref (wire->plain ($ svc 'scope-snapshot "s1" #f "bob")) 'proposals) '()))
  (check "bob sees exactly one invite" (= 1 (length props-bob)))
  (check "invite label is the human name" (aref (car props-bob) 'label) "boardgames")
  (check "invite carries the inviter (from)" (aref (car props-bob) 'from) "alice")
  (check "invite is flagged social" (eq? #t (aref (car props-bob) 'social)))
  (check "invite start hour is 18" (aref (car props-bob) 'sh) 18)

  ;; carol (not whitelisted) neither sees nor can accept it
  (check "carol does NOT see the invite"
         (null? (or (aref (wire->plain ($ svc 'scope-snapshot "s1" #f "carol")) 'proposals) '())))
  (check "carol cannot accept (whitelist)"
         (eq? 'error (car ($ svc 'accept-invite "s1" "carol" pid))))

  ;; bob accepts → a commitment appears
  (check "bob accepts ok" (eq? 'ok (car ($ svc 'accept-invite "s1" "bob" pid))))
  (check "accepted invite becomes a commitment"
         (pair? (or (aref (wire->plain ($ svc 'scope-snapshot "s1" #f "bob")) 'commitments) '()))))

(test-summary!)
