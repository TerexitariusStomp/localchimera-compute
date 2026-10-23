;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/doors/test-see-door.scm — a picture, read at the seat, and the
;;; week's allotment of reads (docs/observation/capture.md §5, §9).
;;;
;;; What this pins:
;;;   • a picture crosses in parts and is read whole, several pictures of one
;;;     thing as one read, each part and the whole within its bound;
;;;   • a read takes the pictures out: the session holds them no longer;
;;;   • an unplanned read spends one of the week's, a read the model did not
;;;     answer is given back, and a week with none left reads nothing and
;;;     says so;
;;;   • a read that fulfils a count the plan asked of this person draws on
;;;     the plan and spends nothing, and a commitment that is not this
;;;     person's count is an unplanned read;
;;;   • with no service the door answers "", and the anonymous lobby has no
;;;     such door;
;;;   • the service reads with an enclave model or not at all, and sends the
;;;     pictures as image parts beside the text.
;;;
;;; Run: tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/doors/test-see-door.scm

(add-to-load-path "module")

;; this person's files live in a directory of the test's own, and the service
;; reads with an enclave model; both are read when the modules load, which a
;; compile of this file does at expansion, so the environment is set then too
(eval-when (expand load eval)
  (define %dir (string-append (or (getenv "TMPDIR") "/tmp") "/playnet-see-test-"
                              (number->string (getpid))))
  (setenv "PLAYNET_DATA_DIR" %dir)
  (setenv "PLAYNET_PHOTO_ALLOTMENT" "3")
  (setenv "API_VISION_MODEL" "TEE/test-vision"))

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet gateway evidence)
             (playnet gateway llm-service)
             (playnet gateway allotment)
             ((playnet wire rows) #:select (plain-reply))
             ((playnet utils clock) #:select (civil->epoch))
             (goblins) (goblins vat) (goblins actor-lib methods)
             (goblins actor-lib on)
             (ice-9 textual-ports) (ice-9 regex)
             (srfi srfi-1))

(define vat (spawn-vat))
(define %alice "EAliceSeeDoorTestAID0000000000000000000000000")
(define %bob   "EBobSeeDoorTestAID000000000000000000000000000")

(define %seen '())                                  ; newest first
(define %answer "[{\"name\":\"plum jam\",\"qty\":12,\"unit\":\"each\"}]")
(define (^fake-ai bcom)
  (methods
   ((see system user images)
    (set! %seen (cons (list system user images) %seen))
    %answer)
   ((sees?) #t)
   ((complete sys user model) "done")))
(define ai (with-vat vat (spawn ^fake-ai)))

;; a planner that knows one count: alice's
(define (^fake-planner bcom)
  (methods
   ((count-commitment-of scope-id agent cid)
    (cons 'ok (and (equal? cid "cmt-count-1") (equal? agent %alice))))))
(define planner (with-vat vat (spawn ^fake-planner)))

(define* (spawn-session who ai-svc #:optional (planner-svc planner))
  (with-vat vat
    (spawn ^lobby-session who
           #f #f #f #f
           #f #f #f #f #f #f planner-svc
           'device #f #f ai-svc)))

(define (ask session . msg)
  (let ((answer 'unsettled))
    (with-vat vat
      (on (apply $ session msg)
          (lambda (v) (set! answer v))
          #:catch (lambda (e) (set! answer (list 'broken e)))))
    (let wait ((n 0))
      (when (and (eq? answer 'unsettled) (< n 100))
        (usleep 20000)
        (wait (+ n 1))))
    answer))

(define (ok? r) (and (pair? r) (eq? (car r) 'ok)))
(define (err r) (and (pair? r) (eq? (car r) 'error) (cdr r)))
(define (allotment session) (cdr (plain-reply (ask session 'allotment))))
(define (remaining session) (assq-ref (allotment session) 'remaining))
(define (send! session upload index . parts)
  (map (lambda (p) (ask session 'see-part upload index p)) parts))

(display "\n── 1. a picture crosses in parts ──\n")

(define seat (spawn-session %alice ai))
(check "the week opens whole" (remaining seat) 3)
(check-pred "the allotment says a picture can be read here"
            (assq-ref (allotment seat) 'sees))
(check "…and of how many" (assq-ref (allotment seat) 'per-week) 3)
(check-pred "…and when the next week opens, a Monday midnight, as an instant the page reads"
            (let* ((o (assq-ref (allotment seat) 'opens))
                   (u (and (string? o) (civil->epoch o))))
              (and u (= u (week-opens (allotment-week u))))))

(define sent (send! seat "up-1" 0 "AAAA" "BBBB" "CC"))
(check-pred "every part is taken" (every ok? sent))
(check "the session says how much it holds" (cdr (last sent)) 10)

(define text (ask seat 'see "up-1" "look for stock" "a pantry shelf"))
(check "the read answers with the model's text" text %answer)
(check "the picture reached the model whole, its parts in order"
       (caddr (car %seen)) '("AAAABBBBCC"))
(check "…with what to look for" (car (car %seen)) "look for stock")
(check "…and what the asker knows" (cadr (car %seen)) "a pantry shelf")
(check "the read took the picture out"
       (ask seat 'see "up-1" "s" "u") "err:no picture arrived")

(send! seat "up-2" 0 "FACE")
(send! seat "up-2" 1 "PLA" "TE")
(ask seat 'see "up-2" "s" "u")
(check "several pictures of one thing are one read, each whole"
       (caddr (car %seen)) '("FACE" "PLATE"))

(display "\n── 2. the bounds ──\n")

(check-pred "a part is sixteen kilobytes at the most"
            (err (ask seat 'see-part "up-3" 0 (make-string 16385 #\A))))
(check-pred "a part of sixteen kilobytes is taken"
            (ok? (ask seat 'see-part "up-3" 0 (make-string 16384 #\A))))
(check-pred "a read takes four pictures at the most"
            (err (ask seat 'see-part "up-3" 4 "AAAA")))
(check-pred "…the last of them is taken"
            (ok? (ask seat 'see-part "up-3" 3 "AAAA")))
(check "the door's words follow its bound"
       (cdr (ask seat 'see-part "up-3" %pictures-per-read "AAAA")) "a read takes 4 pictures at the most")
(check-pred "a part is something" (err (ask seat 'see-part "up-3" 0 "")))
(check-pred "a picture is sent under a name" (err (ask seat 'see-part "" 0 "AAAA")))
(define flood
  (let loop ((i 0) (last-reply #f))
    (if (or (> i 80) (err last-reply))
        last-reply
        (loop (+ i 1) (ask seat 'see-part "up-4" 0 (make-string 16384 #\A))))))
(check-pred "pictures past the whole's bound are refused" (err flood))
(check "…and the session lets go of what it held"
       (ask seat 'see "up-4" "s" "u") "err:no picture arrived")

;; the bridge sends each part under the bound the gateway takes
(define bridge-part-chars
  (let* ((src (call-with-input-file "hoot/day-boot.scm" get-string-all))
         (m   (string-match "\\(define %picture-send-chars ([0-9]+)\\)" src)))
    (and m (string->number (match:substring m 1)))))
(check-pred "the bridge's part is a figure under the gateway's bound"
            (and bridge-part-chars (< 0 bridge-part-chars) (<= bridge-part-chars %part-chars)))

;; the page takes as many shots of a scene as the gateway takes pictures of one
(define page-shots
  (let* ((src (call-with-input-file "ui/app/photo.ts" get-string-all))
         (m   (string-match "SHOTS_PER_READ = ([0-9]+)" src)))
    (and m (string->number (match:substring m 1)))))
(check "the page's shots to a read are the gateway's pictures to a read" page-shots %pictures-per-read)

(display "\n── 3. the week's reads ──\n")

;; two reads are spent above; a read of nothing spends nothing
(check "two reads have spent two of the week's three" (remaining seat) 1)

(set! %answer "")
(send! seat "up-5" 0 "AAAA")
(check "a read the model did not answer comes back empty"
       (ask seat 'see "up-5" "s" "u") "")
(check "…and is given back" (remaining seat) 1)

(set! %answer "[]")
(send! seat "up-6" 0 "AAAA")
(ask seat 'see "up-6" "s" "u")
(check "the week's last read leaves none" (remaining seat) 0)

(set! %seen '())
(send! seat "up-7" 0 "AAAA")
(define spent (ask seat 'see "up-7" "s" "u"))
(check-pred "a week with none left says so"
            (and (string? spent) (string-prefix? "err:" spent)
                 (string-contains spent "spent")))
(check "…and the model is not asked" %seen '())

(check "a new seat of the same person finds the same week"
       (remaining (spawn-session %alice ai)) 0)
(check "another person has their own week" (remaining (spawn-session %bob ai)) 3)

(display "\n── 4. a count the plan asked for ──\n")

(set! %seen '())
(send! seat "up-8" 0 "AAAA")
(check "a read that fulfils this person's planned count is read, the week spent or not"
       (ask seat 'see "up-8" "s" "u" "org:commune" "cmt-count-1") "[]")
(check "…and the model was asked" (length %seen) 1)
(check "…and the week is as it was" (remaining seat) 0)

(define bob (spawn-session %bob ai))
(send! bob "up-9" 0 "AAAA")
(ask bob 'see "up-9" "s" "u" "org:commune" "cmt-count-1")
(check "a count that is another's is an unplanned read" (remaining bob) 2)
(send! bob "up-10" 0 "AAAA")
(ask bob 'see "up-10" "s" "u" "org:commune" "cmt-none")
(check "a commitment the plan does not hold is an unplanned read" (remaining bob) 1)

(define unplanned (spawn-session "ECarolSeeDoorTestAID00000000000000000000000" ai #f))
(send! unplanned "up-11" 0 "AAAA")
(ask unplanned 'see "up-11" "s" "u" "org:commune" "cmt-count-1")
(check "with no planner to ask, a read is unplanned" (remaining unplanned) 2)

(display "\n── 5. no service, no seat ──\n")

(define unwired (spawn-session "EDaveSeeDoorTestAID000000000000000000000000" #f))
(send! unwired "up-12" 0 "AAAA")
(check "with no service the door answers \"\""
       (ask unwired 'see "up-12" "s" "u") "")
(check "…and spends nothing" (remaining unwired) 3)
(check-pred "…and says no picture can be read here"
            (not (assq-ref (allotment unwired) 'sees)))

(define lobby (with-vat vat (spawn ^lobby #f ai #f #f #f #f #f #f)))
(check "see is not the anonymous lobby's"
       (raises? (lambda () (ask lobby 'see "up-1" "s" "u"))))
(check "see-part is not the anonymous lobby's"
       (raises? (lambda () (ask lobby 'see-part "up-1" 0 "AAAA"))))

(display "\n── 6. the service ──\n")

(define %sent '())
(define (^fake-pool bcom)
  (methods
   ((request path body) (set! %sent (cons body %sent))
    "{\"choices\":[{\"message\":{\"content\":\"three jars\"}}],\"id\":\"r1\"}")))
(define pool-vat (spawn-vat))
(define pool (with-vat pool-vat (spawn ^fake-pool)))
(define svc (with-vat vat (spawn ^ai-service pool-vat pool)))

(check "the service answers with what the model saw"
       (ask svc 'see "look" "a shelf" '("QUJD" "REVG")) "three jars")
(define body (car %sent))
(check-pred "it reads with the enclave model named for pictures"
            (string-contains body "\"model\":\"TEE/test-vision\""))
(check-pred "the text rides beside the pictures"
            (and (string-contains body "\"type\":\"text\"")
                 (string-contains body "a shelf")))
(check "each picture is an image part"
       (let loop ((i 0) (n 0))
         (let ((at (string-contains body "\"type\":\"image_url\"" i)))
           (if at (loop (+ at 1) (+ n 1)) n)))
       2)
(check-pred "…carried as a data address"
            (and (string-contains body "data:image/jpeg;base64,QUJD")
                 (string-contains body "data:image/jpeg;base64,REVG")))
(check-pred "the read carries the token cap" (string-contains body "\"max_tokens\":"))
(check-pred "the service says it can read pictures" (ask svc 'sees?))
(check-pred "a service with no keys cannot"
            (not (ask (with-vat vat (spawn ^ai-service pool-vat #f)) 'sees?)))
(check "…and answers \"\""
       (ask (with-vat vat (spawn ^ai-service pool-vat #f)) 'see "s" "u" '("QUJD")) "")

;; the test's own directory, and what it held
(for-each (lambda (f) (false-if-exception (delete-file (string-append %dir "/" f))))
          (or (false-if-exception
               (filter (lambda (f) (not (member f '("." ".."))))
                       ((@ (ice-9 ftw) scandir) %dir)))
              '()))
(false-if-exception (rmdir %dir))

(test-summary!)
