;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; law/jurisdiction-at.scm — the place a position stands in.
;;;
;;; A member's position is a pair of coordinates; the law is written on places.
;;; `jurisdiction-at` answers with the DEEPEST place of the shared tree whose
;;; outline holds the point, so a position in Alameda County stands under
;;; California, the United States and the world by the tree's own climb.
;;;
;;; The outlines are the ones the tree already ships, each matched to a place by
;;; the id that place carries:
;;;   browser/data/geo/world-countries-110m.json   a nation, by its ISO numeric
;;;                                                (a place's `iso` extra)
;;;   browser/data/geo/us-states-10m.json          a US state, by FIPS: us-<fips>
;;;   data/law/*-zones.geojson                     a zone, by its feature's own id
;;;                                                (tools/law/fetch-fr-gpu.py)
;;; A place with no outline here is reached by none of them; the caller falls
;;; back to the nearest place it knows, or leaves the position unplaced.
;;; Read on first use and kept.

(define-module (localchimera knowledge law jurisdiction-at)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (localchimera utils geo)
  #:use-module (localchimera vf facts places)
  #:use-module ((localchimera legal registry) #:select (place-chain))
  #:export (jurisdiction-at jurisdiction-outlines register-jurisdiction-outline!))

(define (read-json path)
  (json-string->scm (call-with-input-file path get-string-all #:encoding "UTF-8")))
(define (jarr x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))
(define (find-under dir)                ; DIR as the repo, the parent, or the deployed tree has it
  (find file-exists? (list dir (string-append "../" dir) (string-append "/srv/localchimera/" dir))))

;;; (place-id . geometry) for every outline that names a place the tree knows
(define %extra '())                     ; outlines a caller registers (a test, a scope)
(define (register-jurisdiction-outline! place-id geometry)
  (set! %extra (cons (cons place-id geometry) %extra))
  (set! %outlines #f))
(define (shipped-outlines)
  (let* ((geo   (find-under "browser/data/geo"))
         (law   (find-under "data/law"))
         (file  (lambda (dir name) (and dir (let ((p (string-append dir "/" name)))
                                              (and (file-exists? p) p)))))
         (iso->place (filter-map (lambda (id) (let ((iso (place-extra-ref id 'iso)))
                                                (and iso (cons iso id))))
                                 (all-place-ids)))
         (nations (let ((p (file geo "world-countries-110m.json")))
                    (if p
                        (filter-map (lambda (f)
                                      (let ((place (and (car f) (assoc-ref iso->place (car f)))))
                                        (and place (cons place (cdr f)))))
                                    (topojson-features (read-json p) "countries"))
                        '())))
         (states  (let ((p (file geo "us-states-10m.json")))
                    (if p
                        (filter-map (lambda (f)
                                      (let ((place (and (car f) (string-append "us-" (car f)))))
                                        (and place (place-known? place) (cons place (cdr f)))))
                                    (topojson-features (read-json p) "states"))
                        '())))
         (zones   (if law
                      (append-map
                       (lambda (name)
                         (filter-map
                          (lambda (f)
                            (let ((id (assoc-ref (or (assoc-ref f "properties") '()) "id")))
                              (and (string? id) (place-known? id) (assoc-ref f "geometry")
                                   (cons id (assoc-ref f "geometry")))))
                          (jarr (assoc-ref (read-json (string-append law "/" name)) "features"))))
                       (filter (lambda (n) (string-suffix? "-zones.geojson" n))
                               (or (scandir law) '())))
                      '())))
    (append nations states zones)))

(define %outlines #f)
(define (jurisdiction-outlines)
  (or %outlines
      (let ((all (append %extra (catch #t shipped-outlines (lambda _ '())))))
        (set! %outlines all)
        all)))

(define (jurisdiction-at lat lon)
  "The deepest place of the shared tree whose outline holds (LAT, LON), or #f."
  (let ((hits (filter (lambda (o) (in-geometry? lon lat (cdr o))) (jurisdiction-outlines))))
    (and (pair? hits)
         (car (fold (lambda (o best)
                      (if (> (length (place-chain (car o))) (length (place-chain (car best)))) o best))
                    (car hits) (cdr hits))))))
