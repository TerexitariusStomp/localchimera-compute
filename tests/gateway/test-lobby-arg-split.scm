;;; test-lobby-arg-split.scm — doors/lobby.scm's own boundary translation for the
;;; doors split from a bare variadic tail into real named arguments
;;;
;;; The delegation family (test-delegation-scope-arg.scm) already proved this
;;; pattern once. This covers the rest of the doors whose translation logic
;;; lives in doors/lobby.scm itself, where nothing tested it before: `open`'s
;;; target-ids/subject are a DIFFERENT positional encoding depending on KIND
;;; (the same slot means target-ids for an expression, subject for a
;;; ballot) — the riskiest of this whole batch — and cast-signed's `u`
;;; going from a checked-inside-the-body rest tail to a genuinely required
;;; argument, with vkey now never a caller argument at all.
;;;
;;; A stand-in governance-svc RECORDS what it was sent rather than acting on
;;; it — this is about doors/lobby.scm's OWN translation, which governance-svc's
;;; existing tests (spawned directly, bypassing doors/lobby.scm) never exercised.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-lobby-arg-split.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet doors lobby)
             (goblins) (goblins vat) (goblins actor-lib methods))

(define vat (spawn-vat))
(define ME "ECitizen000000000000000000000000000000000000")

(define asked '())
(define gov-svc
  (with-vat vat
    (spawn (lambda (bcom)
             (methods
               ((open . args) (set! asked (cons (cons 'open args) asked)) '(ok "p1"))
               ((cast-signed . args) (set! asked (cons (cons 'cast-signed args) asked)) 'ok))))))
(define session (with-vat vat (spawn ^lobby-session ME #f #f gov-svc #f)))
(define (last-call) (cdr (car asked)))

(display "\n── open: the SAME slot means a different thing per KIND ──\n")
(with-vat vat ($ session 'open 'ballot "policy" "id1" "desc" 'federation))
(check "ballot, neither optional given: rest is empty"
       (list-tail (last-call) 6) '())
(with-vat vat ($ session 'open 'ballot "policy" "id1" "desc" 'federation #f "subj"))
(check "ballot, subject given (target-ids irrelevant for a ballot): rest is (subject)"
       (list-tail (last-call) 6) '("subj"))
(with-vat vat ($ session 'open 'expression "policy" "id1" "desc" 'federation '("a" "b")))
(check "expression, target-ids given, no subject: rest is (target-ids)"
       (list-tail (last-call) 6) '(("a" "b")))
(with-vat vat ($ session 'open 'expression "policy" "id1" "desc" 'federation '("a" "b") "subj"))
(check "expression, both given: rest is (target-ids subject) — target-ids FIRST, not subject"
       (list-tail (last-call) 6) '(("a" "b") "subj"))

(display "\n── cast-signed: u is a real required argument, vkey never a caller's ──\n")
(with-vat vat ($ session 'cast-signed "id1" 'yes "2026-01-01T00:00:00Z" "sig" "nonce-u"))
(check "the call reaches governance-svc with u in its own slot"
       (list-ref (last-call) 5) "nonce-u")
(check-pred "…and a vkey is ALWAYS present (server-derived), never left for the caller to omit"
            (list-ref (last-call) 6))
(check "no oobi-host wired: vkey falls back to the caller's own AID"
       (list-ref (last-call) 6) ME)

(display "\n── audit-kinds/chat-post: the optional passes straight through ──\n")
(define planner-asked '())
(define planner-svc
  (with-vat vat
    (spawn (lambda (bcom)
             (methods
               ((audit-kinds . args) (set! planner-asked (cons (cons 'audit-kinds args) planner-asked)) '(ok))
               ((chat-post . args) (set! planner-asked (cons (cons 'chat-post args) planner-asked)) '(ok))
               ((declare-place . args) (set! planner-asked (cons (cons 'declare-place args) planner-asked)) '(ok))
               ((declare-means . args) (set! planner-asked (cons (cons 'declare-means args) planner-asked)) '(ok . "rid"))
               ((declare-need . args) (set! planner-asked (cons (cons 'declare-need args) planner-asked)) '(ok . "iid")))))))
(define session2 (with-vat vat (spawn ^lobby-session ME #f #f gov-svc #f #f #f #f #f #f #f planner-svc)))
(define (last-planner-call) (cdr (car planner-asked)))

(with-vat vat ($ session2 'audit-kinds "s1"))
(check "no options given: the slot is #f, not omitted" (last-planner-call) (list "s1" ME #f))
(with-vat vat ($ session2 'audit-kinds "s1" '((tolerance . 0.5))))
(check "options given: it reaches the planner intact" (last-planner-call) (list "s1" ME '((tolerance . 0.5))))

(with-vat vat ($ session2 'chat-post "s1" "topic" "hello"))
(check "no message-kind given: the slot is #f, the planner's own default (text) applies"
       (last-planner-call) (list "s1" "topic" ME "hello" #f))
(with-vat vat ($ session2 'chat-post "s1" "topic" "hello" "system"))
(check "message-kind given: it reaches the planner intact"
       (last-planner-call) (list "s1" "topic" ME "hello" "system"))

(display "\n── declare-need/-means/-place: plain named passthrough ──\n")
;; unlike open/cast-signed above, these three have no translation logic left
;; at all — the session arm just forwards every named optional to the
;; planner in the same order it declares them. Worth pinning anyway: it is
;; still a real arity a caller depends on, and it USED to be an opaque
;; `apply … opts` splice.
(with-vat vat
  ($ session2 'declare-place "c1" "The Barn" 1.0 2.0 "1 Field Rd"))
(check "declare-place: address reaches the planner in its own slot, no parent being none"
       (last-planner-call) (list "c1" ME "The Barn" 1.0 2.0 "1 Field Rd" #f))
(with-vat vat
  ($ session2 'declare-place "c1" "Shelf 1" 0 0 "" "place:site/pantry"))
(check "declare-place: the place it is inside reaches the planner in its own slot"
       (last-planner-call) (list "c1" ME "Shelf 1" 0 0 "" "place:site/pantry"))
(with-vat vat
  ($ session2 'declare-means "c1" "lathe" 1 %effort-unit "town" "" "note" "🛠️" "n" "[]" "{}"))
(check "declare-means: all six optionals reach the planner in their own slots"
       (last-planner-call) (list "c1" ME "lathe" 1 %effort-unit "town" "" "note" "🛠️" "n" "[]" "{}"))
(with-vat vat
  ($ session2 'declare-need "c1" "spec" 1 "kg" "town" "" "" "" "" "" "n" "[]" "{}" "des" 3))
(check "declare-need: all five optionals reach the planner in their own slots"
       (last-planner-call) (list "c1" ME "spec" 1 "kg" "town" "" "" "" "" "" "n" "[]" "{}" "des" 3))

(test-summary!)
