;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-observer-corrections.scm — corrections are events, and the fold stays a sum.
;;;
;;; ValueFlows (concepts/accounting.md, examples/ex-production.md "Correcting
;;; errors"): a recorded event is never changed. A correction is another event of
;;; the SAME action on the SAME resource and process, with a SIGNED quantity (the
;;; amount to add or subtract) and a `corrects` link. A consume of 3 is backed out
;;; by a consume of -3; a work of 7 hours adjusted by a work of -1. The original
;;; stays; the net effect is the sum. The observer applies a correction exactly as
;;; it applies any event, so the state is a function of the SET of events: the
;;; order they arrive in, and whether the original or its correction arrives first,
;;; cannot matter.
;;;
;;; Older logs hold the previous reading (a correction REPLACES its original: a
;;; restated quantity, or no quantity for a void). `legacy-corrections->canonical`
;;; turns such a list into the ValueFlows form once, at the replay seam: a void
;;; becomes the full back-out, a restatement becomes the back-out plus the restated
;;; event.
;;;
;;; A container counted in units takes the same SHARE of its contents when units
;;; are consumed (the containment cascade). A draw beyond what the container held
;;; takes all of them and never more, and a container with nothing on hand has no
;;; share to take.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/observation/test-observer-corrections.scm

(use-modules (playnet test harness)
             ((playnet utils clock) #:select (civil->instant))
             (playnet test events)
             (playnet observation observer) (playnet vf schemas) (srfi srfi-1)
             (playnet observation observer)
             (goblins utils hashmap)
             (srfi srfi-1))

(define (ids st) (sort (map economic-event-id (os-events st)) string<?))

(define (stock) (list (ev "open" 'raise #:rid "ply" #:spec "plywood" #:q 100.0 #:unit "one")))

;; ── the spec's own example ───────────────────────────────────────────────────
(display "\n── ex-production.md: a consume of 3 is backed out and re-entered as 5 ──\n")
(let* ((events (append (stock)
                       (list (ev "c3"  'consume #:rid "ply" #:spec "plywood" #:q 3.0 #:unit "one" #:input "P")
                             (ev "c3x" 'consume #:rid "ply" #:spec "plywood" #:q -3.0 #:unit "one" #:input "P" #:corrects "c3")
                             (ev "c5"  'consume #:rid "ply" #:spec "plywood" #:q 5.0 #:unit "one" #:input "P"))))
       (st (fold-events events)))
  (check "the net effect is the sum: 100 - 3 + 3 - 5 = 95"   (near? (onhand st "ply") 95.0) #t)
  (check "the original stays in the log, beside its correction" (and (member "c3" (ids st)) (member "c3x" (ids st)) #t) #t)
  (check "the log holds all four events"                      (length (os-events st)) 4))

(display "\n── a work of 7 hours adjusted by -1 ──\n")
(let* ((st (fold-events (list (ev "w7"  'work #:effort '(7.0 . "hour") #:input "P")
                              (ev "w-1" 'work #:effort '(-1.0 . "hour") #:input "P" #:corrects "w7"))))
       (hours (fold (lambda (e a) (+ a (measure-has-numerical-value (economic-event-effort-quantity e))))
                    0 (events-with-action st 'work))))
  (check "the work fold sums to 6 hours" (near? hours 6.0) #t))

;; ── order cannot matter ──────────────────────────────────────────────────────
(display "\n── the state is a function of the set of events ──\n")
(let* ((o  (ev "c3"  'consume #:rid "ply" #:spec "plywood" #:q 3.0 #:unit "one" #:input "P"))
       (cx (ev "c3x" 'consume #:rid "ply" #:spec "plywood" #:q -3.0 #:unit "one" #:input "P" #:corrects "c3"))
       (a  (fold-events (append (stock) (list o cx))))
       (b  (fold-events (append (stock) (list cx o)))))
  (check "a correction recorded before its original lands on the same stock" (near? (onhand b "ply") (onhand a "ply")) #t)
  (check "…the stock the two events net to: 100"                              (near? (onhand b "ply") 100.0) #t))

(display "\n── idempotent ──\n")
(let* ((cx (ev "c3x" 'consume #:rid "ply" #:spec "plywood" #:q -3.0 #:unit "one" #:input "P" #:corrects "c3"))
       (st (fold-events (append (stock)
                                (list (ev "c3" 'consume #:rid "ply" #:spec "plywood" #:q 3.0 #:unit "one" #:input "P") cx cx)))))
  (check "the same correction delivered twice counts once" (near? (onhand st "ply") 100.0) #t))

;; ── the implied custody transfer is corrected like any event ────────────────
(display "\n── a back-out undoes an implied custody transfer ──\n")
(let* ((open (list (ev "oa" 'raise #:rid "A" #:spec "apples" #:q 100.0 #:receiver "alice")))
       (pk   (ev "pk" 'pickup #:rid "A" #:to-rid "C" #:spec "apples" #:q 30.0 #:input "P" #:provider "alice" #:receiver "claudia"))
       (bo   (ev "pkx" 'pickup #:rid "A" #:to-rid "C" #:spec "apples" #:q -30.0 #:input "P" #:provider "alice" #:receiver "claudia" #:corrects "pk"))
       (before (fold-events open))
       (after  (fold-events (append open (list pk bo)))))
  (check "after the pickup and its back-out, A holds what it held before" (near? (onhand after "A") (onhand before "A")) #t)
  (check "…and the carrier's resource nets to what it held before"
         (near? (or (onhand after "C") 0.0) 0.0) #t))

;; ── legacy logs: a correction that REPLACES its original ───────────────────
(display "\n── the replay seam: older corrections become signed events ──\n")
(let* ((o   (ev "o"  'consume #:rid "ply" #:spec "plywood" #:q 10.0 #:unit "one" #:input "P"))
       (rs  (ev "rs" 'consume #:rid "ply" #:spec "plywood" #:q 4.0 #:unit "one" #:input "P" #:corrects "o"))   ; restated to 4
       (o2  (ev "o2" 'consume #:rid "ply" #:spec "plywood" #:q 5.0 #:unit "one" #:input "P"))
       (vd  (ev "vd" 'consume #:rid "ply" #:spec "plywood" #:input "P" #:corrects "o2"))                      ; a void: no quantity
       (legacy (append (stock) (list o rs o2 vd)))
       (canon  (legacy-corrections->canonical legacy))
       (st     (fold-events canon)))
  (check "a restatement to 4 and a void leave 100 - 4 = 96" (near? (onhand st "ply") 96.0) #t)
  (check "the original events are still in the list"
         (and (member "o" (map economic-event-id canon)) (member "o2" (map economic-event-id canon)) #t) #t)
  (check "no event of the canonical list replaces another: every correction is signed"
         (every (lambda (e)
                  (or (not (economic-event-corrects e))
                      (let ((m (economic-event-resource-quantity e)))
                        (and m (< (measure-has-numerical-value m) 0)))))
                canon) #t)
  (check "a log already in the canonical form is returned as it stands"
         (equal? (map economic-event-id (legacy-corrections->canonical canon)) (map economic-event-id canon)) #t))

;; A correction that ADDS is as canonical as one that subtracts (accounting.md: "the
;; amount to add or subtract"): a consume of 3 adjusted by a consume of +2 is 5.
;; Reading a snapshot back keeps every canonical event as it stands; only a snapshot
;; written before this reading (it carries no registered join terms) is converted.
(display "\n── a canonical correction that adds survives a snapshot ──\n")
(let* ((st  (fold-events (append (stock)
                                 (list (ev "c3"  'consume #:rid "ply" #:spec "plywood" #:q 3.0 #:unit "one" #:input "P")
                                       (ev "c3p" 'consume #:rid "ply" #:spec "plywood" #:q 2.0 #:unit "one" #:input "P" #:corrects "c3")))))
       (st2 (deserialize-observer-state (serialize-observer-state st)))
       (net (lambda (s) (let ((e (standing-event s "c3"))) (and e (measure-has-numerical-value (economic-event-resource-quantity e)))))))
  (check "live: the consume stands at 3 + 2 = 5"            (net st)  5.0)
  (check "after a snapshot round-trip it still stands at 5" (net st2) 5.0)
  (check "…and the stock it left is unchanged: 100 - 5"     (list (onhand st "ply") (onhand st2 "ply")) '(95.0 95.0))
  (check "the log holds the same events"                    (ids st2) (ids st)))

(display "\n── a snapshot from before the reading is converted once ──\n")
(let* ((legacy (fold-events (append (stock)
                                    (list (ev "o" 'consume #:rid "ply" #:spec "plywood" #:q 10.0 #:unit "one" #:input "P")
                                          (ev "rs" 'consume #:rid "ply" #:spec "plywood" #:q 4.0 #:unit "one" #:input "P" #:corrects "o")))))
       (old    (positional-snapshot legacy #:slots 5))          ; the shape written before the terms and process slots
       (st     (deserialize-observer-state old))
       (e      (standing-event st "rs")))
  (check "the restatement to 4 stands as the 4, the original backed out"
         (list (and e (measure-has-numerical-value (economic-event-resource-quantity e)))
               (standing-event st "o"))
         '(4.0 #f))
  (check "…and a second load of the converted snapshot leaves it as it is"
         (ids (deserialize-observer-state (serialize-observer-state st))) (ids st)))

;; ── the containment cascade takes shares, never more ────────────────────────
(display "\n── a container's units drawn take the same share of its contents ──\n")
(define* (contents-world #:key (box 4.0))
  (fold-events (list (ev "ob" 'raise #:rid "box" #:spec "case" #:q box #:unit "one")
                     (ev "oi" 'raise #:rid "i1" #:spec "jar" #:q 10.0 #:unit "one")
                     (ev "oc" 'combine #:rid "i1" #:to-rid "box" #:spec "jar" #:q 0.0 #:unit "one" #:input "P"))))   ; containment only
(let* ((w  (contents-world))
       (st (cdr (let ((r (call-with-values (lambda () (observer-record-event w (ev "d1" 'consume #:rid "box" #:spec "case" #:q 1.0 #:unit "one" #:input "P")))
                           (lambda (s _) (cons 'ok s)))))
                  r))))
  (check "consuming 1 of 4 takes a quarter of the contents: 10 -> 7.5" (near? (onhand st "i1") 7.5) #t))
(let* ((w  (contents-world))
       (st (call-with-values (lambda () (observer-record-event w (ev "d5" 'consume #:rid "box" #:spec "case" #:q 5.0 #:unit "one" #:input "P")))
             (lambda (s _) s))))
  (check "a draw of 5 on a container of 4 takes all of the contents, not more" (near? (onhand st "i1") 0.0) #t)
  (check "contents are never driven below zero by a container's over-draw"    (>= (onhand st "i1") 0.0) #t))
(let* ((w  (contents-world #:box 0.0))
       (st (call-with-values (lambda () (observer-record-event w (ev "d0" 'consume #:rid "box" #:spec "case" #:q 1.0 #:unit "one" #:input "P")))
             (lambda (s _) s))))
  (check "a container with nothing on hand has no share to take: contents stay" (near? (onhand st "i1") 10.0) #t))

;; the share is a share of the container's OWN unit: 500 g drawn from 4 kg is an eighth
(display "\n── the share is read in the container's unit ──\n")
(let* ((w  (fold-events (list (ev "ob" 'raise #:rid "box" #:spec "case" #:q 4.0 #:unit "kg")
                              (ev "oi" 'raise #:rid "i1" #:spec "jar" #:q 10.0 #:unit "one")
                              (ev "oc" 'combine #:rid "i1" #:to-rid "box" #:spec "jar" #:q 0.0 #:unit "one" #:input "P"))))
       (st (call-with-values (lambda () (observer-record-event w (ev "dg" 'consume #:rid "box" #:spec "case" #:q 500.0 #:unit "g" #:input "P")))
             (lambda (s _) s))))
  (check "drawing 500 g of 4 kg takes an eighth of the contents: 10 -> 8.75"
         (list (near? (onhand st "box") 3.5) (near? (onhand st "i1") 8.75)) '(#t #t)))

;; the ledger as of an instant undoes exactly what the fold did: the implied custody
;; transfer of a modify between two agents leaves the source's on-hand alone and puts
;; the goods on the carrier's resource, so that is what is taken back out
(display "\n── the ledger as of an instant follows the fold's effects ──\n")
(let* ((at  (lambda (e iso) (copy-economic-event e #:has-point-in-time iso)))
       (st  (fold-events
             (list (at (ev "r" 'raise #:rid "R" #:spec "oak" #:q 100.0 #:receiver "alice") "2026-06-12T08:00:00Z")
                   (at (ev "m" 'modify #:rid "R" #:to-rid "T" #:spec "oak" #:q 5.0 #:input "P" #:output "P"
                           #:provider "alice" #:receiver "bob") "2026-06-12T10:00:00Z"))))
       (before (civil->instant "2026-06-12T09:00:00Z")))
  (check "the fold leaves R at 100 and puts 5 on T" (list (onhand st "R") (onhand st "T")) '(100.0 5.0))
  (check "as of before the modify: R held 100, T held nothing"
         (list (near? (onhand-as-of st "R" before) 100.0) (near? (onhand-as-of st "T" before) 0.0)) '(#t #t)))

(test-summary!)
