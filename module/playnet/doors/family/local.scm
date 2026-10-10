;;; family-local.scm — the household face's solve, JSON in and JSON out.
;;;
;;; The face holds its week as JSON rows. This module reads them, runs the
;;; planner's own family solve (family.scm) and shapes the reply for the face
;;; (family-wire.scm). The service reads its rows through `family-needs-of-json`;
;;; the page's solve worker (hoot/family-worker.scm) calls `family-split-json`
;;; and `family-bills-json` on the device, so the household's ledger never leaves it.
;;;
;;;   NEEDS-JSON     [{person,what,cost,want,voice,kind,substance?}, …]
;;;   MEMBERS-JSON   [{person,capacity,hours}, …]   (see family-members-of-json)
;;;   reply          the solve's rows as a JSON object, or "err:…"

(define-module (playnet doors family local)
  #:use-module ((playnet doors family solve) #:select (family-split family-bills))
  #:use-module ((playnet doors family wire) #:select (family-split->json-alist family-bills->json-alist))
  #:use-module ((playnet vf facts tension-terms) #:select (kind-string->symbol))
  #:use-module ((playnet utils json-portable) #:select (scm->json-canonical json-read-ordered))
  #:use-module ((playnet utils catch) #:select (catch*))
  #:export (family-needs-of-json family-members-of-json family-split-json family-bills-json))

(define (rows-of json)                 ; a JSON array of objects, as a list of alists
  (let ((v (json-read-ordered json)))
    (if (vector? v) (vector->list v) '())))

(define (family-needs-of-json needs-json)
  "The face's JSON list of {person,what,cost,want,voice,kind,substance?} as
   the family solve's need rows — one parse for family-split and
   family-externalities. SUBSTANCE, present only on a floor row whose right
   is not on the good named but on what it reduces to (docs/rights.md;
   family.scm's need-substance), is appended only when the row carries one —
   an ordinary floor (no substitute form, e.g. medicine) stays a 6-tuple,
   walling its own good exactly as before."
  (map (lambda (n)
         (let ((base (list (assoc-ref n "person") (assoc-ref n "what")
                           (exact->inexact (assoc-ref n "cost"))
                           (exact->inexact (assoc-ref n "want"))
                           (exact->inexact (or (assoc-ref n "voice") 0))
                           (kind-string->symbol (assoc-ref n "kind"))))
               (substance (assoc-ref n "substance")))
           (if (string? substance) (append base (list substance)) base)))
       (rows-of needs-json)))

(define (family-members-of-json members-json)
  "The face's JSON list of {person,capacity,hours} as MEMBERS
   ((person capacity hours) …) for family-voice-of (playnet.typ §The credit
   identity) — CAPACITY a_p ∈ [0,1] (the contribution-capacity factor;
   default 1, full capacity), HOURS the labour contributed to the
   household's own reproduction this period (default 0). Absent or empty
   parses to '() — every owner reads as an equal citizen, unchanged."
  (map (lambda (m)
         (list (assoc-ref m "person")
               (exact->inexact (or (assoc-ref m "capacity") 1))
               (exact->inexact (or (assoc-ref m "hours") 0))))
       (rows-of (or members-json "[]"))))

;; ── the two doors, answered on this device ──────────────────────────────────
(define (refusal key . args)
  (string-append "err:" (symbol->string key)
                 (if (and (pair? args) (string? (car args))) (string-append ": " (car args)) "")))

(define (family-split-json needs-json purse labour-h weighted? members-json per-citizen-hours)
  (catch* #t
    (lambda ()
      (scm->json-canonical
       (family-split->json-alist
        (family-split (family-needs-of-json needs-json) purse
                      #:weighted? weighted? #:labour-h labour-h
                      #:members (family-members-of-json members-json)
                      #:per-citizen-hours per-citizen-hours))))
    refusal))

(define (family-bills-json needs-json purse labour-h weighted? eur-per-hour members-json per-citizen-hours)
  (catch* #t
    (lambda ()
      (scm->json-canonical
       (family-bills->json-alist
        (family-bills (family-needs-of-json needs-json) purse
                      #:weighted? weighted? #:labour-h labour-h #:eur-per-hour eur-per-hour
                      #:members (family-members-of-json members-json)
                      #:per-citizen-hours per-citizen-hours))))
    refusal))
