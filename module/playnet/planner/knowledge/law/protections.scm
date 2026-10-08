;;; law/protections.scm — the statutes that SHIELD an activity in a place.
;;;
;;; A shield removes risk; it is not a thing the activity must do. So it stays
;;; out of the demand fold (legal/registry.scm) and is carried as a FACT about a
;;; place, the way a reading of a structural demand is: registered from a
;;; context pack's `protections` section (law/context-pack.scm), read by whoever
;;; asks, cited to its source. A protection is its own serialisation — an alist:
;;;
;;;   ((place . "us") (activity . "free-food-distribution")
;;;    (name . "Bill Emerson Good Samaritan Food Donation Act")
;;;    (shields . "good-faith donation … — liability protection")
;;;    (source . "42 U.S.C. §1791 (1996)"))
;;;
;;; A place stands under its own protections and those of every place that
;;; contains it.

(define-module (playnet planner knowledge law protections)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner legal registry)       ; jurisdiction-path
  #:use-module (playnet planner facts places)     ; the one containment tree
  #:export (protection-place protection-activity protection-name
            protection-shields protection-source
            register-protection! all-protections protections-at
            protection-problems))

(define (protection-place p)    (assq-ref p 'place))
(define (protection-activity p) (assq-ref p 'activity))
(define (protection-name p)     (assq-ref p 'name))
(define (protection-shields p)  (assq-ref p 'shields))
(define (protection-source p)   (assq-ref p 'source))

;;; (place . name) → protection; registering again replaces, so loading the same
;;; pack twice leaves one row.
(define *protections* (make-hash-table))

(define (register-protection! protection)
  (hash-set! *protections*
             (cons (protection-place protection) (protection-name protection))
             protection)
  protection)

(define (all-protections)
  (sort (hash-map->list (lambda (k v) v) *protections*)
        (lambda (a b)
          (let ((pa (protection-place a)) (pb (protection-place b)))
            (if (equal? pa pb)
                (string<? (protection-name a) (protection-name b))
                (string<? pa pb))))))

(define (protections-at place-id)
  "The protections PLACE-ID stands under, by its chain and the regimes it stands
   in: the widest place's first, its own last."
  (let ((all (all-protections)))
    (append-map (lambda (id) (filter (lambda (p) (equal? id (protection-place p))) all))
                (reverse (delete-duplicates (apply append (place-endpoints place-id)))))))

;;; ─── lint : what is wrong with a protection, as strings ───────────────────
(define* (protection-problems protection #:key (known-place? place-known?))
  (let ((where (format #f "protection ~a / ~s"
                       (protection-place protection) (protection-name protection)))
        (said? (lambda (v) (and (string? v) (not (string-null? v))))))
    (append
     (provenance-problems where "protection" #:place (protection-place protection)
                          #:source (protection-source protection)
                          #:known-place? known-place?)
     (if (said? (protection-name protection)) '()
         (list (string-append where ": a protection is named")))
     (if (said? (protection-activity protection)) '()
         (list (string-append where ": a protection names the activity it shields"))))))
