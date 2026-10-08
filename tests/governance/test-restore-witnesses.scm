;;; test-restore-witnesses.scm — a witness younger than a scope still holds
;;; its log: a restored scope brings every default witness up to date.
;;;
;;; The founding commune and the universal commune were minted before the
;;; oobi-host mirror existed and have been restored on every boot since;
;;; a restored scope used to get a bare kel-store, so the mirror never saw
;;; them and /oobi/{i} had nothing to serve. The kel-store's `witness!` door
;;; hands a joining witness the log it already holds, and spawn-scope uses
;;; it for minted and restored stores alike.
;;;
;;; Run: guile -L module tests/governance/test-restore-witnesses.scm

(use-modules (playnet test harness)
             (playnet governance kel-store) (playnet governance oobi-host-mirror) (playnet governance paths) (playnet governance scope)
             (playnet governance keri-backend live)
             (playnet governance scope-recovery)
             (playnet governance kel-store)
             (playnet gateway oobi-host)
             (playnet keri signify)
             (goblins) (goblins vat)
             (ice-9 format))

(define base-state-dir
  (string-append "/tmp/playnet-restore-witnesses-"
                 (number->string (current-time)) "-"
                 (number->string (random 100000000))))
(setenv "PLAYNET_STATE_DIR" base-state-dir)
(setenv "PLAYNET_VAULT_KEY"
        (let loop ((i 0) (acc "")) (if (= i 32) acc (loop (+ i 1) (string-append acc "ab")))))

(format #t "~%=== a scope minted with no witness, restored with one ===~%")

(define vat (spawn-vat))
(define scope-label #f)
(define scope-i #f)

;; Minted with the default witnesses EMPTY — the world before the mirror.
(with-vat vat
  (parameterize ((default-scope-witnesses '()))
    (let ((s (spawn-scope "elder-commune"
                          #:kind 'commune
                          #:durable? #t
                          #:keri-backend (live-keri-backend))))
      (set! scope-label ($ s 'scope-aid))
      (set! scope-i (kel-event-aid (car ($ s 'kel-events))))
      (check "the scope's log holds its inception" (= 1 (length ($ s 'kel-events))))
      (check "the inception names itself by its SAID (E…)" (string-prefix? "E" scope-i)))))

;; A witness appears after the fact.
(define host   (with-vat vat (spawn ^oobi-host)))
(define mirror (with-vat vat (spawn-oobi-host-mirror host)))

(check "before the restore the witness holds nothing"
       (not (with-vat vat ($ host 'get scope-i))))

(define vat2 (spawn-vat))
(with-vat vat2
  (parameterize ((default-scope-witnesses (list mirror)))
    (let ((s (restore-scope! scope-label
                             #:kind 'commune
                             #:keri-backend (live-keri-backend))))
      (check "restore-scope! produces a ref" (and s #t))
      (check "the restored kel-store lists the witness"
             (member mirror ($ ($ s 'kel-store) 'subscribers))))))

;; `witness!` sends the log with `<-`; give the host's vat a turn.
(define (entry-after-turns)
  (let loop ((n 0))
    (let ((e (with-vat vat ($ host 'get scope-i))))
      (cond ((pair? e) e)
            ((>= n 50) #f)
            (else (usleep 20000) (loop (+ n 1)))))))

(define entry (entry-after-turns))
(check "the witness holds the restored scope's inception, under its own i"
       (and (pair? entry) (equal? scope-i (assq-ref entry 'aid))))
(check "the scope's key label holds no entry"
       (not (with-vat vat ($ host 'get scope-label))))

;; A second restore replays the same events: the entry stays one entry.
(define vat3 (spawn-vat))
(with-vat vat3
  (parameterize ((default-scope-witnesses (list mirror)))
    (restore-scope! scope-label #:kind 'commune #:keri-backend (live-keri-backend))))
(check "a replay leaves the entry whole (no duplicate rotations)"
       (let ((e (entry-after-turns)))
         (and (pair? e) (null? (or (assq-ref e 'rotations) '())))))

(test-summary!)
