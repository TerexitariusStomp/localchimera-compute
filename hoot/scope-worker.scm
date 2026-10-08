;;; scope-worker.scm — a scope held on the device, asked by the page.
;;;
;;; With no gateway in reach the page still has books to read and count: a copy
;;; of the scope its person is in, or the demo neighbourhood's. They are a real
;;; scope ((playnet planner doors page-scope): a scope root, its observer and stores,
;;; the planner's own door functions), held here in a worker of its own
;;; (browser/scope-worker.js), so the spine's vat is not held up while a count
;;; lands or a schedule is read.
;;;
;;; The page's calls arrive as strings and leave as one JSON string through a
;;; callback — the same shape as the spine's handlers (hoot/day-boot.scm) and the
;;; household solve's (hoot/family-worker.scm). One handler:
;;;   door NAME ARGS    ask the door NAME of ARGS (a JSON array of strings)
;;; The doors, `open` and `hold` among them, are page-scope's own table.
;;;
;;; Build: make browser/scope.wasm     Check: make check-scope-worker

(use-modules (hoot ffi)
             ((playnet planner doors page-scope) #:select (page-door))
             ((playnet utils json-portable) #:select (json-read-ordered)))

(define-foreign %set-handler "scope" "setHandler" (ref string) (ref extern) -> none)
(define-foreign %call-callback "scope" "callCallback" (ref extern) (ref string) -> none)

(define (str v) (if (string? v) v ""))

(%set-handler "door"
  (procedure->external
   (lambda (name args cb)
     (%call-callback cb (page-door (str name)
                                   (let ((a (json-read-ordered (str args))))
                                     (map str (if (vector? a) (vector->list a) '()))))))))
