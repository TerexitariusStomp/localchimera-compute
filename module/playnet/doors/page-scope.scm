;;; page-scope.scm — a scope held in a page, answering the doors a gateway answers.
;;;
;;; A page with no gateway in reach still has books: a copy of the scope its
;;; person is in (replica.scm), or the demo neighbourhood's where they are in
;;; none. This module holds such a scope (a scope root, its observer and
;;; stores, its reading fold) and answers the doors over it with the functions
;;; the planner service answers them with (count-door.scm, reading-fold.scm,
;;; inventory.scm, snapshot.scm), shaped for the page by the wire modules the
;;; page's spine shapes a gateway's replies with. So a face asks a door and
;;; cannot tell which side answered.
;;;
;;; Two layers, as on the gateway:
;;;   page-call   the service's methods, by their names and arguments, over the
;;;               held root — what `play-demo!` and a suite call;
;;;   page-door   the page's doors, by the names the seam knows them by, every
;;;               argument a string and the reply one JSON string or "err:…" —
;;;               what the worker's handler calls (hoot/scope-worker.scm). Two of
;;;               them bring a scope to be held: `open` stands the demo
;;;               neighbourhood, `hold` a replica a gateway answered.
;;;
;;; Plain Scheme over Goblins; it builds for a page (`make check-hoot-scope`).

(define-module (playnet doors page-scope)
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet scope root) #:select (spawn-scope-root))
  #:use-module ((playnet knowledge dsl world) #:select (seed-world!))
  #:use-module ((playnet knowledge worlds demo-neighbourhood)
                #:select (%demo-scope %demo-you demo-world-on play-demo!))
  #:use-module ((playnet doors count-door)
                #:select (do-count-stock count-schedule-reply count-history-reply
                          label-stock-reply read-label-reply))
  #:use-module ((playnet utils envelope) #:select (success failure catch-as-failure))
  #:use-module ((playnet doors inventory) #:select (scope-inventory-wire))
  #:use-module ((playnet scope snapshot) #:select (scope-locations->wire))
  #:use-module ((playnet scope replica) #:select (hold-replica! text->replica))
  #:use-module ((playnet observation log-observe) #:select (do-log-observe))
  #:use-module ((playnet doors slots)
                #:select (declare-need-reply declare-means-reply my-slots-reply slots-at-reply))
  #:use-module ((playnet pools reading-fold)
                #:select (^reading-pool wire-reading-node! node-readings-reply readings-between-reply))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet wire rows) #:select (->list alist-ref))
  #:use-module ((playnet wire replies) #:select (finished))
  #:use-module ((playnet utils json-portable) #:select (scm->json-canonical))
  #:export (open-neighbourhood! open-replica! page-call page-door page-doors))

;;; ── the scope held ───────────────────────────────────────────────────────

(define *vat* #f)
(define *root* #f)
(define *scope* #f)       ; the scope's id
(define *me* #f)          ; the person the page is seen through
(define *reading* #f)     ; the scope's reading fold

(define (hold! vat root scope-id me reading)
  (set! *vat* vat) (set! *root* root) (set! *scope* scope-id) (set! *me* me) (set! *reading* reading))

(define (stand! scope-id me seed!)
  "Hold a fresh scope SCOPE-ID, seen through the person ME, seeded by (SEED! root)."
  (let* ((vat (spawn-vat))
         (kit (with-vat vat
                (let* ((root (spawn-scope-root scope-id))
                       (node (spawn ^reading-pool '() '() scope-id)))
                  (seed! root)
                  ;; the reading fold reads the books it is wired to, so the books come first
                  (wire-reading-node! root node #:scope-id scope-id)
                  (cons root node)))))
    (hold! vat (car kit) scope-id me (cdr kit))))

(define (open-neighbourhood! today)
  "Stand the demo neighbourhood in a scope of this page and play what happened
   in it, as of TODAY (a unix second). Returns the acts' replies."
  (stand! %demo-scope %demo-you (lambda (root) (seed-world! root (demo-world-on today))))
  (play-demo! page-call
              ;; a contest is governance's to open, and governance stands on a gateway
              (lambda (who event-id reason) (failure "a contest is opened at a gateway"))
              today))

(define (open-replica! scope-id me text)
  "Hold a copy of the scope SCOPE-ID as its member ME, from the replica TEXT a
   gateway answered (replica.scm). Holding a newer text is the refresh."
  (let ((replica (text->replica text)))
    (stand! scope-id me (lambda (root) (hold-replica! root replica)))))

;;; ── the service's methods, over the held root ────────────────────────────

(define (in-vat thunk) (with-vat *vat* (thunk)))

(define (page-call method . args)
  "What the planner service's METHOD answers of ARGS, over the scope held here.
   A method no page answers yet is refused in the envelope, as a door refuses."
  (if (not *root*)
      (failure "no scope is held here")
      (in-vat
       (lambda ()
         (let ((root *root*))
           (finished method
           (case method
             ((count-stock)
              (apply (lambda* (scope-id agent-id resource-id counted unit
                               #:optional (technique #f) (place #f) (when-iso #f)
                                          (fulfills #f) (evidence #f) (note #f))
                       (do-count-stock root scope-id agent-id resource-id counted (string-or-false unit)
                                       #:technique (string-or-false technique) #:place (string-or-false place)
                                       #:when-iso (string-or-false when-iso) #:fulfills (string-or-false fulfills)
                                       #:evidence (string-or-false evidence) #:note (string-or-false note)))
                     args))
             ((count-history)
              (apply (lambda* (scope-id agent-id resource-id #:optional (limit #f))
                       (count-history-reply root agent-id resource-id limit))
                     args))
             ((count-schedule)
              (apply (lambda* (scope-id #:optional (regime #f))
                       (count-schedule-reply root scope-id *reading* regime))
                     args))
             ((label-stock)
              (apply (lambda (scope-id agent-id resource-id)
                       (label-stock-reply root scope-id agent-id resource-id))
                     args))
             ((read-label)
              (apply (lambda (scope-id agent-id code) (read-label-reply root code)) args))
             ((scope-readings)
              (apply (lambda (scope-id spec) (success (node-readings-reply *reading* spec))) args))
             ((readings-between)
              (apply (lambda (scope-id spec from until)
                       (catch-as-failure
                        (lambda ()
                          (success (readings-between-reply ($ ($ root 'observer) 'standing-log) scope-id spec
                                                           (string-or-false from) (string-or-false until))))))
                     args))
             ((log-observe)
              (apply (lambda (scope-id agent-id action spec qty unit note when-iso)
                       (do-log-observe root scope-id agent-id action spec qty unit
                                       #:note (string-or-false note) #:when-iso (string-or-false when-iso)))
                     args))
             ((declare-need)
              (apply (lambda (scope-id . rest) (apply declare-need-reply root rest)) args))
             ((declare-means)
              (apply (lambda (scope-id . rest) (apply declare-means-reply root rest)) args))
             ((my-slots)
              (apply (lambda (scope-id agent-id) (my-slots-reply root agent-id)) args))
             ((slots-at) (slots-at-reply root))
             ((scope-snapshot)
              (success                         `((locations . ,(scope-locations->wire root))
                          (inventory . ,(scope-inventory-wire root *scope*)))))
             (else (failure (string-append "this door is answered at a gateway: " (symbol->string method)))))))))))

;;; ── the page's doors ─────────────────────────────────────────────────────
;;; Each is (name arity ask shape): ASK takes the door's string arguments and
;;; calls the service's method; SHAPE turns what it answered into what the page
;;; reads: an object, or the word the page's spine answers that door with. The table is the page's whole surface, so the worker registers
;;; from it and the boot module learns each door's arity from it.

(define (num v) (if (string? v) (or (string->number v) 0) v))
(define (opt v) (and (string? v) (not (string-null? v)) v))
;; a read door answers the page's rows already (service.scm `finished`); the row passes
(define (as-is v) v)

(define %doors
  `(;; the two ways a scope comes to be held here; each answers the doors it then takes
    ("open" 1
     ,(lambda (today) (open-neighbourhood! (inexact->exact (floor (num today)))) (success '()))
     ,(lambda (v) `(("doors" . ,(page-doors)))))
    ("hold" 3
     ,(lambda (scope-id me text) (open-replica! scope-id me text) (success '()))
     ,(lambda (v) `(("doors" . ,(page-doors)))))
    ("snapshot" 0
     ,(lambda () (page-call 'scope-snapshot *scope*))
     ,as-is)
    ("countStock" 9
     ,(lambda (resource counted unit technique place when fulfills evidence note)
        (let ((n (if (string? counted) (string->number counted) counted)))
          (if (not (and (number? n) (>= n 0)))
              (failure "a count is a number, zero or more")
              (page-call 'count-stock *scope* *me* resource n unit technique place when fulfills evidence note))))
     ,as-is)
    ("countHistory" 2
     ,(lambda (resource limit) (page-call 'count-history *scope* *me* resource (and (opt limit) (num limit))))
     ,as-is)
    ("countSchedule" 1
     ,(lambda (regime) (page-call 'count-schedule *scope* regime))
     ,as-is)
    ("scopeReadings" 1
     ,(lambda (spec) (page-call 'scope-readings *scope* spec))
     ,as-is)
    ("readingsBetween" 3
     ,(lambda (spec from until) (page-call 'readings-between *scope* spec from until))
     ,as-is)
    ;; what people ask for and offer; a means' criteria are the matcher's to read, at a gateway
    ("declareNeed" 14
     ,(lambda (spec qty unit loc arcs note emoji from until name cats criteria tension voice)
        (page-call 'declare-need *scope* *me* spec (num qty) (or (opt unit) %count-unit) loc arcs note emoji
                   from until name cats #f tension (num voice)))
     ,(lambda (v) "ok"))
    ("declareMeans" 10
     ,(lambda (spec qty unit loc arcs note emoji name cats criteria)
        (page-call 'declare-means *scope* *me* spec (num qty) (or (opt unit) %count-unit) (opt loc)
                   arcs note emoji name cats #f))
     ,(lambda (v) "ok"))
    ;; an observation of one's own doing; the page reads the event's id after "ok:"
    ("logObserve" 6
     ,(lambda (action spec qty unit note when)
        (page-call 'log-observe *scope* *me* action spec (if (opt qty) (num qty) 1) unit note when))
     ,(lambda (v) (string-append "ok:" (alist-ref v 'event ""))))
    ("mySlots" 0 ,(lambda () (page-call 'my-slots *scope* *me*)) ,as-is)
    ("slotsAt" 0 ,(lambda () (page-call 'slots-at *scope*)) ,as-is)
    ("labelStock" 1 ,(lambda (resource) (page-call 'label-stock *scope* *me* resource)) ,as-is)))

(define (page-doors)
  "Every door this page answers, with how many arguments it takes: ((name . arity) …)."
  (map (lambda (d) (cons (first d) (second d))) %doors))

(define (fit args n)
  "ARGS as exactly N strings: an argument left out is \"\", one too many is dropped."
  (let loop ((a args) (n n))
    (cond ((zero? n) '())
          ((null? a) (cons "" (loop '() (- n 1))))
          (else (cons (car a) (loop (cdr a) (- n 1)))))))

(define (page-door name args)
  "What the door NAME answers of ARGS (strings), as the wire carries it: one JSON
   string, or \"err:\" and the refusal. A door takes as many arguments as its row
   says; one left out reads as \"\"."
  (let ((d (assoc name %doors)))
    (if (not d)
        (string-append "err:unavailable: no such door here: " name)
        (let ((reply (catch-as-failure (lambda () (apply (third d) (fit args (second d)))))))
          (cond
           ;; a door's answer is an object, written as JSON, or the word the spine answers it with
           ((and (pair? reply) (eq? 'ok (car reply)))
            (let ((out ((fourth d) (cdr reply))))
              (if (string? out) out (scm->json-canonical out))))
           ((and (pair? reply) (eq? 'error (car reply)) (string? (cdr reply)))
            (string-append "err:" (cdr reply)))
           (else "err:refused"))))))
