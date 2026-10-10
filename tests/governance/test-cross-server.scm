;;; test-cross-server.scm — cross-server federation via OCapN fake netlayer
;;;
;;; Simulates two servers: server-A hosts a scope-root, server-B hosts
;;; the federation. The federation enlivens server-A's scope via sturdyref
;;; across the fake OCapN network.

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet org endorsement))
(use-modules (playnet governance async) (playnet boot scope) (playnet boot scope) (playnet governance sturdyref-credential) (playnet keri acdc-store))
(use-modules (goblins)
             (goblins vat)
             (goblins utils hashmap)
             (goblins ocapn captp)
             (goblins ocapn netlayer fake)
             (goblins ocapn ids)
             (fibers)
             (fibers channels)
             (fibers conditions)
             (ice-9 atomic)
             (srfi srfi-1))

(setvbuf (current-output-port) 'line)


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Cross-server voice-share-async via fake OCapN
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Cross-server voice-share-async ──\n")

;; Pattern: both servers share one run-fibers context. Server-A registers
;; its scope as a sturdyref. Server-B enlivens it. We use conditions
;; (non-blocking signal) instead of channels for cross-vat sync.

(define sref-box (make-atomic-box #f))
(define sref-ready (make-condition))
(define result-box (make-atomic-box #f))
(define result-ready (make-condition))

(run-fibers
 (lambda ()
   (define net-vat (spawn-vat #:name "net"))
   (define fake-net (with-vat net-vat (spawn ^fake-network)))

   ;; --- Server A: scope with alice=30 ---
   (define server-a-vat (spawn-vat #:name "server-a"))
   (with-vat server-a-vat
     (let* ((ch (make-channel))
            (nl (spawn ^fake-netlayer "sa" fake-net ch))
            (mycapn (spawn-mycapn nl))
            (scope (spawn-scope-root "Farm")))
       (<-np fake-net 'register "sa" ch)
       ($ ($ scope 'account-store) 'add-contribution "alice" 30)
       (on (<- mycapn 'register scope 'fake)
           (lambda (sref)
             (atomic-box-set! sref-box (ocapn-id->string sref))
             (signal-condition! sref-ready)
             'done))))

   ;; Wait for sref outside any vat
   (wait sref-ready)
   (let ((sref-uri (atomic-box-ref sref-box)))

     ;; --- Server B: local scope with bob=70, enliven remote ---
     (define server-b-vat (spawn-vat #:name "server-b"))
     (with-vat server-b-vat
       (let* ((ch (make-channel))
              (nl (spawn ^fake-netlayer "sb" fake-net ch))
              (mycapn (spawn-mycapn nl))
              (local-scope (spawn-scope-root "Workshop")))
         (<-np fake-net 'register "sb" ch)
         ($ ($ local-scope 'account-store) 'add-contribution "bob" 70)
         (on (<- mycapn 'enliven (string->ocapn-id sref-uri))
             (lambda (remote-scope)
               (let ((scope-roots (list local-scope remote-scope)))
                 (on (voice-share-async "alice" scope-roots)
                     (lambda (alice-vs)
                       (on (voice-share-async "bob" scope-roots)
                           (lambda (bob-vs)
                             (atomic-box-set! result-box
                                              (list alice-vs bob-vs))
                             (signal-condition! result-ready)
                             'done)
                           #:promise? #t))
                     #:promise? #t)))))))

   (wait result-ready))
 #:drain? #f)

(let ((result (atomic-box-ref result-box)))
  (check-pred "cross-server alice voice = 3/10"
              (= (list-ref result 0) 3/10))
  (check-pred "cross-server bob voice = 7/10"
              (= (list-ref result 1) 7/10)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Cross-server federation with admit-commune-remote + sturdyref ACDC
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Cross-server federation admit + resolve ──\n")

(define sref-box-2 (make-atomic-box #f))
(define sref-ready-2 (make-condition))
(define result-box-2 (make-atomic-box #f))
(define result-ready-2 (make-condition))

(run-fibers
 (lambda ()
   (define net-vat (spawn-vat #:name "net2"))
   (define fake-net (with-vat net-vat (spawn ^fake-network)))

   ;; --- Server A: commune wrapping scope, alice=60, bob=40 ---
   (define server-a-vat (spawn-vat #:name "server-a2"))
   (with-vat server-a-vat
     (let* ((ch (make-channel))
            (nl (spawn ^fake-netlayer "sa2" fake-net ch))
            (mycapn (spawn-mycapn nl))
            (scope (spawn-scope-root "Watershed"))
            (commune (spawn-commune "Watershed" scope
                                    #:commune-aid "E_watershed_aid")))
       (<-np fake-net 'register "sa2" ch)
       ($ ($ scope 'account-store) 'ensure-account "alice")
       ($ ($ scope 'account-store) 'add-contribution "alice" 60)
       ($ ($ scope 'account-store) 'ensure-account "bob")
       ($ ($ scope 'account-store) 'add-contribution "bob" 40)
       ;; Register the COMMUNE (not bare scope) — it has scope-root method
       (on (<- mycapn 'register commune 'fake)
           (lambda (sref)
             (atomic-box-set! sref-box-2 (ocapn-id->string sref))
             (signal-condition! sref-ready-2)
             'done))))

   (wait sref-ready-2)
   (let ((remote-sref-uri (atomic-box-ref sref-box-2)))

     ;; --- Server B: federation + local scope, carol=100 ---
     (define server-b-vat (spawn-vat #:name "server-b2"))
     (with-vat server-b-vat
       (let* ((ch (make-channel))
              (nl (spawn ^fake-netlayer "sb2" fake-net ch))
              (mycapn (spawn-mycapn nl))
              (local-scope (spawn-scope-root "Bakery"))
              (store (spawn-acdc-store))
              (fed (spawn-federation "River" #:acdc-store store
                                            #:mycapn-ref mycapn))
              (gov-cap ($ fed 'mint-gov-cap "bootstrap")))
         (<-np fake-net 'register "sb2" ch)
         ($ ($ local-scope 'account-store) 'ensure-account "carol")
         ($ ($ local-scope 'account-store) 'add-contribution "carol" 100)
         ;; Admit local commune (near ref — commune wraps scope-root)
         (let ((local-commune (spawn-commune "Bakery" local-scope
                                             #:commune-aid "E_bakery_aid")))
           ($ fed 'admit-commune gov-cap "bakery" local-commune))
         ;; Admit remote commune by sturdyref
         ($ fed 'admit-commune-remote
            gov-cap "watershed" "E_watershed_aid" remote-sref-uri)
         ;; Resolve across OCapN
         (on (<- fed 'resolve-commune "watershed")
             (lambda (remote-commune)
               ($ fed 'store-resolved "watershed" remote-commune)
               (on (<- remote-commune 'scope-root)
                   (lambda (remote-scope)
                     (let ((scope-roots (list local-scope remote-scope)))
                 (on (commune-weight-async fed "bakery" scope-roots)
                     (lambda (bakery-w)
                       (on (commune-weight-async fed "watershed" scope-roots)
                           (lambda (watershed-w)
                             (let ((sref-creds
                                    ($ store 'by-schema
                                       *schema-playnet-federation-sturdyref*)))
                               (atomic-box-set! result-box-2
                                                (list bakery-w watershed-w
                                                      (length sref-creds)))
                               (signal-condition! result-ready-2)
                               'done))
                           #:promise? #t))
                     #:promise? #t))
                   #:promise? #t)))))))

   (wait result-ready-2))
 #:drain? #f)

(let ((result (atomic-box-ref result-box-2)))
  ;; bakery: 100/200 = 1/2, watershed: 100/200 = 1/2
  (check-pred "bakery weight = 1/2"
              (= (list-ref result 0) 1/2))
  (check-pred "watershed weight = 1/2"
              (= (list-ref result 1) 1/2))
  (check-pred "sturdyref ACDC issued"
              (= (list-ref result 2) 1)))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
