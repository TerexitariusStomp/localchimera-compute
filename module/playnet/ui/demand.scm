;;; demand.scm — Resource demand specification card (SXML).
;;;
;;; Port of planner/src/lib/components/commune/ResourceDemandCard.svelte.
;;; Operates directly on the ValueFlows records defined in
;;; (playnet vf schemas): <resource-specification>, <intent>,
;;; <measure>, <availability-window>, <specific-date-window>.
;;;
;;; A demand card lists one or more <intent>s under a single
;;; <resource-specification>: quantity + unit, with optional time-pattern
;;; and location pills, and an "+ Add demand" affordance.
;;;
;;; Pure: records in, SXML out. No DOM mutation, no actor refs.
;;; Hoot/WASM compatible.
;;;
;;; UI ephemera (which row's time / location panel is currently expanded)
;;; is NOT part of the VF data model. The caller passes it as a small
;;; <open-state> alist of `(intent-id . panel-kind)` where panel-kind is
;;; one of: 'time, 'loc, #f.
;;;
;;; Callbacks
;;; ---------
;;;   on-add-demand   : ()            → user clicked "+ Add demand"
;;;   on-update-qty   : (intent-id)   → user committed a new quantity
;;;                                      (read input value via the DOM id
;;;                                       returned by demand-qty-input-id)
;;;   on-update-unit  : ()            → user committed a new unit
;;;                                      (read input via demand-unit-input-id)
;;;   on-delete       : (intent-id)   → user clicked ✕ on a row
;;;   on-toggle-time  : (intent-id)   → expand/collapse time pill
;;;   on-toggle-loc   : (intent-id)   → expand/collapse location pill
;;;   on-toggle-claim : ()            → flip commons / individual-claimable

(define-module (playnet ui demand)
  #:use-module (srfi srfi-1)
  #:use-module (playnet ui components)        ; fmt-num, str-join
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond schedules)
  #:use-module (srfi srfi-1); ValueFlows records live here — the
                                         ; umbrella re-exports (playnet vf
                                         ; schemas), so this keeps working
  #:export (demand-card
            demand-row
            add-demand-button
            demand-qty-input-id
            demand-unit-input-id
            intent-claimable?
            format-availability-window
            format-at-location))


;;; ── DOM ids ──────────────────────────────────────────────────────────────────

(define (demand-unit-input-id spec-id)
  (string-append "dc-unit-" (or spec-id "")))

(define (demand-qty-input-id spec-id intent-id)
  (string-append "dc-qty-" (or spec-id "") "-" (or intent-id "")))


;;; ── Intent-level helpers over the VF record ──────────────────────────────────

(define *claimable-tag* "individual-claimable")

(define (intent-claimable? intent)
  "True when INTENT carries the 'individual-claimable' classification tag.
   Mirrors the Svelte component's isClaimable derivation."
  (let ((tags (intent-resource-classified-as intent)))
    (and tags (pair? tags)
         (any (lambda (t) (equal? t *claimable-tag*)) tags))))

(define (intent-qty-number intent)
  "Numerical value of INTENT's resource-quantity <measure>, or 1 if absent."
  (let ((m (intent-resource-quantity intent)))
    (if (and m (measure? m))
        (measure-has-numerical-value m)
        1)))

(define (intent-qty-unit intent fallback-unit)
  "Unit string of INTENT's resource-quantity <measure>, falling back to
   FALLBACK-UNIT (typically the spec's default-unit-of-resource)."
  (let ((m (intent-resource-quantity intent)))
    (or (and m (measure? m) (measure-has-unit m))
        fallback-unit
        "units")))


;;; ── Pretty-print availability-window and at-location ─────────────────────────

(define (format-time-range tr)
  (string-append (time-range-start-time tr) "–" (time-range-end-time tr)))

(define (format-availability-window aw)
  "Compact one-line label for an <availability-window> or
   <specific-date-window>, or #f if AW is #f. Mirrors formatWhen() in
   src/lib/utils/time.ts at a high level — the goal here is a short pill
   string, not a full description."
  (cond
    ((not aw) #f)
    ((specific-date-window? aw)
     (let ((dates (specific-date-window-specific-dates aw)))
       (cond ((null? dates) "—")
             ((null? (cdr dates)) (car dates))
             (else (string-append (car dates)
                                  " +" (number->string (- (length dates) 1)))))))
    ((availability-window? aw)
     (let ((ms  (availability-window-month-schedules aw))
           (ws  (availability-window-week-schedules  aw))
           (ds  (availability-window-day-schedules   aw))
           (trs (availability-window-time-ranges     aw)))
       (cond
         ((and ms (pair? ms))
          (string-append (number->string (length ms)) " months"))
         ((and ws (pair? ws))
          (string-append (number->string (length ws)) " weeks"))
         ((and ds (pair? ds))
          (let ((days (apply append (map day-schedule-days ds))))
            (if (null? days) "—"
                (str-join (map symbol->string days) " "))))
         ((and trs (pair? trs))
          (format-time-range (car trs)))
         (else "—"))))
    (else "—")))

(define (format-at-location at-location)
  "Short label for INTENT's at-location string field.
   Mirrors locLabel() in ResourceDemandCard.svelte."
  (cond
    ((not at-location) "—")
    ((equal? at-location "") "—")
    ((equal? at-location "live") "live")
    ((or (string-prefix? "http://"  at-location)
         (string-prefix? "https://" at-location)) "online")
    ((coord-string? at-location) "coords")
    (else (substring at-location 0
                     (min 8 (string-length at-location))))))

(define (string-prefix? prefix s)
  (and (>= (string-length s) (string-length prefix))
       (string=? prefix (substring s 0 (string-length prefix)))))

(define (coord-string? s)
  ;; Matches "lat,long" — two numeric tokens separated by a comma.
  ;; Cheap test: at least one digit before and after a single comma.
  (let ((n (string-length s)))
    (let loop ((i 0) (seen-comma? #f) (digit-l? #f) (digit-r? #f))
      (cond
        ((>= i n) (and seen-comma? digit-l? digit-r?))
        (else
         (let ((c (string-ref s i)))
           (cond
             ((char=? c #\,)
              (if seen-comma? #f (loop (+ i 1) #t digit-l? digit-r?)))
             ((or (char-numeric? c) (char=? c #\.) (char=? c #\-)
                  (char=? c #\space))
              (loop (+ i 1) seen-comma?
                    (or digit-l? (and (not seen-comma?) (char-numeric? c)))
                    (or digit-r? (and seen-comma?       (char-numeric? c)))))
             (else #f))))))))


;;; ── demand-row ───────────────────────────────────────────────────────────────

(define* (demand-row spec intent
                     #:key (readonly? #f) (compact? #f)
                           (open-panel #f)   ;; 'time, 'loc, or #f
                           on-update-qty on-delete
                           on-toggle-time on-toggle-loc
                           time-panel loc-panel)
  "Single demand row inside a card. SPEC is a <resource-specification>;
   INTENT is an <intent>. OPEN-PANEL selects which (if any) sub-panel
   is currently expanded for this row."
  (let* ((spec-id    (resource-specification-id spec))
         (intent-id  (intent-id intent))
         (qty        (intent-qty-number intent))
         (unit       (intent-qty-unit intent
                                      (resource-specification-default-unit-of-resource spec)))
         (time-lbl   (or (format-availability-window
                          (intent-availability-window intent)) "—"))
         (loc-lbl    (format-at-location (intent-at-location intent)))
         (time-on?   (eq? open-panel 'time))
         (loc-on?    (eq? open-panel 'loc)))
    `(div (@ (class "dc-row-wrap"))
          (div (@ (class "dc-row"))
               ,@(if readonly?
                     `((span (@ (class "dc-qty-text")) ,(fmt-num qty))
                       (span (@ (class "dc-unit-label")) ,unit)
                       ,@(if compact? '()
                             `((span (@ (class "dc-pill")
                                        (title "Time pattern"))
                                     "⏰ " ,time-lbl)
                               (span (@ (class "dc-pill dc-loc-pill")
                                        (title "Location"))
                                     "📍 " ,loc-lbl))))
                     `((input (@ (id ,(demand-qty-input-id spec-id intent-id))
                                 (class "dc-qty")
                                 (type "number")
                                 (value ,(fmt-num qty))
                                 (min "0")
                                 (step "1")
                                 ,@(if on-update-qty
                                       `((change ,(lambda (e)
                                                    (on-update-qty intent-id))))
                                       '())))
                       (span (@ (class "dc-unit-label")) ,unit)
                       ,@(if compact?
                             `((button (@ (class ,(string-append
                                                   "dc-icon-btn"
                                                   (if time-on? " active" "")))
                                          (title ,time-lbl)
                                          ,@(if on-toggle-time
                                                `((click ,(lambda (e)
                                                            (on-toggle-time
                                                             intent-id))))
                                                '()))
                                       "⏰")
                               (button (@ (class ,(string-append
                                                   "dc-icon-btn"
                                                   (if loc-on? " active" "")))
                                          (title ,loc-lbl)
                                          ,@(if on-toggle-loc
                                                `((click ,(lambda (e)
                                                            (on-toggle-loc
                                                             intent-id))))
                                                '()))
                                       "📍"))
                             `((button (@ (class ,(string-append
                                                   "dc-pill"
                                                   (if time-on? " active" "")))
                                          (title "Time pattern")
                                          ,@(if on-toggle-time
                                                `((click ,(lambda (e)
                                                            (on-toggle-time
                                                             intent-id))))
                                                '()))
                                       "⏰ " ,time-lbl)
                               (button (@ (class ,(string-append
                                                   "dc-pill dc-loc-pill"
                                                   (if loc-on? " active" "")))
                                          (title "Location")
                                          ,@(if on-toggle-loc
                                                `((click ,(lambda (e)
                                                            (on-toggle-loc
                                                             intent-id))))
                                                '()))
                                       "📍 " ,loc-lbl)))
                       (button (@ (class "dc-del")
                                  ,@(if on-delete
                                        `((click ,(lambda (e)
                                                    (on-delete intent-id))))
                                        '()))
                               "✕"))))
          ,@(if (and (not readonly?) time-on? time-panel)
                `((div (@ (class "dc-expand")) ,time-panel))
                '())
          ,@(if (and (not readonly?) loc-on? loc-panel)
                `((div (@ (class "dc-expand")) ,loc-panel))
                '()))))


;;; ── add-demand-button ────────────────────────────────────────────────────────

(define (add-demand-button on-add-demand)
  `(button (@ (class "dc-add-row")
              ,@(if on-add-demand
                    `((click ,(lambda (e) (on-add-demand))))
                    '()))
           "+ Add demand"))


;;; ── demand-card ──────────────────────────────────────────────────────────────

(define* (demand-card spec intents
                      #:key (readonly? #f) (compact? #f)
                            (open-state '())   ;; alist intent-id → 'time|'loc|#f
                            (row-panels '())   ;; alist intent-id → (time-sxml . loc-sxml)
                            on-add-demand
                            on-update-qty on-update-unit on-delete
                            on-toggle-time on-toggle-loc
                            on-toggle-claim)
  "Render a resource-demand card.
   SPEC: <resource-specification>.
   INTENTS: list of <intent> conforming to SPEC.
   OPEN-STATE: optional alist of (intent-id . 'time|'loc) marking which
               sub-panel (if any) is currently expanded for that row.
   ROW-PANELS: optional alist of (intent-id . (time-sxml . loc-sxml));
               the time/loc editor SXML is supplied by the parent."
  (let* ((spec-id    (resource-specification-id spec))
         (name       (or (resource-specification-name spec) ""))
         (image      (or (resource-specification-image spec) "📦"))
         (unit       (or (resource-specification-default-unit-of-resource spec)
                         "units"))
         (note       (resource-specification-note spec))
         (claimable? (any intent-claimable? intents))
         (tags       (or (resource-specification-resource-classified-as spec)
                         '())))
    `(div (@ (class ,(string-append "dc-card"
                                    (if compact? " compact" ""))))
          ;; Header
          (div (@ (class "dc-card-header"))
               (span (@ (class "dc-emoji")) ,image)
               (span (@ (class "dc-spec-name")) ,name)
               (button (@ (class ,(string-append
                                   "dc-type-toggle"
                                   (if claimable? " dc-type-toggle--claim" "")))
                          (title ,(if claimable?
                                      "Claimable — click to make commons"
                                      "Commons — click to make claimable"))
                          ,@(if (or readonly? (not on-toggle-claim))
                                '((disabled "true"))
                                `((click ,(lambda (e) (on-toggle-claim))))))
                       ,(if claimable? "◆" "∞"))
               ,(if readonly?
                    `(span (@ (class "dc-unit-display")) ,unit)
                    `(input (@ (id ,(demand-unit-input-id spec-id))
                               (class "dc-unit-input")
                               (type "text")
                               (value ,unit)
                               (title "Unit (applies to all rows)")
                               ,@(if on-update-unit
                                     `((change ,(lambda (e) (on-update-unit))))
                                     '())))))

          ;; Optional: art band + tags + note (non-compact only)
          ,@(if compact? '()
                `((div (@ (class "dc-card-art") (aria-hidden "true")))
                  ,@(let ((shown (filter (lambda (t)
                                           (not (equal? t "communal-demand")))
                                         tags)))
                      (if (null? shown) '()
                          `((div (@ (class "dc-tag-row"))
                                 ,@(map (lambda (t)
                                          `(span (@ (class
                                                     ,(string-append
                                                       "dc-class-tag dc-class-tag--"
                                                       t)))
                                                 ,t))
                                        shown)))))
                  ,@(if note `((p (@ (class "dc-card-desc")) ,note)) '())))

          ;; Demand rows
          (div (@ (class "dc-rows"))
               ,@(map (lambda (intent)
                        (let* ((iid    (intent-id intent))
                               (panels (assoc-ref row-panels iid))
                               (tp     (and (pair? panels) (car panels)))
                               (lp     (and (pair? panels) (cdr panels)))
                               (open   (assoc-ref open-state iid)))
                          (demand-row spec intent
                                      #:readonly? readonly?
                                      #:compact? compact?
                                      #:open-panel open
                                      #:on-update-qty on-update-qty
                                      #:on-delete on-delete
                                      #:on-toggle-time on-toggle-time
                                      #:on-toggle-loc on-toggle-loc
                                      #:time-panel tp
                                      #:loc-panel lp)))
                      intents)
               ,@(if (or readonly? (not on-add-demand)) '()
                     `(,(add-demand-button on-add-demand)))))))
