;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; solve/routing.scm — the arc-time table: Valhalla travel-time priors ⊕ observed EWMA.
;;;
;;; Travel time between located places is a FACT with two sources of knowledge:
;;;   prior     — the local Valhalla engine's answer over the road/transit network
;;;               (one sources_to_targets matrix call per manner, refreshed only
;;;               when the tileset changes — never on the solve path);
;;;   observed  — what performed trips actually took (the observer's pickup→
;;;               dropoff events), folded as an exponentially-weighted mean so
;;;               the federation learns its real relocation time from its own
;;;               events while old measurements age out.
;;; The merge (observed wins per key, else prior) is what `ingest-travel-times!`
;;; pours into the planner's *arc-hours* hash; planner.scm's `arc-hours` falls
;;; back to rate×haversine for any absent key, so an empty table reproduces
;;; today's numbers exactly (STRICT PARITY).
;;;
;;; Keys are "from-place|to-place|manner" where manner is a Valhalla costing
;;; ("pedestrian" "bicycle" "auto" "bus" "multimodal"). A 4th |period-class
;;; segment is reserved for time-of-day variation later; absent now.
;;; ALL hours, never seconds: the ÷3600 happens here, at the Valhalla boundary.
;;;
;;; Loaded like schemas.scm / tension-kinds.scm: a primitive-load sibling of the
;;; planner script (no define-module), also loadable standalone for the refresh
;;; CLI and the pure-fold tests. This file is the planner side's ONLY importer
;;; of (web client)/(json) — the solve path never touches either.

(define-module (localchimera solve routing)
  #:use-module ((localchimera utils host) #:select (getenv))
  #:use-module (ice-9 format)
  #:export (trip-key ewma-fold %period-classes epoch->period-class
            period-class-date-times arc-table-merge routing-save-priors!
            routing-load-priors routing-priors-stamp *valhalla-base* http-body->string
            valhalla-status valhalla-up? valhalla-tileset-stamp valhalla-matrix
            refresh-priors!)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors))

;; The priors file and the Valhalla client need a file system, an HTTP client and
;; the JSON library: a gateway has them, a page has none. Under Hoot the names
;; stand with a page's answers (no priors kept, no engine reachable); see the
;; cond-expand below.
(cond-expand (guile (use-modules (web client) (web uri) (json)))
             (else))


;; ── pure: EWMA fold over observed trips ──────────────────────────────────────
;; trips: chronological (oldest first) list of (from to manner hours).
;; Returns (("from|to|manner" . smoothed-hours) …), one entry per arc key:
;;   s₀ = x₀ ;  sₙ = α·xₙ + (1−α)·sₙ₋₁
;; Recency-weighted because cities drift; α=0.3 forgets in a few trips.
(define (trip-key tr)
  (string-append (first tr) "|" (second tr) "|" (third tr)))

(define* (ewma-fold trips #:key (alpha 0.3))
  (let ((acc (make-hash-table)))
    (for-each
     (lambda (tr)
       (let* ((k (trip-key tr)) (x (fourth tr)) (s (hash-ref acc k #f)))
         (hash-set! acc k (if s (+ (* alpha x) (* (- 1.0 alpha) s)) x))))
     trips)
    (sort (hash-map->list cons acc)
          (lambda (a b) (string<? (car a) (car b))))))

;; ── canonical period-classes — ONE vocabulary for the three parties that
;; must agree: the prior refresh (matrix date_times), the live boundary
;; (classing observed trips by their begin epoch), and the planner (mapping
;; its abstract periods through a deployment's period-spans). Local time —
;; the ONE deliberate civil-time seam in the tree: rush hour is a local
;; phenomenon, and Valhalla reads a date_time as civil at the location. The
;; planner core is UTC throughout (planner.scm iso->epoch); these classes
;; never flow back into it as instants, only as class names.
(define %period-classes '("wd-am" "wd-pm" "wd-night" "we"))

(cond-expand
(guile
(define (epoch->period-class secs)
  (let* ((tm (localtime secs)) (h (tm:hour tm)) (wd (tm:wday tm)))
    (cond ((or (= wd 0) (= wd 6))    "we")
          ((and (>= h 6)  (< h 12))  "wd-am")
          ((and (>= h 12) (< h 21))  "wd-pm")
          (else                      "wd-night"))))

(define (period-class-date-times)
  "Representative local date_times for each class in the COMING week —
   computed from now, never hardcoded, so prior refreshes don't rot."
  (let* ((day 86400) (now (current-time))
         (wd (tm:wday (localtime now)))
         (ahead (lambda (target)
                  (let ((d (modulo (- target wd) 7)))
                    (+ now (* day (if (zero? d) 7 d))))))
         (date (lambda (t) (strftime "%Y-%m-%d" (localtime t))))
         (mon (date (ahead 1))) (sat (date (ahead 6))))
    `(("wd-am"    . ,(string-append mon "T08:30"))
      ("wd-pm"    . ,(string-append mon "T17:30"))
      ("wd-night" . ,(string-append mon "T03:00"))
      ("we"       . ,(string-append sat "T11:00"))))))
(else
;; a page reads the class off the UTC hour and weekday (it has no zone table), and
;; asks no engine for date_times
(define (epoch->period-class secs)
  (let* ((s (inexact->exact (floor secs)))
         (h (modulo (floor-quotient s 3600) 24))
         (wd (modulo (+ 4 (floor-quotient s 86400)) 7)))
    (cond ((or (= wd 0) (= wd 6))    "we")
          ((and (>= h 6)  (< h 12))  "wd-am")
          ((and (>= h 12) (< h 21))  "wd-pm")
          (else                      "wd-night"))))
(define (period-class-date-times) '())))

;; ── pure: merge priors with observations — per FIELD, not per key ────────────
;; A trip measures TIME; only the matrix knows ROAD distance. So an observed
;; bare-hours entry inherits the prior's km instead of shadowing it away:
;; (observed-hours . prior-km). Keys without observations keep the prior whole.
(define (arc-table-merge priors observed)
  (append
   (map (lambda (o)
          (let ((p (assoc-ref priors (car o))))
            (if (and (pair? p) (not (pair? (cdr o))))
                (cons (car o) (cons (cdr o) (cdr p)))
                o)))
        observed)
   (remove (lambda (p) (assoc (car p) observed)) priors)))

(cond-expand
(guile
;; ── prior persistence — a plain sexp file, diffable, json-free to load ────────
;;   ((stamp . "<tileset_last_modified>") (entries (key . hours) …))
(define (routing-save-priors! path stamp entries)
  (let ((dir (dirname path)))
    (unless (file-exists? dir) (system* "mkdir" "-p" dir)))
  (call-with-output-file path
    (lambda (p)
      (write `((stamp . ,stamp) (entries . ,entries)) p)
      (newline p))))

(define* (routing-load-priors #:optional (path "data/routing/priors.sexp"))
  "Entries alist from PATH, '() when absent/unreadable."
  (or (false-if-exception
       (and (file-exists? path)
            (let ((d (call-with-input-file path read)))
              (or (assq-ref d 'entries) '()))))
      '()))

(define* (routing-priors-stamp #:optional (path "data/routing/priors.sexp"))
  (false-if-exception
   (and (file-exists? path)
        (assq-ref (call-with-input-file path read) 'stamp))))

;; ── Valhalla client (normal Guile; the Hoot (json) shadowing that constrains
;;    serve-static does not apply here) ─────────────────────────────────────────
(define *valhalla-base*
  (or (getenv "LOCALCHIMERA_VALHALLA_URL") "http://127.0.0.1:8002"))

(define (http-body->string body)
  (if (bytevector? body) (utf8->string body) body))

(define (valhalla-status)
  "Parsed /status alist, or #f when the engine is unreachable."
  (false-if-exception
   (call-with-values
       (lambda () (http-get (string-append *valhalla-base* "/status")))
     (lambda (resp body)
       (json-string->scm (http-body->string body))))))

(define (valhalla-up?) (and (valhalla-status) #t))

(define (valhalla-tileset-stamp)
  "tileset_last_modified — the prior table's version stamp."
  (and=> (valhalla-status)
         (lambda (st) (assoc-ref st "tileset_last_modified"))))

;; ONE matrix call per manner over the place-set. places = list of place ids;
;; latlon = alist or hash of place → (lat . lon). Returns the keyed entries
;; (("from|to|manner" . HOURS) …) — seconds are divided out HERE so nothing
;; downstream ever sees Valhalla's native unit. Unreachable pairs (null time)
;; and self-arcs are simply absent (the planner falls back / short-circuits).
(define* (valhalla-matrix places latlon manner
                          #:key (date-time #f) (key-suffix ""))
  ;; DATE-TIME ("2026-06-08T08:30", local) makes the matrix time-dependent —
  ;; rush-hour auto times differ from 3am's. KEY-SUFFIX ("|wd-am") stamps the
  ;; produced keys with the period-class those times belong to.
  (let* ((ll (lambda (p) (if (hash-table? latlon)
                             (hash-ref latlon p)
                             (assoc-ref latlon p))))
         (located (filter ll places))
         (locs (map (lambda (p)
                      (let ((c (ll p)))
                        `(("lat" . ,(car c)) ("lon" . ,(cdr c)))))
                    located))
         (req (scm->json-string
               `(("sources" . ,(list->vector locs))
                 ("targets" . ,(list->vector locs))
                 ("costing" . ,manner)
                 ("units" . "kilometers")
                 ,@(if date-time
                       `(("date_time" . (("type" . 1) ("value" . ,date-time))))
                       '())))))
    (if (null? located) '()
        (call-with-values
            (lambda ()
              (http-post (string-append *valhalla-base* "/sources_to_targets")
                         #:body req
                         #:headers '((content-type . (application/json)))))
          (lambda (resp body)
            (let* ((js (json-string->scm (http-body->string body)))
                   (rows (assoc-ref js "sources_to_targets"))
                   (pv (list->vector located))
                   (out '()))
              (when (vector? rows)
                (let loop-i ((i 0))
                  (when (< i (vector-length rows))
                    (let ((row (vector-ref rows i)))
                      (when (vector? row)
                        (let loop-j ((j 0))
                          (when (< j (vector-length row))
                            (let* ((ent (vector-ref row j))
                                   (t (and (pair? ent) (assoc-ref ent "time")))
                                   (dk (and (pair? ent) (assoc-ref ent "distance"))))
                              (when (and (number? t) (not (= i j)))
                                ;; (hours . net-km) — time AND real road distance,
                                ;; so the planner can spend fuel over the road it
                                ;; actually drives. Bare hours when distance absent.
                                (set! out
                                      (cons (cons (string-append
                                                   (vector-ref pv i) "|"
                                                   (vector-ref pv j) "|" manner
                                                   key-suffix)
                                                  (if (number? dk)
                                                      (cons (/ t 3600.0) dk)
                                                      (/ t 3600.0)))
                                            out))))
                            (loop-j (+ j 1))))))
                    (loop-i (+ i 1)))))
              (reverse out)))))))

;; ── refresh: fill the prior file for the current place-set ───────────────────
;; Never on the solve path — run from the refresh CLI (or a cron) when places
;; change or the tileset/GTFS is rebuilt.
;; PERIOD-CLASSES — alist (class . date_time), e.g. (("wd-am" . "2026-06-08T08:30")
;; ("wd-night" . "2026-06-08T03:00")) — adds one time-dependent matrix sweep per
;; class on top of the timeless one; classed keys carry the |class 4th segment
;; the planner's *period-class-of* prefers. Empty ⇒ exactly the old behaviour.
(define* (refresh-priors! places latlon manners
                          #:key (path "data/routing/priors.sexp")
                                (period-classes '()))
  (let* ((stamp (or (valhalla-tileset-stamp)
                    (error "valhalla unreachable — no priors refreshed")))
         (entries
          (append-map
           (lambda (m)
             (append (valhalla-matrix places latlon m)
                     (append-map
                      (lambda (pc)
                        (valhalla-matrix places latlon m
                                         #:date-time (cdr pc)
                                         #:key-suffix (string-append "|" (car pc))))
                      period-classes)))
           manners)))
    (routing-save-priors! path stamp entries)
    (format #t "priors: ~a arcs over ~a places × ~a manners × ~a classes (stamp ~a) → ~a~%"
            (length entries) (length places) (length manners)
            (+ 1 (length period-classes)) stamp path)
    entries))
)
(else
;; a page keeps no priors and reaches no routing engine: the planner reads its
;; arcs from what the observer performed, and a refresh says there is no engine
(define (routing-save-priors! path stamp entries) (error "routing-save-priors!: no file system here"))
(define* (routing-load-priors #:optional (path #f)) '())
(define* (routing-priors-stamp #:optional (path #f)) #f)
(define *valhalla-base* #f)
(define (http-body->string body) body)
(define (valhalla-status) #f)
(define (valhalla-up?) #f)
(define (valhalla-tileset-stamp) #f)
(define* (valhalla-matrix places latlon manner #:key (date-time #f) (key-suffix "")) '())
(define* (refresh-priors! places latlon manners #:key (path #f) (period-classes '()))
  (error "valhalla unreachable — no priors refreshed"))))
