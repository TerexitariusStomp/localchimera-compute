;;; charts.scm — SVG chart components in SXML for playnet dashboard
;;;
;;; Translated from old/planner/src/lib/components/execution/BufferHealthRunChart.svelte
;;;
;;; Pure functions returning SXML SVG trees.
;;; Hoot/WASM compatible.

(define-module (playnet ui charts)
  #:use-module (srfi srfi-1)
  #:use-module (playnet ddmrp)
  #:use-module (playnet ui components)
  #:export (buffer-health-run-chart))


;;; ── buffer-health-run-chart ───────────────────────────────────────────────────
;;; 30-day polyline chart with zone band fills, threshold lines, axis labels,
;;; colored data points, and summary row.
;;;
;;; ENTRIES: list of alists with 'date, 'pct, 'zone
;;; BZ: buffer zone alist with 'tor, 'toy, 'tog

(define* (buffer-health-run-chart entries bz #:key title (class ""))
  "SVG run chart showing buffer health over time with zone coloring.
   Returns SXML for the complete chart with optional title and summary row."
  (let* (;; Chart geometry
         (W 360) (H 120)
         (PAD-L 36) (PAD-B 20)
         (chart-w (- W PAD-L))
         (chart-h (- H PAD-B))
         ;; Zone thresholds as percentages of TOG
         (tor (alist-ref bz 'tor 0))
         (toy (alist-ref bz 'toy 0))
         (tog (alist-ref bz 'tog 0))
         (tor-pct (if (> tog 0) (* (/ tor tog) 100) 0))
         (toy-pct (if (> tog 0) (* (/ toy tog) 100) 0))
         ;; Scale: max pct drives Y axis
         (max-pct (apply max 120
                         (map (lambda (e) (alist-ref e 'pct 0)) entries)))
         ;; Coordinate functions
         (to-y (lambda (pct) (- chart-h (* (/ pct max-pct) chart-h))))
         (n (length entries))
         (to-x (lambda (i) (+ PAD-L (* (/ i (max 1 (- n 1))) chart-w))))
         ;; Polyline points string
         (points
          (str-join
           (map (lambda (e i)
                  (string-append
                   (number->string (inexact->exact (round (to-x i))))
                   ","
                   (number->string (inexact->exact (round (to-y (alist-ref e 'pct 0)))))))
                entries (iota n))
           " "))
         ;; X-axis ticks (at most 7 labels)
         (x-step (max 1 (ceiling (/ n 6))))
         (x-ticks
          (filter-map
           (lambda (e i)
             (if (or (= (modulo i x-step) 0) (= i (- n 1)))
                 `((x . ,(to-x i))
                   (label . ,(let ((d (alist-ref e 'date "")))
                               (if (>= (string-length d) 5)
                                   (substring d 5)
                                   d)))
                   (i . ,i))
                 #f))
           entries (iota n)))
         ;; Y-axis ticks
         (y-ticks `(((pct . 0)        (label . "0%"))
                    ((pct . ,tor-pct)  (label . ,(fmt-pct tor-pct)))
                    ((pct . ,toy-pct)  (label . ,(fmt-pct toy-pct)))
                    ((pct . 100)       (label . "100%"))))
         ;; Summary counts
         (count-zone
          (lambda (z) (count (lambda (e) (eq? (alist-ref e 'zone) z)) entries)))
         (total (max 1 n))
         (red-days (count-zone 'red))
         (yellow-days (count-zone 'yellow))
         (green-days (count-zone 'green))
         (excess-days (count-zone 'excess))
         (zone-pct (lambda (c) (inexact->exact (round (* (/ c total) 100))))))

    `(div (@ (class ,(string-append "bhrc " class)))
       ;; Optional title
       ,@(if title `((div (@ (class "title")) ,title)) '())
       ;; SVG chart
       (svg (@ (width ,(number->string W))
               (height ,(number->string H))
               (viewBox ,(string-append "0 0 " (number->string W) " " (number->string H)))
               (overflow "visible"))
         ;; Zone band fills (bottom to top: red, yellow, green, excess)
         (rect (@ (x ,(number->string PAD-L))
                  (y ,(number->string (inexact->exact (round (to-y tor-pct)))))
                  (width ,(number->string chart-w))
                  (height ,(number->string (inexact->exact (round (- chart-h (to-y tor-pct))))))
                  (fill "var(--zone-red-fill, rgba(252,88,88,0.12))")))
         (rect (@ (x ,(number->string PAD-L))
                  (y ,(number->string (inexact->exact (round (to-y toy-pct)))))
                  (width ,(number->string chart-w))
                  (height ,(number->string (inexact->exact (round (- (to-y tor-pct) (to-y toy-pct))))))
                  (fill "var(--zone-yellow-fill, rgba(232,176,78,0.12))")))
         (rect (@ (x ,(number->string PAD-L))
                  (y ,(number->string (inexact->exact (round (to-y 100)))))
                  (width ,(number->string chart-w))
                  (height ,(number->string (inexact->exact (round (- (to-y toy-pct) (to-y 100))))))
                  (fill "var(--zone-green-fill, rgba(126,232,162,0.12))")))
         (rect (@ (x ,(number->string PAD-L))
                  (y "0")
                  (width ,(number->string chart-w))
                  (height ,(number->string (inexact->exact (round (to-y 100)))))
                  (fill "var(--zone-excess-fill, rgba(126,179,245,0.12))")))

         ;; Threshold dashed lines
         (line (@ (x1 ,(number->string PAD-L))
                  (y1 ,(number->string (inexact->exact (round (to-y tor-pct)))))
                  (x2 ,(number->string W))
                  (y2 ,(number->string (inexact->exact (round (to-y tor-pct)))))
                  (stroke "var(--zone-red, #fc5858)")
                  (stroke-width "0.5") (stroke-dasharray "3,3") (opacity "0.5")))
         (line (@ (x1 ,(number->string PAD-L))
                  (y1 ,(number->string (inexact->exact (round (to-y toy-pct)))))
                  (x2 ,(number->string W))
                  (y2 ,(number->string (inexact->exact (round (to-y toy-pct)))))
                  (stroke "var(--zone-yellow, #e8b04e)")
                  (stroke-width "0.5") (stroke-dasharray "3,3") (opacity "0.5")))
         (line (@ (x1 ,(number->string PAD-L))
                  (y1 ,(number->string (inexact->exact (round (to-y 100)))))
                  (x2 ,(number->string W))
                  (y2 ,(number->string (inexact->exact (round (to-y 100)))))
                  (stroke "var(--zone-green, #7ee8a2)")
                  (stroke-width "0.5") (stroke-dasharray "3,3") (opacity "0.5")))

         ;; Axes
         (line (@ (x1 ,(number->string PAD-L)) (y1 "0")
                  (x2 ,(number->string PAD-L)) (y2 ,(number->string chart-h))
                  (stroke "currentColor") (opacity "0.2")))
         (line (@ (x1 ,(number->string PAD-L)) (y1 ,(number->string chart-h))
                  (x2 ,(number->string W)) (y2 ,(number->string chart-h))
                  (stroke "currentColor") (opacity "0.2")))

         ;; Y-axis ticks and labels
         ,@(map (lambda (t)
                  (let ((y (inexact->exact (round (to-y (alist-ref t 'pct 0))))))
                    `(g
                       (line (@ (x1 ,(number->string (- PAD-L 3))) (y1 ,(number->string y))
                                (x2 ,(number->string PAD-L)) (y2 ,(number->string y))
                                (stroke "currentColor") (opacity "0.3")))
                       (text (@ (x ,(number->string (- PAD-L 5)))
                                (y ,(number->string (+ y 3)))
                                (text-anchor "end")
                                (font-size "9") (opacity "0.6"))
                         ,(alist-ref t 'label "")))))
                y-ticks)

         ;; X-axis ticks and labels
         ,@(map (lambda (t)
                  (let ((x (inexact->exact (round (alist-ref t 'x 0)))))
                    `(g
                       (line (@ (x1 ,(number->string x)) (y1 ,(number->string chart-h))
                                (x2 ,(number->string x)) (y2 ,(number->string (+ chart-h 3)))
                                (stroke "currentColor") (opacity "0.3")))
                       (text (@ (x ,(number->string x))
                                (y ,(number->string (- H 4)))
                                (text-anchor "middle")
                                (font-size "9") (opacity "0.6"))
                         ,(alist-ref t 'label "")))))
                x-ticks)

         ;; Data polyline
         ,@(if (> n 1)
               `((polyline (@ (points ,points)
                              (fill "none") (stroke "currentColor")
                              (stroke-width "1.5") (stroke-linejoin "round")
                              (opacity "0.5"))))
               '())

         ;; Data points (colored circles)
         ,@(map (lambda (e i)
                  (let ((cx (inexact->exact (round (to-x i))))
                        (cy (inexact->exact (round (to-y (alist-ref e 'pct 0)))))
                        (zone (alist-ref e 'zone 'green)))
                    `(circle (@ (cx ,(number->string cx))
                                (cy ,(number->string cy))
                                (r "3")
                                (fill ,(zone-svg-color zone))))))
                entries (iota n)))

       ;; Summary row
       (div (@ (class "summary"))
         (span (@ (class "zone-stat"))
           ,(zone-badge 'red #:label "Red")
           ,(string-append (number->string red-days) "d ("
                           (number->string (zone-pct red-days)) "%)"))
         (span (@ (class "zone-stat"))
           ,(zone-badge 'yellow #:label "Yellow")
           ,(string-append (number->string yellow-days) "d ("
                           (number->string (zone-pct yellow-days)) "%)"))
         (span (@ (class "zone-stat"))
           ,(zone-badge 'green #:label "Green")
           ,(string-append (number->string green-days) "d ("
                           (number->string (zone-pct green-days)) "%)"))
         ,@(if (> excess-days 0)
               `((span (@ (class "zone-stat"))
                   ,(zone-badge 'excess #:label "Excess")
                   ,(string-append (number->string excess-days) "d ("
                                   (number->string (zone-pct excess-days)) "%)")))
               '())))))
