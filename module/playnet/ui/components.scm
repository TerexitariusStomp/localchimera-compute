;;; components.scm — SXML UI component library for playnet dashboard
;;;
;;; Pure functions returning SXML trees for zone badges, buffer bars,
;;; funnels, priority cells, and other DDMRP visualization primitives.
;;;
;;; All components produce standard SXML consumed by the virtual-dom
;;; renderer in browser/repl.scm.
;;;
;;; Hoot/WASM compatible.

(define-module (playnet ui components)
  #:use-module (playnet ddmrp)
  #:export (;; Zone system
            zone-class
            zone-svg-color

            ;; Base components
            zone-badge
            priority-cell
            buffer-zone-bar
            buffer-funnel

            ;; Utility
            clamp
            fmt-num
            fmt-pct
            truncate-id
            str-join))


;;; ── Utilities ─────────────────────────────────────────────────────────────────

(define (str-join strs sep)
  "Join a list of strings with separator SEP.
   Portable fallback — Guile has built-in string-join but Hoot may not."
  (if (null? strs) ""
      (let loop ((rest (cdr strs)) (acc (car strs)))
        (if (null? rest) acc
            (loop (cdr rest) (string-append acc sep (car rest)))))))

(define (clamp v lo hi)
  (max lo (min hi v)))

(define (fmt-num n)
  "Format a number for display — integer if whole, 1 decimal otherwise."
  (if (= n (floor n))
      (number->string (inexact->exact (floor n)))
      (let* ((s (number->string (/ (floor (* n 10)) 10))))
        s)))

(define (fmt-pct n)
  "Format as percentage with 0 decimals."
  (string-append (number->string (inexact->exact (round n))) "%"))

(define (truncate-id id n)
  "Truncate string ID to N characters."
  (if (> (string-length id) n)
      (substring id 0 n)
      id))


;;; ── Zone system ───────────────────────────────────────────────────────────────

(define (zone-class zone)
  "Map a zone symbol to a CSS class string."
  (string-append "zone-" (symbol->string zone)))

(define (zone-svg-color zone)
  "Map a zone symbol to an SVG fill color string."
  (case zone
    ((red)      "#fc5858")
    ((yellow)   "#e8b04e")
    ((green)    "#7ee8a2")
    ((excess)   "#7eb3f5")
    ((stockout) "#a0aec0")
    ((early)    "#63b3ed")
    ((late)     "#fc5858")
    (else       "#a0aec0")))


;;; ── zone-badge ────────────────────────────────────────────────────────────────

(define* (zone-badge zone #:key label pct (class ""))
  "Inline colored badge showing zone name, label, or percentage.
   ZONE: symbol (red, yellow, green, excess, stockout, early, late).
   Optional LABEL string overrides display. Optional PCT number shows as N%."
  (let ((display (cond
                  (label label)
                  (pct (fmt-pct pct))
                  (else (symbol->string zone)))))
    `(span (@ (class ,(string-append "badge " (zone-class zone) " " class)))
       ,display)))


;;; ── priority-cell ─────────────────────────────────────────────────────────────

(define* (priority-cell pct zone #:key (class ""))
  "Zone-colored percentage label for planning table priority column.
   PCT: NFP/TOG * 100 (can be negative). ZONE: symbol."
  (let ((label (if (and (number? pct) (finite? pct))
                   (string-append (fmt-num (* (/ (round (* pct 10)) 10) 1)) "%")
                   "—")))
    `(span (@ (class ,(string-append "pc " (zone-class zone) " " class))
              (title ,(string-append "Priority: " label)))
       ,label)))


;;; ── buffer-zone-bar ───────────────────────────────────────────────────────────

(define* (buffer-zone-bar value tor toy tog
                          #:key (unit "") (show-labels #f)
                                (orientation 'horizontal) (invert #f)
                                (tipping-point #f) (class ""))
  "Segmented bar with zone colors and positioned cursor dot.
   ORIENTATION: 'horizontal or 'vertical.
   INVERT: swap red/green (for capacity utilization bars)."
  (let* ((red-pct   (if (> tog 0) (* (/ tor tog) 100) 0))
         (yellow-pct (if (> tog 0) (* (/ (- toy tor) tog) 100) 0))
         (green-pct  (if (> tog 0) (* (/ (- tog toy) tog) 100) 0))
         (cursor-pct (if (> tog 0) (clamp (* (/ value tog) 100) 0 104) 0))
         (zone (classify-zone value tor toy tog)))
    (if (eq? orientation 'vertical)
        ;; Vertical (funnel): red at bottom, green at top
        `(div (@ (class ,(string-append "bzb vertical " class))
                 (role "meter"))
           (div (@ (class "track vertical"))
             (div (@ (class "seg green") (style ,(string-append "flex:" (fmt-num green-pct)))))
             (div (@ (class "seg yellow") (style ,(string-append "flex:" (fmt-num yellow-pct)))))
             (div (@ (class "seg red") (style ,(string-append "flex:" (fmt-num red-pct)))))
             (div (@ (class "cursor v")
                     (style ,(string-append "bottom:" (fmt-num cursor-pct) "%"))))))
        ;; Horizontal
        `(div (@ (class ,(string-append "bzb horizontal " class))
                 (role "meter"))
           (div (@ (class "track horizontal"))
             ,@(if invert
                   `((div (@ (class "seg green") (style ,(string-append "flex:" (fmt-num red-pct)))))
                     (div (@ (class "seg yellow") (style ,(string-append "flex:" (fmt-num yellow-pct)))))
                     (div (@ (class "seg red") (style ,(string-append "flex:" (fmt-num green-pct))))))
                   `((div (@ (class "seg red") (style ,(string-append "flex:" (fmt-num red-pct)))))
                     (div (@ (class "seg yellow") (style ,(string-append "flex:" (fmt-num yellow-pct)))))
                     (div (@ (class "seg green") (style ,(string-append "flex:" (fmt-num green-pct)))))))
             (div (@ (class "cursor h")
                     (style ,(string-append "left:" (fmt-num cursor-pct) "%"))))
             ,@(if (and tipping-point (> tog 0) (> tipping-point 0) (< tipping-point tog))
                   (let ((tip-pct (clamp (* (/ tipping-point tog) 100) 0 100)))
                     `((div (@ (class "tipping-line")
                               (style ,(string-append "left:" (fmt-num tip-pct) "%"))
                               (title "Tipping point")))))
                   '()))
           ,@(if show-labels
                 `((div (@ (class "labels"))
                     (span "0")
                     (span (@ (style ,(string-append "left:" (fmt-num red-pct) "%"))) "TOR")
                     (span (@ (style ,(string-append "left:" (fmt-num (+ red-pct yellow-pct)) "%"))) "TOY")
                     (span (@ (style "right:0"))
                       ,(string-append "TOG" (if (string=? unit "") "" (string-append " (" unit ")"))))))
                 '())))))


;;; ── buffer-funnel ─────────────────────────────────────────────────────────────

(define* (buffer-funnel bz onhand #:key (height 80) (class ""))
  "Trapezoid-shaped buffer visualization with zone-colored fill.
   BZ: buffer zone alist. ONHAND: current quantity."
  (let* ((tor (alist-ref bz 'tor 0))
         (toy (alist-ref bz 'toy 0))
         (tog (alist-ref bz 'tog 0))
         (status (buffer-status onhand bz))
         (zone (alist-ref status 'zone 'red))
         (pct (if (> tog 0) (inexact->exact (round (* (/ onhand tog) 100))) 0))
         (title-text (string-append (fmt-num onhand) " / " (fmt-num tog)
                                    " (" (number->string pct) "% — "
                                    (symbol->string zone) ")")))
    `(div (@ (class ,(string-append "funnel-wrap " class))
             (style ,(string-append "height:" (number->string height) "px"))
             (title ,title-text))
       (div (@ (class "funnel-shape"))
         ,(buffer-zone-bar onhand tor toy tog #:orientation 'vertical))
       (div (@ (class ,(string-append "funnel-val " (zone-class zone))))
         ,(fmt-num onhand)))))
