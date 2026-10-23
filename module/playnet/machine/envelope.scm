;;; compute/envelope.scm — the job envelope: what a node pulls and runs.
;;;
;;; WHAT THE FILE HOLDS. The <job-envelope> record — the self-describing
;;; unit of work a machine node fetches under a dispatch claim — and the
;;; one structural rule the spec makes load-bearing: AN ENVELOPE CARRIES
;;; NO AMOUNT. Pricing is never in the job; what a lender earns is decided
;;; by the commune's settlement, not by bytes the node executes. The
;;; validator refuses any envelope that names price-like keys, loudly —
;;; an envelope that says what it pays is not an envelope, it is a leak
;;; of the settlement layer into the execution layer.
;;;
;;; KINDS. An envelope declares one of *envelope-kinds* — 'exec (the
;;; original shape: image + entrypoint), 'store (hold contentHash for
;;; ttlSeconds; answer challenges), 'relay (pass traffic; params name
;;; the measured shape), 'sense (emit readings on an interval), and
;;; 'bundle (a job whose legs are sub-envelopes). Kind-specific fields
;;; ride in PARAMS — a free alist under the same no-amount rule, checked
;;; recursively so a nested leg cannot smuggle price either.

(define-module (playnet machine envelope)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:export (<job-envelope> make-job-envelope job-envelope?
            job-envelope-kind job-envelope-bridge-job-id job-envelope-image
            job-envelope-entrypoint job-envelope-input-hash
            job-envelope-caps job-envelope-network? job-envelope-params
            envelope-kind? *envelope-kinds*
            alist->job-envelope job-envelope->alist envelope-no-amount?))


;;; The keys an envelope may never carry — in any spelling a bridge might
;;; reach for. Checked on both construction and parse, so a hand-written
;;; alist cannot smuggle the field past a struct.
(define *price-keys* '(amount price cost fee payment payout rate tip
                              unit-price currency))

;;; the kind vocabulary — the wire the offer/jobs shape names
(define *envelope-kinds* '(exec store relay sense bundle))

(define (envelope-kind? x) (and (memq x *envelope-kinds*) #t))

(define-record-type <job-envelope>
  (%make-job-envelope kind bridge-job-id image entrypoint input-hash caps
                      network? params)
  job-envelope?
  (kind          job-envelope-kind)        ; 'exec | 'store | 'relay | 'sense | 'bundle
  (bridge-job-id job-envelope-bridge-job-id) ; string — the claim's job
  (image         job-envelope-image)         ; string | #f — exec kind only
  (entrypoint    job-envelope-entrypoint)    ; string | #f — exec kind only
  (input-hash    job-envelope-input-hash)    ; string — content hash for 'store
  (caps          job-envelope-caps)          ; alist: mem-mb, cpu-seconds
  (network?      job-envelope-network?)      ; bool — egress allowed or not
  (params        job-envelope-params))       ; alist — kind fields, price-free

(define* (make-job-envelope #:key (kind 'exec) bridge-job-id (image #f)
                            (entrypoint #f) input-hash
                            (caps '()) (network? #f) (params '()))
  (unless (envelope-kind? kind)
    (error "envelope: not an envelope kind" kind))
  (when (eq? kind 'exec)
    (unless (and (string? image) (string? entrypoint))
      (error "envelope: an exec envelope needs image and entrypoint")))
  (unless (envelope-no-amount? params)
    (error "envelope: params carry no amount"))
  (%make-job-envelope kind bridge-job-id image entrypoint input-hash caps
                      network? params))

(define (envelope-no-amount? fields)
  "No key in FIELDS (an alist or a list of symbols) is a price key —
   checked recursively, so a params value or bundle leg that is itself an
   alist is walked too."
  (every (lambda (f)
           (and (not (memq (if (pair? f) (car f) f) *price-keys*))
                (or (not (and (pair? f) (list? (cdr f))))
                    (envelope-no-amount? (cdr f)))))
         fields))

(define (alist->job-envelope a)
  "Parse the wire alist. Refuses any envelope carrying a price key.
   'kind' and 'params' are optional — an envelope that names neither is the
   original exec shape, so every pre-kind wire form still parses."
  (unless (envelope-no-amount? a)
    (error "envelope: a job envelope carries no amount"))
  (let ((kind (cond ((assq-ref a 'kind) => string->symbol)
                    (else 'exec)))
        (params (or (assq-ref a 'params) '()))
        (jid (assq-ref a 'bridgeJobId))
        (image (assq-ref a 'image))
        (entry (assq-ref a 'entrypoint))
        (input-hash (assq-ref a 'inputHash))
        (caps (assq-ref a 'caps))
        (network? (assq-ref a 'network)))
    (unless (string? jid) (error "envelope: bridgeJobId must be a string" a))
    (unless (string? input-hash)
      (error "envelope: inputHash must be a string" a))
    (unless (boolean? network?)
      (error "envelope: network must be a boolean" a))
    (make-job-envelope #:kind kind #:bridge-job-id jid #:image image
                       #:entrypoint entry #:input-hash input-hash
                       #:caps (or caps '()) #:network? network?
                       #:params params)))

(define (job-envelope->alist e)
  `(("kind"        . ,(symbol->string (job-envelope-kind e)))
    ("bridgeJobId" . ,(job-envelope-bridge-job-id e))
    ("image"       . ,(job-envelope-image e))
    ("entrypoint"  . ,(job-envelope-entrypoint e))
    ("inputHash"   . ,(job-envelope-input-hash e))
    ;; a vector on the wire decodes to a vector in the browser — a bare '()
    ;; here would cross as one too, but as the tagged record the JSON
    ;; writer can't carry
    ("caps"        . ,(let ((c (job-envelope-caps e)))
                        (if (vector? c) c (list->vector (or c '())))))
    ("network"     . ,(job-envelope-network? e))
    ("params"      . ,(job-envelope-params e))))
