;;; playnet/utils/pmtiles.scm — a reader for PMTiles v3 archives.
;;;
;;; A PMTiles archive is one file: a 127-byte header, a root directory, JSON
;;; metadata, leaf directories and the tile data, every section addressed by
;;; offset and length from the header. A directory is a sorted vector of
;;; entries (tile-id run-length offset length); an entry whose run-length is
;;; zero points at a leaf directory instead of a tile. Tile ids lie on a
;;; Hilbert curve, so a tile's neighbours are its neighbours in the file.
;;; Spec: https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
;;;
;;; The one I/O primitive is `archive-bytes`: open, seek, read a range, close.
;;; A lookup opens the file per read and shares no seek state, so the fibers
;;; web backend can answer tiles concurrently from one archive record.
;;;
;;; Directories arrive gzipped (the builders' default) or plain; the archive's
;;; header says which. Tile bodies are handed over AS STORED — gzipped tiles
;;; go to the browser under `Content-Encoding: gzip`, which is the cheapest
;;; path and the one the spec intends.

(define-module (playnet utils pmtiles)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (zlib)
  #:export (pmtiles-open
            pmtiles-path
            pmtiles-tile
            pmtiles-tile-compression
            pmtiles-info
            pmtiles-archives
            tile-id
            decode-directory
            directory-find))

;;; ── Tile ids ──────────────────────────────────────────────────────────────

;; One Hilbert step: rotate the quadrant so the curve stays continuous.
(define (hilbert-rotate n x y rx ry)
  (if (= ry 0)
      (let ((x (if (= rx 1) (- n 1 x) x))
            (y (if (= rx 1) (- n 1 y) y)))
        (values y x))
      (values x y)))

(define (tile-id z x y)
  "The PMTiles id of tile Z/X/Y: every tile of the zooms below it, then its
position on the Hilbert curve of its own zoom."
  (let ((base (let loop ((i 0) (acc 0))
                (if (< i z) (loop (+ i 1) (+ acc (expt 4 i))) acc))))
    (let loop ((s (ash 1 (max 0 (- z 1)))) (x x) (y y) (d 0))
      (if (or (= z 0) (= s 0))
          (+ base d)
          (let* ((rx (if (zero? (logand x s)) 0 1))
                 (ry (if (zero? (logand y s)) 0 1))
                 (d  (+ d (* s s (logxor (* 3 rx) ry)))))
            (call-with-values (lambda () (hilbert-rotate s x y rx ry))
              (lambda (x y) (loop (ash s -1) x y d))))))))

;;; ── Byte helpers ──────────────────────────────────────────────────────────

(define (u64 bv off) (bytevector-u64-ref bv off (endianness little)))
(define (u8  bv off) (bytevector-u8-ref bv off))
(define (s32 bv off) (bytevector-s32-ref bv off (endianness little)))

(define (read-varint bv pos)
  "The LEB128 unsigned integer at POS, and the position after it."
  (let loop ((pos pos) (shift 0) (acc 0))
    (let ((b (u8 bv pos)))
      (if (zero? (logand b #x80))
          (values (logior acc (ash b shift)) (+ pos 1))
          (loop (+ pos 1) (+ shift 7) (logior acc (ash (logand b #x7f) shift)))))))

(define (gunzip bv)
  (call-with-zlib-input-port (open-bytevector-input-port bv) get-bytevector-all
                             #:format (quote gzip)))

;;; ── The archive record ────────────────────────────────────────────────────

(define-record-type <pmtiles>
  (make-pmtiles path root-off root-len leaf-off leaf-len data-off data-len
                internal-compression tile-compression tile-type
                min-zoom max-zoom bounds root leaves)
  pmtiles?
  (path pmtiles-path)
  (root-off pmtiles-root-off) (root-len pmtiles-root-len)
  (leaf-off pmtiles-leaf-off) (leaf-len pmtiles-leaf-len)
  (data-off pmtiles-data-off) (data-len pmtiles-data-len)
  (internal-compression pmtiles-internal-compression)
  (tile-compression pmtiles-tile-compression*)
  (tile-type pmtiles-tile-type)
  (min-zoom pmtiles-min-zoom) (max-zoom pmtiles-max-zoom)
  (bounds pmtiles-bounds)          ; (west south east north), degrees
  (root pmtiles-root)              ; the decoded root directory
  (leaves pmtiles-leaves))         ; offset → decoded leaf directory

(define (archive-bytes a offset length)
  "LENGTH bytes of archive A from OFFSET, or #f past its end."
  (let ((path (if (pmtiles? a) (pmtiles-path a) a)))
    (call-with-input-file path
      (lambda (p)
        (seek p offset SEEK_SET)
        (let ((bv (get-bytevector-n p length)))
          (and (bytevector? bv) (= (bytevector-length bv) length) bv)))
      #:binary #t)))

(define (compression-name code)
  (case code ((1) 'none) ((2) 'gzip) (else #f)))

(define (decode-directory bv)
  "A directory's bytes (already uncompressed) as a vector of entries
#(tile-id run-length offset length), sorted by tile id."
  (let*-values (((n pos) (read-varint bv 0)))
    (let ((ids (make-vector n 0)) (runs (make-vector n 0))
          (lens (make-vector n 0)) (offs (make-vector n 0)))
      (define (read-column! vec pos fold)
        (let loop ((i 0) (pos pos) (prev 0))
          (if (= i n) pos
              (let-values (((v pos) (read-varint bv pos)))
                (let ((v (fold v prev i)))
                  (vector-set! vec i v)
                  (loop (+ i 1) pos v))))))
      (let* ((pos (read-column! ids pos (lambda (v prev i) (+ v prev))))
             (pos (read-column! runs pos (lambda (v prev i) v)))
             (pos (read-column! lens pos (lambda (v prev i) v)))
             (pos (read-column! offs pos
                    (lambda (v prev i)
                      (if (and (zero? v) (> i 0))
                          (+ (vector-ref offs (- i 1)) (vector-ref lens (- i 1)))
                          (- v 1))))))
        (let ((dir (make-vector n #f)))
          (let loop ((i 0))
            (when (< i n)
              (vector-set! dir i (vector (vector-ref ids i) (vector-ref runs i)
                                         (vector-ref offs i) (vector-ref lens i)))
              (loop (+ i 1))))
          dir)))))

(define (directory-find dir id)
  "The entry of DIR holding tile ID — a tile entry whose run covers it, or the
leaf entry it falls under — or #f."
  (let loop ((lo 0) (hi (- (vector-length dir) 1)))
    (if (> lo hi)
        (and (>= hi 0)
             (let ((e (vector-ref dir hi)))
               (and (or (zero? (vector-ref e 1))
                        (< (- id (vector-ref e 0)) (vector-ref e 1)))
                    e)))
        (let* ((k (quotient (+ lo hi) 2))
               (e (vector-ref dir k))
               (c (- id (vector-ref e 0))))
          (cond ((> c 0) (loop (+ k 1) hi))
                ((< c 0) (loop lo (- k 1)))
                (else e))))))

(define (pmtiles-open path)
  "Open the archive at PATH: read its header and root directory. Raises
'pmtiles-error on a file this reader does not serve — bad magic, a version
other than 3, a compression other than none/gzip, a tile type other than
vector (MVT)."
  (define (fail why . args) (throw 'pmtiles-error path why args))
  (let ((h (archive-bytes path 0 127)))
    (unless h (fail "too short for a header"))
    (unless (equal? (utf8->string (let ((m (make-bytevector 7))) (bytevector-copy! h 0 m 0 7) m)) "PMTiles")
      (fail "not a PMTiles archive"))
    (unless (= (u8 h 7) 3) (fail "PMTiles version" (u8 h 7)))
    (let ((ic (compression-name (u8 h 97)))
          (tc (compression-name (u8 h 98))))
      (unless ic (fail "internal compression" (u8 h 97)))
      (unless tc (fail "tile compression" (u8 h 98)))
      (unless (= (u8 h 99) 1) (fail "tile type (vector tiles only)" (u8 h 99)))
      (let* ((root-off (u64 h 8)) (root-len (u64 h 16))
             (raw (archive-bytes path root-off root-len))
             (root (decode-directory (if (eq? ic 'gzip) (gunzip raw) raw))))
        (make-pmtiles path root-off root-len
                      (u64 h 40) (u64 h 48) (u64 h 56) (u64 h 64)
                      ic tc (u8 h 99) (u8 h 100) (u8 h 101)
                      (map (lambda (off) (/ (s32 h off) 1e7)) '(102 106 110 114))
                      root (make-hash-table))))))

(define (leaf-directory a offset length)
  (let ((leaves (pmtiles-leaves a)))
    (or (hash-ref leaves offset)
        (let* ((raw (archive-bytes a (+ (pmtiles-leaf-off a) offset) length))
               (dir (decode-directory
                     (if (eq? (pmtiles-internal-compression a) 'gzip) (gunzip raw) raw))))
          ;; a regional archive has a handful of leaves; a planet has many
          ;; thousands — keep the table bounded either way
          (when (> (hash-count (const #t) leaves) 256) (hash-clear! leaves))
          (hash-set! leaves offset dir)
          dir))))

(define (pmtiles-tile a z x y)
  "The stored bytes of tile Z/X/Y in archive A, or #f when the archive has no
such tile. The spec allows three leaf hops; this follows as many as the
directories chain."
  (and (<= (pmtiles-min-zoom a) z (pmtiles-max-zoom a))
       (let ((id (tile-id z x y)))
         (let loop ((dir (pmtiles-root a)) (hops 0))
           (let ((e (directory-find dir id)))
             (cond ((not e) #f)
                   ((> (vector-ref e 1) 0)
                    (archive-bytes a (+ (pmtiles-data-off a) (vector-ref e 2))
                                   (vector-ref e 3)))
                   ((>= hops 3) #f)
                   (else (loop (leaf-directory a (vector-ref e 2) (vector-ref e 3))
                               (+ hops 1)))))))))

(define (pmtiles-tile-compression a)
  "'gzip or 'none — how the tile bodies of A are stored, hence the
Content-Encoding a server sends them under."
  (pmtiles-tile-compression* a))

(define (pmtiles-info a)
  "What a client needs to know about archive A: its name, extent, zooms and
size, as an alist."
  (let ((path (pmtiles-path a)))
    `((name . ,(basename path ".pmtiles"))
      (bounds . ,(pmtiles-bounds a))
      (min-zoom . ,(pmtiles-min-zoom a))
      (max-zoom . ,(pmtiles-max-zoom a))
      (bytes . ,(stat:size (stat path))))))

;;; ── The archive directory ─────────────────────────────────────────────────

;; path → (mtime size . archive); an archive dropped into the directory is
;; served by the next request, a replaced one is reopened.
(define %open-archives (make-hash-table))

(define (pmtiles-archives dir)
  "Every readable *.pmtiles archive under DIR, sorted by name. An unreadable
file is skipped (and reported once per change) rather than failing the rest."
  (let ((names (or (scandir dir (lambda (n) (string-suffix? ".pmtiles" n))) '())))
    (filter-map
     (lambda (name)
       (let* ((path (string-append dir "/" name))
              (st (stat path #f))
              (key (and st (cons (stat:mtime st) (stat:size st))))
              (hit (hash-ref %open-archives path)))
         (cond ((not st) #f)
               ((and hit (equal? (car hit) key)) (cdr hit))
               (else
                (let ((a (catch 'pmtiles-error
                           (lambda () (pmtiles-open path))
                           (lambda (_ path why . args)
                             (format (current-error-port)
                                     "pmtiles: skipping ~a: ~a~a~%" path why
                                     (if (null? args) "" (format #f " ~a" args)))
                             #f))))
                  (hash-set! %open-archives path (cons key a))
                  a)))))
     (sort names string<?))))
