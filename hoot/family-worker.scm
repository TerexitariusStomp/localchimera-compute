;;; family-worker.scm — the household's solve, run on the device.
;;;
;;; The family face (ui/app/tabs/family.ts) asks a week's question: split this
;;; purse across these needs, or what would the week take. That is a solve over
;;; the household's own ledger, and the planner's family solve is a pure function
;;; of it, so it runs here, in the page, in a worker of its own (browser/family-
;;; worker.js): the ledger never leaves the device, the answer needs no network,
;;; and the spine's vat is not held up for the ~400 ms a solve takes.
;;;
;;; The page's calls arrive as strings and leave as one JSON string through a
;;; callback — the same shape as the spine's handlers (hoot/day-boot.scm).
;;;
;;; Build: make browser/family.wasm     Check: make check-family-worker

(use-modules (hoot ffi) (playnet planner doors family local))

(define-foreign %set-handler "family" "setHandler" (ref string) (ref extern) -> none)
(define-foreign %call-callback "family" "callCallback" (ref extern) (ref string) -> none)

(define (str v) (if (string? v) v ""))
(define (num v) (exact->inexact (if (string? v) (or (string->number v) 0) v)))
(define (flag v) (not (equal? v "false")))

(%set-handler "split"
  (procedure->external
   (lambda (needs purse labour-h weighted members per-citizen-hours cb)
     (%call-callback cb (family-split-json (str needs) (num purse) (num labour-h) (flag weighted)
                                           (str members) (num per-citizen-hours))))))

(%set-handler "bills"
  (procedure->external
   (lambda (needs purse labour-h weighted eur-per-hour members per-citizen-hours cb)
     (%call-callback cb (family-bills-json (str needs) (num purse) (num labour-h) (flag weighted)
                                           (num eur-per-hour) (str members) (num per-citizen-hours))))))
