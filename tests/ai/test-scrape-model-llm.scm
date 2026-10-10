;;; test-scrape-model-llm.scm — the model recogniser over the HOUSE LLM stack.
;;;
;;; test-scrape-model.scm proved the #:complete seam with a bare mock lambda. This
;;; proves the REAL transport: model-recognise driven through the codebase's own
;;; `llm-completer` → `do-completion` → key-pool `request` protocol (the same wire
;;; envelope the lobby uses), from (playnet ai llm). Only the HTTP endpoint is
;;; mocked — a fake key-pool actor returns a canned chat-completions JSON body — so
;;; nothing hits the network, yet the whole stack above the socket is exercised:
;;;   prompt → do-completion's {model,messages} JSON → key-pool → choices[0]
;;;          .message.content → scrape's parser → demand records → rules @ 'reported.
;;; do-completion is synchronous when the key-pool is reachable IN-VAT, so the
;;; whole extraction runs inside (with-vat vat …). It also checks the loop the
;;; OTHER way (the request carried the instructions + statute) and that a broken
;;; pool degrades to no-records, not a crash.
;;;
;;; Run: guile -L module tests/ai/test-scrape-model-llm.scm

(use-modules (playnet test harness)
             (goblins) (goblins vat) (goblins actor-lib methods)
             (playnet ai llm) (json)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet knowledge law scrape))

(define statute
  (string-append
   "No person shall sell alcohol without first obtaining a Liquor License. "
   "A person who handles food must hold a Food Handler Card."))

;; the model's canned reply (leading prose, to exercise the parser) — a competent
;; extraction that resolves the conditional ban as an OBTAIN.
(define canned-content
  (string-append
   "The obligations are:\n"
   "(((crossing . public-sale) (kind . obtain) (name . \"Liquor License\") (rides . entity)"
   "   (evidence . \"No person shall sell alcohol without first obtaining a Liquor License.\"))\n"
   " ((crossing . food-vending) (kind . obtain) (name . \"Food Handler Card\") (rides . person)"
   "   (evidence . \"A person who handles food must hold a Food Handler Card.\")))"))
;; the OpenAI-compatible envelope do-completion expects: choices[0].message.content
(define canned-json
  (scm->json-string `(("choices" . #((("message" . (("content" . ,canned-content)))))))))

;; a fake key-pool: records the request body, returns the canned JSON. This is the
;; ONLY mock — it stands exactly where the real HTTP POST would be.
(define *last-body* #f)
(define (^mock-pool _bcom)
  (methods ((request path body) (set! *last-body* body) canned-json)))

;;; ─── drive model-recognise through llm-completer + do-completion ──────────
;;; Everything runs INSIDE the vat turn, so do-completion's `$ pool 'request` is a
;;; synchronous near-call and (complete prompt) returns the text directly.
(define vat (spawn-vat))
(define out
  (with-vat vat
    (let* ((pool     (spawn ^mock-pool))                    ; the ONLY mock (stands in for HTTP)
           (complete (llm-completer pool #:system "Extract legal obligations.")))
      (call-with-values
        (lambda () (extract-rules #:jurisdiction "foodville" #:text statute
                     #:recognise (lambda (t) (model-recognise t #:complete complete))
                     #:source "Foodville Code (model via key-pool)" #:as-of "2026-07-19"
                     #:steward "scope:food.foodville"))
        (lambda (rules report)
          (list (model-recognise statute #:complete complete) rules))))))
(define recs  (first out))
(define rules (second out))
(define (rec-named nm) (find (lambda (r) (equal? (assq-ref r 'name) nm)) recs))

(display "\n── model-recognise over the real llm-completer / do-completion / key-pool ──\n")
(format #t "  records: ~s\n" (map (lambda (r) (assq-ref r 'name)) recs))
(check "the real chat-completions envelope round-trips to two demand records" (length recs) 2)
(check "the licence parsed from choices[0].message.content is an obtain (entity)"
       (list (assq-ref (rec-named "Liquor License") 'kind) (assq-ref (rec-named "Liquor License") 'rides))
       '(obtain entity))
(check "the handler card rides a person" (assq-ref (rec-named "Food Handler Card") 'rides) 'person)

;;; ─── the loop the other way: the prompt reached the key-pool as JSON ──────
(display "\n── the request that hit the key-pool carried the prompt (real wire) ──\n")
(define body-scm (json-string->scm *last-body*))
(format #t "  request had model=~s, ~a messages\n"
        (assoc-ref body-scm "model") (vector-length (assoc-ref body-scm "messages")))
(check-pred "do-completion built a well-formed {model, messages} request body"
            (and (assoc-ref body-scm "model") (vector? (assoc-ref body-scm "messages"))))
(check-pred "…and the user message carried the extraction instructions + the statute"
            (and (string-contains *last-body* "legal-compliance extractor")
                 (string-contains *last-body* "sell alcohol")))

;;; ─── same downstream contract: rules @ 'reported, licence fires ───────────
(define sale-rule (find (lambda (r) (equal? (legal-rule-label r) "foodville/public-sale (extracted)")) rules))
(display "\n── the model output builds the same 'reported rules ──\n")
(check-pred "the public-sale rule obtains the Liquor License"
            (and sale-rule (member "Liquor License" (map demand-name (legal-rule-demands sale-rule)))))
(check-pred "every rule is 'reported — the model transport didn't relax the gate"
            (every (lambda (r) (eq? (legal-rule-confidence r) 'reported)) rules))

;;; ─── an empty completion degrades to no records ───────────────────────────
(define empty-json (scm->json-string `(("choices" . #((("message" . (("content" . "")))))))))
(define (^empty-pool _bcom) (methods ((request path body) empty-json)))
(define empty
  (with-vat vat (model-recognise statute #:complete (llm-completer (spawn ^empty-pool)))))
(display "\n── an empty completion → no records, no crash ──\n")
(check "an empty model reply yields no records (graceful, not an exception)" empty '())

(display "\n")
(test-summary!)
