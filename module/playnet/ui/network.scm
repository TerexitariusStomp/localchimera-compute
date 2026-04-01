;;; network.scm — Scope-level process network diagram in SXML
;;;
;;; Translated from old/planner/src/lib/components/federation/ScopeNetworkDiagram.svelte
;;;
;;; Renders a horizontal SVG process flow: process boxes in topological columns,
;;; input/output resource cards, cubic Bezier flow edges, buffer funnels.
;;;
;;; Data-driven: receives flat lists of processes, commitments, and buffer zones.
;;; All functions are pure: data in, SXML out.
;;;
;;; Hoot/WASM compatible.

(define-module (playnet ui network)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (playnet ddmrp)
  #:use-module (playnet ui components)
  #:export (scope-network-diagram))


;;; ── Layout constants ──────────────────────────────────────────────────────────

(define ML 20) (define MT 16)
(define COL-W 380) (define PROC-W 100) (define PROC-H 44)
(define CARD-W 106) (define CARD-H 46) (define CARD-RX 3) (define RES-GAP 10)
(define ROW-H 52) (define SLOT-BOT 16) (define SLOT-GAP 12)
(define BUF-W 14) (define BUF-H 20)
(define CAP-H 5) (define CAP-GAP 3)
(define IO-X (+ (/ PROC-W 2) RES-GAP (/ CARD-W 2)))


;;; ── Helpers ───────────────────────────────────────────────────────────────────

(define (n->s n)
  (let ((r (/ (round (* n 10)) 10)))
    (number->string (if (= r (floor r)) (inexact->exact (floor r)) r))))

(define (trunc s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 (- n 1)) "\u2026")
      s))

(define *action-colors*
  '((produce . "#38a169") (consume . "#e53e3e") (use . "#4299e1")
    (work . "#9f7aea") (cite . "#718096")))

(define (action-color act)
  (let ((p (assq act *action-colors*)))
    (if p (cdr p) "#718096")))

(define (fulfill-color pct)
  (cond ((>= pct 100) "#38a169") ((>= pct 50) "#d69e2e") (else "#e53e3e")))


;;; ── Topological sort ──────────────────────────────────────────────────────────

(define (topo-sort proc-ids edges)
  "Topological sort of process IDs given edges ((from . to) ...)."
  (let* ((adj (map (lambda (pid) (cons pid '())) proc-ids)))
    ;; Build adjacency
    (for-each (lambda (e)
                (let ((entry (assoc (alist-ref e 'from-id) adj equal?)))
                  (when entry
                    (set-cdr! entry (cons (alist-ref e 'to-id) (cdr entry))))))
              edges)
    ;; DFS
    (let ((visited (list))
          (result (list)))
      (define (dfs pid stack)
        (when (and (not (member pid visited equal?))
                   (not (member pid stack equal?)))
          (let ((new-stack (cons pid stack)))
            (for-each (lambda (succ) (dfs succ new-stack))
                      (let ((p (assoc pid adj equal?)))
                        (if p (cdr p) '())))
            (set! visited (cons pid visited))
            (set! result (cons pid result)))))
      (for-each (lambda (pid) (dfs pid '())) proc-ids)
      result)))


;;; ── Column assignment ─────────────────────────────────────────────────────────

(define (assign-columns topo-order edges)
  "Assign column indices to each process based on topological order.
   Returns alist mapping pid -> column."
  (let ((col-map '()))
    (for-each
     (lambda (pid)
       (let ((max-pred-col
              (fold (lambda (e best)
                      (if (and (equal? (alist-ref e 'to-id) pid)
                               (assoc (alist-ref e 'from-id) col-map equal?))
                          (max best (+ 1 (cdr (assoc (alist-ref e 'from-id) col-map equal?))))
                          best))
                    0 edges)))
         (set! col-map (cons (cons pid max-pred-col) col-map))))
     topo-order)
    col-map))


;;; ── Build process node layout ─────────────────────────────────────────────────

(define (build-layout processes commitments buffer-zones spec-names)
  "Build the full layout of process nodes with positioned input/output cards.
   PROCESSES: list of ((id . \"p1\") (name . \"Milling\")).
   COMMITMENTS: list of ((id . \"c1\") (input-of . \"p1\") (output-of . #f)
                          (resource-conforms-to . \"wheat\") (action . consume)
                          (qty . 50) (unit . \"kg\")).
   BUFFER-ZONES: list of ((spec-id . \"flour\") (tor . 10) (toy . 25) (tog . 40)).
   Returns list of node alists with 'proc, 'col, 'x, 'y, 'inputs, 'outputs."
  (let* ((proc-ids (map (lambda (p) (alist-ref p 'id)) processes))
         ;; Build raw edges from commitments
         (raw-edges
          (let loop ((c1s commitments) (acc '()) (seen '()))
            (if (null? c1s) acc
                (let* ((c1 (car c1s))
                       (out-of (alist-ref c1 'output-of #f))
                       (spec (alist-ref c1 'resource-conforms-to #f)))
                  (if (or (not out-of) (not spec))
                      (loop (cdr c1s) acc seen)
                      (let inner ((c2s commitments) (acc2 acc) (seen2 seen))
                        (if (null? c2s)
                            (loop (cdr c1s) acc2 seen2)
                            (let* ((c2 (car c2s))
                                   (in-of (alist-ref c2 'input-of #f))
                                   (spec2 (alist-ref c2 'resource-conforms-to #f))
                                   (key (and in-of (equal? spec spec2)
                                             (string-append out-of "->" in-of ":" spec))))
                              (if (and key (not (member key seen2 equal?)))
                                  (inner (cdr c2s)
                                         (cons `((from-id . ,out-of) (to-id . ,in-of) (spec-id . ,spec)) acc2)
                                         (cons key seen2))
                                  (inner (cdr c2s) acc2 seen2))))))))))
         ;; Topological sort and column assignment
         (topo (topo-sort proc-ids raw-edges))
         (col-map (assign-columns topo raw-edges))
         ;; Group by column
         (max-col (fold (lambda (p best) (max best (cdr p))) 0 col-map))
         (col-groups
          (let loop ((col 0) (acc '()))
            (if (> col max-col) acc
                (loop (+ col 1)
                      (cons (cons col (filter (lambda (pid)
                                                (let ((p (assoc pid col-map equal?)))
                                                  (and p (= (cdr p) col))))
                                              proc-ids))
                            acc)))))
         ;; Build cards for each process
         (make-cards
          (lambda (pid side)
            (let ((cmts (filter (lambda (c)
                                  (equal? (alist-ref c (if (eq? side 'input) 'input-of 'output-of)) pid))
                                commitments)))
              (map (lambda (c)
                     (let* ((is-work (eq? (alist-ref c 'action) 'work))
                            (spec-id (alist-ref c 'resource-conforms-to ""))
                            (qty (if is-work
                                     (alist-ref c 'effort-qty 0)
                                     (alist-ref c 'qty 0)))
                            (unit (if is-work
                                      (alist-ref c 'effort-unit "hr")
                                      (alist-ref c 'unit "")))
                            (bz (and (eq? side 'output) (not is-work)
                                     (find (lambda (b) (equal? (alist-ref b 'spec-id) spec-id))
                                           buffer-zones)))
                            (sn (let ((p (assoc spec-id spec-names equal?)))
                                  (if p (cdr p) spec-id))))
                       `((spec-id . ,spec-id) (spec-name . ,sn)
                         (action . ,(alist-ref c 'action 'consume))
                         (qty . ,qty) (unit . ,unit) (is-work . ,is-work)
                         (commitment-id . ,(alist-ref c 'id ""))
                         ,@(if bz `((buffer-zone . ,bz)) '())
                         (y . 0))))  ;; y assigned later
                   cmts))))
         ;; Slot height per process
         (slot-h
          (lambda (pid)
            (let ((ni (count (lambda (c) (equal? (alist-ref c 'input-of) pid)) commitments))
                  (no (count (lambda (c) (equal? (alist-ref c 'output-of) pid)) commitments)))
              (+ (* (max ni no 1) ROW-H) SLOT-BOT))))
         ;; Column heights
         (col-heights
          (map (lambda (cg)
                 (cons (car cg)
                       (fold (lambda (pid acc)
                               (+ acc (slot-h pid)
                                  (if (> acc 0) SLOT-GAP 0)))
                             0 (cdr cg))))
               col-groups))
         (max-h (fold (lambda (ch best) (max best (cdr ch))) 1 col-heights))
         ;; Process name lookup
         (proc-map (map (lambda (p) (cons (alist-ref p 'id) p)) processes)))

    ;; Position nodes
    (let ((nodes '()))
      (for-each
       (lambda (cg)
         (let* ((col (car cg))
                (pids (cdr cg))
                (ch (let ((p (assoc col col-heights))) (if p (cdr p) 0)))
                (col-offset (/ (- max-h ch) 2))
                (x (+ ML (* col COL-W) (/ COL-W 2))))
           (let ploop ((ps pids) (slot-top (+ MT col-offset)))
             (when (not (null? ps))
               (let* ((pid (car ps))
                      (proc (let ((p (assoc pid proc-map equal?))) (if p (cdr p) `((id . ,pid) (name . ,pid)))))
                      (in-base (make-cards pid 'input))
                      (out-base (make-cards pid 'output))
                      (max-rows (max (length in-base) (length out-base) 1))
                      (proc-y (+ slot-top (/ (* max-rows ROW-H) 2)))
                      ;; Position cards vertically centered on process
                      (position-cards
                       (lambda (cards)
                         (let ((n (length cards)))
                           (map (lambda (c i)
                                  (alist-set c 'y (+ proc-y (* (- i (/ (- n 1) 2)) ROW-H))))
                                cards (iota n)))))
                      (inputs (position-cards in-base))
                      (outputs (position-cards out-base)))
                 (set! nodes
                       (cons `((proc . ,proc) (col . ,col)
                               (x . ,x) (y . ,proc-y)
                               (inputs . ,inputs) (outputs . ,outputs))
                             nodes))
                 (ploop (cdr ps) (+ slot-top (slot-h pid) SLOT-GAP)))))))
       col-groups)

      ;; Return nodes + raw-edges for edge rendering
      (values (reverse nodes) raw-edges))))


;;; ── Render the SVG ────────────────────────────────────────────────────────────

(define* (scope-network-diagram processes commitments
                                 #:key (buffer-zones '()) (spec-names '())
                                       (mode 'plan) on-card-click
                                       (class ""))
  "Render a scope-level process network as SXML SVG.
   PROCESSES: list of ((id . \"p1\") (name . \"Milling\")).
   COMMITMENTS: list with 'id, 'input-of or 'output-of, 'resource-conforms-to,
                'action, 'qty, 'unit."
  (if (null? processes)
      `(div (@ (class "net-wrap")) (p (@ (class "empty")) "No commitments."))
      (let-values (((nodes raw-edges) (build-layout processes commitments buffer-zones spec-names)))
        (let* (;; Compute edges with positions
               (net-edges
                (filter-map
                 (lambda (re)
                   (let ((src (find (lambda (n) (equal? (alist-ref (alist-ref n 'proc) 'id)
                                                        (alist-ref re 'from-id))) nodes))
                         (tgt (find (lambda (n) (equal? (alist-ref (alist-ref n 'proc) 'id)
                                                        (alist-ref re 'to-id))) nodes)))
                     (and src tgt
                          (let ((out-row (find (lambda (r) (equal? (alist-ref r 'spec-id) (alist-ref re 'spec-id)))
                                              (alist-ref src 'outputs '())))
                                (in-row (find (lambda (r) (equal? (alist-ref r 'spec-id) (alist-ref re 'spec-id)))
                                             (alist-ref tgt 'inputs '()))))
                            (and out-row in-row
                                 `((from-x . ,(+ (alist-ref src 'x) IO-X (/ CARD-W 2)))
                                   (from-y . ,(alist-ref out-row 'y))
                                   (to-x . ,(- (alist-ref tgt 'x) IO-X (/ CARD-W 2)))
                                   (to-y . ,(alist-ref in-row 'y))))))))
                 raw-edges))
               ;; SVG dimensions
               (svg-w (if (null? nodes) 420
                          (+ ML (* (+ 1 (fold (lambda (n best) (max best (alist-ref n 'col 0)))
                                              0 nodes))
                                   COL-W)
                             IO-X (/ CARD-W 2) BUF-W 20)))
               (all-ys (append-map
                        (lambda (n)
                          (map (lambda (c) (+ (alist-ref c 'y 0) (/ CARD-H 2)))
                               (append (alist-ref n 'inputs '()) (alist-ref n 'outputs '()))))
                        nodes))
               (svg-h (+ (if (null? all-ys) 80 (apply max MT all-ys)) 16)))

          `(div (@ (class ,(string-append "net-wrap " class)))
             (svg (@ (width ,(n->s svg-w)) (height ,(n->s svg-h)) (class "scope-net-svg"))
               ;; Arrow marker
               (defs
                 (marker (@ (id "snd-arr") (markerWidth "8") (markerHeight "6")
                            (refX "7") (refY "3") (orient "auto"))
                   (path (@ (d "M0,0 L0,6 L8,3 Z") (fill "rgba(226,232,240,0.6)")))))

               ;; ── Flow edges (cubic Bezier) ────────────────────────
               ,@(map (lambda (e)
                        (let* ((fx (alist-ref e 'from-x)) (fy (alist-ref e 'from-y))
                               (tx (alist-ref e 'to-x)) (ty (alist-ref e 'to-y))
                               (dx (- tx fx)))
                          `(path (@ (d ,(string-append
                                        "M" (n->s fx) "," (n->s fy)
                                        " C" (n->s (+ fx (* dx 0.5))) "," (n->s fy)
                                        " " (n->s (- tx (* dx 0.5))) "," (n->s ty)
                                        " " (n->s tx) "," (n->s ty)))
                                    (fill "none") (stroke "rgba(226,232,240,0.28)")
                                    (stroke-width "1.5") (marker-end "url(#snd-arr)")))))
                      net-edges)

               ;; ── Process nodes ────────────────────────────────────
               ,@(append-map
                  (lambda (node)
                    (let* ((proc (alist-ref node 'proc))
                           (nx (alist-ref node 'x)) (ny (alist-ref node 'y))
                           (inputs (alist-ref node 'inputs '()))
                           (outputs (alist-ref node 'outputs '())))
                      `(;; Process box
                        (rect (@ (x ,(n->s (- nx (/ PROC-W 2)))) (y ,(n->s (- ny (/ PROC-H 2))))
                                  (width ,(n->s PROC-W)) (height ,(n->s PROC-H)) (rx "4")
                                  (fill "rgba(255,255,255,0.04)") (stroke "rgba(255,255,255,0.25)")
                                  (stroke-width "1.5")))
                        (text (@ (x ,(n->s nx)) (y ,(n->s (- ny 6)))
                                  (text-anchor "middle") (font-size "9") (font-weight "600")
                                  (fill "#e2e8f0"))
                          ,(trunc (alist-ref proc 'name (alist-ref proc 'id "")) 14))
                        (text (@ (x ,(n->s nx)) (y ,(n->s (+ ny 10)))
                                  (text-anchor "middle") (font-size "7")
                                  (fill "rgba(255,255,255,0.35)"))
                          "PROCESS")
                        ;; Status dot
                        (circle (@ (cx ,(n->s (+ nx (/ PROC-W 2) -7)))
                                   (cy ,(n->s (- ny (/ PROC-H 2) -7)))
                                   (r "3.5") (fill "rgba(226,232,240,0.25)")))

                        ;; ── Input cards ─────────────────────────────
                        ,@(append-map
                           (lambda (row)
                             (let* ((ox (- nx IO-X))
                                    (acol (action-color (alist-ref row 'action 'consume)))
                                    (card-x (- ox (/ CARD-W 2)))
                                    (card-y (- (alist-ref row 'y) (/ CARD-H 2)))
                                    (is-work (alist-ref row 'is-work #f))
                                    (qty (alist-ref row 'qty 0))
                                    (unit (alist-ref row 'unit ""))
                                    (clickable (and (eq? mode 'observe) on-card-click)))
                               `(;; Connector line
                                 (line (@ (x1 ,(n->s (+ ox (/ CARD-W 2)))) (y1 ,(n->s (alist-ref row 'y)))
                                          (x2 ,(n->s (- nx (/ PROC-W 2)))) (y2 ,(n->s ny))
                                          (stroke "rgba(226,232,240,0.2)") (stroke-width "1")
                                          (marker-end "url(#snd-arr)")))
                                 ;; Card rect
                                 (rect (@ (x ,(n->s card-x)) (y ,(n->s card-y))
                                          (width ,(n->s CARD-W)) (height ,(n->s CARD-H)) (rx ,(n->s CARD-RX))
                                          (fill ,(if is-work "rgba(159,122,234,0.12)" "rgba(74,85,104,0.25)"))
                                          (stroke ,(if is-work "rgba(159,122,234,0.45)" "rgba(160,174,192,0.4)"))
                                          (stroke-width "1")
                                          ,@(if clickable
                                                `((style "cursor:pointer")
                                                  (click ,(lambda (e)
                                                            (on-card-click
                                                             `((process-id . ,(alist-ref proc 'id ""))
                                                               (proc-name . ,(alist-ref proc 'name ""))
                                                               (spec-id . ,(alist-ref row 'spec-id ""))
                                                               (spec-name . ,(alist-ref row 'spec-name ""))
                                                               (action . ,(alist-ref row 'action 'consume))
                                                               (is-input . #t)
                                                               (planned-qty . ,qty)
                                                               (unit . ,unit)
                                                               (is-work . ,is-work)
                                                               (commitment-id . ,(alist-ref row 'commitment-id "")))))))
                                                '())))
                                 ;; Spec name
                                 (text (@ (x ,(n->s ox)) (y ,(n->s (+ card-y 13)))
                                          (text-anchor "middle") (font-size "8") (font-weight "500")
                                          (fill "#e2e8f0"))
                                   ,(trunc (alist-ref row 'spec-name "") 14))
                                 ;; Action label
                                 (text (@ (x ,(n->s ox)) (y ,(n->s (+ card-y 25)))
                                          (text-anchor "middle") (font-size "7.5") (fill ,acol))
                                   ,(symbol->string (alist-ref row 'action 'consume)))
                                 ;; Quantity
                                 (text (@ (x ,(n->s ox)) (y ,(n->s (+ card-y 37)))
                                          (text-anchor "middle") (font-size "7")
                                          (fill "rgba(226,232,240,0.4)"))
                                   ,(string-append (n->s qty) " " unit)))))
                           inputs)

                        ;; ── Output cards + buffer funnels ───────────
                        ,@(append-map
                           (lambda (row)
                             (let* ((ox (+ nx IO-X))
                                    (acol (action-color (alist-ref row 'action 'produce)))
                                    (card-x (- ox (/ CARD-W 2)))
                                    (card-y (- (alist-ref row 'y) (/ CARD-H 2)))
                                    (bz (alist-ref row 'buffer-zone #f))
                                    (qty (alist-ref row 'qty 0))
                                    (unit (alist-ref row 'unit ""))
                                    (clickable (and (eq? mode 'observe) on-card-click)))
                               `(;; Connector line
                                 (line (@ (x1 ,(n->s (+ nx (/ PROC-W 2)))) (y1 ,(n->s ny))
                                          (x2 ,(n->s (- ox (/ CARD-W 2)))) (y2 ,(n->s (alist-ref row 'y)))
                                          (stroke "rgba(226,232,240,0.2)") (stroke-width "1")
                                          (marker-end "url(#snd-arr)")))
                                 ;; Card rect
                                 (rect (@ (x ,(n->s card-x)) (y ,(n->s card-y))
                                          (width ,(n->s CARD-W)) (height ,(n->s CARD-H)) (rx ,(n->s CARD-RX))
                                          (fill "rgba(49,130,206,0.12)")
                                          (stroke ,(if bz "rgba(214,158,46,0.55)" "rgba(49,130,206,0.6)"))
                                          (stroke-width ,(if bz "1.5" "1"))
                                          ,@(if clickable
                                                `((style "cursor:pointer")
                                                  (click ,(lambda (e)
                                                            (on-card-click
                                                             `((process-id . ,(alist-ref proc 'id ""))
                                                               (proc-name . ,(alist-ref proc 'name ""))
                                                               (spec-id . ,(alist-ref row 'spec-id ""))
                                                               (spec-name . ,(alist-ref row 'spec-name ""))
                                                               (action . ,(alist-ref row 'action 'produce))
                                                               (is-input . #f)
                                                               (planned-qty . ,qty)
                                                               (unit . ,unit)
                                                               (is-work . #f)
                                                               (commitment-id . ,(alist-ref row 'commitment-id "")))))))
                                                '())))
                                 ;; Spec name
                                 (text (@ (x ,(n->s ox)) (y ,(n->s (+ card-y 13)))
                                          (text-anchor "middle") (font-size "8") (font-weight "500")
                                          (fill "#e2e8f0"))
                                   ,(trunc (alist-ref row 'spec-name "") 14))
                                 ;; Action label
                                 (text (@ (x ,(n->s ox)) (y ,(n->s (+ card-y 25)))
                                          (text-anchor "middle") (font-size "7.5") (fill ,acol))
                                   ,(symbol->string (alist-ref row 'action 'produce)))
                                 ;; Quantity
                                 (text (@ (x ,(n->s ox)) (y ,(n->s (+ card-y 37)))
                                          (text-anchor "middle") (font-size "7")
                                          (fill "rgba(226,232,240,0.4)"))
                                   ,(string-append (n->s qty) " " unit))
                                 ;; Buffer funnel
                                 ,@(if bz
                                       (let* ((fx (+ ox (/ CARD-W 2) (/ BUF-W 2) 6))
                                              (fy (alist-ref row 'y))
                                              (tog (alist-ref bz 'tog 1))
                                              (tor-f (/ (alist-ref bz 'tor 0) tog))
                                              (toy-f (/ (alist-ref bz 'toy 0) tog)))
                                         `((g (@ (transform ,(string-append
                                                              "translate(" (n->s fx) ","
                                                              (n->s (- fy (/ BUF-H 2))) ")")))
                                             ;; Red zone (bottom)
                                             (rect (@ (x "0") (y ,(n->s (* tor-f BUF-H)))
                                                      (width ,(n->s BUF-W))
                                                      (height ,(n->s (* (- 1 tor-f) BUF-H)))
                                                      (fill "rgba(197,48,48,0.5)")))
                                             ;; Yellow zone
                                             (rect (@ (x "0") (y ,(n->s (* toy-f BUF-H)))
                                                      (width ,(n->s BUF-W))
                                                      (height ,(n->s (* (- tor-f toy-f) BUF-H)))
                                                      (fill "rgba(214,158,46,0.5)")))
                                             ;; Green zone (top)
                                             (rect (@ (x "0") (y "0")
                                                      (width ,(n->s BUF-W))
                                                      (height ,(n->s (* toy-f BUF-H)))
                                                      (fill "rgba(56,161,105,0.5)"))))))
                                       '()))))
                           outputs))))
                  nodes)))))))
