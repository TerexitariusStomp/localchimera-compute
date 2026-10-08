;;; test-work-correction.scm — a corrected work event leaves every total.
;;;
;;; Hours count the moment they are worked against a declared need; what keeps
;;; that trust sound is that a correction can take them back. A correction is an
;;; event of the same action with a SIGNED quantity that `corrects` another (VF
;;; accounting.md): the original stays in the log and the net is the sum. A full
;;; back-out leaves the event in no total. Pinned here as properties of the log
;;; (docs/planning/identity/skill-standing.md §5):
;;;   1. one back-out, every total — credit, skill hours, and the intent's
;;;      satisfaction all drop by the corrected event's share, and nothing
;;;      else moves;
;;;   2. the records agree — the correction reaches the credential bridge, the
;;;      corrected event's credential is revoked, and the co-signer fold over
;;;      live credentials drops it too;
;;;   3. Σ skill hours = validated gross over work that names a skill; work
;;;      that names none stands in the ledger and in no skill's hours;
;;;   4. corrections add: any number may correct one event, each by its signed
;;;      quantity, and a correction of a correction nets as well;
;;;   5. replay agrees — the log folded onto a fresh observer reaches the same
;;;      totals, corrections included.
;;;
;;; Run: guile -L module tests/planner/test-work-correction.scm

(use-modules (playnet test harness))
(use-modules ((playnet test events) #:select (ev)))
(use-modules (playnet planner observation observer) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet governance acdc-bridge) (playnet keri acdc) (playnet keri acdc-store))
(use-modules ((playnet planner observation observer) #:select (void-event)))
(use-modules ((playnet governance acdc-bridge)
              #:select (make-credentialing-on-event skill-attestation-standing)))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define (intent! obs aid skill hours intent-id)
  ($ obs 'register-intent
     (make-intent #:id intent-id #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours "hour") #:provider aid)))

;; a work event by AID in SKILL for HOURS (negative on a correction), satisfying
;; INTENT-ID, correcting CORRECTS when given
(define* (work-event aid skill hours event-id intent-id #:optional (corrects #f))
  (make-economic-event
    #:id event-id #:action 'work #:resource-conforms-to skill
    #:provider aid #:effort-quantity (and hours (make-measure hours "hour")) #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies intent-id #:corrects corrects))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Work Correction Test")) store))

(define (totals obs)
  (list ($ obs 'validated-gross "ada")
        ($ obs 'practiced-hours "ada" "spec:baker")
        ($ obs 'practiced-hours "ada" "spec:surgeon")
        ($ obs 'validated-gross "bob")))

(display "\n── a back-out: the work is taken out of every total ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer))
        (acdc (spawn-acdc-store))
        (heard '()))
    ;; the credential bridge on the on-event slot, a listener beside it
    ($ obs 'set-callback 'on-event (make-credentialing-on-event acdc "EScope"))
    (let ((obs ($ scope 'observer)))
      ($ obs 'add-event-listener (lambda (ev . _) (set! heard (cons (economic-event-id ev) heard))))
      (intent! obs "ada" "spec:baker"   6 "in-1")
      (intent! obs "ada" "spec:baker"   4 "in-2")
      (intent! obs "ada" "spec:surgeon" 10 "in-3")
      (intent! obs "bob" "spec:baker"   8 "in-4")
      ($ obs 'record-event (work-event "ada" "spec:baker"   6 "ev-1" "in-1"))
      ($ obs 'record-event (work-event "ada" "spec:baker"   4 "ev-2" "in-2"))
      ($ obs 'record-event (work-event "ada" "spec:surgeon" 10 "ev-3" "in-3"))
      ($ obs 'record-event (work-event "bob" "spec:baker"   8 "ev-4" "in-4"))
      (check "before: gross 20, baker 10, surgeon 10, bob 8" (totals obs) '(20 10 10 8))
      (check "before: the records hold both of ada's baking events"
             (assq-ref (assoc-ref (skill-attestation-standing acdc "ada") "spec:baker") 'events) 2)

      ;; ev-1 never happened: backed out by a work event of the opposite quantity
      ($ obs 'apply-correction
         (void-event ($ obs 'get-event "ev-1") "ev-1-void" "never happened" "scope"
                     "2026-03-02T08:00:00Z"))

      (check "after: ada's credit and her baking hours drop by exactly the voided 6; nothing else moves"
             (totals obs) '(14 4 10 8))
      (check "the ledger and the skills still agree"
             (+ ($ obs 'practiced-hours "ada" "spec:baker")
                ($ obs 'practiced-hours "ada" "spec:surgeon"))
             ($ obs 'validated-gross "ada"))
      (check "the need the voided work had met reads unmet again"
             ($ obs 'validated-fraction (work-event "x" "spec:baker" 1 "probe" "in-1")) 0)
      (check-pred "the original stays in the log — the record of what was said"
                  ($ obs 'get-event "ev-1"))
      (check-pred "the correction was told to the listeners, as any event is"
                  (member "ev-1-void" heard))
      (check "the records agree: one baking event stands in the live credentials"
             (assq-ref (assoc-ref (skill-attestation-standing acdc "ada") "spec:baker") 'events) 1)

      (display "\n── an adjustment: six hours were really three ──\n")
      (intent! obs "ada" "spec:surgeon" 6 "in-5")
      ($ obs 'record-event (work-event "ada" "spec:surgeon" 6 "ev-5" "in-5"))
      (check "recorded: surgeon 16" ($ obs 'practiced-hours "ada" "spec:surgeon") 16)
      ;; record-event with a `corrects` edge is the same door: -3 of the six
      ($ obs 'record-event (work-event "ada" "spec:surgeon" -3 "ev-5-fix" "in-5" "ev-5"))
      (check "restated: three hours against a need of six validates at one half — 1.5"
             ($ obs 'practiced-hours "ada" "spec:surgeon") 23/2)
      (check "the records hold the net, and the stated record is revoked"
             (assq-ref (assoc-ref (skill-attestation-standing acdc "ada") "spec:surgeon") 'events) 2)

      (display "\n── corrections add ──\n")
      (check-pred "an event may be corrected again: one more hour comes off"
                  (begin ($ obs 'record-event (work-event "ada" "spec:surgeon" -1 "ev-5-again" "in-5" "ev-5"))
                         (= 32/3 ($ obs 'practiced-hours "ada" "spec:surgeon"))))
      (check-pred "…and a correction of a correction nets as well: the six hours come back"
                  (begin ($ obs 'record-event
                            (work-event "ada" "spec:surgeon" 4 "ev-5-fix2" "in-5" "ev-5-fix"))
                         (= 16 ($ obs 'practiced-hours "ada" "spec:surgeon"))))
      (check "a correction naming an event this log never held records as plain work"
             (begin (intent! obs "bob" "spec:baker" 2 "in-6")
                    ($ obs 'record-event (work-event "bob" "spec:baker" 2 "ev-6" "in-6" "ev-nowhere"))
                    ($ obs 'validated-gross "bob"))
             10)

      (display "\n── work that names no skill ──\n")
      (intent! obs "ada" #f 5 "in-7")
      ($ obs 'record-event (work-event "ada" #f 5 "ev-7" "in-7"))
      (check-pred "it stands in the credit ledger"
                  (= (+ 5 4 16) ($ obs 'validated-gross "ada")))
      (check "and in no skill's hours: no row is keyed by #f"
             (filter (lambda (p) (not (car p))) ($ obs 'skill-hours-of "ada")) '())
      (check "Σ skill hours = gross over the work that names a skill"
             (apply + (map cdr ($ obs 'skill-hours-of "ada"))) (+ 4 16))

      (display "\n── replay agrees: the log, folded again, reaches the same totals ──\n")
      ;; the portable log replays as one record-event per payload (the list form
      ;; is what it carries); the needs are the plan's, registered as before
      (let* ((scope2 (spawn-scope-root "Work Correction Replay"))
             (obs2   ($ scope2 'observer)))
        (for-each (lambda (i) (apply intent! obs2 i))
                  '(("ada" "spec:baker" 6 "in-1") ("ada" "spec:baker" 4 "in-2")
                    ("ada" "spec:surgeon" 10 "in-3") ("bob" "spec:baker" 8 "in-4")
                    ("ada" "spec:surgeon" 6 "in-5") ("bob" "spec:baker" 2 "in-6")
                    ("ada" #f 5 "in-7")))
        (for-each (lambda (ev)
                    ($ obs2 'record-event (list->economic-event (economic-event->list ev))))
                  ($ obs 'all-events))
        (check "every total, replayed" (totals obs2) (totals obs))
        (check "every skill's hours, replayed"
               (sort ($ obs2 'skill-hours-of "ada") (lambda (a b) (string<? (car a) (car b))))
               (sort ($ obs  'skill-hours-of "ada") (lambda (a b) (string<? (car a) (car b)))))))))

(display "\n── a partial correction nets every credential, not only work ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer))
        (acdc (spawn-acdc-store)))
    ($ obs 'set-callback 'on-event (make-credentialing-on-event acdc "EScope"))
    (define (live-qty event-id)
      (let ((c (find (lambda (c) (and (equal? event-id (cred-claim c 'event-id)) (not (cred-revoked? c))))
                     ($ acdc 'all))))
        (and c (cred-claim c 'qty))))
    ($ obs 'record-event (ev "obs-1" 'raise #:rid "obs-rice" #:spec "rice" #:q 10.0 #:provider "ada" #:receiver "ada"))
    (check "an observation credential states what the event stated" (live-qty "obs-1") 10.0)
    ($ obs 'record-event (ev "obs-1-fix" 'raise #:rid "obs-rice" #:spec "rice" #:q -3.0 #:provider "ada" #:receiver "ada"
                             #:corrects "obs-1"))
    (check "a partial correction leaves the live credential at the net: 7" (live-qty "obs-1") 7.0)
    ($ obs 'record-event (ev "obs-1-void" 'raise #:rid "obs-rice" #:spec "rice" #:q -7.0 #:provider "ada" #:receiver "ada"
                             #:corrects "obs-1"))
    (check "a full back-out leaves no live credential" (live-qty "obs-1") #f)))

(display "\n")
(test-summary!)
