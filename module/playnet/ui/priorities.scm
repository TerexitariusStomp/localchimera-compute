;;; priorities.scm — Priority tree treemap, free-association style.
;;;
;;; A treemap where each rectangle represents a priority node sized
;;; proportional to its points. Users navigate by tapping (zoom in),
;;; resize by dragging vertically, and manage nodes via add/rename/delete.
;;;
;;; Pure SXML in, SXML out. No DOM mutation, no actor refs.
;;; Hoot/WASM compatible.

(define-module (playnet ui priorities)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils alist)
  #:export (priorities-page
            treemap-binary-layout
            prio-find-node
            prio-update-in-tree
            prio-remove-from-tree
            prio-node-color
            prio-darker-color))


;;; ── Tree helpers ────────────────────────────────────────────────────────────

(define (prio-find-node tree id)
  (cond
    ((not tree) #f)
    ((equal? (alist-ref tree 'id) id) tree)
    (else
     (let loop ((kids (alist-ref tree 'children '())))
       (cond
         ((null? kids) #f)
         ((prio-find-node (car kids) id) => (lambda (x) x))
         (else (loop (cdr kids))))))))

(define (prio-update-in-tree tree id updater)
  (cond
    ((not tree) tree)
    ((equal? (alist-ref tree 'id) id)
     (updater tree))
    (else
     (alist-set tree 'children
                (map (lambda (child)
                       (prio-update-in-tree child id updater))
                     (alist-ref tree 'children '()))))))

(define (prio-remove-from-tree tree id)
  (alist-set tree 'children
             (let loop ((kids (alist-ref tree 'children '())))
               (cond
                 ((null? kids) '())
                 ((equal? (alist-ref (car kids) 'id) id)
                  (loop (cdr kids)))
                 (else
                  (cons (prio-remove-from-tree (car kids) id)
                        (loop (cdr kids))))))))


;;; ── Treemap binary layout ───────────────────────────────────────────────────

(define (treemap-binary-layout children x0 y0 x1 y1 padding)
  (let ((n (length children)))
    (cond
      ((= n 0) '())
      ((= n 1)
       (let* ((c (car children))
              (px padding) (py padding))
         (list `((id . ,(alist-ref c 'id))
                 (name . ,(alist-ref c 'name ""))
                 (points . ,(alist-ref c 'points 1))
                 (x0 . ,(+ x0 px)) (y0 . ,(+ y0 py))
                 (x1 . ,(- x1 px)) (y1 . ,(- y1 py))
                 (has-children . ,(not (null? (alist-ref c 'children '()))))))))
      (else
       (let* ((sorted (sort children
                            (lambda (a b)
                              (> (alist-ref a 'points 1)
                                 (alist-ref b 'points 1)))))
              (total (fold (lambda (c acc) (+ (max 1 (alist-ref c 'points 1)) acc))
                          0 sorted))
              (width (- x1 x0))
              (height (- y1 y0))
              (horizontal? (>= width height)))
         (let split-loop ((rest sorted) (left-list '()) (left-sum 0))
           (cond
             ((null? (cdr rest))
              (let ((all (reverse (cons (car rest) left-list))))
                (treemap-single-row all x0 y0 x1 y1 padding horizontal? total)))
             (else
              (let* ((cur (car rest))
                     (cur-pts (max 1 (alist-ref cur 'points 1)))
                     (new-sum (+ left-sum cur-pts))
                     (remaining (cdr rest)))
                (if (>= new-sum (/ total 2))
                    (let* ((left (reverse (cons cur left-list)))
                           (right remaining)
                           (ratio (if (> total 0) (/ (* 1.0 new-sum) total) 0.5)))
                      (if horizontal?
                          (let ((sx (+ x0 (* width ratio))))
                            (append
                             (treemap-binary-layout left x0 y0 sx y1 padding)
                             (treemap-binary-layout right sx y0 x1 y1 padding)))
                          (let ((sy (+ y0 (* height ratio))))
                            (append
                             (treemap-binary-layout left x0 y0 x1 sy padding)
                             (treemap-binary-layout right x0 sy x1 y1 padding)))))
                    (split-loop remaining
                                (cons cur left-list)
                                new-sum)))))))))))

(define (treemap-single-row nodes x0 y0 x1 y1 padding horizontal? total)
  (let ((dim (if horizontal? (- x1 x0) (- y1 y0))))
    (let loop ((rest nodes) (offset 0.0) (acc '()))
      (if (null? rest)
          (reverse acc)
          (let* ((c (car rest))
                 (pts (max 1 (alist-ref c 'points 1)))
                 (frac (if (> total 0) (/ (* 1.0 pts) total) (/ 1.0 (length nodes))))
                 (size (* dim frac))
                 (px padding) (py padding)
                 (rect
                  (if horizontal?
                      `((id . ,(alist-ref c 'id))
                        (name . ,(alist-ref c 'name ""))
                        (points . ,pts)
                        (x0 . ,(+ x0 offset px)) (y0 . ,(+ y0 py))
                        (x1 . ,(+ x0 offset size (- px))) (y1 . ,(- y1 py))
                        (has-children . ,(not (null? (alist-ref c 'children '())))))
                      `((id . ,(alist-ref c 'id))
                        (name . ,(alist-ref c 'name ""))
                        (points . ,pts)
                        (x0 . ,(+ x0 px)) (y0 . ,(+ y0 offset py))
                        (x1 . ,(- x1 px)) (y1 . ,(+ y0 offset size (- py)))
                        (has-children . ,(not (null? (alist-ref c 'children '()))))))))
            (loop (cdr rest) (+ offset size) (cons rect acc)))))))


;;; ── Color from name ─────────────────────────────────────────────────────────

(define (name-hash name)
  (modulo (fold (lambda (ch acc) (+ (* acc 31) (char->integer ch)))
                0 (string->list (or name "")))
          360))

(define (prio-node-color name)
  (let ((h (name-hash name)))
    (string-append "hsl(" (number->string h) ",40%,24%)")))

(define (prio-darker-color name)
  (let ((h (name-hash name)))
    (string-append "hsl(" (number->string h) ",40%,16%)")))


;;; ── SXML rendering ──────────────────────────────────────────────────────────

(define (fmt-pct n)
  (string-append (number->string (+ 0.0 n)) "%"))

(define* (priorities-page #:key tree current-id path
                          resizing-id editing-id delete-mode?
                          on-zoom-in on-zoom-out on-zoom-to
                          on-add-node on-delete on-rename
                          on-pointer-down on-pointer-move on-pointer-up
                          on-edit-start on-edit-commit
                          on-toggle-delete)
  (let* ((node (and tree current-id (prio-find-node tree current-id)))
         (kids (if node (alist-ref node 'children '()) '()))
         (rects (if (null? kids) '()
                    (treemap-binary-layout kids 0.0 0.0 100.0 100.0 0.3))))
    `(div (@ (class "prio-view"))
          ,(render-prio-breadcrumb path tree on-zoom-to)
          (div (@ (class "prio-treemap-container"))
               ,@(if (null? rects)
                     (list (render-prio-empty on-add-node))
                     (map (lambda (rect)
                            (render-prio-cell rect resizing-id editing-id
                                              delete-mode?
                                              on-pointer-down on-pointer-move
                                              on-pointer-up on-edit-start
                                              on-edit-commit on-delete))
                          rects)))
          ,(render-prio-toolbar on-add-node on-toggle-delete delete-mode?
                                path on-zoom-out))))

(define (render-prio-breadcrumb path tree on-zoom-to)
  (if (or (not path) (null? path))
      `(div (@ (class "prio-breadcrumb")))
      `(div (@ (class "prio-breadcrumb"))
            ,@(let loop ((ids path) (acc '()))
                (if (null? ids)
                    (reverse acc)
                    (let* ((id (car ids))
                           (nd (and tree (prio-find-node tree id)))
                           (name (if nd (alist-ref nd 'name "?") "?"))
                           (is-last (null? (cdr ids))))
                      (loop (cdr ids)
                            (cons
                             (if is-last
                                 `(span (@ (class "prio-crumb prio-crumb-active"))
                                        ,name)
                                 `(span (span (@ (class "prio-crumb")
                                                 (click ,(lambda (e)
                                                           (on-zoom-to id))))
                                              ,name)
                                        (span (@ (class "prio-crumb-sep")) " / ")))
                             acc))))))))

(define (render-prio-cell rect resizing-id editing-id delete-mode?
                          on-pointer-down on-pointer-move
                          on-pointer-up on-edit-start on-edit-commit
                          on-delete)
  (let* ((id (alist-ref rect 'id))
         (name (alist-ref rect 'name ""))
         (pts (alist-ref rect 'points 0))
         (x0 (alist-ref rect 'x0))
         (y0 (alist-ref rect 'y0))
         (x1 (alist-ref rect 'x1))
         (y1 (alist-ref rect 'y1))
         (has-kids (alist-ref rect 'has-children #f))
         (is-resizing (and resizing-id (equal? resizing-id id)))
         (is-dimmed (and resizing-id (not (equal? resizing-id id))))
         (is-editing (and editing-id (equal? editing-id id)))
         (bg (prio-node-color name)))
    `(div (@ (class ,(string-append "prio-node"
                                    (if is-resizing " prio-resizing" "")
                                    (if is-dimmed " prio-dimmed" "")
                                    (if has-kids " prio-has-children" "")
                                    (if delete-mode? " prio-deleting" "")))
             (style ,(string-append
                      "position:absolute;"
                      "left:" (fmt-pct x0) ";"
                      "top:" (fmt-pct y0) ";"
                      "width:" (fmt-pct (- x1 x0)) ";"
                      "height:" (fmt-pct (- y1 y0)) ";"
                      "background:" bg ";"))
             (pointerdown ,(lambda (e)
                             (if delete-mode?
                                 (on-delete id)
                                 (on-pointer-down e id))))
             (pointermove ,(lambda (e) (on-pointer-move e id)))
             (pointerup ,(lambda (e)
                           (unless delete-mode?
                             (on-pointer-up e id)))))
          ,(if is-editing
               `(input (@ (class "prio-node-input")
                          (value ,name)
                          (autofocus "true")
                          (keydown ,(lambda (e) (on-edit-commit e id)))))
               `(div (@ (class "prio-node-label")
                        (dblclick ,(lambda (e) (on-edit-start id))))
                     ,name))
          (div (@ (class "prio-node-points"))
               ,(number->string pts)))))

(define (render-prio-empty on-add-node)
  `(div (@ (class "prio-empty"))
        (div (@ (class "prio-empty-prompt"))
             (button (@ (class "prio-add-btn")
                        (click ,(lambda (e) (on-add-node))))
                     "+ add priority"))))

(define (render-prio-toolbar on-add-node on-toggle-delete delete-mode?
                             path on-zoom-out)
  `(div (@ (class "prio-toolbar"))
        ,@(if (and path (> (length path) 1))
              (list `(button (@ (class "prio-toolbar-btn")
                                (click ,(lambda (e) (on-zoom-out))))
                             "◀"))
              '())
        (button (@ (class ,(string-append "prio-toolbar-btn"
                                          (if delete-mode? " prio-toolbar-active" "")))
                   (click ,(lambda (e) (on-toggle-delete))))
                "−")
        (button (@ (class "prio-toolbar-btn")
                   (click ,(lambda (e) (on-add-node))))
                "+")))
