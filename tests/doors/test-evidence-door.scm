;;; tests/doors/test-evidence-door.scm — a counter's picture, held for the
;;; contest of their count (docs/observation/capture.md §8).
;;;
;;; What this pins:
;;;   • the counter whose act is contested attaches the picture the count
;;;     names, in order, in parts of sixteen kilobytes at the most; the last
;;;     part joins them and the gateway checks the bytes hash to the value the
;;;     count names, and holds the picture;
;;;   • the counter and the franchise read it back, part by part, whole; no one
;;;     else does, and no one else attaches;
;;;   • a picture other than the one the count names, parts out of order, a
;;;     part over its bound, bytes that do not hash to their name: refused;
;;;   • when the ballot settles the picture is let go.
;;;
;;; Run: tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/doors/test-evidence-door.scm

(add-to-load-path "module")

(define %dir (string-append (or (getenv "TMPDIR") "/tmp") "/playnet-evidence-test-"
                            (number->string (getpid))))
(setenv "PLAYNET_DATA_DIR" %dir)

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet gateway evidence)
             (gcrypt base64) (rnrs bytevectors)
             (goblins) (goblins vat) (goblins actor-lib methods)
             (goblins actor-lib on)
             (srfi srfi-1))

(define vat (spawn-vat))
(define %alice "EAliceEvidenceTestAID00000000000000000000000")   ; the counter
(define %bob   "EBobEvidenceTestAID0000000000000000000000000")   ; the franchise
(define %carl  "ECarlEvidenceTestAID000000000000000000000000")   ; neither

;; a picture of 40000 bytes: four parts of base64
(define bytes (make-bytevector 40000 7))
(do ((i 0 (+ i 1))) ((= i 40000)) (bytevector-u8-set! bytes i (modulo (* i 31) 251)))
(define pic (base64-encode bytes))
(define hash (picture-hash pic))
(define other-hash (string-append "sha256:" (make-string 64 #\0)))

(define settled? #f)
(define (^fake-governance bcom)
  (methods
   ((contest-terms aid ballot)
    (cond ((not (equal? ballot "contest:evt-1")) (list 'error "no such contest"))
          (settled? (list 'error "this contest has settled"))
          ((equal? aid %alice) (list 'ok `((role . attach) (scope-id . "Granary") (hash . ,hash))))
          ((equal? aid %bob)   (list 'ok `((role . view)   (scope-id . "Granary") (hash . ,hash))))
          (else (list 'error "only the counter and the scope's members see this contest's picture"))))))
(define gov (with-vat vat (spawn ^fake-governance)))

(define (spawn-session who)
  (with-vat vat (spawn ^lobby-session who #f #f gov #f #f #f #f #f #f #f #f #f 'device)))

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

(define alice (spawn-session %alice))
(define bob   (spawn-session %bob))
(define carl  (spawn-session %carl))

(define parts (let loop ((i 0) (acc '()))
                (if (>= (* i %part-chars) (string-length pic)) (reverse acc)
                    (loop (+ i 1) (cons (substring pic (* i %part-chars)
                                                   (min (string-length pic) (* (+ i 1) %part-chars)))
                                        acc)))))
(define n (length parts))

(display "\n── 1. the hash is the digest of the bytes ──\n")
(check "a known vector" (picture-hash "YWJj") "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
(check-pred "text that is no base64 has no hash" (not (picture-hash "!!not base64!!")))
(check-pred "a picture of 40000 bytes is more than one part" (> n 1))
(check "the parts count as the module counts them" (evidence-parts-total pic) n)

(display "\n── 1b. the parts, taken in order ──\n")
(call-with-values (lambda () (take-part '() "b" "h" 0 3 "AA"))
  (lambda (pending st)
    (check "the first part is held" st '(more . 2))
    (call-with-values (lambda () (take-part pending "b" "h" 1 3 "BB"))
      (lambda (pending st)
        (check "…the second adds to it" st '(more . 4))
        (call-with-values (lambda () (take-part pending "b" "h" 2 3 "CC"))
          (lambda (pending st)
            (check "the last joins them" st '(done . "AABBCC"))
            (check "…and leaves nothing pending" pending '())))))))
(call-with-values (lambda () (take-part '() "b" "h" 1 3 "BB"))
  (lambda (pending st)
    (check "a part out of order is refused" (car st) 'error)
    (check "…and leaves nothing pending" pending '())))
(call-with-values (lambda () (take-part '(("b" "h" 3 "AA")) "b" "other" 1 3 "BB"))
  (lambda (pending st)
    (check "parts sent under another hash begin again, so the second is refused" (car st) 'error)))
(call-with-values (lambda () (take-part '(("a" "h" 2 "AA")) "b" "h" 0 2 "XX"))
  (lambda (pending st)
    (check "another ballot's parts are kept apart" (list (car st) (assoc-ref pending "a")) '(more ("h" 2 "AA")))))

(display "\n── 2. the counter attaches the picture ──\n")
(check "a part is not sent to a contest that is no contest"
       (err (ask alice 'evidence-part "ballot-1" hash 0 n (car parts))) "a picture is attached to a contest")
(check-pred "a picture is named by a sha256 hash"
            (err (ask alice 'evidence-part "contest:evt-1" "sha256:abc" 0 n (car parts))))
(check "the parts are sent in order: the second first is refused"
       (err (ask alice 'evidence-part "contest:evt-1" hash 1 n (cadr parts))) "the parts of a picture are sent in order")
(check "only the counter attaches"
       (err (ask bob 'evidence-part "contest:evt-1" hash 0 n (car parts))) "only the counter attaches the picture")
(check-pred "…and no one outside the contest"
            (err (ask carl 'evidence-part "contest:evt-1" hash 0 n (car parts))))
(check "a picture other than the one the count names is refused"
       (err (ask alice 'evidence-part "contest:evt-1" other-hash 0 n (car parts))) "that is not the picture the count names")
(check-pred "a part over sixteen kilobytes is refused"
            (err (ask alice 'evidence-part "contest:evt-1" hash 0 n (make-string (+ %part-chars 1) #\A))))
(check "a picture is as many parts as its bound in characters takes" %evidence-max-parts 25)
(check-pred "a picture of more parts than that is refused"
            (err (ask alice 'evidence-part "contest:evt-1" hash 0 (+ %evidence-max-parts 1) (car parts))))
(check "a part is not read from an id that is no contest"
       (err (ask alice 'evidence-chunk "ballot-1" 0)) "a picture is held for a contest")
(define sent (let loop ((i 0) (ps parts) (acc '()))
               (if (null? ps) (reverse acc)
                   (loop (+ i 1) (cdr ps) (cons (ask alice 'evidence-part "contest:evt-1" hash i n (car ps)) acc)))))
(check-pred "every part is taken" (every ok? sent))
(check "…the last says the picture is held" (cdr (last sent)) 'held)

(display "\n── 3. the counter and the franchise read it ──\n")
(define (fetch session)
  (let loop ((i 0) (acc ""))
    (let ((r (ask session 'evidence-chunk "contest:evt-1" i)))
      (cond ((not (ok? r)) r)
            ((< (+ i 1) (assq-ref (cdr r) 'total)) (loop (+ i 1) (string-append acc (assq-ref (cdr r) 'part))))
            (else (string-append acc (assq-ref (cdr r) 'part)))))))
(check "the counter reads the picture whole" (fetch alice) pic)
(check "a member of the franchise reads the same" (fetch bob) pic)
(check "each part names the hash it is held under"
       (assq-ref (cdr (ask bob 'evidence-chunk "contest:evt-1" 0)) 'hash) hash)
(check "someone outside reads nothing" (err (ask carl 'evidence-chunk "contest:evt-1" 0))
       "only the counter and the scope's members see this contest's picture")
(check "a part past the last is none" (err (ask bob 'evidence-chunk "contest:evt-1" n)) "no such part")
(check-pred "a contest that is no contest holds none" (err (ask bob 'evidence-chunk "ballot-1" 0)))

(display "\n── 4. bytes that do not hash to their name ──\n")
(define bad (string-append (substring pic 0 100) "AAAA"))
(check-pred "a short picture of other bytes is refused at the last part"
            (begin (ask alice 'evidence-part "contest:evt-1" hash 0 2 (substring bad 0 60))
                   (err (ask alice 'evidence-part "contest:evt-1" hash 1 2 (substring bad 60)))))
(check "…and the picture held before it stands" (fetch alice) pic)

(display "\n── 5. the picture goes when the ballot settles ──\n")
(set! settled? #f)
(release-contest-evidence! "contest:evt-1")
(check "the held picture is let go" (err (ask alice 'evidence-chunk "contest:evt-1" 0)) "no picture is held for this contest")
(check-pred "…and releasing what is not held is no error" (begin (release-contest-evidence! "contest:evt-1") #t))

(test-summary!)
