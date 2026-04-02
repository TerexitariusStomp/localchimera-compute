;;; test-capacity-execute.scm — Tests for capacity-managed execution primitives
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-capacity-execute.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define pass-count 0)
(define (check label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (format #t "  ok: ~a\n" label))
      (error (string-append "FAIL: " label))))


;; =========================================================================
;; Setup: scope with infrastructure
;; =========================================================================

(display "=== Setup ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Compute Commune"))
    store))

(define compute-ref #f)
(define memory-ref #f)

(with-vat vat
  (let ((rs  ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (lr  ($ scope 'live-registry)))

    ;; Specs
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:compute" "CPU" #f #f #f "cpu-hours" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec:memory" "Memory" #f #f #f "GB" #f #f #f #f #f))

    ;; Observer resources (total capacity)
    ($ obs 'seed-resource
       (make-economic-resource "cpu-1" "CPU" #f #f #f "spec:compute" #f
         (make-measure 16 "cpu-hours") (make-measure 16 "cpu-hours")
         "dc-1" #f "agent:commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "mem-1" "Memory" #f #f #f "spec:memory" #f
         (make-measure 32 "GB") (make-measure 32 "GB")
         "dc-1" #f "agent:commune" #f #f #f #f #f #f #f #f))

    ;; Live-resource actors (available capacity)
    (set! compute-ref (spawn ^live-resource "cpu-1" "spec:compute" 16 16 "cpu-hours" "dc-1" '()))
    (set! memory-ref (spawn ^live-resource "mem-1" "spec:memory" 32 32 "GB" "dc-1" '()))
    ($ lr 'register "cpu-1" compute-ref)
    ($ lr 'register "mem-1" memory-ref)

    (check "setup complete" #t)))


;; =========================================================================
;; 1. with-capacity — basic reserve/thunk/release
;; =========================================================================

(display "\n=== with-capacity ===\n")

(with-vat vat
  (check "before: 16 available" (= 16 ($ compute-ref 'available)))

  (let ((result (with-capacity compute-ref 4
                  (lambda () (+ 21 21)))))
    (check "thunk result returned" (= 42 result))
    (check "after: 16 available (released)" (= 16 ($ compute-ref 'available)))))


;; =========================================================================
;; 2. with-capacity — error safety
;; =========================================================================

(display "\n=== Error safety ===\n")

(with-vat vat
  (catch #t
    (lambda ()
      (with-capacity compute-ref 4
        (lambda () (error "task crashed"))))
    (lambda _args #f))
  (check "after error: 16 available (released)" (= 16 ($ compute-ref 'available))))


;; =========================================================================
;; 3. with-resources — multi-resource
;; =========================================================================

(display "\n=== with-resources ===\n")

(with-vat vat
  (let ((result (with-resources
                  `((,compute-ref . 4) (,memory-ref . 8))
                  (lambda ()
                    ;; During thunk: compute=12, memory=24
                    (list ($ compute-ref 'available)
                          ($ memory-ref 'available))))))
    (check "during: compute was 12" (= 12 (car result)))
    (check "during: memory was 24" (= 24 (cadr result)))
    (check "after: compute 16" (= 16 ($ compute-ref 'available)))
    (check "after: memory 32" (= 32 ($ memory-ref 'available)))))

;; Multi-resource error safety
(with-vat vat
  (catch #t
    (lambda ()
      (with-resources
        `((,compute-ref . 4) (,memory-ref . 8))
        (lambda () (error "multi-resource crash"))))
    (lambda _args #f))
  (check "after multi-error: compute 16" (= 16 ($ compute-ref 'available)))
  (check "after multi-error: memory 32" (= 32 ($ memory-ref 'available))))


;; =========================================================================
;; 4. execute-with-event — capacity + VF event recording
;; =========================================================================

(display "\n=== execute-with-event ===\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (events-before (length ($ obs 'all-events)))
         (result (execute-with-event obs
                   `((,compute-ref "cpu-1" "spec:compute" 4 "cpu-hours")
                     (,memory-ref "mem-1" "spec:memory" 8 "GB"))
                   (lambda () "transcription complete")
                   #:process-id "proc-transcribe"
                   #:provider "agent:cluster")))

    (check "result returned" (equal? "transcription complete" result))
    (check "capacity released: compute 16" (= 16 ($ compute-ref 'available)))
    (check "capacity released: memory 32" (= 32 ($ memory-ref 'available)))

    ;; Two events should have been recorded (one per resource)
    (let ((events-after (length ($ obs 'all-events))))
      (check "2 events recorded" (= 2 (- events-after events-before))))))

;; execute-with-event error safety
(with-vat vat
  (let* ((obs ($ scope 'observer))
         (events-before (length ($ obs 'all-events))))
    (catch #t
      (lambda ()
        (execute-with-event obs
          `((,compute-ref "cpu-1" "spec:compute" 4 "cpu-hours"))
          (lambda () (error "execution failed"))))
      (lambda _args #f))
    (check "after exec error: compute 16" (= 16 ($ compute-ref 'available)))
    ;; No events recorded on failure (thunk didn't complete)
    (check "no events on failure" (= (length ($ obs 'all-events)) events-before))))


;; =========================================================================
;; 5. Real computation example
;; =========================================================================

(display "\n=== Real computation ===\n")

(with-vat vat
  ;; Simulate a computation: factorial of 20
  (let ((result (with-capacity compute-ref 1
                  (lambda ()
                    (let loop ((n 20) (acc 1))
                      (if (= n 0) acc (loop (- n 1) (* acc n))))))))
    (check "factorial(20) computed" (= 2432902008176640000 result))
    (check "capacity released" (= 16 ($ compute-ref 'available)))))


;; =========================================================================
;; Done
;; =========================================================================

(format #t "\n~a/~a checks passed.\n" pass-count pass-count)
