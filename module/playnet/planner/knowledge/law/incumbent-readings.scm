;;; law/incumbent-readings.scm — what a structural demand's incumbent function is
;;; HERE: one steward's reading of one place.
;;;
;;; law/structural-demands.scm states each abolition once, for the general case: the
;;; incumbent L is every function the state's monopoly serves, coercive shell
;;; included. A place has its own history. France separated its churches from
;;; the state in 1905; Germany's tax offices collect the church levy today. So
;;; the incumbent that stands in a place is a READING of that place, carried the
;;; way a rule is carried: with its source, its date, its confidence and the
;;; steward who read it.
;;;
;;; A reading names the clauses of the demand's incumbent that are IN FORCE in a
;;; place. Everything else follows from the same (L, I, D) diff the general case
;;; uses (reform.scm), with L narrowed to the reading:
;;;
;;;   won       the coercive clauses (L − D) the place has already shed
;;;   standing  the coercive clauses still in force there
;;;   status    won | partly | standing — by which of the two sets is empty;
;;;             unread when the reading is the root's general case
;;;
;;; A place inherits the nearest reading up its containment chain, so a nation
;;; is read once and a region speaks only where it differs. The chain ends at
;;; the root, and the root carries the GENERAL case — the demand's whole
;;; incumbent, registered by law/structural-demands.scm. So every place resolves a
;;; reading by the one walk, and a place that reaches the root's is UNREAD: the
;;; general case is all anyone has said there.
;;;
;;; Readings ride in a context pack beside places and rules (law/context-pack.scm,
;;; the `readings` section), so a steward registers one the way they register a
;;; rule. A reading is its own serialisation — an alist:
;;;
;;;   ((place . "france") (demand . "Separate church from state")
;;;    (in-force public-education civil-registry religious-schooling)
;;;    (source . "…") (as-of . "2026-10-02") (confidence . reported)
;;;    (steward . "scope:…") (note . "…"))

(define-module (playnet planner knowledge law incumbent-readings)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner legal registry)       ; jurisdiction-path
  #:use-module (playnet planner legal reform)               ; the (L, I, D) diff
  #:use-module (playnet planner facts places)     ; the one containment tree
  #:export (reading-place reading-demand reading-in-force reading-source
            reading-as-of reading-confidence reading-steward reading-note
            register-incumbent-reading! all-incumbent-readings
            readings-at-place incumbent-at reading-general? %reading-statuses reading-standing
            reading-problems))

(define (reading-place r)      (assq-ref r 'place))
(define (reading-demand r)     (assq-ref r 'demand))
(define (reading-in-force r)   (or (assq-ref r 'in-force) '()))
(define (reading-source r)     (assq-ref r 'source))
(define (reading-as-of r)      (assq-ref r 'as-of))
(define (reading-confidence r) (or (assq-ref r 'confidence) 'reported))
(define (reading-steward r)    (assq-ref r 'steward))
(define (reading-note r)       (assq-ref r 'note))

;;; ─── the registry : (place . demand) → reading ────────────────────────────
;;; One reading per place and demand; registering again replaces it, so loading
;;; the same pack twice leaves one row.
(define *readings* (make-hash-table))

(define (register-incumbent-reading! reading)
  (hash-set! *readings* (cons (reading-place reading) (reading-demand reading)) reading)
  reading)

(define (all-incumbent-readings)
  (sort (hash-map->list (lambda (k v) v) *readings*)
        (lambda (a b)
          (let ((pa (reading-place a)) (pb (reading-place b)))
            (if (equal? pa pb)
                (string<? (reading-demand a) (reading-demand b))
                (string<? pa pb))))))

(define (readings-at-place place-id)
  "The readings registered ON this place itself, in demand order."
  (filter (lambda (r) (equal? place-id (reading-place r))) (all-incumbent-readings)))

(define (incumbent-at place-id demand-name)
  "The nearest reading of DEMAND-NAME up PLACE-ID's containment chain, then up
   the regimes it stands in, or #f."
  (any (lambda (id) (hash-ref *readings* (cons id demand-name) #f))
       (apply append (place-endpoints place-id))))

(define (reading-general? reading)
  "Is READING the general case — one registered on a root of the tree?"
  (eq? 'root (place-kind (reading-place reading))))

;;; ─── the standing of a demand under a reading ─────────────────────────────
;;; MIRROR is the demand's general (L, I, D) mirror. The reading narrows L to the
;;; clauses in force; I and D stay the federation's own.
;;; how a structural demand stands at a place, by its nearest reading
(define %reading-statuses '(won partly standing unread))

(define (reading-standing reading mirror)
  (let* ((L        (or (spec-mirror-legal mirror) '()))
         (D        (or (spec-mirror-desired mirror) '()))
         (in-force (lset-intersection eq? L (reading-in-force reading)))
         (shell    (lset-difference eq? L D))
         (won      (lset-difference eq? shell in-force))
         (standing (lset-intersection eq? shell in-force))
         (here     (spec-mirror (spec-mirror-name mirror)
                                #:kind (spec-mirror-kind mirror)
                                #:legal in-force
                                #:internal (spec-mirror-internal mirror)
                                #:desired D)))
    `((status   . ,(cond ((reading-general? reading) 'unread)
                         ((null? standing) 'won)
                         ((null? won) 'standing)
                         (else 'partly)))
      (in-force . ,in-force)
      (won      . ,won)
      (standing . ,standing)
      (entry    . ,(reform-entry here)))))

;;; ─── lint : what is wrong with a reading, as strings ──────────────────────
;;; DEMANDS is the structural catalogue (law/structural-demands.scm), passed in so
;;; this file stands below it in the load order. KNOWN-PLACE? defaults to the
;;; shared tree; the pack lint passes the places its folder declares.
(define* (reading-problems reading demands #:key (known-place? place-known?))
  (let* ((name   (reading-demand reading))
         (demand (find (lambda (d) (equal? name (assq-ref d 'name))) demands))
         (L      (if demand (or (spec-mirror-legal (assq-ref demand 'mirror)) '()) '()))
         (where  (format #f "reading ~a / ~s" (reading-place reading) name)))
    (append
     (provenance-problems where "reading" #:place (reading-place reading)
                          #:source (reading-source reading)
                          #:confidence (reading-confidence reading)
                          #:known-place? known-place?)
     (if demand '() (list (string-append where ": no structural demand has this name")))
     (filter-map (lambda (clause)
                   (and demand (not (memq clause L))
                        (format #f "~a: ~a is not a clause of the demand's incumbent" where clause)))
                 (reading-in-force reading)))))
