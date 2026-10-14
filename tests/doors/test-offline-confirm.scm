;;; test-offline-confirm.scm — hours and planned rows are confirmed on a device with no gateway, and land once.
;;;
;;; A replica carries what a confirmation reads: the member's own work commitments and the
;;; rows the plan last stated (scope/replica.scm). A device that holds one answers
;;; recordEffort and recordFlow over it with the same functions the gateway answers them with
;;; (doors/effort.scm, doors/record-flow.scm), and each act is named by its press's token, so
;;; the flush that sends it to the gateway lands what the device already landed and nothing
;;; more. Properties:
;;;
;;;   CARRIED   a replica brings the member's open work commitments and the plan's rows, and
;;;             another member's commitment stays at the gateway
;;;   DEVICE    hours and a row confirmed on the device land on its copy, under the token's id
;;;   ONCE      the same acts then sent to the gateway land there once, under the same ids,
;;;             and a second send answers with what stands
;;;   REFUSED   a commitment the copy does not hold, and a row the plan did not state, are
;;;             refused where the person is, in the gateway's words
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/doors/test-offline-confirm.scm

(use-modules (playnet test harness) (playnet test books)
             (playnet vf schemas) ((playnet vf serdes) #:select (vf-deserialize))
             ((playnet vf formulas flows) #:select (make-work-commitment))
             ((playnet observation account) #:select (fulfillment-remaining))
             (playnet doors service) (playnet doors page-scope) (playnet scope replica)
             ((playnet utils json-portable) #:select (json-read-ordered))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define %standing (@@ (playnet doors service) %standing))
(define (cache-solve! sid demand alist)
  ((@ (playnet doors planner solve-cache) cache-solve!) (%standing 'cache) sid demand alist))
(define (ref al k) (let ((p (assoc k al))) (and p (cdr p))))
(define (ask door . args) (page-door door args))
(define (device-onhand id)
  (let* ((snap (json-read-ordered (ask "snapshot")))
         (rs (vector->list (ref (ref snap "inventory") "resources")))
         (r (find (lambda (r) (equal? id (ref r "id"))) rs)))
    (and r (ref r "onhand"))))
(define ROW "mc|consume|water|P|A||2026-10-02")
(define effort-id #f)
(define flow-id #f)

(define-values (vat scope) (fresh-scope))
(define text #f)
(define svc #f)
(define obs #f)
(begin
  (with-vat vat
    (set! obs ($ scope 'observer))
    (set! svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
    ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
    ($ ($ scope 'plan-store) 'add-commitment (make-work-commitment #:id "c-4h" #:provider "ana" #:skill "baking" #:hours 4.0))
    ($ ($ scope 'plan-store) 'add-commitment (make-work-commitment #:id "c-bo" #:provider "bo" #:skill "baking" #:hours 2.0))
    (cache-solve! "org:t" '()
                  `((material . (((id . ,ROW) (action . consume) (conforms-to . "water") (quantity . 10.0)
                                  (at-location . "A") (input-of . "P") (when . "2026-10-02") (note . #f))))))
    (set! text (cdr ($ svc 'scope-replica "org:t" "ana"))))

  (display "\n── CARRIED: what a confirmation reads travels with the scope ──\n")
  (let ((replica (text->replica text)))
    (check "the plan's row comes with it" (length (replica-material replica)) 1)
    (check "…and the member's own commitment, not another's"
           (length (vf-deserialize (assq-ref replica 'commitments))) 1))
  (ask "hold" "org:t" "ana" text)

  (display "\n── DEVICE: hours and a row land on the copy, under the token's id ──\n")
  (let ((r (ask "recordEffort" "org:t" "c-4h" "1.5" "hours" "pressA")))
    (check-pred "1.5 hours of the block are recorded" (string-prefix? "ok:" r))
    (set! effort-id r))
  (check "the same press answers with the event that stands" (ask "recordEffort" "org:t" "c-4h" "1.5" "hours" "pressA") effort-id)
  (let ((r (ask "recordFlow" "org:t" "consume" "water" "4" "10" "A" "2026-10-02" "P" "" ROW "pressB")))
    (check-pred "4 of the 10 are confirmed" (string-prefix? "ok:" r))
    (set! flow-id r))
  (check "the water left the copy once" (device-onhand "w1") 96.0)
  (check "the same press confirms nothing more" (ask "recordFlow" "org:t" "consume" "water" "4" "10" "A" "2026-10-02" "P" "" ROW "pressB") flow-id)
  (check "…and the water is as it was" (device-onhand "w1") 96.0)

  (display "\n── REFUSED: the copy says no where the person is ──\n")
  (check-pred "another member's commitment is the gateway's"
              (string-prefix? "err:" (ask "recordEffort" "org:t" "c-bo" "1" "hours" "pressC")))
  (check-pred "a row the plan did not state is refused"
              (string-prefix? "err:" (ask "recordFlow" "org:t" "consume" "salt" "1" "1" "A" "2026-10-02" "P" "" "mc|no|such" "pressD")))

  (display "\n── ONCE: the flush lands what the device landed, and nothing more ──\n")
  (with-vat vat
    (let ((e ($ svc 'record-effort "org:t" "c-4h" "ana" 1.5 "hours" "pressA"))
          (f ($ svc 'record-flow "org:t" "consume" "water" 4.0 10.0 "A" "2026-10-02" "P" "" ROW "pressB")))
      (check "the gateway names the hours' event as the device did" (string-append "ok:" (cdr e)) effort-id)
      (check "…and the row's" (string-append "ok:" (assq-ref (cdr f) 'event-id)) flow-id))
    (check "the hours stand once at the gateway" (fulfillment-remaining ($ obs 'get-fulfillment "c-4h")) 2.5)
    (check "the water left the gateway once" (onhand-of obs "w1") 96.0)
    (let ((again ($ svc 'record-flow "org:t" "consume" "water" 4.0 10.0 "A" "2026-10-02" "P" "" ROW "pressB")))
      (check "a second send answers with what stands" (assq-ref (cdr again) 'again) #t))
    (check "…and the water is still 96" (onhand-of obs "w1") 96.0)))

(test-summary!)
