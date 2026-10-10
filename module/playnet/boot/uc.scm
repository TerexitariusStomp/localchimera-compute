;;; module/playnet/boot/uc.scm — the scope graph, the Universal Commune above every root, its curator, and the peers' graphs.
;;;
;;; The UC is the planning-time root above all federation roots. Its members
;;; are *derived* from the orphan set of the current scope-graph — no
;;; enrollment, no manual roster. The curator reconciles the UC's membership
;;; against the graph on a periodic tick.
;;;
;;; Boot sequence:
;;;   1. Spawn ^scope-graph in gateway-vat; hydrate from the scopes
;;;      restored earlier (parents derived from each scope's
;;;      federation-membership ACDCs).
;;;   2. Set the (current-scope-graph) parameter so future
;;;      admit-commune / remove-commune / spawn-scope calls fire
;;;      reactive note-* hooks into it.
;;;   3. Discover the UC: find-universal-commune-aid scans the on-disk
;;;      kind files. If found, pluck the existing ref from the restored
;;;      scopes; else mint a fresh UC.
;;;   4. Persist the UC AID to universal-commune-aid.txt for
;;;      serve-static's /universal-commune.json endpoint.
;;;   5. Mint a gov-cap and spawn ^uc-curator with its periodic tick.

(define-module (playnet boot uc)
  #:use-module ((playnet boot restore) #:select (restored-aid restored-kind restored-ref restored-scope restored-vat))
  #:use-module ((playnet scope actor) #:select (federation-memberships-of-holder))
  #:use-module ((playnet boot site) #:select (data-path keep-line! log!))
  #:use-module ((playnet federation pending-recompositions) #:select (current-pending-recompositions spawn-pending-recompositions))
  #:use-module ((playnet federation remote-scope-poller) #:select (parse-peers-env spawn-remote-scope-poller))
  #:use-module ((playnet federation scope-graph) #:select (^scope-graph aggregating-parent current-graph-vat current-scope-graph))
  #:use-module ((playnet federation uc-curator) #:select (spawn-uc-curator uc-curator-default-interval-sec))
  #:use-module ((playnet federation universal-commune) #:select (spawn-uc-merge-proposals spawn-universal-commune uc-reconcile-action))
  #:use-module ((playnet keys keri-backend live) #:select (live-keri-backend))
  #:use-module ((playnet keys peers) #:select (known-uc-aid))
  #:use-module ((playnet scope recovery) #:select (find-universal-commune-aid))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((srfi srfi-1) #:select (delete-duplicates))
  #:export (stand-universal-commune! poll-remote-scopes!))

(define* (stand-universal-commune! #:key gateway-vat planner-service restored)
  "(values scope-graph universal-commune-ref). Under PLAYNET_SCOPES_DURABLE;
the caller catches a failure."
  (define scope-graph (with-vat gateway-vat (spawn ^scope-graph)))
  ;; Hydrate the graph from disk: each restored scope's kind and
  ;; the parents its own membership credentials name. The edges
  ;; are read in the scope's own vat (a $ on its acdc-store from
  ;; another vat throws) before the graph's turn, so the tree
  ;; stands from the first turn after a restart exactly as the
  ;; admit-commune hooks built it before; the reparent sink below
  ;; replays these edges into the planner's aggregation tree.
  (define (restored-parents r)
    (let ((aid (restored-aid r)))
      (catch #t
        (lambda ()
          (with-vat (restored-vat r)
            (let ((store ($ (restored-ref r) 'acdc-store)))
              (if store
                  (delete-duplicates
                   (map car (federation-memberships-of-holder store aid)))
                  '()))))
        (lambda (key . args)
          (log! "  [scope-graph] parents of ~a unread (~a ~a); it hangs under the UC~%"
                aid key args)
          '()))))
  (let ((parents-of
         (map (lambda (r)
                (list (restored-aid r) (restored-kind r) (restored-parents r) (restored-ref r)))
              restored)))
    (with-vat gateway-vat
      (for-each
       (lambda (row)
         ;; #:ref keeps find-ref answering across restarts — the
         ;; demand fold (socialized-plan-fn #:scope-of) and the
         ;; IPEX grant handler both look restored scopes up here,
         ;; and a hydration that records only the kind silently
         ;; turns the fold off until the next fresh mint.
         ($ scope-graph 'note-spawn (car row) (cadr row) (caddr row)
            #:ref (cadddr row)))
       parents-of))
    (log! "  [gateway] scope-graph hydrated: ~a scope(s), ~a with parents~%"
          (length parents-of)
          (length (filter (lambda (row) (pair? (caddr row))) parents-of))))
  ;; Bind the parameter for the rest of the process. New
  ;; scopes spawned after this point notify the graph via
  ;; the hooks in scope.scm.
  (current-scope-graph scope-graph)
  ;; …and the vat it lives in, so any thread can reach it through
  ;; the one door scope-graph.scm already provides (in-graph-vat).
  (current-graph-vat gateway-vat)
  ;; The aggregation tree follows the credential graph: every
  ;; membership edge the ACDC-backed note-* hooks record fires
  ;; the reparent sink, and the planner's move-scope! carries the
  ;; scope's folds and descents to the new parent (or the UC when
  ;; the parent set empties, or names a scope the planner does
  ;; not aggregate). A scope admitted into several federations
  ;; aggregates under ONE of them, chosen by aggregating-parent
  ;; (scope-graph.scm: the smallest AID), so every boot and every
  ;; edge order projects the same tree. Installing the sink
  ;; replays the hydrated edges through it. Fire-and-forget across
  ;; the vat boundary — the projection is idempotent and the next
  ;; edge corrects it.
  (with-vat gateway-vat
    ($ scope-graph 'set-on-reparent
       (lambda (child parents)
         (<-np planner-service 'move-scope! child
               (aggregating-parent parents)))))
  ;; …and the recomposition-orchestration registry the
  ;; ratification post-admit hook fires into (task #43). The
  ;; hook reaches it through in-graph-vat, so it lives in the
  ;; graph's vat; the boot cell makes it readable from the
  ;; poll fiber the hook runs on.
  (current-pending-recompositions
   (with-vat gateway-vat (spawn-pending-recompositions)))
  ;; Discover/mint UC, mint curator gov-cap, write AID file,
  ;; spawn curator — all inside one with-vat turn so the $
  ;; calls have a syscaller (per the goblins gotcha:
  ;; "No current syscaller" raised by $ outside a vat).
  ;;
  ;; KERIA-aware AID minting: when keri-connect! succeeded
  ;; earlier (KERIA_BRAN was set + agent reachable), pass
  ;; the live keri-backend so the UC mints a REAL AID with
  ;; a real KEL. Otherwise fall back to the synthetic AID
  ;; the test path uses (E_universal_commune) so the rest
  ;; of the boot can still proceed in unconfigured envs.
  ;; Detection: try (live-keri-backend); if KERIA's not
  ;; up, the actual create-scope-aid call throws — caught
  ;; by the caller and logged.
  (define universal-commune-ref
    (let* ((uc-aid-on-disk (find-universal-commune-aid))
           (existing-ref   (and uc-aid-on-disk (restored-scope restored uc-aid-on-disk))))
      (with-vat gateway-vat
        (let ((uc
               (catch #t
                 (lambda ()
                   (spawn-universal-commune
                    #:scope-graph  scope-graph
                    #:existing-ref existing-ref
                    #:durable?     #t
                    #:keri-backend (live-keri-backend)))
                 (lambda (key . args)
                   (log! "  [gateway] live-keri-backend UC mint failed (~a ~a); falling back to synthetic~%" key args)
                   (spawn-universal-commune
                    #:scope-graph  scope-graph
                    #:existing-ref existing-ref
                    #:durable?     #t)))))
          (let ((uc-aid ($ uc 'scope-aid)))
            (log! "  [gateway] universal-commune: ~a (~a)~%"
                  uc-aid (if existing-ref 'restored 'minted))
            ;; Write the AID file that /universal-commune.json reads.
            (let ((aid-file (data-path "universal-commune-aid.txt")))
              (catch #t
                (lambda ()
                  (keep-line! aid-file uc-aid)
                  (log! "  [gateway] wrote ~a~%" aid-file))
                (lambda (key . args)
                  (log! "  [gateway] write UC aid-file failed: ~a ~a~%"
                        key args)))))
          ;; Mint curator gov-cap (in-vat) + spawn curator.
          (let ((gov-cap ($ uc 'mint-gov-cap 'uc-curator)))
            (spawn-uc-curator uc scope-graph gov-cap
                              #:start-ticker? #t
                              #:vat gateway-vat)
            (log! "  [gateway] ^uc-curator running (interval ~as)~%"
                  (uc-curator-default-interval-sec)))
          uc))))
  (values scope-graph universal-commune-ref))

(define* (poll-remote-scopes! #:key gateway-vat planner-vat governance-svc scope-graph uc-ref recognise-root!)
  "Cross-gateway scope ingest: ^remote-scope-poller fetches /scopes from
each PLAYNET_PEERS gateway and feeds new scope-graph entries. With peers
empty the actor still spawns but no-ops on tick — safe default. A peer's
own Universal Commune joins the roots this gateway honours, and a genuine
collision is recorded as a merge proposal for ratification."
  (let ((peers (parse-peers-env))
        ;; In planner-vat (with governance-svc) so the governance
        ;; surface can read `pending` synchronously; the poller's
        ;; callback records into it across the vat via <-np.
        (uc-merge-proposals (with-vat planner-vat
                              (spawn-uc-merge-proposals))))
    ;; Surface UC merge proposals in the governance panel
    ;; (scope-formation decisions).
    (with-vat planner-vat
      ($ governance-svc 'set-uc-proposals! uc-merge-proposals))
    (with-vat gateway-vat
      (spawn-remote-scope-poller
       scope-graph
       #:peers peers
       #:start-ticker? #t
       ;; One-UC-as-gravity: when a peer reports its own Universal
       ;; Commune, reconcile toward unity BY CONSENT — RECORD a
       ;; merge proposal on a genuine collision (drained + ratified
       ;; by UC governance → merge-bottom-up!), no-op if it's
       ;; identical or already lineally unified with ours.
       #:on-peer-uc
       (lambda (peer-uc-aid)
         ;; a PEER is the operator's word that another graph is
         ;; ours to recognise: its Universal Commune joins the
         ;; roots this gateway honours — multi-root
         ;; cross-recognition, so a personhood chaining to a
         ;; peer's root is a person here, and a bundle carrying
         ;; that root's blessing is checkable here
         (recognise-root! peer-uc-aid)
         (when uc-ref
           (let* ((my-uc  (known-uc-aid))
                  (store  ($ uc-ref 'acdc-store))
                  (action (uc-reconcile-action store my-uc peer-uc-aid)))
             (when (eq? (car action) 'propose-merge)
               ;; cross-vat: fire-and-forget (dedup is in the registry)
               (<-np uc-merge-proposals 'propose my-uc peer-uc-aid)
               (log! "  [gateway] UC collision: peer ~a ≠ ours ~a — merge proposed for ratification~%"
                     peer-uc-aid my-uc)))))
       #:vat gateway-vat))
    (log! "  [gateway] ^remote-scope-poller running (~a peer(s))~%"
          (length peers))))
