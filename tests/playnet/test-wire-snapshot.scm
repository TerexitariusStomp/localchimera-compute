;;; test-wire-snapshot.scm — a scope's answers, as the page reads them.
;;;
;;; The page's spine (hoot/day-boot.scm) and the demo recorder shape a snapshot
;;; and the read doors' replies through (playnet wire snapshot) and (playnet
;;; wire replies). What this pins, over a real ^planner-service:
;;;
;;;   • the snapshot object carries each arm the page ingests, and it is JSON;
;;;   • a place rides with its coordinates and its container;
;;;   • a stock rides with its figure, its place and what it sits in;
;;;   • a count's reply carries its figure's difference, the ledger after and
;;;     how it stands beside a later count;
;;;   • a row of the history carries the figure found and its ballot;
;;;   • a door the wire does not know is refused.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/playnet/test-wire-snapshot.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules (playnet test harness))
(use-modules (goblins)
             (goblins utils hashmap)
             (playnet planner scope root) (srfi srfi-1)
             (playnet planner doors service)
             (playnet planner knowledge dsl world)
             (playnet planner knowledge dsl shorthand)
             (playnet wire rows)
             (playnet wire snapshot)
             (playnet wire replies)
             ((playnet utils json-portable) #:select (scm->json-canonical json-read-ordered))
             (srfi srfi-1))

(define vat (spawn-vat #:name "wire"))
(define root (with-vat vat (spawn-scope-root "Hood")))
(define svc (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "org:hood" root))))
(define (call method . args) (with-vat vat (apply $ svc method args)))

(with-vat vat
  (seed-world! root
    (world #:specs (list (spec* "spec-bread" "Bread" "loaf"))
           #:spatials (list (place* "place:hall" #:lat 0.01 #:lon 0.02 #:name "Hall")
                            (place* "place:pantry" #:parent "place:hall" #:name "Pantry"))
           #:agents (list (person* "you" #:place "place:hall" #:name "You"))
           #:resources (list (er "bin" "spec-bread" "org:hood" #:place "place:pantry"
                                 #:qty 1.0 #:unit "each" #:name "Bread bin")
                             (er "bread" "spec-bread" "org:hood" #:place "place:pantry"
                                 #:qty 12.0 #:unit "loaf" #:name "Bread"
                                 #:contained-in "bin")))))

(define (wire-of snap)
  snap)   ; the door answers the page's rows already
(define (ref al k) (let ((p (assoc k al))) (and p (cdr p))))
(define (row-of rows id)
  (find (lambda (r) (equal? (ref r "id") id)) (vector->list rows)))

(display "\n── the snapshot ──\n")
(define wire (wire-of (call 'scope-snapshot "org:hood" #f "you")))
(check "each arm the page ingests is there"
       (map car wire)
       (quote ("commitments" "intents" "proposals" "recipes" "plan" "matter" "inventory" "credit" "fragility" "locations" "events" "scopeId" "scopeName" "members" "plans" "alerts" "floors")))

(check-pred "it is JSON the page can read back"
            (pair? (json-read-ordered (scm->json-canonical wire))))

(define hall   (row-of (ref wire "locations") "place:hall"))
(define pantry (row-of (ref wire "locations") "place:pantry"))
(check "a place carries its coordinates" (list (ref hall "lat") (ref hall "lng")) '(0.01 0.02))
(check "…and what it is inside" (ref pantry "containedIn") "place:hall")

(define bread (row-of (ref (ref wire "inventory") "resources") "bread"))
(check "a stock carries its figure" (ref bread "onhand") 12.0)
(check "…its unit, its place and what it sits in"
       (list (ref bread "unit") (ref bread "location") (ref bread "contained-in"))
       '("loaf" "place:pantry" "bin"))
(check "a stock no plan bears on carries no range" (ref bread "expected") #f)

(display "\n── a count, and the history it leaves ──\n")
(define counted (call 'count-stock "org:hood" "you" "bread" 10.0 "loaf" "stated"
                      "place:pantry" "2026-01-05T09:00:00Z" "" "" ""))
(define reply (cdr counted))
(check "the reply carries the difference and the ledger after"
       (list (ref reply "delta") (ref reply "onhand")) '(-2.0 10.0))
(check "…and how it stands beside a later count" (ref reply "sighting") "")
(check-pred "…and its event" (positive? (string-length (ref reply "event"))))

(define hist (ref (cdr (call 'count-history "org:hood" "you" "bread")) "rows"))
(define h (vector-ref hist 0))
(check "a row of the history carries the figure found" (ref h "counted") 10.0)
(check "…the difference, the unit and whose it is"
       (list (ref h "delta") (ref h "unit") (ref h "mine")) '(-2.0 "loaf" #t))
(check "…and the ballot a contest of it is" (ref h "ballot") (string-append "contest:" (ref h "id")))

(define after (wire-of (call 'scope-snapshot "org:hood" #f "you")))
(check "the snapshot reads the count"
       (ref (row-of (ref (ref after "inventory") "resources") "bread") "onhand") 10.0)
(check-pred "…and the lived layer holds it"
            (row-of (ref after "events") (ref reply "event")))

(display "\n── a reply in the page's own words ──\n")
(check "an alist is an object under its keys' names, a list an array"
       (plain->wire '((source . "s") (controls ((spec . "co2") (s . 0.5) (kind . soft))) (people)))
       `(("source" . "s") ("controls" . ,(vector '(("spec" . "co2") ("s" . 0.5) ("kind" . "soft")))) ("people" . ,(vector))))
(check "a number that is no number is null" (plain->wire (list (/ 0. 0.) 1.5)) (vector 'null 1.5))

(display "\n── a door the wire does not know ──\n")
(check-pred "is refused"
            (catch #t (lambda () (reply->wire 'no-such-door '()) #f) (lambda _ #t)))

(test-summary!)
