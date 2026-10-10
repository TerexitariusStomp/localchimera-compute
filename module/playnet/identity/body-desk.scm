;;; module/playnet/identity/body-desk.scm — the desk where a body's inception
;;; waits for its stewards' signatures.
;;;
;;; A ceremony (identity/body-ceremony.scm) reads and writes the oobi-host, so
;;; it lives in the oobi-host's vat; the body service (planner/doors/bodies.scm)
;;; lives in the planner's. This desk is the one actor between them: it holds
;;; the open ceremonies by the body's provisional id, opens one on request,
;;; hands out the statement to sign, counts a signature, and reports standing.
;;; When a ceremony publishes, its `close!` reaches the body service through
;;; CLOSER, which the gateway makes once both exist.
;;;
;;; The desk keeps no store: a ceremony's durable record is the ceremony's own
;;; (under the witness dir), and a desk spawned afresh holds no open round.
;;;
;;;   (spawn ^body-ceremony-desk oobi-host closer #:witness-dir dir)
;;;     'open! scope-id body-id initiator-aid steward-aids k   → standing
;;;     'status body-id                                        → standing | #f
;;;     'statuses body-ids                                     → ((body-id . standing|#f) …)
;;;     'preimage body-id what  → (("what" . w) ("said" . s))  or raises
;;;     'sign body-id aid what said sig-qb64                   → standing   or raises
;;;   standing = (("have" . n) ("need" . k) ("published" . aid|#f) ("what" . w))

(define-module (playnet identity body-desk)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((playnet identity body-ceremony) #:select (spawn-body-ceremony))
  #:export (^body-ceremony-desk ceremony-standing))

(define (sym->str x) (cond ((symbol? x) (symbol->string x)) ((string? x) x) (else "")))

(define (ceremony-standing cer)
  "The wire shape of a ceremony's status, or #f for none."
  (and cer
       (let ((st ($ cer 'status)))
         (and (list? st)
              `(("have" . ,(or (assq-ref st 'have) 0))
                ("need" . ,(or (assq-ref st 'need) 0))
                ("published" . ,(or (assq-ref st 'published) #f))
                ("what" . ,(sym->str (or (assq-ref st 'what) "inception"))))))))

(define* (^body-ceremony-desk bcom oobi-host closer #:key (witness-dir #f) (create-group #f))
  (define open (make-hash-table))          ; body-id → ceremony actor
  (define (cer-of id) (hash-ref open id #f))
  (methods
   ((open! scope-id body-id initiator-aid steward-aids k)
    (when (cer-of body-id) (error "a ceremony is already open for this body"))
    (let ((cer (spawn-body-ceremony
                #:scope-aid scope-id #:initiator-aid initiator-aid
                #:steward-aids steward-aids #:k k #:oobi-host oobi-host
                #:witness-dir witness-dir #:create-group create-group
                #:close! (lambda (aid)
                           (hash-remove! open body-id)
                           (closer scope-id body-id aid)))))
      ;; the KERIA path closes at once; only a collecting round stays open
      (let ((st (ceremony-standing cer)))
        (unless (assoc-ref st "published") (hash-set! open body-id cer))
        st)))
   ((status body-id) (ceremony-standing (cer-of body-id)))
   ((statuses body-ids)
    (map (lambda (id) (cons id (ceremony-standing (cer-of id)))) body-ids))
   ((preimage body-id what)
    (let ((cer (or (cer-of body-id) (error "no ceremony is open for this body"))))
      (let ((p ($ cer 'preimage)))
        (unless (list? p) (error "the ceremony has nothing to sign"))
        (unless (equal? (sym->str (assq-ref p 'what)) (sym->str what))
          (error (format #f "the ceremony is at ~a, not ~a" (assq-ref p 'what) what)))
        `(("what" . ,(sym->str what)) ("said" . ,(assq-ref p 'said))))))
   ((sign body-id aid what said sig)
    (let ((cer (or (cer-of body-id) (error "no ceremony is open for this body"))))
      (let ((p ($ cer 'preimage)))
        (unless (and (list? p) (equal? said (assq-ref p 'said)))
          (error "that is not the statement open for signing"))
        (unless (equal? (sym->str (assq-ref p 'what)) (sym->str what))
          (error (format #f "the ceremony is at ~a, not ~a" (assq-ref p 'what) what)))
        ($ cer 'sign aid sig)
        (ceremony-standing cer))))))
