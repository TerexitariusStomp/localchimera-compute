;;; comms/card.scm — render a post skeleton to an SVG card (image-only channels).
;;;
;;; Instagram has no text posts (comms/fragility.scm: the rented channel). This
;;; turns a composed, entailment-fenced post into a shareable image so it can go
;;; where the people are. PURE + deterministic — no libraries, no fonts to embed;
;;; it returns an SVG string. Rasterising to JPEG and hosting at a clearnet URL
;;; are the infra half (the image-url-for seam, platforms.scm spawn-instagram) —
;;; a deliberate opsec decision, not code.
;;;
;;; Load as a plain lib (needs only srfi-13 / ice-9 format).

(define-module (playnet planner comms card)
  #:use-module (ice-9 format)
  #:export (xml-escape wrap-text render-post-card))

(use-modules (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define (xml-escape s)
  (string-fold-right
   (lambda (c acc)
     (string-append
      (case c ((#\&) "&amp;") ((#\<) "&lt;") ((#\>) "&gt;") ((#\") "&quot;") (else (string c)))
      acc))
   "" s))

(define (wrap-text text max-chars)
  "Greedy word-wrap TEXT into lines of at most MAX-CHARS characters."
  (let loop ((words (string-split text #\space)) (line "") (lines '()))
    (cond
     ((null? words) (reverse (if (string-null? line) lines (cons line lines))))
     (else
      (let* ((w (car words))
             (cand (if (string-null? line) w (string-append line " " w))))
        (if (<= (string-length cand) max-chars)
            (loop (cdr words) cand lines)
            (loop (cdr words) w (cons line lines))))))))

(define* (render-post-card text #:key (width 1080) (height 1080) (margin 96)
                           (font-size 52) (bg "#0f172a") (fg "#f8fafc"))
  "A square SVG card with TEXT wrapped and vertically centred. Deterministic."
  (let* ((max-chars (max 8 (inexact->exact (floor (/ (- width (* 2 margin)) (* font-size 0.55))))))
         (lines (wrap-text text max-chars))
         (line-h (* font-size 1.3))
         (y0 (- (/ height 2) (/ (* (max 0 (- (length lines) 1)) line-h) 2))))
    (string-append
     (format #f "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"~a\" height=\"~a\" viewBox=\"0 0 ~a ~a\">"
             width height width height)
     (format #f "<rect width=\"~a\" height=\"~a\" fill=\"~a\"/>" width height bg)
     (string-concatenate
      (map (lambda (line i)
             (format #f "<text x=\"~a\" y=\"~a\" font-family=\"sans-serif\" font-size=\"~a\" fill=\"~a\" text-anchor=\"middle\">~a</text>"
                     (/ width 2) (+ y0 (* i line-h)) font-size fg (xml-escape line)))
           lines (iota (length lines))))
     "</svg>")))
