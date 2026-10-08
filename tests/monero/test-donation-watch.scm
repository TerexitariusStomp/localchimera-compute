;;; tests/monero/test-donation-watch.scm — the gateway's donation watch
;;;
;;; The wallet runs in its own process, so the gateway asks its policy with
;;; sends and works as the answers arrive. What has to hold:
;;;
;;;   - the XMR pool's total is the wallet's UNLOCKED balance
;;;   - a transfer is recorded as a donation once — across ticks, and across
;;;     a restart of the gateway (the state file)
;;;   - a wallet that is down costs a tick and nothing else
;;;
;;; Run:  guile -L module tests/monero/test-donation-watch.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (playnet test harness)
             (playnet planner vf schemas) (srfi srfi-1)
             (playnet monero wallet)
             (playnet monero poller)
             (srfi srfi-1)
             (ice-9 format))

(define gateway-vat (spawn-vat #:name "gateway"))
(define planner-vat (spawn-vat #:name "planner"))

(define (settle) (usleep 250000))

;;; ── What the policy client answers ────────────────────────────────────────

(define %wallet-up? #t)
(define %balance (make-balance-info 3000000000000 1000000000000 5))
(define %incoming '())              ; list of transfer alists
(define %asked-min-heights '())

(define (transfer txid amount height)
  `(("txid" . ,txid) ("amount" . ,amount) ("height" . ,height)
    ("subaddr_index" . (("major" . 0) ("minor" . 0)))))

(define (^fake-policy bcom)
  (methods
   ((get-balance)
    (unless %wallet-up? (error "the wallet service has announced no policy"))
    %balance)
   ((get-incoming min-height)
    (unless %wallet-up? (error "the wallet service has announced no policy"))
    (set! %asked-min-heights (cons min-height %asked-min-heights))
    `(("in" . ,(list->vector %incoming))))))

(define policy (with-vat gateway-vat (spawn ^fake-policy)))

;;; ── The planner's side: a pool and an observer that record ────────────────

(define %pool-total #f)
(define %recorded '())

(define-values (scope pool)
  (with-vat planner-vat
    (let* ((observer (spawn (lambda (bcom)
                              (methods
                               ((record-event event)
                                (set! %recorded (cons event %recorded)))))))
           (scope (spawn (lambda (bcom)
                           (methods ((observer) observer)))))
           (pool (spawn (lambda (bcom)
                          (methods
                           ((resize new-total) (set! %pool-total new-total)))))))
      (values scope pool))))

(define %state-file (format #f "/tmp/playnet-test-donation-watch-~a.state" (getpid)))
(when (file-exists? %state-file) (delete-file %state-file))

(define (tick!)
  (with-vat gateway-vat
    (donation-watch-tick! policy scope pool %state-file))
  (settle))

(define (recorded-ids) (map economic-event-id %recorded))

;;; ── The pool is what the wallet can pay ───────────────────────────────────

(tick!)
(check "the pool's total is the UNLOCKED balance (1 XMR of 3)"
       (and (number? %pool-total) (= 1.0 %pool-total)))
(check "with nothing received, nothing is recorded" (null? %recorded))
(check "a first tick asks for transfers from height 0"
       (equal? '(0) %asked-min-heights))

;;; ── A donation is recorded once ───────────────────────────────────────────

(set! %incoming (list (transfer "tx-a" 500000000000 3766100)))
(tick!)
(check "an incoming transfer becomes one donation event"
       (= 1 (length %recorded)))
(check "the event is a 'raise of 0.5 XMR classified as a donation"
       (let ((e (car %recorded)))
         (and (eq? 'raise (economic-event-action e))
              (equal? '("donation") (economic-event-resource-classified-as e))
              (= 0.5 (measure-has-numerical-value
                      (economic-event-resource-quantity e))))))

(tick!)
(tick!)
(check "the wallet keeps reporting it; it stays recorded once"
       (= 1 (length %recorded)))
(check "later ticks ask from the height already seen"
       (= 3766100 (car %asked-min-heights)))

(set! %incoming (list (transfer "tx-a" 500000000000 3766100)
                      (transfer "tx-b" 250000000000 3766140)))
(tick!)
(check "a second transfer is recorded, the first is left alone"
       (and (= 2 (length %recorded))
            (= 2 (length (delete-duplicates (recorded-ids))))))

;;; ── A restart records nothing twice ───────────────────────────────────────

(check "the state is on disk" (file-exists? %state-file))
(let ((state (load-poller-state %state-file)))
  (check "and holds the height and both txids"
         (and (= 3766140 (assq-ref state 'last-seen-height))
              (lset= equal? '("tx-a" "tx-b") (assq-ref state 'seen-txids)))))

;; Nothing in this process remembers the transfers but the file.
(tick!)
(check "a tick after a restart finds nothing new" (= 2 (length %recorded)))

;;; ── A wallet that is down ─────────────────────────────────────────────────

(set! %wallet-up? #f)
(set! %pool-total 'untouched)
(tick!)
(check "a tick with the wallet down leaves the pool as it was"
       (eq? 'untouched %pool-total))
(check "and records nothing" (= 2 (length %recorded)))

(set! %wallet-up? #t)
(set! %balance (make-balance-info 3000000000000 3000000000000 0))
(tick!)
(check "the next tick, wallet back, the pool follows the unlocked balance"
       (= 3.0 %pool-total))

(when (file-exists? %state-file) (delete-file %state-file))
(test-summary!)
