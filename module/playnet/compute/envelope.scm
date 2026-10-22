;;; compute/envelope.scm — the job envelope: what a node pulls and runs.
;;;
;;; WHAT THE FILE HOLDS. The <job-envelope> record — the self-describing
;;; unit of work a compute node fetches under a dispatch claim — and the
;;; one structural rule the spec makes load-bearing: AN ENVELOPE CARRIES
;;; NO AMOUNT. Pricing is never in the job; what a lender earns is decided
;;; by the commune's settlement, not by bytes the node executes. The
;;; validator refuses any envelope that names price-like keys, loudly —
;;; an envelope that says what it pays is not an envelope, it is a leak
;;; of the settlement layer into the execution layer.

(define-module (playnet compute envelope)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:export (<job-envelope> make-job-envelope job-envelope?
            job-envelope-bridge-job-id job-envelope-image
            job-envelope-entrypoint job-envelope-input-hash
            job-envelope-caps job-envelope-network?
            alist->job-envelope job-envelope->alist envelope-no-amount?))


;;; The keys an envelope may never carry — in any spelling a bridge might
;;; reach for. Checked on both construction and parse, so a hand-written
;;; alist cannot smuggle the field past a struct.
(define *price-keys* '(amount price cost fee payment payout rate tip
                              unit-price currency))

(define-record-type <job-envelope>
  (%make-job-envelope bridge-job-id image entrypoint input-hash caps network?)
  job-envelope?
  (bridge-job-id job-envelope-bridge-job-id) ; string — the claim's job
  (image         job-envelope-image)         ; string — container/wasm image ref
  (entrypoint    job-envelope-entrypoint)    ; string
  (input-hash    job-envelope-input-hash)    ; string — input fetched out-of-band
  (caps          job-envelope-caps)          ; alist: mem-mb, cpu-seconds
  (network?      job-envelope-network?))     ; bool — egress allowed or not

(define* (make-job-envelope #:key bridge-job-id image entrypoint input-hash
                            (caps '()) (network? #f))
  (%make-job-envelope bridge-job-id image entrypoint input-hash caps network?))

(define (envelope-no-amount? fields)
  "No key in FIELDS (an alist or a list of symbols) is a price key."
  (every (lambda (k)
           (not (memq (if (pair? k) (car k) k) *price-keys*)))
         fields))

(define (alist->job-envelope a)
  "Parse the wire alist. Refuses any envelope carrying a price key."
  (unless (envelope-no-amount? a)
    (error "envelope: a job envelope carries no amount"))
  (match a
    ((('bridgeJobId . (? string? jid))
      ('image . (? string? image))
      ('entrypoint . (? string? entrypoint))
      ('inputHash . (? string? input-hash))
      ('caps . caps)
      ('network . (? boolean? network?)) . _)
     (make-job-envelope #:bridge-job-id jid #:image image
                        #:entrypoint entrypoint #:input-hash input-hash
                        #:caps caps #:network? network?))
    (_ (error "envelope: not a job-envelope alist" a))))

(define (job-envelope->alist e)
  `(("bridgeJobId" . ,(job-envelope-bridge-job-id e))
    ("image"       . ,(job-envelope-image e))
    ("entrypoint"  . ,(job-envelope-entrypoint e))
    ("inputHash"   . ,(job-envelope-input-hash e))
    ("caps"        . ,(job-envelope-caps e))
    ("network"     . ,(job-envelope-network? e))))
