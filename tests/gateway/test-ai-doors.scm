;;; tests/gateway/test-ai-doors.scm — the AI the commons pays for is asked from a seat
;;;
;;; What this pins:
;;;   • the anonymous lobby has no transcribe / express / ai-complete door;
;;;   • a session answers them through the AI service, and answers "" with
;;;     no service wired (the browser's cue to work on-device);
;;;   • each session has a per-minute budget across the three; past it the
;;;     answer is "" and the service is not asked;
;;;   • the AI service runs an enclave (TEE/…) model as named and any other
;;;     named model as its default.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-ai-doors.scm

(use-modules (playnet test harness)
             (playnet gateway lobby)
             (playnet gateway services)
             (playnet ai llm)
             (goblins) (goblins vat) (goblins actor-lib methods)
             (goblins actor-lib on))

(define vat (spawn-vat))
(define %alice "EAliceAiDoorsTestAID000000000000000000000000")

(define %asked '())                                 ; newest first
(define (^fake-ai bcom)
  (methods
   ((transcribe b64) (set! %asked (cons `(transcribe ,b64) %asked)) "heard")
   ((express text)   (set! %asked (cons `(express ,text) %asked)) "(expressed)")
   ((complete sys user model)
    (set! %asked (cons `(complete ,model) %asked)) "done")))

(define ai (with-vat vat (spawn ^fake-ai)))

(define (spawn-session ai-svc)
  (with-vat vat
    (spawn ^lobby-session %alice
           #f #f #f #f              ; terminal, mailbox, governance, signup-agent
           #f #f #f #f #f #f #f     ; oobi-host, acdc-store, folksonomy, presence, push, registry, planner
           'device #f #f ai-svc)))

;; A session's AI door answers with the service's promise; the wire settles
;; it for a browser, and this settles it here.
(define (ask session . msg)
  (let ((answer 'unsettled))
    (with-vat vat
      (on (apply $ session msg)
          (lambda (v) (set! answer v))
          #:catch (lambda (e) (set! answer (list 'broken e)))))
    (let wait ((n 0))
      (when (and (eq? answer 'unsettled) (< n 50))
        (usleep 20000)
        (wait (+ n 1))))
    answer))

(display "\n── 1. the lobby has no AI door ──\n")

(define lobby (with-vat vat (spawn ^lobby #f ai #f #f #f #f #f #f)))
(check "ai-complete is not the anonymous lobby's"
       (raises? (lambda () (ask lobby 'ai-complete "s" "u" #f))))
(check "transcribe is not the anonymous lobby's"
       (raises? (lambda () (ask lobby 'transcribe "AAAA"))))

(display "\n── 2. a seat asks the service ──\n")

(define seated (spawn-session ai))
(check "a session transcribes through the service"
       (equal? "heard" (ask seated 'transcribe "AAAA")))
(check "a session expresses through the service"
       (equal? "(expressed)" (ask seated 'express "make bread")))
(check "a session completes through the service"
       (equal? "done" (ask seated 'ai-complete "sys" "user" #f)))
(check "the model the seat names reaches the service"
       (and (equal? "done" (ask seated 'ai-complete "sys" "user" "TEE/other"))
            (equal? '(complete "TEE/other") (car %asked))))

(define unwired (spawn-session #f))
(check "with no service, a session answers \"\" — on-device is the fallback"
       (and (equal? "" (ask unwired 'transcribe "AAAA"))
            (equal? "" (ask unwired 'ai-complete "s" "u" #f))))

(display "\n── 3. the budget ──\n")

(set! %asked '())
(define budgeted (spawn-session ai))
(let loop ((i 0))
  (when (< i 20)
    (ask budgeted 'ai-complete "s" "u" #f)
    (loop (+ i 1))))
(check "twenty calls in a minute reach the service" (= 20 (length %asked)))
(check "the twenty-first is answered \"\" and the service is not asked"
       (and (equal? "" (ask budgeted 'transcribe "AAAA"))
            (= 20 (length %asked))))
(check "another seat has its own minute"
       (equal? "done" (ask (spawn-session ai) 'ai-complete "s" "u" #f)))

(display "\n── 4. the service pins the model ──\n")

(define %sent '())
(define (^fake-pool bcom)
  (methods
   ((request path body) (set! %sent (cons body %sent))
    "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"id\":\"r1\"}")))
(define pool-vat (spawn-vat))
(define pool (with-vat pool-vat (spawn ^fake-pool)))
(define svc (with-vat vat (spawn ^ai-service pool-vat pool)))

(define (model-sent) (let ((body (car %sent)))
                       (and (string-contains body "\"model\":\"")
                            (let* ((start (+ 9 (string-contains body "\"model\":\"")))
                                   (end (string-index body #\" start)))
                              (substring body start end)))))
(ask svc 'complete "s" "u" #f)
(check "no model named: the default" (equal? %default-completion-model (model-sent)))
(ask svc 'complete "s" "u" "TEE/llama-3.3-70b-instruct")
(check "an enclave slug runs as named" (equal? "TEE/llama-3.3-70b-instruct" (model-sent)))
(ask svc 'complete "s" "u" "gpt-5-pro")
(check "any other slug runs as the default" (equal? %default-completion-model (model-sent)))
(check "every completion carries the token cap"
       (string-contains (car %sent) "\"max_tokens\":"))

(test-summary!)
