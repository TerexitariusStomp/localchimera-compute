;;; process-forest.scm — a bioregion's FOREST-COVER fragility state from ESA WorldCover
;;; 10 m (2021, v200). KEY-FREE: reads the public Cloud-Optimized GeoTIFF over HTTP range
;;; requests with a tiny COG reader — (web client) for the ranges, (rnrs bytevectors) for
;;; the TIFF IFD, and libz (via the FFI, as guile-zlib itself does) for the DEFLATE tiles.
;;; No download, no key. GENERAL + reproducible: a pinned dataset + a deterministic window
;;; → the same % every time, any point on Earth. Source: ESA WorldCover (CC-BY 4.0).
;;;
;;;   guile process-forest.scm [LON] [LAT] [LABEL] [HALF_DEG]
;;;   guile process-forest.scm -123.0 45.0 cascadia 0.05

(use-modules (web client) (rnrs bytevectors) (system foreign)
             (ice-9 format) (srfi srfi-1))

(define A (cdr (command-line)))
(define (arg i d) (if (> (length A) i) (list-ref A i) d))
(define lon-s (arg 0 "78.03")) (define lat-s (arg 1 "30.32"))
(define label (arg 2 "doon"))  (define half-s (arg 3 "0.05"))
(define lon (string->number lon-s)) (define lat (string->number lat-s))
(define HALF (string->number half-s))

;; ESA WorldCover 3° tiles, named by the SW corner (floored to a multiple of 3).
(define sw-lat (inexact->exact (* 3 (floor (/ lat 3)))))
(define sw-lon (inexact->exact (* 3 (floor (/ lon 3)))))
(define name (string-append
              (if (>= sw-lat 0) (format #f "N~2,'0d" sw-lat) (format #f "S~2,'0d" (- sw-lat)))
              (if (>= sw-lon 0) (format #f "E~3,'0d" sw-lon) (format #f "W~3,'0d" (- sw-lon)))))
(define URL (string-append
             "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/"
             "ESA_WorldCover_10m_2021_v200_" name "_Map.tif"))

;; one HTTP range read → a bytevector (Guile's `range` is a typed (unit (start . end) …) header).
(define (http-range url start len)
  (call-with-values
      (lambda () (http-get url #:decode-body? #f
                           #:headers (list (cons 'range (cons 'bytes (list (cons start (+ start len -1))))))))
    (lambda (resp body) body)))

;; ---- classic-TIFF COG header (IFD + tile index live at the file front) ----
(define h (http-range URL 0 (expt 2 20)))         ; 1 MB header
(define END (if (= (bytevector-u8-ref h 0) 73) (endianness little) (endianness big)))  ; 'I' = II
(define (u16 off) (bytevector-u16-ref h off END))
(define (u32 off) (bytevector-u32-ref h off END))
(define ifd (u32 4))
(define tags (make-hash-table))                   ; tag → (type count value-field-offset)
(let ((n (u16 ifd)))
  (do ((i 0 (+ i 1))) ((= i n))
    (let ((e (+ ifd 2 (* i 12))))
      (hash-set! tags (u16 e) (list (u16 (+ e 2)) (u32 (+ e 4)) (+ e 8))))))

(define SZ '((1 . 1) (3 . 2) (4 . 4)))            ; TIFF type → byte size (BYTE/SHORT/LONG)
(define (elt off typ) (cond ((= typ 1) (bytevector-u8-ref h off))
                            ((= typ 3) (bytevector-u16-ref h off END))
                            ((= typ 4) (bytevector-u32-ref h off END))))
(define (tag-arr t)                               ; a tag's values (inline if ≤4 bytes, else at offset)
  (let* ((info (hash-ref tags t)) (typ (car info)) (cnt (cadr info)) (voff (caddr info))
         (sz (assv-ref SZ typ)) (base (if (<= (* sz cnt) 4) voff (u32 voff))))
    (map (lambda (i) (elt (+ base (* i sz)) typ)) (iota cnt))))

(define IW (car (tag-arr 256))) (define IH (car (tag-arr 257)))
(define TW (car (tag-arr 322))) (define TH (car (tag-arr 323)))
(define offsets (list->vector (tag-arr 324)))
(define counts  (list->vector (tag-arr 325)))
(define predictor (if (hash-ref tags 317) (car (tag-arr 317)) 1))   ; 2 = horizontal differencing
(define tiles-x (quotient (+ IW TW -1) TW))

;; ---- DEFLATE via libz (the FFI, exactly as guile-zlib does under the hood) ----
(define libz (or (any (lambda (n) (false-if-exception (dynamic-link n)))
                      '("libz" "libz.so.1" "/usr/lib/x86_64-linux-gnu/libz.so.1"))
                 (error "libz not found — install zlib")))
(define c-uncompress (pointer->procedure int (dynamic-func "uncompress" libz)
                                         (list '* '* '* unsigned-long)))
(define (inflate src destsize)                    ; zlib stream → bytevector of known size
  (let ((dest (make-bytevector destsize 0))
        (dl (make-bytevector (sizeof unsigned-long) 0)))
    (bytevector-uint-set! dl 0 destsize (native-endianness) (sizeof unsigned-long))
    (let ((rc (c-uncompress (bytevector->pointer dest) (bytevector->pointer dl)
                            (bytevector->pointer src) (bytevector-length src))))
      (unless (= rc 0) (error "zlib uncompress failed, code" rc))
      dest)))

(define cache (make-hash-table))
(define (tile tx ty)
  (let ((k (cons tx ty)))
    (or (hash-ref cache k)
        (let* ((i (+ (* ty tiles-x) tx))
               (b (inflate (http-range URL (vector-ref offsets i) (vector-ref counts i)) (* TW TH))))
          (when (= predictor 2)                   ; un-difference each row
            (do ((r 0 (+ r 1))) ((= r TH))
              (let ((o (* r TW)))
                (do ((c 1 (+ c 1))) ((= c TW))
                  (bytevector-u8-set! b (+ o c)
                                      (logand (+ (bytevector-u8-ref b (+ o c))
                                                 (bytevector-u8-ref b (+ o c -1))) #xFF))))))
          (hash-set! cache k b) b))))

;; ---- the window: tally class frequencies over [c0,c1)×[r0,r1), clamped ----
(define freq (make-hash-table)) (define order '()) (define total 0)
(define (tally! v)
  (set! total (+ total 1))
  (unless (hash-ref freq v) (set! order (cons v order)))
  (hash-set! freq v (+ 1 (hash-ref freq v 0))))
(define px (/ 3.0 IW))                            ; degrees/pixel; top-left = (sw-lon, sw-lat+3)
(define lon0 sw-lon) (define lat0 (+ sw-lat 3))
(define (tr x) (inexact->exact (truncate x)))
(let ((c0 (max 0 (tr (/ (- lon HALF lon0) px)))) (c1 (min IW (tr (/ (- (+ lon HALF) lon0) px))))
      (r0 (max 0 (tr (/ (- lat0 (+ lat HALF)) px)))) (r1 (min IH (tr (/ (- lat0 (- lat HALF)) px)))))
  (do ((r r0 (+ r 1))) ((>= r r1))
    (let ((ty (quotient r TH)) (ly (remainder r TH)))
      (do ((c c0 (+ c 1))) ((>= c c1))
        (tally! (bytevector-u8-ref (tile (quotient c TW) ty) (+ (* ly TW) (remainder c TW))))))))

(define NAME '((10 . "tree") (20 . "shrub") (30 . "grass") (40 . "crop") (50 . "built")
               (60 . "bare") (70 . "snow") (80 . "water") (90 . "wetland") (95 . "mangrove") (100 . "moss")))
(define T (max total 1))
(define tree (hash-ref freq 10 0))
(define land (let ((l (- total (hash-ref freq 80 0)))) (if (= l 0) T l)))
(define seen (reverse order))                     ; first-seen order (Counter tie-break)
(define top5 (take (sort seen (lambda (a b) (> (hash-ref freq a) (hash-ref freq b)))) ; stable → ties keep first-seen
                   (min 5 (length seen))))
(define (cls-name v) (or (assv-ref NAME v) v))
(define brk (string-join
             (map (lambda (v) (format #f "~a ~a%" (cls-name v)
                                      (inexact->exact (round (/ (* 100 (hash-ref freq v)) T)))))
                  top5) ", "))

(format #t "[~a] ESA WorldCover forest cover (±~a° window at ~a,~a):~%" label half-s lat-s lon-s)
(format #t "  tree cover: ~,1f% of window, ~,1f% of land~%" (/ (* 100.0 tree) T) (/ (* 100.0 tree) land))
(format #t "  land cover: ~a~%" brk)
(format #t "→ the forest fragility STATE (tree-cover fraction) — ESA WorldCover 10 m, key-free.~%")
