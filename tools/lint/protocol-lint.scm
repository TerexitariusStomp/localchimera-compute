#!/usr/bin/env -S guile -L module
!#
;;; tools/lint/protocol-lint.scm — the declaration and the code name the same doors
;;;
;;; Three properties, each a refusal on its own:
;;;   1. every (object name args) head in the code (tools/lint/protocol-extract.scm)
;;;      is declared in (playnet doors protocol) with the same args, and vice versa;
;;;   2. (gone: a door's seam is derived from the seam table, property 5)
;;;   3. no planner door is declared behind a session gate the planner does
;;;      not have (the lobby's facet allowlist is derived from the
;;;      declaration, so it cannot drift on its own);
;;;   4. every argument name on every door has a shape in
;;;      (playnet protocol shapes), so no emit ever guesses a type;
;;;   5. the seam table and day-boot's registry name the same handlers, and
;;;      every door a handler sends is declared.
;;;
;;; Run: guile -L module tools/lint/protocol-lint.scm   (make check-protocol)

(use-modules (playnet doors protocol)
             (playnet protocol shapes)
             (playnet protocol seam)
             ((playnet wire rows) #:select (reply-table-ref))
             (playnet wire replies) (playnet doors record-rows)   ; the reply tables, registered
             ((playnet doors lobby) #:select (%planner-public-doors))
             (ice-9 popen) (ice-9 rdelim) (ice-9 regex) (ice-9 format)
             (srfi srfi-1))

(define (code-heads)
  (let* ((p (open-pipe* OPEN_READ "guile" "-L" "module" "tools/lint/protocol-extract.scm" "sexp"))
         (forms (let loop ((acc '()))
                  (let ((f (read p))) (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))
    (close-pipe p)
    ;; (object name . args)
    forms))

(define (registry-names)
  "Every handler the spine registers: the Scheme registry in day-boot.scm and
the three the JS shell sets on HANDLERS itself (device key tiers/forget)."
  (define (scan file rx)
    (let ((src (call-with-input-file file read-string)) (rx (make-regexp rx)))
      (let loop ((start 0) (acc '()))
        (let ((m (regexp-exec rx src start)))
          (if m (loop (match:end m) (cons (match:substring m 1) acc)) acc)))))
  (delete-duplicates
   (append (scan "hoot/day-boot.scm" "\\(\"([A-Za-z0-9]+)\" *\\. *,handle-")
           (scan "browser/day-boot.js" "HANDLERS\\.([A-Za-z0-9]+) *="))))

(define bad 0)
(define (refuse fmt . args) (set! bad (+ bad 1)) (apply format #t fmt args) (newline))

;; 1. heads
(let* ((code (code-heads))
       (decl (map (lambda (d) (cons* (door-object d) (door-name d) (door-args d))) %doors)))
  (for-each (lambda (h) (unless (member h decl)
                          (let ((d (door-ref (car h) (cadr h))))
                            (if d
                                (refuse "args differ for ~a ~a: code ~s, declared ~s" (car h) (cadr h) (cddr h) (door-args d))
                                (refuse "undeclared door in code: ~a ~a ~s" (car h) (cadr h) (cddr h))))))
            code)
  (for-each (lambda (h) (unless (member h code)
                          (unless (find (lambda (c) (and (eq? (car c) (car h)) (eq? (cadr c) (cadr h)))) code)
                            (refuse "declared door absent from code: ~a ~a" (car h) (cadr h)))))
            decl)
  (format #t "heads: ~a in code, ~a declared~%" (length code) (length decl)))

;; 2. targets — where a session door's act is done, declared on the door
;;    (#:to) and read off the lobby clause's own body: the two must agree.
(let* ((p (open-pipe* OPEN_READ "guile" "-L" "module" "tools/lint/protocol-extract.scm" "targets"))
       (code (let loop ((acc '()))
               (let ((f (read p))) (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))
  (close-pipe p)
  (for-each (lambda (d)
              (when (eq? (door-object d) 'session)
                (let ((t (assq-ref code (door-name d))))
                  (when (and t (not (eq? t (door-to d))))
                    (refuse "session door ~a is declared #:to ~a and its code sends to ~a" (door-name d) (door-to d) t)))))
            %doors)
  (format #t "targets: ~a session doors forward to the planner, ~a to governance~%"
          (count (lambda (d) (and (eq? (door-object d) 'session) (eq? (door-to d) 'planner))) %doors)
          (count (lambda (d) (and (eq? (door-object d) 'session) (eq? (door-to d) 'governance))) %doors)))

;; 3. planner facet — the lobby derives its allowlist from the declaration,
;; so the one thing left to refuse is a planner door declared behind a
;; session gate the planner does not have yet.
(let ((anon (filter (lambda (d) (and (eq? (door-object d) 'planner)
                                     (eq? (door-auth d) 'anonymous)))
                    %doors)))
  (for-each (lambda (d) (when (and (eq? (door-object d) 'planner)
                                   (memq (door-auth d) '(device root)))
                          (refuse "planner door ~a declared ~a: the planner has no session gate yet" (door-name d) (door-auth d))))
            %doors)
  (unless (equal? (map door-name anon) %planner-public-doors)
    (refuse "the lobby's %planner-public-doors is not the declaration's anonymous planner doors"))
  (format #t "facet: ~a anonymous planner doors~%" (length anon)))

;; 4. shapes
(let ((unknown '()))
  (for-each (lambda (d)
              (for-each (lambda (e)
                          (unless (cadr e)
                            (set! unknown (cons (list (door-object d) (door-name d) (car e)) unknown))))
                        (door-arg-shapes d)))
            %doors)
  (for-each (lambda (u) (refuse "argument ~a on ~a ~a has no shape (module/playnet/protocol/shapes.scm)" (caddr u) (car u) (cadr u)))
            (reverse unknown))
  (format #t "shapes: ~a doors have an HTTP form~%" (count door-http? %doors)))

;; 5. seam table
(let ((reg (registry-names)))
  (for-each (lambda (h)
              (unless (member (handler-name h) reg)
                (refuse "seam handler ~s is not registered in day-boot.scm" (handler-name h)))
              (for-each (lambda (d)
                          (unless (door-ref (car d) (cdr d))
                            (refuse "seam handler ~s sends undeclared door ~a ~a" (handler-name h) (car d) (cdr d))))
                        (handler-doors h))
              (let ((r (handler-reply h)))
                (when r
                  (unless (member r (map cdr (handler-doors h)))
                    (refuse "seam handler ~s says its reply is door ~a's, which it does not send" (handler-name h) r))
                  (unless (reply-table-ref r)
                    (refuse "seam handler ~s says its reply is door ~a's table, and the registry has none" (handler-name h) r)))))
            %handlers)
  (for-each (lambda (n)
              (unless (handler-ref n)
                (refuse "day-boot registers ~s, absent from (playnet protocol seam)" n)))
            reg)
  (format #t "seam table: ~a handlers, ~a local~%" (length %handlers) (count handler-local? %handlers)))

;; 6. the push half: the table against day-boot.js's own calls and the wasm's
;;    "seam" imports. The wired sinks and every push are BUILT from the table
;;    (seam.ts over the generated SEAM_WIRE), so what remains to check is what
;;    hands write: a page-raised push day-boot.js calls, and the imports the
;;    wasm declares.
(let* ((js      (call-with-input-file "browser/day-boot.js" read-string))
       (scm     (call-with-input-file "hoot/day-boot.scm" read-string))
       (scan    (lambda (text rx)
                  (let loop ((start 0) (acc '()))
                    (let ((m (string-match rx text start)))
                      (if m
                          (loop (match:end m) (cons (match:substring m 1) acc))
                          (delete-duplicates (reverse acc)))))))
       (calls   (scan js "seam\\.([A-Za-z]+)\\("))                  ; seam methods day-boot.js calls
       (imports (scan scm "\"seam\" \"([A-Za-z]+)\"")))            ; the wasm's "seam" imports
  (for-each (lambda (p)
              (unless (or (push-sink p) (member (push-name p) calls))
                (refuse "seam push ~s has no sink and day-boot.js never raises it" (push-name p))))
            %pushes)
  (for-each (lambda (n)
              (unless (push-ref n)
                (refuse "day-boot.js calls seam.~a(…), absent from (playnet protocol seam) pushes" n)))
            calls)
  (for-each (lambda (n)
              (unless (or (member n %sink-plumbing)
                          (find (lambda (p) (equal? (push-sink p) n)) %pushes))
                (refuse "the wasm imports \"seam\" ~s, which is neither a push sink nor plumbing" n)))
            imports)
  (for-each (lambda (p)
              (when (and (push-sink p) (not (member (push-sink p) imports)))
                (refuse "seam push ~s names sink ~s, which the wasm never raises" (push-name p) (push-sink p))))
            %pushes)
  (format #t "seam pushes: ~a, ~a from the wasm, ~a raised in JS~%"
          (length %pushes) (count push-sink %pushes) (count (lambda (p) (not (push-sink p))) %pushes)))

(if (zero? bad)
    (begin (display "protocol-lint: ok\n") (exit 0))
    (begin (format #t "protocol-lint: ~a refusal(s)~%" bad) (exit 1)))
