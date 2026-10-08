;;; bioregions.scm — a bioregion is not a bespoke index; it is an ECOLOGICAL AGENT
;;; = a SpatialThing CONTAINER (playnet.typ §bioregion: "the watershed, the
;;; foodshed, the airshed, the ecoregion", a matter-bound scope shaped by its
;;; watershed). It carries a MULTITUDE of things, and here they are ONE object:
;;;
;;;   • where it is       — id, name, lat/lon, and its parent container (the
;;;                         containment tree it is a node of).
;;;   • its FUTURES       — a <planning-scenario> set (the weather it plans against).
;;;   • its LIMITS        — ecological fragilities (spec . (lo hi α w)): the
;;;                         regenerative envelopes its draws must not cross.
;;;
;;; A scope placed `contained-in` a bioregion INHERITS BOTH — futures and limits —
;;; by one walk up the containment tree (the same walk *frag-container* uses to
;;; debit an ecological budget). So onboarding any scope in any bioregion is generic:
;;; place it inside, and its weather and its ecological caps both follow. No
;;; per-region code — the containment relation IS the index.
;;;
;;; Loaded from planner.scm core (beside engine/robust.scm) — generic MECHANISM, no data.
;;; Knowledge/data files `register-bioregion!` a real shed; plan-scope then resolves
;;; both channels from the shed a scope sits in. The registry is seeded config (like
;;; the SpatialThing tree), NOT per-solve state — reset! deliberately leaves it.

;; A bioregion: an ecological-agent container. ONE declaration of everything it
;; carries, so a scope placed in it inherits all of it from the single object.
;; (make-record-type, matching the house style of <spatial-thing> in schemas.scm —
;; the planner is primitive-loaded without srfi-9's define-record-type in scope.)

;; The upward walk this file's climbs are built on. bioregion-find calls
;; `containment-first` directly, so the module has to be imported here rather
;; than assumed: primitive-loaded into guile-user, nothing else brings it in,
;; and the climb raises an unbound variable the moment it is actually taken.
;; The module depends only on srfi-1, so importing it closes no loop.
(define-module (playnet planner knowledge worlds bioregions)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields))
  #:use-module (playnet planner aggregation containment)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner beyond scenario)
  #:use-module ((playnet planner formulas shocks) #:select (normalize-shocks tail-beyond-record))
  #:export (<bioregion> %make-bioregion make-bioregion bioregion? bioregion-id
            bioregion-name bioregion-lat bioregion-lon bioregion-parent
            bioregion-scenarios bioregion-fragilities bioregion-boundary
            *spatial-boundaries* set-spatial-boundary! spatial-boundary-of
            bioregion-spatial *bioregions* register-bioregion!
            attach-bioregion-scenarios! bioregion-find scope-bioregion
            scope-bioregion-scenarios scope-bioregion-fragilities
            bioregion-scenarios-for bioregion-of assemble-scenarios))


;; a type is its name — the same object on both sides of the load seam



(define <bioregion>
  (vf-record-type 'Bioregion
    '((immutable id)            ; SpatialThing id (the ecological agent)
      (immutable name)
      (immutable lat)
      (immutable lon)
      (immutable parent)        ; enclosing container id (containment), or #f
      (immutable scenarios)     ; <planning-scenario> list — the futures
      (immutable fragilities)   ; (spec . (lo hi α w)) list — the limits
      (immutable boundary))))   ; GeoJSON extent (Polygon/MultiPolygon) or #f — the shape
(define %make-bioregion       (vf-record-constructor <bioregion>))
;; boundary optional so existing 7-arg constructions are unchanged (a shed with no
;; polygon is a point at lat/lon; with one it is a real region).
(define* (make-bioregion id name lat lon parent scenarios fragilities #:optional (boundary #f))
  (%make-bioregion id name lat lon parent scenarios fragilities boundary))
(define bioregion?            (vf-record-predicate   <bioregion>))
(define bioregion-id          (vf-record-accessor    <bioregion> 'id))
(define bioregion-name        (vf-record-accessor    <bioregion> 'name))
(define bioregion-lat         (vf-record-accessor    <bioregion> 'lat))
(define bioregion-lon         (vf-record-accessor    <bioregion> 'lon))
(define bioregion-parent      (vf-record-accessor    <bioregion> 'parent))
(define bioregion-scenarios   (vf-record-accessor    <bioregion> 'scenarios))
(define bioregion-fragilities (vf-record-accessor    <bioregion> 'fragilities))
(define bioregion-boundary    (vf-record-accessor    <bioregion> 'boundary))

;; GENERIC SpatialThing EXTENTS — an extent is a property of ANY SpatialThing (a
;; nation, a district, a building footprint, an ecoregion), not of a bioregion. The
;; registry maps a SpatialThing id → its GeoJSON-geometry JSON STRING (opaque over
;; OCapN + day-boot's integer-only writer, JSON.parsed client-side). Populated from a
;; SINGLE SOURCE geometry file (load-boundaries! in service.scm, at boot); empty ⇒ the
;; thing stays a point. Same attach-by-id idiom as scenarios/fragilities — one more
;; spatial property keyed off the SpatialThing id. A bioregion is just the first user.
(define *spatial-boundaries* (make-hash-table))
(define (set-spatial-boundary! id geojson-string) (hash-set! *spatial-boundaries* id geojson-string))
(define (spatial-boundary-of id) (hash-ref *spatial-boundaries* id #f))

;; The SpatialThing node this bioregion IS, ready to splice into a scope's tree —
;; carrying its EXTENT (its polygon) when it has one, else a point at lat/lon. Its own
;; boundary wins; else the one loaded by id from the single source — exactly how any
;; SpatialThing acquires an extent (nothing here is bioregion-specific but the caller).
(define (bioregion-spatial b)
  (make-spatial-thing #:id (bioregion-id b) #:name (bioregion-name b)
                      #:lat (bioregion-lat b) #:long (bioregion-lon b) #:contained-in (bioregion-parent b)
                      #:boundary (or (bioregion-boundary b) (spatial-boundary-of (bioregion-id b)))))

;; id → <bioregion>. Seeded config, not per-solve — reset! does not clear it.
(define *bioregions* (make-hash-table))
(define (register-bioregion! b) (hash-set! *bioregions* (bioregion-id b) b) b)

;; back-compat: register a SCENARIOS-only bioregion by id (no coords, no fragilities).
(define (attach-bioregion-scenarios! id scenarios)
  (register-bioregion! (make-bioregion id #f #f #f #f scenarios '())))

;; From a PLACE up the contained-in chain to the nearest REGISTERED bioregion,
;; returning the <bioregion> or #f. The climb itself is the shared one
;; (aggregation/containment.scm); what is written here is only which answer the
;; chain is being searched for. `by-id` is threadable so a whole scope resolves
;; in one id-map build.
(define* (bioregion-find spatials place-id #:optional by-id)
  (let* ((idx (or by-id (let ((h (make-hash-table)))
                          (for-each (lambda (s) (hash-set! h (spatial-thing-id s) s)) spatials) h)))
         (resolve (lambda (id) (hash-ref idx id #f))))
    (containment-first (resolve place-id)
                       (lambda (s) (hash-ref *bioregions* (spatial-thing-id s) #f))
                       #:parent-of spatial-thing-contained-in
                       #:resolve resolve)))

;; The bioregion a whole SCOPE sits in (the shed containing its places), or #f. A
;; scope normally sits in one — walk up from each of its SpatialThings, sharing one
;; id-map, and take the first registered shed.
(define (scope-bioregion spatials)
  (let ((idx (make-hash-table)))
    (for-each (lambda (s) (hash-set! idx (spatial-thing-id s) s)) spatials)
    (any (lambda (s) (bioregion-find spatials (spatial-thing-id s) idx)) spatials)))

;; The two channels a scope inherits from its shed. '() when unplaced, so an
;; unconfigured scope stays deterministic and uncapped — exactly as before.
(define (scope-bioregion-scenarios   spatials) (or (and=> (scope-bioregion spatials) bioregion-scenarios) '()))
(define (scope-bioregion-fragilities spatials) (or (and=> (scope-bioregion spatials) bioregion-fragilities) '()))

;; back-compat projections of a per-place walk (scenarios/id at a single place).
(define (bioregion-scenarios-for spatials place-id) (and=> (bioregion-find spatials place-id) bioregion-scenarios))
(define (bioregion-of            spatials place-id) (and=> (bioregion-find spatials place-id) bioregion-id))

;; Assemble a bioregion's RUIN-ROBUST scenario set — the SAME shape every shed uses:
;; three historical futures (bet on the record) + a p=0 precautionary TAIL (defended
;; without a forecast). `futures` = ((name prob mults note) …); `tail` = (mults note).
;; ids <prefix>-<name>, scenario sc-<prefix>-<name>. Returns the tail-robust list; the
;; base set is (drop-right … 1) and the tail is (last …). One place, every bioregion.
;;
;; THE TAIL STANDS BEYOND THE RECORD, by construction: its shocks are laid over
;; the record's envelope (shocks.scm tail-beyond-record), so on every channel
;; any recorded future shocks, the future the floor is defended in is at least
;; as adverse as the worst year on record. A tail stated further out stands as
;; written.
(define (assemble-scenarios prefix futures tail)
  (define (scn name prob mults note)
    (make-planning-scenario (string-append prefix "-" name)
                            (string-append "sc-" prefix "-" name) prob mults note))
  (append (map (lambda (f) (apply scn f)) futures)
          (list (scn "stress" 0.0
                     (tail-beyond-record (map (lambda (f) (normalize-shocks (caddr f))) futures)
                                         (car tail))
                     (cadr tail)))))
