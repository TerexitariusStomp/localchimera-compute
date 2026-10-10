;;; test-tag-keys-registered.scm — every "key:value" tag the planner reads has one reader.
;;;
;;; A classification tag is read through facts/agent-tags (tag-value, tag-values,
;;; tag-key?), and the keys it may carry stand in %tag-keys there — with the time keys
;;; (facts/agent-time) and the tension terms (facts/tension-terms), the two registries
;;; that came first. This suite scans the planner's modules for a `string-prefix?
;;; "<key>:"` read and refuses one whose key is not registered: the id prefixes a row
;;; or a store key carries (payout:, offer:, need:, means:, home:, …) are named below as
;;; ids, which are not tags.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/vf/test-tag-keys-registered.scm

(use-modules (playnet test harness)
             ((playnet vf facts agent-tags) #:select (%tag-keys tag-value tag-values tag-key?))
             (ice-9 ftw) (ice-9 rdelim) (ice-9 regex) (srfi srfi-1))

(define %id-prefixes   ; keys of ids and store rows, read by the module that mints them
  '("payout" "offer" "xmr" "unsettled" "sent" "res" "plan" "need" "means" "home" "geo"
    "sha256" "count" "contest" "claim"))
(define %tension-terms '("level" "voice" "tension" "against"))   ; facts/tension-terms, its own registry
(define %time-keys '("sleep" "away"))                              ; facts/agent-time

(define (scm-files root)
  (file-system-fold
   (lambda (path stat result) (not (string-contains path "/deprecated")))
   (lambda (path stat result) (if (string-suffix? ".scm" path) (cons path result) result))
   (lambda (path stat result) result) (lambda (path stat result) result) (lambda (path stat result) result)
   (lambda (path stat errno result) result) '() root))

(define rx (make-regexp "string-prefix\\? \"([A-Za-z:-]+):\""))
(define (keys-read path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((line (read-line port)))
          (if (eof-object? line) acc
              (loop (append (map (lambda (m) (match:substring m 1))
                                 (list-matches rx (let ((i (string-index line #\;))) (if i (substring line 0 i) line))))
                            acc))))))))

(define registered (append %tag-keys %id-prefixes %tension-terms %time-keys))
(define unregistered
  (delete-duplicates
   (append-map (lambda (f)
                 (filter-map (lambda (k) (and (not (member k registered)) (cons f k))) (keys-read f)))
               (scm-files "module/playnet/planner"))))

(display "\n── the readers ──\n")
(check "tag-value reads a key" (tag-value '("diet:vegan" "age:40") "diet") "vegan")
(check "tag-values reads them all" (tag-values '("self:a" "x" "self:b") "self") '("a" "b"))
(check-pred "tag-key? knows a key" (and (tag-key? "manner:bicycle" "manner") (not (tag-key? "mannered" "manner"))))

(display "\n── every key the planner reads by prefix is registered ──\n")
(check "no unregistered key:value prefix is read by hand" unregistered '())

(test-summary!)
