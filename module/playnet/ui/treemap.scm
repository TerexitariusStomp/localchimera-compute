;;; treemap.scm — the reproduction-labour surface, as SXML/SVG
;;;
;;; A direct port of docs/viz/treemap.html.  The whole point: the economy is a
;;; tree, an s-expression is a tree, and SXML is a tree — so the data, the
;;; fold over it, and the rendered surface are all the *same shape*.
;;;
;;;   data tree  ──repro──▶  decomposition   ──render──▶  SXML tree (SVG)
;;;
;;; `repro` is a one-line catamorphism: a leaf computes its maintenance /
;;; production / insurance split; a branch is the per-component sum of its
;;; children.  So the reproduction-labour mix is an emergent property at every
;;; level of the tree.  `*intents*` is one data table every renderer maps over;
;;; colour is `hsl(h s l)` with lightness naming the intent and saturation the
;;; state, emitted straight as a CSS string (no colour maths, no conversion).
;;;
;;; Hoot/WASM compatible: no macros, no SRFI-1, no mutable strings, numbers
;;; stringified through `n->s` (works around the Hoot number->string regression).

(define-module (playnet ui treemap)
  #:use-module (ice-9 optargs)          ; define*
  #:use-module (playnet ui map)         ; the geographic drill-down component
  ;; Minimal public surface — common names like `node`/`leaf`/`group`/`attr`
  ;; are kept INTERNAL on purpose: they collide with other modules (e.g.
  ;; (playnet ui priorities) exports `node`) when imported into hoot/repl.scm.
  #:export (treemap-surface       ; focus node -> SVG SXML (fills container)
            repro                  ; the catamorphism (handy for tests)
            tm-node-name           ; accessor used by callers (namespaced)
            tm-node-kids           ; children accessor (namespaced)
            tm-axis-root?          ; is this node the activities/categories axis-root?
            leaf->markers          ; bridge to (playnet ui map)
            *playnet-tree*         ; root: free time + federation + scopes
            *food-scope*))


;;; ── tiny prelude (avoid SRFI-1 / Hoot-missing procedures) ──────────────────

(define (append-map f xs) (apply append (map f xs)))
(define (sum-list xs) (let loop ((xs xs) (a 0)) (if (null? xs) a (loop (cdr xs) (+ a (car xs))))))
(define (max-list xs) (let loop ((xs (cdr xs)) (a (car xs))) (if (null? xs) a (loop (cdr xs) (max a (car xs))))))
(define (min-list xs) (let loop ((xs (cdr xs)) (a (car xs))) (if (null? xs) a (loop (cdr xs) (min a (car xs))))))
(define (snoc lst x) (append lst (list x)))
(define (clean al) (let loop ((al al)) (cond ((null? al) '()) ((cdr (car al)) (cons (car al) (loop (cdr al)))) (else (loop (cdr al))))))

;; Number -> string, one decimal, dodging the Hoot number->string rational bug.
(define (n->s n)
  (cond
   ((or (not (number? n)) (and (real? n) (not (rational? n)))) "0")
   (else
    (let* ((scaled (inexact->exact (round (* n 10))))
           (neg? (negative? scaled)) (a10 (abs scaled))
           (whole (quotient a10 10)) (tenth (remainder a10 10)) (sgn (if neg? "-" "")))
      (if (zero? tenth)
          (string-append sgn (number->string whole))
          (string-append sgn (number->string whole) "." (number->string tenth)))))))

(define (ints n) (number->string (inexact->exact (round n))))       ; integer string
(define (hsl h s l) (string-append "hsl(" (n->s h) "," (n->s s) "%," (n->s l) "%)"))


;;; ── the tree (a node is just a 3-list: name · attrs · children) ────────────
;;; Leaves carry value/sat/cat (+ optional maint/ins/target) in attrs and no
;;; children; branches carry a cat (for colour) and children.  Built with the
;;; `leaf` / `group` constructors, the data reads as the tree it is.

(define (node name attrs kids) (list name attrs kids))
(define (node-name n) (car n))
(define tm-node-name node-name)         ; exported alias (node-name stays internal)
(define (node-attrs n) (cadr n))
(define (node-kids n) (caddr n))
(define tm-node-kids node-kids)          ; exported alias
(define (leaf? n) (null? (node-kids n)))
(define (tm-axis-root? n) (and (pair? n) (attr n 'axis-root #f)))  ; exported
(define* (attr n k #:optional (default #f))
  (let ((p (assq k (node-attrs n)))) (if p (cdr p) default)))

;; `dw` = desire weight (how much citizens want it); `ds` = fraction of that
;; desire filled (a number for individual-claimable; left #f for communal goods,
;; which are socially allocated, and for means, which have no direct desire).
(define* (leaf name value cat #:key (sat 0.85) target maint ins dw ds)
  (node name (clean (list (cons 'value value) (cons 'cat cat) (cons 'sat sat)
                          (cons 'target target) (cons 'maint maint) (cons 'ins ins)
                          (cons 'dw dw) (cons 'ds ds)))
        '()))
(define (group name cat . kids) (node name (list (cons 'cat cat)) kids))


;;; ── palette + intent table (one source of truth) ──────────────────────────
;;; Per category: (hue saturation% default-maint default-ins).  Lightness is
;;; supplied per intent by `*intents*`; saturation distinguishes done vs to-come.

(define *cats*
  ;;  cat       hue  sat  maint  ins
  '((ind    .  (137  30  0.18  0.08))   ; individual-claimable — produced fresh
    (com    .  (137  28  0.45  0.10))   ; communal consumption
    (mop    .  (212  43  0.72  0.12))   ; means of production — depreciation/repair
    (lpd    .  (266  22  0.55  0.15))   ; skilled population (labour-power) — recert + redundancy
    (skill  .  (266  22  0.55  0.15))   ; alias of lpd
    (adm    .  (0     0  0.75  0.08))   ; administration
    (moc    .  (137  30  0.40  0.10))   ; (container hues)
    (scope  .  (137  30  0.40  0.10))   ; scopes & federation are production-green
    (federation . (137 30 0.40 0.10))
    (root   .  (137  30  0.40  0.10))
    (free   .  (185  28  0.40  0.10))))  ; free time — teal

(define (cat-spec cat) (let ((p (assq cat *cats*))) (if p (cdr p) '(137 30 0.40 0.10))))
(define (cat-hue cat) (car (cat-spec cat)))
(define (cat-sat cat) (cadr (cat-spec cat)))

;;  key    label          lightness%
(define *intents*
  '((maint "maintenance" 30)
    (prod  "production"  47)
    (ins   "insurance"   64)))
(define (intent-label i) (cadr i))
(define (intent-lum i) (caddr i))


;;; ── repro : the catamorphism ───────────────────────────────────────────────
;;; A leaf splits its required labour into the three deductions; a branch is
;;; the per-component sum of its children.  Result is an alist over `*rkeys*`.

(define *rkeys* '(total realized maint prod ins))
(define (rget r k) (cdr (assq k r)))
(define (r+ a b) (map (lambda (k) (cons k (+ (rget a k) (rget b k)))) *rkeys*))
(define (rsum rs) (if (null? rs) (map (lambda (k) (cons k 0)) *rkeys*) (r+ (car rs) (rsum (cdr rs)))))

(define (intent-share node which)            ; default share for a leaf's category
  (let ((spec (cat-spec (attr node 'cat 'scope))))
    (if (eq? which 'maint) (caddr spec) (cadddr spec))))

(define (decomp node)
  (let* ((p     (attr node 'value 0))
         (sat   (attr node 'sat 0.85))
         (maint (* p (or (attr node 'maint) (intent-share node 'maint))))
         (ins   (min (* p (or (attr node 'ins) (intent-share node 'ins)))
                     (max 0 (- p maint))))
         (prod  (- p maint ins)))
    (list (cons 'total p) (cons 'realized (* p sat))
          (cons 'maint maint) (cons 'prod prod) (cons 'ins ins))))

(define (repro node)
  (if (leaf? node) (decomp node) (rsum (map repro (node-kids node)))))


;;; ── squarified treemap layout ──────────────────────────────────────────────
;;; items : list of (weight . node).  Returns list of (node x y w h).

(define (worst-ratio areas s)
  (let* ((sum (sum-list areas)) (s2 (* s s)) (sum2 (* sum sum))
         (hi (max-list areas)) (lo (min-list areas)))
    (if (or (= sum 0) (= lo 0)) 1e18
        (max (/ (* s2 hi) sum2) (/ sum2 (* s2 lo))))))

(define (place-row row x y w h s)
  (let* ((used (sum-list (map car row))) (thick (if (> s 0) (/ used s) 0)))
    (if (= s w)
        (let loop ((row row) (cx x) (acc '()))            ; horizontal strip (top)
          (if (null? row) acc
              (let* ((a (caar row)) (cw (if (> thick 0) (/ a thick) 0)))
                (loop (cdr row) (+ cx cw) (snoc acc (list (cdar row) cx y cw thick))))))
        (let loop ((row row) (cy y) (acc '()))            ; vertical strip (left)
          (if (null? row) acc
              (let* ((a (caar row)) (ch (if (> thick 0) (/ a thick) 0)))
                (loop (cdr row) (+ cy ch) (snoc acc (list (cdar row) x cy thick ch)))))))))

(define (squarify-rect areas x y w h)
  (if (null? areas) '()
      (let ((s (min w h)))
        (let grow ((row '()) (rest areas))
          (cond
           ((null? rest) (place-row row x y w h s))
           ((and (pair? row)
                 (> (worst-ratio (map car (snoc row (car rest))) s)
                    (worst-ratio (map car row) s)))
            (let* ((placed (place-row row x y w h s))
                   (used (sum-list (map car row))) (thick (/ used s)))
              (append placed
                      (if (= s w)
                          (squarify-rect rest x (+ y thick) w (- h thick))
                          (squarify-rect rest (+ x thick) y (- w thick) h)))))
           (else (grow (snoc row (car rest)) (cdr rest))))))))

(define (sort-desc items)                     ; insertion sort by weight, big first
  (let insert ((xs items) (out '()))
    (if (null? xs) out
        (insert (cdr xs)
                (let place ((o out))
                  (cond ((null? o) (list (car xs)))
                        ((>= (caar xs) (car (car o))) (cons (car xs) o))
                        (else (cons (car o) (place (cdr o))))))))))

(define (squarify items x y w h)
  (let* ((total (sum-list (map car items)))
         (scale (if (> total 0) (/ (* w h) total) 0))
         (areas (map (lambda (it) (cons (* (car it) scale) (cdr it))) (sort-desc items))))
    (squarify-rect areas x y w h)))


;;; ── layout the whole tree → flat list of placed cells ─────────────────────
;;; Each branch reserves a header strip, insets, and squarifies its children by
;;; their folded total.  Parents are emitted before children (so children
;;; overlay).  A placement is (node x y w h depth).

(define *pad* 3)
(define (header-h h) (min 22 (* h 0.16)))

;; A node is *navigable* (federation, a scope, the root) — these fold into a
;; single zoomable cell unless they are the current focus. Containers (the
;; category groups) always expand inside their scope; leaves are always cells.
;; Activity scopes carry a `scope?` flag so they fold regardless of colour-cat
;; (e.g. UC admin is admin-grey but still a foldable scope).
(define (navigable? n)
  (or (attr n 'scope? #f) (memq (attr n 'cat 'leaf) '(root federation scope))))
(define (expand? n focus)
  (and (pair? (node-kids n))
       (or (eq? n focus) (not (navigable? n)))))

;; Lay the focus subtree into placements (node x y w h depth expand?). Folded
;; navigable nodes and leaves stop the recursion (they render as one cell).
(define (layout node x y w h depth focus)
  (let* ((ex (expand? node focus))
         (self (list node x y w h depth ex)))
    (if (not ex)
        (list self)
        (let* ((hh (header-h h))
               (ix (+ x *pad*)) (iy (+ y hh))
               (iw (max 0 (- w (* 2 *pad*)))) (ih (max 0 (- h hh *pad*)))
               (items (map (lambda (k) (cons (max 1 (rget (repro k) 'total)) k)) (node-kids node)))
               (placed (squarify items ix iy iw ih)))
          (cons self
                (append-map (lambda (p) (layout (car p) (cadr p) (caddr p) (cadddr p) (list-ref p 4) (+ depth 1) focus))
                            placed))))))


;;; ── rendering : placement → SXML ───────────────────────────────────────────

(define (rect x y w h fill . extra)
  `(rect (@ (x ,(n->s x)) (y ,(n->s y)) (width ,(n->s (max 0 w))) (height ,(n->s (max 0 h)))
            (fill ,fill) ,@extra)))
(define (tspan x y size fill weight s)
  `(text (@ (x ,(n->s x)) (y ,(n->s y)) (font-size ,(n->s size)) (fill ,fill)
            (font-weight ,weight) (text-anchor "middle")) ,s))

;; A centered label that shrinks to fit width W and is dropped entirely when it
;; can't fit (so labels never overflow a narrow cell into its neighbour).
;; Returns a list to splice.
(define (label cx y base w fill weight s)
  (let ((fs (min base (/ (max 1 (- w 6)) (max 1 (* (string-length s) 0.55))))))
    (if (< fs 5) '() (list (tspan cx y fs fill weight s)))))

;; One intent band: solid realized at the bottom, a paler desaturated cap above.
(define (band hue sat intent x ybot bandh left w)
  (let* ((lum (intent-lum intent))
         (solid (hsl hue sat lum))                      ; vivid = performed
         (cap (hsl hue (* sat 0.45) (min 90 (+ lum 20)))) ; pale, washed = to come
         (realized (* (- 1 left) bandh))
         (ytop (- ybot bandh)) (ysplit (- ybot realized)))
    (append
     (if (> realized 0.2) (list (rect x ysplit w realized solid)) '())
     (if (> (- ysplit ytop) 0.2) (list (rect x ytop w (- ysplit ytop) cap)) '()))))

(define (pct-str frac) (string-append (ints (* frac 100)) "% "))

;; The view lens, set by the header toggles: (detail? individual? priority? categories?).
(define *pop* 90)                       ; federation citizens — per-capita divisor
(define (vdetail? v) (and (pair? v) (list-ref v 0)))
(define (vindiv?  v) (and (pair? v) (list-ref v 1)))
(define (vprio?   v) (and (pair? v) (list-ref v 2)))
(define (vcats?   v) (and (pair? v) (> (length v) 3) (list-ref v 3)))

;; An axis-root (the federation) swaps its rendered children between the two
;; projections by the categories lens; everyone else uses their own children.
(define (kids-for node view)
  (if (attr node 'axis-root #f)
      (if (vcats? view) (attr node 'categories '()) (attr node 'activities '()))
      (node-kids node)))
(define (hfmt hrs v)                    ; an hours label under the social/individual lens
  (if (vindiv? v)
      (string-append (n->s (/ hrs *pop*)) " h/you")
      (string-append (ints hrs) " h")))

;; Desire-satisfaction Φ for the priority lens: an individual good reads its own
;; `ds`; a scope reads its `priority`; communal goods and means (incl. skills)
;; have no direct desire, so they fall back to how much is reproduced (worked).
(define (phi-of node worked)
  (let ((ds (attr node 'ds)) (pr (attr node 'priority)))
    (cond ((number? ds) ds) (pr pr) (else worked))))

;; Native SVG <title> tooltip for a cell — name, completion, intent breakdown.
(define (cell-tooltip node view)
  (let* ((r (repro node)) (total (rget r 'total))
         (target (attr node 'target #f))
         (pct (if (> total 0) (ints (* 100 (/ (rget r 'realized) total))) "0")))
    `(title ,(string-append
              (node-name node) (if target (string-append " · " target) "")
              " · " (hfmt total view) "\n"
              pct "% performed\n"
              "maintenance " (ints (rget r 'maint)) " h · "
              "production " (ints (rget r 'prod)) " h · "
              "insurance " (ints (rget r 'ins)) " h"))))

;; The simple view (the default, like docs/viz/treemap.html): one progress bar —
;; realized labour (solid, from the bottom) under labour still to come (light) —
;; captioned "N% worked". The calm summary the `detailed` toggle expands.
(define (simple-cell node x y w h on-click view)
  (let* ((r (repro node)) (total (rget r 'total))
         (worked (if (> total 0) (/ (rget r 'realized) total) 0))
         (cat (attr node 'cat 'scope))
         (free? (eq? cat 'free)) (prio? (vprio? view))
         (hue (cat-hue cat)) (sat (cat-sat cat))
         ;; priority lens reads desire-satisfaction Φ and fills/tints by it
         ;; (red→green); the time lens fills by labour worked, in the cat hue.
         (phi (phi-of node worked))
         (fill (if (and prio? (not free?)) phi worked))
         (fhue (if (and prio? (not free?)) (* phi 130) hue)) (fsat (if prio? 58 sat))
         (hh (header-h h)) (by (+ y hh)) (bh (max 0 (- h hh)))
         (cx (+ x (/ w 2))) (clk (and on-click (lambda (e) (on-click node))))
         (dark (hsl fhue fsat 37)) (light (hsl fhue (* fsat 0.5) 72))
         (wh (* fill bh)) (ytop (- (+ by bh) wh)) (dw (attr node 'dw)))
    `(g (@ (class ,(if clk "cell clickable" "cell")) ,@(if clk (list (list 'click clk)) '()))
        ,(cell-tooltip node view)
        ,(rect x y w hh (hsl hue sat 22))
        ,@(label cx (+ y (* hh 0.7)) (min 11 (* hh 0.7)) w "white" "700"
                 (string-append (node-name node) " · " (hfmt total view)))
        ,(rect x by w bh light)                       ; to-come / unmet (light)
        ,(rect x ytop w wh dark)                       ; performed / filled (solid, from bottom)
        ,@(if (and (> wh 30) (> w 50))
              (cond
               (free? (list (tspan cx (+ ytop (/ wh 2)) (min 24 (* w 0.06)) "white" "700"
                                   (hfmt (rget r 'realized) view))
                            (tspan cx (+ (+ ytop (/ wh 2)) 14) (min 12 (* w 0.03)) "#ffffffcc" "400"
                                   (string-append (pct-str worked) "Playtime"))))
               (prio? (list (tspan cx (+ ytop (/ wh 2)) (min 24 (* w 0.06)) "white" "700"
                                   (string-append "Φ " (ints (* phi 100)) "%"))
                            (tspan cx (+ (+ ytop (/ wh 2)) 14) (min 12 (* w 0.03)) "#ffffffcc" "400"
                                   (if dw (string-append (n->s dw) " desire-wt") "desire met"))))
               (else (list (tspan cx (+ ytop (/ wh 2)) (min 24 (* w 0.06)) "white" "700"
                                  (hfmt (rget r 'realized) view))
                           (tspan cx (+ (+ ytop (/ wh 2)) 14) (min 12 (* w 0.03)) "#ffffffcc" "400"
                                  (string-append (pct-str worked) "worked")))))
              '())
        ,(rect x y w h "none" '(stroke "rgba(255,255,255,0.35)") '(stroke-width "0.5")))))

;; The intent cell — maintenance/production/insurance bands (solid = performed,
;; pale = to come). The `detailed` view.
(define (intent-cell node x y w h on-click view)
  (let* ((r (repro node)) (total (rget r 'total))
             (cat (attr node 'cat 'scope)) (hue (cat-hue cat)) (sat (cat-sat cat))
             (left (if (> total 0) (- 1 (/ (rget r 'realized) total)) 0))
             (hh (header-h h)) (bx x) (by (+ y hh)) (bh (max 0 (- h hh)))
             (cx (+ x (/ w 2))) (small? (or (< w 26) (< h 26)))
             (clk (and on-click (lambda (e) (on-click node)))))
        `(g (@ (class ,(if clk "cell clickable" "cell"))
               ,@(if clk (list (list 'click clk)) '()))
            ,(cell-tooltip node view)
            ,(rect x y w hh (hsl hue sat 26))
            ,@(label cx (+ y (* hh 0.7)) (min 11 (* hh 0.7)) w "white" "700"
                     (string-append (node-name node) " · " (hfmt total view)))
            ,@(let loop ((intents *intents*) (ybot (+ by bh)) (acc '()))
                (if (null? intents) acc
                    (let* ((i (car intents)) (key (car i))
                           (share (if (> total 0) (/ (rget r key) total) 0))
                           (bandh (* share bh)) (ytop (- ybot bandh)))
                      (loop (cdr intents) ytop
                            (append acc
                                    (band hue sat i bx ybot bandh left w)
                                    (if (and (> bandh 16) (> w 40) (not small?))
                                        (list (tspan cx (+ ytop (/ bandh 2)) 9
                                                     (if (eq? key 'ins) "#1a1a1a" "white") "700"
                                                     (hfmt (rget r key) view))
                                              (tspan cx (+ ytop (/ bandh 2) 9) 6
                                                     (if (eq? key 'ins) "#888" "#ffffffcc") "400"
                                                     (intent-label i)))
                                        '()))))))
            ,(rect x y w h "none" '(stroke "rgba(255,255,255,0.35)") '(stroke-width "0.5")))))

;; Dispatch: simple progress bar by default (and always for free time);
;; the detailed intent bands when the view's detail? lens is on.
(define (cell node x y w h on-click view)
  (if (and (vdetail? view) (not (eq? (attr node 'cat 'leaf) 'free)))
      (intent-cell node x y w h on-click view)
      (simple-cell node x y w h on-click view)))

(define (container-cell node x y w h view)
  (let* ((r (repro node)) (cat (attr node 'cat 'scope)) (hue (cat-hue cat)) (sat (cat-sat cat))
         (hh (header-h h)) (cx (+ x (/ w 2))))
    `(g (@ (class "container"))
        ,(cell-tooltip node view)
        ,(rect x y w hh (hsl hue (max 8 sat) 22))
        ,@(label cx (+ y (* hh 0.68)) (min 11 (* hh 0.62)) w "white" "700"
                 (string-append (node-name node) " — " (hfmt (rget r 'total) view)))
        ,(rect x y w h "none" (list 'stroke (hsl hue sat 40)) '(stroke-width "1.2")))))

(define (render-cell placement on-zoom on-leaf-click view)
  (let ((node (car placement)) (x (cadr placement)) (y (caddr placement))
        (w (cadddr placement)) (h (list-ref placement 4)) (ex (list-ref placement 6)))
    (cond
     ((or (< w 1) (< h 1)) '(g))
     (ex (container-cell node x y w h view))             ; expanded branch — header + border
     ((and (navigable? node) (pair? (node-kids node)))   ; folded scope/federation — zoom
      (cell node x y w h on-zoom view))
     (else                                                ; leaf — open map iff it has offers
      (cell node x y w h (and (pair? (leaf-offers node)) on-leaf-click) view)))))


;;; ── entry point ────────────────────────────────────────────────────────────

(define* (treemap-surface focus #:key (width 1500) (height 820)
                          (on-zoom #f) (on-leaf-click #f)
                          (detail? #f) (per-capita? #f) (priority? #f) (categories? #f))
  "Render the FOCUS node's subtree as an SVG SXML tree that fills its container.
   Area is required labour; each cell decomposes by intent into maintenance /
   production / insurance (solid = performed, pale = to come). Navigable nodes
   (federation, scopes) below the focus render as folded cells; ON-ZOOM is called
   with such a node when clicked. A resourced leaf calls ON-LEAF-CLICK (the map)."
  ;; The focus itself carries no header here — the breadcrumb above the surface
  ;; is its header — so its children fill the whole frame.
  (let* ((view (list detail? per-capita? priority? categories?))
         (kids (kids-for focus view))   ; axis-root resolves to activities | categories
         (items (map (lambda (k) (cons (max 1 (rget (repro k) 'total)) k)) kids))
         (placed (squarify items 0 0 width height))
         (cells (append-map (lambda (p) (layout (car p) (cadr p) (caddr p) (cadddr p) (list-ref p 4) 1 focus))
                            placed)))
    `(svg (@ (width "100%") (height "100%")
             (viewBox ,(string-append "0 0 " (n->s width) " " (n->s height)))
             (preserveAspectRatio "none")          ; fill the box (uniform stretch keeps relative areas)
             (class "surface") (style "display:block; width:100%; height:100%;"))
          ,@(map (lambda (c) (render-cell c on-zoom on-leaf-click view)) cells))))


;;; ── bridge to (playnet ui map) ─────────────────────────────────────────────
;;; A leaf's geographic offers (resource instances at lat/lng) become the
;;; map component's grouped-slot-markers — so clicking a leaf opens the very
;;; same map used elsewhere, no second map implementation.

(define (offer-field o k d) (let ((p (assq k o))) (if p (cdr p) d)))

(define (leaf-offers node)
  "The concrete offers behind a leaf: its own 'resources attr, else the
   shared *offers* table keyed by leaf name. Empty list when none."
  (or (attr node 'resources)
      (let ((p (assoc (node-name node) *offers*))) (if p (cdr p) '()))))

(define (leaf->markers node)
  "Convert a leaf's offers into (playnet ui map) grouped-slot-markers."
  (map (lambda (o)
         (let ((qty (offer-field o 'qty 0)) (unit (offer-field o 'unit ""))
               (emoji (offer-field o 'emoji "📦")))
           (make-grouped-slot-marker
            (offer-field o 'id "?")
            (list (cons 'name (node-name node)) (cons 'emoji emoji))   ; capacity
            (list (list (cons 'name (string-append (ints qty) " " unit))
                        (cons 'emoji emoji)
                        (cons 'when (offer-field o 'when ""))))          ; one slot
            (offer-field o 'lng 0) (offer-field o 'lat 0)
            'coordinates (offer-field o 'provider "") (offer-field o 'id "?"))))
       (leaf-offers node)))

;; A few offers around Sofia (where playnet.earth is hosted), mirroring the
;; RESOURCES table in docs/viz/treemap.html. Keyed by leaf name.
(define *offers*
  '(("bread"
     . (((id . "br1") (lat . 42.7017) (lng . 23.3139) (qty . 200) (unit . "loaves") (provider . "Bakery Vitosha")     (emoji . "🍞") (when . "now"))
        ((id . "br3") (lat . 42.7097) (lng . 23.3189) (qty . 300) (unit . "loaves") (provider . "Commons Bread Hub")  (emoji . "🍞") (when . "now"))
        ((id . "br5") (lat . 42.7157) (lng . 23.3309) (qty . 150) (unit . "loaves") (provider . "Slatina Bakery")     (emoji . "🍞") (when . "now"))))
    ("medical"
     . (((id . "md1") (lat . 42.7027) (lng . 23.3119) (qty . 12) (unit . "slots/day") (provider . "Clinic Vitosha")     (emoji . "🏥") (when . "today"))
        ((id . "md2") (lat . 42.6857) (lng . 23.3259) (qty . 8)  (unit . "slots/day") (provider . "Health Commons")     (emoji . "⚕")  (when . "today"))))
    ("hand tools"
     . (((id . "ht1") (lat . 42.6947) (lng . 23.3279) (qty . 18) (unit . "pcs") (provider . "Tool Library North") (emoji . "🔧") (when . "now"))))))


;;; ── example data : the food scope (Figure 2) ───────────────────────────────

;;; ── Sparse classification : a flat registry → categories → taxonomy ────────
;;; No scopes inside food. Every economic resource is declared ONCE, tagged with
;;; its economic category and a classification `path` (mode ▸ taxonomy). The tree
;;; is grown *sparsely* by lazy recursive insertion: a container node exists only
;;; where some resource is classified under it — empty branches never appear. The
;;; same good can sit under two modes (bread under both individual-claimable AND
;;; communal); mode × taxonomy are independent path axes. Every container total
;;; folds from the leaves via `repro`, never hardcoded. (Ported from the
;;; buildCategories design in docs/viz/treemap.html.)

(define *category-roots*
  '((moc . "means of consumption")
    (mop . "means of production")
    (lpd . "skilled population")
    (adm . "administration")))

;; The only path segments that recolour off their parent — the two MoC
;; distribution modes; every other taxonomy node inherits its category's hue.
(define *seg-cat* '(("individual claimable" . ind) ("communal" . com)))
(define (seg-cat seg fallback)
  (let ((p (assoc seg *seg-cat*))) (if p (cdr p) fallback)))

;; A registry entry is one SUBJECT–VERB–OBJECT sentence of the plan:
;;   SUBJECT = the viewer (implicit — the citizen reading the surface)
;;   VERB    = `act`  — the activity / scope, the *doing*        → activities axis
;;   OBJECT  = `category`+`path`+name — the spec, the thing made → categories axis
;; The two axes are two folds of the one registry; both partition the same total
;; L. Stored as (act category path leaf-node); the leaf's colour-cat is the mode
;; (for MoC) or the category itself.
(define* (res act category path name value #:key (sat 0.85) maint ins target dw ds)
  (list act category path
        (leaf name value (if (pair? path) (seg-cat (car path) category) category)
              #:sat sat #:maint maint #:ins ins #:target target #:dw dw #:ds ds)))

;; Small functional helpers (no SRFI-1 reliance under Hoot).
(define (keepf pred xs)
  (let loop ((xs xs))
    (cond ((null? xs) '()) ((pred (car xs)) (cons (car xs) (loop (cdr xs)))) (else (loop (cdr xs))))))
(define (uniq xs)
  (let loop ((xs xs) (seen '()))
    (cond ((null? xs) (reverse seen))
          ((let in? ((s seen)) (cond ((null? s) #f) ((equal? (car s) (car xs)) #t) (else (in? (cdr s)))))
           (loop (cdr xs) seen))
          (else (loop (cdr xs) (cons (car xs) seen))))))

;; Build one node from entries (path . leaf) that share its prefix: entries with
;; an empty remaining path are direct leaves; the rest group by head and recurse.
;; This single recursion *is* the sparsity — structure appears only along paths
;; that carry data.
(define (build-node name cat entries)
  (let* ((direct (keepf (lambda (e) (null? (car e))) entries))
         (nested (keepf (lambda (e) (pair? (car e))) entries))
         (heads  (uniq (map (lambda (e) (car (car e))) nested)))
         (kids   (map (lambda (head)
                        (let ((sub (map (lambda (e) (cons (cdr (car e)) (cdr e)))
                                        (keepf (lambda (e) (equal? (car (car e)) head)) nested))))
                          (build-node head (seg-cat head cat) sub)))
                      heads)))
    (node name (list (cons 'cat cat)) (append kids (map cdr direct)))))

;; Grow the four category roots from (cat path leaf) entries; prune empty roots.
(define (build-categories entries)
  (keepf (lambda (root) (pair? (node-kids root)))
         (map (lambda (cr)
                (let* ((key (car cr)) (nm (cdr cr))
                       (mine (map (lambda (r) (cons (cadr r) (caddr r)))
                                  (keepf (lambda (r) (eq? (car r) key)) entries))))
                  (build-node nm key mine)))
              *category-roots*)))

;;; ── The activities axis : the column-dual of the same registry ─────────────
;;; activities groups by VERB (`act`) — one scope-like node per activity, whose
;;; children are folded into its OWN categories→taxonomy by the same recursion.
;;; categories groups by OBJECT (`category`/`path`) — pooling across all
;;; activities. Both are PARTITIONS: two folds of one registry, identical total.

;; Declared activity order + each activity's colour-cat (admin is grey).
(define *act-order*
  '(("food" . scope) ("manufacturing" . scope) ("construction" . scope)
    ("education" . scope) ("health" . scope) ("transport" . scope)
    ("energy" . scope) ("textiles" . scope) ("tool-making" . scope)
    ("forestry" . scope) ("fishing" . scope) ("arts" . scope)
    ("mining" . scope) ("UC admin" . adm)))

;; Each activity's desire-satisfaction Φ (the priority lens reads this at the
;; scope level, where individual goods carry their own ds and means do not).
(define *act-priority*
  '(("food" . 0.82) ("manufacturing" . 0.71) ("construction" . 0.79)
    ("education" . 0.88) ("health" . 0.91) ("transport" . 0.83)
    ("energy" . 0.89) ("textiles" . 0.64) ("tool-making" . 0.73)
    ("forestry" . 0.77) ("fishing" . 0.69) ("arts" . 0.81)
    ("mining" . 0.58) ("UC admin" . 0.70)))

(define (build-activities resources)
  (keepf (lambda (n) (and n (pair? (node-kids n))))
         (map (lambda (ao)
                (let* ((a (car ao)) (acat (cdr ao))
                       (pr (let ((p (assoc a *act-priority*))) (and p (cdr p))))
                       (mine (keepf (lambda (r) (equal? (car r) a)) resources)))
                  (node a (list (cons 'cat acat) (cons 'scope? #t)   ; foldable scope
                                (cons 'priority pr))
                        (build-categories (map cdr mine)))))   ; strip act → (cat path leaf)
              *act-order*)))

;; The registry — every economic resource, declared once (act · cat · path · leaf).
(define *resources*
  (list
   ;; ═══ food · 1 800 h ═══
   (res "food" 'moc '("individual claimable" "food" "grain")    "bread"  330 #:sat 0.90 #:target "5k loaves"   #:dw 15 #:ds 0.80)
   (res "food" 'moc '("individual claimable" "food" "dairy")    "dairy"  260 #:sat 0.85 #:target "2.1k L"      #:dw 10 #:ds 0.80)
   (res "food" 'moc '("individual claimable" "food" "produce")  "veg."   230 #:sat 0.87 #:target "1.8t"        #:dw 8  #:ds 0.75)
   (res "food" 'moc '("individual claimable" "food" "prepared") "meals"  160 #:sat 0.81 #:target "9k portions" #:dw 6  #:ds 0.72)
   (res "food" 'moc '("communal" "food" "grain")   "bread" 170 #:sat 0.90 #:maint 0.20 #:target "3.5k loaves" #:dw 5)
   (res "food" 'moc '("communal" "food" "produce") "veg."  140 #:sat 0.88 #:maint 0.25 #:target "1.2t"        #:dw 3)
   (res "food" 'moc '("communal" "food" "dairy")   "dairy" 110 #:sat 0.85 #:maint 0.20 #:target "900 L"       #:dw 2)
   (res "food" 'mop '("infrastructure") "irrigation" 70 #:sat 0.88 #:maint 0.45 #:target "3 systems")
   (res "food" 'mop '("materials")      "seed"       45 #:sat 0.95 #:maint 0.30 #:target "8t")
   (res "food" 'mop '("facilities")     "storage"    65 #:sat 1.00 #:maint 0.82 #:ins 0.12 #:target "2 bays")
   (res "food" 'lpd '("food-safety skills") "cert." 120 #:sat 1.00 #:maint 0.70 #:ins 0.15 #:target "6 people")
   (res "food" 'lpd '("food-safety skills") "insp."  70 #:sat 1.00 #:maint 0.70 #:ins 0.15 #:target "4 people")
   (res "food" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ manufacturing · 1 500 h ═══
   (res "manufacturing" 'moc '("individual claimable" "household")    "furnishing" 200 #:sat 0.80 #:maint 0.30 #:target "120 pcs" #:dw 10 #:ds 0.70)
   (res "manufacturing" 'moc '("individual claimable" "electronics")  "devices"    200 #:sat 0.78 #:target "600 units" #:dw 7 #:ds 0.72)
   (res "manufacturing" 'moc '("individual claimable" "household")    "other"      100 #:sat 0.82 #:target "850 units" #:dw 4 #:ds 0.75)
   (res "manufacturing" 'mop '("machinery")  "machine tools" 500 #:sat 0.80 #:maint 0.60 #:target "30")
   (res "manufacturing" 'mop '("components") "parts"         300 #:sat 0.78 #:maint 0.50 #:target "12k units")
   (res "manufacturing" 'lpd '("machinist skills") "machinists" 170 #:sat 0.75 #:maint 0.50 #:target "20 people")
   (res "manufacturing" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ construction · 1 200 h ═══
   (res "construction" 'moc '("individual claimable" "housing") "shelter" 120 #:sat 0.83 #:maint 0.35 #:target "40 units" #:dw 6 #:ds 0.67)
   (res "construction" 'moc '("communal" "housing")             "housing" 230 #:sat 0.85 #:maint 0.25 #:target "60 units" #:dw 8)
   (res "construction" 'mop '("infrastructure") "roads"   350 #:sat 0.82 #:maint 0.50 #:target "12 km")
   (res "construction" 'mop '("infrastructure") "bridges" 200 #:sat 0.80 #:maint 0.40 #:target "3")
   (res "construction" 'mop '("materials")      "cement"  150 #:sat 0.88 #:maint 0.30 #:target "400t")
   (res "construction" 'lpd '("building skills") "masons" 120 #:sat 0.78 #:maint 0.45 #:target "15 people")
   (res "construction" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ education · 1 000 h ═══
   (res "education" 'moc '("communal" "schooling") "schooling" 300 #:sat 0.72 #:maint 0.50 #:target "1.2k pupils" #:dw 9)
   (res "education" 'lpd '("teaching skills") "teachers"    350 #:sat 0.70 #:maint 0.50 #:ins 0.10 #:target "40 people")
   (res "education" 'lpd '("research skills") "researchers" 250 #:sat 0.68 #:maint 0.45 #:ins 0.10 #:target "18 people")
   (res "education" 'mop '("facilities") "classrooms" 70 #:sat 0.80 #:maint 0.70 #:target "30")
   (res "education" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ health · 900 h ═══
   (res "health" 'moc '("communal" "care") "clinics"    350 #:sat 0.78 #:maint 0.45 #:ins 0.12 #:target "1.5k visits" #:dw 13)
   (res "health" 'lpd '("medical skills")  "physicians" 300 #:sat 0.76 #:maint 0.50 #:ins 0.15 #:target "24 people")
   (res "health" 'lpd '("nursing skills")  "nurses"     150 #:sat 0.74 #:maint 0.50 #:ins 0.12 #:target "40 people")
   (res "health" 'mop '("medical equipment") "equipment" 70 #:sat 0.82 #:maint 0.60 #:target "60 units")
   (res "health" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ transport · 700 h ═══
   (res "transport" 'mop '("vehicles")       "bike-share"     200 #:sat 0.90 #:maint 0.50 #:target "60 bikes")
   (res "transport" 'mop '("vehicles")       "car-share"      250 #:sat 0.85 #:maint 0.55 #:target "12 cars")
   (res "transport" 'mop '("infrastructure") "public transit" 180 #:sat 0.92 #:maint 0.60 #:target "8 lines")
   (res "transport" 'mop '("infrastructure") "road maintenance" 40 #:sat 0.80 #:maint 0.95)
   (res "transport" 'adm '() "coordination" 30 #:sat 0.88 #:maint 0.55)
   ;; ═══ energy · 600 h ═══
   (res "energy" 'mop '("generation") "solar" 250 #:sat 0.92 #:maint 0.50 #:target "12 arrays")
   (res "energy" 'mop '("generation") "wind"  200 #:sat 0.90 #:maint 0.50 #:target "8 turbines")
   (res "energy" 'mop '("grid")       "grid"  120 #:sat 0.94 #:maint 0.60 #:target "40 km")
   (res "energy" 'adm '() "coordination" 30 #:sat 0.90 #:maint 0.55)
   ;; ═══ textiles · 500 h ═══
   (res "textiles" 'moc '("individual claimable" "clothing") "garments" 250 #:sat 0.80 #:target "2k items" #:dw 7 #:ds 0.68)
   (res "textiles" 'moc '("individual claimable" "clothing") "fabric"   150 #:sat 0.73 #:target "3k m"     #:dw 5 #:ds 0.70)
   (res "textiles" 'lpd '("textile skills") "weavers" 70 #:sat 0.66 #:maint 0.50 #:target "12 people")
   (res "textiles" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ tool-making · 500 h ═══
   (res "tool-making" 'mop '("tools") "hand tools"  220 #:sat 0.82 #:maint 0.70 #:ins 0.10 #:target "120 pcs")
   (res "tool-making" 'mop '("tools") "power tools" 180 #:sat 0.80 #:maint 0.60 #:target "30 pcs")
   (res "tool-making" 'lpd '("toolmaking skills") "toolmakers" 70 #:sat 0.74 #:maint 0.50 #:target "10 people")
   (res "tool-making" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ forestry · 400 h ═══
   (res "forestry" 'mop '("materials")              "timber"  250 #:sat 0.90 #:maint 0.30 #:target "600 m³")
   (res "forestry" 'moc '("communal" "food" "produce") "foraged" 60 #:sat 0.85 #:maint 0.20 #:target "2t" #:dw 2)
   (res "forestry" 'lpd '("forestry skills") "foresters" 60 #:sat 0.78 #:maint 0.45 #:target "8 people")
   (res "forestry" 'adm '() "coordination" 30 #:sat 0.88 #:maint 0.55)
   ;; ═══ fishing · 350 h ═══
   (res "fishing" 'moc '("individual claimable" "food" "fish") "fish" 180 #:sat 0.78 #:target "4t" #:dw 6 #:ds 0.72)
   (res "fishing" 'moc '("communal" "food" "fish")             "fish"  90 #:sat 0.80 #:maint 0.20 #:target "1.5t" #:dw 3)
   (res "fishing" 'lpd '("fishing skills") "fishers" 50 #:sat 0.70 #:maint 0.45 #:target "10 people")
   (res "fishing" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ arts · 300 h ═══
   (res "arts" 'moc '("communal" "culture")             "performances" 160 #:sat 0.65 #:maint 0.40 #:target "120"     #:dw 6)
   (res "arts" 'moc '("individual claimable" "culture") "artworks"      80 #:sat 0.75 #:target "200 pcs" #:dw 3 #:ds 0.70)
   (res "arts" 'lpd '("arts skills") "artists" 40 #:sat 0.68 #:maint 0.45 #:target "14 people")
   (res "arts" 'adm '() "coordination" 20 #:sat 0.85 #:maint 0.55)
   ;; ═══ mining · 250 h ═══
   (res "mining" 'mop '("materials") "ore"  160 #:sat 0.85 #:maint 0.30 #:target "80t")
   (res "mining" 'mop '("materials") "coal"  60 #:sat 0.84 #:maint 0.30 #:target "40t")
   (res "mining" 'adm '() "coordination" 30 #:sat 0.85 #:maint 0.55)
   ;; ═══ UC admin · 200 h ═══
   (res "UC admin" 'adm '("federation") "verification"     90 #:sat 0.90 #:maint 0.60 #:target "5k events")
   (res "UC admin" 'adm '("federation") "plan coordination" 70 #:sat 0.92 #:maint 0.50)
   (res "UC admin" 'adm '("federation") "refederation"      40 #:sat 0.88 #:maint 0.40)))

;; The two projections of the one registry (both fold to the identical total L).
(define *activities* (build-activities *resources*))
;; The top-level category roots are foldable/zoomable (like activity scopes), so
;; the categories axis shows 4 cells you can drill into — not a dense overview.
;; (The per-scope categories inside an activity stay expanded, as in Figure 2.)
(define *categories*
  (map (lambda (root)
         (node (node-name root) (cons (cons 'scope? #t) (node-attrs root)) (node-kids root)))
       (build-categories (map cdr *resources*))))

;; The federation is the axis-root: its rendered children swap between the two
;; projections by the `categories?` lens; both partition the same total, so the
;; fold (`repro`, on the default `_activities` set) is identical either way.
(define *federation*
  (node "federation"
        (list (cons 'cat 'federation) (cons 'axis-root #t)
              (cons 'activities *activities*) (cons 'categories *categories*))
        *activities*))

;; The food activity node (the showcase scope), exported for tests.
(define *food-scope*
  (let loop ((as *activities*))
    (cond ((null? as) #f)
          ((string=? (node-name (car as)) "food") (car as))
          (else (loop (cdr as))))))

;;; ── the whole tree : playnet → free time + federation ──────────────────────
(define *playnet-tree*
  (node "playnet" (list (cons 'cat 'root))
        (list (leaf "free time" 4800 'free #:sat 0.90)
              *federation*)))
