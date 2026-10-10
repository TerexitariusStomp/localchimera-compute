;;; audit.scm — needs are facts: the audit of a ratified kind
;;;
;;; truth-telling.md, stage 3. A `held` or `floor` row is the strongest
;;; message in the game — its wall is never zeroed — and its quantity is the
;;; one message the fold cannot price (the cell's summed D sits inside every
;;; co-tenant's tension term; Incentives.lean, finding 1). Most such needs
;;; are checkable ex post: the shoes exist or they do not. So the mechanism
;;; is Becker's — audit with probability π and a consequence F such that
;;; π·F ≥ g, the gain from padding (Audit.lean `truth_dominant_iff`) — and
;;; this file is the pure arithmetic of it. What is declared, what the
;;; observer saw, the verdict, and the rate.
;;;
;;; The rate has one honest reading. The consequence of a false `held` is
;;; the grant withdrawn — protection worth exactly what the row moves in the
;;; others (the burn-meter's reading of it), which is also the ceiling on
;;; what padding it could have bought (`gain_le_externality`). With g and F
;;; the same number, π = 1: every held row is audited. Audits can be RARE
;;; only where the scope's consequence is a multiple k of the row's worth
;;; (every grant of the author's, a standing, …), and then π = 1/k. The
;;; factor is the scope's policy; the arithmetic is here.
(define-module (playnet vf facts audit)
  #:use-module ((playnet vf formulas actions) #:select (using-up-actions))
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:export (audit-rate observed-of audit-verdict conduit-verdict audit-draw plan-welfare))

(cond-expand (guile) (else
  ;; Hoot has no `string-hash`: a page hashes a string by its characters (djb2), which
  ;; is as repeatable as the host's and need not agree with it
  (define (string-hash s n)
    (let loop ((i 0) (h 5381))
      (if (= i (string-length s))
          (modulo h n)
          (loop (+ i 1) (modulo (+ (* h 33) (char->integer (string-ref s i))) 4294967296)))))))


(define (audit-rate gain consequence)
  "Becker's rate: the least π with π·CONSEQUENCE ≥ GAIN, capped at 1. A
   consequence of nothing, or a gain nobody has measured (#f), audits
   always — the unknown lie is the one to look at."
  (cond ((or (not gain) (not consequence) (<= consequence 0.0)) 1.0)
        ((<= gain 0.0) 0.0)
        (else (min 1.0 (/ gain consequence)))))

(define (%instant e)
  (or (economic-event-has-point-in-time e) (economic-event-has-beginning e)
      (economic-event-created e)))

(define* (observed-of events spec who #:key (since #f))
  "What the observer's EVENTS say WHO actually took of SPEC: the summed
   resource quantity of every consume / transfer / deliver-service event on
   the spec that WHO received (a consume names its consumer as provider, a
   transfer as receiver), at or after SINCE (an ISO instant; #f = all)."
  (fold (lambda (e acc)
          (let ((act (economic-event-action e))
                (at  (%instant e)))
            (if (and (equal? (economic-event-resource-conforms-to e) spec)
                     (memq act '(consume transfer deliver-service use))   ; verb-meant: what WHO took — a transfer of rights or custody alone is not counted
                     (or (equal? (economic-event-receiver e) who)
                         (and (memq act using-up-actions) (equal? (economic-event-provider e) who)))
                     (or (not since) (not (string? at)) (string>=? at since)))
                (+ acc (or (and=> (economic-event-resource-quantity e) measure-has-numerical-value) 0))
                acc)))
        0.0 events))

(define* (audit-verdict declared observed #:key (tolerance 0.25))
  "'confirmed when what was taken reaches the declared quantity within
   TOLERANCE (a quarter: a held need is a standing order, not a delivery
   receipt); 'padded otherwise. A row declaring nothing is confirmed."
  (if (or (<= declared 0.0) (>= observed (* declared (- 1.0 tolerance))))
      'confirmed 'padded))

(define (audit-draw . parts)
  "A deterministic draw in [0,1) from PARTS (strings): the same row on the
   same day draws the same number, so a sample is reproducible and nobody
   can re-roll it by asking again."
  (let ((h (string-hash (string-join (map (lambda (p) (format #f "~a" p)) parts) "|") 1000003)))
    (/ h 1000003.0)))

(define* (conduit-verdict delivered consumed #:key (tolerance 0.25))
  "The wants' whole remaining audit territory (quantity-as-a-cap.md): under
   the cap rule a padded ask buys the padder nothing, so the one residue is
   the PAD-AND-GIFT conduit — drawing to the water line and passing the
   surplus around the recipients' own voices. Its signature is DELIVERED
   persistently above CONSUMED: 'conduit when what was delivered exceeds
   what was taken by more than TOLERANCE of itself, 'clear otherwise. A row
   delivered nothing is clear."
  (if (or (<= delivered 0.0) (>= consumed (* delivered (- 1.0 tolerance))))
      'clear 'conduit))

(define (plan-welfare rows)
  "TRUE welfare of a plan over ROWS ((weight true-peak delivered) …):
   Σ w·min(delivered, peak) — the satiated utilities the incentive theorems
   are stated in (QuantityAsCap.lean `u`). The SECOND-BEST reading: evaluate
   two plans over the same true peaks and difference them — what a
   strategyproof rule pays in forgone first-best efficiency (Amorós 2002),
   the frontier's fourth residual currency, as one number."
  (fold (lambda (r acc) (+ acc (* (car r) (min (caddr r) (cadr r))))) 0.0 rows))
