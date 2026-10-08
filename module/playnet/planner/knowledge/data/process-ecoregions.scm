;;; process-ecoregions.scm — filter the RESOLVE Ecoregions 2017 to a bioregion and emit a
;;; map-ready GeoJSON layer, NESTED under it. Companion to fetch-ecoregions.sh. Guile-native:
;;; a small shapefile/.dbf reader (rnrs bytevectors) — no pyshp, no Python.
;;;
;;;   guile process-ecoregions.scm SHP BIOREGION_ID [BOUNDARIES_JSON] [TOL_DEG] > out.geojson
;;;   guile process-ecoregions.scm /tmp/resolve-ecoregions/Ecoregions2017.shp cascadia ../boundaries.json 0.03
;;;
;;; An ecoregion belongs to the bioregion if its centroid falls inside the bioregion's own
;;; polygon (from boundaries.json) OR ≥35% of its vertices do — a geographic test, no name
;;; list. Each kept ecoregion is Douglas-Peucker-simplified (TOL_DEG) and tagged
;;; containedIn=BIOREGION_ID so the map nests it. The 149 MB source is NOT vendored, only
;;; this filtered subset. Polygon rings are organised per the shapefile spec (exterior rings
;;; clockwise; holes assigned to the exterior that contains them).

(use-modules (rnrs bytevectors) (rnrs io ports)
             ((json parser) #:select (json-string->scm))
             (ice-9 format) (srfi srfi-1) (srfi srfi-11))

(define A (cdr (command-line)))
(define (arg i d) (if (> (length A) i) (list-ref A i) d))
;; The 149 MB source lands in a SCRATCH dir, not under raw/ — fetch-ecoregions.sh
;; defaults to /tmp/resolve-ecoregions. Only the filtered subset is vendored.
(define shp-path (arg 0 "/tmp/resolve-ecoregions/Ecoregions2017.shp"))
(define bio-id   (arg 1 "cascadia"))
(define bounds   (arg 2 "../boundaries.json"))
(define tol-s    (arg 3 "0.03"))
(define tol (string->number tol-s))

;; ---- the bioregion's own polygon (the membership test) + its bbox ----
(define fc (json-string->scm (call-with-input-file bounds get-string-all)))
(define bio-feat
  (let loop ((fs (vector->list (assoc-ref fc "features"))))
    (cond ((null? fs) (error "bioregion not found in boundaries" bio-id))
          ((equal? (assoc-ref (assoc-ref (car fs) "properties") "id") bio-id) (car fs))
          (else (loop (cdr fs))))))
(define bio-ring                                  ; #((x . y) …), the outer ring
  (list->vector (map (lambda (p) (cons (vector-ref p 0) (vector-ref p 1)))
                     (vector->list (vector-ref (assoc-ref (assoc-ref bio-feat "geometry") "coordinates") 0)))))
(define bx0 (apply min (map car (vector->list bio-ring))))
(define bx1 (apply max (map car (vector->list bio-ring))))
(define by0 (apply min (map cdr (vector->list bio-ring))))
(define by1 (apply max (map cdr (vector->list bio-ring))))

;; ray-casting point-in-ring over a vector of (x . y)
(define (in-ring? x y ring)
  (let ((n (vector-length ring)))
    (let loop ((i 0) (inside #f))
      (if (= i n) inside
          (let* ((pi (vector-ref ring i)) (pj (vector-ref ring (modulo (- i 1) n)))
                 (xi (car pi)) (yi (cdr pi)) (xj (car pj)) (yj (cdr pj)))
            (loop (+ i 1)
                  (if (and (not (eq? (> yi y) (> yj y)))
                           (< x (+ (/ (* (- xj xi) (- y yi)) (- yj yi)) xi)))
                      (not inside) inside)))))))

;; ---- Douglas-Peucker (tolerance in degrees), keeps the ring closed ----
(define (perp p a b)
  (let ((x (car p)) (y (cdr p)) (x0 (car a)) (y0 (cdr a)) (x1 (car b)) (y1 (cdr b)))
    (let ((dx (- x1 x0)) (dy (- y1 y0)))
      (if (and (= dx 0) (= dy 0)) (sqrt (+ (expt (- x x0) 2) (expt (- y y0) 2)))
          (let* ((t (max 0 (min 1 (/ (+ (* (- x x0) dx) (* (- y y0) dy)) (+ (* dx dx) (* dy dy))))))
                 (px (+ x0 (* t dx))) (py (+ y0 (* t dy))))
            (sqrt (+ (expt (- x px) 2) (expt (- y py) 2))))))))
(define (dp pts eps)                              ; pts: list of (x . y)
  (if (< (length pts) 3) pts
      (let* ((a (car pts)) (b (last pts)))
        (let loop ((i 1) (rest (cdr pts)) (dmax 0) (idx 0))
          (if (null? (cdr rest))
              (if (> dmax eps)
                  (append (drop-right (dp (take pts (+ idx 1)) eps) 1) (dp (drop pts idx) eps))
                  (list a b))
              (let ((d (perp (car rest) a b)))
                (if (> d dmax) (loop (+ i 1) (cdr rest) d i)
                    (loop (+ i 1) (cdr rest) dmax idx))))))))
(define (simplify-ring ring)                      ; list of (x . y) → simplified, closed, or #f
  (let ((r (dp ring tol)))
    (if (< (length r) 4) #f
        (let ((closed (if (equal? (car r) (last r)) r (append r (list (car r))))))
          (map (lambda (p) (cons (car p) (cdr p))) closed)))))

;; ---- slug: lowercase, runs of non-[a-z0-9] → "-", trimmed ----
(define (slug name)
  (let* ((chars (string->list (string-downcase name)))
         (mapped (map (lambda (c) (if (or (char<=? #\a c #\z) (char<=? #\0 c #\9)) c #\-)) chars))
         (collapsed (let loop ((cs mapped) (out '()) (prev-dash #f))
                      (cond ((null? cs) (reverse out))
                            ((char=? (car cs) #\-) (loop (cdr cs) (if prev-dash out (cons #\- out)) #t))
                            (else (loop (cdr cs) (cons (car cs) out) #f)))))
         (s (list->string collapsed)))
    (string-trim-both s #\-)))

;; ---- signed area: >0 ccw, <0 cw (shapefile exterior rings are cw) ----
(define (signed-area ring)                        ; ring: list of (x . y), closed
  (let loop ((ps ring) (acc 0.0))
    (if (or (null? ps) (null? (cdr ps))) (/ acc 2.0)
        (loop (cdr ps) (+ acc (- (* (car (car ps)) (cdr (cadr ps)))
                                 (* (car (cadr ps)) (cdr (car ps)))))))))

;; ---- organise a shape's part-rings into GeoJSON coordinates (Polygon | MultiPolygon) ----
(define (organize rings)                          ; rings: list of (list of (x . y))
  (let-values (((exts holes) (partition (lambda (r) (< (signed-area r) 0)) rings)))
    (let ((exts (if (null? exts) rings exts))     ; degenerate: treat all as exteriors
          (holes (if (null? exts) '() holes)))
      (if (<= (length exts) 1)
          (cons 'Polygon (list (cons (car exts) holes)))   ; one polygon: exterior + all holes
          (let* ((extvs (map (lambda (e) (cons e (list->vector e))) exts))   ; (ring . vec)
                 (assigned (map (lambda (ev) (list (car ev))) extvs)))       ; each starts [exterior]
            ;; attach each hole to the first exterior containing its first point
            (for-each
             (lambda (h)
               (let* ((p (car h))
                      (idx (list-index (lambda (ev) (in-ring? (car p) (cdr p) (cdr ev))) extvs)))
                 (when idx
                   (let ((cell (list-ref assigned idx)))
                     (set-cdr! (last-pair cell) (list h))))))   ; append hole to that polygon
             holes)
            (cons 'MultiPolygon assigned))))))

;; ---- simplify an organised geometry; drop collapsed rings/polys; Polygon if 1 poly ----
(define (simplify-geom geom)                       ; geom = (type . polys) ; polys = list of (list of rings)
  (let* ((polys (cdr geom))
         (out (filter-map
               (lambda (poly)
                 (let ((rings (filter-map simplify-ring poly)))
                   (and (pair? rings) rings)))
               polys)))
    (cond ((null? out) #f)
          ((= (length out) 1) (cons 'Polygon (car out)))
          (else (cons 'MultiPolygon out)))))

;; ---- .dbf: pull the ECO_NAME column for every record, in file order ----
(define (dbf-names path)
  (let* ((bv (call-with-input-file path get-bytevector-all #:binary #t)))
    (let* ((nrec (bytevector-u32-ref bv 4 (endianness little)))
           (hsize (bytevector-u16-ref bv 8 (endianness little)))
           (rsize (bytevector-u16-ref bv 10 (endianness little))))
      ;; field descriptors: 32 bytes each from offset 32 until 0x0D
      (let loop ((off 32) (col 1) (name-off #f) (name-len #f))  ; col starts at 1 (deletion flag)
        (if (= (bytevector-u8-ref bv off) #x0D)
            (let ((no name-off) (nl name-len))
              (list->vector
               (map (lambda (i)
                      (let* ((rstart (+ hsize (* i rsize) no))
                             (raw (make-bytevector nl)))
                        (bytevector-copy! bv rstart raw 0 nl)
                        (string-trim-both (bytevector->latin1 raw))))
                    (iota nrec))))
            (let* ((fname (bytevector->fieldname bv off))
                   (flen (bytevector-u8-ref bv (+ off 16))))
              (if (string=? fname "ECO_NAME")
                  (loop (+ off 32) (+ col flen) col flen)
                  (loop (+ off 32) (+ col flen) name-off name-len))))))))
(define (bytevector->latin1 bv)                    ; bytes → string, latin-1
  (list->string (map integer->char (bytevector->u8-list bv))))
(define (bytevector->fieldname bv off)             ; 11-byte, null-terminated field name
  (let loop ((i 0) (cs '()))
    (if (or (= i 11) (= (bytevector-u8-ref bv (+ off i)) 0))
        (list->string (reverse cs))
        (loop (+ i 1) (cons (integer->char (bytevector-u8-ref bv (+ off i))) cs)))))

;; ---- .shp: iterate polygon records (bbox-reject early), zip with dbf names ----
(define (read-shapes shp dbf)
  (let* ((bv (call-with-input-file shp get-bytevector-all #:binary #t))
         (names (dbf-names dbf))
         (total (* 2 (bytevector-s32-ref bv 24 (endianness big)))))  ; file length, words→bytes
    (define (d off) (bytevector-ieee-double-ref bv off (endianness little)))
    (define (i32 off) (bytevector-s32-ref bv off (endianness little)))
    (let loop ((off 100) (rec 0) (acc '()))
      (if (>= off total) (reverse acc)
          (let* ((clen (bytevector-s32-ref bv (+ off 4) (endianness big)))  ; content length (words)
                 (c (+ off 8))                     ; content start
                 (shape-type (i32 c))
                 (next (+ c (* 2 clen))))
            (if (not (= shape-type 5))              ; only Polygon (5); skip null/other
                (loop next (+ rec 1) acc)
                (let ((xmin (d (+ c 4))) (ymin (d (+ c 12))) (xmax (d (+ c 20))) (ymax (d (+ c 28))))
                  (if (or (< xmax bx0) (> xmin bx1) (< ymax by0) (> ymin by1))
                      (loop next (+ rec 1) acc)     ; bbox reject
                      (let* ((nparts (i32 (+ c 36)))
                             (npoints (i32 (+ c 40)))
                             (parts-off (+ c 44))
                             (pts-off (+ parts-off (* 4 nparts)))
                             (parts (map (lambda (i) (i32 (+ parts-off (* 4 i)))) (iota nparts)))
                             (points (list->vector
                                      (map (lambda (i) (cons (d (+ pts-off (* 16 i)))
                                                             (d (+ pts-off (* 16 i) 8))))
                                           (iota npoints))))
                             ;; split flat points into rings by part indices
                             (bounds2 (append parts (list npoints)))
                             (rings (map (lambda (a b) (map (lambda (i) (vector-ref points i))
                                                           (iota (- b a) a)))
                                         parts (cdr bounds2))))
                        (loop next (+ rec 1)
                              (cons (list (vector-ref names rec) points rings) acc)))))))))))

;; ---- build the filtered, nested feature collection ----
(define shapes (read-shapes shp-path
                            (string-append (substring shp-path 0 (- (string-length shp-path) 4)) ".dbf")))
(define FRAC 0.35)
(define feats
  (let loop ((ss shapes) (seen '()) (acc '()))
    (if (null? ss) (reverse acc)
        (let* ((s (car ss)) (name (car s)) (points (cadr s)) (rings (caddr s))
               (np (vector-length points))
               (inside (let c ((i 0) (k 0))
                         (if (= i np) k
                             (c (+ i 1) (if (in-ring? (car (vector-ref points i))
                                                      (cdr (vector-ref points i)) bio-ring) (+ k 1) k)))))
               (cx (/ (fold + 0.0 (map car (vector->list points))) np))
               (cy (/ (fold + 0.0 (map cdr (vector->list points))) np))
               (sid (slug name)))
          (cond ((member sid seen) (loop (cdr ss) seen acc))
                ((not (or (in-ring? cx cy bio-ring) (>= (/ inside np) FRAC))) (loop (cdr ss) seen acc))
                (else
                 (let ((geom (simplify-geom (organize rings))))
                   (if geom
                       (loop (cdr ss) (cons sid seen)
                             (cons (list sid name geom) acc))
                       (loop (cdr ss) seen acc)))))))))
(define sorted (sort feats (lambda (a b) (string<? (car a) (car b)))))

;; ---- JSON emit: json.dumps(separators=(",",":"), ensure_ascii=True) equivalent ----
(define (jstr s)                                    ; string → escaped JSON string literal
  (string-append
   "\"" (string-concatenate
         (map (lambda (ch)
                (let ((n (char->integer ch)))
                  (cond ((char=? ch #\") "\\\"") ((char=? ch #\\) "\\\\")
                        ((char=? ch #\backspace) "\\b") ((char=? ch #\page) "\\f")
                        ((char=? ch #\newline) "\\n") ((char=? ch #\return) "\\r")
                        ((char=? ch #\tab) "\\t")
                        ((or (< n 32) (> n 126)) (format #f "\\u~4,'0x" n))
                        (else (string ch)))))
              (string->list s))) "\""))
(define (jnum x)                                    ; Python repr(round(x,4)) for |x|≥ small
  (let ((n (inexact->exact (round (* x 10000)))))
    (if (= n 0) "0.0"
        (let* ((neg (< n 0)) (a (abs n)) (int (quotient a 10000)) (frac (remainder a 10000))
               (fs (format #f "~4,'0d" frac))
               (fs2 (let strip ((s fs)) (if (and (> (string-length s) 1)
                                                 (char=? (string-ref s (- (string-length s) 1)) #\0))
                                            (strip (substring s 0 (- (string-length s) 1))) s))))
          (string-append (if neg "-" "") (number->string int) "." fs2)))))
(define (jpoint p) (string-append "[" (jnum (car p)) "," (jnum (cdr p)) "]"))
(define (jring r) (string-append "[" (string-join (map jpoint r) ",") "]"))
(define (jrings rs) (string-append "[" (string-join (map jring rs) ",") "]"))
(define (jgeom geom)                                ; (type . rings|polys)
  (if (eq? (car geom) 'Polygon)
      (string-append "{\"type\":\"Polygon\",\"coordinates\":" (jrings (cdr geom)) "}")
      (string-append "{\"type\":\"MultiPolygon\",\"coordinates\":["
                     (string-join (map jrings (cdr geom)) ",") "]}")))
(define (jfeat f)
  (let ((sid (car f)) (name (cadr f)) (geom (caddr f)))
    (string-append
     "{\"type\":\"Feature\",\"properties\":{\"id\":" (jstr sid) ",\"name\":" (jstr name)
     ",\"tier\":\"ecoregion\",\"containedIn\":" (jstr bio-id) "},\"geometry\":" (jgeom geom) "}")))

(define note (format #f "RESOLVE Ecoregions 2017 within the ~a bioregion (centroid-in-polygon), simplified ~a° via process-ecoregions.scm; nested containedIn=~a." bio-id tol-s bio-id))
(display (string-append
          "{\"type\":\"FeatureCollection\",\"_note\":" (jstr note)
          ",\"features\":[" (string-join (map jfeat sorted) ",") "]}"))
(newline)
(format (current-error-port) "[~a] ~a ecoregions kept~%" bio-id (length sorted))
