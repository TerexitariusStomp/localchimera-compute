;;; test-keri-backend.scm — verify ^scope dispatches recomposition through keri-backend
;;;
;;; The unified ^scope actor accepts an optional `keri-backend` alist. When
;;; bound, merge/split call into the backend instead of producing synthetic
;;; AIDs. This test uses the stub-keri-backend (records calls) to verify
;;; the dispatch path is exercised correctly without touching KERIA.

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (srfi srfi-1))
(use-modules (playnet governance scope) (playnet keri acdc-store))
(use-modules (playnet governance keri-backend))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. merge-with dispatches to backend's create-group + rotate-keys
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. merge-with via keri-backend ──\n")

(with-vat vat
  (let* ((events (cons 'events '()))
         (backend (stub-keri-backend events))
         (store-a (spawn-acdc-store))
         (store-b (spawn-acdc-store))
         (root-a (spawn-scope-root "A"))
         (root-b (spawn-scope-root "B"))
         (scope-a (spawn-scope "A"
                               #:kind 'commune
                               #:scope-root-ref root-a
                               #:scope-aid "E_a"
                               #:acdc-store store-a
                               #:keri-backend backend))
         (scope-b (spawn-scope "B"
                               #:kind 'commune
                               #:scope-root-ref root-b
                               #:scope-aid "E_b"
                               #:acdc-store store-b))
         (gov-cap ($ scope-a 'mint-gov-cap "E_a"))
         (combined-aid ($ scope-a 'merge-with scope-b gov-cap)))

    (check-pred "combined-aid is from backend (E_group_*)"
                (and (string? combined-aid)
                     (string-prefix? "E_group_" combined-aid)))

    ;; Backend should have recorded: create-group + 2 rotate-keys (one per predecessor)
    (let ((log (cdr events)))
      (check "3 backend calls recorded" (length log) 3)

      ;; Newest first (record! conses), so:
      ;;   log[0] = rotate-keys E_b
      ;;   log[1] = rotate-keys E_a
      ;;   log[2] = create-group (E_a E_b) 2
      (let ((create-evt (caddr log))
            (rotate-a   (cadr log))
            (rotate-b   (car log)))
        (check "create-group call" (car create-evt) 'create-group)
        (check "create-group members = (E_a E_b)" (cadr create-evt) '("E_a" "E_b"))
        (check "create-group threshold = 2" (caddr create-evt) 2)

        (check "rotate-keys A" (car rotate-a) 'rotate-keys)
        (check "rotate-keys A target" (cadr rotate-a) "E_a")
        (check "rotate-keys B target" (cadr rotate-b) "E_b")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. split dispatches to backend's rotate-keys (parent dissolves)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. split via keri-backend ──\n")

(with-vat vat
  (let* ((events (cons 'events '()))
         (backend (stub-keri-backend events))
         (store (spawn-acdc-store))
         (root (spawn-scope-root "Parent"))
         (scope (spawn-scope "Parent"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "E_parent"
                             #:acdc-store store
                             #:keri-backend backend))
         (gov-cap ($ scope 'mint-gov-cap "E_parent"))
         (sub-aids '("E_sub1" "E_sub2"))
         (result ($ scope 'split sub-aids gov-cap)))

    (check "split returns sub-aids" result sub-aids)

    (let ((log (cdr events)))
      (check "1 rotate-keys call recorded" (length log) 1)
      (check "rotate-keys op" (car (car log)) 'rotate-keys)
      (check "rotate-keys target = parent" (cadr (car log)) "E_parent"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. set-keri-backend rebinds backend post-construction
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. set-keri-backend late binding ──\n")

(with-vat vat
  (let* ((events (cons 'events '()))
         (backend (stub-keri-backend events))
         (store (spawn-acdc-store))
         (root (spawn-scope-root "Late"))
         (scope (spawn-scope "Late"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "E_late"
                             #:acdc-store store)))   ;; no backend at spawn

    (check-pred "no backend initially" (not ($ scope 'keri-backend)))

    ($ scope 'set-keri-backend backend)
    (check-pred "backend bound after set-keri-backend"
                (and ($ scope 'keri-backend) #t))

    ;; Now split should dispatch through backend
    (let* ((gov-cap ($ scope 'mint-gov-cap "E_late"))
           (_      ($ scope 'split '("E_x") gov-cap))
           (log    (cdr events)))
      (check "1 rotate-keys after set-keri-backend" (length log) 1)
      (check "target = E_late" (cadr (car log)) "E_late"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Synthetic fallback when keri-backend = #f (existing behavior preserved)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Synthetic fallback when keri-backend is #f ──\n")

(with-vat vat
  (let* ((store-a (spawn-acdc-store))
         (root-a (spawn-scope-root "A"))
         (root-b (spawn-scope-root "B"))
         (scope-a (spawn-scope "A"
                               #:kind 'commune
                               #:scope-root-ref root-a
                               #:scope-aid "E_a"
                               #:acdc-store store-a))   ;; no backend
         (scope-b (spawn-scope "B"
                               #:kind 'commune
                               #:scope-root-ref root-b
                               #:scope-aid "E_b"))
         (gov-cap ($ scope-a 'mint-gov-cap "E_a"))
         (combined-aid ($ scope-a 'merge-with scope-b gov-cap)))

    (check "synthetic combined-aid" combined-aid "E_merged_A_B")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. split-scope-with-aids helper — backed mode mints AIDs via backend
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. split-scope-with-aids (backed mode) ──\n")

(with-vat vat
  (let* ((events (cons 'events '()))
         (backend (stub-keri-backend events))
         (store (spawn-acdc-store))
         (root (spawn-scope-root "Helper"))
         (scope (spawn-scope "Helper"
                              #:kind 'commune
                              #:scope-root-ref root
                              #:scope-aid "E_helper"
                              #:acdc-store store
                              #:keri-backend backend))
         (gov-cap ($ scope 'mint-gov-cap "E_helper"))
         (sub-aids (split-scope-with-aids scope '("a" "b" "c") gov-cap)))

    (check "3 sub-aids returned" (length sub-aids) 3)
    (check-pred "all sub-aids minted via backend (E_aid_*)"
                (every (lambda (aid)
                         (and (string? aid)
                              (string-prefix? "E_aid_" aid)))
                       sub-aids))

    ;; Backend events: 3 create-aid calls + 1 rotate-keys (parent dissolves)
    (let ((log (cdr events)))
      (check "4 backend calls (3 create-aid + 1 rotate)" (length log) 4)
      ;; Newest first — last one logged is the rotate
      (check "first call recorded was create-aid"
             (car (last log)) 'create-aid))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. split-scope-with-aids helper — synthetic fallback when no backend
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. split-scope-with-aids (synthetic fallback) ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root (spawn-scope-root "Synth"))
         (scope (spawn-scope "Synth"
                              #:kind 'commune
                              #:scope-root-ref root
                              #:scope-aid "E_synth"
                              #:acdc-store store))   ;; no backend
         (gov-cap ($ scope 'mint-gov-cap "E_synth"))
         (sub-aids (split-scope-with-aids scope '("x" "y") gov-cap)))

    (check "2 synthetic sub-aids" sub-aids '("E_split_x" "E_split_y"))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
