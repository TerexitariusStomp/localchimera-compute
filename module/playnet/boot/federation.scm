;;; module/playnet/boot/federation.scm — this gateway on the wire: its federations' desks, the founding commune as a peer, the status the static server reads.

(define-module (playnet boot federation)
  #:use-module ((playnet boot restore) #:select (restored-aid restored-kind restored-ref restored-vat))
  #:use-module ((playnet boot site) #:select (data-path log!))
  #:use-module ((playnet federation federate) #:select (census-credential federation-boot! scope-signer serve-federation!
                                                        told-at-now))
  #:use-module ((playnet federation host) #:select (berth-sturdyref berth-swiss! keep! read-kept wire-handshake))
  #:use-module ((playnet federation scope-graph) #:select (current-scope-graph))
  #:use-module ((playnet federation sturdyref-credential) #:select (spec-goods))
  #:use-module ((playnet federation wire) #:select (signer-aid signer-of))
  #:use-module ((playnet keri bridge) #:select (keri-connected?))
  #:use-module ((playnet keri citizen-sig) #:select (make-keri-identity))
  #:use-module ((playnet keys peers) #:select (known-uc-aid))
  #:use-module ((playnet utils common) #:select (parse-csv-env))
  #:use-module ((playnet vf schemas) #:select (resource-specification-default-unit-of-resource))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((rnrs bytevectors) #:select (make-bytevector))
  #:export (serve-federations! write-federation-status! federate-founding-commune!))

;; Every federation this gateway holds answers for itself on the wire
;; (federation/federate.scm `serve-federation!`): a desk that hands a
;; member the spec — the credentials that stand, signed under the
;; federation's AID — and the fold its members tell, each at a
;; sturdyref that stands across restarts. The desk's sturdyref is kept
;; at federation-desk/<aid>/sref.txt, what a commune names beside the
;; federation's AID in its federation.scm.
(define (serve-federations! restored mycapn ws-netlayer)
  (for-each
   (lambda (r)
     (let ((aid (restored-aid r)) (ref (restored-ref r)))
       (when (eq? (restored-kind r) 'federation)
         (catch #t
           (lambda ()
             (with-vat (restored-vat r)
               (when ($ ref 'has-keypair?)
                 (let ((dir (data-path (string-append "federation-desk/" aid))))
                   (on (serve-federation! ref (scope-signer aid ref) mycapn ws-netlayer dir)
                       (lambda (served)
                         (keep! (string-append dir "/sref.txt") (assq-ref served 'sturdyref))
                         (log! "  [gateway] federation ~a answers at ~a~%"
                               aid (assq-ref served 'sturdyref))))))))
           (lambda (k . a)
             (log! "  [gateway] federation desk for ~a failed: ~a ~a~%" aid k a))))))
   restored))

;; ── Federation-status snapshot for /federation-status.json ─────
;; Boot timestamp + summary written to disk so serve-static (in
;; its own process, no libsodium deps) can render the health
;; endpoint without calling back into the gateway vat.
(define (write-federation-status! auditors watchers)
  (catch #t
    (lambda ()
      (let ((status-file (data-path "federation-status.scm")))
        (call-with-output-file status-file
          (lambda (port)
            (write
             `((boot-time . ,(current-time))
               (peers . ,(length (parse-csv-env "PLAYNET_PEERS")))
               ;; the UPWARD parent (PLAYNET_UC_AID) — the UC another
               ;; gateway's federations push membership to. Empty on the
               ;; UC's own gateway, which is correct and used to read as
               ;; "no UC": the LOCAL UC rides the JSON as `local-uc`,
               ;; joined in by serve-static from universal-commune-aid.txt.
               (federation-parent-uc . ,(or (known-uc-aid) #f))
               (keri-connected? . ,(catch #t
                                     (lambda () (keri-connected?))
                                     (lambda _ #f)))
               (auditors . ,(length auditors))
               (custody-watchers . ,(length watchers)))
             port)
            (newline port)))))
    (lambda (key . args)
      (log! "  [gateway] federation-status write error: ~a ~a~%"
            key args))))

(define* (federate-founding-commune! #:key planner-vat planner-service store fc-aid fc-scope mycapn ws-netlayer)
  "The founding commune on the wire (federation/federate.scm): a peer of the
federated solve, when the data directory holds federation.scm — the
commune's demand, and the federation it answers to: `federation` its AID
with `desk` the sturdyref it answers at (the spec is asked of the federation
itself), `federation` alone for one this gateway holds (its store answers),
or the spec written out (issuer, goods, roster, credentials, tell). Its
berth stands from the first boot, before any spec."
  (with-vat planner-vat
    (let* ((spec (read-kept (data-path "federation.scm")))
           (state-dir (data-path "federation"))
           (say (lambda (m) (log! "  [gateway] federation ~a~%" m))))
      ;; who signs on the wire: the scope, through its own
      ;; key; PLAYNET_FED_SEED (a byte) stands in for a scope
      ;; without one — the synthetic backend, a dev run
      (define signer
        (delay
          (cond ((and fc-scope ($ fc-scope 'has-keypair?)) (scope-signer fc-aid fc-scope))
                ((getenv "PLAYNET_FED_SEED")
                 => (lambda (b)
                      (log! "  [gateway] federation peer signs under a DEV identity (PLAYNET_FED_SEED)~%")
                      (make-keri-identity (make-bytevector 32 (string->number b)))))
                (else (error "the founding commune has no key to sign on the wire with")))))
      (define (federation-signer) (force signer))
      ;; the founding commune's berth: its peer's sturdyref
      ;; stands from the first boot, before any spec, kept
      ;; with the AID it speaks under — what a federation
      ;; admits it with
      (on (berth-sturdyref ws-netlayer (berth-swiss! state-dir))
          (lambda (s)
            (let ((aid (false-if-exception (signer-aid (signer-of (federation-signer))))))
              (keep! (data-path "federation-sref.txt") (list s aid))
              (log! "  [gateway] federation berth at ~a, speaking as ~a (handshake ~a)~%"
                    s aid (wire-handshake)))))
      ;; the goods that cross for this commune, by the AID it
      ;; speaks under: the one the federation admitted
      (define (record-of from)
        (let ((rec ($ planner-service 'scope-record fc-aid
                     (spec-goods from (signer-aid (signer-of (federation-signer))))
                     (assq-ref spec 'demand))))
          (unless (eq? (car rec) 'ok) (error "scope-record" (cdr rec)))
          (cdr rec)))
      ;; what this commune deals in, read off its records
      (define (census)
        (let ((c ($ planner-service 'census fc-aid (assq-ref spec 'demand))))
          (and (eq? (car c) 'ok) (cdr c))))
      ;; the unit a good crosses in: its specification's own, off the commune's
      ;; recipe store
      (define (crossing-unit good)
        (or (false-if-exception
             (let* ((root ($ planner-service 'scope-root-ref fc-aid))
                    (sp ($ ($ root 'recipe-store) 'get-resource-spec good)))
               (and sp (resource-specification-default-unit-of-resource sp))))
            "kg"))
      (define (failed k . a) (log! "  [gateway] federation peer failed: ~a ~a~%" k a))
      (define (boot! spec)
        (catch #t
          (lambda ()
            (on (federation-boot! record-of (federation-signer) mycapn ws-netlayer
                                  state-dir spec #:log say
                                  #:census (census)
                                  ;; a crossing that settles leaves its record in
                                  ;; this gateway's store, signed through the scope
                                  #:custody (list (cons 'store store)
                                                  (cons 'scope (and fc-scope ($ fc-scope 'has-keypair?) fc-scope))
                                                  (cons 'unit-of crossing-unit)))
                (lambda (fed)
                  (on (assq-ref fed 'sturdyref)
                      (lambda (s) (log! "  [gateway] federation peer at ~a~%" s)))
                  (on (assq-ref fed 'joined)
                      (lambda (joined)
                        (log! "  [gateway] federation peer started, ~a of ~a ends joined~%"
                              (length joined) (length (assq-ref fed 'ends))))))
                #:catch (lambda (e) (failed 'boot e))))
          failed))
      (when (and fc-scope spec)
        (let ((fed-aid (assq-ref spec 'federation)) (g (current-scope-graph)))
          (if (and fed-aid g (not (assq-ref spec 'desk)))
              ;; a federation in this graph: the census is told to
              ;; its scope directly, and its spec read off its store
              (let ((fed-ref (<- g 'find-ref fed-aid)))
                (on (if (census)
                        (<- fed-ref 'accept-census
                            (census-credential (federation-signer) fed-aid (census) (told-at-now)
                                               #:units (map (lambda (g) (cons g (crossing-unit g))) (census))))
                        #t)
                    (lambda (_)
                      (on (<- fed-ref 'federation-spec)
                          (lambda (from-store) (boot! (append spec from-store)))
                          #:catch (lambda (e) (log! "  [gateway] federation ~a answers no spec: ~a~%" fed-aid e))))
                    #:catch (lambda (e) (log! "  [gateway] federation ~a takes no census: ~a~%" fed-aid e))))
              (boot! spec)))))))
