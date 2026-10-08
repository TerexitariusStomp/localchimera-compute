;;; test-conform.scm — (playnet ai conform): the one ask-for-a-shape door.
;;;
;;; What it holds, with lambdas standing in for the gateway:
;;;   FIRST TRY     a conforming reply returns at once, one call
;;;   HEALING       a non-conforming reply is re-asked WITH the reason and the
;;;                 previous output quoted back; a model that reads them conforms
;;;   BUDGET        retries bound the calls; the floor ships when they run out
;;;   SALVAGE       the floor sees the LAST readable candidate (drop-the-bad style)
;;;   UNREADABLE    prose with no structure is a reason too, never a crash
;;;   TRANSPORT     an erroring completer goes to the floor with NO retry
;;;   READERS       first S-expression / first {…} out of prose and fences
;;;
;;; Run: guile -L module tests/planner/test-conform.scm

(use-modules (playnet test harness) (playnet ai conform) (srfi srfi-1) (srfi srfi-13))

;; the shape under test: an alist with kind ∈ (a b) and a string name
(define (read-rec raw) (let ((v (read-first-sexp raw))) (and (list? v) v)))
(define (check-rec r)
  (cond ((not (memq (assq-ref r 'kind) '(a b))) "kind must be a or b")
        ((not (string? (assq-ref r 'name)))    "name must be a string")
        (else #f)))
(define (floor-dry _) 'floor)

;; a completer that counts calls and records the prompts it saw
(define (scripted . replies)
  (let ((seen '()) (left replies))
    (values (lambda (prompt)
              (set! seen (cons prompt seen))
              (let ((r (car left))) (set! left (if (null? (cdr left)) left (cdr left))) r))
            (lambda () (reverse seen)))))

;;; ─── first try ────────────────────────────────────────────────────────────
(display "\n── a conforming reply returns at once ──\n")
(define-values (c1 seen1) (scripted "Sure: ((kind . a) (name . \"x\"))"))
(check "the candidate comes back" (conform c1 "ask" #:read read-rec #:check check-rec #:floor floor-dry)
       '((kind . a) (name . "x")))
(check "one call" (length (seen1)) 1)

;;; ─── healing ──────────────────────────────────────────────────────────────
(display "\n── a re-ask carries the reason and the previous output ──\n")
(define-values (c2 seen2) (scripted "((kind . zzz) (name . \"x\"))" "((kind . b) (name . \"x\"))"))
(check "the second reply conforms" (conform c2 "ask" #:read read-rec #:check check-rec #:floor floor-dry)
       '((kind . b) (name . "x")))
(check "two calls" (length (seen2)) 2)
(define heal (cadr (seen2)))
(check-pred "the re-ask quotes the reason" (string-contains heal "kind must be a or b"))
(check-pred "…and the previous output" (string-contains heal "(kind . zzz)"))
(check-pred "…and the original request" (string-contains heal "Original request:\nask"))

;;; ─── budget + salvage ─────────────────────────────────────────────────────
(display "\n── retries bound the calls; the floor sees the last candidate ──\n")
(define-values (c3 seen3) (scripted "((kind . zzz) (name . \"x\"))"))
(check "retries 0 ⇒ one call, floor" (conform c3 "ask" #:read read-rec #:check check-rec #:floor floor-dry #:retries 0) 'floor)
(check "…exactly one call" (length (seen3)) 1)
(define-values (c4 seen4) (scripted "((kind . zzz) (name . \"x\"))"))
(check "retries 2 ⇒ three calls, then the floor" (conform c4 "ask" #:read read-rec #:check check-rec #:floor floor-dry #:retries 2) 'floor)
(check "…exactly three calls" (length (seen4)) 3)
(define-values (c5 seen5) (scripted "((kind . zzz) (name . \"x\"))"))
(check "the floor receives the last readable candidate (salvage)"
       (conform c5 "ask" #:read read-rec #:check check-rec #:retries 0
                #:floor (lambda (last) (assq-ref last 'name)))
       "x")

;;; ─── unreadable ───────────────────────────────────────────────────────────
(display "\n── prose with nothing readable is a reason, not a crash ──\n")
(define-values (c6 seen6) (scripted "I'm sorry, I can't help with that."))
(check "unreadable ⇒ floor with #f" (conform c6 "ask" #:read read-rec #:check check-rec #:retries 1
                                            #:floor (lambda (last) (list 'floor last)))
       '(floor #f))
(check-pred "…the re-ask says so" (string-contains (cadr (seen6)) "nothing readable"))
(define-values (c7 seen7) (scripted "I'm sorry." "((kind . a) (name . \"late\"))"))
(check "an unreadable first reply can still heal" (conform c7 "ask" #:read read-rec #:check check-rec #:floor floor-dry)
       '((kind . a) (name . "late")))

;;; ─── transport ────────────────────────────────────────────────────────────
(display "\n── an erroring completer floors at once, no retry ──\n")
(define calls 0)
(define (erroring p) (set! calls (+ calls 1)) (error "gateway down"))
(check "error ⇒ floor" (conform erroring "ask" #:read read-rec #:check check-rec #:floor floor-dry #:retries 3) 'floor)
(check "…one call only" calls 1)
(check-pred "a missing floor is a design error, refused up front"
            (catch #t (lambda () (conform c1 "ask" #:read read-rec #:check check-rec) #f) (lambda _ #t)))

;;; ─── readers ──────────────────────────────────────────────────────────────
(display "\n── the readers strip prose and fences ──\n")
(check "first sexp behind prose" (read-first-sexp "Here you go:\n```scheme\n(a b)\n```") '(a b))
(check "no paren ⇒ #f" (read-first-sexp "nope") #f)
(check "unbalanced ⇒ #f" (read-first-sexp "(a b") #f)
(check "non-text ⇒ #f" (read-first-sexp #f) #f)
(check "first {…} object, outermost braces, parsed" (read-first-json-object "ok: {\"a\":{\"b\":1}} done") '(("a" . (("b" . 1)))))
(check "no braces ⇒ #f" (read-first-json-object "{") #f)
(check "two joined objects do not parse ⇒ #f" (read-first-json-object "{\"a\":1} and {\"b\":2}") #f)
(check "accept maps a conforming candidate"
       (conform c1 "ask" #:read read-rec #:check check-rec #:floor floor-dry
                #:accept (lambda (r) (assq-ref r 'name)))
       "x")

(display "\n")
(test-summary!)
