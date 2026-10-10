;;; slots.scm — what people ask for and offer.
;;;
;;; A need and a means are each ONE expression (free-association's slot): a
;;; quantity of a good or a service, a place, the hours it recurs in, a note. A
;;; need is an intent on the plan-store; a means is a resource on the observer's
;;; books, accounted to the person who offers it. This module is the doors over
;;; them — declare a need, declare a means, read a person's own, read the scope's
;;; pool — each the door's whole answer over a scope root, so the planner service
;;; on a gateway and a scope held in a page (page-scope.scm) answer alike.
;;;
;;; What another part of the system says about a slot is handed in by the caller
;;; that keeps it: how far a need is met (the last solve), a means' criteria as
;;; its steward set them, the pool of lent means, and who is to hear a change.

(define-module (playnet doors slots)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond schedules)
  #:use-module ((playnet utils envelope) #:select (success failure catch-as-failure))
  #:use-module ((playnet vf facts person-facts) #:select (need-id means-id need-prefix means-prefix need-id?))
  #:use-module ((playnet utils json-portable) #:select (json-read-ordered))
  #:use-module ((playnet utils catch) #:select (catch*))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet utils units) #:select (time-unit? %count-unit %effort-unit))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet vf facts availability)
                #:select (make-dated-week dated-week? dated-week-week dated-week-dated))
  #:use-module ((playnet vf facts tension-terms)
                #:select (kind-string->symbol with-tension-terms without-tension-terms tension-kind-of tension-mass-of))
  #:use-module ((playnet observation adjustment) #:select (adjustment-event count-difference))
  #:use-module ((playnet doors counts) #:select (fresh-label))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet solve engine) #:select (owned-spec))
  #:export (arcs-json->window cats-json->list window->arcs arc-dates dated-arc?
            ratified-kinds-ref ratified-kinds-set! kind-ratified? *service-units*
            slot-criteria slot-criteria-set! move-slot-criteria!
            need-slot-row
            declare-need-reply declare-means-reply my-slots-reply slots-at-reply))

;; ── slots: the arcs wire ⇄ <availability-window> ─────────────────────────
;; One JSON convention on both rails: [{start:"HH:MM", end:"HH:MM",
;; days:["monday"…]} …] — each arc a day-schedule with one time-range,
;; unioned into a window (the same shape set-availability-ranges always
;; parsed for the AGENT'S window; factored here so resource capacities and
;; need intents ride the identical code).
(define %day-syms '(monday tuesday wednesday thursday friday saturday sunday))

(define (arcs-json->window json)
  "Parse the dial's availability-arcs JSON into an <availability-window>,
   or #f when empty/absent/unparseable (unconstrained).

   An arc is a day-schedule (days × one time-range); it may also name
   `weeks` (1–5, of the month) and `months` (1–12) — the two tiers above the
   day the window already has. The finest tier named anywhere is where the
   arcs are placed (a month-schedule holds week-schedules or day-schedules;
   the flatten in matching/availability.scm reads month > week > day), and
   the day tier ALWAYS carries the union — the planner's own readers take
   day-schedules directly and see the widest reading."
  (define (->list x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))
  (define (aref a k) (let ((p (and (pair? a) (assoc k a)))) (and p (cdr p))))
  (define (norm-days ds)
    (let ((lst (filter-map (lambda (d) (and (string? d) (string->symbol d)))
                           (->list ds))))
      (if (null? lst) %day-syms lst)))
  (define (norm-ints xs lo hi)
    (let ((l (filter (lambda (n) (and (integer? n) (<= lo n hi)))
                     (map (lambda (x) (if (string? x) (or (string->number x) 0) x))
                          (->list xs)))))
      (and (pair? l) (sort (delete-duplicates l) <))))
  (and (string? json) (not (string-null? json))
       (let* ((parsed (catch* #t (lambda () (json-read-ordered json)) (lambda _ '())))
              ;; (ds weeks months) per arc
              (arcs
               (filter-map
                (lambda (arc)
                  (let ((s (aref arc "start")) (e (aref arc "end")))
                    (and (string? s) (string? e) (not (dated-arc? arc))
                         (list (make-day-schedule (norm-days (aref arc "days"))
                                                  (list (make-time-range s e)))
                               (norm-ints (aref arc "weeks") 1 5)
                               (norm-ints (aref arc "months") 1 12)))))
                (->list parsed)))
              ;; dated arcs: {start end dates:["YYYY-MM-DD"…]} — the offer on
              ;; those dates stated outright; a zero-length range is a day
              ;; withdrawn. One <specific-date-window> per date-set.
              (dated
               (let loop ((arcs (filter dated-arc? (->list parsed))) (acc '()))
                 (if (null? arcs) (reverse acc)
                     (let* ((a (car arcs)) (ds (arc-dates a))
                            (same (filter (lambda (x) (equal? (arc-dates x) ds)) arcs))
                            (rest (filter (lambda (x) (not (equal? (arc-dates x) ds))) arcs))
                            (trs (filter-map (lambda (x)
                                               (let ((s (aref x "start")) (e (aref x "end")))
                                                 (and (string? s) (string? e) (not (equal? s e))
                                                      (make-time-range s e))))
                                             same)))
                       (loop rest (cons (make-specific-date-window ds trs) acc))))))
              (dss (map car arcs))
              (any-weeks  (any cadr arcs))
              (any-months (any caddr arcs))
              (week-of (lambda (a) (make-week-schedule (or (cadr a) '(1 2 3 4 5)) (list (car a)))))
              (weeks (and any-weeks (not any-months) (map week-of arcs)))
              (months
               (and any-months
                    (map (lambda (m)
                           (let ((here (filter (lambda (a) (memv m (or (caddr a) '(1 2 3 4 5 6 7 8 9 10 11 12))))
                                               arcs)))
                             (make-month-schedule
                              m
                              (let ((ws (filter-map (lambda (a) (and (cadr a) (week-of a))) here)))
                                (and (pair? ws) ws))
                              (let ((ds (filter-map (lambda (a) (and (not (cadr a)) (car a))) here)))
                                (and (pair? ds) ds))
                              #f)))
                         (filter (lambda (m) (any (lambda (a) (memv m (or (caddr a) '(1 2 3 4 5 6 7 8 9 10 11 12)))) arcs))
                                 '(1 2 3 4 5 6 7 8 9 10 11 12))))))
         (let ((week (and (pair? dss) (make-availability-window months weeks dss #f))))
           (cond ((and week (pair? dated)) (make-dated-week week dated))
                 ((pair? dated) (make-dated-week (make-availability-window #f #f '() #f) dated))
                 (else week))))))

(define (arc-dates arc)
  (let ((ds (let ((p (and (pair? arc) (assoc "dates" arc)))) (and p (cdr p)))))
    (let ((l (filter (lambda (d) (and (string? d) (>= (string-length d) 10)))
                     (cond ((vector? ds) (vector->list ds)) ((list? ds) ds) (else '())))))
      (and (pair? l) (sort (delete-duplicates (map (lambda (d) (substring d 0 10)) l)) string<?)))))

(define (dated-arc? arc) (and (arc-dates arc) #t))

(define (cats-json->list json)
  "Parse a JSON array of category term-ids into a list of strings; '() when
   empty/absent/unparseable. The classify pass hands the dial's suggested
   folksonomy terms through declare-need/declare-means on this wire."
  (if (and (string? json) (not (string-null? json)))
      (catch* #t
        (lambda ()
          (let ((parsed (json-read-ordered json)))
            (filter string?
                    (cond ((vector? parsed) (vector->list parsed))
                          ((list? parsed) parsed)
                          (else '())))))
        (lambda _ '()))
      '()))

(define (window->arcs aw)
  "Flatten an <availability-window> — or a dated week, its week's arcs and then
   one dated arc per exception range, a withdrawn day as a zero-length one —
   into the arcs wire:
   (((start . s) (end . e) (days . (sym …)) [(weeks . (n …))] [(months . (n …))]) …).
   Reads the tier the window was placed in (month > week > day) and merges
   the arcs of one (days · time · weeks) back over their months, so an arc
   declared for every month reads back without a months field. '() when no
   window."
  (define (dated-arcs sdw)
    (let ((dates (or (specific-date-window-specific-dates sdw) '()))
          (trs (or (specific-date-window-time-ranges sdw) '())))
      (if (null? trs)
          `(((start . "00:00") (end . "00:00") (dates . ,dates)))
          (map (lambda (tr) `((start . ,(time-range-start-time tr))
                              (end   . ,(time-range-end-time tr))
                              (dates . ,dates)))
               trs))))
  (define all-months '(1 2 3 4 5 6 7 8 9 10 11 12))
  (define all-weeks '(1 2 3 4 5))
  (define (ds-arcs ds weeks months)         ; one day-schedule → arcs
    (map (lambda (tr)
           `((start . ,(time-range-start-time tr))
             (end   . ,(time-range-end-time tr))
             (days  . ,(day-schedule-days ds))
             ,@(if weeks `((weeks . ,weeks)) '())
             ,@(if months `((months . ,months)) '())))
         (or (day-schedule-time-ranges ds) '())))
  (define (ws-arcs ws months)
    (let ((w (week-schedule-weeks ws)))
      (append-map (lambda (ds) (ds-arcs ds (and (not (equal? (sort (or w '()) <) all-weeks)) w) months))
                  (or (week-schedule-day-schedules ws) '()))))
  (define (merge-months arcs)               ; same arc over several months → one arc
    (let loop ((rest arcs) (acc '()))
      (if (null? rest) (reverse acc)
          (let* ((a (car rest))
                 (key (lambda (x) (list (assq-ref x 'start) (assq-ref x 'end)
                                        (assq-ref x 'days) (assq-ref x 'weeks))))
                 (same (filter (lambda (x) (equal? (key x) (key a))) rest))
                 (others (filter (lambda (x) (not (equal? (key x) (key a)))) rest))
                 (ms (sort (delete-duplicates (append-map (lambda (x) (or (assq-ref x 'months) '())) same)) <))
                 (base (filter (lambda (p) (not (eq? (car p) 'months))) a)))
            (loop others (cons (if (or (null? ms) (equal? ms all-months)) base
                                   (append base `((months . ,ms))))
                               acc))))))
  (cond
   ((not aw) '())
   ((dated-week? aw) (append (window->arcs (dated-week-week aw))
                             (append-map dated-arcs (dated-week-dated aw))))
   ((pair? (availability-window-month-schedules aw))
    (merge-months
     (append-map
      (lambda (ms)
        (let ((m (list (month-schedule-month ms))))
          (append (append-map (lambda (ws) (ws-arcs ws m)) (or (month-schedule-week-schedules ms) '()))
                  (append-map (lambda (ds) (ds-arcs ds #f m)) (or (month-schedule-day-schedules ms) '())))))
      (availability-window-month-schedules aw))))
   ((pair? (availability-window-week-schedules aw))
    (append-map (lambda (ws) (ws-arcs ws #f)) (availability-window-week-schedules aw)))
   (else
    (append-map (lambda (ds) (ds-arcs ds #f #f))
                (or (availability-window-day-schedules aw) '())))))

;; ── ratified kinds: the constitution's one mechanical rule ─────────────────
;; A kind other than a want — `held` (never zeroed) or `floor` (a right) — is a
;; statement the scope makes, never the citizen alone (truth-telling.md,
;; stage 1: claiming `held` is the strongest move in the game, and its
;; tension mass is unbounded, so no budget prices it). The scope's grants
;; live on its own plan-store as metadata, keyed by SPEC — categorical, as a
;; floor is ("the prescription is a right", "physio may be held") — with the
;; ratifier's AID and instant on each. The rite that authorises a ratifier is
;; the scope's own (a table vote, a steward's ack); this door records who,
;; and the gate in declare-need reads the result.
(define (ratified-kinds-ref root)
  (or (false-if-exception
       (let ((row ($ ($ root 'plan-store) 'get-meta "ratified-kinds")))
         (and row (assq-ref row 'grants))))
      '()))

(define (ratified-kinds-set! root grants)
  ($ ($ root 'plan-store) 'set-meta "ratified-kinds" (list (cons 'grants grants))))

(define (kind-ratified? root spec kind)
  "Does the scope ratify SPEC as KIND? A want needs no ratification; a floor
   grant also covers held (a right may be stated as a need, never the other
   way round)."
  (or (eq? kind 'des)
      (let ((g (assoc-ref (ratified-kinds-ref root) spec)))
        (and g (let ((gk (assq-ref g 'kind)))
                 (or (eq? gk kind) (and (eq? gk 'floor) (eq? kind 'held))))))))

;; SERVICE-DENOMINATED units: a need declared in one of these is occupancy of a
;; durable's service — action 'use, effort-quantity — exactly as hours are. The
;; list is the generic-resource seam: housing's person-nights, transit's
;; seat-hours, storage's m3-days each name a Svc| draw, never a good consumed.
;; A unit NOT here still declares (as a 'consume good) — this list only decides
;; which VF action carries the measure.
(define *service-units*
  '("person-nights" "person-night" "seat-hours" "seat-hour" "m3-days" "m3-day"))

;; ── the slot's criteria sidecar ─────────────────────────────────────────────
;; The matcher-only fields <intent-matching-criteria> names (the eligibility
;; rule, divisibility, an online link, a priority) ride each declare as ONE
;; JSON object and are kept here beside the record they qualify — keyed by
;; the scope's own ROOT object (not its id string — two ^planner-service
;; instances can both have a "Granary", and a string key would let one
;; instance's criteria answer the other's) + row id, so a need and a means
;; keep their own. In memory, like the means-caps below: the record is the
;; plan-store's, the sidecar is the matcher's, and a re-declare without one
;; clears it (editing IS declaring).
(define *slot-criteria* (make-hash-table))

(define (criteria-key root rid) (cons root rid))

(define (slot-criteria-set! root rid criteria)
  "Keep CRITERIA (the alist the matcher reads, or #f to clear) beside the row RID of ROOT."
  (if criteria
      (hash-set! *slot-criteria* (criteria-key root rid) criteria)
      (hash-remove! *slot-criteria* (criteria-key root rid))))

(define (slot-criteria root rid)
  (hash-ref *slot-criteria* (criteria-key root rid) #f))

;; a standing need <intent> as one slot row — my-slots (the citizen's own view)
;; and slots-at (the scope-wide pool) read the SAME shape from this one
;; builder, so the two wires cannot drift. `who` is the intent's receiver;
;; my-slots' caller already knows it is themselves, the pool's reader needs it.
;; `criteria` is the sidecar above, as the dial sent it (#f when none).
(define (no-met spec) #f)
(define* (need-slot-row i scope-root #:key (met-of no-met))
  (define (mq m acc) (if m (acc m) #f))
  (let ((measure (or (intent-resource-quantity i) (intent-effort-quantity i))))
    `((id    . ,(intent-id i))
      (criteria . ,(and scope-root (slot-criteria scope-root (intent-id i))))
      ;; the plan's provision of this need, as of the last solve (#f = none
      ;; yet): the citizen's OWN delivered good first (a want stated for
      ;; oneself is felt on "spec~aid"), else the scope's good
      (met   . ,(and scope-root
                     (let ((spec (intent-resource-conforms-to i)) (who (intent-receiver i)))
                       (or (and spec who (met-of (owned-spec spec who)))
                           (met-of spec)))))
      (spec  . ,(intent-resource-conforms-to i))
      (name  . ,(or (intent-name i) (intent-resource-conforms-to i)))
      (emoji . ,(intent-image i))
      (note  . ,(intent-note i))
      (who   . ,(intent-receiver i))
      (qty   . ,(or (mq measure measure-has-numerical-value) 0))
      (unit  . ,(or (mq measure measure-has-unit) %count-unit))
      (where . ,(intent-at-location i))
      (from  . ,(intent-has-beginning i))
      (until . ,(intent-has-end i))
      (cats  . ,(without-tension-terms (intent-resource-classified-as i)))
      (tension . ,(symbol->string (tension-kind-of (intent-resource-classified-as i))))
      ;; the attached voice — a legacy level ladder row reads as its mass
      ;; (tension-mass-of), so one field carries the emphasis either way
      (voice . ,(or (tension-mass-of (intent-resource-classified-as i)
                                     (or (mq measure measure-has-numerical-value) 1))
                    0))
      (arcs  . ,(window->arcs (intent-availability-window i))))))

;; The criteria sidecar of a slot follows the slot: set at TO's root when it
;; has none, gone from FROM's root.
(define (move-slot-criteria! from-root to-root rid)
  (let ((c (slot-criteria from-root rid)))
    (when (and c (not (slot-criteria to-root rid)))
      (hash-set! *slot-criteria* (criteria-key to-root rid) c))
    (hash-remove! *slot-criteria* (criteria-key from-root rid))))

;;; ── the doors ────────────────────────────────────────────────────────────

(define* (declare-need-reply root agent-id spec qty unit location arcs-json note emoji from until
                             #:optional (name #f) (cats-json #f) (criteria #f) (need-kind #f) (voice 0)
                             #:key (changed! (lambda () #t)))
  "AGENT-ID states a need of QTY UNIT of SPEC. CRITERIA is the matcher's alist or
   #f; CHANGED! is called once the need stands."
  (catch-as-failure
  (lambda ()
    (let* ((ps  ($ root 'plan-store))
           (iid (need-id agent-id spec))
           (u   (if (and (string? unit) (not (string-null? unit))) unit %count-unit))
           (loc (string-or-false location))
           (window (arcs-json->window arcs-json))
           (name (or (string-or-false name) (string-or-false spec)))
           ;; classification terms for the need side of affinity —
           ;; and, under the reserved prefix, the need's own KIND and
           ;; VOICE (tension-terms.scm), NEED-KIND "floor"|"held"|"des"
           ;; (des when unstated). They ride on the intent so the
           ;; demand fold, which reads intents alone, carries them
           ;; up as totals.
           (kind (kind-string->symbol (if (string? need-kind) need-kind "des")))
           (voice (cond ((number? voice) voice)
                        ((and (string? voice) (string->number voice)) => (lambda (n) n))
                        (else 0)))
           (cats (with-tension-terms (cats-json->list cats-json) kind voice))
           ;; VF measures by kind: a time — and any SERVICE-DENOMINATED
           ;; unit (*service-units*: a bed's person-nights, a network's
           ;; seat-hours) — is occupancy: effort-quantity with action
           ;; 'use (services OCCUPY, they are never held); anything else
           ;; is a good — resource-quantity, 'consume
           (hours? (or (time-unit? u)
                       (member u *service-units*)))
           (m (make-measure qty u)))
      ;; the constitution's gate: a kind beyond a want is the scope's
      ;; statement (ratified-kinds), so an unratified one is refused
      ;; with the rite named — a bare declare states a want
      (if (not (kind-ratified? root spec kind))
          (failure (format #f "~a as ~a needs the scope's ratification (ratify-kind); a bare declare states a want"
                           spec kind))
          (begin
      (when ($ ps 'get-intent iid) ($ ps 'remove-intent iid))
      ($ ps 'add-intent
         (make-intent
          #:id iid #:action (if hours? 'use 'consume) #:name name #:note (string-or-false note) #:image (string-or-false emoji) #:resource-conforms-to spec #:resource-classified-as (and (pair? cats) cats)
          #:resource-quantity (if hours? #f m) #:effort-quantity (if hours? m #f) #:receiver agent-id
          #:has-beginning (string-or-false from) #:has-end (string-or-false until)
          #:at-location loc #:in-scope-of '()
          #:availability-window window))
      ;; the criteria sidecar, one JSON object; absent clears
      (slot-criteria-set! root iid criteria)
      (changed!)
      (success `((id . ,iid)))))))))

(define* (declare-means-reply root agent-id spec qty unit location
                              #:optional (arcs-json #f) (note #f) (emoji #f) (name #f) (cats-json #f) (criteria #f)
                              #:key (changed! (lambda () #t)))
  "AGENT-ID offers QTY UNIT of SPEC: a resource on the books, accounted to them.
   CRITERIA is the matcher's alist or #f; CHANGED! is called once it stands."
  (let* ((obs ($ root 'observer))
       (rid (means-id agent-id spec))
       (u   (if (and (string? unit) (not (string-null? unit))) unit %count-unit))
       (m   (make-measure qty u))
       (loc (if (and (string? location) (not (string-null? location))) location #f))
       (window (arcs-json->window arcs-json))
       (note  (string-or-false note))
       (emoji (string-or-false emoji))
       (name  (or (string-or-false name) (string-append agent-id "'s " spec)))
       ;; classification terms (the classify pass's suggestion, or
       ;; the citizen's own tags) — the offer side of affinity
       (cats (cats-json->list cats-json)))
  ;; editing IS declaring, and a quantity edit is an EVENT: the
  ;; metadata re-seeds carrying the CURRENT on-hand, then a
  ;; raise/lower moves it to the asked quantity — the skills
  ;; discipline, so the record and its history survive every edit
  (let* ((was   ($ obs 'get-resource rid))
         (prior (and=> was
                       (lambda (r) (measure-has-numerical-value
                                    (economic-resource-onhand-quantity r)))))
         (base  (or prior qty)))
    ;; a re-declaration is a copy of the record with what the
    ;; declaration states changed: the code a thing is known by, what
    ;; it sits in, its lot, its custody, stage and state are the
    ;; thing's own and outlast every edit. The tags a declaration
    ;; states decide the distribution mode, so a declaration that
    ;; states none states none.
    (let ((tags (and (pair? cats) cats)))
      ($ obs 'record-resource
         (if was
             (copy-economic-resource
              was #:name name #:note note #:image emoji
              #:conforms-to spec #:classified-as tags
              #:accounting-quantity (make-measure base u)
              #:onhand-quantity (make-measure base u)
              #:current-location loc #:primary-accountable agent-id
              #:availability-window window #:distribution-mode #f)
             (make-economic-resource
              #:id rid #:name name #:note note #:image emoji #:tracking-identifier (fresh-label obs) #:conforms-to spec #:classified-as tags
              #:accounting-quantity (make-measure base u) #:onhand-quantity (make-measure base u)
              #:current-location loc #:primary-accountable agent-id #:availability-window window))))
    (when prior
      (let ((now (iso-now)))
        (let ((ev (adjustment-event (generate-id (string-append "declare:" rid ":" now ":")) rid spec
                                    (count-difference prior qty) u
                                    #:provider agent-id #:receiver agent-id
                                    #:when now #:created now #:counted qty
                                    #:note "means re-declared")))
          (when ev ($ obs 'record-event ev))))))
  ;; the criteria sidecar (eligibility rule · divisibility · link ·
  ;; priority), one JSON object; absent clears
  (slot-criteria-set! root rid criteria)
  (changed!)        ; the means fold hears its writer
  `(ok . ,rid)))

(define* (my-slots-reply root agent-id #:key (met-of no-met) (criteria-of #f))
  "AGENT-ID's own needs and means, one wire. MET-OF says how far a spec is met;
   CRITERIA-OF gives a means' criteria (the sidecar's, when unstated)."
  (let ((criteria-of (or criteria-of (lambda (r) (slot-criteria root (economic-resource-id r))))))
    (catch-as-failure
    (lambda ()
      (let* ((ps  ($ root 'plan-store))
             (obs ($ root 'observer))
             (mprefix (means-prefix agent-id))
             (nprefix (need-prefix agent-id))
             (mq (lambda (m acc) (if m (acc m) #f)))
             (needs
              (filter-map
               (lambda (i)
                 (and (string-prefix? nprefix (intent-id i))
                      (not (intent-finished i))
                      (need-slot-row i root #:met-of met-of)))
               ($ ps 'all-intents)))
             (means
              (filter-map
               (lambda (r)
                 (let ((q (or (mq (economic-resource-onhand-quantity r)
                                  measure-has-numerical-value) 0)))
                   (and (string-prefix? mprefix (economic-resource-id r))
                        (> q 0)
                        `((id    . ,(economic-resource-id r))
                          (spec  . ,(economic-resource-conforms-to r))
                          (name  . ,(or (economic-resource-name r)
                                        (economic-resource-conforms-to r)))
                          (emoji . ,(economic-resource-image r))
                          (note  . ,(economic-resource-note r))
                          (qty   . ,q)
                          (unit  . ,(or (mq (economic-resource-onhand-quantity r)
                                            measure-has-unit) %count-unit))
                          (where . ,(economic-resource-current-location r))
                          (cats  . ,(or (economic-resource-classified-as r) '()))
                          (criteria . ,(criteria-of r))
                          (arcs  . ,(window->arcs
                                      (economic-resource-availability-window r)))))))
               ($ obs 'inventory))))
        (success `((needs . ,needs) (means . ,means))))))))

(define* (slots-at-reply root #:key (met-of no-met) (solved '()) (pool #f))
  "The scope's pool: every standing need, and the means lent into the commons.
   SOLVED is the last solve's lent means with how much of each is taken; POOL,
   where the scope keeps one, is the lent means as they stand now."
  (catch-as-failure
   (lambda ()
     (let* ((needs (filter-map
                    (lambda (i)
                      (and (need-id? (intent-id i))
                           (not (intent-finished i))
                           (need-slot-row i root #:met-of met-of)))
                    ($ ($ root 'plan-store) 'all-intents)))
            (drawn-by-id (map (lambda (x) (cons (assq-ref x 'id) (assq-ref x 'drawn))) solved))
            (drawn-of (lambda (row) (or (assoc-ref drawn-by-id (assq-ref row 'id)) 0.0)))
            (means (if pool
                       (map (lambda (row) (cons (cons 'drawn (drawn-of row)) row)) pool)
                       solved)))
       (success `((needs . ,needs) (means . ,means)))))))
