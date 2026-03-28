;;; buffer-zones.scm — Goblins actor for DDMRP buffer zone management
;;;
;;; Translated from src/lib/knowledge/buffer-zones.ts (BufferZoneStore)
;;;
;;; State: a hashmap of zone-id -> <buffer-zone> record (from schemas.scm).
;;; All mutations produce a new actor via bcom (immutable transitions).
;;;
;;; Persistence: Goblins cannot serialize arbitrary Guile records, only its
;;; native types (hashmaps, lists, symbols, numbers, strings, etc.).
;;; We use #:portrait to convert zones to a hashmap of id -> list (field values),
;;; and #:restore to reconstruct <buffer-zone> records on load.
;;;
;;; Lookup semantics for find-zone:
;;;   1. Exact match: spec-id + at-location
;;;   2. Global match: spec-id + no at-location (#f)
;;;   3. #f (no zone configured)
;;;
;;; DDMRP ref: Ptak & Smith Ch 8 — Buffer Profiles & Levels
;;;            Ch 12 — Signal Integrity

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization for persistence
;; =========================================================================

(define (buffer-zone->list z)
  "Convert a <buffer-zone> record to a flat list of its 40 field values.
   Field order matches make-buffer-zone constructor."
  (list (buffer-zone-id z)
        (buffer-zone-spec-id z)
        (buffer-zone-profile-id z)
        (buffer-zone-buffer-classification z)
        (buffer-zone-at-location z)
        (buffer-zone-upstream-location-id z)
        (buffer-zone-replenishment-recipe-id z)
        (buffer-zone-upstream-stage-id z)
        (buffer-zone-downstream-stage-id z)
        (buffer-zone-adu z)
        (buffer-zone-adu-unit z)
        (buffer-zone-adu-blend-ratio z)
        (buffer-zone-adu-window-days z)
        (buffer-zone-adu-computed-from z)
        (buffer-zone-adu-alert-high-pct z)
        (buffer-zone-adu-alert-low-pct z)
        (buffer-zone-adu-alert-window-days z)
        (buffer-zone-estimated-adu z)
        (buffer-zone-bootstrap-days-accumulated z)
        (buffer-zone-ost-horizon-days z)
        (buffer-zone-dlt-days z)
        (buffer-zone-moq z)
        (buffer-zone-moq-unit z)
        (buffer-zone-order-cycle-days z)
        (buffer-zone-override-reason z)
        (buffer-zone-override-note z)
        (buffer-zone-transport-days z)
        (buffer-zone-staging-days z)
        (buffer-zone-tor z)
        (buffer-zone-toy z)
        (buffer-zone-tog z)
        (buffer-zone-tipping-point z)
        (buffer-zone-red-base z)
        (buffer-zone-red-safety z)
        (buffer-zone-demand-adj-factor z)
        (buffer-zone-zone-adj-factor z)
        (buffer-zone-lead-time-adj-factor z)
        (buffer-zone-supply-offset-days z)
        (buffer-zone-active-adjustment-ids z)
        (buffer-zone-last-computed-at z)))

(define (list->buffer-zone lst)
  "Reconstruct a <buffer-zone> record from a flat list of 40 field values."
  (apply make-buffer-zone lst))

(define (zones-hashmap->portrait hm)
  "Serialize a hashmap of id -> <buffer-zone> to a hashmap of id -> list."
  (hashmap-fold (lambda (k v acc)
                  (hashmap-set acc k (buffer-zone->list v)))
                (hashmap)
                hm))

(define (portrait->zones-hashmap hm)
  "Deserialize a hashmap of id -> list back to id -> <buffer-zone>."
  (hashmap-fold (lambda (k v acc)
                  (hashmap-set acc k (list->buffer-zone v)))
                (hashmap)
                hm))


;; =========================================================================
;; ^buffer-zone-store — persistent Goblins actor
;; =========================================================================

(define-actor (^buffer-zone-store bcom zones)
  ;; zones: hashmap of string -> <buffer-zone>

  #:portrait
  (lambda () (list (zones-hashmap->portrait zones)))

  #:version 1

  #:restore
  (lambda (version serialized-zones)
    (case version
      ((1) (spawn ^buffer-zone-store (portrait->zones-hashmap serialized-zones)))
      (else (error "Unknown ^buffer-zone-store version" version))))

  (methods

    ;; --- CRUD ---

    ((add-zone zone)
     ;; Register a buffer zone. Overwrites any existing zone with the same ID.
     ;; Returns the zone ID.
     (let* ((id (or (buffer-zone-id zone) (generate-id "bz-")))
            (new-zones (hashmap-set zones id zone)))
       (bcom (^buffer-zone-store bcom new-zones)
             id)))

    ((get-zone id)
     ;; Returns the <buffer-zone> record, or #f if not found.
     (hashmap-ref zones id #f))

    ((all-zones)
     ;; Returns a list of all <buffer-zone> records.
     (hashmap-values zones))

    ;; --- Queries ---

    ((zones-for-spec spec-id)
     ;; All zones for a given ResourceSpecification ID (across all locations).
     ;; Returns global zone (no at-location) first, then location-specific.
     (let ((matching (hashmap-filter
                       (lambda (z) (equal? (buffer-zone-spec-id z) spec-id))
                       zones)))
       (append (filter (lambda (z) (not (buffer-zone-at-location z))) matching)
               (filter (lambda (z) (buffer-zone-at-location z)) matching))))

    ((find-zone spec-id . rest)
     ;; Find the best-matching zone for a spec + optional location.
     ;; Priority: exact (spec+location) > global (spec, no location) > #f.
     (let ((at-location (if (pair? rest) (car rest) #f))
           (all-vals (hashmap-values zones)))
       (or (and at-location
                (find (lambda (z)
                        (and (equal? (buffer-zone-spec-id z) spec-id)
                             (equal? (buffer-zone-at-location z) at-location)))
                      all-vals))
           (find (lambda (z)
                   (and (equal? (buffer-zone-spec-id z) spec-id)
                        (not (buffer-zone-at-location z))))
                 all-vals))))

    ;; --- Mutations ---

    ((replace-zone zone)
     ;; Replace a zone with a fully-recomputed version.
     ;; The zone's id must already exist; errors otherwise.
     ;; Returns the zone.
     (let ((id (buffer-zone-id zone)))
       (unless (hashmap-ref zones id #f)
         (error (string-append "BufferZone " id " not found")))
       (bcom (^buffer-zone-store bcom (hashmap-set zones id zone))
             zone)))

    ;; --- Recalibration ---

    ((zones-due-for-recalibration as-of-seconds profile-map)
     ;; Return all zones whose recalculation cadence has elapsed.
     ;; as-of-seconds: integer (POSIX epoch seconds)
     ;; profile-map: hashmap of profile-id -> <buffer-profile>
     ;;
     ;; Cadence check (conservative — triggers at first opportunity):
     ;;   daily   -> lastComputedAt >= 86400s ago
     ;;   weekly  -> lastComputedAt >= 7 days ago
     ;;   monthly -> lastComputedAt >= 30 days ago
     (hashmap-filter
       (lambda (z)
         (let* ((profile (hashmap-ref profile-map
                           (buffer-zone-profile-id z) #f))
                (cadence (and profile
                              (buffer-profile-recalculation-cadence profile))))
           (if (not cadence)
               #f  ;; no cadence = manual recalibration only
               (let* ((last-str (buffer-zone-last-computed-at z))
                      (last-seconds (iso-datetime->epoch last-str))
                      (age-seconds (- as-of-seconds last-seconds)))
                 (case cadence
                   ((daily)   (>= age-seconds 86400))
                   ((weekly)  (>= age-seconds (* 7 86400)))
                   ((monthly) (>= age-seconds (* 30 86400)))
                   (else #f))))))
       zones))))


;; iso-datetime->epoch is provided by store-utils.scm

;; =========================================================================
;; Persistence environment
;; =========================================================================

(define buffer-zone-store-env
  (make-persistence-env
    `((((vf knowledge) ^buffer-zone-store) ,^buffer-zone-store))))
