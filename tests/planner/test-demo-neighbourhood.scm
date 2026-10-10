;;; test-demo-neighbourhood.scm — the demo neighbourhood, standing in a real scope.
;;;
;;; The neighbourhood (planner/knowledge/worlds/demo-neighbourhood.scm) is a world and
;;; a list of acts played through the real doors; the page's offline demo is a
;;; recording of it. What this pins, as properties of whatever the tables hold:
;;;
;;;   • every act is answered ok;
;;;   • every place a stock is at, and every container it sits in, is of the world;
;;;   • every place inside another names a place of the world, and every venue a place;
;;;   • a counted stock reads its latest count, and its history is newest first;
;;;   • each need and offer is of a good and a person of the world and stands at
;;;     a place of it;
;;;   • a contest is open on a count, and stands to the demo's person as theirs
;;;     to answer or theirs to vote on;
;;;   • the preset seeds the same world, accounted to the scope that adopts it.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/planner/test-demo-neighbourhood.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules (playnet test harness))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists
(use-modules (playnet vf schemas) (srfi srfi-1)
             (playnet knowledge dsl world)
             (playnet knowledge worlds presets)
             (playnet knowledge worlds demo-neighbourhood)
             (playnet doors demo-stage)
             (srfi srfi-1))

(define today (current-time))
(define stage (stage-demo today))
(define (call . a) (plain-reply (apply (assq-ref stage 'planner) a)))
(define (gov . a) (plain-reply (apply (assq-ref stage 'governance) a)))
(define (ok? r) (and (pair? r) (eq? 'ok (car r))))

(display "\n── the acts ──\n")
(check "every act is answered ok"
       (filter (lambda (r) (not (ok? r))) (assq-ref stage 'replies)) '())

(display "\n── the world holds together ──\n")
(define places (map spatial-thing-id (world-spatials demo-world)))
(define stocks (world-resources demo-world))
(define stock-ids (map economic-resource-id stocks))
(check "every stock is at a place of the world"
       (filter (lambda (r) (not (member (economic-resource-current-location r) places))) stocks) '())
(check "every stock inside another sits in a stock of the world"
       (filter (lambda (r) (let ((in (economic-resource-contained-in r)))
                             (and in (not (member in stock-ids)))))
               stocks)
       '())
(check "every place inside another is inside a place of the world"
       (filter (lambda (p) (let ((in (spatial-thing-contained-in p)))
                             (and in (not (member in places)))))
               (world-spatials demo-world))
       '())
(define face (demo-face))
(check "every venue is at a place of the world"
       (filter (lambda (v) (not (member (assoc-ref v "place") places)))
               (vector->list (assoc-ref face "venues")))
       '())
(check "every place and every stock has its emoji"
       (list (lset-difference equal? places (map car (assoc-ref face "places")))
             (lset-difference equal? stock-ids (map car (assoc-ref face "stocks"))))
       '(() ()))

(display "\n── the books read the counts ──\n")
(define snap (call 'scope-snapshot %demo-scope #f %demo-you))
(define held (assq-ref (assq-ref snap 'inventory) 'resources))
(define (onhand id) (assq-ref (find (lambda (r) (equal? id (assq-ref r 'id))) held) 'onhand))
(define counted
  (delete-duplicates (filter-map (lambda (a) (and (eq? 'count (car a)) (third a))) demo-acts)))
(define (latest-count stock)
  (fourth (last (filter (lambda (a) (and (eq? 'count (car a)) (equal? stock (third a)))) demo-acts))))
(check "the snapshot holds every stock" (lset-difference equal? stock-ids (map (lambda (r) (assq-ref r 'id)) held)) '())
(check "a counted stock reads its latest count"
       (filter (lambda (s) (not (= (onhand s) (latest-count s)))) counted) '())
(define (history stock) (assq-ref (cdr (call 'count-history %demo-scope %demo-you stock)) 'rows))
(check "a stock's history holds each of its counts"
       (filter (lambda (s)
                 (not (= (length (history s))
                         (count (lambda (a) (and (eq? 'count (car a)) (equal? s (third a)))) demo-acts))))
               counted)
       '())
(check "…newest first"
       (filter (lambda (s) (let ((at (map (lambda (r) (assq-ref r 'at)) (history s))))
                             (not (equal? at (sort at string>?)))))
               counted)
       '())
(check-pred "the schedule lists a stock never counted"
            (any (lambda (r) (equal? "" (assq-ref r 'last-count)))
                 (assq-ref (cdr (call 'count-schedule %demo-scope)) 'rows)))

(display "\n── the contests ──\n")
(define open (assq-ref (cdr (gov 'contests %demo-you %demo-scope)) 'rows))
(check "each contest act stands open"
       (length open) (count (lambda (a) (eq? 'contest (car a))) demo-acts))
(check "one is the person's own count, to answer with a picture; one is theirs to vote on"
       (sort (map (lambda (c) (assq-ref c 'role)) open) string<?)
       '("attach" "vote"))
(check "each names a stock of the world"
       (filter (lambda (c) (not (member (assq-ref c 'resource) stock-ids))) open) '())

(display "\n── what people ask for and offer ──\n")
(define slot-acts (filter (lambda (a) (memq (car a) '(need offer))) demo-acts))
(define specs (map resource-specification-id (world-specs demo-world)))
(define people (map agent-id (world-agents demo-world)))
(check "every slot is of a good the world names" (filter (lambda (a) (not (member (third a) specs))) slot-acts) '())
(check "…and a person's of the world" (filter (lambda (a) (not (member (second a) people))) slot-acts) '())
(define mine (cdr (call 'my-slots %demo-scope %demo-you)))
(check "the person reads their own needs and offers back"
       (list (length (assq-ref mine 'needs)) (length (assq-ref mine 'means)))
       (list (count (lambda (a) (and (eq? 'need (car a)) (equal? %demo-you (second a)))) slot-acts)
             (count (lambda (a) (and (eq? 'offer (car a)) (equal? %demo-you (second a)))) slot-acts)))
(define pool
  (append-map (lambda (who)
                (let ((own (cdr (call 'my-slots %demo-scope who))))
                  (append (assq-ref own 'needs) (assq-ref own 'means))))
              people))
(check "everyone's own slots are every need and every offer" (length pool) (length slot-acts))
(check "every slot stands at a place of the world"
       (filter (lambda (s) (not (member (assq-ref s 'where) places))) pool) '())

(display "\n── the preset ──\n")
(check-pred "the neighbourhood is a preset" (preset-ref "neighbourhood"))
(check "a scope that adopts it is accountable for the commons' stocks"
       (delete-duplicates
        (filter (lambda (who) (not (member who (map agent-id (world-agents demo-world)))))
                (map economic-resource-primary-accountable
                     (world-resources (preset-ref "neighbourhood" "E_adopter")))))
       '("E_adopter"))

(test-summary!)
