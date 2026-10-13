;;; module/playnet/doors/journeys.scm — a journey is a performed Process: its ids, its good, the place it is minted at, its two events.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet doors journeys)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module ((playnet vf schemas) #:select (make-spatial-thing recipe-flow-action recipe-flow-resource-conforms-to recipe-process-id))
  #:use-module ((srfi srfi-1) #:select (find))
  #:export (trip-ids trip-good ensure-place!))

;;; ── A journey is a performed Process ─────────────────────────────────
;; The trip's process and the commitment for its arrival are named from the
;; departure's commitment, so the arrival finds them again; both ids are opaque.
(define (trip-ids cid)
  "(process-id . arrival-commitment-id) of the journey whose departure commitment is CID."
  (cons (keyed-id "trip" cid) (keyed-id "arrive" cid)))

(define (trip-good rs mode-rp)
  "The good a trip moves: the pickup flow's spec of its MODE-RP, a rider when no mode
   of the scope covers the way it was made."
  (or (and mode-rp
           (let ((f (find (lambda (f) (eq? 'pickup (recipe-flow-action f)))
                          (car ($ rs 'flows-for-process (recipe-process-id mode-rp))))))
             (and f (recipe-flow-resource-conforms-to f))))
      "spec-rider"))

(define (ensure-place! sts place)
  "A \"geo:lat,lng\" place is minted as a SpatialThing, so every trip's location
   references one; any other id is the caller's own."
  (when (and (string? place) (string-prefix? "geo:" place)
             (not (false-if-exception ($ sts 'get-location place))))
    (let* ((parts (string-split (substring place 4) #\,))
           (lat (and (= 2 (length parts)) (string->number (car parts))))
           (lon (and lat (string->number (cadr parts)))))
      (when (and lat lon)
        ($ sts 'add-location (make-spatial-thing #:id place #:name place #:lat lat #:long lon))))))
