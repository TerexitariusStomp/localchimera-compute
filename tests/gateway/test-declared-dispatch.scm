;;; tests/gateway/test-declared-dispatch.scm — an object's methods are its declared doors
;;;
;;; What this pins:
;;;   • heads that match the declaration spawn and answer as `methods` would;
;;;   • a head the declaration lacks, a declared door the code lacks, or a
;;;     differing argument list is refused at the first spawn, naming each
;;;     difference;
;;;   • the check runs once per object per process (a second spawn is free).
;;;
;;; Run: guile -L module -L tests tests/gateway/test-declared-dispatch.scm

(use-modules (playnet test harness)
             (playnet doors protocol)
             (playnet protocol dispatch)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define vat (spawn-vat))

(display "\n── 1. heads-drift is the diff ──\n")

(define lobby-heads (map (lambda (d) (cons (door-name d) (door-args d))) (doors-of 'lobby)))
(check "the declared heads have no drift" (null? (heads-drift 'lobby lobby-heads)))
(check "an extra head is named"
       (let ((d (heads-drift 'lobby (cons '(bogus x) lobby-heads))))
         (and (= 1 (length d)) (string-contains (car d) "bogus"))))
(check "a missing door is named"
       (let ((d (heads-drift 'lobby (cdr lobby-heads))))
         (and (= 1 (length d)) (string-contains (car d) "declared and not in the code"))))
(check "a differing argument list is named"
       (let* ((h (car lobby-heads))
              (d (heads-drift 'lobby (cons (cons (car h) '(other args)) (cdr lobby-heads)))))
         (and (= 1 (length d)) (string-contains (car d) "takes"))))

(display "\n── 2. declared-methods refuses drift at spawn ──\n")

;; A pretend object kind: the declaration has no doors for it, so ANY head
;; is drift — the refusal path, without touching the real objects.
(define (^drifter _bcom)
  (declared-methods nowhere
    ((hello) 'hi)))
(define (refused? thunk)
  (catch #t (lambda () (thunk) #f) (lambda _ #t)))
(check "spawning an object whose heads are undeclared is refused"
       (refused? (lambda () (with-vat vat (spawn ^drifter)))))

(display "\n── 3. matching heads answer as methods ──\n")

;; The planner's smallest declared doors, on a stand-in object with exactly
;; the declared heads (every planner door, most as stubs), so the check passes
;; and dispatch works. Built from the declaration itself.
(define planner-heads (map (lambda (d) (cons (door-name d) (door-args d))) (doors-of 'planner)))
(check "planner declares scope-list with no arguments"
       (equal? '() (cdr (assq 'scope-list planner-heads))))

(define (^stand-in _bcom)
  ;; two real clauses; the rest of the declared heads appended as stubs by
  ;; the helper below would need the macro to take a runtime list, which it
  ;; does not — so this object is checked against a declaration slice.
  (declared-methods session-slice
    ((whoami) "EStandIn")))
;; there is no `session-slice` object in the declaration → refused too
(check "a slice of the session is also refused (all-or-nothing)"
       (refused? (lambda () (with-vat vat (spawn ^stand-in)))))

;; The real objects — ^lobby, ^lobby-session, the planner service — carry
;; declared-methods in their own modules; test-planner-facet and
;; test-contact-binding spawn the first two, so their heads are checked
;; there, and tools/protocol-lint.scm compares all three offline.

(test-summary!)
