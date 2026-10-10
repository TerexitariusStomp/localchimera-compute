;;; legal/scrape.scm — the FRONT of the curation pipeline: statute prose → a `reported`
;;; rule-pack (legal/registry.scm), with per-clause evidence for a steward.
;;;
;;; Design: docs/legal/legal-compliance-lifecycle.md §14. "All countries" is a
;;; data-curation pipeline — scrape → grade → steward-verify → sign — not an
;;; engineering push. This file is the SCRAPE stage. It reads legal text and emits
;;; rules at `confidence 'reported` (NEVER 'verified), so the downstream gate
;;; (`filing-submittable?`, the dry-run) refuses autonomous submission until a
;;; human steward reviews the evidence and PROMOTES a rule to 'verified.
;;;
;;; The extractor here is a deterministic, POSIX-regex matcher over statute
;;; clauses — honest, testable, offline. It is the SAME shape a model-based
;;; extractor would take (text → structured (crossing, demand) records); swap the
;;; recogniser, keep the rule-pack + provenance + steward-gate contract. The two
;;; lexicons (`*demand-triggers*`, `*activity-crossings*`) are DATA — extend them
;;; per language/jurisdiction without touching the fold.
;;;
;;; It maps recognised legal signal onto the demand vocabulary:
;;;   "must obtain/hold a …"        → obtain     (rides person iff a competence noun)
;;;   "shall pay/remit a …"         → pay
;;;   "must file/report/disclose …" → tell
;;;   "no person shall / unlawful"  → forbid      (a possibility-tension)
;;; and onto a crossing via activity keywords, then groups per crossing into one
;;; rule guarded by (all-of (in-jurisdiction J) (on-crossing C)).
;;;
;;; Run the demo:  guile -L module module/playnet/knowledge/law/scrape.scm

(define-module (playnet knowledge law scrape)
  #:use-module (playnet knowledge law pack-dir)
  #:use-module (playnet ai conform)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-26)
  #:export (%sc-dir *demand-triggers* *activity-crossings* split-clauses after-trigger
            *name-stops* clean-name short-reason person-competence? detect-crossing
            extract-demands demand-record obtain-rides regex-recognise record->demand
            group-by-crossing records->rule extract-rules extract-and-save
            model-extract-instructions parse-sexp-list
            normalize-model-record model-record-fault model-recognise steward-verify %demo-statute
            scrape-demo))

(use-modules (ice-9 regex) (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define %sc-dir (or (and=> (current-filename) (lambda (f) (dirname (dirname (dirname f))))) "module/playnet"))
(use-modules (playnet legal registry))
(use-modules (playnet legal crossings))
(use-modules ((playnet knowledge law lint) #:select (known-demand-names lint-demand-records))
             ((playnet knowledge dsl findings) #:select (findings->reason)))

;;; ─── lexicon 1 : demand triggers (modal + verb → a demand kind) ───────────
;;; A per-kind (regexp . strength). `forbid` is tried first and SHORT-CIRCUITS a
;;; clause (a prohibition dominates); the others may co-occur in one clause. The
;;; regexps are POSIX-extended (no \b / lookahead) — the name is read as the text
;;; AFTER the trigger (clean-name trims it at the first connective).
(define *demand-triggers*
  (list
   (list 'forbid (make-regexp "no (person|one) (shall|may)|it is unlawful|it shall be unlawful|is prohibited|are prohibited|shall not|may not " regexp/icase) 0.8)
   (list 'obtain (make-regexp "(must|shall|required to) (first )?(obtain|hold|possess|apply for|secure|maintain|be granted|be issued|be licensed)( a| an| the)?" regexp/icase) 0.7)
   (list 'pay    (make-regexp "(must|shall|required to) (pay|remit|collect)( a| an| the)?" regexp/icase) 0.6)
   (list 'tell   (make-regexp "(must|shall|required to) (file|submit|report|disclose|notify|provide notice of)( a| an| the)?" regexp/icase) 0.6)
   ;; what the law OFFERS: an entitlement, a status, a relief the actor may claim
   (list 'grant  (make-regexp "(is|are|shall be) (entitled to|eligible for|exempt from)|may (claim|be granted|apply for)( a| an| the)?" regexp/icase) 0.6)))

;;; ─── lexicon 2 : activity keywords → a crossing symbol ────────────────────
;;; First hit wins, so put the SPECIFIC activity before the generic (food-vending
;;; before public-sale) — "sells food" resolves to food, not bare public-sale.
;;; Unknown crossings default to 'mirrored downstream (legal/crossings.scm), the safe
;;; assumption; a steward can register an annotated one.
(define *activity-crossings*
  '(("food" . food-vending) ("meal" . food-vending) ("restaurant" . food-vending) ("kitchen" . food-vending)
    ("alcohol" . alcohol) ("liquor" . alcohol) ("spirits" . alcohol)
    ("personal data" . data-processing) ("personal information" . data-processing)
    ("building" . built-structure) ("construct" . built-structure) ("structure" . built-structure)
    ("employ" . wage-labour) ("wage" . wage-labour) ("worker" . wage-labour)
    ("vehicle" . public-vehicle)
    ("firearm" . dangerous-thing) ("hazardous" . dangerous-thing) ("controlled substance" . dangerous-thing)
    ("emit" . eco-draw) ("discharge" . eco-draw) ("pollut" . eco-draw)
    ("property" . own-property) ("lease" . own-property)
    ("sell" . public-sale) ("sale" . public-sale) ("retail" . public-sale) ("vend" . public-sale)))

;;; ─── clause splitting + name cleanup ──────────────────────────────────────
(define (split-clauses text)                            ; on . ; and newlines
  (filter (lambda (s) (> (string-length s) 8))          ; drop headings / fragments
          (map string-trim-both
               (append-map (lambda (s) (string-split s #\;))
                           (append-map (lambda (s) (string-split s #\newline))
                                       (string-split text #\.))))))

(define (after-trigger clause m)                        ; text following the matched verb
  (string-trim-both (substring clause (match:end m))))

(define *name-stops*                                    ; a name ends at the first connective
  '(" from " " issued " " prior " " before " " with " " and " " to " " for "
    " unless " " within " " that " " which " " when " " on " " in "))
(define (clean-name s)
  (let* ((s (string-trim-both s)) (low (string-downcase s)))
    (let loop ((stops *name-stops*) (cut (string-length s)))
      (if (null? stops)
          (string-trim-right (substring s 0 cut)
                             (lambda (c) (not (or (char-alphabetic? c) (char-numeric? c)))))
          (let ((i (string-contains low (car stops))))
            (loop (cdr stops) (if (and i (< i cut)) i cut)))))))

(define (short-reason clause)
  (let ((s (string-trim-both clause)))
    (if (> (string-length s) 70) (string-append (substring s 0 70) "…") s)))

;; a competence rides a PERSON iff its name carries a competence noun.
(define (person-competence? name)
  (let ((n (string-downcase name)))
    (or (string-contains n "handler") (string-contains n "card")
        (string-contains n "training") (string-contains n "practitioner")
        (string-contains n "competenc") (string-contains n "certification"))))

;;; ─── recognise one clause → (crossing kind name strength evidence) records ─
(define (detect-crossing clause)
  (let ((c (string-downcase clause)))
    (let loop ((xs *activity-crossings*))
      (cond ((null? xs) #f)
            ((string-contains c (caar xs)) (cdar xs))
            (else (loop (cdr xs)))))))

(define (extract-demands clause)                        ; → list of (kind name strength)
  (let* ((fb (assq 'forbid *demand-triggers*))
         (fbm (regexp-exec (cadr fb) clause)))
    (if fbm
        (list (list 'forbid (short-reason clause) (caddr fb)))    ; a ban — short-circuits
        (filter-map
         (lambda (trig)
           (let ((kind (car trig)) (rx (cadr trig)) (str (caddr trig)))
             (and (not (eq? kind 'forbid))
                  (let ((m (regexp-exec rx clause)))
                    (and m (let ((nm (clean-name (after-trigger clause m))))
                             (and (> (string-length nm) 2) (list kind nm str))))))))
         *demand-triggers*))))

;;; ─── a RECOGNISER : text → demand RECORDS (the pluggable seam) ────────────
;;; A recogniser maps statute text to a flat list of demand RECORDS. The record
;;; SCHEMA lives in exactly one place — this constructor — so both recognisers
;;; (regex here, model below) emit the identical shape and `extract-rules`
;;; consumes it without knowing which produced it. That is what makes "any
;;; recogniser drops in behind `#:recognise`" literally true, not a coincidence.
(define* (demand-record #:key crossing kind name rides (strength 0.7) (evidence ""))
  `((crossing . ,crossing) (kind . ,kind) (name . ,name)
    (rides . ,rides) (strength . ,strength) (evidence . ,evidence)))

;; an obtain rides a PERSON iff a human competence, an ENTITY otherwise; other
;; kinds ride nothing. The ONE place this rule is decided — both recognisers and
;; record->demand defer here.
(define (obtain-rides kind name)
  (and (eq? kind 'obtain) (if (person-competence? name) 'person 'entity)))

(define (regex-recognise text)
  (append-map
   (lambda (clause)
     (let ((cross (detect-crossing clause)))
       (map (lambda (d)
              (let ((kind (car d)) (name (cadr d)) (str (caddr d)))
                (demand-record #:crossing cross #:kind kind #:name name
                               #:rides (obtain-rides kind name)
                               #:strength str #:evidence clause)))
            (extract-demands clause))))
   (split-clauses text)))

;;; ─── assemble records → rules (grouped per crossing) ──────────────────────
(define (record->demand rec)
  (let ((kind (assq-ref rec 'kind)) (name (assq-ref rec 'name)) (rides (assq-ref rec 'rides)))
    (case kind
      ((obtain) (obtain #:rides (or rides (obtain-rides 'obtain name)) #:name name))
      ((pay)    (pay  #:name name))
      ((tell)   (tell #:name name))
      ((forbid) (forbid #:reason name))
      ((grant)  (grant #:name name))
      (else #f))))

(define (group-by-crossing records)                     ; → alist crossing → records
  (let ((tbl (make-hash-table)))
    (for-each (lambda (r) (let ((c (assq-ref r 'crossing)))
                            (hash-set! tbl c (cons r (hash-ref tbl c '())))))
              records)
    (hash-map->list (lambda (k v) (cons k (reverse v))) tbl)))

(define (records->rule jurisdiction cross recs source as-of steward)
  (let ((demands (delete-duplicates (filter-map record->demand recs) demand=?))
        (guard   (if cross (all-of (in-jurisdiction jurisdiction) (on-crossing cross))
                     (in-jurisdiction jurisdiction))))
    (rule guard demands
          #:label (format #f "~a/~a (extracted)" jurisdiction (or cross 'general))
          #:source source #:as-of as-of
          #:confidence 'reported                        ; NEVER auto-verified — a steward promotes
          #:steward steward)))

;;; ─── the public entry : text → (values rules report) ──────────────────────
;;; `rules` are ready for save-rule-pack / load-rule-packs (they load at
;;; 'reported). `report` is the steward's review sheet — every extracted demand
;;; paired with its evidence clause and match strength, so a human sees exactly
;;; what was inferred from what before promoting anything to 'verified.
(define* (extract-rules #:key jurisdiction text (source "(scraped, unverified)")
                        (as-of #f) (steward "scope:legal") (recognise regex-recognise))
  (let* ((records (recognise text))
         (groups  (group-by-crossing records)))
    (values
     (map (lambda (g) (records->rule jurisdiction (car g) (cdr g) source as-of steward)) groups)
     (map (lambda (r) (cons (cons 'jurisdiction jurisdiction) r)) records))))   ; report = records

;; scrape → pack on disk in one step. → (values n-rules report).
(define* (extract-and-save path #:key jurisdiction text
                           (source "(scraped, unverified)") (as-of #f) (steward "scope:legal")
                           (recognise regex-recognise))
  (call-with-values
    (lambda () (extract-rules #:jurisdiction jurisdiction #:text text #:source source
                              #:as-of as-of #:steward steward #:recognise recognise))
    (lambda (rules report) (save-rule-pack path rules) (values (length rules) report))))

;;; ─── the MODEL recogniser : same seam, a model does the reading ───────────
;;; Drops in behind `#:recognise` exactly where `regex-recognise` sits, so it
;;; inherits the whole contract — records → rules → pack → 'reported → steward.
;;; A model reads context the regex can't (it resolves "no X without obtaining Y"
;;; as an OBTAIN, not a bare forbid), yet is trusted no more: its output still
;;; lands at 'reported with per-record evidence for a steward to promote.
;;;
;;; The model TRANSPORT is itself injectable (`#:complete : prompt → string`), so
;;; the network lives at the edge and the extractor stays pure + testable (a mock
;;; transport in tests). For a REAL client, use the house LLM stack — do not
;;; hand-roll an HTTP/CLI shim: `(playnet ai llm)` gives `llm-completer key-pool`,
;;; which curries onto `do-completion` and reuses the key-pool's provider
;;; selection, rotation, health and private nano-gpt provider `(playnet ai key-pool)`.
;;; Per that module's contract the key-pool must be reachable in-vat, so run the
;;; extraction inside the pool's vat:
;;;   (with-vat pool-vat
;;;     (extract-rules … #:recognise (lambda (t)
;;;       (model-recognise t #:complete (llm-completer key-pool #:model m)))))
(define (%symbols->words syms) (string-join (map symbol->string syms) " "))
(define (model-extract-instructions)
  "The extraction prompt, built at call time: the kinds are the registry's
   (%demand-kinds) and the crossings are the catalogue's (all-crossings), so a
   crossing a steward registers is offered to the model on the next call."
  (string-append
   "You are a legal-compliance extractor. From the statute below, extract EVERY "
   "obligation it places on an activity. Respond with ONLY a Scheme list of records "
   "— no prose, no code fences. Each record is an alist:\n"
   "  ((crossing . C) (kind . K) (name . \"N\") (rides . R) (evidence . \"CLAUSE\"))\n"
   "K is one of " (%symbols->words %demand-kinds) ". R is entity or person for an obtain "
   "(person iff a human competence, e.g. a handler card), #f otherwise. C is a "
   "crossing symbol (" (%symbols->words (all-crossings)) ") or #f. N is "
   "the permit/tax/report name, or a short reason for a forbid. CLAUSE is the exact "
   "sentence. Resolve a conditional prohibition (\"no one may X without a Y\") as an "
   "obtain of Y, not a forbid. Statute:\n\n"))

;; parse the model's reply: the first S-expression, prose and fences skipped
;; (playnet ai conform's reader); anything that is not a list reads as none.
(define (parse-sexp-list raw)
  (let ((v (read-first-sexp raw))) (if (list? v) v '())))

;; validate + coerce ONE model record; #f (dropped) if it isn't a well-formed
;; demand — a bad extraction can't smuggle a malformed rule into the pack.
(define (model-record-fault r)
  "Why record R is not a demand, as one clause the model can act on; #f when it
   is well-formed. The single source of the shape normalize-model-record coerces.
   The kinds are the registry's and the crossings the catalogue's: the same two
   lists the prompt offered."
  (cond
   ((not (and (list? r) (pair? r) (every pair? r)))
    "is not an alist of (key . value) pairs")
   ((not (memq (assq-ref r 'kind) %demand-kinds))
    (format #f "has kind ~s; kind must be one of ~a" (assq-ref r 'kind)
            (%symbols->words %demand-kinds)))
   ((let ((c (assq-ref r 'crossing))) (and c (not (known-crossing? c))))
    (format #f "has crossing ~s; crossing must be one of ~a, or #f"
            (assq-ref r 'crossing) (%symbols->words (all-crossings))))
   ((not (let ((n (assq-ref r 'name))) (and (string? n) (> (string-length (string-trim-both n)) 0))))
    "needs a non-empty string name")
   (else #f)))
(define (normalize-model-record r default-strength)
  (and (not (model-record-fault r))
       (let ((c  (assq-ref r 'crossing))
             (rd (assq-ref r 'rides))
             (e  (assq-ref r 'evidence)))
         (demand-record
          #:crossing (and (symbol? c) c)
          #:kind     (assq-ref r 'kind)
          #:name     (string-trim-both (assq-ref r 'name))
          #:rides    (and (memq rd '(entity person)) rd)
          #:strength (or (assq-ref r 'strength) default-strength)
          #:evidence (if (string? e) e "")))))

;; the demand names the tree's packs already spell, read once: the law lint
;; compares a model's names against them (docs/legal/contexts)
(define %known-demand-names
  (let ((names #f))
    (lambda ()
      (or names
          (begin (set! names (catch #t
                               (lambda () (known-demand-names %contexts-dir))
                               (lambda _ '())))
                 names)))))

;; every fault in a reply, numbered, as the re-ask's validation errors; #f when
;; the whole list conforms. Two readers of the records: each record's own shape
;; (model-record-fault), and the law lint over the list — a demand stated
;; twice, a name the packs spell another way — as the facts it found.
(define (%records-fault records)
  (let* ((faults (filter-map
                  (lambda (r i) (let ((f (model-record-fault r)))
                                  (and f (format #f "- record ~a ~a" (+ i 1) f))))
                  records (iota (length records))))
         (lint (and (null? faults)
                    (findings->reason (lint-demand-records records #:known (%known-demand-names))))))
    (cond ((pair? faults) (string-join faults "\n"))
          (lint lint)
          (else #f))))

;; model-recognise : a recogniser (text → records) backed by a model transport.
;; One door (playnet ai conform): a reply with a malformed record is asked again
;; with the faults quoted back, RETRIES times; the floor then keeps the
;; well-formed records of the last reply and drops the rest, so a bad
;; extraction can never corrupt the pack and a good one is never lost.
(define* (model-recognise text #:key complete (strength 0.75)
                          (retries %conform-default-retries))
  (unless (procedure? complete)
    (error "model-recognise: supply a #:complete transport (prompt -> string)"))
  (define (normalize records)
    (filter-map (lambda (r) (normalize-model-record r strength)) records))
  (conform complete (string-append (model-extract-instructions) text)
           #:read   (lambda (raw) (let ((v (read-first-sexp raw))) (and (list? v) v)))
           #:check  %records-fault
           #:accept normalize
           #:floor  (lambda (last) (normalize (or last '())))
           #:retries retries))

;;; ─── the human-in-the-loop gate : steward review PROMOTES to 'verified ─────
;;; The one act the machine cannot do. A steward reads the report, confirms the
;;; extraction, and re-issues the rule at 'verified under their own scope — after
;;; which the filings dry-run (filing-submittable?) will let it cross the
;;; `submitted` boundary. Nothing scraped is ever auto-trusted.
(define (steward-verify r steward)
  (rule (legal-rule-guard-form r) (legal-rule-demands r)
        #:label (legal-rule-label r) #:source (legal-rule-source r)
        #:as-of (legal-rule-as-of r) #:confidence 'verified #:steward steward))

;;; ─── demo (only when run as a script) ─────────────────────────────────────
(define %demo-statute
  (string-append
   "Section 4. Any person who operates a food establishment or sells food to the "
   "public must obtain a Food Establishment Permit from the health department "
   "before commencing operations. Each individual who handles food must hold a "
   "Food Handler Card. The operator shall pay an annual food facility fee. The "
   "establishment must file a monthly sales tax return with the treasurer. "
   "Section 12. No person shall sell raw milk to the public."))

(define (scrape-demo)
  (call-with-values
    (lambda () (extract-rules #:jurisdiction "foodville" #:text %demo-statute
                              #:source "Foodville Municipal Code (scraped)" #:as-of "2026-07-16"
                              #:steward "scope:food.foodville"))
    (lambda (rules report)
      (format #t "~%legal/scrape.scm — statute prose → a 'reported rule-pack:~%~%")
      (for-each (lambda (r)
                  (format #t "  ~a  [~a]~%" (legal-rule-label r) (legal-rule-confidence r))
                  (for-each (lambda (d)
                              (format #t "      ~a ~s~a~%" (demand-kind d) (demand-name d)
                                      (if (eq? (demand-kind d) 'obtain)
                                          (format #f " (rides ~a)" (demand-rides d)) "")))
                            (legal-rule-demands r)))
                rules)
      (format #t "~%  evidence sheet for the steward (~a extracted demands):~%" (length report))
      (for-each (lambda (e)
                  (format #t "    ~a ~s ← \"~a…\"~%" (assq-ref e 'kind) (assq-ref e 'name)
                          (substring (assq-ref e 'evidence) 0
                                     (min 44 (string-length (assq-ref e 'evidence))))))
                report)
      (format #t "~%  NOTHING is 'verified — a steward promotes after review (steward-verify).~%")
      (format #t "  see tests/knowledge/test-scrape-extractor.scm for the full pipeline.~%"))))

(when (and (pair? (command-line))
           (string-suffix? "legal/scrape.scm" (car (command-line))))
  (scrape-demo))
