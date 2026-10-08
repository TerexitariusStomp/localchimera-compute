;;; map.scm — geographic map tab UI
;;;
;;; Pure SXML for the layout (container div + side panel). The MapLibre
;;; GL instance itself is imperative and lives in repl.scm (FFI bindings
;;; + *map-instance* global + mount hook). This module owns:
;;;
;;;   - Marker record types (grouped-slot-marker, cluster-marker)
;;;   - Side-panel SXML (mirrors MapSidePanel.svelte structure)
;;;   - The map-view skeleton: container + overlay panel + controls
;;;
;;; Inspired by docs/free-assoc/src/lib/components/Map.svelte +
;;; MapSidePanel.svelte. We don't port svelte-maplibre-gl; we drive the
;;; raw maplibre-gl JS API through the "map" FFI namespace.

(define-module (playnet ui map)
  #:use-module (srfi srfi-9)
  #:export (make-grouped-slot-marker
            grouped-slot-marker?
            gsm-id gsm-capacity gsm-slots gsm-lng gsm-lat
            gsm-source gsm-provider gsm-location-key

            make-cluster-marker
            cluster-marker?
            cm-id cm-lng cm-lat cm-markers cm-total-slots cm-total-capacities

            map-view
            map-side-panel
            empty-side-panel
            marker-sxml))

;;; ── Marker records ──────────────────────────────────────────────────────────
;;;
;;; A "grouped slot marker" is one icon on the map representing all slots
;;; from a single capacity at a single (lat,lng). A "cluster marker" is a
;;; bubble that groups several grouped-slot-markers together at low zoom.

(define-record-type <grouped-slot-marker>
  (make-grouped-slot-marker id capacity slots lng lat source provider location-key)
  grouped-slot-marker?
  (id           gsm-id)
  (capacity     gsm-capacity)
  (slots        gsm-slots)
  (lng          gsm-lng)
  (lat          gsm-lat)
  (source       gsm-source)        ;; 'coordinates or 'geocoded
  (provider     gsm-provider)
  (location-key gsm-location-key))

(define-record-type <cluster-marker>
  (make-cluster-marker id lng lat markers total-slots total-capacities)
  cluster-marker?
  (id               cm-id)
  (lng              cm-lng)
  (lat              cm-lat)
  (markers          cm-markers)
  (total-slots      cm-total-slots)
  (total-capacities cm-total-capacities))

;;; ── Marker DOM (handed to maplibre via the "map" FFI) ───────────────────────
;;;
;;; The map FFI's makeMarker takes an element built on the Scheme side.
;;; sxml->dom (in repl.scm) realises this. The caller supplies the click
;;; handler so this module stays free of repl state.

(define (marker-sxml marker on-click)
  (cond
   ((cluster-marker? marker)
    (let ((emojis (cluster-emojis marker)))
      `(div (@ (class "map-cluster-marker")
               (click ,on-click))
            ,(if (<= (length emojis) 9)
                 `(div (@ (class "emoji-pack"))
                       ,@(map (lambda (e) `(span (@ (class "packed-emoji")) ,e))
                              emojis))
                 `(div (@ (class "cluster-count"))
                       (div (@ (class "cluster-count-n"))
                            ,(number->string (cm-total-capacities marker)))
                       (div (@ (class "cluster-count-label"))
                            "capacities"))))))
   ((grouped-slot-marker? marker)
    (let* ((slots (gsm-slots marker))
           (first (and (pair? slots) (car slots)))
           (emoji (or (and first (slot-emoji first))
                      (if (and (pair? slots) (pair? (cdr slots))) "📦" "🎁")))
           (label (cond
                   ((null? slots) "")
                   ((null? (cdr slots)) (slot-name first))
                   (else (string-append (number->string (length slots)) " slots")))))
      `(div (@ (class "map-slot-marker")
               (click ,on-click))
            (div (@ (class "marker-icon")) ,emoji)
            (div (@ (class "marker-label")) ,label))))
   (else
    `(div (@ (class "map-marker")) "?"))))

(define (slot-emoji slot)
  "Field-access shim — accepts either an assoc list or a record."
  (cond
   ((not slot) #f)
   ((pair? slot) (let ((p (assq 'emoji slot))) (and p (cdr p))))
   (else #f)))

(define (slot-name slot)
  (cond
   ((not slot) "")
   ((pair? slot) (let ((p (assq 'name slot))) (if p (cdr p) "")))
   (else "")))

(define (cluster-emojis cluster)
  (let loop ((ms (cm-markers cluster)) (seen '()))
    (if (null? ms)
        (reverse seen)
        (let* ((m (car ms))
               (slots (if (grouped-slot-marker? m) (gsm-slots m) '()))
               (e (and (pair? slots) (slot-emoji (car slots)))))
          (loop (cdr ms)
                (if (and e (not (member e seen))) (cons e seen) seen))))))

;;; ── Side panel ──────────────────────────────────────────────────────────────
;;;
;;; Mirrors the structure of MapSidePanel.svelte: header with close, then
;;; either a search-result list, a cluster-contents list, or the detail
;;; view for a single grouped-slot-marker.

(define (search-row search-query on-search on-clear)
  "Search bar + 'Any Time' filter pill, mirrors the target screenshots."
  `(div (@ (class "map-search-row"))
        (div (@ (class "map-search-input-wrap"))
             (input (@ (class "map-search-input")
                       (id "map-search")
                       (type "text")
                       (placeholder "Search offers…")
                       (value ,(or search-query ""))
                       (input ,on-search)))
             ,@(if (and search-query (not (string=? search-query "")))
                   (list `(span (@ (class "map-search-clear")
                                   (click ,on-clear))
                                "×"))
                   '()))
        (div (@ (class "map-time-pill")
                (title "Time filter (placeholder)"))
             (span (@ (class "map-time-icon")) "⏱")
             (span (@ (class "map-time-label")) "Any Time")
             (span (@ (class "map-time-caret")) "▾"))))

(define* (map-side-panel selected
                         on-close
                         on-marker-click
                         #:key
                         (search-query "")
                         (search-results '())
                         (on-search (lambda (e) #f))
                         (on-search-clear (lambda (e) #f))
                         (on-result-click (lambda (m) #f))
                         (journey #f)
                         (on-route #f)
                         (on-journey-profile (lambda (p) #f))
                         (on-journey-clear (lambda (e) #f))
                         (on-journey-commit #f)
                         (on-journey-arrive #f)
                         (journey-extra #f)
                         (idle-extra #f))
  "Always-rendered floating card. Always shows the search row; the body
   beneath it is one of: hint (idle), search results, active journey,
   cluster contents, detail view."
  `(div (@ (class "map-side-panel"))
        ,(search-row search-query on-search on-search-clear)
        ,(cond
          ;; Active search wins over selection so the list stays visible.
          ((and search-query (not (string=? search-query "")))
           (search-results-body search-query search-results on-result-click))
          ;; An active journey owns the panel until cleared.
          (journey
           (journey-body journey on-journey-profile on-journey-clear
                         #:on-commit on-journey-commit
                         #:on-arrive on-journey-arrive
                         #:extra journey-extra))
          ((cluster-marker? selected)
           (cluster-body selected on-close on-marker-click))
          ((grouped-slot-marker? selected)
           (detail-body selected on-close #:on-route on-route))
          (else (hint-body idle-extra)))))

(define* (hint-body #:optional (extra #f))
  `(div (@ (class "panel-body"))
        (div (@ (class "panel-hint"))
             "Click a marker to see capacity details.")
        ,@(if extra (list extra) '())))

(define (search-results-body query results on-result-click)
  `(div (@ (class "panel-body search-body"))
        (div (@ (class "search-summary"))
             (div (@ (class "search-summary-count"))
                  ,(number->string (length results)) " RESULTS")
             (div (@ (class "search-summary-sort"))
                  "By Relevance ▾"))
        ,@(if (null? results)
              (list `(div (@ (class "panel-hint"))
                          "No matches for \"" ,query "\"."))
              (map (lambda (m)
                     `(div (@ (class "search-card")
                              (click ,(lambda (e) (on-result-click m))))
                           ,@(result-card-sxml m)))
                   results))))

(define (result-card-sxml m)
  "Compact 2-row card: emoji + name, then provider + slot count."
  (let* ((cap   (gsm-capacity m))
         (name  (capacity-field cap 'name "(unnamed)"))
         (emoji (or (capacity-field cap 'emoji #f)
                    (and (pair? (gsm-slots m))
                         (slot-emoji (car (gsm-slots m))))
                    "🎁"))
         (prov  (or (gsm-provider m) "")))
    `((div (@ (class "search-card-title"))
           (span (@ (class "search-card-emoji")) ,emoji)
           (span (@ (class "search-card-name")) ,name))
      (div (@ (class "search-card-meta"))
           (span (@ (class "search-card-provider")) "👤 " ,prov)
           (span (@ (class "search-card-badge"))
                 ,(number->string (length (gsm-slots m))) " slots")))))

(define (cluster-body cluster on-close on-marker-click)
  `(div (@ (class "panel-body"))
        (div (@ (class "panel-section-title"))
             ,(number->string (cm-total-capacities cluster))
             " items at this location"
             (span (@ (class "panel-close") (click ,on-close)) " ×"))
        ,@(map (lambda (m)
                 `(div (@ (class "panel-row")
                          (click ,(lambda (e) (on-marker-click m))))
                       ,(marker-row-sxml m)))
               (cm-markers cluster))))

(define* (detail-body mk on-close #:key (on-route #f))
  (let* ((slots (gsm-slots mk))
         (cap (gsm-capacity mk))
         (cap-name (capacity-field cap 'name "Capacity"))
         (provider (or (gsm-provider mk) "")))
    `(div (@ (class "panel-body"))
          (div (@ (class "panel-section-title"))
               ,cap-name
               (span (@ (class "panel-close") (click ,on-close)) " ×"))
          ,@(if (string=? provider "") '()
                (list `(div (@ (class "panel-meta")) "Provider: " ,provider)))
          (div (@ (class "panel-meta"))
               "📍 " ,(format-lnglat (gsm-lng mk) (gsm-lat mk)))
          ,@(if on-route
                (list `(div (@ (class "journey-route-btn")
                               (click ,(lambda (e) (on-route mk))))
                            "⇀ route here"))
                '())
          (div (@ (class "panel-section-title"))
               "Availability (" ,(number->string (length slots)) ")")
          ,@(map (lambda (s) `(div (@ (class "panel-slot"))
                                   ,(marker-row-sxml s)))
                 slots))))

;;; ── Journey (route to a marker) ─────────────────────────────────────────────
;;;
;;; Pure rendering of an active journey — repl.scm owns the route state and
;;; the Valhalla round-trip; this body just shows what it's handed:
;;;   journey = alist with dest-name / profile / summary / turns,
;;;   where turns is a list of instruction strings (possibly empty while
;;;   the route is still being fetched, or on the straight-line fallback).

(define %journey-profiles
  '(("foot" . "🚶") ("bike" . "🚲") ("car" . "🚗") ("transit" . "🚌")))

(define (journey-field j key default)
  (let ((p (assq key j))) (if p (cdr p) default)))

(define* (journey-body j on-profile on-clear #:key (on-commit #f) (on-arrive #f)
                                                  (extra #f))
  (let ((profile (journey-field j 'profile "foot"))
        (summary (journey-field j 'summary ""))
        (turns   (journey-field j 'turns '())))
    `(div (@ (class "panel-body journey-body"))
          (div (@ (class "panel-section-title"))
               "Journey"
               (span (@ (class "panel-close") (click ,on-clear)) " ×"))
          (div (@ (class "panel-meta journey-dest"))
               "→ " ,(journey-field j 'dest-name "destination"))
          (div (@ (class "journey-profiles"))
               ,@(map (lambda (p)
                        `(span (@ (class ,(string-append
                                           "journey-profile-pill"
                                           (if (string=? (car p) profile)
                                               " active" "")))
                                  (title ,(car p))
                                  (click ,(lambda (e) (on-profile (car p)))))
                               ,(cdr p)))
                      %journey-profiles))
          ,@(if (string=? summary "") '()
                (list `(div (@ (class "journey-summary")) ,summary)))
          ;; plan vs observed, once arrived (map-matched trace drawn warm)
          ,@(let ((dv (journey-field j 'divergence "")))
              (if (string=? dv "") '()
                  (list `(div (@ (class "journey-divergence")) ,dv))))
          ;; the journey's life as VF records: go → arrived → recorded
          ,@(cond
             ((journey-field j 'done #f)
              (list `(div (@ (class "journey-recorded"))
                          "✓ recorded — the plan learns from this trip")))
             ((journey-field j 'commitment #f)
              (if on-arrive
                  (list `(div (@ (class "journey-route-btn")
                                 (click ,on-arrive)) "✓ arrived"))
                  '()))
             (on-commit
              (list `(div (@ (class "journey-route-btn")
                             (click ,on-commit)) "⇀ i'll go")))
             (else '()))
          ,@(if (null? turns) '()
                (list `(div (@ (class "journey-turns"))
                            ,@(map (lambda (t)
                                     `(div (@ (class "journey-turn")) ,t))
                                   turns))))
          ;; a host-supplied tail (the repl hangs the journey's CHAT here —
          ;; this body stays pure rendering, the host owns the wiring)
          ,@(if extra (list extra) '()))))

(define empty-side-panel
  ;; Kept for backwards compat (still exported).
  (lambda (on-close)
    `(div (@ (class "map-side-panel empty"))
          ,(search-row "" (lambda (e) #f) (lambda (e) #f))
          ,(hint-body))))

(define (marker-row-sxml x)
  (cond
   ((grouped-slot-marker? x)
    `(div (@ (class "panel-row-inner"))
          (span (@ (class "row-emoji"))
                ,(or (and (pair? (gsm-slots x))
                          (slot-emoji (car (gsm-slots x))))
                     "🎁"))
          (span (@ (class "row-label"))
                ,(capacity-field (gsm-capacity x) 'name "(unnamed)"))
          (span (@ (class "row-count"))
                ,(number->string (length (gsm-slots x))) " slots")))
   ((pair? x)
    `(div (@ (class "panel-row-inner"))
          (span (@ (class "row-emoji")) ,(or (slot-emoji x) "·"))
          (span (@ (class "row-label")) ,(slot-name x))))
   (else
    `(div (@ (class "panel-row-inner")) "·"))))

(define (capacity-field cap key default)
  (cond
   ((not cap) default)
   ((pair? cap) (let ((p (assq key cap))) (if p (cdr p) default)))
   (else default)))

(define (format-lnglat lng lat)
  (string-append (number->string lat) ", " (number->string lng)))

;;; ── Map view skeleton ───────────────────────────────────────────────────────
;;;
;;; The container div #playnet-map is what maplibre attaches to. We render
;;; this once when the tab opens, then call the FFI from repl.scm to mount
;;; the map onto it (after the DOM is in place — the tab click handler is
;;; the right place to do that).
;;;
;;; The side panel renders as a sibling flex item on the right; the
;;; control bar sits across the top above the map.

(define* (map-view #:key
                   selected
                   on-close
                   on-marker-click
                   on-toggle-globe
                   on-toggle-3d
                   on-toggle-terrain
                   on-toggle-clustering
                   on-toggle-fab
                   globe?
                   show-3d?
                   show-terrain?
                   clustering?
                   fab-open?
                   (search-query "")
                   (search-results '())
                   (on-search (lambda (e) #f))
                   (on-search-clear (lambda (e) #f))
                   (on-result-click (lambda (m) #f))
                   (journey #f)
                   (on-route #f)
                   (on-journey-profile (lambda (p) #f))
                   (on-journey-clear (lambda (e) #f))
                   (on-journey-commit #f)
                   (on-journey-arrive #f)
                   (journey-extra #f)
                   (idle-extra #f))
  `(div (@ (class "map-tab"))
        (div (@ (id "playnet-map") (class "map-canvas")))
        ,(map-side-panel selected on-close on-marker-click
                         #:search-query search-query
                         #:search-results search-results
                         #:on-search on-search
                         #:on-search-clear on-search-clear
                         #:on-result-click on-result-click
                         #:journey journey
                         #:on-route on-route
                         #:on-journey-profile on-journey-profile
                         #:on-journey-clear on-journey-clear
                         #:on-journey-commit on-journey-commit
                         #:on-journey-arrive on-journey-arrive
                         #:journey-extra journey-extra
                         #:idle-extra idle-extra)
        (div (@ (class "map-fab"))
             ,@(if fab-open?
                   (list `(div (@ (class "map-fab-menu"))
                               ,(fab-btn "🌐 globe"     globe?        on-toggle-globe)
                               ,(fab-btn "🏢 3D"        show-3d?      on-toggle-3d)
                               ,(fab-btn "🏔️ terrain"   show-terrain? on-toggle-terrain)
                               ,(fab-btn "🗂️ cluster"   clustering?   on-toggle-clustering)))
                   '())
             (div (@ (class "map-fab-toggle")
                     (title "Map settings")
                     (click ,on-toggle-fab))
                  ,(if fab-open? "✕" "⚙")))))

(define (fab-btn label active? handler)
  `(div (@ (class ,(string-append "map-fab-btn"
                                  (if active? " active" "")))
           (click ,handler))
        ,label))
