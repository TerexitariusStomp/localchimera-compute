;;; tests/gateway/test-corpus-search-degrade.scm — ^lobby's corpus-search /
;;; corpus-domains doors, with NO ^corpus-service configured — the
;;; soft-degrade path a box with no onnxruntime/guile-sqlite3 in its
;;; manifest actually takes.
;;;
;;; A real bug lived here, found by testing this exact path rather than by
;;; review: the degrade reply was `(list 'error "…")` — a flat 2-element
;;; list — while `hoot/day-boot.scm`'s handle-corpus-search/-domains call
;;; `(assq-ref r 'error)` on whatever comes back, and `assq-ref` THROWS on
;;; a non-alist. The exact case this file exists to answer gracefully
;;; (no corpus service configured) was the one case that broke — the
;;; browser's corpusSearch/corpusDomains promise would hang, never
;;; resolving to the "offline" fallback the bridge otherwise provides.
;;;
;;; Every ^lobby argument past ai-svc/presence/etc. here is #f/a stub —
;;; this test exercises ONLY the two corpus doors, with corpus-svc
;;; deliberately omitted (its documented default), not a full lobby.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-corpus-search-degrade.scm

(use-modules (playnet test harness))
(use-modules (goblins) (goblins vat))
(use-modules (playnet gateway lobby))

(define vat (spawn-vat))

(define lobby
  (with-vat vat
    ;; signup-agent ai-svc presence terminal-svc mailbox-mgr planner-service
    ;; wallet-policy governance-svc — none of these are reached by the two
    ;; corpus methods, so #f stands in for all of them; corpus-svc is left
    ;; at its own #:optional default (#f) by simply not passing it.
    (spawn ^lobby #f #f #f #f #f #f #f #f)))

(display "\n── corpus-search, no ^corpus-service configured ──\n")
(let ((r (with-vat vat ($ lobby 'corpus-search "permaculture" "anything" 5))))
  ;; the regression itself: `r` used to be `(list 'error "…")`, a flat
  ;; 2-element list, and `assq-ref` THROWS when given a non-alist —
  ;; simply reaching the checks below without an uncaught exception here
  ;; IS the proof this is fixed
  (check "…carrying a clear, human-readable 'error" (assq-ref r 'error))
  (check "…and it names the actual gap, not a generic failure"
         (string-contains (or (assq-ref r 'error) "") "corpus search is not configured")))

(display "\n── corpus-domains, no ^corpus-service configured ──\n")
(let ((r (with-vat vat ($ lobby 'corpus-domains))))
  (check "the reply is a real alist too" (assq-ref r 'error))
  ;; this is exactly the call hoot/day-boot.scm's handle-corpus-domains
  ;; makes on the reply — proving the shape it actually needs, not a
  ;; hypothetical one
  (check "assq-ref r 'domains is safely #f, not a throw (the real regression)"
         (assq-ref r 'domains) #f))

(test-summary!)
