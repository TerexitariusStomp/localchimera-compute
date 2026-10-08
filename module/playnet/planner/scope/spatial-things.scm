;;; spatial-things.scm — Goblins actor for location management
;;; @defines spatial-things
;;;
;;; Translated from src/lib/knowledge/spatial-things.ts
;;; State: hashmap of location-id -> <spatial-thing> record.

(define-module (playnet planner scope spatial-things)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet utils records) #:select (vf-record-from-list))
  #:use-module (playnet utils store-utils)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:export (circle-boundary spatial-thing->list list->spatial-thing resolve-chain-hm
            resolve-coordinates-hm is-descendant-or-equal-hm ^spatial-thing-store
            spatial-thing-store-env)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap))


;; Assumes schemas.scm and store-utils.scm are loaded.


;; A place's EXTENT, when all that is known about it is a radius: the GeoJSON
;; Polygon (as the JSON string every boundary is carried as) approximating the
;; circle of RADIUS-M about the point. Some places have a surveyed outline; a
;; doorway, a meeting point, a box under a bridge has a distance instead — and
;; both answer the same question, "am I standing in it".
(define* (circle-boundary lat long radius-m #:optional (n 24))
  (let* ((pi 3.141592653589793)
         (dlat (/ radius-m 111320.0))
         (dlong (/ radius-m (max 1.0 (* 111320.0 (cos (* lat (/ pi 180.0)))))))
         (pt (lambda (i)
               (let ((a (* 2 pi (/ i n))))
                 (format #f "[~,6f,~,6f]"
                         (+ long (* dlong (cos a))) (+ lat (* dlat (sin a))))))))
    (string-append "{\"type\":\"Polygon\",\"coordinates\":[["
                   (string-join (map pt (iota (+ n 1))) ",")
                   "]]}")))

;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (spatial-thing->list st)
  (list (spatial-thing-id st)
        (spatial-thing-name st)
        (spatial-thing-note st)
        (spatial-thing-lat st)
        (spatial-thing-long st)
        (spatial-thing-alt st)
        (spatial-thing-mappable-address st)
        (spatial-thing-contained-in st)))

(define list->spatial-thing (vf-record-from-list <spatial-thing>))


;; =========================================================================
;; Internal helpers (pure, operate on hashmap)
;; =========================================================================

(define (resolve-chain-hm locations id)
  "Walk containedIn chain from id. Returns list [self, parent, ..., root].
   Breaks on cycle or missing parent."
  (let loop ((current-id id) (visited '()) (chain '()))
    (cond
      ((not current-id) (reverse chain))
      ((member current-id visited string=?) (reverse chain))  ; cycle guard
      (else
        (let ((st (hashmap-ref locations current-id #f)))
          (if (not st)
              (reverse chain)
              (loop (spatial-thing-contained-in st)
                    (cons current-id visited)
                    (cons st chain))))))))

(define (resolve-coordinates-hm locations id)
  "Walk chain upward, return first (lat . long) pair found, or #f."
  (let ((chain (resolve-chain-hm locations id)))
    (let loop ((rest chain))
      (if (null? rest)
          #f
          (let ((st (car rest)))
            (if (and (spatial-thing-lat st) (spatial-thing-long st))
                (cons (spatial-thing-lat st) (spatial-thing-long st))
                (loop (cdr rest))))))))

(define (is-descendant-or-equal-hm locations candidate-id ancestor-id)
  "True if candidate-id equals ancestor-id or is transitively contained in it."
  (if (string=? candidate-id ancestor-id)
      #t
      (let ((chain (resolve-chain-hm locations candidate-id)))
        (any (lambda (st) (string=? (spatial-thing-id st) ancestor-id)) chain))))


;; =========================================================================
;; ^spatial-thing-store
;; =========================================================================

(define-actor (^spatial-thing-store bcom locations)
  ;; locations: hashmap of string -> <spatial-thing>

  #:portrait
  (lambda () (list (serialize-hashmap locations spatial-thing->list)))

  #:version 2

  #:upgrade
  (migrations
   [(2 data)
    ;; v1→v2: 7-field spatial-thing records → append #f for contained-in
    (list (hashmap-map-values (lambda (lst) (append lst '(#f))) data))])

  #:restore
  (lambda (version data)
    (spawn ^spatial-thing-store (deserialize-hashmap data list->spatial-thing)))

  (methods

    ((add-location loc)
     (let* ((id (or (spatial-thing-id loc) (generate-id "loc-")))
            ;; Cycle detection: walk proposed parent's chain for id
            (contained (spatial-thing-contained-in loc))
            (_ (when contained
                 (let ((chain (resolve-chain-hm locations contained)))
                   (when (any (lambda (st) (string=? (spatial-thing-id st) id)) chain)
                     (error "SpatialThing cycle detected" id contained)))))
            (new-locs (hashmap-set locations id loc)))
       (bcom (^spatial-thing-store bcom new-locs) id)))

    ;; a place withdrawn: the person who named it as their own has left
    ((remove-location id)
     (bcom (^spatial-thing-store bcom (hashmap-remove locations id)) (and (hashmap-ref locations id #f) #t)))

    ((get-location id)
     (hashmap-ref locations id #f))

    ((all-locations)
     (hashmap-values locations))

    ((resolve-root id)
     (let ((chain (resolve-chain-hm locations id)))
       (if (null? chain) #f (last chain))))

    ((resolve-coordinates id)
     (resolve-coordinates-hm locations id))

    ((resolve-chain id)
     (resolve-chain-hm locations id))

    ((is-descendant-or-equal candidate-id ancestor-id)
     (is-descendant-or-equal-hm locations candidate-id ancestor-id))

    ((children-of id)
     (filter (lambda (st) (equal? (spatial-thing-contained-in st) id))
             (hashmap-values locations)))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define spatial-thing-store-env
  (make-persistence-env
    `((((vf knowledge) ^spatial-thing-store) ,^spatial-thing-store))))
