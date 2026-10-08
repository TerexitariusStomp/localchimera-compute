;;; test-offer-doors.scm — the doors people use on the commitment arc:
;;; present-offers (a solve's suggestions become offers), accept-regret (what
;;; the standing accepts cost), make-fresh-check (a never-held accept takes
;;; its trial at the door).
;;;
;;; docs/planning/solve/commitment-horizon.md. Fixture: (playnet test planner bread).

(use-modules (playnet test harness)
             (playnet planner vf schemas) (playnet planner beyond scenario) (srfi srfi-1)
             (playnet planner scope live)
             (playnet planner plan accepts)
             (playnet planner doors offers)
             (playnet planner plan store)
             (playnet test planner bread)
             ((playnet utils clock) #:select (now instant->unix))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (bake-hours r) (bread-hours r "bake"))


(display "\n── 1. present-offers: the solve's suggestions become offers ──\n")

(define vat (spawn-vat #:name "present"))
(define-values (scope ps als) (with-vat vat (spawn-bread-scope)))
(define r (with-vat vat (plan-scope->alist scope #:demand '(("bread#town@0" . 4.0))
                                          #:reproduce? #f #:backend 'native-c)))
(define pids (with-vat vat (present-offers scope r)))
(format #t "  suggested rows: ~s~%  offers: ~a for ~a rows~%" (map (lambda (w) (cons (assq-ref w 'input-of) (assq-ref w 'provider))) (assq-ref r 'work)) (length (with-vat vat (open-work-offers scope))) (length pids))
(check "every suggested provider got a directed offer"
       (and (pair? pids) (= (length pids) (length (with-vat vat (open-work-offers scope))))))
(check "re-presenting replaces the standing offers, never duplicates"
       (= (length pids) (length (with-vat vat (begin (present-offers scope r) (open-work-offers scope))))))
;; accept one — its slot leaves the open set and is NOT re-presented
(define pid1 (car pids))
(define agent1 (cadr (string-split (substring pid1 5) #\:)))
(with-vat vat ($ ps 'accept-proposal pid1 `((provider . ,agent1) (receiver . "town"))
                 `((accepting-agent-id . ,agent1))))
(check "an accepted slot is not re-presented"
       (= (- (length pids) 1)
          (length (with-vat vat (begin (present-offers scope r) (open-work-offers scope))))))
(check "#:limit walks fewer, nearest-forcing-first"
       (>= 1 (length (with-vat vat (present-offers scope r #:limit 1)))))


(display "\n── 2. accept-regret: the pin's cost, said in hours ──\n")

(define vat2 (spawn-vat #:name "regret"))
(define-values (scope2 ps2 als2) (with-vat vat2 (spawn-bread-scope)))
;; ONE accept at the solve's own optimum: ada takes ALL the baking the free solve
;; asks for — read off that solve, since a pin fixes the act's count, and the
;; optimum's split of it between ada and bob is arbitrary
(define opt-bake
  (with-vat vat2
    (fold (lambda (w a) (if (equal? "bake" (assq-ref w 'input-of))
                            (+ a (assq-ref w 'effort)) a))
          0.0 (assq-ref (plan-scope->alist scope2 #:demand '(("bread#town@0" . 4.0)) #:reproduce? #f #:backend 'native-c) 'work))))
(format #t "  the free solve's baking by ada: ~,3f h~%" opt-bake)
(with-vat vat2 ($ ps2 'add-commitment
                  (make-commitment #:id "cmt-regret" #:action 'work #:input-of "bake" #:resource-conforms-to "skill-bake"
                                   #:effort-quantity (make-measure opt-bake "hours") #:provider "ada" #:receiver "town" #:at-location "town")))
;; the regret is the pin's, so the program is the chain alone (#:reproduce? #f,
;; as section 1): with the town feeding its people the free solve's optimum is
;; wide and flat, and a pin can read cheaper than a stopped solve by more than
;; the tolerance here
(define r-opt (with-vat vat2 (accept-regret scope2 #:demand '(("bread#town@0" . 4.0)) #:reproduce? #f #:backend 'native-c)))
(format #t "  regret at the optimum: ~s  (pinned ~s h met ~s · free ~s h met ~s)~%" (assq-ref r-opt 'regret-hours)
        (assq-ref r-opt 'hours-pinned) (assq-ref r-opt 'met-pinned) (assq-ref r-opt 'hours-free) (assq-ref r-opt 'met-free))
(check "an accept at the optimum reads ~zero regret" (< (abs (assq-ref r-opt 'regret-hours)) 0.1))
;; the world moves — demand falls to 1 — and the pin cannot follow
(define r-moved (with-vat vat2 (accept-regret scope2 #:demand '(("bread#town@0" . 1.0)) #:reproduce? #f #:backend 'native-c)))
(format #t "  regret off the pin: ~s~%" (assq-ref r-moved 'regret-hours))
(check "when the world moves off the pin, the regret is real and positive"
       (> (assq-ref r-moved 'regret-hours) 1.0))
(check "…and the first-stage delta names the forced columns (bake among them)"
       (let ((d (assq-ref r-moved 'first-stage-delta))) (and (pair? d) (> (or (assoc-ref d "bake") 0) 2.0))))
(check "a singleton world's tilt is trivially the one branch"
       (let ((q (assq-ref r-moved 'regret-tilt))) (and (= 1 (length q)) (< (abs (- (cdar q) 1.0)) 1e-9))))
(define r-two (with-vat vat2 (accept-regret scope2
                #:demand '(("bread#town@0" . 1.0)) #:backend 'native-c #:gamma 1.0
                #:scenarios (list (make-planning-scenario "normal" #f 0.5 '() #f)
                                  (make-planning-scenario "drought" #f 0.5 '(("bake" . 0.5)) #f)))))
(check "two branches: per-branch regret is read off each branch's own program"
       (= 2 (length (assq-ref r-two 'branch-regret))))
(check "…and the regret-tilt is a distribution over them"
       (let ((q (assq-ref r-two 'regret-tilt)))
         (and (= 2 (length q)) (< (abs (- (apply + (map cdr q)) 1.0)) 1e-9)
              (every (lambda (e) (and (> (cdr e) 0) (< (cdr e) 1))) q))))


(display "\n── 3. the fresh check: a never-held accept takes its trial NOW ──\n")

(define vat3 (spawn-vat #:name "fresh"))
(define-values (scope3 ps3 als3) (with-vat vat3 (spawn-bread-scope)))
(with-vat vat3 ($ ps3 'set-fresh-check
                  (make-fresh-check scope3
                    #:solve-opts-thunk (lambda () (list #:demand '(("bread#town@0" . 4.0)) #:backend 'native-c)))))
(define (self-intent id hours)
  (make-intent #:id id #:action 'work #:input-of "mill" #:resource-conforms-to "skill-mill"
               #:effort-quantity (make-measure hours "hours") #:at-location "town"))
(with-vat vat3 ($ ps3 'add-intent (self-intent "self-mill-ok" 1.44)))
(check "a feasible never-held accept passes its trial and promotes"
       (string? (with-vat vat3 ($ ps3 'promote-to-commitment "self-mill-ok" '((provider . "ada") (receiver . "town"))))))
(with-vat vat3 ($ ps3 'add-intent (self-intent "self-mill-big" 1000.0)))
(check "an infeasible one is refused AT the door — not by the next solve"
       (raises? (lambda () (with-vat vat3 ($ ps3 'promote-to-commitment "self-mill-big" '((provider . "ada") (receiver . "town")))))))
;; a HELD intent skips the check — its wall rode the solves already
(with-vat vat3 ($ ps3 'set-fresh-check (lambda (it) "refuse everything")))
(define held-pid (with-vat vat3 (offer-work scope3 '((input-of . "grow") (effort . 0.5)) "farmer")))
(check "a held offer's accept skips the fresh check entirely"
       (assq-ref (with-vat vat3 ($ ps3 'accept-proposal held-pid '((provider . "farmer") (receiver . "town"))
                                   '((accepting-agent-id . "farmer"))))
                 'agreement-id))

(test-summary!)
