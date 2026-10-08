;;; family-wire.scm — the household solve's reply, as the face reads it.
;;;
;;; The face (ui/app/tabs/family.ts) reads the solve back as a JSON object. The
;;; planner answers it in two places — the service, through the session, and the
;;; page's own solve worker (family-local.scm) — and both shape the reply through
;;; these two tables, so the face cannot tell them apart. Plain Scheme with no
;;; planner behind it, so the page's spine (hoot/day-boot.scm), which only relays
;;; the service's answer, can carry it without carrying the planner.

(define-module (playnet planner doors family wire)
  #:use-module ((playnet wire rows) #:select (alist-ref wire-table wire-row*))
  #:export (family-split->json-alist family-bills->json-alist))

(define (or-blank key) (lambda (row ctx) (or (alist-ref row key) "")))
(define (named key default)
  (lambda (row ctx) (let ((v (alist-ref row key))) (if (symbol? v) v default))))
(define (yes-no row ctx) (if (eq? (alist-ref row 'feasible?) #f) "no" "yes"))

;; Shared by the top-level reply and, nested once, by BEST-EFFORT: the same
;; purse's best use anyway when the floors alone are infeasible (never a
;; plan — family.scm's own `feasible?` on that nested alist stays #f-shaped
;; "no", the face reads it as a diagnostic beside the refusal).
(define %family-need-wire
  (wire-table 'family-need #f
    `(("person" person str) ("what" what str)
      ("want" want num) ("got" got num) ("met" met num) ("voice" voice num)
      ("kind" ,(named 'kind "des") str) ("cost" cost num))))
(define %family-split-wire
  (wire-table 'family-split #f
    `(("feasible" ,yes-no str) ("floors" floors num)
      ("needs" needs (rows family-need))
      ("spent" spent num) ("purse" purse num) ("income" income num)
      ("pfandTrips" pfand-trips num) ("labourH" labour-h num)
      ("bestEffort" ,(lambda (v ctx) (let ((be (alist-ref v 'best-effort))) (and (pair? be) be)))
       (omit-false (row family-split))))))
(define (family-split->json-alist v) (wire-row* %family-split-wire v))

;; the week asked backwards (family.scm family-bills): euros and hours beyond
;; the purse and the hours on hand, for rights, then needs, then wants held as
;; walls — three tiers, each net of the residue a solve holding nothing buys.
(define %family-tier-wire
  (wire-table 'family-tier #f
    `(("tier" ,(named 'tier "rights") str) ("eur" eur num) ("hours" hours num)
      ("stepEur" step-eur num) ("stepHours" step-hours num) ("feasible" ,yes-no str))))
(define %family-bills-wire
  (wire-table 'family-bills #f
    '(("tiers" tiers (rows family-tier)) ("eurPerHour" eur-per-hour num)
      ("residueEur" residue-eur num) ("residueHours" residue-hours num))))
(define (family-bills->json-alist v) (wire-row* %family-bills-wire v))
