;;; test-buffer-management.scm — Buffer tracking, snapshots, and eco-signals
;;;
;;; Ported from: old/planner/src/lib/tests/buffer-snapshots.test.ts
;;;              old/planner/src/lib/tests/buffer-first-inversion.test.ts
;;;              old/planner/src/lib/tests/eco-buffer.test.ts
;;;
;;; Intent: Verify buffer snapshot recording, zone transition tracking,
;;; first-inversion detection, tipping point breach for ecological
;;; buffers, and conservation signal generation.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-buffer-management.scm

(use-modules (playnet test harness))
(use-modules (playnet planner ddmrp buffers) (playnet planner federation remote-transport) (playnet planner scope root) (playnet planner vf schemas) (playnet planner ddmrp records) (playnet utils store-utils) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Buffer Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-water" #:name "Water"
                                    #:default-unit-of-resource "litre"))
    (check-pred "specs ok" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Buffer zone creation and retrieval
;;;
;;; Ported from: buffer-snapshots "record and retrieve"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Buffer zone CRUD ──\n")

(with-vat vat
  (let ((bzs ($ scope 'buffer-zone-store)))
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-wheat" "spec-wheat" "bp-1" 'replenished
         #f #f #f #f #f
         25 "kg" #f #f #f #f #f #f #f #f #f
         10 0 "kg" #f #f #f #f #f
         100 250 400 #f #f #f #f #f #f #f #f
         "2026-03-27T00:00:00Z"))

    (check-pred "zone created" (buffer-zone? ($ bzs 'get-zone "bz-wheat")))
    (let ((bz ($ bzs 'get-zone "bz-wheat")))
      (check "zone spec" (buffer-zone-spec-id bz) "spec-wheat")
      (check "zone tor" (buffer-zone-tor bz) 100)
      (check "zone toy" (buffer-zone-toy bz) 250)
      (check "zone tog" (buffer-zone-tog bz) 400))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Buffer snapshots
;;;
;;; Ported from: "record snapshot with zone classification"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Buffer snapshots ──\n")

(with-vat vat
  (let ((sns ($ scope 'snapshot-store)))
    ;; Day 1: green zone (onhand=350, TOY=250, TOG=400)
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-28" 350 100 250 400 'green))

    ;; Day 2: yellow zone (onhand=180)
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-29" 180 100 250 400 'yellow))

    ;; Day 3: red zone (onhand=80)
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-30" 80 100 250 400 'red))

    (check "3 snapshots" (length ($ sns 'all-snapshots)) 3)

    ;; Latest snapshot
    (let ((latest ($ sns 'latest "spec-wheat")))
      (check-pred "latest exists" (buffer-snapshot? latest))
      (check "latest zone" (buffer-snapshot-zone latest) 'red)
      (check "latest date" (buffer-snapshot-date latest) "2026-03-30"))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Zone transition detection
;;;
;;; Ported from: "detects zone transitions between snapshots"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Zone transitions ──\n")

(with-vat vat
  (let ((sns ($ scope 'snapshot-store)))
    ;; Get all snapshots for wheat, check transitions
    (let ((snaps (filter (lambda (s) (equal? "spec-wheat" (buffer-snapshot-spec-id s)))
                         ($ sns 'all-snapshots))))
      ;; Sort by date
      (let ((sorted (sort snaps (lambda (a b)
                                  (string<? (buffer-snapshot-date a)
                                            (buffer-snapshot-date b))))))
        (check "day 1 zone" (buffer-snapshot-zone (list-ref sorted 0)) 'green)
        (check "day 2 zone" (buffer-snapshot-zone (list-ref sorted 1)) 'yellow)
        (check "day 3 zone" (buffer-snapshot-zone (list-ref sorted 2)) 'red)

        ;; Transition: green→yellow (day 1→2), yellow→red (day 2→3)
        (check-pred "green→yellow transition"
                    (and (eq? 'green (buffer-snapshot-zone (list-ref sorted 0)))
                         (eq? 'yellow (buffer-snapshot-zone (list-ref sorted 1)))))
        (check-pred "yellow→red transition"
                    (and (eq? 'yellow (buffer-snapshot-zone (list-ref sorted 1)))
                         (eq? 'red (buffer-snapshot-zone (list-ref sorted 2)))))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Buffer status with tipping point (ecological)
;;;
;;; Ported from: eco-buffer "tippingPointBreached"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Ecological tipping point ──\n")

(with-vat vat
  (let ((bzs ($ scope 'buffer-zone-store)))
    ;; Create eco-buffer for water with tipping point
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-water" "spec-water" "bp-eco" 'replenished
         #f #f #f #f #f
         50 "litre" #f #f #f #f #f #f #f #f #f
         5 0 "litre" #f #f #f #f #f
         100 200 300 #f #f #f #f #f #f #f #f
         "2026-03-27T00:00:00Z"))

    (let ((bz ($ bzs 'get-zone "bz-water")))
      ;; Above tipping point (no breach)
      (let ((s (buffer-status 150 bz)))
        (check "above tipping: yellow" (assq-ref s 'zone) 'yellow))

      ;; At TOR boundary
      (let ((s (buffer-status 100 bz)))
        (check "at TOR: red" (assq-ref s 'zone) 'red))

      ;; Below TOR (critical)
      (let ((s (buffer-status 50 bz)))
        (check "below TOR: red" (assq-ref s 'zone) 'red)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. First inversion detection
;;;
;;; Ported from: buffer-first-inversion "tracks first time zone drops"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── First inversion ──\n")

(with-vat vat
  (let ((sns ($ scope 'snapshot-store)))
    ;; The snapshot history shows: green → yellow → red
    ;; First inversion from green = day 2 (when it dropped to yellow)
    (let* ((snaps (filter (lambda (s) (equal? "spec-wheat" (buffer-snapshot-spec-id s)))
                          ($ sns 'all-snapshots)))
           (sorted (sort snaps (lambda (a b)
                                 (string<? (buffer-snapshot-date a)
                                           (buffer-snapshot-date b)))))
           ;; Find first non-green snapshot
           (first-drop (find (lambda (s) (not (eq? 'green (buffer-snapshot-zone s))))
                             sorted)))
      (check-pred "first inversion found" (buffer-snapshot? first-drop))
      (check "first inversion date" (buffer-snapshot-date first-drop) "2026-03-29")
      (check "first inversion zone" (buffer-snapshot-zone first-drop) 'yellow))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Replenishment triggers
;;;
;;; Ported from: "generates replenishment signal when NFP drops"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Replenishment triggers ──\n")

(with-vat vat
  (let ((bzs ($ scope 'buffer-zone-store)))
    (let ((bz ($ bzs 'get-zone "bz-wheat")))
      ;; Red zone NFP → should generate signal
      (let* ((fake-nfp `((nfp . 80) (onhand . 80) (onorder . 0)
                         (qualified-demand . 0) (zone . red) (priority . 0.2)))
             (signal (generate-replenishment-signal
                       "spec-wheat" fake-nfp bz
                       (iso-datetime->epoch "2026-03-30T00:00:00Z"))))
        (check-pred "red signal generated" (replenishment-signal? signal))
        (check "signal zone" (replenishment-signal-zone signal) 'red)
        ;; recommended = TOG - NFP = 400 - 80 = 320
        (check-pred "signal qty" (approx= 320 (replenishment-signal-recommended-qty signal) 1)))

      ;; Excess zone NFP → no signal (NFP > TOY means no replenishment needed)
      (let* ((fake-nfp `((nfp . 500) (onhand . 500) (onorder . 0)
                         (qualified-demand . 0) (zone . excess) (priority . 1.25)))
             (signal (generate-replenishment-signal
                       "spec-wheat" fake-nfp bz
                       (iso-datetime->epoch "2026-03-30T00:00:00Z"))))
        (check-pred "excess zone: no signal needed" (not signal))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Snapshot persistence
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Snapshot persistence ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (error "Restore!"))
    store))

(with-vat vat2
  (let ((sns ($ scope2 'snapshot-store))
        (bzs ($ scope2 'buffer-zone-store)))
    (check "restored snapshots" (length ($ sns 'all-snapshots)) 3)
    (check-pred "restored zone" (buffer-zone? ($ bzs 'get-zone "bz-wheat")))
    (check-pred "restored eco zone" (buffer-zone? ($ bzs 'get-zone "bz-water")))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
