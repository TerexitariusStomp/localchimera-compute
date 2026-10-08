;;; test-scrape-model.scm — a MODEL recogniser wired behind extract-rules.
;;;
;;; law/scrape.scm's recogniser is a pluggable seam (#:recognise). This test drops a
;;; MODEL recogniser into it and proves the whole contract still holds — and that
;;; the model reads context the regex can't — while trusting the model no more:
;;;   (1) the transport is injectable (#:complete : prompt → string), so the
;;;       extractor stays pure/offline; a MOCK stands in for a live client here;
;;;   (2) the model resolves a conditional prohibition ("no one may X without
;;;       obtaining Y") as an OBTAIN of Y — where the regex mis-reads a `forbid`;
;;;   (3) same downstream contract: records → rules @ 'reported → fire in the fold;
;;;   (4) robustness: leading prose / junk / a malformed record can't corrupt the
;;;       pack (stripped, dropped, or → no records — never a crash);
;;;   (5) the safety gate is unmoved: model output is 'reported, steward promotes.
;;;
;;; Run: guile -L module tests/planner/test-scrape-model.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format))

(define here (dirname (current-filename)))
(use-modules (playnet planner legal crossings))
(use-modules (playnet planner legal registry))
(use-modules (playnet planner knowledge law scrape))

;; the statute: a CONDITIONAL PROHIBITION (the regex's blind spot) + a competence.
(define statute
  (string-append
   "No person shall sell alcohol without first obtaining a Liquor License. "
   "A person who handles food must hold a Food Handler Card."))

;; a MOCK transport standing in for a live model client. It ignores the prompt and
;; returns a canned reply — with leading prose, to exercise the parser — that a
;; competent model would produce: the conditional ban resolved as an OBTAIN.
(define (mock-complete prompt)
  (string-append
   "Sure — here is the extraction:\n"
   "(((crossing . public-sale) (kind . obtain) (name . \"Liquor License\") (rides . entity)"
   "   (evidence . \"No person shall sell alcohol without first obtaining a Liquor License.\"))\n"
   " ((crossing . food-vending) (kind . obtain) (name . \"Food Handler Card\") (rides . person)"
   "   (evidence . \"A person who handles food must hold a Food Handler Card.\")))"))

;;; ─── (1) the model transport seam ─────────────────────────────────────────
(define recs (model-recognise statute #:complete mock-complete))
(define (rec-named nm) (find (lambda (r) (equal? (assq-ref r 'name) nm)) recs))
(display "\n── (1) a model recogniser, transport injected, prose stripped ──\n")
(format #t "  records: ~a  →  ~s\n" (length recs) (map (lambda (r) (assq-ref r 'name)) recs))
(check "the model reply (leading prose + sexp) parses to two demand records" (length recs) 2)
(check-pred "a transport is required — the network lives at the edge, not in the extractor"
            (catch #t (lambda () (model-recognise statute) #f) (lambda _ #t)))

;;; ─── (2) the model reads context the regex cannot ─────────────────────────
(define regex-first                                     ; what the regex makes of the ban clause
  (let ((clause "No person shall sell alcohol without first obtaining a Liquor License"))
    (assq-ref (car (regex-recognise clause)) 'kind)))
(display "\n── (2) conditional prohibition: regex vs model ──\n")
(format #t "  regex reads \"no one may sell without obtaining\" as: ~a\n" regex-first)
(format #t "  model reads it as: ~a (~s)\n" (assq-ref (rec-named "Liquor License") 'kind)
        (assq-ref (rec-named "Liquor License") 'rides))
(check "the regex mis-reads the conditional ban as a forbid" regex-first 'forbid)
(check "the model resolves it as an OBTAIN of the licence (its context advantage)"
       (assq-ref (rec-named "Liquor License") 'kind) 'obtain)
(check "…riding an entity (a facility door)"
       (assq-ref (rec-named "Liquor License") 'rides) 'entity)
(check "…and the competence card rides a person"
       (assq-ref (rec-named "Food Handler Card") 'rides) 'person)

;;; ─── (3) same downstream contract: records → rules @ 'reported → fold ──────
(define (model-recog t) (model-recognise t #:complete mock-complete))
(define-values (rules report)
  (extract-rules #:jurisdiction "foodville" #:text statute #:recognise model-recog
                 #:source "Foodville Code (model-extracted)" #:as-of "2026-07-16"
                 #:steward "scope:food.foodville"))
(define sale-rule (find (lambda (r) (equal? (legal-rule-label r) "foodville/public-sale (extracted)")) rules))
(display "\n── (3) model records → rules, driving the live legal fold ──\n")
(check-pred "the model output builds the same rule shape (public-sale obtains the licence)"
            (and sale-rule (member "Liquor License" (map demand-name (legal-rule-demands sale-rule)))))
(check-pred "model-extracted rules are 'reported — trusted no more than scraped"
            (every (lambda (r) (eq? (legal-rule-confidence r) 'reported)) rules))
;; save → reload → fire
(define pack (string-append (or (getenv "TMPDIR") "/tmp") "/model-scraped-" (number->string (getpid)) ".sexp"))
(save-rule-pack pack rules)
(define loaded (load-rule-pack pack))
(define (parent-of id) (if (equal? id "foodville") "world" #f))
(define bill
  (call-with-values
    (lambda () (legal-demands (legal-context #:crossings '(public-sale)
                                             #:place-path (jurisdiction-path "foodville" parent-of)
                                             #:act 'activity) #:rules loaded))
    (lambda (bill hits) bill)))
(format #t "  reloaded public-sale obtain-entity: ~s\n" (map demand-name (assq-ref bill 'obtain-entity)))
(check-pred "the reloaded model rule fires: the licence is an obtain at a public-sale door"
            (member "Liquor License" (map demand-name (assq-ref bill 'obtain-entity))))
(check-pred "…and there is NO forbid — the model corrected the regex's false ban"
            (null? (assq-ref bill 'forbid)))

;;; ─── (4) robustness: a bad reply cannot corrupt the pack ──────────────────
(display "\n── (4) a malformed model reply is stripped / dropped, never trusted ──\n")
(check "a junk reply with no S-expression yields no records (no crash)"
       (model-recognise statute #:complete (lambda (p) "I'm sorry, I can't help with that.")) '())
(define mixed
  (model-recognise statute
    #:complete (lambda (p) "(((kind . bogus) (name . \"X\")) ((crossing . public-sale) (kind . pay) (name . \"City Fee\")))")))
(check "a malformed record is dropped; the well-formed one survives" (length mixed) 1)
(check "…and it is the valid pay demand" (assq-ref (car mixed) 'kind) 'pay)

;;; ─── (4b) a malformed reply is asked again with the fault named ───────────
;;; (playnet ai conform): the door quotes the faulty record and the reason back;
;;; a model that reads them returns the corrected record, and nothing is lost.
(display "\n── (4b) healing: the fault is quoted back, the corrected reply lands ──\n")
(define prompts '())
(define (healing-complete prompt)
  (set! prompts (cons prompt prompts))
  (if (string-contains prompt "failed validation")
      "(((crossing . public-sale) (kind . pay) (name . \"City Fee\")))"
      "(((crossing . public-sale) (kind . levy) (name . \"City Fee\")))"))
(define healed (model-recognise statute #:complete healing-complete))
(check "the corrected record lands (nothing dropped)" (length healed) 1)
(check "…as the pay demand" (assq-ref (car healed) 'kind) 'pay)
(check "two calls: the ask and the one re-ask" (length prompts) 2)
(check-pred "the re-ask names the fault in the model's words"
            (string-contains (car prompts) "record 1 has kind levy; kind must be one of obtain pay tell forbid"))
(check "retries 0 keeps the old one-shot behaviour (the bad record is dropped)"
       (model-recognise statute #:complete healing-complete #:retries 0) '())

;;; ─── (4c) the law lint reads the records too ──────────────────────────────
;;; A demand stated twice, or spelled unlike the packs, is a fact the lint
;;; finds before the pack exists — and the fact the model is asked again with.
(display "
── (4c) the law lint's findings are the re-ask's reason ──
")
(use-modules ((playnet planner knowledge law lint) #:select (lint-demand-records))
             ((playnet planner knowledge dsl findings) #:select (finding-kind findings->reason)))
(define twice
  '(((crossing . public-sale) (kind . pay) (name . "City Fee"))
    ((crossing . public-sale) (kind . pay) (name . "city fee"))))
(check "a demand stated twice is one finding"
       (map finding-kind (lint-demand-records twice)) '(duplicate-demand))
(check "a name the packs spell another way is a finding"
       (map finding-kind (lint-demand-records '(((kind . obtain) (name . "food handler card")))
                                              #:known '("Food Handler Card")))
       '(demand-name-spelling))
(check "the packs' own spelling is clean"
       (lint-demand-records '(((kind . obtain) (name . "Food Handler Card"))) #:known '("Food Handler Card")) '())
(define prompts2 '())
(define (dedupe-complete prompt)
  (set! prompts2 (cons prompt prompts2))
  (if (string-contains prompt "failed validation")
      "(((crossing . public-sale) (kind . pay) (name . \"City Fee\")))"
      "(((crossing . public-sale) (kind . pay) (name . \"City Fee\")) ((crossing . public-sale) (kind . pay) (name . \"city fee\")))"))
(define deduped (model-recognise statute #:complete dedupe-complete))
(check "the re-ask lands one record" (length deduped) 1)
(check-pred "…and it named the repeat as a fact"
            (string-contains (car prompts2) "record 2: repeats record 1"))

;;; ─── (5) the steward gate is unmoved ──────────────────────────────────────
(define verified (steward-verify sale-rule "scope:food.foodville"))
(display "\n── (5) a steward still must promote model output to 'verified ──\n")
(check "steward-verify promotes the model-extracted rule to 'verified"
       (list (legal-rule-confidence verified) (legal-rule-steward verified))
       '(verified "scope:food.foodville"))

(display "\n")
(test-summary!)
