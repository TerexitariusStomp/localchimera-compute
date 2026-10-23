;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-hold-carry.scm — the two bare shapes of transport.scm, and what a
;;; commons can do with them.
;;;
;;; `recipe-hold` and `recipe-carry` are the same pickup→dropoff pair with and
;;; without a container. Which arc the engine tiles them along is never marked on
;;; the recipe: it reads it off the container's `keep-in-place`. So one shape
;;; crosses TIME and the other crosses SPACE, and nothing else distinguishes
;;; them.
;;;
;;; Together they are enough for a thing to be left somewhere public and drawn
;;; from somewhere else the next day — which is a left-luggage office, a
;;; lending shelf, a fridge on a street corner, or a box under a bridge, and the
;;; model does not need to know which:
;;;
;;;   1. does it CARRY?    Bread left in a container on Monday is bread on
;;;      Tuesday, having paid the container's own service for the stay.
;;;   2. does it TRAVEL?   The same pair without a container walks it to where it
;;;      is wanted, paid in somebody's hours.
;;;   3. is it in the PLAN?  Only when custody of it has been granted to the
;;;      commune. Ungranted, the same bread in the same box is invisible.
;;;
;;; Nothing here passes #:storable or #:movable. Both carries come from recipes,
;;; which is the point: storability is a fact about what the commons HAS, and
;;; portability is a fact about somebody being willing to walk.
;;;
;;; Run:  guile -L module tests/solve/test-hold-carry.scm

;; The engine, then the recipe pack on top of it — the way every other test in
;; this directory loads. (Importing the (playnet boot prelude) umbrella AND
;; primitive-loading the engine works, but it is the one combination that has to
;; keep two record-type universes in step, so a test that needs neither the
;; actors nor the stores does not ask for it.)
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan) (playnet solve world)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))
;; transport.scm is a module now — use-modules, not primitive-load. A
;; define-module inside a primitive-loaded file switches current-module for
;; the REST of this file and never switches back.
(use-modules (playnet knowledge recipes transport))

(define BRIDGE "under-the-bridge")   ; where the container stands
(define SQUARE "square")             ; where the bread is wanted

;; ── a container in a public place ───────────────────────────────────────────
;; Keep-in-place is the whole declaration: using this thing to move something
;; moves it through time. A silo says it, and so does a box nobody owns the
;; ground under.
(define spec-box
  (make-resource-specification
    #:id "spec-box" #:name "Box left in a public place" #:resource-classified-as '("container")
    #:default-unit-of-resource "hours/day" #:default-unit-of-effort %effort-unit
    #:keep-in-place #t))

(define the-box
  (er "box/bridge" "spec-box" #f #:name "the box under the bridge"
      #:place BRIDGE #:qty 24.0 #:unit "hours/day"))

;; The place, with an EXTENT rather than just a point: some places are surveyed,
;; some are known as "within thirty metres of here", and both answer the same
;; question — am I standing in it.
(define bridge-site
  (make-spatial-thing #:id BRIDGE #:name "under the bridge"
                      #:note "third pillar from the north bank, behind the loose brick"
                      #:lat 52.5163 #:long 13.3777
                      ;; a real extent, as `circle-boundary` (knowledge/spatial-
                      ;; things.scm) writes for a place known only as "within
                      ;; thirty metres of here"
                      #:boundary (string-append "{\"type\":\"Polygon\",\"coordinates\":"
                                     "[[[13.37726,52.51603],[13.37814,52.51603],"
                                     "[13.37814,52.51657],[13.37726,52.51657],"
                                     "[13.37726,52.51603]]]}")))

(define spatials
  (list bridge-site
        (place* SQUARE #:name "the square" #:lat 52.5180 #:lon 13.3790)))

;; ── what Ada left there on Monday ───────────────────────────────────────────
;; An ordinary EconomicResource standing at that place. Custody is the commune's
;; once she grants it; the rights stay hers either way, which is the whole
;; difference between leaving a thing somewhere and selling it.
(define loaves
  (er "left/loaves" "bread" "ada" #:name "three loaves" #:place BRIDGE
      #:qty 3.0 #:unit "kg" #:custodian "commune"))

;; ── the two shapes ──────────────────────────────────────────────────────────
(define-values (hold-proc  hold-flows)  (recipe-hold  "bread" "spec-box" #:unit "kg"))
(define-values (carry-proc carry-flows) (recipe-carry "bread" "walking"  #:unit "kg"))

;; …and baking, so bread is a thing somebody makes rather than a free raw.
;; Nobody here holds `skill-bake`, so the only bread is the bread already left.
(define bake-proc (rp* "bake" "Bake"))
(define bake-flows
  (list (out* "b1" "bread" 1.0 "bake")
        (wk* "b2" "skill-bake" 1.0 "bake")))

(define procs (list hold-proc carry-proc bake-proc))
(define flows (append hold-flows carry-flows bake-flows))

;; ── the people ──────────────────────────────────────────────────────────────
;; Bo is AT the box on Tuesday, which is what the engine asks of a carrier: a
;; relocation arc needs somebody standing at its origin. Ada is at the square,
;; where the bread is wanted. Both can walk; neither can bake.
(define win (weekday-window "09:00" "17:00" '(monday tuesday)))
(define agents (list (person* "bo"  #:name "Bo"  #:place BRIDGE #:window win)
                     (person* "ada" #:name "Ada" #:place SQUARE #:window win)))
(define (skills-of a) '("walking"))

(define MON "2026-08-03")
(define TUE "2026-08-04")

;; Wanted at the square on the SECOND day of the horizon.
(define demand (list (cons (format #f "bread#~a@1" SQUARE) 2.0)))

;; ── reading an arc, without pinning it to a band ─────────────────────────────
;; The horizon is two DAYS; the lattice underneath it is finer. Ada and Bo are
;; available 09:00–17:00, and a declared clock boundary IS a period boundary, so
;; each day is cut into three bands and "Tuesday" is bands 3–5 rather than band
;; 1. The demand key follows that refinement on its own — `coarse->fine` re-keys
;; it onto the stretch and `*stretch*` makes the one form span all three — which
;; is exactly why a date "cannot go stale under refinement".
;;
;; A probe written as a literal `@1` does not follow it. It reads whichever
;; slice of the plan happens to land in Monday afternoon, and what lives there
;; is the barrier's residue rather than the delivery. That residue used to be
;; large enough to read as signal; at a derived path floor it is ~0.1 kg, and
;; the probe fails while the plan is right. So read an arc by its SHAPE — which
;; place-pair, wherever in the lattice the plan chose to run it — and let the
;; plan pick its own hour.
(define (cell-place c) (let ((at (string-rindex c #\@))) (if at (substring c 0 at) c)))
(define (cell-band  c) (let ((at (string-rindex c #\@)))
                         (if at (string->number (substring c (+ at 1))) 0)))
(define (band-date b) (let ((ds (period-dates b))) (and (pair? ds) (car ds))))

(define (arcs x idx proc from to)
  "Every arc column of PROC running FROM→TO, as ((from-band to-band . level) …)."
  (let ((out '()))
    (hash-for-each
     (lambda (k j)
       (let ((p (string-split k #\|)))
         (when (and (= 4 (length p)) (equal? "p" (car p)) (equal? proc (cadr p))
                    (equal? from (cell-place (caddr p)))
                    (equal? to   (cell-place (cadddr p))))
           (set! out (cons (list (cell-band (caddr p)) (cell-band (cadddr p))
                                 (vector-ref x j))
                           out)))))
     idx)
    out))

(define (total as) (fold (lambda (a s) (+ s (caddr a))) 0.0 as))
(define (on-day d as) (filter (lambda (a) (equal? d (band-date (car a)))) as))

(define (run granted?)
  ;; The commune's solve sees the box and the people either way. What Ada left is
  ;; there only when custody of it has been granted — which is exactly what
  ;; `project-socialized-custody` (economy/socialization.scm) produces from a
  ;; live custody attestation naming that resource.
  (let ((resources (if granted? (list the-box loaves) (list the-box))))
    (call-with-values
        (lambda ()
          (plan-from-records resources agents spatials procs flows
                             #:specs (list spec-box)     ; keep-in-place reaches the engine here
                             #:demand demand
                             #:horizon (cons "2026-08-03" 2)   ; Monday, then Tuesday
                             #:agent-skills skills-of
                             #:per-agent? #t #:backend 'native-c
                             #:allow-infeasible? #t))
      (lambda (i c material fill cols x idx nt rep)
        (let* ((holds (arcs x idx "rp-hold"  BRIDGE BRIDGE))
               (there (arcs x idx "rp-carry" BRIDGE SQUARE))
               (back  (arcs x idx "rp-carry" SQUARE BRIDGE))
               ;; THE TIME ARC, at the one moment that proves it is one: the
               ;; hold that carries the loaves across midnight into the day they
               ;; are wanted. A hold WITHIN a day would be a shorter claim.
               (overnight (fold max 0.0
                                (map caddr (filter (lambda (a)
                                                     (and (equal? MON (band-date (car a)))
                                                          (equal? TUE (band-date (cadr a)))))
                                                   holds))))
               ;; THE SPACE ARC, netted: a barrier leaves a little traffic in
               ;; both directions, and what reaches the square is the difference.
               ;; Read on TUESDAY — the day the bread is wanted — so the check is
               ;; that the plan walked it there in time, not merely that it walked.
               (delivered (- (total (on-day TUE there)) (total (on-day TUE back))))
               (baked (fold + 0.0 (map (lambda (b)
                                         (let ((j (hash-ref idx (format #f "p|bake|~a@~a" SQUARE b) #f)))
                                           (if j (vector-ref x j) 0.0)))
                                       *periods*))))
          (list fill overnight delivered baked))))))

(define granted (run #t))
(define private (run #f))

(format #t "~%── one pair, two arcs ──~%")
(format #t "  the place says: ~s~%" (spatial-thing-note bridge-site))
(format #t "  and knows its own extent: ~a…~%"
        (substring (spatial-thing-boundary bridge-site) 0 44))
(format #t "  2 kg of bread wanted at the square on Tuesday; nobody can bake:~%")
(format #t "    granted → ~,0f% met  ·  held overnight ~,2f kg  ·  walked ~,2f kg  ·  baked ~,2f~%"
        (* 100 (first granted)) (second granted) (third granted) (fourth granted))
(format #t "    private → ~,0f% met~%" (* 100 (first private)))

;; 1.9 rather than 2.0 on both arcs: the demand is 2 kg and an interior point
;; never sits exactly on a bound, so each arc lands a little either side of it.
;; What is being asserted is that the WHOLE want crossed each arc — not a
;; magnitude anyone tuned.
(let* ((c1 (> (first granted) 0.99))
       (c2 (> (second granted) 1.9))                  ; stayed in the box Mon→Tue
       (c3 (> (third granted) 1.9))                   ; walked box→square, on the day
       (c4 (< (fourth granted) 0.01))                 ; and none of it was baked
       (c5 (< (first private) 0.01))                  ; ungranted ⇒ invisible
       (c6 (resource-spec-keep-in-place? spec-box))
       (ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  [~a] the need is met, and only from what was left      (~,0f%)~%" (if c1 "✓" "✗") (* 100 (first granted)))
  (format #t "  [~a] HOLD: the pair through a container is a TIME arc  (~,2f kg overnight)~%" (if c2 "✓" "✗") (second granted))
  (format #t "  [~a] CARRY: the same pair, no container, is SPACE      (~,2f kg on Tuesday)~%" (if c3 "✓" "✗") (third granted))
  (format #t "  [~a] nothing was baked — there was no baker            (~,2f)~%" (if c4 "✓" "✗") (fourth granted))
  (format #t "  [~a] ungranted, the same box is invisible to the plan  (~,0f%)~%" (if c5 "✓" "✗") (* 100 (first private)))
  (format #t "  [~a] and the difference between the arcs is one flag on one spec~%" (if c6 "✓" "✗"))
  (format #t "~%  ~a leaving a thing somewhere public and taking it away again is~%" (if ok "✓" "✗"))
  (format #t "    pickup/dropoff twice over, plus one custody grant.~%~%")
  (exit (if ok 0 1)))
