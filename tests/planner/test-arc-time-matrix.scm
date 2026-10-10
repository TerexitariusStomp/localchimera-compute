;;; test-arc-time-matrix.scm — the matrix as a first-class source, locked.
;;;
;;; Matrix-sourced entries are (hours . road-km) pairs; from them the planner
;;; derives three further facts, each with a strict precedence rule:
;;;
;;;   values   — arc-hours reads the hours, arc-net-km the road km;
;;;              bare-hours (observed) entries leave km on haversine;
;;;   pace     — per-manner median hours/km, UNLESS explicitly declared;
;;;   topology — finite arcs become *neighbours*, ONLY when opted in AND
;;;              no edges were declared (governance wins over geometry);
;;;
;;; and the merge is per-FIELD: an observed time inherits the prior's km
;;; rather than shadowing the road out of existence. No solver, no network.
;;;
;;; Run:  guile module/playnet/planner/arc-time-matrix-test.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine))
(use-modules (playnet solve routing))

(define (~= a b) (and a b (< (abs (- a b)) 1e-9)))
(define (setup!)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.9) ("C" 0.9 0.0))))   ; ~100 km haversine

;; ── pair values: hours and road-km read from the same entry ─────────────────
(setup!)
(ingest-travel-times! '(("A|B|auto" . (1.6 . 130.0))   ; matrix pair
                        ("A|C|auto" . 2.0)))           ; observed bare hours
(define cA (cell "A" 0)) (define cB (cell "B" 0)) (define cC (cell "C" 0))
(define c1 (~= (arc-hours cA cB "auto" 999.0) 1.6))
(define c2 (~= (arc-net-km cA cB "auto") 130.0))                  ; the road, not the crow
(define c3 (~= (arc-hours cA cC "auto" 999.0) 2.0))
(define c4 (~= (arc-net-km cA cC "auto") (km cA cC)))             ; bare hours ⇒ haversine km

;; ── pace: derived as median hours/km; the table is the one source ───────────────
(define c5 (~= (or (assoc-ref *manner-pace* "auto") 0)
               (/ 1.6 130.0)))                                    ; one pair ⇒ its own pace
(setup!)
(set! *manner-pace* '(("auto" . 0.5)))                            ; a stale value from before
(ingest-travel-times! '(("A|B|auto" . (1.6 . 130.0))))
(define c6 (~= (assoc-ref *manner-pace* "auto") (/ 1.6 130.0)))   ; the data speak

;; ── topology: fills only silence, and only when asked ───────────────────────
(setup!)
(ingest-travel-times! '(("A|B|auto" . (1.6 . 130.0))))            ; no flag
(define c7 (not (hash-ref *neighbours* "A")))                     ; untouched
(setup!)
(ingest-travel-times! '(("A|B|auto" . (1.6 . 130.0))) #:derive-topology? #t)
(define c8 (equal? (hash-ref *neighbours* "A") '("B")))           ; matrix arc → edge
(setup!)
(hash-set! *neighbours* "A" '("C"))                               ; declared edges…
(ingest-travel-times! '(("A|B|auto" . (1.6 . 130.0))) #:derive-topology? #t)
(define c9 (equal? (hash-ref *neighbours* "A") '("C")))           ; …win over geometry

;; ── period-classes: the classed key refines, the manner-wide key carries ────
(setup!)
(ingest-travel-times! '(("A|B|auto" . 1.0)
                        ("A|B|auto|wd-am" . 1.8)))            ; rush hour
(define c12 (~= (arc-hours cA cB "auto" 999.0) 1.0))          ; no classifier ⇒ manner-wide
(set! *period-class-of* (lambda (t) "wd-am"))
(define c13 (~= (arc-hours cA cB "auto" 999.0) 1.8))          ; classified ⇒ rush-hour entry
(set! *period-class-of* (lambda (t) "wd-night"))
(define c14 (~= (arc-hours cA cB "auto" 999.0) 1.0))          ; unknown class ⇒ falls back

;; ── per-field merge: observed time inherits the prior's road ─────────────────
(define merged (arc-table-merge '(("A|B|auto" . (1.6 . 130.0)) ("B|C|auto" . (1.0 . 80.0)))
                                '(("A|B|auto" . 2.1))))
(define c10 (equal? (assoc-ref merged "A|B|auto") '(2.1 . 130.0)))  ; obs hours ⊕ prior km
(define c11 (equal? (assoc-ref merged "B|C|auto") '(1.0 . 80.0)))   ; un-observed prior whole

(for-each (lambda (ok label) (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
          (list c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14)
          '("pair entry: arc-hours reads the hours"
            "pair entry: arc-net-km reads the road km"
            "bare entry: arc-hours reads the hours"
            "bare entry: arc-net-km stays on haversine"
            "pace derived as hours/km from matrix pairs"
            "the table is the one source of a manner's pace"
            "no flag: topology untouched"
            "flag + silence: matrix arcs become edges"
            "flag + declared edges: governance wins"
            "merge: observed hours inherit the prior's road km"
            "merge: un-observed priors pass through whole"
            "no classifier: manner-wide entry serves"
            "classified period: the classed entry refines"
            "unknown class: falls back to manner-wide"))
(let ((ok (and c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14)))
  (format #t "~%  ~a the matrix is a first-class source, with precedence locked~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
