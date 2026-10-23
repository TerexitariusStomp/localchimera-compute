;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tension-terms.scm — a need's KIND and VOICE, carried as classification terms.
;;;
;;; A citizen's need enters harmony as one of three tensions (tension-kinds.scm):
;;;   floor  a right — a hard wall at the stated quantity
;;;   held   a need  — short at the margin, never zeroed
;;;   des    a want  — set aside for a finite price, quietest rows first
;;; and, among wants (and among held needs), an attached VOICE: the row's total
;;; tension mass, spent from the citizen's conserved purse of emphasis
;;; (docs/planning/identity/truth-telling.md stage 2). The attachment IS the weight —
;;; the statement is the payment. The kind is a classification of the resource
;;; AS NEEDED, so it rides where ValueFlows keeps classifications: the intent's
;;; `resource-classified-as`, beside the folksonomy terms, under a reserved
;;; prefix the affinity matcher's cats reading skips.
;;;
;;;   tension:held   voice:46
;;;
;;; A LEVEL 0..9 term (weight β^level × qty, `priority-weight`) is the
;;; same mass stated on the older ladder; stores still carry them and every
;;; reader honours both. An intent carrying neither reads as a want with no
;;; attachment — every need declared before this vocabulary existed keeps its
;;; meaning.

(define-module (playnet vf facts tension-terms)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf formulas tension-kinds) #:select (priority-weight))   ; β^level — the ladder's one table
  #:export (%tension-kinds tension-term? tension-kind-of tension-level-of
            tension-level-stated? tension-voice-of tension-mass-of
            tension-terms with-tension-terms without-tension-terms
            kind-string->symbol tension-against-of))

(define %tension-kinds '(floor held des))

(define (tension-term? t)
  (and (string? t) (or (string-prefix? "tension:" t)
                       (string-prefix? "level:" t)
                       (string-prefix? "voice:" t))))

(define (kind-string->symbol s)
  "\"floor\" | \"held\" | \"budget\" | anything else → the kind symbol, des by default.
   budget is not a tension: it is the cell a floor stated `against:Γ` lays
   beside itself (tension-against-of), carrying Γ — the fold reads the pair
   as one budgeted floor."
  (cond ((member s '("floor" floor)) 'floor)
        ((member s '("held" held)) 'held)
        ((member s '("budget" budget)) 'budget)
        (else 'des)))

(define (tension-against-of cats)
  "Γ when CATS states `against:Γ` — a floor held against ANY Γ of the sources
   that feed it lost (the budgeted wall, engine lay-budgeted-floors); #f when
   the floor is bare. Stated on a right only; a want or a held need ignores it."
  (let ((t (and (list? cats) (find (lambda (c) (and (string? c) (string-prefix? "against:" c))) cats))))
    (and t (let ((n (string->number (substring t 8)))) (and n (>= n 0) n)))))

(define (tension-kind-of cats)
  "The kind a classification list states; des when it states none."
  (let ((t (and (list? cats) (find (lambda (c) (and (string? c) (string-prefix? "tension:" c))) cats))))
    (if t (kind-string->symbol (substring t 8)) 'des)))

(define (tension-level-stated? cats)
  "Does CATS carry an explicit level:N term? — the line between \"unset\"
   (an old need that never heard of levels, or a want the citizen has not yet
   graded) and \"stated 0\" (graded, lowest). The two read the same number but
   must not fold the same way: an unset want defers to the engine's own
   default (*desire-w0*, full priority — no information is not low priority),
   while a stated 0 is real information and folds at its own weight."
  (and (list? cats) (find (lambda (c) (and (string? c) (string-prefix? "level:" c))) cats) #t))
(define (tension-level-of cats)
  "The level 0..9 a classification list states; 0 when it states none."
  (let ((t (and (list? cats) (find (lambda (c) (and (string? c) (string-prefix? "level:" c))) cats))))
    (if t
        (let ((n (string->number (substring t 6))))
          (if (and n (real? n)) (max 0 (min 9 (inexact->exact (round n)))) 0))
        0)))

(define (tension-voice-of cats)
  "The voice attached to the row — its total tension mass — or #f where none
   is stated (an unattached row, or one graded on the level ladder)."
  (let ((t (and (list? cats) (find (lambda (c) (and (string? c) (string-prefix? "voice:" c))) cats))))
    (and t
         (let ((n (string->number (substring t 6))))
           (and n (real? n) (max 0 (exact->inexact n)))))))

(define (tension-mass-of cats qty)
  "The emphasis CATS states, as MASS: the attached voice, else a level ladder
   row read as β^level × QTY, else #f — nothing stated. The voice/level
   precedence has this one home; every reader supplies its own default on #f
   (the fold's unstated held need, the wire's 0). One walk over CATS."
  (let loop ((cs (if (list? cats) cats '())) (lvl #f) (voice #f))
    (cond (voice voice)
          ((null? cs) (and lvl (* (priority-weight lvl) qty)))
          ((not (string? (car cs))) (loop (cdr cs) lvl voice))
          ((string-prefix? "voice:" (car cs))
           (let ((n (string->number (substring (car cs) 6))))
             (loop (cdr cs) lvl (and n (real? n) (max 0 (exact->inexact n))))))
          ((string-prefix? "level:" (car cs))
           (let ((n (string->number (substring (car cs) 6))))
             (loop (cdr cs) (if (and n (real? n)) (max 0 (min 9 (inexact->exact (round n)))) 0) voice)))
          (else (loop (cdr cs) lvl voice)))))

(define (tension-terms kind voice)
  "The terms for KIND and an attached VOICE (a positive number; the row's
   total tension mass). The default — a want with nothing attached — carries
   nothing. Writers state voice only; the level ladder survives in stores,
   never in a fresh write."
  (let ((k (kind-string->symbol kind))
        (v (and (number? voice) (> voice 0) (exact->inexact voice))))
    (append (if (eq? k 'des) '() (list (string-append "tension:" (symbol->string k))))
            (if v (list (string-append "voice:" (number->string v))) '()))))

(define (without-tension-terms cats)
  (if (list? cats) (remove tension-term? cats) '()))

(define (with-tension-terms cats kind voice)
  "CATS with its tension terms replaced by those for KIND and VOICE."
  (append (without-tension-terms cats) (tension-terms kind voice)))
