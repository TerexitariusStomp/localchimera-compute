;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; legal/filings.scm — a filing is a deterministic render PROCESS producing a document
;;; <economic-resource>, content-addressed (SAID); granting it yields the permit
;;; resource compliance.scm then sees as HELD. The whole lifecycle stays in VF.
;;; @defines filings
;;;
;;; Design: docs/legal/legal-compliance-lifecycle.md §5–§7. The "reproducibly"
;;; in the ask is exactly this: `render-filing` is a PURE function
;;;   artifact = f(template@version, canonical-VF-data) ,
;;; so re-running yields a byte-identical document with the same id — "regenerate
;;; every filing as of date D" is a fold, and two parties get the same artifact.
;;; Nothing is hand-typed into a portal and lost.
;;;
;;; The SUBMISSION is the one honest impurity (§7): we build and address the
;;; artifact and record `submitted`/`granted` as VF EconomicEvents, but the
;;; keystroke at the authority's door is a boundary act, not autonomous filing.
;;;
;;; Run the demo:  guile -L module module/playnet/legal/filings.scm

(define-module (playnet legal filings)
  #:use-module ((playnet vf formulas flows) #:select (make-transfer-event))
  #:use-module (ice-9 format)
  #:export (%fl-dir %canon %fnv1a filing-said render-fields
            %make-filing-template filing-template filing-provenance filing-submittable?
            render-filing filing-preview submitted-event grant-event
            *submission-drivers* register-submission-driver! submission-driver-for
            clear-submission-drivers! submit-filing minimize-disclosure
            template-disclose filing-template->sexp sexp->filing-template
            *retention-years* retention-years iso-add-years retain-until
            artifact-expired? drop-event retention-sweep filings-demo
            ;; the record declarations below define these (define-vf-record; check-record-exports holds the list)
            <filing-template> filing-template? filing-template-name filing-template-jurisdiction filing-template-demand-name filing-template-version
            filing-template-render filing-template-fields filing-template-source filing-template-as-of filing-template-confidence filing-template-steward))

(use-modules ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-predicate vf-record-accessor vf-record-constructor vf-record-type-fields)))
;; a type is its name — the same object on both sides of the load seam

(use-modules (srfi srfi-1) (ice-9 format))

(define %fl-dir (or (and=> (current-filename) (lambda (f) (dirname (dirname f)))) "module/playnet"))
(use-modules (playnet vf schemas))

;;; ─── a stable content address (a stand-in for the KERI SAID) ─────────────
;;; A filing is content-addressed so regeneration is verifiable. In production
;;; this is the blake3/CESR SAID of the credential substrate (Technical
;;; appendix); here we compute a dependency-free, deterministic digest of the
;;; canonicalised fields so legal/filings.scm loads without libblake3. Same content ⇒
;;; same address, which is all "reproducible" requires. The "E" prefix marks the
;;; slot a real SAID occupies.
(define (%canon obj)                                   ; a deterministic string form
  (cond ((string? obj) (format #f "~s" obj))
        ((symbol? obj) (symbol->string obj))
        ((number? obj) (number->string obj))
        ((boolean? obj) (if obj "#t" "#f"))
        ((null? obj) "()")
        ((list? obj)                                   ; proper list — sort so order can't drift
         (string-append "(" (string-join (sort (map %canon obj) string<?) " ") ")"))
        ((pair? obj)                                   ; dotted pair (k . v)
         (string-append "(" (%canon (car obj)) " . " (%canon (cdr obj)) ")"))
        (else (format #f "~s" obj))))
(define (%fnv1a str)                                   ; 64-bit FNV-1a, hex
  (let ((h 14695981039346656037) (m 1099511628211) (mask (- (expt 2 64) 1)))
    (string-for-each
     (lambda (ch) (set! h (logand mask (* (logxor h (char->integer ch)) m)))) str)
    (format #f "~16,'0x" h)))
(define (filing-said template-name version fields)
  (string-append "E" (%fnv1a (%canon (list template-name version fields)))))

;;; ─── FilingTemplate : a (demand-name, jurisdiction) → the authority's form ─
;;; `render` maps canonical VF data (an alist) → the form's field alist. Kept as
;;; a plain closure; provenance mirrors a legal rule's (source/as-of/confidence/
;;; steward) so a template replays to reconstruct "what did we file on date D".
;;; A template's field map is DECLARATIVE DATA (mirroring a legal rule's guard
;;; FORM, legal/registry.scm): a list of entries `(form-field source)`, source ∈
;;;   (canonical KEY)               disclose canonical[KEY] (above the floor)
;;;   (canonical KEY floor PSEUD)   KEY is below the pseudonymity floor — never
;;;                                 raw; disclose the stable pseudonym PSEUD (or,
;;;                                 PSEUD #f ⇒ WITHHELD, a disclosure tension)
;;;   (const V)                     a literal form constant
;;; So a template — like a rule — SERIALIZES to disk (a country-pack), and it OWNS
;;; its own disclosure surface (which keys it discloses, which it floors): render
;;; and minimize-disclosure both DERIVE from this one spec, not the caller.
;;; `render-fields` interprets it → (values field-alist withheld-form-fields).
(define (render-fields spec canonical)
  (let loop ((es spec) (fields '()) (withheld '()))
    (if (null? es) (values (reverse fields) (reverse withheld))
        (let* ((e (car es)) (ff (car e)) (src (cadr e)) (tag (car src)))
          (case tag
            ((const) (loop (cdr es) (cons (cons ff (cadr src)) fields) withheld))
            ((canonical)
             (let* ((key     (cadr src))
                    (floored (and (> (length src) 2) (eq? (caddr src) 'floor)))
                    (pseud   (and floored (> (length src) 3) (cadddr src))))
               (cond
                 (floored (if pseud (loop (cdr es) (cons (cons ff pseud) fields) withheld)
                                    (loop (cdr es) fields (cons ff withheld))))
                 (else (let ((v (assq-ref canonical key)))
                         (if v (loop (cdr es) (cons (cons ff v) fields) withheld)
                               (loop (cdr es) fields (cons ff withheld))))))))
            (else (error "unknown filing-template field source" src)))))))

(define-vf-record <filing-template> FilingTemplate
  (name jurisdiction demand-name version render fields source as-of confidence steward))
(define %make-filing-template (vf-record-constructor <filing-template>))
;;; a template is built EITHER from a declarative `#:fields` spec (data, portable)
;;; or — the escape hatch — a bespoke `#:render` closure. `#:fields` derives the
;;; render, so callers get one behaviour either way.
(define* (filing-template name #:key jurisdiction demand-name (version "1")
                          (render #f) (fields #f)
                          (source #f) (as-of #f) (confidence 'reported) (steward #f))
  (%make-filing-template name jurisdiction demand-name version
                         (or render
                             (and fields (lambda (c) (call-with-values
                                                       (lambda () (render-fields fields c))
                                                       (lambda (f w) f))))
                             (lambda (c) c))
                         fields source as-of confidence steward))

;;; the template's PROVENANCE — sourced/dated/graded/stewarded, exactly like a
;;; legal rule's, so a filing replays to "what did we file, from what, on date D".
(define (filing-provenance template)
  `((source     . ,(filing-template-source template))
    (as-of      . ,(filing-template-as-of template))
    (confidence . ,(filing-template-confidence template))
    (steward    . ,(filing-template-steward template))
    (version    . ,(filing-template-version template))))
;; submittable-without-review ⟺ VERIFIED; a reported/uncertain template must be
;; DRY-RUN and reviewed by its steward before it crosses the submission boundary.
(define (filing-submittable? template) (eq? (filing-template-confidence template) 'verified))

;;; ─── render-filing : the deterministic Process (template × data → document) ─
;;; → (values resource fields said). The document is an <economic-resource>
;;; conforming to "filing", its id = SAID, its rendered fields stashed in `note`
;;; (a plain readable sexp), tagged with the template + target demand. Custodied
;;; by the filer (the adapter/scope). Pure: same inputs ⇒ same said + fields.
(define* (render-filing template canonical #:key (filer #f))
  (let* ((fields ((filing-template-render template) canonical))
         (said   (filing-said (filing-template-name template)
                              (filing-template-version template) fields)))
    (values
     (make-economic-resource
      #:id said                                            ; id = the content address
      #:name (filing-template-name template)                 ; name
      #:note (format #f "~s" fields)                          ; note = the rendered form
 #:tracking-identifier said                                          ; image #f, tracking = said
      #:conforms-to "filing"                                         ; conforms-to
      #:classified-as (list "filing"                                   ; classified-as: type + provenance
            (string-append "template:" (filing-template-name template))
            (string-append "for:" (or (filing-template-demand-name template) "?"))
            (string-append "jurisdiction:" (format #f "~a" (filing-template-jurisdiction template)))
            (string-append "confidence:" (format #f "~a" (filing-template-confidence template)))
            (string-append "source:" (format #f "~a" (or (filing-template-source template) "?")))
            (string-append "steward:" (format #f "~a" (or (filing-template-steward template) "?")))) #:onhand-quantity (make-measure 1 "document")                   ; accounting #f, onhand 1
 #:primary-accountable filer #:state "rendered")
     fields said)))

;;; ─── dry-run : preview what WOULD be filed — no side effect, no boundary ───
;;; Render the artifact and hand back everything a steward reviews BEFORE the
;;; `submitted` keystroke: the rendered fields, the content address, the template's
;;; provenance, and whether it is `submittable` (verified) or needs review
;;; (reported/uncertain, with a caveat). Pure — produces NO `submitted` event and
;;; changes nothing. The honest gate in front of the submission boundary (§7).
(define* (filing-preview template canonical #:key (filer #f))
  (call-with-values (lambda () (render-filing template canonical #:filer filer))
    (lambda (resource fields said)
      `((template     . ,(filing-template-name template))
        (jurisdiction . ,(filing-template-jurisdiction template))
        (for          . ,(filing-template-demand-name template))
        (said         . ,said)
        (fields       . ,fields)
        (withheld     . ,(call-with-values (lambda () (template-disclose template canonical))
                           (lambda (f w) w)))     ; keys the template floors and cannot pseudonymize
        (provenance   . ,(filing-provenance template))
        (submittable  . ,(filing-submittable? template))
        (caveat       . ,(if (filing-submittable? template) #f
                             (format #f "template confidence is ~a — review before submitting"
                                     (filing-template-confidence template))))))))

;;; ─── the submission boundary (§7) : record, do not robo-file ─────────────
;;; `submitted-event` — the artifact leaves for the authority (a deliver-service
;;; to the authority agent). This is the door; the keystroke is a human/front
;;; act, this only RECORDS it. `grant-event` closes the loop: the authority
;;; hands back the PERMIT — a transfer that raises the credential resource into
;;; the filer's custody, after which compliance.scm's holding-status reads it as
;;; satisfied. (Positional make-economic-event: id action input-of output-of
;;; resource-inv to-resource-inv conforms-to classified provider receiver …)
(define* (submitted-event id filing-said authority filer stamp #:optional (demand-name #f))
  (make-economic-event
    #:id id #:action 'deliver-service #:resource-inventoried-as filing-said #:resource-conforms-to "filing" #:provider filer #:receiver authority
    #:resource-quantity (make-measure 1 "document") #:has-point-in-time stamp))

;;; the grant: the authority raises the permit credential into the filer's hands.
;;; `permit-spec` is the demand-name (compliance.scm demand->spec-id); the new
;;; resource is what holding-status will find as satisfied.
(define* (grant-event id permit-resource-id permit-spec authority filer stamp)
  (make-transfer-event #:id id #:from permit-resource-id #:spec permit-spec #:provider authority #:receiver filer
                       #:qty 1 #:unit "cert" #:when stamp))

;;; ─── submission drivers : manual by default, automated where an API exists ─
;;; The `submitted` event is ALWAYS the boundary — prepare + record, never
;;; robo-file. Where an authority offers a CLEAN machine API (many tax e-file
;;; systems, some registries), an OPTIONAL driver may automate the keystroke — but
;;; ONLY behind this same event, never load-bearing: absent a driver the filing is
;;; `pending-human` and a front lodges it by hand. A driver is
;;;   (filing-said authority filer stamp demand-name) → outcome,
;;; outcome = ((status . granted|rejected|pending) (credential . <er>|#f)).
(define *submission-drivers* (make-hash-table))
(define (register-submission-driver! authority driver) (hash-set! *submission-drivers* authority driver))
(define (submission-driver-for authority) (hash-ref *submission-drivers* authority #f))
(define (clear-submission-drivers!) (hash-clear! *submission-drivers*))

;; submit a rendered filing: emit the `submitted` boundary event, then EITHER
;; drive it (an API) or leave it `pending-human` (the manual front). →
;; ((submitted . <ev>) (status . …) (credential . <er>|#f) (via . driver|manual)).
(define* (submit-filing #:key filing-said authority filer stamp (demand-name #f)
                        (driver (submission-driver-for authority)))
  (let ((sub (submitted-event (string-append "ev:submit:" (or filing-said "?"))
                              filing-said authority filer stamp demand-name)))
    (if driver
        (let ((outcome (driver filing-said authority filer stamp demand-name)))
          `((submitted  . ,sub)
            (status     . ,(or (assq-ref outcome 'status) 'pending))
            (credential . ,(assq-ref outcome 'credential))
            (via        . driver)))
        `((submitted . ,sub) (status . pending-human) (credential . #f) (via . manual)))))

;;; ─── disclosure minimization + the pseudonymity floor (§13) ───────────────
;;; A filing must carry ONLY the fields its door requires, and NEVER a field
;;; below the pseudonymity floor in the clear — the scope files as ITSELF (a
;;; stable pseudonym), not as the natural people behind it (playnet.typ: identity
;;; is held by key, a mask at the door). `minimize-disclosure` projects canonical
;;; data to the door's `required` keys, substitutes a pseudonym for any required
;;; key that sits below the `floor`, and surfaces as `withheld` any required key
;;; we refuse to disclose raw and have no pseudonym for — a disclosure TENSION the
;;; steward sees, not a silent over-share. → ((disclosed . alist) (withheld . keys)).
;; a thin projection onto render-fields (the SINGLE floor implementation): each
;; required key becomes a same-named field; a floored key carries its pseudonym,
;; or none (⇒ withheld). One flat key-list in, no bespoke form-renaming/constants.
(define* (minimize-disclosure canonical required #:key (floor '()) (pseudonyms '()))
  (call-with-values
    (lambda ()
      (render-fields
       (map (lambda (k) (list k (if (memq k floor)
                                    (list 'canonical k 'floor (assq-ref pseudonyms k))
                                    (list 'canonical k))))
            required)
       canonical))
    (lambda (disclosed withheld) `((disclosed . ,disclosed) (withheld . ,withheld)))))

;; template-disclose : a template's OWN disclosure surface (it declares which keys
;; it discloses and which it floors), so the caller no longer supplies required/
;; floor/pseudonyms — the field-spec is the single source of truth. A bespoke
;; closure template (no #:fields) withholds nothing (it discloses whatever it renders).
;; → (values field-alist withheld-form-fields).
(define (template-disclose template canonical)
  (let ((spec (filing-template-fields template)))
    (if spec (render-fields spec canonical)
        (values ((filing-template-render template) canonical) '()))))

;;; ─── serialization : a declarative template ⇄ S-expression (country-pack) ──
;;; Like a legal rule (legal/registry.scm rule->sexp), a `#:fields` template
;;; round-trips through write/read — the render is DERIVED, so nothing
;;; closure-shaped needs saving. A bespoke-closure template has no portable form;
;;; `->sexp` returns #f for it, naming the one thing that must stay in-code.
;; The sexp is the type's fields in order, less `render` — the one field that is a
;; closure, which `#:fields` derives again on the way back. A field added to the
;; type is carried by the sexp with no edit; a template with no `#:fields` (a
;; bespoke render) has no sexp.
(define %sexp-fields (delq 'render (vf-record-type-fields <filing-template>)))
(define (filing-template->sexp t)
  (and (filing-template-fields t)
       (map (lambda (f) ((vf-record-accessor <filing-template> f) t)) %sexp-fields)))
(define (sexp->filing-template s)
  (apply filing-template (car s)
         (append-map (lambda (f v) (list (symbol->keyword f) v)) (cdr %sexp-fields) (cdr s))))

;;; ─── retention horizon : keep exactly as long as required, then drop (§13) ─
;;; Disclosure minimization across TIME. An artifact is retained only until its
;;; obligation closes plus the statutory keep-period, then dropped — the deletion
;;; is itself a VF EconomicEvent, so "we no longer hold it" is auditable. Windows
;;; are year-granular (statutory retention is stated in years); ISO day-strings
;;; compare lexicographically for the same month/day.
;; Retention is a datum on the RULE (legal/registry.scm: a demand's #:retain),
;; stamped onto the filing at render time — so `retention-sweep` reads each
;; artifact's OWN window and needs no lookup. This table is only a FALLBACK
;; library for filings that carry no stamped window (a default per permit-name).
(define *retention-years*                               ; DEFAULT keep-period, in YEARS
  '(("Sales Tax Return"        . 7)
    ("Food Establishment Permit" . 3)
    ("Vendor Registration"     . 3)))
(define (retention-years demand-name) (or (assoc-ref *retention-years* demand-name) 5))
(define (iso-add-years iso years)                      ; "YYYY-MM-DD…" → year+years
  (string-append (number->string (+ (string->number (substring iso 0 4)) years))
                 (substring iso 4)))
(define (retain-until close-date demand-name) (iso-add-years close-date (retention-years demand-name)))
(define (artifact-expired? retain-until as-of) (string>? as-of retain-until))

;; drop-event : the artifact leaves the books once its horizon passes — a `lower`
;; of the one document (the table's own word for a stock taken off the books by
;; no process), classed "dropped" with the reason — minimization made auditable.
(define* (drop-event id filing-said filer stamp #:optional (reason "retention-horizon"))
  (make-economic-event
    #:id id #:action 'lower #:resource-inventoried-as filing-said #:resource-conforms-to "filing" #:resource-classified-as (list "dropped" reason) #:provider filer
    #:resource-quantity (make-measure 1 "document") #:has-point-in-time stamp))

;; retention-sweep : given held filings — each ((said . …)(demand . …)(closed . iso)) —
;; return those past their horizon as-of, each paired with the drop event that
;; removes it. Keep everything still within its statutory window; drop the rest.
(define* (retention-sweep filings as-of #:key (filer #f))
  (filter-map
   (lambda (f)
     (let* ((said   (assq-ref f 'said))
            (years  (or (assq-ref f 'retain)                       ; the rule's OWN datum (stamped)
                        (retention-years (assq-ref f 'demand))))    ; else the fallback library
            (until  (iso-add-years (assq-ref f 'closed) years)))
       (and (artifact-expired? until as-of)
            `((said . ,said) (retain-until . ,until)
              (drop . ,(drop-event (string-append "ev:drop:" said) said filer as-of))))))
   filings))

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (filings-demo)
  (let* ((tmpl (filing-template "Food Establishment Permit Application"
                 #:jurisdiction 'foodville #:demand-name "Food Establishment Permit"
                 #:version "2026.1"
                 #:render (lambda (c)
                            `((applicant   . ,(assq-ref c 'adapter-name))
                              (site        . ,(assq-ref c 'site))
                              (activity    . "retail food vending")))
                 #:source "foodville Health Code" #:as-of "2026-01-01"
                 #:confidence 'verified #:steward "scope:food.foodville"))
         (canonical '((adapter-name . "FoodCo Commons LLC") (site . "12 Market St")))
         (a (call-with-values (lambda () (render-filing tmpl canonical #:filer "scope:foodco")) list))
         (b (call-with-values (lambda () (render-filing tmpl canonical #:filer "scope:foodco")) list)))
    (format #t "~%legal/filings.scm — a deterministic render Process:~%")
    (format #t "  said       : ~a~%" (caddr a))
    (format #t "  fields     : ~s~%" (cadr a))
    (format #t "  determinism: re-render ⇒ same said? ~a~%" (equal? (caddr a) (caddr b)))
    (format #t "  a tweaked field ⇒ a different said? ~a~%"
            (not (equal? (caddr a)
                         (caddr (call-with-values
                                 (lambda () (render-filing tmpl '((adapter-name . "Other") (site . "x"))
                                                           #:filer "scope:foodco")) list)))))
    (format #t "  submitted → authority, then grant raises the held permit — see~%")
    (format #t "  tests/observation/test-filings.scm for the round-trip into holding-status.~%")))

(when (and (pair? (command-line))
           (string-suffix? "legal/filings.scm" (car (command-line))))
  (filings-demo))
