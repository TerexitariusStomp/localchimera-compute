;;; test-page-scope.scm — a scope held in a page answers the doors a gateway answers.
;;;
;;; (playnet doors page-scope) holds a scope root and answers the page's doors
;;; over it with the planner service's own door functions. What this pins:
;;;
;;;   • the neighbourhood stands and its counts, labels, needs and offers land;
;;;   • a door answers the JSON the page reads: the snapshot's places and stock,
;;;     the schedule, a stock's counts, a spec's readings;
;;;   • a count through the door moves the books, heads the history and is read
;;;     by the reading fold;
;;;   • a refusal is the door's "err:" and its words;
;;;   • each door answers what the planner service answers of the same acts
;;;     (the stage of doors/demo-stage.scm), ids aside;
;;;   • a replica of a gateway's scope, carried as text and held here, answers
;;;     the doors as the gateway does, ids and all; a count lands on it as on the
;;;     gateway; holding the replica again is the refresh.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/planner/test-page-scope.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (goblins)
             (playnet doors page-scope)
             (playnet scope replica)
             (playnet knowledge worlds demo-neighbourhood)
             (playnet doors demo-stage)
             (playnet wire replies)
             ((playnet utils json-portable) #:select (json-read-ordered scm->json-canonical))
             (srfi srfi-1))

(define today (current-time))
(define (ref al k) (let ((p (assoc k al))) (and p (cdr p))))
(define (ask door . args) (page-door door args))
(define (read-json s) (json-read-ordered s))
(define (rows-of s) (vector->list (ref (read-json s) "rows")))

(display "\n── the neighbourhood stands ──\n")
(define acts (open-neighbourhood! today))
(define (act-kind a) (car a))
(check "every act of the neighbourhood lands, bar the contests a gateway opens"
       (filter-map (lambda (a r) (and (not (eq? 'contest (act-kind a))) (not (eq? 'ok (car r))) a))
                   demo-acts acts)
       '())

(display "\n── the doors answer what the page reads ──\n")
(define snap (read-json (ask "snapshot")))
(check-pred "the snapshot carries the places" (> (vector-length (ref snap "locations")) 40))
(define stock (vector->list (ref (ref snap "inventory") "resources")))
(define (onhand id) (ref (find (lambda (r) (equal? id (ref r "id"))) stock) "onhand"))
(check "…and the stock, reading the latest count" (onhand "demo:greens") 72.0)
(check-pred "the schedule lists the stocks" (> (length (rows-of (ask "countSchedule" ""))) 5))
(check "a stock's counts, newest first"
       (map (lambda (r) (ref r "counted")) (rows-of (ask "countHistory" "demo:greens" "")))
       '(72.0 75.0))
(check-pred "a spec's readings carry its drift"
            (> (ref (ref (read-json (ask "scopeReadings" "spec-beans")) "drift") "n") 0))
(check-pred "the label of a labelled stock is its code"
            (= 6 (string-length (ref (read-json (ask "labelStock" "demo:shelf")) "code"))))

(display "\n── a count through the door ──\n")
(define landed (read-json (ask "countStock" "demo:tea" "7" "box" "stated" "place:teahouse" "" "" "" "")))
(check "it answers the difference and the ledger after" (list (ref landed "delta") (ref landed "onhand")) '(-2.0 7.0))
(check "the books read it"
       (let ((s (vector->list (ref (ref (read-json (ask "snapshot")) "inventory") "resources"))))
         (ref (find (lambda (r) (equal? "demo:tea" (ref r "id"))) s) "onhand"))
       7.0)
(check "it heads the stock's history, as the person's own"
       (let ((h (car (rows-of (ask "countHistory" "demo:tea" "")))))
         (list (ref h "counted") (ref h "mine")))
       '(7.0 #t))
(check-pred "the reading fold reads it"
            (> (ref (ref (read-json (ask "scopeReadings" "spec-tea")) "drift") "n") 0))

(display "\n── what people ask for and offer ──\n")
(define own (read-json (ask "mySlots")))
(check "the person reads their own needs and offers"
       (list (vector-length (ref own "needs")) (vector-length (ref own "means"))) '(3 2))
(check-pred "a need declared through the door stands among them"
            (begin (ask "declareNeed" "spec-tea" "2" "box" "" "" "for the weekend" "🍵" "" "" "tea" "" "" "" "")
                   (find (lambda (n) (equal? "spec-tea" (ref n "spec")))
                         (vector->list (ref (read-json (ask "mySlots")) "needs")))))
(check "a declare answers the word the spine answers it with"
       (ask "declareMeans" "spec-tea" "3" "box" "place:home" "" "from the cupboard" "🍵" "tea to share" "" "") "ok")
(check-pred "an observation lands and answers its event"
            (string-prefix? "ok:evt-log-" (ask "logObserve" "produce" "spec-jar" "4" %count-unit "filled four jars" "")))
(check "the same observation at the same instant is the same event"
       (ask "logObserve" "work" "spec-bike-repair" "2" %effort-unit "fixed a flat" "2026-01-03T10:00:00Z")
       (ask "logObserve" "work" "spec-bike-repair" "2" %effort-unit "fixed a flat" "2026-01-03T10:00:00Z"))
(check-pred "the pool holds everyone's needs" (> (vector-length (ref (read-json (ask "slotsAt")) "needs")) 5))

(display "\n── a refusal ──\n")
(check "a count in another unit is refused in the door's words"
       (ask "countStock" "demo:tea" "3" "kg" "stated" "" "" "" "" "")
       "err:count in the stock's unit: box")
(check-pred "a count that is no number is refused" (string-prefix? "err:" (ask "countStock" "demo:tea" "" "box" "" "" "" "" "" "")))
(check-pred "a door this page does not answer says so" (string-prefix? "err:unavailable" (ask "noSuchDoor")))

(display "\n── the same answers as the planner service ──\n")
;; the same acts played on a gateway's side of things, each door asked of both
(define stage (stage-demo today))
(define call (assq-ref stage 'planner))
(define (plain rows) (map (lambda (r) (filter (lambda (p) (not (member (car p) '("id" "ballot")))) r)) rows))
(define (service-rows door . args)
  (vector->list (ref (cdr (apply call door %demo-scope args)) "rows")))
(check "a stock's counts"
       (plain (rows-of (ask "countHistory" "demo:beans" "")))
       (plain (service-rows 'count-history %demo-you "demo:beans")))
(check "the readings of a spec"
       (ref (read-json (ask "scopeReadings" "spec-veg")) "drift")
       (ref (cdr (call 'scope-readings %demo-scope "spec-veg")) "drift"))
(check "the person's own needs and offers"
       (cdr (page-call 'my-slots %demo-scope "ana"))
       (cdr (call 'my-slots %demo-scope "ana")))
(check "the stocks scheduled for a count"
       (sort (map (lambda (r) (ref r "id")) (rows-of (ask "countSchedule" ""))) string<?)
       (sort (map (lambda (r) (ref r "id")) (service-rows 'count-schedule)) string<?))

(display "\n── a copy of a gateway's scope ──\n")
;; what a gateway holds of the neighbourhood, carried as text and held here: the
;; doors then answer what the gateway's answer, ids and all
;; asked through the planner's own door, as a member's device asks it
(define text (cdr (call 'scope-replica %demo-scope %demo-you)))
(check-pred "a replica is text" (and (string? text) (> (string-length text) 1000)))
(open-replica! %demo-scope %demo-you text)
(define (service-json door . args) (scm->json-canonical (cdr (apply call door %demo-scope args))))
(check "a stock's counts, ids and all"
       (ask "countHistory" "demo:greens" "") (service-json 'count-history %demo-you "demo:greens"))
(check "the person's needs and offers"
       (ask "mySlots") (service-json 'my-slots %demo-you))
(check "the stock on the books"
       (sort (map (lambda (r) (cons (ref r "id") (ref r "onhand")))
                  (vector->list (ref (ref (read-json (ask "snapshot")) "inventory") "resources")))
             (lambda (a b) (string<? (car a) (car b))))
       (sort (map (lambda (r) (cons (assoc-ref r "id") (assoc-ref r "onhand")))
                  (vector->list (assoc-ref (assoc-ref (cdr (call 'scope-snapshot %demo-scope #f %demo-you)) "inventory") "resources")))
             (lambda (a b) (string<? (car a) (car b)))))
(check "the readings of a spec"
       (ask "scopeReadings" "spec-beans") (service-json 'scope-readings "spec-beans"))
(check "a count on the copy lands as it lands on a gateway"
       (let ((mine (read-json (ask "countStock" "demo:loaves" "100" "loaf" "stated" "place:bakery" "" "" "" "")))
             (theirs (cdr (call 'count-stock %demo-scope %demo-you "demo:loaves" 100.0 "loaf" "stated" "place:bakery" "" "" "" ""))))
         (list (ref mine "delta") (ref mine "onhand")))
       '(-4.0 100.0))
(open-replica! %demo-scope %demo-you text)
(check "holding the replica again is the refresh: the copy reads what the gateway held"
       (ref (car (rows-of (ask "countHistory" "demo:loaves" ""))) "counted") 104.0)

(test-summary!)
