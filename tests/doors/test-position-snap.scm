;;; test-position-snap.scm — a shared fix names a place that is NEAR it
;;;
;;; set-position-latlon snaps raw coordinates to the scope's places. A place
;;; counts only with a real coordinate and only within snap-km of the fix; a
;;; fix in Berlin does not land at a Sofia granary because that is the only
;;; located place the scope holds — it names a place of its own, labelled from
;;; the nearest place any scope knows.
;;; Run: guile -L module tests/doors/test-position-snap.scm

(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas)
             (playnet doors service)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define nearest-place (@@ (playnet doors position) nearest-place))
(define snap-km       (@@ (playnet doors position) snap-km))
(define label-km      (@@ (playnet doors position) label-km))

(define (place id name lat lon) (make-spatial-thing #:id id #:name name #:lat lat #:long lon))
(define granary   (place "commune-granary" "Granary" 42.70 23.32))
(define fed       (place "fed" "Federation" #f #f))
(define biosphere (place "biosphere" "The biosphere" 0.0 0.0))
(define steglitz  (place "bz-steglitz-zehlendorf" "Steglitz-Zehlendorf" 52.4371 13.278))
(define mitte     (place "bz-mitte" "Mitte" 52.5321 13.3698))

;; a fix in Steglitz (52.44, 13.30)
(define lat 52.44) (define lon 13.30)

(define (id-of s) (and s (spatial-thing-id s)))

(display "\n── which place a fix may snap to ──\n")
(check "a scope of only distant places names none of them"
       (nearest-place (list fed granary biosphere) lat lon snap-km) #f)
(check "a place with no coordinate never wins (#f)"
       (nearest-place (list fed) lat lon snap-km) #f)
(check "…nor one at the 0/0 of 'none'"
       (nearest-place (list biosphere) 0.001 0.001 snap-km) #f)
(check "the nearest of the near places is taken"
       (id-of (nearest-place (list granary mitte steglitz) lat lon snap-km))
       "bz-steglitz-zehlendorf")
(check "beyond the snap radius: not snapped to"
       (nearest-place (list steglitz) 52.30 13.278 snap-km) #f)
(check "…but near enough to name the fix's own place"
       (id-of (nearest-place (list steglitz) 52.30 13.278 label-km))
       "bz-steglitz-zehlendorf")

(display "\n── over the service: a Berlin fix in a Sofia scope ──\n")
(define vat (spawn-vat))
(with-vat vat
  (let* ((sr  (spawn-scope-root "Granary"))
         (sts ($ sr 'spatial-thing-store))
         (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
    (for-each (lambda (s) ($ sts 'add-location s)) (list fed granary))
    (let ((r ($ svc 'set-position-latlon "s1" "alice" 0 lat lon)))
      (check "ok" (car r) 'ok)
      (check "the fix is placed at a place of its own, not at Granary"
             (cdr r) "place:alice:here"))
    (let ((own ($ sts 'get-location "place:alice:here")))
      (check "it names a place of its own, on a ~1 km grid"
             (and own (spatial-thing-lat own) (spatial-thing-long own)
                  (equal? (list (spatial-thing-lat own) (spatial-thing-long own)) (list 52.44 13.3)))
             #t))
    (check "a fix beside a known place snaps to it"
           (cdr ($ svc 'set-position-latlon "s1" "alice" 0 42.71 23.33))
           "commune-granary")))

(display "\n")
(test-summary!)
