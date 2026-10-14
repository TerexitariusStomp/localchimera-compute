;;; module/playnet/doors/record-flow.scm — one material row of the plan confirmed: the rows a plan states, held as the commitments they are, and a quantity recorded against them.
;;;
;;; A library the planner service's record-flow door calls (docs/planning/codebase-layout.md
;;; §12), and the device's own door over its copy of the scope (doors/page-scope.scm): a
;;; verb takes the scope root, the plan's rows and what they were solved with, and the
;;; arguments; the door is the gate and one call. The rows are `Commitment` records, so they
;;; travel in a replica (scope/replica.scm) and a device confirms against what the plan
;;; last stated.

(define-module (playnet doors record-flow)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet observation account) #:select (fulfillment-remaining))
  #:use-module ((playnet observation landing) #:select (standing-event tap-event-id tap?))
  #:use-module ((playnet observation observer) #:select (reach-slack target-passed?))
  #:use-module ((playnet scope live) #:select (held-commitment record-flow-done))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet vf formulas actions) #:select (*flow-actions* occupying-actions relocating-actions))
  #:use-module ((playnet vf formulas flows) #:select ((row-id . flow-row-id) row-action row-place row-quantity row-run row-spec row-when))
  #:use-module ((playnet vf schemas) #:select (economic-event-effort-quantity economic-event-id economic-event-resource-quantity measure-has-numerical-value))
  #:use-module ((srfi srfi-1) #:select (filter filter-map fold))
  #:export (do-record-flow rows-matching hold-row! planned-row-id row-left))

;; the record-flow door names one of its arguments `row-id` (the protocol declares it);
;; under that name a caller reads a row's id by this one
(define planned-row-id flow-row-id)

(define (rows-matching material action spec place when-iso proc)
  "The rows of MATERIAL (the material rows of a plan) that are the row ACTION SPEC at
   PLACE of PROC (at WHEN-ISO when one is named). What a confirmation may record is what
   the plan states."
  (filter (lambda (m)
            (and (equal? (format #f "~a" (row-action m)) action)
                 (equal? (row-spec m) spec)
                 (equal? (or (row-place m) "") (or place ""))       ; the wire spells an absent value ""
                 (equal? (or (row-run m) "") (or proc ""))
                 (or (not when-iso) (equal? when-iso "") (equal? (format #f "~a" (row-when m)) when-iso))))
          material))

(define (hold-row! obs scope-id m)
  "Register the plan's row M as the commitment it is, under the plan's own row id: a
   row the plan states again moves its target and keeps what was confirmed."
  ($ obs 'register-commitment (held-commitment m scope-id)))

(define (row-left obs m)
  "What the events fulfilling plan row M have not yet met of it."
  (fulfillment-remaining ($ obs 'get-fulfillment (planned-row-id m))))

;; How much of the row CID the act under EVENT-ID recorded: its event, and the ones a
;; draw from several lots added (`<id>.1`, `<id>.2`), each its resource figure or, for a
;; means occupied, its hours.
(define (share-recorded obs cid event-id)
  (fold + 0
        (filter-map (lambda (e)
                      (let ((id (or (economic-event-id e) "")))
                        (and (or (string=? id event-id) (string-prefix? (string-append event-id ".") id))
                             (let ((q (or (economic-event-resource-quantity e) (economic-event-effort-quantity e))))
                               (and q (measure-has-numerical-value q))))))
                    (or ($ obs 'fulfilled-by cid) '()))))


(define* (do-record-flow root scope-id material runs vocabulary action spec qty place when-iso proc
                         #:key (row-id #f) (tap #f))
  "Record QTY of the plan row ACTION SPEC at PLACE of PROC against the scope ROOT, the
   per-row browser door onto the same confirmation mile enact walks wholesale. MATERIAL is
   the plan's material rows, RUNS the runs it names and VOCABULARY the goods it read stock
   against (#f reads the standing one). The row is found among MATERIAL by its own id
   (ROW-ID, which the schedule carries) or, for a caller that has none, by its coordinates
   (action, spec, place, when, process). Each plan row is a commitment under the plan's own
   row id, so this door and enact name one commitment per row and FulfillmentState governs
   partials as it does for work: QTY is spread over the matching rows' remainders in plan
   order (a numbered event each), a finished row answers `already` instead of double-moving
   stock, and more than the rows hold is refused here, where the member's word becomes an
   event. The flow is dated at the row's planned slot, or at its confirmation when the slot
   is still ahead (live.scm planned-stamp). The two rows of a relocation chain through the
   cargo's own lot: a dropoff lands what its pickup carried, and is refused before that.
   Replies (ok . ((event-id . id) [again] [already])) or the refusal.
   NB the clock argument is named when-iso, never `when`: a parameter named `when`
   lexically shadows the macro."
  (catch-as-failure
    (lambda ()
      (if (not (memq (string->symbol action)                    ; the actions a material row carries: a flow, a relocation, an occupation
                     (append *flow-actions* relocating-actions occupying-actions)))
          (failure (string-append "unknown flow action: " action))
          (let* ((obs  ($ root 'observer))
                 (rows (if (and (string? row-id) (not (string-null? row-id)))
                           (filter (lambda (m) (equal? (planned-row-id m) row-id)) material)
                           (rows-matching material action spec place when-iso proc))))
            (when (null? rows)
              (error "the plan holds no such row; confirm what the plan states" action spec place))
            (for-each (lambda (m) (hold-row! obs scope-id m)) rows)
            (let* ((tap  (string-or-false tap))
                   (_    (when (and tap (not (tap? tap))) (error "a tap is 1 to 64 letters, digits, _ or -" tap)))
                   ;; THE ACT'S OWN IDENTITY: with a tap, each row's share of this act is the
                   ;; event under (row, tap), so a repeat of the request finds what landed
                   ;; and takes it off what is still to record. Asked of EVERY matched row,
                   ;; the finished ones too: a share that filled its row leaves no room, and
                   ;; room is not how a repeat is told from a new act.
                   (stood (if tap
                              (filter-map (lambda (m) (let ((e (standing-event obs (tap-event-id (planned-row-id m) tap))))
                                                        (and e (cons m e))))
                                          rows)
                              '()))
                   (landed (fold + 0 (map (lambda (me) (share-recorded obs (planned-row-id (car me)) (tap-event-id (planned-row-id (car me)) tap)))
                                          stood)))
                   (need0 (- qty landed))
                   (open (filter (lambda (m) (and (> (row-left obs m) (reach-slack (row-quantity m)))
                                                  (not (assoc m stood))))
                                 rows))
                   (room (fold + 0 (map (lambda (m) (row-left obs m)) open))))
              (cond
               ;; the whole act is already in the books; or it has landed on every row it can
               ;; (a repeat that states another figure is still the same press: the key names the
               ;; act, so what stands is the answer). Only a press that landed on some rows and
               ;; has rows still open for the rest (a spread the first request did not finish) goes on.
               ((and (pair? stood) (or (not (target-passed? need0 0)) (null? open)))
                (success `((event-id . ,(economic-event-id (cdar stood))) (again . #t) (already . #t))))
               ((null? open) (success `((event-id . "") (already . #t))))
               ((target-passed? need0 room)
                (error (format #f "the row holds ~a more; ~a recorded" room need0)))
               (else
                (let spend ((ms open) (need need0) (first (and (pair? stood) (economic-event-id (cdar stood)))))
                  (if (or (null? ms) (not (target-passed? need 0)))
                      (success `((event-id . ,(or first ""))))
                      (let* ((m    (car ms))
                             (cid  (planned-row-id m))
                             (take (min need (row-left obs m)))
                             (evid (if tap
                                       (tap-event-id cid tap)
                                       (string-append "ev-" cid "-"
                                                      (number->string (length (or ($ obs 'fulfilled-by cid) '())))))))
                        (record-flow-done root m
                                          #:quantity take #:event-id evid
                                          #:vocabulary vocabulary
                                          #:runs runs)
                        (spend (cdr ms) (- need take) (or first evid)))))))))))))
