;;; snapshot.scm — a scope's standing, as a snapshot carries it.
;;;
;;; The planner answers `scope-snapshot` with one alist: the scope's places, its
;;; stock, its plan, its day. Each arm is read off the scope root's stores here,
;;; so whoever holds a scope root reads it the same way: the planner service on a
;;; gateway, and a scope held in a page (page-scope.scm).
;;;
;;; What depends on the last solve is handed in by the caller, who keeps it: a
;;; place's slack is the solve's to say.

(define-module (playnet scope snapshot)
  #:use-module (goblins)
  #:use-module ((playnet vf schemas)
                #:select (spatial-thing-id spatial-thing-name spatial-thing-lat spatial-thing-long
                          spatial-thing-contained-in spatial-thing-boundary spatial-thing-note
                          spatial-thing-mappable-address))
  #:export (scope-locations->wire dedup-locations))

;; The scope's places. LOCSLACK, where a solve stands, is a table from a place id
;; to how far its demand is met (met over want); a place it does not hold, and
;; every place when no solve stands, carries #f.
(define* (scope-locations->wire scope-root #:optional (locslack #f))
  (map (lambda (s)
         (let ((sl (and locslack (hash-ref locslack (spatial-thing-id s) #f))))
           `((id           . ,(spatial-thing-id s))
             (name         . ,(or (spatial-thing-name s) (spatial-thing-id s)))
             (lat          . ,(spatial-thing-lat s))
             (long         . ,(spatial-thing-long s))
             (contained-in . ,(spatial-thing-contained-in s))
             (boundary     . ,(spatial-thing-boundary s))   ; GeoJSON extent (JSON string) or #f
             ;; what the place says about itself: a venue's access note, the
             ;; sentence that finds a box left under a bridge.
             (note         . ,(spatial-thing-note s))
             ;; a human-readable address, when the citizen who named it gave one —
             ;; free-association's Specific tab (street/city/state/postal/country)
             ;; collapsed to the one string the schema already carries
             (address      . ,(spatial-thing-mappable-address s))
             (slack        . ,sl))))
       ($ ($ scope-root 'spatial-thing-store) 'all-locations)))

;; union of location wires, keeping the FIRST occurrence of each id (the viewer's
;; own places win over a sibling's copy of the shared federation root).
(define (dedup-locations locs)
  (let ((seen (make-hash-table)) (out '()))
    (for-each (lambda (l)
                (let ((id (assq-ref l 'id)))
                  (unless (or (not id) (hash-ref seen id #f))
                    (hash-set! seen id #t)
                    (set! out (cons l out)))))
              locs)
    (reverse out)))
