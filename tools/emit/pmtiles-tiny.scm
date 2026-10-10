;;; tools/emit/pmtiles-tiny.scm — write the test fixture tests/fixtures/map/tiny.pmtiles
;;;
;;; A PMTiles v3 archive small enough to commit and complete enough to exercise
;;; the reader: a gzipped root directory with one tile entry and one leaf
;;; entry, a gzipped leaf directory with a run-length entry, and gzipped tile
;;; bodies whose text is the tile's own "z/x/y". Bounds are Berlin.
;;;
;;; Run: guile -L module tools/emit/pmtiles-tiny.scm [out-path]
;;; The browser-side reader test reads the same file, so the two readers are
;;; checked against one artefact.

(use-modules (rnrs bytevectors)
             (ice-9 binary-ports)
             (zlib)
             ((playnet utils pmtiles) #:select (tile-id)))

(define (varint n)
  (let loop ((n n) (acc '()))
    (if (< n #x80)
        (u8-list->bytevector (reverse (cons n acc)))
        (loop (ash n -7) (cons (logior #x80 (logand n #x7f)) acc)))))

(define (cat . bvs)
  (let* ((len (apply + (map bytevector-length bvs)))
         (out (make-bytevector len)))
    (let loop ((bvs bvs) (pos 0))
      (unless (null? bvs)
        (bytevector-copy! (car bvs) 0 out pos (bytevector-length (car bvs)))
        (loop (cdr bvs) (+ pos (bytevector-length (car bvs))))))
    out))

(define (gzip bv)
  (call-with-values open-bytevector-output-port
    (lambda (port get)
      (call-with-zlib-output-port port (lambda (p) (put-bytevector p bv)) #:format 'gzip)
      (get))))

;; entries: list of (id run offset length), sorted by id — encoded per spec:
;; count, ids as deltas, runs, lengths, offsets (0 ⇒ contiguous, else off+1).
(define (encode-directory entries)
  (apply cat
         (varint (length entries))
         (append
          (let loop ((es entries) (prev 0) (acc '()))
            (if (null? es) (reverse acc)
                (loop (cdr es) (car (car es)) (cons (varint (- (car (car es)) prev)) acc))))
          (map (lambda (e) (varint (cadr e))) entries)
          (map (lambda (e) (varint (cadddr e))) entries)
          (let loop ((es entries) (prev #f) (acc '()))
            (if (null? es) (reverse acc)
                (let* ((e (car es))
                       (contiguous? (and prev (= (caddr e) (+ (caddr prev) (cadddr prev))))))
                  (loop (cdr es) e
                        (cons (varint (if contiguous? 0 (+ 1 (caddr e)))) acc))))))))

(define (tile-body z x y) (gzip (string->utf8 (format #f "~a/~a/~a" z x y))))

;; The tiles: 0/0/0 in the root; 1/0/0, 1/0/1 as one run of two (ids 1, 2),
;; 2/1/1 alone, all three in the leaf. 1/1/1 and the rest are holes.
(define t000 (tile-body 0 0 0))
(define t100 (tile-body 1 0 0))        ; shares its run with 1/0/1: same bytes
(define t211 (tile-body 2 1 1))
(define data (cat t000 t100 t211))
(define off-t000 0)
(define off-t100 (bytevector-length t000))
(define off-t211 (+ off-t100 (bytevector-length t100)))

(define leaf
  (gzip (encode-directory
         (list (list (tile-id 1 0 0) 2 off-t100 (bytevector-length t100))
               (list (tile-id 2 1 1) 1 off-t211 (bytevector-length t211))))))

(define root
  (gzip (encode-directory
         (list (list (tile-id 0 0 0) 1 off-t000 (bytevector-length t000))
               ;; run-length 0: a leaf at leaf-section offset 0
               (list (tile-id 1 0 0) 0 0 (bytevector-length leaf))))))

(define metadata
  (gzip (string->utf8 "{\"name\":\"tiny\",\"planetiler:osm:osmosisreplicationtime\":\"2026-10-08T04:00:00Z\"}")))

(define (header root-off root-len meta-off meta-len leaf-off leaf-len data-off data-len)
  (let ((h (make-bytevector 127 0)))
    (bytevector-copy! (string->utf8 "PMTiles") 0 h 0 7)
    (bytevector-u8-set! h 7 3)
    (for-each (lambda (off v) (bytevector-u64-set! h off v (endianness little)))
              '(8 16 24 32 40 48 56 64 72 80 88)
              (list root-off root-len meta-off meta-len leaf-off leaf-len data-off data-len
                    4 3 3))
    (bytevector-u8-set! h 96 1)          ; clustered
    (bytevector-u8-set! h 97 2)          ; internal compression: gzip
    (bytevector-u8-set! h 98 2)          ; tile compression: gzip
    (bytevector-u8-set! h 99 1)          ; tile type: MVT
    (bytevector-u8-set! h 100 0)         ; min zoom
    (bytevector-u8-set! h 101 2)         ; max zoom
    (for-each (lambda (off v) (bytevector-s32-set! h off v (endianness little)))
              '(102 106 110 114 119 123)
              '(130000000 523000000 138000000 527000000 134000000 525000000))
    (bytevector-u8-set! h 118 1)         ; center zoom
    h))

(define out (if (> (length (command-line)) 1)
                (cadr (command-line))
                "tests/fixtures/map/tiny.pmtiles"))

(let* ((root-off 127)
       (meta-off (+ root-off (bytevector-length root)))
       (leaf-off (+ meta-off (bytevector-length metadata)))
       (data-off (+ leaf-off (bytevector-length leaf)))
       (h (header root-off (bytevector-length root) meta-off (bytevector-length metadata)
                  leaf-off (bytevector-length leaf) data-off (bytevector-length data))))
  (call-with-output-file out
    (lambda (p) (put-bytevector p (cat h root metadata leaf data)))
    #:binary #t)
  (format #t "wrote ~a (~a bytes)~%" out (+ 127 (bytevector-length root) (bytevector-length metadata)
                                           (bytevector-length leaf) (bytevector-length data))))
