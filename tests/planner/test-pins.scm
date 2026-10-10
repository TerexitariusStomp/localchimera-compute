;;; test-pins.scm — the pin book: map lists folded like the folksonomy
;;;
;;; A citizen's book is theirs; only the lists marked shared fold, and a note
;;; never does. In the fold a (list · subject) filing counts who made it, an
;;; AID re-folds by clearing its own, and merge is set-aid over by-aid.
;;;
;;; Run: guile -L module tests/planner/test-pins.scm

(use-modules (playnet test harness)
             (playnet folksonomy pins)
             (srfi srfi-1))

(define (doc lists pins) (make-pins-doc lists pins))
(define (lst id label emoji shared)
  `((id . ,id) (label . ,label) (emoji . ,emoji) (shared . ,shared)))
(define (pin l s . note)
  `((list . ,l) (subject . ,s) ,@(if (pair? note) `((note . ,(car note))) '())))

(display "\n── the public half of a book ──\n")
(define ada-book
  (doc (list (lst "list:squats" "Squats" "🏚" #t)
             (lst "list:mine" "Secret spots" "🤫" #f))
       (list (pin "list:squats" "place:1" "ring twice")
             (pin "list:squats" "spot:52.5,13.4")
             (pin "list:mine" "place:9" "don't tell"))))
(define pub (pins-doc-public ada-book))
(check "only the shared list folds" (map (lambda (l) (assq-ref l 'id)) (assq-ref pub 'lists))
       '("list:squats"))
(check "…with its pins, and not the private list's"
       (map (lambda (p) (assq-ref p 'subject)) (assq-ref pub 'pins))
       '("place:1" "spot:52.5,13.4"))
(check "a note never leaves the book"
       (any (lambda (p) (assq 'note p)) (assq-ref pub 'pins)) #f)
(check "nor the shared flag itself" (any (lambda (l) (assq 'shared l)) (assq-ref pub 'lists)) #f)

(display "\n── the fold: counts, who, re-fold, merge ──\n")
(define (set ps aid d)
  (let ((p (parse-pins-doc d)))
    (pins-set-aid ps aid (assq-ref p 'pins) (assq-ref p 'lists))))
(define ps1 (set (make-pins) "ada" pub))
(define ps2 (set ps1 "ben" (doc (list (lst "list:squats" "" "" #t))
                                (list (pin "list:squats" "place:1")
                                      (pin "list:squats" "place:2")))))
(define (subjects ps l) (sort (map pin-subject (pins-in ps l)) string<?))
(define (count-of ps l s)
  (let ((p (find (lambda (p) (equal? (pin-subject p) s)) (pins-in ps l)))) (and p (pin-count p))))
(check "two books, one list, three places" (subjects ps2 "list:squats")
       '("place:1" "place:2" "spot:52.5,13.4"))
(check "a place two people file counts twice" (count-of ps2 "list:squats" "place:1") 2)
(check "…and names both" (sort (pin-by (find (lambda (p) (equal? (pin-subject p) "place:1"))
                                             (pins-in ps2 "list:squats"))) string<?)
       '("ada" "ben"))
(let ((row (car (pins-lists-at ps2))))
  (check "the list reads its label from whoever named it" (assq-ref row 'label) "Squats")
  (check "…its places and its people" (list (assq-ref row 'places) (assq-ref row 'by)) '(3 2)))
(define ps3 (set ps2 "ada" (doc (list (lst "list:squats" "Squats" "🏚" #t))
                                (list (pin "list:squats" "place:1")))))
(check "a smaller republish drops what ada withdrew" (subjects ps3 "list:squats") '("place:1" "place:2"))
(check "…and the count follows" (count-of ps3 "list:squats" "place:1") 2)
(define ps4 (pins-drop-aid ps3 "ada"))
(check "ada gone: her filings go, ben's stand" (subjects ps4 "list:squats") '("place:1" "place:2"))
(check "…the place both filed now counts one" (count-of ps4 "list:squats" "place:1") 1)
(check "a list nobody shares any more is gone"
       (pins-lists-at (pins-drop-aid ps4 "ben")) '())
(define merged (pins-merge (set (make-pins) "ada" pub)
                           (set (make-pins) "ben" (doc (list (lst "list:squats" "" "" #t))
                                                       (list (pin "list:squats" "place:1"))))))
(check "merge = set-aid over the other side's by-aid" (count-of merged "list:squats" "place:1") 2)
(check "a merge is idempotent on an AID already folded"
       (count-of (pins-merge merged merged) "list:squats" "place:1") 2)

(display "\n")
(test-summary!)
