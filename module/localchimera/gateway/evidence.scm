;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/gateway/evidence.scm — a counter's picture, held for a contest
;;;
;;; A photo read keeps its picture on the counter's device and names it on the
;;; count by hash (docs/observation/capture.md §8, §9). When the count is
;;; contested, the counter may attach the picture to the ballot: the picture
;;; crosses in parts (the transport hangs on a message past sixteen kilobytes,
;;; deploy/UPSTREAM-ISSUES.md §14), the gateway checks that the joined bytes
;;; hash to the value the count names, holds them in its data directory for the
;;; ballot's life, serves them to the franchise, and lets them go when the
;;; ballot settles.
;;;
;;; This module is the held file and the arithmetic of parts; who may attach
;;; and who may read is the governance service's word (contest-terms), asked by
;;; the session door.

(define-module (localchimera gateway evidence)
  #:use-module (srfi srfi-1)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (gcrypt base64)
  #:use-module ((localchimera vf facts limits) #:select (%evidence-max-chars))
  #:re-export (%evidence-max-chars)
  #:export (%part-chars %evidence-max-parts %pictures-per-read
            picture-hash evidence-parts-total evidence-part-of take-part
            hold-evidence! held-evidence release-evidence!))

(define (ceiling-quotient a b) (quotient (+ a b -1) b))

;; a part is sixteen kilobytes at the most: the one bound on a message the
;; transport carries, for the pictures of a read and the picture of a contest
;; alike (the bridge sends a round figure beneath it, hoot/day-boot.scm)
(define %part-chars (* 16 1024))
;; the whole is bounded as a read's pictures are: one reduced picture
;; (%evidence-max-chars, vf/facts/limits.scm)
;; the shots of one scene a read takes (ui/app/photo.ts SHOTS_PER_READ, pinned by test-see-door)
(define %pictures-per-read 4)
;; …which is this many parts of at most %part-chars
(define %evidence-max-parts (ceiling-quotient %evidence-max-chars %part-chars))

(define (picture-hash b64)
  "The hash a picture's base64 is known by on a count: sha256: and the digest of
   its bytes in hex. #f when B64 is no base64."
  (catch #t
    (lambda () (string-append "sha256:" (bytevector->base16-string (sha256 (base64-decode b64)))))
    (lambda _ #f)))

(define (evidence-parts-total b64)
  "How many parts of at most %part-chars B64 is served in."
  (max 1 (ceiling-quotient (string-length b64) %part-chars)))

(define (evidence-part-of b64 index)
  "Part INDEX of B64, or #f when it has none."
  (let ((from (* index %part-chars)))
    (and (integer? index) (>= index 0) (< from (string-length b64))
         (substring b64 from (min (string-length b64) (+ from %part-chars))))))

(define (file-for dir ballot-id)
  (string-append dir "/evidence/"
                 (string-map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_))) c #\_))
                             ballot-id)
                 ".pic"))

;; The parts of a picture on its way to a contest, as they arrive: PENDING is
;; ((ballot hash total part …) …), the parts oldest first. They are taken in
;; order, under one hash and one total. Returns the new pending and a status:
;; (error . words), (more . characters-held) or (done . the joined base64).
(define (take-part pending ballot hash index total part)
  (let* ((held  (assoc-ref pending ballot))
         (parts (if (and held (equal? (car held) hash) (equal? (cadr held) total)) (cddr held) '()))
         (rest  (filter (lambda (x) (not (equal? (car x) ballot))) pending)))
    (cond
     ((not (= index (length parts)))
      (values rest (cons 'error "the parts of a picture are sent in order")))
     ((< (+ index 1) total)
      (let ((parts* (append parts (list part))))
        (values (cons (cons ballot (cons hash (cons total parts*))) rest)
                (cons 'more (apply + (map string-length parts*))))))
     (else
      (values rest (cons 'done (apply string-append (append parts (list part)))))))))

(define (ensure-dir! dir)
  "DIR and the directories above it, made where they are missing."
  (unless (or (string=? dir "") (string=? dir "/") (file-exists? dir))
    (ensure-dir! (dirname dir))
    (catch 'system-error (lambda () (mkdir dir)) (lambda _ #f))))

(define (hold-evidence! dir ballot-id hash b64)
  "Hold the picture B64 under BALLOT-ID, naming HASH. #f when its bytes do not
   hash to HASH or it is over its bound."
  (and (string? b64) (<= (string-length b64) %evidence-max-chars)
       (equal? hash (picture-hash b64))
       (let ((file (file-for dir ballot-id)))
         (ensure-dir! (string-append dir "/evidence"))
         (call-with-output-file file
           (lambda (p) (display hash p) (newline p) (display b64 p) (newline p)))
         #t)))

(define (held-evidence dir ballot-id)
  "(hash . base64) held under BALLOT-ID, or #f."
  (let ((file (file-for dir ballot-id)))
    (and (file-exists? file)
         (call-with-input-file file
           (lambda (p)
             (let* ((hash (read-line* p)) (b64 (read-line* p)))
               (and (string? hash) (string? b64) (cons hash b64))))))))

(define (read-line* p)
  (let loop ((cs '()))
    (let ((c (read-char p)))
      (cond ((or (eof-object? c) (char=? c #\newline))
             (and (or (pair? cs) (not (eof-object? c))) (list->string (reverse cs))))
            (else (loop (cons c cs)))))))

(define (release-evidence! dir ballot-id)
  "Let go of the picture held under BALLOT-ID."
  (let ((file (file-for dir ballot-id)))
    (when (file-exists? file)
      (catch 'system-error (lambda () (delete-file file)) (lambda _ #f)))))
