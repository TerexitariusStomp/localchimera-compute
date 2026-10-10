;;; matching/h3-ffi.scm — H3 backend via Hoot FFI to h3-js.
;;;
;;; Provides a real <h3-backend> (defined in spatial.scm) backed by
;;; the h3-js library in the browser. The "h3" import namespace must
;;; be wired in the JS host (browser/repl.js) before these are called.

(define-module (playnet matching h3-ffi)
  #:use-module (hoot ffi)
  #:use-module (playnet matching spatial)
  #:export (make-h3-js-backend
            install-h3-backend!))


;;; ── Foreign declarations ────────────────────────────────────────────────────

(define-foreign %lat-lng->cell  "h3" "latLngToCell"
  f64 f64 i32 -> (ref string))
(define-foreign %get-resolution "h3" "getResolution"
  (ref string) -> i32)
(define-foreign %grid-disk      "h3" "gridDisk"
  (ref string) i32 -> (ref null extern))
(define-foreign %cell-to-parent "h3" "cellToParent"
  (ref string) i32 -> (ref string))
(define-foreign %cell-to-lat-lng "h3" "cellToLatLng"
  (ref string) -> (ref null extern))
(define-foreign %grid-distance  "h3" "gridDistance"
  (ref string) (ref string) -> i32)

(define-foreign js-array-length    "array" "length"
  (ref null extern) -> i32)
(define-foreign js-array-ref-string "array" "refString"
  (ref null extern) i32 -> (ref string))
(define-foreign js-array-ref-f64    "array" "refF64"
  (ref null extern) i32 -> f64)


;;; ── JS array → Scheme list ──────────────────────────────────────────────────

(define (js-strings->list arr)
  (let ((n (js-array-length arr)))
    (let loop ((i 0) (acc '()))
      (if (>= i n) (reverse acc)
          (loop (+ i 1) (cons (js-array-ref-string arr i) acc))))))


;;; ── Backend ─────────────────────────────────────────────────────────────────

(define (make-h3-js-backend)
  (make-h3-backend
   #:lat-lng->cell   %lat-lng->cell
   #:get-resolution  %get-resolution
   #:grid-disk       (lambda (cell k) (js-strings->list (%grid-disk cell k)))
   #:cell-to-parent  %cell-to-parent
   #:cell-to-lat-lng (lambda (cell)
                       (let ((a (%cell-to-lat-lng cell)))
                         (cons (js-array-ref-f64 a 0)
                               (js-array-ref-f64 a 1))))
   #:grid-distance   (lambda (a b)
                       (let ((d (%grid-distance a b)))
                         (and (>= d 0) d)))))

(define (install-h3-backend!)
  (*h3-backend* (make-h3-js-backend)))
