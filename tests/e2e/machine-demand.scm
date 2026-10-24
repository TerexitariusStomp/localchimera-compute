;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-demand.scm — the paid-intake API translators
;;;
;;; POST /api/demand/<endpoint> with a demand key is the traditional
;;; buyer's door: the key (the book's keyHash, minted by
;;; machine-demand-credit) is the whole credential — no device signature
;;; — and every intake resolves its commune through the desk, debits the
;;; book, and mints a real envelope job. The rules this suite pins: a
;;; missing or unknown key is 401, a wireable endpoint mints (202, never
;;; a fabricated result), the book's balance moves exactly by the rate
;;; card, a short balance is 402, a non-JSON body is 400, the status read
;;; is the borrower's own, and a PUT s3 body becomes a store job.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-demand.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine registry)
             (localchimera machine payers)
             (localchimera boot governance)
             (localchimera doors demand)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (web request) (web response) (web uri)
             (rnrs bytevectors)
             (json)
             (srfi srfi-1)
             (srfi srfi-13))

(define vat (spawn-vat #:name "machine-demand-e2e"))
(define HOME  "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceOperator")
(define KEY   "kh-api-customer-1")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  ;; the session the HTTP layer would spawn for the key — in-test the
  ;; door calls land on the service directly with the person injected
  (define (target object person) person)
  (define (call ref name args)
    (apply $ gov name ref args))

  (define (req path method headers)
    (build-request (string->uri (string-append "http://localhost" path))
                   #:method method
                   #:headers headers
                   #:port (open-input-string "")
                   #:validate-headers? #f))

  (define (demand path method body-string)
    (call-with-values
        (lambda ()
          (handle-demand-request
           (req path method '((authorization . "Bearer kh-api-customer-1")
                              (content-type . (application/json))))
           (if body-string (string->utf8 body-string) (make-bytevector 0))
           #:target target #:call call))
      (lambda (response text)
        (cons (response-code response)
              (and (not (string-null? text)) (json-string->scm text))))))

  (define (demand-nokey path method body-string)
    (call-with-values
        (lambda ()
          (handle-demand-request
           (req path method '())
           (if body-string (string->utf8 body-string) (make-bytevector 0))
           #:target target #:call call))
      (lambda (response text) (cons (response-code response) text))))

  (define (demand-badkey path method body-string)
    (call-with-values
        (lambda ()
          (handle-demand-request
           (req path method '((authorization . "Bearer kh-nobody")))
           (if body-string (string->utf8 body-string) (make-bytevector 0))
           #:target target #:call call))
      (lambda (response text) (cons (response-code response) text))))

  (define (aref a k) (let ((p (assoc k a))) (and p (cdr p))))

  (scenario "the book — the operator mints a customer's key")
  (door-call gov ALICE 'machine-demand-credit HOME KEY 100 "USD" 'name "acme")

  (scenario "admission — the key is the credential")
  (check "no key is a 401"
         (car (demand-nokey "/api/demand/balance" 'GET #f)) 401)
  (check "an unknown key is a 401"
         (car (demand-badkey "/api/demand/balance" 'GET #f)) 401)
  (check "the key reads its own book"
         (let ((r (demand "/api/demand/balance" 'GET #f)))
           (list (car r) (aref (cdr r) "balance")))
         '(200 100))

  (scenario "the wireable intakes — standard shapes mint real jobs")
  (define fetch-r (demand "/api/demand/fetch" 'POST "{\"url\":\"https://example.com/a\"}"))
  (check "a fetch pays out and queues"
         (list (car fetch-r) (aref (cdr fetch-r) "status") (aref (cdr fetch-r) "payer"))
         '(202 "queued" "api-fetch"))
  (define fetch-job (aref (vector-ref (aref (cdr fetch-r) "jobs") 0) "jobId"))
  (check "the fetch job minted an id"
         (string? fetch-job) #t)
  (check "the book moved by the rate card"
         (aref (cdr (demand "/api/demand/balance" 'GET #f)) "balance") 99)

  (define check-r (demand "/api/demand/check" 'POST "{\"url\":\"https://ex.com\",\"vantages\":3}"))
  (check "a check fans out one job per vantage"
         (vector-length (aref (cdr check-r) "jobs")) 3)
  (check "the vantages all queued"
         (car check-r) 202)

  (check "a judge intake queues an exec job"
         (car (demand "/api/demand/judge" 'POST "{\"source_code\":\"print(1)\",\"language_id\":\"python\"}"))
         202)
  (check "an openai-shaped chat intake queues"
         (car (demand "/api/demand/v1/chat/completions" 'POST "{\"model\":\"llama-3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"))
         202)
  (check "an ocr intake queues"
         (car (demand "/api/demand/ocr" 'POST "{\"image\":\"aGk=\"}"))
         202)

  (scenario "the reads — the customer's own status, nobody else's")
  (define job-r (demand (string-append "/api/demand/jobs/" fetch-job) 'GET #f))
  (check "the job reads its state"
         (list (car job-r) (aref (cdr job-r) "state") (aref (cdr job-r) "borrower"))
         `(200 "open" ,KEY))
  (check "the ledger row rides the status read"
         (vector-length (aref (cdr job-r) "ledger")) 1)
  (check "the ledger read lists the customer's rows"
         (let ((r (demand "/api/demand/ledger" 'GET #f)))
           (>= (vector-length (aref (cdr r) "rows")) 6))
         #t)
  (check "a job that isn't the borrower's reads 404"
         (let* ((other (door-call gov ALICE 'machine-submit HOME "swarm-infer"
                                  "member" "deterministic" "in:other"
                                  'envelope `((kind . "exec") (bridgeJobId . "bj-o")
                                              (image . "js:q") (entrypoint . "m")
                                              (inputHash . "in:o") (caps . ())
                                              (network . #f) (params . ()))))
                (r (demand (string-append "/api/demand/jobs/" other) 'GET #f)))
           (car r))
         404)

  (scenario "the honest refusals")
  (check "a non-JSON body is a 400"
         (car (demand "/api/demand/fetch" 'POST "not json{")) 400)
  (check "an unknown endpoint is a 404"
         (car (demand "/api/demand/teleport" 'POST "{}")) 404)
  (check "a fetch without a url is a 400"
         (car (demand "/api/demand/fetch" 'POST "{}")) 400)
  (check "a short balance is a 402"
         (car (demand "/api/demand/loadtest" 'POST "{\"url\":\"https://x\",\"concurrency\":50}"))
         402)
  (check "…and names the shortfall, not a crash"
         (let ((r (demand "/api/demand/loadtest" 'POST "{\"url\":\"https://x\",\"concurrency\":50}")))
           (and (string? (aref (cdr r) "error"))
                (number? (string-contains (aref (cdr r) "error") "insufficient"))))
         #t)
  (check "the s3 put lands a store job"
         (car (demand "/api/demand/s3/backups/dump-1" 'PUT "YWJj"))
         202)
  (check "the book kept moving after the failures"
         (number? (aref (cdr (demand "/api/demand/balance" 'GET #f)) "balance"))
         #t)

  (scenario "the doors behind the api — resolve and job, direct")
  ;; the translator calls these; any other session may too — the key is
  ;; still the whole credential
  (check "a key resolves to its commune and owner"
         (let ((r (door-call gov KEY 'machine-demand-resolve KEY)))
           (list (aref r "commune") (aref r "owner")))
         (list HOME ALICE))
  (check "a key cannot resolve somebody else's"
         (car ($ gov 'machine-demand-resolve KEY "kh-someone-else"))
         'error)
  (check "an unbooked key resolves nothing"
         (car ($ gov 'machine-demand-resolve "kh-unbooked" "kh-unbooked"))
         'error)
  (check "the borrower key reads its own job"
         (let ((r (door-call gov KEY 'machine-demand-job HOME fetch-job)))
           (aref r "state"))
         "open")
  (check "a non-borrower reads error, not the job"
         (car ($ gov 'machine-demand-job "did:keri:DPeeper" HOME fetch-job))
         'error)
  (check "a missing job is an error"
         (car ($ gov 'machine-demand-job KEY HOME "job-nonesuch"))
         'error))
