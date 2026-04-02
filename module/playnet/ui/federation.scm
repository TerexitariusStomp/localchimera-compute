;;; federation.scm — Federation page components in SXML
;;;
;;; Translated from:
;;;   old/planner/src/lib/components/federation/FederationGraphView.svelte
;;;   old/planner/src/lib/components/federation/FederationEventLog.svelte
;;;   old/planner/src/lib/components/federation/InventoryBand.svelte
;;;
;;; All functions are pure: data in, SXML out. No DOM mutation.
;;; Hoot/WASM compatible.

(define-module (playnet ui federation)
  #:use-module (srfi srfi-1)
  #:use-module (playnet ddmrp)
  #:use-module (playnet ui components)
  #:use-module (playnet ui network)
  #:export (;; Graph
            federation-graph-view

            ;; Event log
            federation-event-log

            ;; Inventory band
            inventory-band

            ;; Detail panel
            scope-detail-panel
            deficit-residual-bar

            ;; Composed page
            federation-page

            ;; Helpers (exported for testing)
            spec-color
            hex-points
            trade-arc-path
            trade-label-pos))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  UTILITIES
;;; ═══════════════════════════════════════════════════════════════════════════════

(define pi 3.141592653589793)

(define (n->s n)
  "Number to string, rounding to 1 decimal for coordinates."
  (let ((r (/ (round (* n 10)) 10)))
    (number->string (if (= r (floor r)) (inexact->exact (floor r)) r))))

(define (spec-color id)
  "Deterministic HSL color from a string (spec ID -> consistent hue)."
  (let loop ((i 0) (h 0))
    (if (>= i (string-length id))
        (string-append "hsl(" (number->string (modulo h 360)) ", 62%, 58%)")
        (loop (+ i 1)
              (modulo (+ (* h 31) (char->integer (string-ref id i))) 65536)))))

(define (zone-svg-fill zone)
  "Zone symbol to SVG fill color."
  (case zone
    ((red)    "#fc5858")
    ((yellow) "#e8b04e")
    ((excess) "#7eb3f5")
    (else     "#7ee8a2")))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  FEDERATION GRAPH VIEW
;;; ═══════════════════════════════════════════════════════════════════════════════

;;; Data representation:
;;;   scope:  ((id . "commune-grain") (parent . "agri-federation") (role . leaf))
;;;   result: ((id . "commune-grain") (surplus-qty . 670) (deficit-count . 0)
;;;            (total-orig . 100) (total-short . 0) (has-deficits . #f))
;;;   trade:  ((id . "t1") (from . "commune-grain") (to . "commune-dairy")
;;;            (spec . "wheat") (qty . 50) (buffer-zone . red))
;;;   buffer: ((spec-id . "wheat") (zone . green) (onhand . 35)
;;;            (tor . 10) (toy . 25) (tog . 40))
;;;   resource: ((id . "r1") (conforms-to . "wheat") (name . "Wheat Reserve")
;;;              (onhand . 670) (unit . "kg"))

(define *trade-colors*
  '#("#63b3ed" "#f6ad55" "#b794f4" "#4fd1c5" "#f687b3" "#7ee8a2"))

(define (trade-color-ref idx)
  (vector-ref *trade-colors* (modulo idx (vector-length *trade-colors*))))

;; ── Node role detection ─────────────────────────────────────────────────────

(define (node-role scope scopes)
  "Determine role: 'root, 'federation, or 'leaf."
  (let ((parent (alist-ref scope 'parent #f)))
    (cond
     ((not parent) 'root)
     ((any (lambda (s) (equal? (alist-ref s 'parent) (alist-ref scope 'id)))
           scopes) 'federation)
     (else 'leaf))))

;; ── Radial layout ───────────────────────────────────────────────────────────

(define (compute-positions scopes svg-width svg-height)
  "Compute radial positions for all scopes.
   Returns alist mapping scope-id -> (x . y)."
  (let* ((cx (/ svg-width 2))
         (cy (+ (/ svg-height 2) 14))
         (root (find (lambda (s) (not (alist-ref s 'parent #f))) scopes))
         (root-id (and root (alist-ref root 'id)))
         (feds (filter (lambda (s) (equal? (alist-ref s 'parent) root-id)) scopes))
         (R1 (min (* svg-width 0.24) (* svg-height 0.23)))
         (R2 (min (* svg-width 0.46) (* svg-height 0.43)))
         (com-spread (/ pi 6.5)))
    (let loop ((feds-left feds) (fi 0) (pos (if root `((,root-id . (,cx . ,cy))) '())))
      (if (null? feds-left)
          pos
          (let* ((fed (car feds-left))
                 (fid (alist-ref fed 'id))
                 (nfeds (length feds))
                 (angle (+ (- (/ pi 2)) (* (/ (* 2 pi) nfeds) fi)))
                 (fx (+ cx (* R1 (cos angle))))
                 (fy (+ cy (* R1 (sin angle))))
                 (communes (filter (lambda (s) (equal? (alist-ref s 'parent) fid)) scopes))
                 (ncom (length communes))
                 (com-pos
                  (let cloop ((cs communes) (ci 0) (acc '()))
                    (if (null? cs) acc
                        (let* ((cid (alist-ref (car cs) 'id))
                               (offset (if (> ncom 1)
                                           (* (- ci (/ (- ncom 1) 2)) com-spread 2.2)
                                           0))
                               (ca (+ angle offset))
                               (cxx (+ cx (* R2 (cos ca))))
                               (cyy (+ cy (* R2 (sin ca)))))
                          (cloop (cdr cs) (+ ci 1) (cons (cons cid (cons cxx cyy)) acc)))))))
            (loop (cdr feds-left)
                  (+ fi 1)
                  (append pos (list (cons fid (cons fx fy))) com-pos)))))))

;; ── Hexagon geometry ────────────────────────────────────────────────────────

(define (hex-points rx ry)
  "Generate SVG polygon points string for a hexagon with radii rx, ry."
  (str-join
   (map (lambda (pair)
          (string-append (n->s (car pair)) "," (n->s (cdr pair))))
        (list (cons (- rx) 0) (cons (* rx -0.5) (- ry))
              (cons (* rx 0.5) (- ry)) (cons rx 0)
              (cons (* rx 0.5) ry) (cons (* rx -0.5) ry)))
   " "))

(define (hex-rx role)
  (case role ((root) 105) ((federation) 92) (else 88)))

(define (hex-ry role)
  (case role ((root) 50) ((federation) 43) (else 40)))

(define (card-dims role)
  (case role ((root) '(160 . 72)) ((federation) '(140 . 62)) (else '(130 . 80))))

;; ── Display helpers ─────────────────────────────────────────────────────────

(define (display-lines id)
  "Return (line1 . line2-or-#f) for a scope name."
  (cond
   ((equal? id "universal-commune") (cons "UNIVERSAL" "COMMUNE"))
   ((string-suffix? "-federation" id)
    (cons (string-upcase* (string-drop-right id 11)) "FEDERATION"))
   ((string-prefix? "commune-" id)
    (cons (string-upcase* (substring id 8)) #f))
   (else (cons (string-upcase* id) #f))))

(define (string-upcase* s)
  (list->string (map char-upcase (string->list s))))

(define (string-suffix? suffix s)
  (let ((sl (string-length suffix)) (ll (string-length s)))
    (and (>= ll sl) (string=? (substring s (- ll sl)) suffix))))

(define (string-prefix? prefix s)
  (let ((pl (string-length prefix)))
    (and (>= (string-length s) pl) (string=? (substring s 0 pl) prefix))))

(define (string-drop-right s n)
  (substring s 0 (- (string-length s) n)))

(define (node-stroke id role result has-trade selected)
  (cond
   ((and result (alist-ref result 'has-deficits #f)) "#7ee8a2")
   ((eq? role 'root) "rgba(120,195,255,0.85)")
   ((eq? role 'federation) "rgba(160,210,255,0.40)")
   (has-trade "rgba(120,195,255,0.60)")
   (else "rgba(160,210,255,0.26)")))

(define (node-fill id selected)
  (cond
   ((equal? id selected) "#1d3358")
   (else "#161f33")))

;; ── Trade arc paths (quadratic Bezier) ──────────────────────────────────────

(define (trade-arc-path positions svg-width svg-height from-id to-id)
  "Quadratic bezier arc from FROM-ID to TO-ID, pushed outward from center."
  (let* ((f (assoc from-id positions equal?))
         (t (assoc to-id positions equal?)))
    (if (or (not f) (not t)) ""
        (let* ((fx (cadr f)) (fy (cddr f))
               (tx (cadr t)) (ty (cddr t))
               (cx (/ svg-width 2)) (cy (+ (/ svg-height 2) 14))
               (mx (/ (+ fx tx) 2)) (my (/ (+ fy ty) 2))
               (dx (- mx cx)) (dy (- my cy))
               (len (let ((d (sqrt (+ (* dx dx) (* dy dy))))) (if (= d 0) 1 d)))
               (chord (sqrt (+ (expt (- fx tx) 2) (expt (- fy ty) 2))))
               (push (+ (* chord 0.3) 55))
               (qx (+ mx (* (/ dx len) push)))
               (qy (+ my (* (/ dy len) push))))
          (string-append "M " (n->s fx) " " (n->s fy)
                         " Q " (n->s qx) " " (n->s qy)
                         " " (n->s tx) " " (n->s ty))))))

(define (trade-label-pos positions svg-width svg-height from-id to-id)
  "Position for trade label at arc midpoint."
  (let* ((f (assoc from-id positions equal?))
         (t (assoc to-id positions equal?)))
    (if (or (not f) (not t)) #f
        (let* ((fx (cadr f)) (fy (cddr f))
               (tx (cadr t)) (ty (cddr t))
               (cx (/ svg-width 2)) (cy (+ (/ svg-height 2) 14))
               (mx (/ (+ fx tx) 2)) (my (/ (+ fy ty) 2))
               (dx (- mx cx)) (dy (- my cy))
               (len (let ((d (sqrt (+ (* dx dx) (* dy dy))))) (if (= d 0) 1 d)))
               (chord (sqrt (+ (expt (- fx tx) 2) (expt (- fy ty) 2))))
               (push (+ (* chord 0.3) 55)))
          (cons (+ mx (* (/ dx len) push))
                (+ my (* (/ dy len) push)))))))

;; ── SVG arrow marker defs ───────────────────────────────────────────────────

(define (arrow-marker-defs)
  "Generate <defs> with arrow markers for trade arcs."
  `(defs
     ,@(map (lambda (i)
              (let ((color (trade-color-ref i)))
                `(marker (@ (id ,(string-append "tarrow-" (number->string i)))
                            (markerWidth "7") (markerHeight "7")
                            (refX "6") (refY "3.5") (orient "auto"))
                   (path (@ (d "M0,0 L7,3.5 L0,7 Z") (fill ,color) (opacity "0.9"))))))
            (iota (vector-length *trade-colors*)))
     ;; Zone-colored arrowheads
     ,@(map (lambda (pair)
              `(marker (@ (id ,(string-append "barrow-" (car pair)))
                          (markerWidth "7") (markerHeight "7")
                          (refX "6") (refY "3.5") (orient "auto"))
                 (path (@ (d "M0,0 L7,3.5 L0,7 Z") (fill ,(cdr pair)) (opacity "0.9")))))
            '(("red" . "#fc5858") ("yellow" . "#e8b04e")
              ("green" . "#7ee8a2") ("excess" . "#7eb3f5")))))

;; ── Render a single node ────────────────────────────────────────────────────

(define (render-node scope scopes results trades resources-by-scope buffers-by-scope
                     positions selected on-select svg-width svg-height)
  "Render a single node in the graph. Returns SXML <g> element."
  (let* ((id (alist-ref scope 'id))
         (pos (assoc id positions equal?))
         (px (if pos (cadr pos) 0))
         (py (if pos (cddr pos) 0))
         (role (node-role scope scopes))
         (result (assoc id results equal?))
         (result-data (if result (cdr result) #f))
         (lines (display-lines id))
         (line1 (car lines)) (line2 (cdr lines))
         (is-selected (equal? id selected))
         (has-trade (any (lambda (t) (or (equal? (alist-ref t 'from) id)
                                         (equal? (alist-ref t 'to) id))) trades))
         (surplus-qty (if result-data (alist-ref result-data 'surplus-qty 0) 0))
         (def-count (if result-data (alist-ref result-data 'deficit-count 0) 0))
         (total-orig (if result-data (alist-ref result-data 'total-orig 0) 0))
         (total-short (if result-data (alist-ref result-data 'total-short 0) 0))
         (w (car (card-dims role)))
         (resolved-w (if (> total-orig 0)
                         (* (/ (- total-orig total-short) total-orig) (- w 14))
                         0))
         (scope-res (or (assoc id resources-by-scope equal?) '()))
         (scope-res-list (if (pair? scope-res) (cdr scope-res) '()))
         (scope-bufs (let ((b (assoc id buffers-by-scope equal?)))
                       (if b (cdr b) '()))))
    `(g (@ (transform ,(string-append "translate(" (n->s px) "," (n->s py) ")"))
           (style "cursor:pointer")
           ,@(if on-select
                 `((click ,(lambda (e) (on-select id e))))
                 '()))

       ;; Hexagon background
       (polygon (@ (points ,(hex-points (hex-rx role) (hex-ry role)))
                   (fill ,(node-fill id selected))
                   (stroke ,(node-stroke id role result-data has-trade selected))
                   (stroke-width ,(if is-selected "2" (if (eq? role 'root) "1.5" "1")))
                   ,@(if (eq? role 'federation)
                         '((stroke-dasharray "5 3"))
                         '())))

       ,@(cond
          ;; ── Root node ─────────────────────────────────────────────
          ((eq? role 'root)
           (let ((nfeds (count (lambda (s) (eq? (node-role s scopes) 'federation)) scopes)))
             `((text (@ (x "0") (y "-10") (text-anchor "middle") (class "node-name root-name"))
                 ,line1)
               (text (@ (x "0") (y "8") (text-anchor "middle") (class "node-sub"))
                 ,(or line2 ""))
               (text (@ (x "0") (y "24") (text-anchor "middle") (class "node-stat dim-txt"))
                 ,(string-append (number->string nfeds) " federations")))))

          ;; ── Federation node ───────────────────────────────────────
          ((eq? role 'federation)
           (let* ((kids (filter (lambda (s) (equal? (alist-ref s 'parent) id)) scopes))
                  (nkids (length kids))
                  (coherent (count (lambda (s)
                                     (let ((r (assoc (alist-ref s 'id) results equal?)))
                                       (or (not r) (not (alist-ref (cdr r) 'has-deficits #f)))))
                                   kids))
                  (coherence (if (> nkids 0) (/ coherent nkids) 1))
                  (pie-r 11) (pie-cy 26)
                  (pie-angle (* coherence 2 pi))
                  (pie-end-x (* pie-r (sin pie-angle)))
                  (pie-end-y (- pie-cy (* pie-r (cos pie-angle))))
                  (pie-large (if (> coherence 0.5) 1 0)))
             `((text (@ (x "0") (y "-7") (text-anchor "middle") (class "node-name fed-name"))
                 ,line1)
               (text (@ (x "0") (y "8") (text-anchor "middle") (class "node-sub"))
                 ,(or line2 ""))
               ;; Coherence pie background
               (circle (@ (cx "0") (cy ,(n->s pie-cy)) (r ,(n->s pie-r))
                          (fill "rgba(255,255,255,0.04)")
                          (stroke "rgba(255,255,255,0.14)") (stroke-width "0.5")))
               ;; Coherence fill
               ,@(cond
                  ((>= coherence 1)
                   `((circle (@ (cx "0") (cy ,(n->s pie-cy)) (r ,(n->s pie-r))
                                (fill "rgba(126,232,162,0.30)")))))
                  ((> coherence 0)
                   `((path (@ (d ,(string-append
                                   "M 0 " (n->s pie-cy)
                                   " L 0 " (n->s (- pie-cy pie-r))
                                   " A " (n->s pie-r) " " (n->s pie-r)
                                   " 0 " (number->string pie-large)
                                   " 1 " (n->s pie-end-x) " " (n->s pie-end-y) " Z"))
                              (fill "rgba(126,232,162,0.30)")))))
                  (else '()))
               (text (@ (x "0") (y ,(n->s (+ pie-cy 4)))
                        (text-anchor "middle") (class "pie-pct"))
                 ,(string-append (number->string (inexact->exact (round (* coherence 100)))) "%")))))

          ;; ── Leaf commune ──────────────────────────────────────────
          (else
           (let* ((trade-idx (list-index (lambda (t) (equal? (alist-ref t 'from) id)) trades))
                  (trade-idx2 (or trade-idx
                                  (list-index (lambda (t) (equal? (alist-ref t 'to) id)) trades)))
                  (trade-clr (and trade-idx2 (trade-color-ref trade-idx2))))
             `(;; Trade accent dot
               ,@(if trade-clr
                     `((circle (@ (cx "60") (cy "-22") (r "4")
                                  (fill ,trade-clr) (opacity "0.5"))))
                     '())
               ;; Name
               (text (@ (x "0") (y "-6") (text-anchor "middle") (class "node-name leaf-name"))
                 ,line1)
               ;; Resource squares
               ,@(if (not (null? scope-res-list))
                     (let* ((sq-size 6) (sq-gap 2)
                            (n (length scope-res-list))
                            (total-w (+ (* n sq-size) (* (- n 1) sq-gap)))
                            (start-x (- (/ total-w 2))))
                       (map (lambda (res ri)
                              (let ((rid (alist-ref res 'id ""))
                                    (cto (alist-ref res 'conforms-to "")))
                                `(rect (@ (x ,(n->s (+ start-x (* ri (+ sq-size sq-gap)))))
                                          (y "18") (width ,(n->s sq-size)) (height ,(n->s sq-size))
                                          (rx "1") (fill ,(spec-color cto)) (opacity "0.82"))
                                   (title ,(string-append cto " " (n->s (alist-ref res 'onhand 0))
                                                          " " (alist-ref res 'unit ""))))))
                            scope-res-list (iota n)))
                     '())
               ;; Surplus label
               ,@(if (> surplus-qty 0)
                     `((text (@ (x "-62") (y "22") (class "node-stat green-txt"))
                         ,(string-append "+" (n->s (round surplus-qty)))))
                     '())
               ;; Deficit badge
               ,@(cond
                  ((> def-count 0)
                   `((rect (@ (x "20") (y "-28") (width "30") (height "13") (rx "2")
                              (fill "rgba(252,88,88,0.30)")))
                     (text (@ (x "35") (y "-19") (text-anchor "middle")
                              (class "badge-txt") (fill "#fc5858"))
                       ,(string-append (number->string def-count) "D"))))
                  ((and result-data (> total-orig 0))
                   `((rect (@ (x "20") (y "-28") (width "30") (height "13") (rx "2")
                              (fill "rgba(126,232,162,0.20)")))
                     (text (@ (x "35") (y "-19") (text-anchor "middle")
                              (class "badge-txt") (fill "#7ee8a2"))
                       "\u2713")))  ;; checkmark
                  (else '()))
               ;; Residual resolution bar
               ,@(if (and result-data (> total-orig 0))
                     `((rect (@ (x "-72") (y "6") (width "144") (height "4") (rx "2")
                                (fill "rgba(140,180,255,0.12)")))
                       ,@(if (> resolved-w 0)
                             `((rect (@ (x "-72") (y "6")
                                        (width ,(n->s resolved-w)) (height "4") (rx "2")
                                        (fill "#7ee8a2") (opacity "0.85"))))
                             '())
                       ,@(if (< resolved-w (- w 14))
                             `((rect (@ (x ,(n->s (+ -72 resolved-w))) (y "6")
                                        (width ,(n->s (- w 14 resolved-w))) (height "4") (rx "2")
                                        (fill "#fc5858") (opacity "0.60"))))
                             '()))
                     '())
               ;; Buffer zone pips
               ,@(if (not (null? scope-bufs))
                     (let* ((pip-w 10) (pip-gap 3)
                            (n (length scope-bufs))
                            (total-pip-w (+ (* n pip-w) (* (- n 1) pip-gap)))
                            (pip-x (- (/ total-pip-w 2))))
                       (map (lambda (buf bi)
                              (let ((z (alist-ref buf 'zone 'green)))
                                `(rect (@ (x ,(n->s (+ pip-x (* bi (+ pip-w pip-gap)))))
                                          (y "30") (width ,(n->s pip-w)) (height "5") (rx "1.5")
                                          (fill ,(zone-svg-fill z)) (opacity "0.82"))
                                   (title ,(string-append (alist-ref buf 'spec-id "")
                                                          ": " (n->s (alist-ref buf 'onhand 0))
                                                          "/" (n->s (alist-ref buf 'tog 0))
                                                          " (" (symbol->string z) ")")))))
                            scope-bufs (iota n)))
                     '()))))))))

;; ── Main graph view ─────────────────────────────────────────────────────────

(define* (federation-graph-view scopes results trades
                                #:key (resources-by-scope '())
                                      (buffers-by-scope '())
                                      (selected "")
                                      on-select
                                      (svg-width 1100) (svg-height 720))
  "Render the full federation radial network graph as SXML SVG.
   SCOPES: list of scope alists with 'id, 'parent.
   RESULTS: alist mapping scope-id -> result alist.
   TRADES: list of trade alists with 'id, 'from, 'to, 'spec, 'qty, 'buffer-zone."
  (let* ((positions (compute-positions scopes svg-width svg-height))
         ;; Hierarchy edges
         (hier-edges
          (filter-map (lambda (s)
                        (let ((p (alist-ref s 'parent #f))
                              (id (alist-ref s 'id)))
                          (and p (assoc p positions equal?)
                               (assoc id positions equal?)
                               (cons p id))))
                      scopes)))
    `(svg (@ (width ,(n->s svg-width)) (height ,(n->s svg-height))
             (viewBox ,(string-append "0 0 " (n->s svg-width) " " (n->s svg-height)))
             (class "net-svg"))
       ;; Defs (arrow markers)
       ,(arrow-marker-defs)

       ;; ── Hierarchy edges (bottom layer) ───────────────────────────
       ,@(map (lambda (edge)
                (let* ((f (assoc (car edge) positions equal?))
                       (t (assoc (cdr edge) positions equal?)))
                  (if (and f t)
                      `(path (@ (d ,(string-append
                                     "M " (n->s (cadr f)) " " (n->s (cddr f))
                                     " L " (n->s (cadr t)) " " (n->s (cddr t))))
                                (stroke "rgba(130,175,255,0.18)")
                                (stroke-width "1") (fill "none")))
                      `(g))))
              hier-edges)

       ;; ── Trade arcs ───────────────────────────────────────────────
       ,@(append-map
          (lambda (trade idx)
            (let* ((from-id (alist-ref trade 'from))
                   (to-id (alist-ref trade 'to))
                   (spec (alist-ref trade 'spec ""))
                   (qty (alist-ref trade 'qty 0))
                   (buf-zone (alist-ref trade 'buffer-zone #f))
                   (is-buf (symbol? buf-zone))
                   (color (if is-buf (zone-svg-fill buf-zone) (trade-color-ref idx)))
                   (path (trade-arc-path positions svg-width svg-height from-id to-id))
                   (lp (trade-label-pos positions svg-width svg-height from-id to-id)))
              (if (string=? path "") '()
                  `(;; Arc path
                    (path (@ (d ,path) (stroke ,color)
                             (stroke-width ,(if is-buf "2" "1.5"))
                             (fill "none")
                             (stroke-dasharray ,(if is-buf "none" "6 3"))
                             (opacity ,(if is-buf "0.85" "0.72"))
                             (marker-end ,(if is-buf
                                              (string-append "url(#barrow-" (symbol->string buf-zone) ")")
                                              (string-append "url(#tarrow-" (number->string (modulo idx 6)) ")")))
                             (class ,(if is-buf "buffer-fill-arc" "trade-arc"))))
                    ;; Label
                    ,@(if lp
                          (let ((lx (car lp)) (ly (cdr lp)))
                            `((rect (@ (x ,(n->s (- lx 32))) (y ,(n->s (- ly 9)))
                                       (width "64") (height "16") (rx "2")
                                       (fill "#111e30") (stroke ,color)
                                       (stroke-width "0.5") (opacity "0.95")))
                              (text (@ (x ,(n->s lx)) (y ,(n->s (+ ly 3)))
                                       (text-anchor "middle") (class "trade-lbl") (fill ,color))
                                ,(string-append (if is-buf "\u25a3 " "")
                                                spec " \u00d7" (n->s qty)))))
                          '())))))
          trades (iota (length trades)))

       ;; ── Nodes (top layer) ────────────────────────────────────────
       ,@(map (lambda (scope)
                (render-node scope scopes results trades
                             resources-by-scope buffers-by-scope
                             positions selected on-select
                             svg-width svg-height))
              scopes))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  FEDERATION EVENT LOG
;;; ═══════════════════════════════════════════════════════════════════════════════

(define *round-labels*
  '((0 . "PASS 0  BOTTOM-UP")
    (1 . "PASS 1  LATERAL")
    (2 . "PASS 2  RESIDUALS")))

(define (event-icon kind)
  (case kind
    ((scope-planned)        "\u25c6")   ;; ◆
    ((scope-cached)         "\u25cb")   ;; ○
    ((deficit-announced)    "\u25bd")   ;; ▽
    ((surplus-offered)      "\u25b3")   ;; △
    ((lateral-match)        "\u21c4")   ;; ⇄
    ((deficit-propagated)   "\u2191")   ;; ↑
    ((residual-unresolved)  "\u2715")   ;; ✕
    ((sacrifice-rebalanced) "\u2696")   ;; ⚖
    (else "\u00b7")))

(define (event-color kind)
  (case kind
    ((scope-planned)        "rgba(255,255,255,0.45)")
    ((scope-cached)         "rgba(255,255,255,0.2)")
    ((deficit-announced)    "#e53e3e")
    ((surplus-offered)      "#68d391")
    ((lateral-match)        "#63b3ed")
    ((deficit-propagated)   "#d69e2e")
    ((residual-unresolved)  "#fc8181")
    ((sacrifice-rebalanced) "#b794f4")
    (else "rgba(255,255,255,0.3)")))

(define (group-by-round events)
  "Group events by round number, return sorted list of (round . events)."
  (let loop ((evts events) (acc '()))
    (if (null? evts) (sort acc (lambda (a b) (< (car a) (car b))))
        (let* ((e (car evts))
               (r (alist-ref e 'round 0))
               (existing (assv r acc)))
          (if existing
              (begin (set-cdr! existing (cons e (cdr existing)))
                     (loop (cdr evts) acc))
              (loop (cdr evts) (cons (cons r (list e)) acc)))))))

(define (federation-event-log events)
  "Render the federation event log sidebar.
   EVENTS: list of event alists with 'round, 'kind (symbol), 'scope-id,
           optional 'target-scope-id, 'spec-id, 'qty."
  (let ((grouped (group-by-round events)))
    `(div (@ (class "event-log"))
       (div (@ (class "log-label")) "FEDERATION EVENT LOG")
       (div (@ (class "rounds-wrap"))
         ,@(map
            (lambda (group)
              (let* ((round (car group))
                     (evts (reverse (cdr group)))
                     (label (let ((p (assv round *round-labels*)))
                              (if p (cdr p) (string-append "PASS " (number->string round))))))
                `(div (@ (class "round-group"))
                   (div (@ (class "round-header"))
                     (span (@ (class "round-label")) ,label)
                     (span (@ (class "round-count")) ,(number->string (length evts))))
                   (div (@ (class "events-row"))
                     ,@(map
                        (lambda (evt)
                          (let* ((kind (alist-ref evt 'kind 'unknown))
                                 (color (event-color kind))
                                 (scope-id (alist-ref evt 'scope-id ""))
                                 (target (alist-ref evt 'target-scope-id #f))
                                 (spec (alist-ref evt 'spec-id #f))
                                 (qty (alist-ref evt 'qty #f)))
                            `(div (@ (class "event-chip")
                                     (style ,(string-append "--chip-color:" color
                                                            ";border-color:" color "22")))
                               (span (@ (class "evt-icon") (style ,(string-append "color:" color)))
                                 ,(event-icon kind))
                               (span (@ (class "evt-scope")) ,scope-id)
                               ,@(if target
                                     `((span (@ (class "evt-arrow") (style ,(string-append "color:" color)))
                                         "\u2192")
                                       (span (@ (class "evt-scope")) ,target))
                                     '())
                               ,@(if spec
                                     `((span (@ (class "evt-spec")
                                                (style ,(string-append "color:" color "bb")))
                                         ,spec))
                                     '())
                               ,@(if qty
                                     `((span (@ (class "evt-qty")
                                                (style ,(string-append "color:" color "88")))
                                         ,(string-append "\u00d7" (n->s qty))))
                                     '()))))
                        evts)))))
            grouped)))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  INVENTORY BAND
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (inventory-band all-resources spec-names
                         #:key (selected-scope "") (my-resources '()))
  "Render the bottom inventory band.
   ALL-RESOURCES: alist mapping scope-id -> list of resource alists.
   SPEC-NAMES: alist mapping spec-id -> display name.
   Each resource: ((id . \"r1\") (conforms-to . \"wheat\") (name . \"Wheat Reserve\")
                   (onhand . 670) (unit . \"kg\"))."
  (let ((has-any (any (lambda (p) (not (null? (cdr p)))) all-resources)))
    `(div (@ (class "band"))
       (div (@ (class "band-label")) "INVENTORY")
       (div (@ (class "scroll-area"))
         ;; My resources section
         ,@(if (not (null? my-resources))
               `((div (@ (class "scope-group"))
                   (div (@ (class "scope-divider") (style "color:#7ee8a2")) "MY INV")
                   ,@(map (lambda (r) (render-resource-card r spec-names #t #f)) my-resources)))
               '())
         ;; Per-scope resources
         ,@(if has-any
               (append-map
                (lambda (scope-entry)
                  (let ((scope-id (car scope-entry))
                        (resources (cdr scope-entry)))
                    (if (null? resources) '()
                        `((div (@ (class "scope-group"))
                            (div (@ (class "scope-divider")) ,scope-id)
                            ,@(map (lambda (r)
                                     (render-resource-card r spec-names
                                                           (equal? scope-id selected-scope)
                                                           #f))
                                   resources))))))
                all-resources)
               `((div (@ (class "empty")) "No inventory observed.")))))))

(define (render-resource-card res spec-names is-selected is-claimable)
  "Render a single inventory resource card."
  (let* ((cto (alist-ref res 'conforms-to ""))
         (name (or (alist-ref res 'name #f)
                   (let ((p (assoc cto spec-names equal?)))
                     (if p (cdr p) cto))))
         (onhand (alist-ref res 'onhand 0))
         (unit (alist-ref res 'unit ""))
         (accent (if is-claimable "#e8b04e" "#7ee8a2")))
    `(div (@ (class ,(string-append "resource-card" (if is-selected " selected" ""))))
       (div (@ (class "card-scope")) ,cto)
       (div (@ (class "card-name")) ,name)
       (div (@ (class "card-qty") (style ,(string-append "border-left-color:" accent)))
         ,(string-append "OH " (n->s onhand) " " unit)))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  DEFICIT RESIDUAL BAR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (deficit-residual-bar spec shortfall original resolved-at)
  "Stacked progress bar for deficit resolution.
   SPEC: string. SHORTFALL: remaining. ORIGINAL: total original.
   RESOLVED-AT: list of scope-id strings."
  (let* ((resolved-qty (- original shortfall))
         (resolved-pct (if (> original 0) (* (/ (- original shortfall) original) 100) 0))
         (bar-w 200))
    `(div (@ (class "deficit-bar"))
       (div (@ (class "deficit-bar-header"))
         (span (@ (class "deficit-spec")) ,spec)
         (span (@ (class "deficit-pct"))
           ,(string-append (n->s (round resolved-pct)) "% resolved")))
       (div (@ (class "deficit-track"))
         ,@(if (> resolved-qty 0)
               `((div (@ (class "deficit-fill green")
                         (style ,(string-append "width:" (n->s (* (/ resolved-qty original) bar-w)) "px")))))
               '())
         ,@(if (> shortfall 0)
               `((div (@ (class "deficit-fill red")
                         (style ,(string-append "width:" (n->s (* (/ shortfall original) bar-w)) "px")))))
               '()))
       ,@(if (not (null? resolved-at))
             `((div (@ (class "deficit-resolvers"))
                 ,@(map (lambda (s) `(span (@ (class "resolver-tag")) ,s)) resolved-at)))
             '()))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  SCOPE DETAIL PANEL
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (scope-detail-panel scope-id result trades on-close
                             #:key (processes '()) (commitments '())
                                   (buffer-zones '()) (spec-names '())
                                   (resources '()) (demand-intents '())
                                   (mode 'plan) on-mode-change
                                   (class ""))
  "Right sidebar showing scope signals, deficits, surplus, trades, network, demands, and metrics.
   RESULT: alist with 'deficits, 'surplus, etc.
   MODE: 'plan or 'observe."
  (let* ((deficits (alist-ref result 'deficits '()))
         (surplus-items (alist-ref result 'surplus '()))
         (outgoing (filter (lambda (t) (equal? (alist-ref t 'from) scope-id)) trades))
         (incoming (filter (lambda (t) (equal? (alist-ref t 'to) scope-id)) trades))
         (has-trades (or (not (null? outgoing)) (not (null? incoming))))
         (has-signals (or (not (null? deficits)) (not (null? surplus-items)) has-trades)))
    `(aside (@ (class ,(string-append "detail-panel " class)))
       ;; Header
       (div (@ (class "panel-header"))
         (div (@ (class "header-left"))
           (span (@ (class "scope-label")) "SCOPE")
           (span (@ (class "scope-name")) ,scope-id))
         (div (@ (class "header-right"))
           (div (@ (class "mode-tabs"))
             (button (@ (class ,(string-append "tab-btn" (if (eq? mode 'plan) " active" "")))
                        ,@(if on-mode-change `((click ,(lambda (e) (on-mode-change 'plan)))) '()))
               "PLAN")
             (button (@ (class ,(string-append "tab-btn" (if (eq? mode 'observe) " active" "")))
                        ,@(if on-mode-change `((click ,(lambda (e) (on-mode-change 'observe)))) '()))
               "OBSERVE"))
           (button (@ (class "close-btn")
                      ,@(if on-close `((click ,on-close)) '()))
             "\u2715")))

       ;; Signals band
       (div (@ (class "signals-band"))
         ;; Deficits
         ,@(if (not (null? deficits))
               `((div (@ (class "section-label")) "DEFICITS")
                 ,@(map (lambda (d)
                          (deficit-residual-bar
                           (alist-ref d 'spec "")
                           (alist-ref d 'shortfall 0)
                           (alist-ref d 'original 0)
                           (alist-ref d 'resolved-at '())))
                        deficits))
               '())

         ;; Surplus
         ,@(if (not (null? surplus-items))
               `((div (@ (class "section-label")) "SURPLUS")
                 ,@(map (lambda (s)
                          `(div (@ (class "signal-row"))
                             (span (@ (class "signal-spec")) ,(alist-ref s 'spec ""))
                             (span (@ (class "green")) ,(n->s (alist-ref s 'qty 0)))))
                        surplus-items))
               '())

         ;; Inter-scope supports
         ,@(if has-trades
               `((div (@ (class "section-label")) "INTER-SCOPE SUPPORTS")
                 ,@(map (lambda (t)
                          `(div (@ (class "trade-row"))
                             (span (@ (class "trade-arrow") (style "color:#63b3ed")) "\u2192")
                             (span (@ (class "trade-peer")) ,(alist-ref t 'to ""))
                             (span (@ (class "trade-spec")) ,(alist-ref t 'spec ""))
                             (span (@ (class "trade-qty"))
                               ,(string-append "\u00d7" (n->s (alist-ref t 'qty 0))))
                             (span (@ (class "trade-status") (style "color:#63b3ed")) "PROPOSED")))
                        outgoing)
                 ,@(map (lambda (t)
                          `(div (@ (class "trade-row"))
                             (span (@ (class "trade-arrow") (style "color:#68d391")) "\u2190")
                             (span (@ (class "trade-peer")) ,(alist-ref t 'from ""))
                             (span (@ (class "trade-spec")) ,(alist-ref t 'spec ""))
                             (span (@ (class "trade-qty"))
                               ,(string-append "\u00d7" (n->s (alist-ref t 'qty 0))))
                             (span (@ (class "trade-status") (style "color:#63b3ed")) "PROPOSED")))
                        incoming))
               '())

         ;; Empty state
         ,@(if (not has-signals)
               '((p (@ (class "empty")) "No signals."))
               '()))

       ;; Network diagram section
       ,@(if (not (null? processes))
             `((div (@ (class "panel-section diagram-section"))
                 (div (@ (class "section-label"))
                   ,(string-append "NETWORK  " scope-id))
                 ,(scope-network-diagram processes commitments
                                         #:buffer-zones buffer-zones
                                         #:spec-names spec-names)))
             '())

       ;; Demands band
       ,@(if (not (null? demand-intents))
             `((div (@ (class "panel-section"))
                 (div (@ (class "section-label"))
                   ,(string-append "DEMANDS \u00b7 " (string-upcase* scope-id)
                                   "  " (number->string (length demand-intents)) " intents"))
                 ;; Supply column
                 ,@(if (not (null? resources))
                       `((div (@ (class "supply-section"))
                           (div (@ (class "supply-label")) "SUPPLY")
                           ,@(map (lambda (r)
                                    (let ((sn (let ((p (assoc (alist-ref r 'conforms-to "") spec-names equal?)))
                                                (if p (cdr p) (alist-ref r 'conforms-to ""))))
                                          (oh (alist-ref r 'onhand 0))
                                          (unit (alist-ref r 'unit "")))
                                      `(div (@ (class "supply-row"))
                                         (span (@ (class "supply-spec")) ,sn)
                                         (span (@ (class "supply-qty green"))
                                           ,(string-append (n->s oh) " " unit)))))
                                  resources)))
                       '())
                 ;; Demand cards
                 (div (@ (class "demand-cards"))
                   ,@(map (lambda (d)
                            (let ((sn (let ((p (assoc (alist-ref d 'spec "") spec-names equal?)))
                                        (if p (cdr p) (alist-ref d 'spec ""))))
                                  (qty (alist-ref d 'qty 0))
                                  (unit (alist-ref d 'unit "")))
                              `(div (@ (class "demand-card"))
                                 (div (@ (class "demand-spec")) ,sn)
                                 (div (@ (class "demand-qty"))
                                   ,(string-append (n->s qty) " " unit)))))
                          demand-intents))))
             '())

       ;; Metrics band
       (div (@ (class "panel-section metrics-band"))
         (div (@ (class "section-label"))
           ,(string-append "METRICS \u00b7 " (string-upcase* scope-id)))
         (div (@ (class "metric-cards"))
           (div (@ (class "metric-card"))
             (div (@ (class "metric-label")) "OTIF")
             (div (@ (class "metric-value")) "\u2014%"))
           (div (@ (class "metric-card"))
             (div (@ (class "metric-label")) "ON TIME")
             (div (@ (class "metric-value")) "\u2014%"))
           (div (@ (class "metric-card"))
             (div (@ (class "metric-label")) "IN FULL")
             (div (@ (class "metric-value")) "\u2014%"))
           (div (@ (class "metric-card"))
             (div (@ (class "metric-label")) "SIGNALS")
             (div (@ (class "metric-value")) "0")))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  FEDERATION PAGE (COMPOSER)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (federation-page #:key (scopes '()) (results '()) (trades '())
                                (events '()) (resources-by-scope '())
                                (buffers-by-scope '()) (spec-names '())
                                (processes-by-scope '()) (commitments-by-scope '())
                                (selected "") on-select on-close-detail on-mode-change
                                (mode 'plan)
                                (svg-width 1100) (svg-height 720)
                                (class ""))
  "Compose the full federation planning page.
   Body: event-log sidebar | graph view | optional detail panel
   Bottom: inventory band"
  (let* ((has-selection (and (string? selected) (not (string=? selected ""))))
         (sel-result (and has-selection (assoc selected results equal?)))
         (sel-result-data (and sel-result (cdr sel-result)))
         (sel-procs (if has-selection
                        (let ((p (assoc selected processes-by-scope equal?)))
                          (if p (cdr p) '()))
                        '()))
         (sel-cmts (if has-selection
                       (let ((c (assoc selected commitments-by-scope equal?)))
                         (if c (cdr c) '()))
                       '())))
    `(div (@ (class ,(string-append "fed-page " class)))
       ;; Header
       (div (@ (class "stat-bar")) "FEDERATION PLANNING")
       ;; Body: sidebar + graph + optional detail panel
       (div (@ (class "fed-body"))
         ,(federation-event-log events)
         ,(federation-graph-view scopes results trades
                                 #:resources-by-scope resources-by-scope
                                 #:buffers-by-scope buffers-by-scope
                                 #:selected selected
                                 #:on-select on-select
                                 #:svg-width svg-width
                                 #:svg-height svg-height)
         ,@(if (and has-selection sel-result-data)
               `(,(scope-detail-panel selected sel-result-data trades
                                      on-close-detail
                                      #:processes sel-procs
                                      #:commitments sel-cmts
                                      #:spec-names spec-names
                                      #:resources (let ((r (assoc selected resources-by-scope equal?)))
                                                    (if r (cdr r) '()))
                                      #:demand-intents (alist-ref sel-result-data 'demand-intents '())
                                      #:mode mode
                                      #:on-mode-change on-mode-change))
               '()))
       ;; Bottom inventory band
       ,(inventory-band resources-by-scope spec-names
                        #:selected-scope selected))))
