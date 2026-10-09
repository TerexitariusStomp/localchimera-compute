;;; tests/server/test-pmtiles.scm
;;;
;;; The basemap's tile source: (playnet utils pmtiles) reads a PMTiles v3
;;; archive, and serve-static answers /tiles/osm/{z}/{x}/{y} and
;;; /tiles/osm/regions.json from the archives under PLAYNET_MAP_DIR.
;;;
;;; The fixture tests/fixtures/map/tiny.pmtiles is written by
;;; tools/pmtiles-tiny.scm: tile 0/0/0 in the root directory, 1/0/0 and 1/0/1
;;; as one run and 2/1/1 alone in a leaf, every other tile a hole; each body
;;; is the gzipped text "z/x/y". The browser-side reader test reads the same
;;; file.
;;;
;;; Run: guile -L module -L tests -L . tests/server/test-pmtiles.scm

(use-modules (playnet test harness)
             (playnet utils pmtiles)
             (rnrs bytevectors)
             (ice-9 binary-ports)
             (zlib)
             (web response)
             (srfi srfi-1))

(define %fixture-dir "tests/fixtures/map")
(define %fixture (string-append %fixture-dir "/tiny.pmtiles"))

(define (gunzip bv)
  (call-with-zlib-input-port (open-bytevector-input-port bv) get-bytevector-all
                             #:format 'gzip))
(define (tile-text a z x y)
  (let ((bv (pmtiles-tile a z x y)))
    (and bv (utf8->string (gunzip bv)))))

;; ── tile ids: the spec's worked values ────────────────────────────────────
(check "tile id 0/0/0" (tile-id 0 0 0) 0)
(check "tile id 1/0/0" (tile-id 1 0 0) 1)
(check "tile id 1/0/1" (tile-id 1 0 1) 2)
(check "tile id 1/1/1" (tile-id 1 1 1) 3)
(check "tile id 1/1/0" (tile-id 1 1 0) 4)
(check "tile id 2/0/0" (tile-id 2 0 0) 5)
(check "a zoom's ids are a permutation of its range"
  (let* ((z 4) (n (ash 1 z)) (base (tile-id z 0 0))
         (ids (sort (append-map (lambda (x) (map (lambda (y) (tile-id z x y)) (iota n)))
                                (iota n))
                    <)))
    (equal? ids (iota (* n n) base))))

;; ── the archive ───────────────────────────────────────────────────────────
(define a (pmtiles-open %fixture))
(check "tile compression is read from the header" (pmtiles-tile-compression a) 'gzip)
(check "info names the file and its extent"
  (let ((i (pmtiles-info a)))
    (list (assq-ref i 'name) (assq-ref i 'bounds) (assq-ref i 'min-zoom) (assq-ref i 'max-zoom)))
  '("tiny" (13.0 52.3 13.8 52.7) 0 2))
(check "a root entry's tile" (tile-text a 0 0 0) "0/0/0")
(check "a leaf entry's tile" (tile-text a 1 0 0) "1/0/0")
(check "the second tile of a run shares its bytes" (tile-text a 1 0 1) "1/0/0")
(check "a tile after the run" (tile-text a 2 1 1) "2/1/1")
(check "a hole inside the leaf's range is #f" (pmtiles-tile a 1 1 1) #f)
(check "a hole past the last entry is #f" (pmtiles-tile a 2 3 3) #f)
(check "a zoom past max-zoom is #f without a lookup" (pmtiles-tile a 3 0 0) #f)

(check "a file that is not an archive raises pmtiles-error naming it"
  (let ((bad (string-append "/tmp/playnet-pmtiles-bad-" (number->string (getpid)) ".pmtiles")))
    (call-with-output-file bad (lambda (p) (display "not an archive at all, just text" p)))
    (let ((r (catch 'pmtiles-error (lambda () (pmtiles-open bad) #f)
               (lambda (key path why . _) (and (string=? path bad) why)))))
      (delete-file bad)
      (string? r))))

(check "the directory lists the fixture once, by name"
  (map pmtiles-path (pmtiles-archives %fixture-dir))
  (list %fixture))
(check "a directory with no archives is empty, not an error"
  (null? (pmtiles-archives "/nonexistent/playnet-map-dir")))

;; ── the routes ────────────────────────────────────────────────────────────
(setenv "PLAYNET_MAP_DIR" %fixture-dir)
(use-modules ((server serve-static) #:select (handle-osm-tile handle-osm-regions handle-osm-pack))
             (web request) (web uri))
(define (call-handler thunk) (call-with-values thunk list))
(define (header pair name) (assq-ref (response-headers (car pair)) name))

(let ((r (call-handler (lambda () (handle-osm-tile "1" "0" "1")))))
  (check "a held tile answers 200" (response-code (car r)) 200)
  (check "…as a vector tile" (header r 'content-type) '(application/vnd.mapbox-vector-tile))
  (check "…under the archive's encoding" (header r 'content-encoding) '(gzip))
  (check "…with the stored bytes" (utf8->string (gunzip (cadr r))) "1/0/0")
  (check "…cached as immutable" (and (memq 'immutable (header r 'cache-control)) #t)))
(check "a hole answers 404"
  (response-code (car (call-handler (lambda () (handle-osm-tile "1" "1" "1"))))) 404)
(check "a non-integer coordinate answers 404, never a lookup"
  (response-code (car (call-handler (lambda () (handle-osm-tile "1" "../x" "0"))))) 404)
(let ((r (call-handler handle-osm-regions)))
  (check "regions.json answers 200" (response-code (car r)) 200)
  (check "…listing the archive's name, bounds and zooms"
    (let ((body (cadr r)))
      (and (string-contains body "\"name\":\"tiny\"")
           (string-contains body "\"bounds\":[13.0,52.3,13.8,52.7]")
           (string-contains body "\"maxZoom\":2")
           #t))))


;; ── the pack: one archive by Range ─────────────────────────────────────────
(define (pack-request range)
  (build-request (string->uri "http://localhost/tiles/osm/tiny.pmtiles")
                 #:headers (if range `((range . ,range)) '())))
(define whole (call-with-input-file %fixture get-bytevector-all #:binary #t))
(let ((r (call-handler (lambda () (handle-osm-pack "tiny.pmtiles" (pack-request '(bytes (0 . 126))))))))
  (check "a Range answers 206" (response-code (car r)) 206)
  (check "…with the content range and the size" (header r 'content-range) `(bytes (0 . 126) ,(bytevector-length whole)))
  (check "…and exactly those bytes" (bytevector-length (cadr r)) 127)
  (check "…the header's bytes" (utf8->string (let ((m (make-bytevector 7))) (bytevector-copy! (cadr r) 0 m 0 7) m)) "PMTiles"))
(let ((r (call-handler (lambda () (handle-osm-pack "tiny.pmtiles" (pack-request '(bytes (200 . #f))))))))
  (check "an open-ended Range runs to the end" (header r 'content-range) `(bytes (200 . ,(- (bytevector-length whole) 1)) ,(bytevector-length whole)))
  (check "…and carries the tail" (bytevector-length (cadr r)) (- (bytevector-length whole) 200)))
(check "a Range past the end answers 416"
  (response-code (car (call-handler (lambda () (handle-osm-pack "tiny.pmtiles" (pack-request '(bytes (100000 . #f)))))))) 416)
(let ((r (call-handler (lambda () (handle-osm-pack "tiny.pmtiles" (pack-request #f))))))
  (check "no Range answers the whole file" (response-code (car r)) 200)
  (check "…byte for byte" (cadr r) whole)
  (check "…saying ranges are welcome" (header r 'accept-ranges) '(bytes)))
(check "a name no archive carries is 404, never a path"
  (response-code (car (call-handler (lambda () (handle-osm-pack "../../etc/passwd.pmtiles" (pack-request #f)))))) 404)

(test-summary!)
