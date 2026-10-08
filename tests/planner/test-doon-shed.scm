;;; test-doon-shed.scm — a bioregion carries a MULTITUDE of fragilities, on ONE
;;; shed id, each via the existing containment cascade. Proves the architectural
;;; claim "any resource-spec can contain fragilities": the Doon shed contains TWO
;;; distinct fragile specs (groundwater, topsoil), and a crop that draws BOTH
;;; stresses BOTH shed barriers at once — while an unrelated draw stresses neither.
;;; Same machinery as frag-container-test, just several contained specs, not one.
;;;
;;; Real data (worlds/doon-shed.scm / data/sources.md): the shed's ERA5 climate scenarios
;;; + SoilGrids topsoil state; the fragility ranges are DRAFT (governance).
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/planner/test-doon-shed.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner vf schemas)
             (playnet planner knowledge worlds bioregions)
             (srfi srfi-1)
             (ice-9 format))
(use-modules (playnet planner knowledge worlds doon-valley)
             (playnet planner knowledge dsl shorthand))   ; scenarios (data)
(use-modules (playnet planner knowledge worlds doon-shed))     ; the assembled bioregion (one <bioregion>)

;; everything the test needs is projected from the ONE object *doon-shed*:
(define *doon-shed-id*  (bioregion-id *doon-shed*))
(define *doon-shed-eco* (bioregion-fragilities *doon-shed*))

;; ── A crop that IRRIGATES (draws groundwater) and TILLS (draws topsoil) ────────
;; Each ecological spec is a fragile draw the shed contains (a marker resource maps
;; it into *contained*[doon-shed]; its onhand is the tiny draw-to-date PRIOR). Its
;; OWN per-spec fragility (#:eco-spec-frag) caps the draw rate at the shed cell; the
;; drawable envelope is set in *cap* (availability, separate from the prior). The
;; grow recipe draws both, so producing grain is pulled by BOTH fragilities at once.
(define (eco-marker spec)                         ; onhand 1.0 = negligible prior draw, maps into *contained*
  (er (string-append spec "-1") spec #f #:place #f #:qty 1.0 #:unit "u" #:contained-in *doon-shed-id*))
(define (grow-recipe)
  (compile-recipe (list (rp "grow" "Grow"))
                  (list (out "o1" "grain" 1.0 "grow") (wrk "o2" 0.01 "grow")
                        (in "o3" "groundwater" 1.0 "grow") (in "o4" "topsoil" 1.0 "grow"))))

(define (run eco)   ; eco: subset of *doon-shed-eco* to activate (per-spec fragilities)
  (set-templates! (grow-recipe))
  (ingest-located! (list (eco-marker "groundwater") (eco-marker "topsoil")) '()
    *doon-shed-spatials*
    #:periods '(0)
    #:eco-spec-frag eco
    #:demand (list (cons (lg "grain" (cell *doon-shed-id* 0)) 1000.0)))   ; want to grow far past either tip
  (hash-set! *A* (cell *doon-shed-id* 0) 1000000.0)
  ;; availability of the ecological draws (separate from the prior above) — a big
  ;; envelope so the FRAGILITY, not the stock, is what eases the draw off.
  (hash-set! *cap* (lg "groundwater" (cell *doon-shed-id* 0)) 100000.0)
  (hash-set! *cap* (lg "topsoil"     (cell *doon-shed-id* 0)) 100000.0)
  (call-with-values solve-located
    (lambda (x idx) ((Vof x idx) "p|grow|doon-shed@0"))))

(define tip 100.0)
(define free  (run '()))                                   ; no shed fragility
;; The shed's limits are held at different SCALES now — groundwater pooled over
;; the whole shed, topsoil per plot — so the list mixes a <fragility> record with
;; a bare (spec . profile) pair. Selecting one by name has to read both shapes.
(define (eco-named name)
  (filter (lambda (e)
            (if (fragility? e)
                (and (member name (fragility-specs e)) #t)
                (equal? name (car e))))
          *doon-shed-eco*))
(define water (run (eco-named "groundwater")))   ; only groundwater binds
(define both  (run *doon-shed-eco*))                       ; groundwater AND topsoil bind
(define contained (sort (hash-ref *contained* *doon-shed-id* '()) string<?))

;; BOTH channels reach the farm by containment (no #:scenarios / #:eco-spec-frag
;; needed): the shed's futures AND its limits, from the one placement.
(define farm-scen (scope-bioregion-scenarios   *doon-shed-spatials*))
(define farm-frag (scope-bioregion-fragilities *doon-shed-spatials*))

(format #t "~%── the Doon shed: a MULTITUDE of fragilities on one bioregion id ──~%")
(format #t "  *contained*[doon-shed] = ~a~%" contained)
(format #t "  grow, no shed fragility:        ~,1f~%" free)
(format #t "  grow, groundwater cap only:     ~,1f~%" water)
(format #t "  grow, groundwater AND topsoil:  ~,1f~%" both)
(format #t "  farm inherits ~a climate scenarios via containment~%" (length farm-scen))

(let* ((c1 (equal? contained '("groundwater" "topsoil")))   ; both mapped in from contained-in
       (c2 (> free (* 2.0 tip)))                            ; unconstrained runs far past
       (c3 (and (< water tip) (> (- tip water) 0.1)))       ; one fragility already holds the line
       (c4 (< both water))                                  ; TWO binding is STRICTLY tighter than one
       (c5 (> both 1.0))                                    ; still grows — limits, not a shutoff
       (c6 (= (length farm-scen) 4))                        ; the 4 real scenarios reached the farm
       (c7 (equal? farm-frag *doon-shed-eco*))              ; …and the 2 fragilities reached it too — SYMMETRIC
       (ok (and c1 c2 c3 c4 c5 c6 c7)))
  (format #t "~%  [~a] shed contains TWO fragile specs, both mapped from contained-in~%" (if c1 "✓" "✗"))
  (format #t "  [~a] unconstrained the draw runs far past the tip (~,1f)~%" (if c2 "✓" "✗") free)
  (format #t "  [~a] groundwater alone already eases it off (~,1f < ~a)~%" (if c3 "✓" "✗") water tip)
  (format #t "  [~a] adding topsoil binds TIGHTER — two fragilities compose (~,1f < ~,1f)~%" (if c4 "✓" "✗") both water)
  (format #t "  [~a] the shed still yields grain — a limit, not a shutoff~%" (if c5 "✓" "✗"))
  (format #t "  [~a] the farm inherits the shed's ~a climate scenarios via containment~%" (if c6 "✓" "✗") (length farm-scen))
  (format #t "  [~a] …AND its ~a ecological fragilities — futures + limits, one placement~%" (if c7 "✓" "✗") (length farm-frag))
  (format #t "~%  ~a a bioregion is ONE container of a multitude — both channels flow from where a scope sits~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
