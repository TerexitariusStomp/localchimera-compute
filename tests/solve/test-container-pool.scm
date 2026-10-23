;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-container-pool.scm — a line's seats are boardable anywhere on it, once.
;;;
;;; A network is not at a station; it runs THROUGH them. Held at one station, its
;;; seats used to fail in both directions at the same time: rides from that station
;;; were bounded, and rides from every OTHER station drew a `Svc|` pool with no bound
;;; at all — because `svc-held?` asks per SPEC rather than per cell, so a scope that
;;; holds a network anywhere skips the ≥0 balance everywhere. planner.scm recorded
;;; that as a deliberate trade-off: a per-cell rule would read "no seats at B" as "no
;;; such network", which collapses ordinary transit rather than catching anything.
;;;
;;; Containment dissolves the trade-off. The seats sit in a train, the train stands on
;;; the LINE, and the line is a SpatialThing that contains its stations — so the seats
;;; resolve to the line (`resource-place`) and their service becomes ONE POOL over
;;; every station under it (`ingest-stock!`). Boardable anywhere on the line, bounded
;;; in total, and absent from a place the line does not reach.
;;;
;;; Three properties, and the middle one is the whole point:
;;;   • present at every station on the line
;;;   • bounded ACROSS them together, not that much at each
;;;   • absent where the line does not go — a bound, not a licence
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-container-pool.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve ingest) (playnet solve world)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 0.001))

;;; The city: a LINE containing two stations, and one place off the line.
(define (place id parent) (place* id #:name id #:lat 52.5 #:lon 13.4 #:parent parent))
(define city
  (list (place "u2" #f)                 ; the line — a container
        (place "alex" "u2")             ; …with two stations under it
        (place "kotti" "u2")
        (place "offline" #f)))          ; somewhere the line does not reach

(define (res id spec qty unit at inside)
  (er id spec #f #:place at #:qty qty #:unit unit #:contained-in inside))

;; seats ⊂ train, train ON THE LINE
(define train (res "train" "train" 1.0 %count-unit "u2" #f))
(define seats (res "seats" "seat" 240.0 "hours/day" #f "train"))

(define (tpl spec)
  (list (string-append "p-" spec) '(("thing" . 1.0))
        (list (cons (string-append "Svc|" spec) 1.0)) 0.0 '() '() '() '() '()))

(define (ingest! holdings)
  (declare-world! #:places '("alex" "kotti" "offline" "u2")
                  #:spans '((0 "2026-03-03" "2026-03-03"))
                  #:templates (list (tpl "seat"))
                  #:spatial-things city)
  (ingest-stock! holdings)
  (adopt-container-pools! '())
  (build-columns))

(format #t "~%── 1. the seats become a POOL, not a cap ──~%~%")

(ingest! (list train seats))
(define pool (find (lambda (b) (string-prefix? "cp|" (car b))) *supplier-bundles*))

(check "no per-cell cap was written for the seats"
       (= 0 (hash-fold (lambda (k v a) (if (string-prefix? "Svc|seat" k) (+ a 1) a)) 0 *cap*)))
(check "one pool exists instead"
       (and pool #t))
(format #t "    pool budget ~a over ~a cell(s)~%"
        (and pool (cadr pool)) (and pool (length (cadddr pool))))
(check "its budget is the seats' capacity for the day — 240 hours/day over 24 h"
       (and pool (near? 240.0 (cadr pool))))

(format #t "~%── 2. present on the line, absent off it ──~%~%")

(define pool-cells (and pool (map cadr (cadddr pool))))
(check "the draws sit at every place under the line, and at the line itself"
       (and pool-cells
            (equal? (list (cell "alex" 0) (cell "kotti" 0) (cell "u2" 0))
                    (sort pool-cells string<?))))
(check "and NOT at the place the line does not reach"
       (and pool-cells (not (member (cell "offline" 0) pool-cells))))

;;; The bound is a bound. With no *cap* entry for `Svc|seat`, the pool is the only
;;; thing that supplies it — so off the line the good must balance against no supply
;;; at all, which is the fail-closed reading rather than a free draw.
(check "off the line the service is unsupplied, not free"
       (not (svc-held? (svc-good "seat"))))

(format #t "~%── 3. one budget, shared across the stations ──~%~%")

;; Each station gets its own supply COLUMN — a seat is boarded somewhere — but every
;; column draws on the one budget, so seats spent at Alex are gone at Kotti.
(check "each reachable cell has its own supply column"
       (and pool-cells (= 3 (length pool-cells))))
(check "…all of them drawing ONE budget"
       (and pool (= 1 (length (filter (lambda (b) (string-prefix? "cp|" (car b)))
                                      *supplier-bundles*)))))

;;; A holding at an ORDINARY place keeps the per-cell reading — nothing about the
;;; common case changes, and that is what makes this a strictly added capability.
(format #t "~%── 4. an ordinary place is unchanged ──~%~%")
(ingest! (list (res "bench" "seat" 240.0 "hours/day" "offline" #f)))
(check "a means at a place containing nothing is a plain per-cell cap"
       (and (near? 240.0 (hash-ref *cap* (lg (svc-good "seat") (cell "offline" 0)) 0.0))
            (null? (filter (lambda (b) (string-prefix? "cp|" (car b))) *supplier-bundles*))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a line's seats are boardable anywhere on it,~%  bounded across it, and absent where it does not run.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
