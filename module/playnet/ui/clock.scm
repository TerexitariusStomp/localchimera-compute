;;; playnet ui clock — the social-time dial.
;;;
;;; One clock, two readings, joined by a pinch. The angle is the hour
;;; (midnight on top, the day runs clockwise). The radius is need
;;; satisfaction: at zoom 0 the dial is YOUR day — each hour wholly work
;;; (blue) or free (gold), sharply cut, deep up to the share of your
;;; needs met that hour and pale beyond. Pinch two fingers together and
;;; the dial zooms out to society: the radius becomes the share of
;;; everyone's needs met, and the sharp cuts grade into continuous
;;; bands — a blue core of work, a gold band of play, a pale rim of
;;; unmet free time. Both readings are the same four-fraction stack
;;; (work-met, work-unmet, play, free-unmet); the zoom is a linear
;;; blend, so the geometry never jumps.
;;;
;;; Events (intents with a clock time) ride the OUTER EDGE of the
;;; circle as labelled arcs — outside the face so they never occlude
;;; the distribution. Overlapping events stack outward into lanes:
;;; the first event claims the lane closest to the rim, an overlap in
;;; time takes the next lane out. Events live during work hours and
;;; free hours alike, and they need not tile a band — work is a share
;;; of the hour, not a calendar block.
;;;
;;; This module is pure SXML: all state (zoom, pinch tracking) lives
;;; with the caller, which passes handlers in.

(define-module (playnet ui clock)
  #:use-module (ice-9 optargs)
  #:use-module (srfi srfi-1)
  #:export (clock-surface *clock-demo-events*))

;; ── palette (same as docs/social-time.typ) ─────────────────────────────
(define c-work "#1581a8")       ; work, needs met: cyan blue
(define c-work-pale "#9fcbdf")  ; work, unmet: pale cyan
(define c-play "#e2a512")       ; play: sun gold
(define c-free-pale "#fdf2cf")  ; free, not play: pale dawn
(define c-deep "#2c4a6e")       ; chrome
(define c-time "#c62828")       ; clock chrome: hour marks + satisfaction axis
(define c-faint "#888888")

(define pi 3.141592653589793)

;; ── tiny numeric / colour helpers ──────────────────────────────────────
(define (n->s x)
  ;; short decimal string for SVG attributes
  (let* ((r (/ (round (* (exact->inexact x) 100.0)) 100.0)))
    (number->string r)))

(define (hex->rgb h)            ; "#rrggbb" -> (r g b)
  (let ((n (string->number (substring h 1) 16)))
    (list (quotient n 65536) (modulo (quotient n 256) 256) (modulo n 256))))

(define (rgb->hex rgb)
  (string-append
   "#"
   (string-concatenate
    (map (lambda (v)
           (let* ((i (max 0 (min 255 (inexact->exact (round v)))))
                  (s (number->string i 16)))
             (if (< i 16) (string-append "0" s) s)))
         rgb))))

(define (mix-hex a b f)         ; f in [0,1]: 0 -> a, 1 -> b
  (rgb->hex (map (lambda (x y) (+ x (* f (- y x))))
                 (hex->rgb a) (hex->rgb b))))

(define (clamp x lo hi) (max lo (min hi x)))

;; ── clock geometry: hours -> screen ────────────────────────────────────
;; midnight on top, clockwise; SVG y grows downward.
(define (hr->x cx r t) (+ cx (* r (sin (* t (/ pi 12.0))))))
(define (hr->y cy r t) (- cy (* r (cos (* t (/ pi 12.0))))))

(define (arc-path cx cy r t0 t1 sweep)
  ;; bare arc (no fill) from t0 to t1 at radius r
  (string-append
   "M " (n->s (hr->x cx r t0)) " " (n->s (hr->y cy r t0))
   " A " (n->s r) " " (n->s r) " 0 "
   (if (> (- t1 t0) 12.0) "1" "0") " " sweep " "
   (n->s (hr->x cx r t1)) " " (n->s (hr->y cy r t1))))

(define (wedge-path cx cy r t0 t1)
  ;; pie wedge centre -> t0 -> arc -> centre
  (string-append "M " (n->s cx) " " (n->s cy)
                 " L " (n->s (hr->x cx r t0)) " " (n->s (hr->y cy r t0))
                 " A " (n->s r) " " (n->s r) " 0 "
                 (if (> (- t1 t0) 12.0) "1" "0") " 1 "
                 (n->s (hr->x cx r t1)) " " (n->s (hr->y cy r t1))
                 " Z"))

(define (band-path cx cy r0 r1 t0 t1)
  ;; annular band between radii r0 < r1, from t0 to t1
  (string-append
   "M " (n->s (hr->x cx r1 t0)) " " (n->s (hr->y cy r1 t0))
   " A " (n->s r1) " " (n->s r1) " 0 "
   (if (> (- t1 t0) 12.0) "1" "0") " 1 "
   (n->s (hr->x cx r1 t1)) " " (n->s (hr->y cy r1 t1))
   " L " (n->s (hr->x cx r0 t1)) " " (n->s (hr->y cy r0 t1))
   " A " (n->s r0) " " (n->s r0) " 0 "
   (if (> (- t1 t0) 12.0) "1" "0") " 0 "
   (n->s (hr->x cx r0 t0)) " " (n->s (hr->y cy r0 t0))
   " Z"))

;; ── the day, two scales ────────────────────────────────────────────────
;; your day: each hour wholly work or free, with your priority-weighted
;; need satisfaction (t0 t1 kind s0 s1)
(define day-you
  '((0.0 6.5 free 0.75 0.75)    ; sleep
    (6.5 8.0 free 0.55 0.45)    ; morning rush
    (8.0 9.0 work 0.35 0.40)    ; commute
    (9.0 13.0 work 0.60 0.70)
    (13.0 14.0 free 0.65 0.65)  ; lunch
    (14.0 18.0 work 0.60 0.40)  ; afternoon slog
    (18.0 19.0 work 0.30 0.35)  ; commute home
    (19.0 20.5 work 0.45 0.50)  ; chores
    (20.5 23.0 free 0.70 0.85)  ; evening
    (23.0 24.0 free 0.80 0.75)))

;; everyone's day: (t0 t1 wf0 wf1 pf0 pf1), met share of work below.
;; The dial is the whole earth — some longitude is always at work — so
;; the distribution is nearly even around the clock: about half of all
;; hours are work, mostly unmet, and the free half is mostly unmet too.
(define day-all
  '((0.0 6.0 0.50 0.48 0.13 0.12)
    (6.0 12.0 0.48 0.53 0.12 0.13)
    (12.0 18.0 0.53 0.50 0.13 0.12)
    (18.0 24.0 0.50 0.50 0.12 0.13)))
(define sw-all 0.28)

(define (seg-at prof t)
  (find (lambda (s) (and (>= t (car s)) (< t (cadr s)))) prof))

;; both readings reduce to the same stack: (work-met work-unmet play free-unmet)
(define (fractions-you t)
  (let* ((seg (or (seg-at day-you t) (last day-you)))
         (t0 (car seg)) (t1 (cadr seg)) (kind (caddr seg))
         (s0 (list-ref seg 3)) (s1 (list-ref seg 4))
         (fr (/ (- t t0) (max 0.001 (- t1 t0))))
         (s (+ s0 (* fr (- s1 s0)))))
    (if (eq? kind 'work)
        (list s (- 1.0 s) 0.0 0.0)
        (list 0.0 0.0 s (- 1.0 s)))))

(define (fractions-all t)
  (let* ((seg (or (seg-at day-all t) (last day-all)))
         (t0 (car seg)) (t1 (cadr seg))
         (fr (/ (- t t0) (max 0.001 (- t1 t0))))
         (wf (+ (list-ref seg 2) (* fr (- (list-ref seg 3) (list-ref seg 2)))))
         (pf (+ (list-ref seg 4) (* fr (- (list-ref seg 5) (list-ref seg 4))))))
    (list (* wf sw-all) (* wf (- 1.0 sw-all)) pf (- 1.0 wf pf))))

(define (fractions-blend t zoom)
  (map (lambda (a b) (+ (* (- 1.0 zoom) a) (* zoom b)))
       (fractions-you t) (fractions-all t)))

;; ── radial gradient per slice ──────────────────────────────────────────
;; the radius IS satisfaction: met time at the centre, unmet at the rim —
;; met work (deep blue) -> play (gold) -> unmet work (pale cyan) ->
;; unmet free time (pale gold). Blends live in a FIXED window around
;; each band boundary so thin bands stay crisp.
;; R0FRAC is the centre disc's share of the gradient radius: the bands
;; BEGIN at the disc's circumference (0% satisfaction) and end at the
;; rim (100%) — nothing hides behind the disc.
(define (slice-stops fracs r0frac)
  (let* ((w 0.05)
         (pc (lambda (x)
               (string-append
                (n->s (* 100.0 (+ r0frac (* (clamp x 0.0 1.0) (- 1.0 r0frac)))))
                "%")))
         ;; only bands that actually have mass take part: a zero-width
         ;; band must not paint its colour into the boundary blend — at
         ;; zoom 0 a work hour has NO play band, so no gold may halo the
         ;; blue; the cuts stay clean and the blends appear only as the
         ;; zoom gives the missing bands mass
         (bands (filter (lambda (b) (> (cdr b) 0.004))
                        (list (cons c-work (car fracs))
                              (cons c-play (caddr fracs))
                              (cons c-work-pale (cadr fracs))
                              (cons c-free-pale (cadddr fracs))))))
    (if (null? bands)
        `((stop (@ (offset "0%") (stop-color ,c-free-pale))))
        (let loop ((bs bands) (c 0.0) (prev 0.0)
                   (acc (list `(stop (@ (offset ,(pc 0.0))
                                        (stop-color ,(caar bands)))))))
          (if (null? (cdr bs))
              (reverse
               (cons `(stop (@ (offset "100%") (stop-color ,(caar bs)))) acc))
              (let* ((c2 (+ c (cdar bs)))
                     (o1 (max prev (- c2 w)))
                     (o2 (max o1 (+ c2 w))))
                (loop (cdr bs) c2 o2
                      (cons `(stop (@ (offset ,(pc o2))
                                      (stop-color ,(car (cadr bs)))))
                            (cons `(stop (@ (offset ,(pc o1))
                                            (stop-color ,(caar bs))))
                                  acc)))))))))

;; ── band-label placement: ride the colour's centroid ──────────────────
;; (mass . band-mid-radial-fraction) for MODE under the satisfaction-
;; ordered stack above.
(define (band-mass-mid fracs mode)
  (let ((wm (car fracs)) (wu (cadr fracs))
        (pf (caddr fracs)) (uf (cadddr fracs)))
    (case mode
      ((work) (cons wm (* 0.5 wm)))                  ; labour, met
      ((play) (cons pf (+ wm (* 0.5 pf))))           ; free, met
      ((toil) (cons wu (+ wm pf (* 0.5 wu))))        ; labour, unmet
      (else (cons uf (+ wm pf wu (* 0.5 uf)))))))    ; waste: free, unmet

;; angle: mass-weighted circular mean over the day (falls back to
;; DEFAULT-HR when the mass is spread evenly around the clock); radius:
;; the band's mid at that hour. So as the zoom morphs the distribution,
;; each label gracefully re-triangulates to the centroid of its colour.
(define (label-spot mode zoom default-hr R)
  (let loop ((i 0) (sx 0.0) (sy 0.0) (mass 0.0))
    (if (< i 48)
        (let* ((t (* (+ i 0.5) 0.5))
               (mm (band-mass-mid (fractions-blend t zoom) mode))
               (m (car mm))
               (a (* t (/ pi 12.0))))
          (loop (+ i 1) (+ sx (* m (sin a))) (+ sy (* m (cos a))) (+ mass m)))
        (let* ((mag (sqrt (+ (* sx sx) (* sy sy))))
               (hr (if (or (< mass 0.001)
                           (< (/ mag (max mass 0.001)) 0.12))
                       default-hr
                       (let ((h (* (atan sx sy) (/ 12.0 pi))))
                         (if (< h 0.0) (+ h 24.0) h))))
               (mid (cdr (band-mass-mid (fractions-blend hr zoom) mode)))
               ;; bands live in the annulus disc-edge..rim
               (r (max 44.0 (min (- R 14.0) (+ 30.0 (* mid (- R 30.0)))))))
          (cons hr r)))))

;; ── events on the outer edge ───────────────────────────────────────────
;; (label t0 t1 kind) — kind 'work or 'free decides the band colour.
(define *clock-demo-events*
  '(("breakfast" 7.0 7.75 free)
    ("standup" 9.0 9.5 work)
    ("harvest shift" 9.5 12.0 work)
    ("lunch w/ Ana" 13.0 14.0 free)
    ("repair café" 15.0 16.5 work)
    ("school run" 16.0 16.75 free)
    ("band practice" 19.5 21.0 free)))

;; overlapping events stack outward: lane 0 hugs the rim, an overlap in
;; time takes the next lane out.
(define (assign-lanes events)
  (let loop ((evs (sort events (lambda (a b) (< (cadr a) (cadr b)))))
             (lane-ends '())     ; end hour per lane, index = lane
             (acc '()))
    (if (null? evs)
        (reverse acc)
        (let* ((ev (car evs))
               (t0 (cadr ev))
               (lane (or (list-index (lambda (e) (<= e (+ t0 0.001))) lane-ends)
                         (length lane-ends)))
               (ends (let upd ((l lane-ends) (i 0))
                       (cond ((null? l) (list (caddr ev)))
                             ((= i lane) (cons (caddr ev) (cdr l)))
                             (else (cons (car l) (upd (cdr l) (+ i 1))))))))
          (loop (cdr evs) ends (cons (cons lane ev) acc))))))

(define (render-event cx cy R idx lane+ev zoom)
  (let* ((lane (car lane+ev))
         (ev (cdr lane+ev))
         (label (car ev)) (t0 (cadr ev)) (t1 (caddr ev)) (kind (cadddr ev))
         (r0 (+ R 4 (* lane 15)))
         (r1 (+ r0 12))
         (col (if (eq? kind 'work) c-work c-play))
         (pid (string-append "ck-ev-" (number->string idx)))
         ;; lower half of the clock (hours ~6..18): run the label path
         ;; the other way round so the text never reads upside down
         (bottom? (let ((mid (/ (+ t0 t1) 2.0))) (and (> mid 6.0) (< mid 18.0))))
         ;; baseline radius differs per orientation so glyphs centre in the band
         (rmid (if bottom? (+ r0 7.5) (+ r0 5.5)))
         ;; your events fade as you zoom out to everyone
         (op (n->s (+ 0.15 (* 0.85 (- 1.0 zoom))))))
    `(g (@ (opacity ,op))
        (path (@ (d ,(band-path cx cy r0 r1 t0 t1))
                 (fill ,col) (stroke "#ffffff") (stroke-width "1")))
        (defs (path (@ (id ,pid)
                       (d ,(if bottom?
                               (arc-path cx cy rmid t1 t0 "0")
                               (arc-path cx cy rmid t0 t1 "1")))
                       (fill "none"))))
        (text (@ (font-size "8.5") (fill "#ffffff") (font-weight "bold")
                 (dominant-baseline "middle"))
              (textPath (@ (href ,(string-append "#" pid))
                           (startOffset "50%") (text-anchor "middle"))
                        ,label)))))

;; ── the dial ───────────────────────────────────────────────────────────
(define* (clock-surface #:key (zoom 0.0) (events *clock-demo-events*)
                        (on-pointer-down #f) (on-pointer-move #f)
                        (on-pointer-up #f) (on-wheel #f) (on-slider #f))
  (let* ((W 560) (H 560)
         (cx 280.0) (cy 280.0)
         (R 190.0)
         (dt 0.5)                          ; angular slice, hours
         (nslices (inexact->exact (round (/ 24.0 dt))))
         (handlers
          (append
           (if on-pointer-down `((pointerdown ,on-pointer-down)) '())
           (if on-pointer-move `((pointermove ,on-pointer-move)) '())
           (if on-pointer-up `((pointerup ,on-pointer-up)
                               (pointercancel ,on-pointer-up)
                               (pointerleave ,on-pointer-up))
               '())
           (if on-wheel `((wheel ,on-wheel)) '()))))
    `(div (@ (class "clock-frame"))
          (svg (@ (viewBox ,(string-append "0 0 " (number->string W) " "
                                           (number->string H)))
                  (class "clock-svg")
                  ,@handlers)
               ;; per-slice radial gradients: the social-time distribution
               (defs
                ,@(map (lambda (i)
                         (let* ((t (* (+ i 0.5) dt))
                                (fr (fractions-blend t zoom)))
                           `(radialGradient
                             (@ (id ,(string-append "ck-g" (number->string i)))
                                (gradientUnits "userSpaceOnUse")
                                (cx ,(n->s cx)) (cy ,(n->s cy)) (r ,(n->s R)))
                             ,@(slice-stops fr (/ 30.0 R)))))
                       (iota nslices)))
               ;; the face
               (g ,@(map (lambda (i)
                           (let ((t0 (* i dt)) (t1 (* (+ i 1) dt)))
                             `(path (@ (d ,(wedge-path cx cy (+ R 0.5) t0 t1))
                                       (fill ,(string-append
                                               "url(#ck-g" (number->string i) ")"))
                                       (stroke "none")))))
                         (iota nslices)))
               ;; sharp seams between your work and free, dissolving with zoom
               ,@(let ((seam-op (- 1.0 zoom)))
                   (if (< seam-op 0.02)
                       '()
                       (let loop ((segs day-you) (prev (caddr (last day-you)))
                                  (out '()))
                         (if (null? segs)
                             (reverse out)
                             (let* ((seg (car segs)) (kind (caddr seg)))
                               (loop (cdr segs) kind
                                     (if (eq? kind prev)
                                         out
                                         (cons
                                          `(line (@ (x1 ,(n->s cx)) (y1 ,(n->s cy))
                                                    (x2 ,(n->s (hr->x cx R (car seg))))
                                                    (y2 ,(n->s (hr->y cy R (car seg))))
                                                    (stroke "#ffffff")
                                                    (stroke-width "1.5")
                                                    (opacity ,(n->s seam-op))))
                                          out))))))))
               ;; rim
               (circle (@ (cx ,(n->s cx)) (cy ,(n->s cy)) (r ,(n->s R))
                          (fill "none") (stroke ,c-deep) (stroke-width "1.5")))
               ;; hour marks on the face, just inside the rim
               ,@(append-map
                  (lambda (h)
                    (let ((major? (= 0 (modulo h 6))))
                      `((line (@ (x1 ,(n->s (hr->x cx R h)))
                                 (y1 ,(n->s (hr->y cy R h)))
                                 (x2 ,(n->s (hr->x cx (- R (if major? 10 5)) h)))
                                 (y2 ,(n->s (hr->y cy (- R (if major? 10 5)) h)))
                                 (stroke ,c-time)
                                 (stroke-width ,(if major? "2.4" "1.1"))))
                        ,@(if major?
                              `((text (@ (x ,(n->s (hr->x cx (- R 22) h)))
                                         (y ,(n->s (+ (hr->y cy (- R 22) h) 3)))
                                         (font-size "11") (fill ,c-time)
                                         (font-weight "bold")
                                         (text-anchor "middle"))
                                      ,(number->string h)))
                              '()))))
                  (iota 24))
               ;; radial axis along hour 3: whose needs the radius counts
               (line (@ (x1 ,(n->s cx)) (y1 ,(n->s cy))
                        (x2 ,(n->s (hr->x cx (- R 2) 3))) (y2 ,(n->s (hr->y cy (- R 2) 3)))
                        (stroke ,c-time) (stroke-width "1.8")))
               (path (@ (d ,(let ((tipx (hr->x cx (- R 2) 3)) (tipy (hr->y cy (- R 2) 3)))
                              (string-append
                               "M " (n->s tipx) " " (n->s tipy)
                               " l -11 1.5 l 4 -8.5 Z")))
                        (fill ,c-time)))
               ;; axis label: starts just past the centre and runs UP along
               ;; the spoke (figure-style); switches your -> social the
               ;; moment you zoom out, and back at zoom 0
               ,(let ((lx (- (hr->x cx 44 3) 4))
                      (ly (- (hr->y cy 44 3) 4)))
                  `(text (@ (x ,(n->s lx)) (y ,(n->s ly))
                            (font-size "10.5") (fill ,c-time) (font-style "italic")
                            (font-weight "bold")
                            (text-anchor "start")
                            (transform ,(string-append
                                         "rotate(-45 " (n->s lx) " " (n->s ly) ")")))
                         "satisfaction"))
               ;; band labels ride the centroid of their colour mass,
               ;; re-triangulating gracefully as the zoom morphs the bands
               ,@(map (lambda (spec)
                        (let* ((mode (car spec))
                               (dh (cadr spec))
                               (txt (caddr spec))
                               (paint (cadddr spec))
                               (spot (label-spot mode zoom dh R))
                               (hr (car spot))
                               (r (cdr spot)))
                          `(text (@ (x ,(n->s (hr->x cx r hr)))
                                    (y ,(n->s (+ (hr->y cy r hr) 4)))
                                    (font-size "11") (fill ,paint)
                                    (font-weight "bold")
                                    (text-anchor "middle"))
                                 ,txt)))
                      '((work 12.0 "work" "#ffffff")
                        (play 21.5 "play" "#ffffff")
                        (toil 16.5 "toil" "#0d5066")
                        (waste 1.5 "waste" "#8a6a10")))
               ;; centre: who the dial is showing
               (circle (@ (cx ,(n->s cx)) (cy ,(n->s cy)) (r "30")
                          (fill "#ffffff") (stroke ,c-deep) (stroke-width "1")))
               ,(let* ((who (cond ((< zoom 0.05) "you")
                                  ((> zoom 0.95) "everyone")
                                  (else (string-append
                                         (number->string
                                          (inexact->exact (round (* zoom 100))))
                                         "%"))))
                       ;; scale the name to the disc so it never exceeds it
                       (fs (min 11.0 (/ 66.0 (max 1 (string-length who))))))
                  `(text (@ (x ,(n->s cx)) (y ,(n->s (+ cy 3)))
                           (font-size ,(n->s fs)) (fill ,c-deep)
                           (font-weight "bold") (text-anchor "middle"))
                        ,who))
               ;; events ride the outer edge, stacking outward on overlap
               ,@(let ((laned (assign-lanes events)))
                   (map (lambda (idx l+e) (render-event cx cy R idx l+e zoom))
                        (iota (length laned)) laned)))
          ;; zoom controls: pinch on the dial, or slide
          (div (@ (class "clock-controls"))
               (span (@ (class "clock-zoom-end")) "you")
               (input (@ (type "range") (min "0") (max "100") (step "1")
                         (id "clock-zoom-slider")
                         (class "clock-zoom-slider")
                         (value ,(number->string
                                  (inexact->exact (round (* zoom 100)))))
                         ,@(if on-slider `((input ,on-slider)) '())))
               (span (@ (class "clock-zoom-end")) "everyone")))))
