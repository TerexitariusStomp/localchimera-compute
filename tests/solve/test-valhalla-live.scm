;;; test-valhalla-live.scm — the matrix client against the real local engine.
;;;
;;; GUARDED: skips cleanly (exit 0) when no Valhalla answers on
;;; PLAYNET_VALHALLA_URL (default 127.0.0.1:8002), so offline CI never reddens.
;;; When the engine is up: a 3-place Sofia matrix per manner must yield
;;; positive HOURS (the ÷3600 boundary check — a missed conversion would show
;;; up as values thousands of times too large), keyed both directions, and the
;;; tileset stamp must exist (it versions the prior file).
;;;
;;; Run:  guile module/playnet/planner/valhalla-live-test.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve routing))

(unless (valhalla-up?)
  (format #t "  ~~ skip: no valhalla at ~a~%" *valhalla-base*)
  (exit 0))

;; the atlas swaps by deployment (regions are pure add/remove of extracts) —
;; probe the known city-triples and test against whichever the engine holds
(define %cities
  `(("sofia"  . (("centre"   . (42.6977 . 23.3219))
                 ("lozenets" . (42.6506 . 23.3792))
                 ("lyulin"   . (42.7140 . 23.2425))))
    ("sf"     . (("centre"   . (37.7782 . -122.4114))
                 ("lozenets" . (37.7702 . -122.4530))   ; GG Park east (~4 km)
                 ("lyulin"   . (37.7340 . -122.4450)))) ; Glen Park-ish
    ("berlin" . (("centre"   . (52.5219 . 13.4045))
                 ("lozenets" . (52.5163 . 13.3777))     ; Brandenburg Gate
                 ("lyulin"   . (52.4870 . 13.4250))))))
(define-values (city latlon)
  (let loop ((cs %cities))
    (if (null? cs) (values #f '())
        (let* ((c (car cs))
               (m (valhalla-matrix (map car (cdr c)) (cdr c) "pedestrian")))
          (if (pair? m) (values (car c) (cdr c)) (loop (cdr cs)))))))
(unless city
  (format #t "  ~~ skip: no test city in the engine's atlas~%")
  (exit 0))
(format #t "  (testing against the ~a tiles)~%" city)
(define places (map car latlon))

(define ped (valhalla-matrix places latlon "pedestrian"))
(define car* (valhalla-matrix places latlon "auto"))

;; entries are hours, or (hours . road-km) when the matrix reports distance
(define (h-of tbl k) (let ((v (assoc-ref tbl k))) (if (pair? v) (car v) v)))
(define (d-of tbl k) (let ((v (assoc-ref tbl k))) (and (pair? v) (cdr v))))
(define c1 (= (length ped) 6))                              ; 3×3 minus self-arcs
(define c2 (let ((h (h-of ped "centre|lozenets|pedestrian")))
             (and h (> h 0.2) (< h 8.0))))                  ; a cross-town walk: hours, not seconds
(define c3 (and (h-of ped "lozenets|centre|pedestrian") #t)); both directions present
(define c4 (let ((hp (h-of ped "centre|lyulin|pedestrian"))
                 (hc (h-of car* "centre|lyulin|auto")))
             (and hp hc (< hc hp))))                        ; driving beats walking
(define c5 (number? (valhalla-tileset-stamp)))
(define c6 (let ((d (d-of ped "centre|lozenets|pedestrian")))
             (and d (> d 1.0) (< d 25.0))))                 ; real road km rides along

(for-each (lambda (ok label) (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
          (list c1 c2 c3 c4 c5 c6)
          (list "matrix yields all 6 directed arcs over 3 places"
                (format #f "a cross-town walk is plausible HOURS (~,2f) — ÷3600 boundary holds"
                        (or (h-of ped "centre|lozenets|pedestrian") 0))
                "arcs are keyed in both directions"
                "auto is faster than pedestrian on the same arc"
                "tileset stamp present (prior versioning)"
                (format #f "road distance rides along (~,1f km, sane bounds)"
                        (or (d-of ped "centre|lozenets|pedestrian") 0))))
(let ((ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  ~a live Valhalla matrix → planner-ready (hours . road-km)~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
