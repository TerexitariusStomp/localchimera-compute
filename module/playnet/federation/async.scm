;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/async.scm — the federated solve with no coordinator and no
;;; rounds: every scope a PEER, every good settled between the scopes that
;;; share it, convergence a silence.
;;;
;;; solve-consensus (solve/federation-oracle.scm) runs the ADMM as rounds a
;;; coordinator conducts. But the step on one good (solve/admm-link.scm) needs only
;;; the flows its participants put on it, so the coordinator's work splits
;;; along the goods:
;;;
;;;   ONE participant of a good is its MASTER — the first of them, in an order
;;;   every side reads the same. It holds the good's agreed flows z, its
;;;   scaled dual u (the pull is ρ·u), the penalty weight ρ, and a VERSION v
;;;   that counts the centres it has published. It sends each other
;;;   participant a  centre  message: v, the centre to solve against, the
;;;   agreed flow, the pull. That participant solves and answers with a  flow
;;;   message tagged v. When the master holds every participant's flow at
;;;   version v it takes the step, and publishes v+1 only if the centres moved
;;;   by more than EPS. The step is the exchange problem's (crossing-step), one
;;;   pull for all, whatever the number of participants.
;;;
;;;   Every flow is SIGNED: above nothing its scope supplies the good, below
;;;   it draws. Which a scope does is what its own solve answered against the
;;;   centre it held, so a scope that supplies this season and draws the next
;;;   is the same participant of the same good.
;;;
;;;   a scope's local solve runs whenever one of its centres has changed,
;;;   against the latest centre it holds on every good. Its flows leave tagged
;;;   with the version of the centre each was solved against, so a flow that
;;;   answers a centre already superseded is recognised and dropped.
;;;
;;; What this buys, each a consequence of the shape and none an added rule:
;;;
;;;   No rounds. A good advances at the pace of its own participants; the
;;;   goods of one scope run at different versions and a scope solves against
;;;   whatever it holds — the bounded staleness asynchronous ADMM proves
;;;   convergent, with the bound set by the handshake (one outstanding
;;;   version per good).
;;;   No stale dual. A silent participant stalls its good: no flow arrives,
;;;   no step is taken, z and the pull hold. Nothing integrates a residual
;;;   that is no longer current, and the rest of the federation keeps solving.
;;;   Convergence is quiescence. A step that moves the centres by less than
;;;   EPS publishes nothing, and a flow that moved by less than EPS is not
;;;   re-sent; when every good is quiet there is nothing left to say. The
;;;   federation stays on: a change anywhere sends a ripple that dies out.
;;;   Loss and duplication are harmless. Messages are idempotent under their
;;;   version: an older one is dropped, a repeated centre is answered with the
;;;   scope's last flow, and a master that has waited past its DEADLINE
;;;   re-sends the centre it last published.
;;;   One weight per good. A master balances its own primal and dual residuals
;;;   and rescales ρ on ITS good (and the dual with it, so the pull λ = ρ·u is
;;;   continuous); the new ρ travels in the next centre. A good whose flows
;;;   agree at once keeps the weight it began with, and one that crawls or
;;;   oscillates finds its own.
;;;
;;; The peer is a state machine that takes a message and returns messages. It
;;; owns no network, no clock and no identity: the caller passes the time in,
;;; carries the messages, and (federation/peer.scm) signs them. `simulate` is
;;; that caller in one process, with seeded delays, drops, duplicates and
;;; outages, so the behaviour under a bad network is a property a test asserts.
;;;
;;; A message is an alist with its `kind`, its `link` (the good) and the `form`
;;; its flows are spoken in, and:
;;;   centre   master → participant   to, v, the centre, z, the pull, ρ
;;;   flow     participant → master   from, v, the flow
;;;   want     participant → master   from  (no centre yet — new, or back from a
;;;                                   restart — asking for the one it holds)
;;;   refined  participant → master   from, v, the flow of its exact local solve
;;;   cap      master → participant   to, v, the flow it is held to
;;; `message-heading` says which way one travels; `to` and `from` are the
;;; participant's NAME, which a peer with one counterpart on a good may leave
;;; out. A message whose form is another is dropped: its numbers mean
;;; something else.

(define-module (playnet federation async)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (playnet federation crossing)
  #:export (make-peer message-kind message-link message-heading message-from message-to
            snapshot-stands? federation-of
            assemble-attestations simulate))

;; ── messages ─────────────────────────────────────────────────────────────────
(define (message-ref m k) (let ((a (assq k m))) (and a (cdr a))))
(define (message-kind m) (message-ref m 'kind))
(define (message-link m) (message-ref m 'link))
(define (message-from m) (message-ref m 'from))
(define (message-to m) (or (message-ref m 'to) 'other))
(define (message-heading m)
  "Which way M travels: `participant` (a centre or a cap, from the master) or
   `master` (everything else)."
  (case (message-kind m)
    ((centre cap) 'participant)
    ((flow want refined) 'master)
    (else (error "federation-async: unknown message" m))))

(define (message kind link from to . kvs)
  "A message: its kind and good, who it is from and to (#f: the one counterpart), and the rest."
  (append `((kind . ,kind) (link . ,link) (form . ,*flow-form*))
          (if from `((from . ,from)) '()) (if to `((to . ,to)) '())
          kvs))

(define (snapshot-stands? kept)
  "Whether KEPT (a peer's `snapshot`) speaks its flows in the form this peer
   does, so that a peer may resume from it."
  (and (pair? kept) (eq? (message-ref kept 'form) *flow-form*)))

;; ── the two kinds of end of a crossing ───────────────────────────────────────
;; The master's end is a <crossing> (federation/crossing.scm): the good's state and
;; a member for every participant. A participant's end is a holder.
;; a participant's end: the centre it holds and what it last said about it
(define-record-type <holder>
  (make-holder link c z pull rho v x replied cap)
  holder?
  (link holder-link)
  (c holder-c set-holder-c!) (z holder-z set-holder-z!) (pull holder-pull set-holder-pull!)
  (rho holder-rho set-holder-rho!)
  (v holder-v set-holder-v!)                  ; -1 until the first centre arrives
  (x holder-x set-holder-x!)                  ; the flow from its last solve
  (replied holder-replied set-holder-replied!)  ; the version its last flow message answered
  (cap holder-cap set-holder-cap!))            ; (v . flow): the flow its master holds it to, or #f

;; ── the peer ─────────────────────────────────────────────────────────────────
(define* (make-peer oracle #:key (name #f) (mastering #f) (members '())
                    (rho 4.0) (alpha 1.6) (accel #t) (mmax 8)
                    (adapt #t) (adapt-ratio 10.0) (adapt-max 8) (damping 1.0)
                    (eps 1e-4) (tol 1e-4) (calm 3) (deadline 1.0) (epoch 0) (z0 '())
                    (restore #f))
  "One scope's side of the federated solve. ORACLE is `make-boundary-oracle`
   over the scope's own record.
   Who: NAME says this peer to the others of a good it shares with more than
   one (#f: it is the only counterpart of each). MASTERING the goods it
   masters; MEMBERS ((good name …) …) the other participants of those
   (default: one, anonymous). A good has exactly one master, and whoever
   wires the peers says which: the first participant of the roster, read the
   same on every side. Left unsaid, a peer masters the goods its own column
   can only give (the oracle's `sides`), and a peer with a column that goes
   either way is told.
   How: RHO the prox weight each good starts at; ADAPT whether a master
   rescales its good's ρ by 2 when one of its residuals exceeds ADAPT-RATIO
   times the other, at most ADAPT-MAX times (a finite number of rescalings
   leaves the convergence to the ADMM's own); ALPHA the over-relaxation
   (1 = plain ADMM); DAMPING η ∈ (0,1] the fraction of each step a master takes
   (1 = all of it; the asynchronous-iteration theorems bound η by the delay —
   docs/planning/federation/FEDERATED-SOLVE.md, Rung 4); ACCEL, with history MMAX, Anderson acceleration of each
   good's own iterates; EPS the centre and flow movement below which nothing
   is said; TOL the flow disagreement a good accepts as agreement, and CALM
   how many steps in a row it must hold before the good stops publishing —
   the coordinator's stop, one good at a time: the flows balance to TOL and z
   has stopped moving by TOL.
   Restarts and time: a peer that restarts RESUMES from RESTORE, what its
   `snapshot` answered before, and stands where it stood, at the same
   versions; EPOCH (a clock reading will do) is the number the versions of a
   good count up from when it begins, so the first version of a good that
   begins again outranks every one published before. A RESTORE that speaks
   its flows in another form (`snapshot-stands?`) is set aside whole, and a
   good whose members are others than it kept begins again, each under EPOCH.
   DEADLINE the seconds a master waits on a version before publishing it
   again; Z0 ((good y …) …) the signed flows to start a good it masters at,
   itself first, summing to nothing.
   Returns a procedure taking a message symbol:
     (p 'links)            the goods it shares
     (p 'name) (p 'mastering)  as given / as resolved
     (p 'start now)        → the messages to send
     (p 'deliver m now)    → the messages to send
     (p 'tick now)         → the messages to send (a stalled version, published again)
     (p 'attest)           the peer's standing, as an alist
     (p 'settled?)         #t when every good is quiet
     (p 'done?)            #t when, besides, the local solve at the settled
                           pulls is made and held to what each good allows
     (p 'snapshot)         its state, as atoms: what RESTORE takes
     (p 'deadline)         the seconds a master waits on a version
     (p 'deadline! s)      the deadline raised to S seconds, when it is shorter"
  (define links (oracle 'links))                ; the goods, in the order of the scope's crossings
  (define my-name (or name 'other))
  (define masters-of
    (or mastering
        (let ((sides (oracle 'sides)))
          (when (any (lambda (s) (eq? (cdr s) 'net)) sides)
            (error "federation-async: a peer whose column goes either way is told what it masters" name))
          (filter-map (lambda (s) (and (eq? (cdr s) 'give) (car s))) sides))))
  (define (master? l) (and (member l masters-of) #t))
  (define tuning (make-tuning alpha damping accel mmax adapt adapt-ratio adapt-max eps tol calm))
  (define crossings (make-hash-table))
  (define holders (make-hash-table))
  (for-each
   (lambda (l)
     (if (master? l)
         (let ((others (let ((w (assoc l members))) (if w (cdr w) '(other)))))
           (when (null? others)
             (error "federation-async: a good mastered with nobody to share it" l))
           (hash-set! crossings l
                      (make-crossing l rho epoch (cons my-name others)
                                   (let ((w (assoc l z0))) (and w (cdr w)))
                                   tuning)))
         (hash-set! holders l (make-holder l 0.0 0.0 0.0 rho -1 0.0 -1 #f))))
   links)
  (define (crossing-held l) (hash-ref crossings l))
  (define (holder-of l) (hash-ref holders l))
  (define (all-crossings) (hash-map->list (lambda (k m) m) crossings))
  (define (all-holders) (hash-map->list (lambda (k h) h) holders))

  (define dirty #f)                             ; some centre has changed since the last solve
  (define met 0.0)
  (define stage 'iterating)                     ; iterating → refined → final
  (define report #f)                            ; the oracle's last refine / clamp report

  ;; back from a restart: every good and holder as it was kept, and nothing
  ;; said until a centre or a flow arrives; the finish is remade, since the
  ;; oracle is cold and the exact local solve stands on its own. A good whose
  ;; snapshot does not stand begins again, and says so at the start.
  (define kept (and (snapshot-stands? restore) restore))
  (define resumed '())                          ; the goods mastered here that stand as they were kept
  (when kept
    (for-each (lambda (e) (let ((m (hash-ref crossings (car e))))
                            (when (and m (crossing-restore! m (cdr e)))
                              (set! resumed (cons (car e) resumed)))))
              (cdr (assq 'crossings kept)))
    (for-each (lambda (e)
                (let ((h (hash-ref holders (car e))))
                  (when h
                    (apply (lambda (c z pull rho v x replied cap)
                             (set-holder-c! h c) (set-holder-z! h z) (set-holder-pull! h pull) (set-holder-rho! h rho)
                             (set-holder-v! h v) (set-holder-x! h x) (set-holder-replied! h replied) (set-holder-cap! h cap))
                           (cdr e)))))
              (cdr (assq 'holders kept)))
    (set! met (cdr (assq 'met kept))))

  (define (centre-for m p)
    (message 'centre (crossing-link m) #f (member-name p)
             `(v . ,(crossing-v m)) `(c . ,(member-pub p)) `(z . ,(crossing-agreed m p))
             `(pull . ,(crossing-pull m)) `(rho . ,(crossing-rho m))))
  (define (centres-for m ps) (map (lambda (p) (centre-for m p)) ps))

  ;; the master's step (federation/crossing.scm), and the next version's centres
  ;; when there is one to publish
  (define (advance! m now)
    (let ((r (crossing-advance! m tuning)))
      (if (and (not (eq? r 'idle)) (crossing-publish! m tuning now (eq? r 'rescaled)))
          (begin (set! dirty #t) (centres-for m (crossing-others m)))
          '())))

  ;; the participant's answer for a solve that put the flow X on the good
  (define (answer! h x)
    (let ((v (holder-v h)))
      (if (< v 0)
          '()
          (let ((send? (or (> v (holder-replied h)) (> (abs (- x (holder-x h))) eps))))
            (set-holder-x! h x)
            (if send?
                (begin (set-holder-replied! h v)
                       (list (message 'flow (holder-link h) name #f `(v . ,v) `(x . ,x))))
                '())))))

  (define (rho-alist)
    (map (lambda (l) (cons l (if (master? l) (crossing-rho (crossing-held l)) (holder-rho (holder-of l)))))
         links))

  ;; the local solve, against the latest centre held on every good
  (define (resolve! now)
    (set! dirty #f)
    (set! stage 'iterating)
    (let* ((centres (map (lambda (l)
                           (cons l
                                 (if (master? l)
                                     (member-pub (crossing-self (crossing-held l)))
                                     (holder-c (holder-of l)))))
                         links))
           (reply (oracle 'solve! centres (rho-alist)))
           (flows (cdr (assq 'flows reply))))
      (set! met (cdr (assq 'met reply)))
      (append-map
       (lambda (l)
         (let ((x (exact->inexact (cdr (assoc l flows)))))
           (if (master? l)
               (let* ((m (crossing-held l)) (me (crossing-self m)))
                 (set-member-y! me x)
                 (set-member-tag! me (crossing-v m))
                 (advance! m now))
               (answer! (holder-of l) x))))
       links)))

  (define (solve-while-dirty now out)
    (if dirty (solve-while-dirty now (append out (resolve! now))) out))

  (define (on-centre msg)
    (let ((h (hash-ref holders (message-link msg))) (v (message-ref msg 'v)))
      (cond ((not h) '())
            ((> v (holder-v h))
             (set-holder-c! h (message-ref msg 'c)) (set-holder-z! h (message-ref msg 'z))
             (set-holder-pull! h (message-ref msg 'pull)) (set-holder-rho! h (message-ref msg 'rho))
             (set-holder-v! h v)
             (set! dirty #t)
             '())
            ;; the master asking again: its centre is here, our answer was lost
            ((and (= v (holder-v h)) (= (holder-replied h) v))
             (list (message 'flow (holder-link h) name #f `(v . ,v) `(x . ,(holder-x h)))))
            (else '()))))

  (define (on-want msg)
    (let* ((m (hash-ref crossings (message-link msg)))
           (p (and m (crossing-member m (or (message-ref msg 'from) 'other)))))
      (if p (list (centre-for m p)) '())))

  (define (uninformed-wants)
    (filter-map (lambda (l) (and (not (master? l))
                                 (< (holder-v (holder-of l)) 0)
                                 (message 'want l name #f)))
                links))

  (define (on-flow msg now)
    (let* ((m (hash-ref crossings (message-link msg))) (v (message-ref msg 'v))
           (p (and m (crossing-member m (or (message-ref msg 'from) 'other)))))
      (if (and p (= v (crossing-v m)))
          (begin (set-member-y! p (message-ref msg 'x))
                 (set-member-tag! p v)
                 (advance! m now))
          '())))

  ;; ── the finish ─────────────────────────────────────────────────────────────
  ;; Once every good this scope shares is quiet the pulls have settled, and
  ;; what is left is what solve-decomposed does at its own end, one scope at a
  ;; time: the exact local solve at the settled pulls (refine!), then the
  ;; reconciliation — a scope that draws held to what is supplied (clamp!). The
  ;; pull and the agreed flow of every good are already here: a master holds
  ;; them, and its centre message carried them to the participant. What a
  ;; participant still needs is the flow it is held to: it says what its
  ;; refined solve put on the good (`refined`), and the master, holding every
  ;; participant's, answers each with a `cap` — its own flow for one that
  ;; supplies (an acknowledgement), and for one that draws its flow, cut back
  ;; pro rata when together they draw more than is supplied.
  (define (link-z l) (if (master? l)
                         (let ((m (crossing-held l))) (crossing-agreed m (crossing-self m)))
                         (holder-z (holder-of l))))
  (define (link-pull l) (if (master? l)
                           (crossing-pull (crossing-held l))
                           (holder-pull (holder-of l))))
  (define (flow-of-report rep link) (let ((a (assoc link (cdr (assq 'flows rep))))) (and a (cdr a))))
  (define (held-links) (filter (lambda (l) (not (master? l))) links))
  (define (master-links) (filter master? links))

  (define (adopt! rep) (set! report rep) (set! met (cdr (assq 'met rep))))

  (define (refined-msgs ls)
    (map (lambda (l) (let ((h (holder-of l)))
                       (message 'refined l name #f `(v . ,(holder-v h))
                                `(x . ,(flow-of-report report l)))))
         ls))

  (define (capped? l)
    (if (master? l)
        (and (member-cap (crossing-self (crossing-held l))) #t)
        (let* ((h (holder-of l)) (c (holder-cap h)))
          (and c (= (car c) (holder-v h))))))

  ;; the master's allocation, once every member has refined at this version
  ;; (the master's own refined flow is its member's, put there when it refined)
  ;; → the cap messages for the others whose share is new or moved (all of
  ;; them when ALL?)
  (define (allocate! m all?)
    (let ((changed (and (memq stage '(refined final)) (crossing-allocate! m tuning))))
      (if changed
          (filter-map (lambda (p)
                        (and (or all? (memq p changed))
                             (message 'cap (crossing-link m) #f (member-name p) `(v . ,(crossing-v m)) `(x . ,(member-cap p)))))
                      (crossing-others m))
          '())))

  (define (own-cap l)                  ; the flow this scope is held to on the good
    (if (master? l)
        (member-cap (crossing-self (crossing-held l)))
        (cdr (holder-cap (holder-of l)))))
  (define (overdrawn? l)               ; its plan draws more than it is held to
    (< (flow-of-report report l) (- (own-cap l) 1e-9)))

  ;; the scope held to what each good allows it, where its plan draws more
  (define (maybe-clamp!)
    (if (and (eq? stage 'refined) (every capped? links))
        (begin
          (when (any overdrawn? links)
            (let ((clamped (oracle 'clamp! (map (lambda (l) (cons l (own-cap l))) links))))
              ;; kept only if this scope's floors still close under it
              (when (cdr (assq 'feasible? clamped)) (adopt! clamped))))
          (set! stage 'final)
          '())
        '()))

  (define (maybe-finish!)
    (cond ((and (eq? stage 'iterating) (settled?) (pair? links))
           (adopt! (oracle 'refine!
                           (map (lambda (l) (cons l (link-z l))) links)
                           (map (lambda (l) (cons l (link-pull l))) links)
                           (rho-alist)))
           (set! stage 'refined)
           (for-each (lambda (l) (set-holder-cap! (holder-of l) #f)) (held-links))
           (for-each (lambda (l) (let ((m (crossing-held l)))
                                   (set-member-refd! (crossing-self m)
                                                     (cons (flow-of-report report l) (crossing-v m)))))
                     (master-links))
           (let ((out (append (refined-msgs (held-links))
                              (append-map (lambda (l) (allocate! (crossing-held l) #t)) (master-links)))))
             (maybe-clamp!)
             out))
          (else '())))

  (define (on-cap msg)
    (let ((h (hash-ref holders (message-link msg))) (v (message-ref msg 'v)))
      (when (and h (= v (holder-v h)))
        (let ((old (holder-cap h)))
          (set-holder-cap! h (cons v (message-ref msg 'x)))
          ;; held to less than it had finished under: back to the clamp
          (when (and (eq? stage 'final) old (< (message-ref msg 'x) 0.0)
                     (> (abs (- (cdr old) (message-ref msg 'x))) eps))
            (set! stage 'refined))))
      (maybe-clamp!)
      '()))

  ;; a participant's refined flow reaches its master; the master answers it (and,
  ;; if the allocation moved, everyone whose share did)
  (define (on-refined msg)
    (let* ((m (hash-ref crossings (message-link msg)))
           (p (and m (crossing-member m (or (message-ref msg 'from) 'other)))))
      (if (and p (= (message-ref msg 'v) (crossing-v m)))
          (let ((me (crossing-self m)))
            (set-member-refd! p (cons (message-ref msg 'x) (crossing-v m)))
            (let* ((changed (allocate! m #f))
                   ;; the sender gets its cap again whether or not it changed: a repeat means it was lost
                   (again (and (member-cap p)
                               (not (any (lambda (c) (equal? (message-to c) (member-name p))) changed))
                               (list (message 'cap (crossing-link m) #f (member-name p) `(v . ,(crossing-v m)) `(x . ,(member-cap p)))))))
              ;; the master's own share moved after it had finished: it goes back to the clamp
              (when (and (eq? stage 'final) (member-cap me)
                         (< (flow-of-report report (crossing-link m)) (- (member-cap me) 1e-9)))
                (set! stage 'refined))
              (maybe-clamp!)
              (append (or again '()) changed)))
          '())))

  (define (refined-resends)            ; a participant still waiting on its cap says what it refined again
    (if (eq? stage 'refined)
        (refined-msgs (filter (lambda (l) (not (capped? l))) (held-links)))
        '()))

  (define (holder-quiet? h) (and (>= (holder-v h) 0) (= (holder-replied h) (holder-v h))))
  (define (settled?)
    (and (not dirty)
         (every (lambda (m) (crossing-quiet? m tuning)) (all-crossings))
         (every holder-quiet? (all-holders))))

  (define (plan-flow l fallback)
    (or (and report (memq stage '(refined final)) (flow-of-report report l)) fallback))

  (define (attest)
    `((met . ,met) (settled? . ,(settled?)) (stage . ,stage)
      (feasible? . ,(and report (memq stage '(refined final)) (cdr (assq 'feasible? report)) #t))
      (gap . ,(if (and report (memq stage '(refined final))) (cdr (assq 'gap-bound report)) +inf.0))
      (links . ,(map (lambda (l)
                       (if (master? l)
                           (let* ((m (crossing-held l)) (me (crossing-self m)) (x (member-y me)))
                             `((link . ,l) (master? . #t)
                               (v . ,(crossing-v m)) (x . ,x) (plan . ,(plan-flow l x))
                               (tag . ,(member-tag me)) (z . ,(link-z l))
                               (pull . ,(link-pull l)) (rho . ,(crossing-rho m))
                               (residual . ,(crossing-residual m)) (quiet? . ,(crossing-quiet? m tuning))))
                           (let ((h (holder-of l)))
                             `((link . ,l) (master? . #f)
                               (v . ,(holder-v h)) (x . ,(holder-x h)) (plan . ,(plan-flow l (holder-x h)))
                               (tag . ,(holder-replied h)) (z . ,(holder-z h))
                               (pull . ,(holder-pull h)) (rho . ,(holder-rho h))
                               (quiet? . ,(holder-quiet? h))))))
                     links))))

  (lambda (msg . args)
    (case msg
      ((links) links)
      ((name) name)
      ((mastering) masters-of)
      ((start)
       (let ((now (car args)))
         (for-each (lambda (m) (set-crossing-since! m now)) (all-crossings))
         ;; a resumed good's participants hold its centres already: a version
         ;; still pending goes out again at the deadline, and a neighbour
         ;; that lost its own state asks. A good that begins publishes.
         (let ((out (append-map (lambda (l) (let ((m (crossing-held l))) (centres-for m (crossing-others m))))
                                (remove (lambda (l) (member l resumed)) (master-links)))))
           (set! dirty (pair? out))
           (let ((sent (solve-while-dirty now (append out (uninformed-wants)))))
             (append sent (maybe-finish!))))))
      ((deliver)
       (let* ((m (car args)) (now (cadr args))
              (sent (solve-while-dirty
                     now
                     (case (and (eq? (message-ref m 'form) *flow-form*) (message-kind m))
                       ((#f) '())                     ; spoken in another form: its numbers mean something else
                       ((centre) (on-centre m))
                       ((flow) (on-flow m now))
                       ((want) (on-want m))
                       ((cap) (on-cap m))
                       ((refined) (on-refined m))
                       (else (error "federation-async: unknown message" m))))))
         (append sent (maybe-finish!))))
      ((tick)
       (let ((now (car args)))
         (append
          (append-map (lambda (m)
                        (if (and (crossing-pending? m) (>= (- now (crossing-since m)) deadline))
                            (begin (set-crossing-since! m now)
                                   (centres-for m (filter (lambda (p) (not (= (member-tag p) (crossing-v m))))
                                                          (crossing-others m))))
                            '()))
                      (all-crossings))
          (uninformed-wants)
          (refined-resends)
          (maybe-finish!))))
      ((attest) (attest))
      ((snapshot)
       `((form . ,*flow-form*)
         (crossings . ,(map (lambda (l) (cons l (crossing-snapshot (crossing-held l)))) (master-links)))
         (holders . ,(map (lambda (l)
                            (let ((h (holder-of l)))
                              (cons l (list (holder-c h) (holder-z h) (holder-pull h) (holder-rho h)
                                                  (holder-v h) (holder-x h) (holder-replied h) (holder-cap h)))))
                          (held-links)))
         (met . ,met)))
      ((deadline) deadline)
      ((deadline!) (set! deadline (max deadline (car args))) deadline)
      ((settled?) (settled?))
      ((done?) (and (settled?) (or (null? links) (eq? stage 'final))))
      (else (error "federation-async: unknown message to a peer" msg)))))

;; ── a federation's peers, wired ──────────────────────────────────────────────
(define (federation-of oracles . options)
  "The peers of a federation in one process, over ORACLES in their order: each
   good is mastered by the first of them that shares it, and the others are
   its members. A good two share keeps its one counterpart anonymous; a peer
   on a good more than two share is named by its place in the order. OPTIONS
   are `make-peer`'s keywords, the same for every peer. → the peers, in order."
  (let* ((n (length oracles))
         (links (map (lambda (o) (o 'links)) oracles))
         (sharing (lambda (g) (filter (lambda (i) (member g (list-ref links i))) (iota n))))
         (name-of (lambda (i) (format #f "scope-~a" i)))
         (named? (lambda (i) (any (lambda (g) (> (length (sharing g)) 2)) (list-ref links i)))))
    (map (lambda (o i)
           (let ((mine (filter (lambda (g) (= i (car (sharing g)))) (list-ref links i))))
             (apply make-peer o
                    #:name (and (named? i) (name-of i))
                    #:mastering mine
                    #:members (map (lambda (g)
                                     (cons g (let ((others (cdr (sharing g))))
                                               (if (null? (cdr others)) '(other) (map name-of others)))))
                                   mine)
                    options)))
         oracles (iota n))))

;; ── the federation's standing, from its peers' attestations ──────────────────
;; Each peer says what it holds; a crossing is settled when its participants
;; agree — the same version, flows that balance — and the certificate is the
;; set of those checks. No peer sees the whole; whoever holds the attestations
;; (signed, on the wire) reads the federation off them.
(define* (assemble-attestations attests #:key (tol 1e-3))
  "ATTESTS: each peer's `attest` alist. → an alist:
     settled?    every peer quiet and every good's participants agreeing
     final?      every peer has made its exact local solve and been held to
                 what each good allows it
     met         the mean fill percentage
     consensus   per good, |Σ flows|: what is supplied less what is drawn; the max
     overdraw    per good, what is drawn beyond what is supplied, at the
                 final plans; the max
     feasible?   every peer's floors close on its final plan
     local-bound the sum of the peers' certified gaps
     pulls      ((good . λ) …), the pull its master holds
     stalled     the goods whose participants do not yet agree on a version"
  (let* ((rows (append-map (lambda (a) (cdr (assq 'links a))) attests))
         (get (lambda (r k) (cdr (assq k r))))
         (goods (delete-duplicates (map (lambda (r) (get r 'link)) rows)))
         (of (lambda (g) (filter (lambda (r) (equal? (get r 'link) g)) rows)))
         (masters (lambda (g) (find (lambda (r) (get r 'master?)) (of g))))
         ;; a good is shared once it has a master and another participant
         (crossings (filter (lambda (g) (and (masters g) (> (length (of g)) 1))) goods))
         (agree? (lambda (g) (let ((vs (map (lambda (r) (get r 'v)) (of g))))
                               (every (lambda (v) (= v (car vs))) vs))))
         (imbalance (lambda (g) (abs (fold + 0.0 (map (lambda (r) (get r 'x)) (of g))))))
         (overdrawn (lambda (g) (- (fold + 0.0 (map (lambda (r) (get r 'plan)) (of g))))))
         (final? (every (lambda (a) (eq? (cdr (assq 'stage a)) 'final)) attests)))
    `((settled? . ,(and (every (lambda (a) (cdr (assq 'settled? a))) attests)
                        (every agree? crossings)
                        (every (lambda (g) (<= (imbalance g) tol)) crossings)))
      (final? . ,final?)
      (met . ,(/ (fold + 0.0 (map (lambda (a) (cdr (assq 'met a))) attests)) (max 1 (length attests))))
      (consensus . ,(fold max 0.0 (map imbalance crossings)))
      (overdraw . ,(if final? (fold max 0.0 (map overdrawn crossings)) +inf.0))
      (feasible? . ,(every (lambda (a) (cdr (assq 'feasible? a))) attests))
      (local-bound . ,(fold + 0.0 (map (lambda (a) (cdr (assq 'gap a))) attests)))
      (pulls . ,(map (lambda (g) (cons g (get (masters g) 'pull))) crossings))
      (stalled . ,(remove agree? crossings)))))

;; ── the network, in one process ──────────────────────────────────────────────
;; Seeded, so a run is repeatable: every message gets a random delay, and may
;; be lost or delivered twice; a peer may be cut off for a while. The clock is
;; virtual — a solve costs no time — so what varies is the ORDER in which
;; things arrive, which is what asynchrony is.
(define (lcg-next s) (modulo (+ (* s 1103515245) 12345) 2147483648))

(define* (simulate peers #:key (seed 1) (delay '(0.01 . 0.2)) (drop 0.0) (dup 0.0)
                                (tick 0.5) (horizon 120.0) (outages '()) (restarts '()))
  "Run PEERS (each a `make-peer` procedure) over a simulated network until
   every peer is settled and nothing is in flight, or HORIZON seconds have
   passed. DELAY (lo . hi) seconds per message; DROP and DUP probabilities;
   OUTAGES ((peer-index from to) …): while one is on, everything to and from
   that peer is lost. RESTARTS ((peer-index at make) …): at time AT peer
   PEER-INDEX is replaced by (MAKE) — a process that came back with nothing —
   and started again. → (values settled? time stats peers): stats an alist
   (delivered dropped), PEERS the peers as they stand at the end."
  (define n (length peers))
  (define pv (list->vector peers))
  ;; good → its master's index; and, for a participant addressed by name, its index
  (define master-of (make-hash-table))
  (define named (make-hash-table))
  (define lone (make-hash-table))               ; good → the index of its one anonymous counterpart
  (do ((i 0 (+ i 1))) ((= i n))
    (let ((p (vector-ref pv i)))
      (for-each (lambda (g)
                  (when (hash-ref master-of g)
                    (error "simulate: a good with two masters" g))
                  (hash-set! master-of g i))
                (p 'mastering))
      (for-each (lambda (l)
                  (unless (member l (p 'mastering))
                    (if (p 'name)
                        (hash-set! named (cons l (p 'name)) i)
                        (hash-set! lone l i))))
                (p 'links))))
  ;; a good somebody shares and nobody masters would never be stepped
  (do ((i 0 (+ i 1))) ((= i n))
    (for-each (lambda (l)
                (unless (hash-ref master-of l)
                  (error "simulate: a good with no master" l)))
              ((vector-ref pv i) 'links)))
  (define rng seed)
  (define (uniform!) (set! rng (lcg-next rng)) (/ rng 2147483648.0))
  (define queue '())                            ; (time seq kind . payload), kept in order
  (define seq 0)
  (define in-flight 0)
  (define delivered 0) (define dropped 0)
  (define (before? a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b)))))
  (define (schedule! t kind . payload)
    (set! seq (+ seq 1))
    (let ((ev (cons t (cons seq (cons kind payload)))))
      (set! queue (let ins ((q queue))
                    (if (or (null? q) (before? ev (car q))) (cons ev q) (cons (car q) (ins (cdr q))))))))
  (define (cut? i t)
    (any (lambda (o) (and (= (car o) i) (<= (cadr o) t) (< t (caddr o)))) outages))
  (define (destination m)
    (if (eq? (message-heading m) 'master)
        (hash-ref master-of (message-link m))
        (let ((to (message-to m)))
          (if (eq? to 'other)
              (hash-ref lone (message-link m))
              (hash-ref named (cons (message-link m) to))))))
  (define (send! now from m)
    (let ((to (destination m)))
      (define (once!)
        (set! in-flight (+ in-flight 1))
        (schedule! (+ now (car delay) (* (uniform!) (- (cdr delay) (car delay)))) 'msg to m))
      (cond ((not to) (set! dropped (+ dropped 1)))
            ((< (uniform!) drop) (set! dropped (+ dropped 1)))
            (else (once!) (when (< (uniform!) dup) (once!))))))
  (do ((i 0 (+ i 1))) ((= i n))
    (set! in-flight (+ in-flight 1))
    (schedule! (* (uniform!) (car delay)) 'start i))
  (for-each (lambda (r) (schedule! (cadr r) 'restart (car r) (caddr r))) restarts)
  (schedule! tick 'tick)
  (let loop ((now 0.0))
    (cond
     ((null? queue) (values (every (lambda (p) (p 'done?)) peers) now
                            `((delivered . ,delivered) (dropped . ,dropped)) peers))
     (else
      (let* ((ev (car queue)) (t (car ev)) (kind (caddr ev)) (payload (cdddr ev)))
        (set! queue (cdr queue))
        (cond
         ((> t horizon)
          (values #f t `((delivered . ,delivered) (dropped . ,dropped)) peers))
         ((eq? kind 'restart)
          (let ((i (car payload)))
            (vector-set! pv i ((cadr payload)))
            (set! peers (vector->list pv))
            (for-each (lambda (m) (send! t i m)) ((vector-ref pv i) 'start t))
            (schedule! (+ t tick) 'tick)
            (loop t)))
         ((eq? kind 'tick)
          (if (and (zero? in-flight) (every (lambda (p) (p 'done?)) peers))
              (loop t)
              (begin
                (do ((i 0 (+ i 1))) ((= i n))
                  (unless (cut? i t)
                    (for-each (lambda (m) (send! t i m)) ((vector-ref pv i) 'tick t))))
                (schedule! (+ t tick) 'tick)
                (loop t))))
         (else
          (let ((i (car payload)))
            (set! in-flight (- in-flight 1))
            (if (cut? i t)
                (set! dropped (+ dropped 1))
                (begin
                  (set! delivered (+ delivered 1))
                  (for-each (lambda (m) (send! t i m))
                            (if (eq? kind 'start)
                                ((vector-ref pv i) 'start t)
                                ((vector-ref pv i) 'deliver (cadr payload) t)))))
            (loop t)))))))))
