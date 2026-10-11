;;; module/playnet/doors/position.scm — where a person is: the live and expected position, the place it snaps to, the sharing mode, and the horizon a demand spans.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet doors position)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors record-rows) #:select (iso-date-from-epoch))
  #:use-module ((playnet knowledge law jurisdiction-at) #:select (jurisdiction-at))
  #:use-module ((playnet legal registry) #:select (place-chain))
  #:use-module ((playnet scope live) #:select (time->period))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) now))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure success))
  #:use-module ((playnet vf facts person-facts) #:select (fix-fresh? location-share-key person-place-id position-key position-key?))
  #:use-module ((playnet vf schemas) #:select (commitment-action commitment-at-location commitment-has-beginning commitment-provider make-spatial-thing spatial-thing-id spatial-thing-lat spatial-thing-long spatial-thing-name))
  #:use-module ((srfi srfi-1) #:select (fold))
  #:export (snap-km label-km located? km-between nearest-place
            nearest-location standing-in own-position-place! location-mode sharing-refused?
            do-set-position demand-horizon federated-horizon demand->keyed agent-position-predicate))

;; ── Live / expected POSITION — where an agent is, per period ─────────────────
;; All three sharing modes feed the SAME thing: a place per (agent, period) that
;; overrides the static primary-location as the planner's commute origin.
;;   • manual "I'm here now"  → set period 0 once
;;   • continuous live share  → set period 0 repeatedly (a watch)
;;   • expected trajectory    → set periods 0..N
;; The client snaps raw GPS to a known place id BEFORE sending (coarse by design —
;; the planner only ever sees a named location, never exact lat/lon).

;; Snap raw lat/lon to a place — the COARSENING step. Either the client snaps
;; and calls set-position with a place, or it sends raw coords to
;; set-position-latlon and the gateway snaps here; either way only a named,
;; coarse place is stored, never the exact coordinate.
;;
;; A place counts when it carries a real coordinate (a container declared
;; without one holds #f, or 0/0 for "none"), and a fix snaps to it only when
;; it is NEAR: within SNAP-KM. Farther than that the nearest place is not
;; where you are — it is another city — so the fix names a place of its own
;; (own-position-place!) rather than borrowing a distant one.
(define snap-km 12.0)
(define label-km 25.0)

(define (located? s)
  (let ((la (spatial-thing-lat s)) (lo (spatial-thing-long s)))
    (and (number? la) (number? lo) (not (and (zero? la) (zero? lo))))))

;; kilometres between two points: planar on a cos(lat)-shrunk longitude, which
;; is exact enough at the scale of a district
(define (km-between la1 lo1 la2 lo2)
  (let* ((k  111.2)
         (dy (* k (- la1 la2)))
         (dx (* k (cos (* (/ (+ la1 la2) 2.0) (/ 3.141592653589793 180.0))) (- lo1 lo2))))
    (sqrt (+ (* dx dx) (* dy dy)))))

;; the located place among LOCS nearest (lat, lon) within WITHIN km, or #f
(define (nearest-place locs lat lon within)
  (let loop ((ls locs) (best #f) (bd within))
    (cond ((null? ls) best)
          ((located? (car ls))
           (let ((d (km-between (spatial-thing-lat (car ls)) (spatial-thing-long (car ls)) lat lon)))
             (if (<= d bd) (loop (cdr ls) (car ls) d) (loop (cdr ls) best bd))))
          (else (loop (cdr ls) best bd)))))

(define (nearest-location scope-root lat lon)
  (let ((s (nearest-place ($ ($ scope-root 'spatial-thing-store) 'all-locations) lat lon snap-km)))
    (and s (spatial-thing-id s))))

;; The place a position STANDS IN — what a person's own place is contained in,
;; so the law of that place reaches them by the tree's climb. The deepest place
;; whose outline holds the point (knowledge/jurisdiction-at.scm); a known place
;; within snap distance, when it stands under that outline or no outline holds
;; the point, is nearer still and is taken instead. #f when nothing places it:
;; the position then stands under no place, and no place's law.
(define (standing-in lat lon all-locs)
  (let* ((outline (jurisdiction-at lat lon))
         (near    (nearest-place all-locs lat lon snap-km))
         (near-id (and near (spatial-thing-id near))))
    (cond ((and near-id (or (not outline) (member outline (place-chain near-id)))) near-id)
          (else outline))))

;; No place of this scope is near: the fix becomes a place of its own, at a
;; ~1 km grid (two decimals — the coarsening), named for the nearest place ANY
;; scope knows when one is near enough to name it ("Steglitz-Zehlendorf"),
;; else by its grid point. ONE id per person (place:AID:here), re-placed as
;; they move, so the store keeps where they are and no trail.
(define (own-position-place! scope-root aid lat lon all-locs)
  (let* ((grid  (lambda (x) (/ (round (* x 100.0)) 100.0)))
         (la (grid lat)) (lo (grid lon))
         (near (nearest-place all-locs lat lon label-km))
         (name (if near
                   (or (spatial-thing-name near) (spatial-thing-id near))
                   (string-append (number->string la) ", " (number->string lo))))
         (id   (person-place-id aid "here")))
    ($ ($ scope-root 'spatial-thing-store) 'add-location
       (make-spatial-thing #:id id #:name name #:lat la #:long lo
                           #:contained-in (standing-in lat lon all-locs)))
    id))

(define (location-mode scope-root agent-id)
  "The mode AGENT-ID declared for sharing where they are — live, here or off — at
   this scope, or #f where none is declared."
  (let ((row ($ ($ scope-root 'plan-store) 'get-meta (location-share-key agent-id))))
    (and (pair? row) (assq-ref row 'mode))))

(define (sharing-refused? scope-root agent-id period place)
  "A fix for now is refused while AGENT-ID has declared they share nothing."
  (and place (eqv? period 0) (eq? (location-mode scope-root agent-id) 'off)))

(define (do-set-position scope-root agent-id period place)
  "place = a known location id (where AGENT is at PERIOD); #f clears it. A fix
   for now (period 0) is a lease and carries the instant it was sent."
  (let ((ps ($ scope-root 'plan-store)))
    (catch-as-failure
      (lambda ()
        (when (sharing-refused? scope-root agent-id period place)
          (error "location sharing is off: declare live or here to send a fix"))
        ($ ps 'set-meta (position-key agent-id period)
           (if place `((place . ,place) (agent . ,agent-id) (period . ,period) (at . ,(clock-now))) '()))
        (success (or place 'cleared))))))

;; Derive the planning HORIZON from the demand so multi-period actually runs
;; live: if the demand asks for anything beyond period 0, lay out that many daily
;; periods starting today (so the periods exist + carry real dates). An explicit
;; (horizon . (start . n)) opt always wins; single-period demand ⇒ #f (unchanged).
(define (demand-horizon demand o)
  (or (assq-ref o 'horizon)
      ;; same wire seam as demand->keyed: JSON arrays cross as vectors
      (let* ((->l (lambda (x) (if (vector? x) (vector->list x) x)))
             (maxp (fold (lambda (d a) (max a (list-ref (->l d) 2))) 0 (->l demand))))
        (and (> maxp 0) (cons (iso-date-from-epoch (now)) (+ maxp 1))))))

;; The FEDERATED plan's horizon: one dated day. Its members' labour arrives
;; off the standing pool as availability windows, and a window's hours are a
;; clock fact — 09:00–10:30 is ninety minutes of one day. A span-less period
;; has no day to meet that against, and the engine's fallback there sums the
;; window over every weekday a period might hold: measured, a 1.5 h window
;; entered the federated solve as 10.5 h and a shrunk roster bound nothing
;; (tests/doors/test-labour-fold-federation.scm). So the day is laid the
;; way plan-commune-scope lays it for an empty scope — today — and it is ONE
;; day because a member's record carries one boundary column per traded
;; good (commune->scope-record: the link key is the good), which is a day's
;; trade. An explicit (horizon . (start . n)) opt wins outright.
(define (federated-horizon o)
  (or (assq-ref o 'horizon)
      (cons (iso-date-from-epoch (now)) 1)))

;; wire-form demand (spec place period qty) → the engine's keyed form (spec#place@period . qty).
;; JSON arrays cross as VECTORS (guile-json), so a browser what-if arrives as
;; #(#(spec place t qty) …) — normalized here, at the one wire seam.
(define (demand->keyed demand)
  (define (->l x) (if (vector? x) (vector->list x) x))
  (map (lambda (d)
         (let ((d (->l d)))
           (cons (string-append (list-ref d 0) "#" (list-ref d 1) "@" (number->string (list-ref d 2)))
                 (list-ref d 3))))
       (->l demand)))

(define (agent-position-predicate scope-root)
  "Where each agent IS, per period, as one consistent TRAJECTORY — priority:
     1. live/manual override   (pos| meta; GPS 'now' or a declared future place)
     2. committed work location (their accepted work IS where they'll be)
     3. home                    (#f ⇒ the planner falls back to primary-location)
   (2) makes 'expected position' fall out of the plan itself: accepting work at a
   place puts you there for further planning, closing the plan↔position loop.
   Manual overrides win over the derivation; home is the floor. Returns #f when
   nothing pins anyone (⇒ everyone at home)."
  (let* ((ps        ($ scope-root 'plan-store))
         (overrides (make-hash-table))    ; (agent . period) → place   [live / manual]
         (committed (make-hash-table))    ; agent → place              [derived expected]
         (any #f))
    ;; 1. explicit overrides (live = period 0; manual expected = any period)
    (for-each
      (lambda (kv)
        (and (position-key? (car kv))
             (let ((place (assq-ref (cdr kv) 'place))
                   (period (assq-ref (cdr kv) 'period)))
               ;; a fix for now is a lease: it counts while it is fresh
               (when (and place (or (not (eqv? period 0)) (fix-fresh? (assq-ref (cdr kv) 'at) (clock-now))))
                 (set! any #t)
                 (hash-set! overrides (cons (assq-ref (cdr kv) 'agent)
                                            (assq-ref (cdr kv) 'period)) place)))))
      ($ ps 'all-meta))
    ;; 2. committed work locations → the derived expected trajectory. The
    ;; commitment's hasBeginning (WHEN, from the schema) maps to its period via
    ;; time->period; a worker is at their committed place IN that period.
    (for-each
      (lambda (c)
        (let ((prov (commitment-provider c)) (loc (commitment-at-location c)))
          (when (and prov loc (eq? (commitment-action c) 'work))
            (set! any #t)
            (hash-set! committed (cons prov (time->period (commitment-has-beginning c))) loc))))
      ($ ps 'all-commitments))
    (and any
         (lambda (agent period)
           (or (hash-ref overrides (cons agent period) #f)          ; override wins
               (hash-ref committed (cons agent period) #f))))))