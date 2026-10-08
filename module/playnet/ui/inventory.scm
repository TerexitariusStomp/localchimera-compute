;;; inventory.scm — ValueFlows resource library, Minecraft-style.
;;;
;;; The inventory tab presents a scope+plan slice of the ValueFlows
;;; recipe-store and observer:
;;;   * a left sidebar listing the resource-classified-as URIs (categories)
;;;     used by the visible specs;
;;;   * a centre grid of <resource-specification> "cells" (the library);
;;;   * a right detail pane that switches between
;;;       - spec-detail-panel: concrete <economic-resource> instances
;;;         conforming to the clicked spec, and
;;;       - resource-detail-panel: a single resource's current custodian,
;;;         a collapsible custody history (events walked via the observer's
;;;         trace-resource), and any contained-in children for recursive
;;;         drill-down (crate -> bottles -> pills).
;;;
;;; All data on the wire is alists shaped server-side by
;;; build-inventory-snapshot / build-resource-detail in
;;; server/planner-service.scm. This module is pure: SXML in, SXML out,
;;; no DOM mutation, no actor refs. Hoot/WASM compatible.

(define-module (playnet ui inventory)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils alist)
  #:use-module (playnet ui components)
  #:use-module (playnet ui calendar)
  #:export (inventory-page
            inventory-view-toggle
            category-sidebar
            spec-library-grid
            spec-detail-panel
            resource-detail-panel))


;;; ── Local helpers ────────────────────────────────────────────────────────────

(define (spec-initials name)
  "Two-character glyph used when a spec has no image. Picks the first
   letter of the first two whitespace-separated words, falling back to
   the first two characters of the name."
  (let* ((s (or name ""))
         (n (string-length s)))
    (cond
      ((= n 0) "??")
      ((= n 1) (string-upcase s))
      (else
       (let loop ((i 0) (saw-space? #t) (acc '()))
         (cond
           ((or (>= i n) (= (length acc) 2))
            (cond
              ((= (length acc) 2)
               (string (car (reverse acc)) (cadr (reverse acc))))
              ((= (length acc) 1)
               (string (car acc) (string-ref s (min 1 (- n 1)))))
              (else (substring s 0 (min 2 n)))))
           (else
            (let ((c (string-ref s i)))
              (cond
                ((char-whitespace? c)
                 (loop (+ i 1) #t acc))
                (saw-space?
                 (loop (+ i 1) #f (cons (char-upcase c) acc)))
                (else
                 (loop (+ i 1) #f acc)))))))))))

(define (category-depth uri)
  "Number of '/' separators in URI. Used to indent nested categories
   when classified-as URIs adopt a vf:Food/Grain style. Today the URIs
   are flat and depth is always 0; the indent code path is dormant
   but preserved so the sidebar can grow into a real tree."
  (let loop ((i 0) (depth 0))
    (cond
      ((>= i (string-length uri)) depth)
      ((char=? (string-ref uri i) #\/) (loop (+ i 1) (+ depth 1)))
      (else (loop (+ i 1) depth)))))

(define (category-label uri)
  "Display label for a category URI. For now we strip the URI prefix
   up to the last '/' so 'vf:Food/Grain' renders as 'Grain'."
  (let loop ((i (- (string-length uri) 1)))
    (cond
      ((< i 0) uri)
      ((char=? (string-ref uri i) #\/) (substring uri (+ i 1)))
      (else (loop (- i 1))))))

(define (spec-matches-category? spec category-uri)
  "True when SPEC's classified-as list contains CATEGORY-URI, or when
   CATEGORY-URI is #f (the 'All' pseudo-category)."
  (or (not category-uri)
      (let ((cats (or (alist-ref spec 'categories '()) '())))
        (and (member category-uri cats) #t))))


;;; ── category-sidebar ─────────────────────────────────────────────────────────

(define (category-sidebar category-tree active-category on-select-category)
  "Left sidebar listing the categories present in the current snapshot.
   CATEGORY-TREE: list of (uri . label) pairs from the snapshot. The label
                  in the wire format is currently the URI itself; we run
                  it through category-label so future hierarchical URIs
                  display nicely.
   ACTIVE-CATEGORY: currently selected URI, or #f for 'All'.
   ON-SELECT-CATEGORY: 1-arg callback receiving a URI string or #f."
  (define (row uri active?)
    (let ((label (if uri (category-label uri) "All"))
          (depth (if uri (category-depth uri) 0)))
      `(div (@ (class ,(string-append "inv-cat-row"
                                      (if active? " active" "")))
               (style ,(string-append "padding-left:"
                                       (number->string (+ 10 (* depth 10)))
                                       "px"))
               (click ,(lambda (e) (on-select-category uri))))
            ,label)))
  `(div (@ (class "inv-cat-sidebar"))
        (div (@ (class "inv-cat-header")) "categories")
        ,(row #f (not active-category))
        ,@(map (lambda (pair)
                 (row (car pair) (equal? (car pair) active-category)))
               (or category-tree '()))))


;;; ── spec-library-grid ────────────────────────────────────────────────────────

(define (spec-cell spec selected? on-select-spec)
  (let* ((id            (alist-ref spec 'id ""))
         (name          (alist-ref spec 'name id))
         (image         (alist-ref spec 'image #f))
         (count         (alist-ref spec 'resource-count 0))
         (onhand-total  (alist-ref spec 'onhand-total 0))
         (default-unit  (alist-ref spec 'default-unit ""))
         (categories    (or (alist-ref spec 'categories '()) '())))
    `(div (@ (class ,(string-append "inv-cell"
                                    (if selected? " selected" "")))
             (click ,(lambda (e) (on-select-spec id))))
          (div (@ (class "inv-cell-icon"))
               ,(if image
                    `(img (@ (src ,image) (alt ,name) (class "inv-cell-img")))
                    (spec-initials name)))
          (div (@ (class "inv-cell-count")) ,(number->string count))
          (div (@ (class "inv-cell-tooltip"))
               (div (@ (class "tt-name")) ,name)
               (div (@ (class "tt-onhand"))
                    ,(string-append (fmt-num onhand-total) " " default-unit))
               ,@(if (null? categories) '()
                     `((div (@ (class "tt-cats"))
                            ,@(map (lambda (c)
                                     `(span (@ (class "tt-cat-chip"))
                                            ,(category-label c)))
                                   categories))))))))

(define (spec-library-grid specs selected-spec-id active-category on-select-spec)
  "The Minecraft-style grid of resource specifications.
   SPECS: list of spec alists from the snapshot.
   SELECTED-SPEC-ID: id string for highlighting, or #f.
   ACTIVE-CATEGORY: filter URI or #f.
   ON-SELECT-SPEC: 1-arg callback receiving the spec id."
  (let ((filtered (filter (lambda (s) (spec-matches-category? s active-category))
                          (or specs '()))))
    `(div (@ (class "inv-grid-wrap"))
          ,(if (null? filtered)
               `(div (@ (class "inv-empty"))
                     "No resource specifications in scope.")
               `(div (@ (class "inv-grid"))
                     ,@(map (lambda (s)
                              (spec-cell s
                                         (equal? (alist-ref s 'id)
                                                 selected-spec-id)
                                         on-select-spec))
                            filtered))))))


;;; ── Concrete-resource card (used by spec-detail and resource children) ──────

(define (resource-card res selected? on-select-resource)
  "A click-aware card for a single concrete EconomicResource alist.
   Distinct from federation.scm's render-resource-card so the click
   handler can flow through the inventory state machine."
  (let* ((id        (alist-ref res 'id ""))
         (name      (alist-ref res 'name id))
         (onhand    (alist-ref res 'onhand 0))
         (unit      (or (alist-ref res 'unit "") ""))
         (cust-name (or (alist-ref res 'custodian-name "") ""))
         (children? (alist-ref res 'has-children? #f)))
    `(div (@ (class ,(string-append "inv-rcard"
                                    (if selected? " selected" "")))
             (click ,(lambda (e) (on-select-resource id))))
          (div (@ (class "inv-rcard-name")) ,name)
          (div (@ (class "inv-rcard-qty"))
               ,(string-append "OH " (fmt-num onhand) " " unit))
          (div (@ (class "inv-rcard-meta"))
               ,@(if (string=? cust-name "") '()
                     `((span (@ (class "inv-rcard-custodian")) ,cust-name)))
               ,@(if children?
                     `((span (@ (class "inv-rcard-nested")) "▾"))
                     '())))))


;;; ── spec-detail-panel ────────────────────────────────────────────────────────

(define (spec-detail-panel spec resources selected-resource-id
                           on-select-resource on-close)
  "Right pane shown after a grid cell click. Lists every concrete
   EconomicResource conforming to SPEC within the active scope+plan."
  (let* ((sname (alist-ref spec 'name (alist-ref spec 'id "spec")))
         (note  (or (alist-ref spec 'note "") ""))
         (cats  (or (alist-ref spec 'categories '()) '()))
         (count (length resources))
         (sid   (alist-ref spec 'id "")))
    `(div (@ (class "inv-detail"))
          (div (@ (class "inv-detail-header"))
               (div (@ (class "inv-detail-title")) ,sname)
               (div (@ (class "inv-detail-close")
                       (click ,(lambda (e) (on-close))))
                    "×"))
          ,@(if (null? cats) '()
                `((div (@ (class "inv-detail-cats"))
                       ,@(map (lambda (c)
                                `(span (@ (class "tt-cat-chip"))
                                       ,(category-label c)))
                              cats))))
          ,@(if (string=? note "") '()
                `((div (@ (class "inv-detail-note")) ,note)))
          (div (@ (class "inv-detail-section"))
               ,(string-append "Concrete resources ("
                               (number->string count) ")"))
          ,(cond
             ((null? resources)
              `(div (@ (class "inv-empty"))
                    "No resources of this type in this scope+plan."))
             (else
              `(div (@ (class "inv-children-grid"))
                    ,@(map (lambda (r)
                             (resource-card
                              r
                              (equal? (alist-ref r 'id) selected-resource-id)
                              on-select-resource))
                           ;; Defensive: filter to the spec we're showing
                           ;; in case the snapshot bundles every resource
                           ;; in the scope (it does).
                           (filter (lambda (r)
                                     (equal? (alist-ref r 'conforms-to) sid))
                                   resources))))))))


;;; ── resource-detail-panel ────────────────────────────────────────────────────

(define (custody-step-row step current?)
  (let* ((agent  (or (alist-ref step 'agent-name "")
                     (alist-ref step 'agent "")
                     ""))
         (action (or (alist-ref step 'action "") ""))
         (qty    (alist-ref step 'qty 0))
         (unit   (or (alist-ref step 'unit "") ""))
         (when-s (or (alist-ref step 'when "") ""))
         (qty-text (cond
                     ((and (number? qty) (> qty 0))
                      (string-append " " (fmt-num qty) " " unit))
                     (else ""))))
    `(div (@ (class ,(string-append "inv-custody-step"
                                    (if current? " current" ""))))
          (span (@ (class "inv-custody-agent")) ,agent)
          (span (@ (class "inv-custody-action")) ,(string-append " " action))
          (span (@ (class "inv-custody-qty")) ,qty-text)
          ,@(if (string=? when-s "") '()
                `((span (@ (class "inv-custody-when"))
                        ,(string-append " · " when-s)))))))

(define (custody-section history expanded? on-toggle-custody)
  (let ((n (length history)))
    `(div (@ (class "inv-custody-block"))
          (div (@ (class "inv-custody-toggle")
                  (click ,(lambda (e) (on-toggle-custody))))
               ,(string-append (if expanded? "▼ " "▶ ")
                               "history ("
                               (number->string n) ")"))
          ,@(if (and expanded? (pair? history))
                `((div (@ (class "inv-custody"))
                       ,@(let* ((rev (reverse history))
                                (last-id (and (pair? rev)
                                              (alist-ref (car rev) 'event-id #f))))
                           (map (lambda (step)
                                  (custody-step-row
                                   step
                                   (equal? (alist-ref step 'event-id) last-id)))
                                history))))
                '()))))

(define (breadcrumb-row breadcrumb on-pop-breadcrumb)
  "Breadcrumb of resource ids leading to the current selection.
   Earlier crumbs are clickable; the last one is the current resource."
  (cond
    ((or (not breadcrumb) (null? breadcrumb)) '())
    (else
     (let loop ((rest breadcrumb) (acc '()))
       (cond
         ((null? rest)
          (list `(div (@ (class "inv-breadcrumb")) ,@(reverse acc))))
         ((null? (cdr rest))
          ;; Last crumb — non-clickable
          (loop (cdr rest)
                (cons `(span (@ (class "crumb crumb-current")) ,(car rest))
                      acc)))
         (else
          (let ((rid (car rest)))
            (loop (cdr rest)
                  (cons `(span (@ (class "crumb-sep")) " / ")
                        (cons `(span (@ (class "crumb")
                                        (click ,(lambda (e) (on-pop-breadcrumb rid))))
                                     ,rid)
                              acc))))))))))

(define* (resource-detail-panel detail breadcrumb custody-expanded?
                                 on-select-child on-pop-breadcrumb
                                 on-toggle-custody on-close
                                 #:key (loading? #f))
  "Right pane shown after a concrete-resource click. DETAIL is the
   alist returned by build-resource-detail, or #f while the fetch is
   inflight."
  (cond
    ((or loading? (not detail))
     `(div (@ (class "inv-detail"))
           (div (@ (class "inv-detail-header"))
                (div (@ (class "inv-detail-title")) "Resource")
                (div (@ (class "inv-detail-close")
                        (click ,(lambda (e) (on-close))))
                     "×"))
           (div (@ (class "inv-empty")) "Loading…")))
    (else
     (let* ((r (alist-ref detail 'resource #f))
            (rid (alist-ref detail 'id ""))
            (name (or (and r (alist-ref r 'name rid)) rid))
            (onhand (and r (alist-ref r 'onhand 0)))
            (unit (or (and r (alist-ref r 'unit "")) ""))
            (loc (and r (alist-ref r 'location #f)))
            (lot (and r (alist-ref r 'lot #f)))
            (track (and r (alist-ref r 'tracking-identifier #f)))
            (cust-name (or (alist-ref detail 'current-custodian-name "") ""))
            (history (or (alist-ref detail 'custody-history '()) '()))
            (kids (or (alist-ref detail 'children '()) '())))
       `(div (@ (class "inv-detail"))
             (div (@ (class "inv-detail-header"))
                  (div (@ (class "inv-detail-title")) ,name)
                  (div (@ (class "inv-detail-close")
                          (click ,(lambda (e) (on-close))))
                       "×"))
             ,@(breadcrumb-row breadcrumb on-pop-breadcrumb)
             (div (@ (class "inv-current-custodian"))
                  ,(if (string=? cust-name "")
                       "(no custodian)"
                       (string-append "held by " cust-name)))
             (div (@ (class "inv-detail-meta"))
                  (div (@ (class "inv-meta-row"))
                       (span (@ (class "inv-meta-key")) "onhand:")
                       (span (@ (class "inv-meta-val"))
                             ,(string-append
                                (fmt-num (or onhand 0)) " " unit)))
                  ,@(if track
                        `((div (@ (class "inv-meta-row"))
                               (span (@ (class "inv-meta-key")) "tracking:")
                               (span (@ (class "inv-meta-val")) ,track)))
                        '())
                  ,@(if loc
                        `((div (@ (class "inv-meta-row"))
                               (span (@ (class "inv-meta-key")) "location:")
                               (span (@ (class "inv-meta-val")) ,loc)))
                        '())
                  ,@(if lot
                        `((div (@ (class "inv-meta-row"))
                               (span (@ (class "inv-meta-key")) "lot:")
                               (span (@ (class "inv-meta-val")) ,lot)))
                        '()))
             ,(custody-section history custody-expanded? on-toggle-custody)
             ,@(if (null? kids) '()
                   `((div (@ (class "inv-detail-section")) "contained")
                     (div (@ (class "inv-children-grid"))
                          ,@(map (lambda (c)
                                   (resource-card c #f on-select-child))
                                 kids)))))))))


;;; ── view-mode toggle (personal / scope) ─────────────────────────────────────

(define (inventory-view-toggle view-mode on-toggle-view-mode)
  "Pill toggle switching between personal inventory and scope inventory.
   VIEW-MODE: 'personal or 'scope (default).
   ON-TOGGLE-VIEW-MODE: 1-arg callback receiving the new mode symbol."
  (define (pill label mode)
    `(button (@ (class ,(string-append "inv-view-pill"
                                       (if (eq? view-mode mode) " active" "")))
                (click ,(lambda (e) (on-toggle-view-mode mode))))
             ,label))
  `(div (@ (class "inv-view-toggle"))
        ,(pill "personal" 'personal)
        ,(pill "scope" 'scope)))


;;; ── inventory-page (top-level composer) ──────────────────────────────────────

(define* (inventory-page #:key snapshot
                              ;; Scope, plan, and acting-as are session
                              ;; state (rendered above the view in
                              ;; repl.scm). They flow in here as read-only
                              ;; context — filter for queries and the
                              ;; ownership-based view mode.
                              current-scope current-plan current-acting-as
                              (view-mode 'scope)
                              selected-spec-id selected-resource-id
                              detail breadcrumb custody-expanded?
                              active-category
                              on-toggle-view-mode
                              on-select-category on-select-spec on-select-resource
                              on-pop-breadcrumb on-toggle-custody
                              on-clear-selection)
  "Compose the inventory tab.

   SNAPSHOT is the alist returned by inventory-snapshot. DETAIL is the
   currently-fetched resource-detail alist (or #f while loading). All
   selection state is held by the caller and threaded through.

   VIEW-MODE is 'personal or 'scope.  In personal mode the resource list
   is filtered to items whose custodian matches CURRENT-ACTING-AS.

   Layout:

     ┌──────── inventory-view-toggle (personal / scope) ──────┤
     ├──────────┬──────────────────────────┬─────────────────┤
     │ category │  spec-library-grid       │  spec-detail or │
     │ sidebar  │                          │  resource-detail│
     └──────────┴──────────────────────────┴─────────────────┘"
  (let* ((all-resources (or (and snapshot (alist-ref snapshot 'resources '())) '()))
         ;; In personal mode, keep only resources held by the acting-as person.
         (resources
           (if (and (eq? view-mode 'personal) current-acting-as)
               (filter (lambda (r)
                         (equal? (alist-ref r 'custodian #f) current-acting-as))
                       all-resources)
               all-resources))
         ;; Recompute spec counts against the (possibly filtered) resources.
         (raw-specs  (or (and snapshot (alist-ref snapshot 'specs '())) '()))
         (specs
           (if (eq? view-mode 'personal)
               ;; Recount: only specs that still have visible resources.
               (filter-map
                 (lambda (s)
                   (let* ((sid   (alist-ref s 'id ""))
                          (mine  (filter (lambda (r)
                                           (equal? (alist-ref r 'conforms-to) sid))
                                         resources))
                          (count (length mine)))
                     (if (> count 0)
                         ;; Patch counts into the spec alist.
                         (let ((patched
                                (map (lambda (pair)
                                       (cond
                                         ((eq? (car pair) 'resource-count)
                                          (cons 'resource-count count))
                                         ((eq? (car pair) 'onhand-total)
                                          (cons 'onhand-total
                                                (fold (lambda (r acc)
                                                        (+ acc (or (alist-ref r 'onhand) 0)))
                                                      0 mine)))
                                         (else pair)))
                                     s)))
                           patched)
                         #f)))
                 raw-specs)
               raw-specs))
         (cat-tree    (or (and snapshot (alist-ref snapshot 'category-tree '())) '()))
         (selected-spec
          (and selected-spec-id
               (find (lambda (s) (equal? (alist-ref s 'id) selected-spec-id))
                     specs))))
    `(div (@ (class "inv-page"))
          ,(inventory-view-toggle view-mode on-toggle-view-mode)
          (div (@ (class "inv-body"))
               ,(category-sidebar cat-tree active-category on-select-category)
               ,(spec-library-grid specs selected-spec-id active-category
                                   on-select-spec)
               ,(cond
                  ;; A resource is selected → show its detail. The detail
                  ;; alist may be #f for the brief window between click
                  ;; and OCapN reply.
                  (selected-resource-id
                   (resource-detail-panel detail breadcrumb custody-expanded?
                                          on-select-resource on-pop-breadcrumb
                                          on-toggle-custody on-clear-selection
                                          #:loading? (not detail)))
                  ;; A spec is selected → show concrete resources.
                  (selected-spec
                   (spec-detail-panel selected-spec resources
                                      selected-resource-id
                                      on-select-resource on-clear-selection))
                  ;; Nothing selected → hint card.
                  (else
                   `(div (@ (class "inv-detail inv-detail-hint"))
                         (div (@ (class "inv-detail-header"))
                              (div (@ (class "inv-detail-title"))
                                   ,(if (eq? view-mode 'personal)
                                        "personal inventory"
                                        "inventory")))
                         (div (@ (class "inv-empty"))
                              ,(if (and (eq? view-mode 'personal)
                                        (not current-acting-as))
                                   "Select who you are in \"Acting as\" to see your personal inventory."
                                   "Pick a category, then click a tile to see its concrete resources.")))))))))
