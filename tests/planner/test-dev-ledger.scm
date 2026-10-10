;;; test-dev-ledger.scm — the development scope's books.
;;;
;;; A row of the week's plan taken is a commitment; an issue solved is the
;;; work that fulfils it and the deliverable produced
;;; (module/playnet/dev/ledger.scm). The tools that book these
;;; run on a timer and keep no memory, so every fact is booked once however
;;; often it is told, and the books stand across a restart.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-dev-ledger.scm

(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (playnet observation states) (srfi srfi-1)
             (playnet vf schemas)
             (playnet dev recipes)
             (playnet dev priorities)
             (playnet dev plan)
             (playnet dev ledger)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define* (fake-issue oid title labels #:optional (status "open") (reason #f))
  (cons oid
        `(("title" . ,title)
          ("state" . (("status" . ,status) ,@(if reason `(("reason" . ,reason)) '())))
          ("labels" . ,(list->vector labels))
          ("assignees" . #()))))

(define issues
  (list (fake-issue "aaa111" "Planned and taken"    '("area:planner" "kind:feature" "prio:p0" "est:12h"))
        (fake-issue "bbb222" "Done by box — earns nothing" '("area:infra" "kind:chore" "prio:p1" "est:5h" "spent:7h"))
        (fake-issue "ccc333" "Done by nobody we know" '("area:infra" "kind:bug" "prio:p2"))
        (fake-issue "ddd444" "Done by a real AID"    '("area:planner" "kind:chore" "prio:p2" "est:3h"))))
(define people
  '(((id . "ann") (hours . 40) (areas . ("planner" "infra")) (aid . "did:test:ann-real-aid"))
    ((id . "box") (hours . 28) (areas . ("infra")) (kind . agent))
    ((id . "carol") (hours . 0))))   ; not in the week's plan — did work anyway, real AID unstated
(define facts (issues->facts issues))
(define (fact oid) (find (lambda (f) (equal? oid (fact-ref f 'oid))) facts))
(define span (dev-week-span))

(define (events-of scope) ($ ($ scope 'observer) 'all-events))
(define (event scope id) ($ ($ scope 'observer) 'get-event id))
(define (hours-of e) (measure-has-numerical-value (economic-event-effort-quantity e)))

(define vat (spawn-vat #:name "dev-ledger-test"))

;;; ── a row taken ──────────────────────────────────────────────────────────────

(display "\n── a row of the plan, taken ──\n")

(with-vat vat
  (let* ((scope (spawn-scope-root "playnet development")))
    (seed-dev-scope! scope facts people)
    (let* ((rows (read-dev-plan (plan-dev-week scope facts people #:meeting? #f) facts people))
           (row  (find (lambda (r) (equal? "aaa111" (row-ref r 'oid))) rows))
           (lead (row-ref row 'lead))
           (cids (commit-row! scope row #:span span #:only lead))
           (c    ($ ($ scope 'plan-store) 'get-commitment (car cids))))
      (check "the planner issue is planned, and ann leads it" (list (row-ref row 'state) lead) '(planned "ann"))
      (check "taking the lead's share makes one commitment" (length cids) 1)
      (check "…named for the issue and the one who took it" (car cids) (commitment-id-for "aaa111" "ann"))
      (check "…a work commitment, by the one who took it" (list (commitment-action c) (commitment-provider c)) '(work "ann"))
      (check "…into the issue's act" (commitment-input-of c) (dev-process-id "aaa111"))
      (check "…for the share's hours"
             (measure-has-numerical-value (commitment-effort-quantity c))
             (assoc-ref (row-ref row 'shares) "ann"))
      (check "…inside the week" (list (commitment-has-beginning c) (commitment-has-end c))
             (list (car span) (cdr span)))
      (check "taking it again keeps the commitment it has"
             (begin (commit-row! scope row #:span span #:only lead)
                    (length (issue-commitments scope "aaa111")))
             1)
      (check-pred "the observer tracks it, open"
                  (find (lambda (fs) (equal? (car cids) (fulfillment-state-commitment-id fs)))
                        ($ ($ scope 'observer) 'open-fulfillments)))

      ;;; ── the issue solved ─────────────────────────────────────────────────────
      (display "\n── the issue solved ──\n")
      (let* ((before (length (events-of scope)))
             (ids    (book-issue-done! scope (fact "aaa111") #:people people))
             (work   (event scope (commitment-event-id c)))
             (done   (event scope (done-event-id "aaa111"))))
        (check "two facts are booked: the work and the deliverable" (length ids) 2)
        (check "…named ev- over the commitment it fulfils, record-work-done's own convention"
               (car ids) (commitment-event-id c))
        (check "the work is credited to ann's real AID, not her scope-local name — provider-aid"
               (economic-event-provider work) "did:test:ann-real-aid")
        (check "…at the issue's skill" (economic-event-resource-conforms-to work) (dev-skill "planner"))
        (check "…for the hours the issue states" (hours-of work) 12.0)
        (check "…fulfilling the commitment" (economic-event-fulfills work) (car cids))
        (check "the deliverable is one unit of the issue's spec"
               (list (economic-event-action done)
                     (economic-event-resource-conforms-to done)
                     (measure-has-numerical-value (economic-event-resource-quantity done)))
               (list 'produce (issue-spec-id "aaa111") 1))
        (check "…output of the issue's own act, made by its own recipe" (economic-event-output-of done) (dev-process-id "aaa111"))
        (check "…fulfilling no real commitment (record-flow-done's end-commitment attempt fails closed)"
               (economic-event-fulfills done) (done-event-id "aaa111"))
        (check-pred "the commitment ended, finished"
                    (commitment-finished ($ ($ scope 'plan-store) 'get-commitment (car cids))))
        (check "…and the observer holds it fulfilled in full"
               (let ((fs (find (lambda (fs) (equal? (car cids) (fulfillment-state-commitment-id fs)))
                               ($ ($ scope 'observer) 'all-fulfillments))))
                 (and fs (measure-has-numerical-value (fulfillment-state-total-fulfilled fs))))
               12.0)
        (check-pred "the issue reads as booked" (booked? scope "aaa111"))
        (check "told again, nothing is booked again"
               (list (book-issue-done! scope (fact "aaa111"))
                     (- (length (events-of scope)) before))
               (list '() 2)))

      ;;; ── work done outside the plan ───────────────────────────────────────────
      (display "\n── work the plan never placed ──\n")
      (book-issue-done! scope (fact "bbb222") #:by "box" #:people people)
      (check-pred "box's own deliverable still lands" (booked? scope "bbb222"))
      (check "…but box earns no work event — the defensive check on the #:by path"
             (filter (lambda (e) (and (eq? 'work (economic-event-action e))
                                      (equal? (dev-process-id "bbb222") (economic-event-input-of e))))
                     (events-of scope))
             '())
      (book-issue-done! scope (fact "ccc333"))
      (check "an issue solved by nobody the scope knows books its deliverable"
             (and (booked? scope "ccc333") #t) #t)
      (check "…and no work"
             (filter (lambda (e) (and (eq? 'work (economic-event-action e))
                                      (equal? (dev-process-id "ccc333") (economic-event-input-of e))))
                     (events-of scope))
             '())

      ;;; ── a real AID, resolved ─────────────────────────────────────────────────
      (display "\n── a human with no stated AID still books ──\n")
      (book-issue-done! scope (fact "ddd444") #:by "carol" #:people people)
      (let ((work (event scope (work-event-id "ddd444" "carol"))))
        (check-pred "carol, outside the plan and with no stated AID, still books" work)
        (check "…under her own bare id, provider-aid's own fallback"
               (economic-event-provider work) "carol"))

      ;;; ── the books ────────────────────────────────────────────────────────────
      (display "\n── the books ──\n")
      (check "hours by who worked and at what skill — ann under her real AID, box in nobody's"
             (ledger-hours scope)
             (list (list "carol" (dev-skill "planner") 3.0)
                   (list "did:test:ann-real-aid" (dev-skill "planner") 12.0))))))

;;; ── across a restart ─────────────────────────────────────────────────────────

(display "\n── the books stand across a restart ──\n")

(define store-path (string-append (or (getenv "TMPDIR") "/tmp") "/dev-ledger-test-"
                                  (number->string (getpid)) ".syrup"))
(false-if-exception (delete-file store-path))

(call-with-values (lambda () (open-dev-ledger store-path))
  (lambda (vat1 scope1)
    (with-vat vat1
      (seed-dev-scope! scope1 facts people)
      (book-issue-done! scope1 (fact "bbb222") #:by "box"))))

(call-with-values (lambda () (open-dev-ledger store-path))
  (lambda (vat2 scope2)
    (with-vat vat2
      (check-pred "an issue booked before the restart reads as booked after it"
                  (booked? scope2 "bbb222"))
      (check "…so telling it again books nothing" (book-issue-done! scope2 (fact "bbb222") #:by "box") '())
      (check "…and an issue never booked reads as open" (booked? scope2 "aaa111") #f))))

(false-if-exception (delete-file store-path))

(test-summary!)
