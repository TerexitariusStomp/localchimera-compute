;;; module/playnet/boot/earth.scm — the planner vat: earth, the planetary economic root, and the founding commune's root under it.
;;;
;;; The persisted root of the planner vat is `earth` — a registry of every
;;; commune's economic scope-root (module/playnet/scope/earth.scm). Each
;;; commune is a durable bundle UNDER earth, so ALL of them survive reboot
;;; with their OWN state; and the ^planner-service reads THIS SAME registry —
;;; one source of truth, no shadow scopes-hm. We root at earth DIRECTLY (no
;;; meeting-scope, no migration); if planner.syrup is an older, incompatible
;;; graph, we start clean (self-heal) — deliberate, there is no legacy
;;; economic state to preserve.

(define-module (playnet boot earth)
  #:use-module ((playnet boot site) #:select (data-path kept-line law-packs log!))
  #:use-module ((playnet mqtt publish) #:select (mqtt-password-file))
  #:use-module ((playnet observation facts-sync) #:select (start-host-facts-sync!))
  #:use-module ((playnet scope earth) #:select (earth-env spawn-earth))
  #:use-module ((goblins persistence-store syrup) #:select (make-syrup-store))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-earth! refresh-priors!))

(define %founding-key "founding-commune")

(define (spawn-earth! registry)
  "Earth in the planner vat, persistent under REGISTRY, and the founding
commune's economic root under it. (values planner-vat earth meeting-scope
fc-key fc-aid-early): the key the founding commune stands under in earth and
its AID when a previous boot minted one."
  (define planner-store-path (data-path "planner.syrup"))
  (define (spawn-earth-vat)
    (spawn-persistent-vat earth-env (lambda () (spawn-earth))
                          (make-syrup-store planner-store-path)
                          #:persistence-registry registry))
  (define-values (planner-vat earth)
    (let ((first (catch #t (lambda () (call-with-values spawn-earth-vat list))
                   (lambda _ #f))))
      (if (and first
               (with-vat (car first)
                 (catch #t (lambda () (equal? ($ (cadr first) 'name) "earth")) (lambda _ #f))))
          (values (car first) (cadr first))
          (begin
            (log! "  [gateway] planner.syrup is not an earth graph — starting clean~%")
            (false-if-exception (delete-file planner-store-path))
            (call-with-values spawn-earth-vat values)))))
  ;; The founding commune "Playnet". On RESTART its AID is on disk, so we key it in
  ;; earth by that AID directly; on a TRUE first boot the AID isn't minted yet, so it
  ;; starts under %founding-key and is rekeyed to its AID once minted (boot/communes)
  ;; — the roster is always keyed by real scope-aids. `meeting-scope` stays the name
  ;; the rest of the boot uses; it now simply comes FROM earth.
  (define fc-aid-early (kept-line (data-path "founding-commune-aid.txt")))
  (define fc-key (or fc-aid-early %founding-key))
  (define meeting-scope
    (with-vat planner-vat ($ earth 'ensure-commune! fc-key "Playnet" (law-packs))))
  ;; Rehydrated scope-roots need their (unserializable) plan→observer callbacks
  ;; re-wired: spawn-scope-root does it on CREATION, but a restored bundle didn't.
  (with-vat planner-vat
    (for-each (lambda (ac)
                (catch #t (lambda () ($ (cdr ac) 'rewire-callbacks)) (lambda _ #f)))
              ($ earth 'all-communes)))

  ;; The machines read themselves into the plan: every host's retained
  ;; five-minute snapshot (tools/dev/host-facts.scm --publish on os.scm's
  ;; mcron timer → playnet/facts/host/<hostname>) syncs into the
  ;; founding commune's live-registry, so plan-scope's solves read each
  ;; machine's reservation-aware free capacity (#:live-avail). Which
  ;; scope stewards the machines is a governed choice; the founding
  ;; commune holds it today. Starts only where the gateway mosquitto
  ;; credential exists (the box writes it at activation) — a dev laptop
  ;; without a broker skips with one line instead of a retry loop.
  (if (file-exists? (mqtt-password-file "gateway"))
      (start-host-facts-sync! planner-vat (lambda () meeting-scope))
      (format #t "[host-facts-sync] no gateway mosquitto credential — host snapshot sync off~%"))
  (values planner-vat earth meeting-scope fc-key fc-aid-early))

(define (refresh-priors! planner-vat meeting-scope)
  "arc-time priors: re-price the scope's located places when the routing
engine's tileset has drifted from the prior file's stamp. Strictly
best-effort — engine down / no located places / module absent all leave the
planner on its geometric fallback (parity)."
  (catch #t
    (lambda ()
      (let ((refresh (module-ref (resolve-interface '(playnet scope live))
                                 'refresh-scope-priors!)))
        (log! "  [gateway] arc-time priors: ~a~%"
              (with-vat planner-vat (refresh meeting-scope)))))
    (lambda (k . args)
      (log! "  [gateway] arc-time priors: skipped (~a)~%" k))))
