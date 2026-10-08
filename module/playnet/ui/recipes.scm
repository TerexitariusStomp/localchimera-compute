;;; recipes.scm — Recipe library + AI-driven workshop, ported from
;;; ~/Programs/planner/src/routes/recipes/+page.svelte.
;;;
;;; A recipe is a production template: a primary output, one or more
;;; ordered processes, and the flows (consume / produce / work) that
;;; connect them. This module is pure: SXML in, SXML out, no DOM
;;; mutation. State (prompt, generated recipes, search query) lives in
;;; hoot/repl.scm and flows in as keyword arguments.

(define-module (playnet ui recipes)
  #:use-module (srfi srfi-1)
  #:export (;; Data
            *starter-recipes*
            *spec-names*
            *example-prompts*
            recipe-generation-system-prompt

            ;; Helpers (exported for caller-side parsing of AI output)
            recipe-from-sexp

            ;; Composed page
            recipes-page))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  SPEC NAMES — display labels for resource-conforms-to slugs
;;; ═══════════════════════════════════════════════════════════════════════════════

(define *spec-names*
  '(("wheat"      . "Wheat")
    ("flour"      . "Flour")
    ("raw-flour"  . "Raw Flour")
    ("dough"      . "Dough")
    ("bread"      . "Bread")
    ("dairy"      . "Dairy")
    ("salt"       . "Salt")
    ("fish"       . "Fish")
    ("ore"        . "Iron Ore")
    ("metal"      . "Iron Metal")
    ("tools"      . "Tools")
    ("goods"      . "Goods")
    ("citrus"     . "Citrus")
    ("olive-oil"  . "Olive Oil")
    ("brine"      . "Brine")))

(define (spec-label slug)
  (or (and slug (assoc-ref *spec-names* slug)) slug))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  STARTER RECIPE LIBRARY — 10 production templates from the federation
;;; ═══════════════════════════════════════════════════════════════════════════════

;;; Recipe alist shape:
;;;   ((id . str) (name . str) (primary-output . str) (note . str)
;;;    (processes . list-of-process-alists)
;;;    (flows     . list-of-flow-alists))
;;;
;;; Process alist:
;;;   ((id . str) (name . str) (sequence-group . int)
;;;    (duration . #f or (value . unit)))
;;;
;;; Flow alist:
;;;   ((id . str)
;;;    (action . symbol)
;;;    (resource-conforms-to . str-or-#f)
;;;    (resource-qty . #f or (value unit))
;;;    (effort-qty   . #f or (value unit))
;;;    (recipe-input-of  . process-id-or-#f)
;;;    (recipe-output-of . process-id-or-#f))

(define (mk-proc id name seq)
  `((id . ,id) (name . ,name) (sequence-group . ,seq) (duration . #f)))

(define* (mk-flow id action #:key (in #f) (out #f) (spec #f) (rqty #f) (eqty #f))
  `((id . ,id) (action . ,action)
    (resource-conforms-to . ,spec)
    (resource-qty . ,rqty) (effort-qty . ,eqty)
    (recipe-input-of . ,in) (recipe-output-of . ,out)))

(define *starter-recipes*
  (list
   ;; ── Bread baking: flour + dairy + salt → dough → bread ──────────────
   `((id . "recipe-bread-baking")
     (name . "Bread Baking")
     (primary-output . "bread")
     (note . "Classic two-stage bake: proof a dough from flour, dairy, salt; then bake.")
     (processes . (,(mk-proc "rp-dough-proofing" "Dough Proofing" 1)
                   ,(mk-proc "rp-baking" "Baking" 2)))
     (flows . (,(mk-flow "f-bb-1" 'consume #:in "rp-dough-proofing" #:spec "flour" #:rqty '(80 "kg"))
               ,(mk-flow "f-bb-2" 'consume #:in "rp-dough-proofing" #:spec "dairy" #:rqty '(30 "kg"))
               ,(mk-flow "f-bb-3" 'consume #:in "rp-dough-proofing" #:spec "salt"  #:rqty '(15 "kg"))
               ,(mk-flow "f-bb-4" 'produce #:out "rp-dough-proofing" #:spec "dough" #:rqty '(90 "kg"))
               ,(mk-flow "f-bb-5" 'consume #:in "rp-baking" #:spec "dough" #:rqty '(90 "kg"))
               ,(mk-flow "f-bb-6" 'work    #:in "rp-baking" #:eqty '(40 "hr"))
               ,(mk-flow "f-bb-7" 'produce #:out "rp-baking" #:spec "bread" #:rqty '(200 "loaf")))))

   ;; ── Grain milling: wheat → raw-flour → flour ────────────────────────
   `((id . "recipe-grain-milling")
     (name . "Grain Milling")
     (primary-output . "flour")
     (note . "Mill whole wheat into raw flour, then sift for the fine grade.")
     (processes . (,(mk-proc "rp-grain-milling" "Grain Milling" 1)
                   ,(mk-proc "rp-flour-sifting" "Flour Sifting" 2)))
     (flows . (,(mk-flow "f-gm-1" 'consume #:in "rp-grain-milling" #:spec "wheat" #:rqty '(200 "kg"))
               ,(mk-flow "f-gm-2" 'work    #:in "rp-grain-milling" #:eqty '(24 "hr"))
               ,(mk-flow "f-gm-3" 'produce #:out "rp-grain-milling" #:spec "raw-flour" #:rqty '(160 "kg"))
               ,(mk-flow "f-gm-4" 'consume #:in "rp-flour-sifting" #:spec "raw-flour" #:rqty '(160 "kg"))
               ,(mk-flow "f-gm-5" 'produce #:out "rp-flour-sifting" #:spec "flour" #:rqty '(150 "kg")))))

   ;; ── Olive pressing ──────────────────────────────────────────────────
   `((id . "recipe-olive-press")
     (name . "Olive Pressing")
     (primary-output . "olive-oil")
     (note . "Cold-press fresh olives into oil.")
     (processes . (,(mk-proc "rp-olive-pressing" "Olive Pressing" 1)))
     (flows . (,(mk-flow "f-op-1" 'work    #:in "rp-olive-pressing" #:eqty '(50 "hr"))
               ,(mk-flow "f-op-2" 'produce #:out "rp-olive-pressing" #:spec "olive-oil" #:rqty '(100 "liter")))))

   ;; ── Ore smithing: ore → metal → tools ───────────────────────────────
   `((id . "recipe-ore-smithing")
     (name . "Ore Smithing")
     (primary-output . "tools")
     (note . "Smelt ore into metal, then forge metal into tools.")
     (processes . (,(mk-proc "rp-ore-smelting" "Ore Smelting" 1)
                   ,(mk-proc "rp-smithing" "Smithing" 2)))
     (flows . (,(mk-flow "f-os-1" 'consume #:in "rp-ore-smelting" #:spec "ore" #:rqty '(120 "kg"))
               ,(mk-flow "f-os-2" 'work    #:in "rp-ore-smelting" #:eqty '(32 "hr"))
               ,(mk-flow "f-os-3" 'produce #:out "rp-ore-smelting" #:spec "metal" #:rqty '(80 "kg"))
               ,(mk-flow "f-os-4" 'consume #:in "rp-smithing" #:spec "metal" #:rqty '(80 "kg"))
               ,(mk-flow "f-os-5" 'work    #:in "rp-smithing" #:eqty '(48 "hr"))
               ,(mk-flow "f-os-6" 'produce #:out "rp-smithing" #:spec "tools" #:rqty '(80 "unit")))))

   ;; ── Wheat harvest ───────────────────────────────────────────────────
   `((id . "recipe-grain-harvest")
     (name . "Wheat Harvest")
     (primary-output . "wheat")
     (note . "Field labour to bring in the grain crop.")
     (processes . (,(mk-proc "rp-wheat-harvest" "Wheat Harvest" 1)))
     (flows . (,(mk-flow "f-wh-1" 'work    #:in "rp-wheat-harvest" #:eqty '(80 "hr"))
               ,(mk-flow "f-wh-2" 'produce #:out "rp-wheat-harvest" #:spec "wheat" #:rqty '(300 "kg")))))

   ;; ── Dairy production ────────────────────────────────────────────────
   `((id . "recipe-dairy-prod")
     (name . "Dairy Production")
     (primary-output . "dairy")
     (note . "Milking and pasteurisation rounds.")
     (processes . (,(mk-proc "rp-dairy-prod" "Dairy Production" 1)))
     (flows . (,(mk-flow "f-dp-1" 'work    #:in "rp-dairy-prod" #:eqty '(40 "hr"))
               ,(mk-flow "f-dp-2" 'produce #:out "rp-dairy-prod" #:spec "dairy" #:rqty '(80 "kg")))))

   ;; ── Fishing ─────────────────────────────────────────────────────────
   `((id . "recipe-fishing")
     (name . "Fishing")
     (primary-output . "fish")
     (note . "Inshore work yielding fresh fish.")
     (processes . (,(mk-proc "rp-fishing" "Fishing" 1)))
     (flows . (,(mk-flow "f-fi-1" 'work    #:in "rp-fishing" #:eqty '(60 "hr"))
               ,(mk-flow "f-fi-2" 'produce #:out "rp-fishing" #:spec "fish" #:rqty '(80 "kg")))))

   ;; ── Salt extraction ─────────────────────────────────────────────────
   `((id . "recipe-salt-extraction")
     (name . "Salt Extraction")
     (primary-output . "salt")
     (note . "Coastal pan evaporation for sea salt.")
     (processes . (,(mk-proc "rp-salt-extraction" "Salt Extraction" 1)))
     (flows . (,(mk-flow "f-se-1" 'work    #:in "rp-salt-extraction" #:eqty '(40 "hr"))
               ,(mk-flow "f-se-2" 'produce #:out "rp-salt-extraction" #:spec "salt" #:rqty '(150 "kg")))))

   ;; ── Citrus harvest ──────────────────────────────────────────────────
   `((id . "recipe-citrus-harvest")
     (name . "Citrus Harvest")
     (primary-output . "citrus")
     (note . "Pick mature citrus from the grove.")
     (processes . (,(mk-proc "rp-citrus-harvest" "Citrus Harvest" 1)))
     (flows . (,(mk-flow "f-ch-1" 'work    #:in "rp-citrus-harvest" #:eqty '(60 "hr"))
               ,(mk-flow "f-ch-2" 'produce #:out "rp-citrus-harvest" #:spec "citrus" #:rqty '(150 "kg")))))

   ;; ── Manufacturing ───────────────────────────────────────────────────
   `((id . "recipe-manufacturing")
     (name . "Manufacturing")
     (primary-output . "goods")
     (note . "Workshop labour producing finished goods.")
     (processes . (,(mk-proc "rp-manufacturing" "Manufacturing" 1)))
     (flows . (,(mk-flow "f-mf-1" 'work    #:in "rp-manufacturing" #:eqty '(60 "hr"))
               ,(mk-flow "f-mf-2" 'produce #:out "rp-manufacturing" #:spec "goods" #:rqty '(60 "unit")))))

   ;; ── Cheese making: dairy + salt → cheese ────────────────────────────
   `((id . "recipe-cheese-making")
     (name . "Cheese Making")
     (primary-output . "cheese")
     (note . "Culture fresh dairy with salt, then press and age.")
     (processes . (,(mk-proc "rp-cheese-curd" "Curdling" 1)
                   ,(mk-proc "rp-cheese-press" "Pressing & Aging" 2)))
     (flows . (,(mk-flow "f-cm-1" 'consume #:in "rp-cheese-curd" #:spec "dairy" #:rqty '(50 "L"))
               ,(mk-flow "f-cm-2" 'consume #:in "rp-cheese-curd" #:spec "salt" #:rqty '(2 "kg"))
               ,(mk-flow "f-cm-3" 'work    #:in "rp-cheese-curd" #:eqty '(8 "hr"))
               ,(mk-flow "f-cm-4" 'produce #:out "rp-cheese-curd" #:spec "curd" #:rqty '(12 "kg"))
               ,(mk-flow "f-cm-5" 'consume #:in "rp-cheese-press" #:spec "curd" #:rqty '(12 "kg"))
               ,(mk-flow "f-cm-6" 'work    #:in "rp-cheese-press" #:eqty '(16 "hr"))
               ,(mk-flow "f-cm-7" 'produce #:out "rp-cheese-press" #:spec "cheese" #:rqty '(10 "wheel")))))

   ;; ── Wool spinning + weaving: wool → cloth ───────────────────────────
   `((id . "recipe-wool-cloth")
     (name . "Wool Cloth")
     (primary-output . "cloth")
     (note . "Spin raw wool into yarn, weave yarn into cloth.")
     (processes . (,(mk-proc "rp-spin" "Spinning" 1)
                   ,(mk-proc "rp-weave" "Weaving" 2)))
     (flows . (,(mk-flow "f-wc-1" 'consume #:in "rp-spin" #:spec "wool" #:rqty '(60 "kg"))
               ,(mk-flow "f-wc-2" 'work    #:in "rp-spin" #:eqty '(28 "hr"))
               ,(mk-flow "f-wc-3" 'produce #:out "rp-spin" #:spec "yarn" #:rqty '(50 "kg"))
               ,(mk-flow "f-wc-4" 'consume #:in "rp-weave" #:spec "yarn" #:rqty '(50 "kg"))
               ,(mk-flow "f-wc-5" 'work    #:in "rp-weave" #:eqty '(32 "hr"))
               ,(mk-flow "f-wc-6" 'produce #:out "rp-weave" #:spec "cloth" #:rqty '(80 "m²")))))

   ;; ── Leather tanning: hide → leather ─────────────────────────────────
   `((id . "recipe-leather-tan")
     (name . "Leather Tanning")
     (primary-output . "leather")
     (note . "Tan raw hides with salt into durable leather.")
     (processes . (,(mk-proc "rp-tan" "Tanning" 1)))
     (flows . (,(mk-flow "f-lt-1" 'consume #:in "rp-tan" #:spec "hide" #:rqty '(40 "kg"))
               ,(mk-flow "f-lt-2" 'consume #:in "rp-tan" #:spec "salt" #:rqty '(5 "kg"))
               ,(mk-flow "f-lt-3" 'work    #:in "rp-tan" #:eqty '(36 "hr"))
               ,(mk-flow "f-lt-4" 'produce #:out "rp-tan" #:spec "leather" #:rqty '(35 "kg")))))

   ;; ── Ale brewing: wheat → malt → ale ─────────────────────────────────
   `((id . "recipe-ale-brewing")
     (name . "Ale Brewing")
     (primary-output . "ale")
     (note . "Malt wheat, then ferment with yeast to brew ale.")
     (processes . (,(mk-proc "rp-malt" "Malting" 1)
                   ,(mk-proc "rp-ferment" "Fermentation" 2)))
     (flows . (,(mk-flow "f-ab-1" 'consume #:in "rp-malt" #:spec "wheat" #:rqty '(80 "kg"))
               ,(mk-flow "f-ab-2" 'work    #:in "rp-malt" #:eqty '(10 "hr"))
               ,(mk-flow "f-ab-3" 'produce #:out "rp-malt" #:spec "malt" #:rqty '(70 "kg"))
               ,(mk-flow "f-ab-4" 'consume #:in "rp-ferment" #:spec "malt" #:rqty '(70 "kg"))
               ,(mk-flow "f-ab-5" 'work    #:in "rp-ferment" #:eqty '(18 "hr"))
               ,(mk-flow "f-ab-6" 'produce #:out "rp-ferment" #:spec "ale" #:rqty '(60 "L")))))

   ;; ── Wine pressing: grapes → wine ────────────────────────────────────
   `((id . "recipe-wine-press")
     (name . "Wine Pressing")
     (primary-output . "wine")
     (note . "Press fresh grapes into juice, ferment slowly into wine.")
     (processes . (,(mk-proc "rp-wine-press" "Wine Pressing" 1)))
     (flows . (,(mk-flow "f-wp-1" 'consume #:in "rp-wine-press" #:spec "grapes" #:rqty '(120 "kg"))
               ,(mk-flow "f-wp-2" 'work    #:in "rp-wine-press" #:eqty '(24 "hr"))
               ,(mk-flow "f-wp-3" 'produce #:out "rp-wine-press" #:spec "wine" #:rqty '(40 "L")))))

   ;; ── Meal preparation (FT): bread + dairy + fish → meals ─────────────
   `((id . "recipe-meal-prep")
     (name . "Tower Meal Preparation")
     (primary-output . "meals")
     (note . "Bakery, dairy and fish combined into prepared meals.")
     (processes . (,(mk-proc "rp-kitchen" "Kitchen Service" 1)))
     (flows . (,(mk-flow "f-mp-1" 'consume #:in "rp-kitchen" #:spec "bread" #:rqty '(60 "loaves"))
               ,(mk-flow "f-mp-2" 'consume #:in "rp-kitchen" #:spec "dairy" #:rqty '(25 "L"))
               ,(mk-flow "f-mp-3" 'consume #:in "rp-kitchen" #:spec "fish" #:rqty '(30 "kg"))
               ,(mk-flow "f-mp-4" 'work    #:in "rp-kitchen" #:eqty '(40 "hr"))
               ,(mk-flow "f-mp-5" 'produce #:out "rp-kitchen" #:spec "meals" #:rqty '(200 "serving")))))

   ;; ── Robot fabrication ───────────────────────────────────────────────
   `((id . "recipe-robot-fab")
     (name . "Robot Fabrication")
     (primary-output . "robots")
     (note . "Design + machine tools + ore → finished robot units.")
     (processes . (,(mk-proc "rp-rb-design" "Robot Design" 1)
                   ,(mk-proc "rp-rb-fab" "Fabrication" 2)))
     (flows . (,(mk-flow "f-rb-1" 'work    #:in "rp-rb-design" #:eqty '(80 "hr"))
               ,(mk-flow "f-rb-2" 'produce #:out "rp-rb-design" #:spec "blueprints" #:rqty '(18 "doc"))
               ,(mk-flow "f-rb-3" 'consume #:in "rp-rb-fab" #:spec "tools" #:rqty '(48 "pcs"))
               ,(mk-flow "f-rb-4" 'consume #:in "rp-rb-fab" #:spec "ore" #:rqty '(35 "kg"))
               ,(mk-flow "f-rb-5" 'consume #:in "rp-rb-fab" #:spec "blueprints" #:rqty '(18 "doc"))
               ,(mk-flow "f-rb-6" 'work    #:in "rp-rb-fab" #:eqty '(120 "hr"))
               ,(mk-flow "f-rb-7" 'produce #:out "rp-rb-fab" #:spec "robots" #:rqty '(18 "unit")))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  EXAMPLE PROMPTS — chips in the workshop
;;; ═══════════════════════════════════════════════════════════════════════════════

(define *example-prompts*
  '("Bake sourdough bread from flour, water, and salt"
    "Forge iron tools from ore and charcoal via smelting and smithing"
    "Press olive oil from fresh olives"
    "Mill wheat into flour using stone grinding"
    "Brew ale from malted barley, hops, and yeast"
    "Cure fish with salt for long-term preservation"
    "Weave linen fabric from flax fibre"
    "Make cheese from fresh dairy milk"))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  AI GENERATION — Scheme-flavoured system prompt
;;; ═══════════════════════════════════════════════════════════════════════════════

(define recipe-generation-system-prompt
  "You generate ValueFlows production recipes as a single Scheme list expression.

The expression must read (via Guile `read`) to an alist of the form:

  ((id . \"recipe-...\")
   (name . \"Display Name\")
   (primary-output . \"resource-slug\")
   (note . \"one-sentence summary\")
   (processes . (((id . \"rp-1\") (name . \"Step name\") (sequence-group . 1) (duration . #f))
                 ...))
   (flows . (((id . \"f-1\") (action . consume)
              (resource-conforms-to . \"slug\")
              (resource-qty . (10 \"kg\")) (effort-qty . #f)
              (recipe-input-of . \"rp-1\") (recipe-output-of . #f))
             ...)))

Rules:
- Each process has a unique id, a name, and a sequence-group integer (1 = first step).
- Each flow has a unique id and references either recipe-input-of OR recipe-output-of with a process id (the other is #f).
- Use action symbols: consume (material input), produce (output), work (labour), use, transfer.
- resource-conforms-to is a short kebab-case slug (e.g. wheat, flour, iron-ore).
- For work flows: effort-qty is set (e.g. (8 \"hr\")), resource-qty is #f.
- For consume/produce flows: resource-qty is set (e.g. (10 \"kg\")), effort-qty is #f.
- primary-output must match the resource-conforms-to of the final produce flow.
- Keep it concise: 1–3 processes, 3–8 flows total.
- Respond with VALID SCHEME ONLY — no markdown fences, no commentary, no JSON.
- The whole response must be one s-expression that `read` consumes in one call.")


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RECIPE PARSING — read AI output → recipe alist (tolerant)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (recipe-from-sexp form)
  "Accept a parsed s-expression that should already be a recipe alist.
   Returns the recipe alist or #f on shape mismatch."
  (and (pair? form)
       (assq 'id form)
       (assq 'processes form)
       (assq 'flows form)
       form))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  HELPERS
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (n->s n)
  (cond ((not n) "")
        ((integer? n) (number->string (inexact->exact n)))
        (else (number->string n))))

(define (assoc-ref alist key . default)
  (let ((p (assq key alist)))
    (cond (p (cdr p))
          ((null? default) #f)
          (else (car default)))))

(define (action-color action)
  (case action
    ((produce)          "#7ee8a2")   ; verb-meant: a display choice per action
    ((consume)          "#fc5858")   ; verb-meant: a display choice per action
    ((work)             "#76c3f5")
    ((transfer)         "#e8b04e")
    ((use move)         "#b0c4f0")
    ((transferAllRights transferCustody transferComplete) "#e8b04e")
    (else "rgba(255,255,255,0.45)")))

(define (sorted-processes procs)
  (sort procs
        (lambda (a b)
          (< (or (assoc-ref a 'sequence-group) 99)
             (or (assoc-ref b 'sequence-group) 99)))))

(define (flows-for-proc flows proc-id key)
  (filter (lambda (f) (equal? (assoc-ref f key) proc-id)) flows))

(define (orphan-flows flows)
  (filter (lambda (f)
            (and (not (assoc-ref f 'recipe-input-of))
                 (not (assoc-ref f 'recipe-output-of))))
          flows))

(define (qty-string q)
  "Format a (value . unit) pair as 'N unit'."
  (cond ((not q) #f)
        ((pair? q)
         (let ((v (car q)) (u (if (pair? (cdr q)) (cadr q) (cdr q))))
           (string-append (n->s v) " " (or u ""))))
        (else #f)))

(define (string-contains-ci? haystack needle)
  "Case-insensitive substring match."
  (let* ((H (%down haystack)) (N (%down needle))
         (hn (string-length H)) (nn (string-length N)))
    (cond ((= nn 0) #t)
          ((> nn hn) #f)
          (else
           (let loop ((i 0))
             (cond ((> (+ i nn) hn) #f)
                   ((string=? (substring H i (+ i nn)) N) #t)
                   (else (loop (+ i 1)))))))))

(define (%down s)
  (let ((out (make-string (string-length s) #\space)))
    (let loop ((i 0))
      (if (= i (string-length s)) out
          (let ((c (string-ref s i)))
            (string-set! out i
                         (if (and (char>=? c #\A) (char<=? c #\Z))
                             (integer->char (+ (char->integer c) 32))
                             c))
            (loop (+ i 1)))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: ACTION BADGE + FLOW ROW
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-action-badge action)
  (let ((c (action-color action)))
    `(span (@ (class "rec-action-badge")
              (style ,(string-append "color:" c ";border-color:" c "40")))
           ,(symbol->string action))))

(define (render-flow-row flow)
  (let* ((action (assoc-ref flow 'action))
         (spec   (assoc-ref flow 'resource-conforms-to))
         (rq     (qty-string (assoc-ref flow 'resource-qty)))
         (eq     (qty-string (assoc-ref flow 'effort))))
    `(div (@ (class "rec-flow-row"))
          ,(render-action-badge action)
          (span (@ (class "rec-flow-spec")) ,(or (spec-label spec) "—"))
          ,(cond (rq `(span (@ (class "rec-flow-qty")) ,rq))
                 (eq `(span (@ (class "rec-flow-qty")) ,eq))
                 (else `(span))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: RECIPE CARD
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-recipe-card recipe show-toggle? on-toggle)
  "Single recipe card. SHOW-TOGGLE? adds an ACTIVE/INACTIVE pill (workshop view)."
  (let* ((name    (assoc-ref recipe 'name))
         (note    (assoc-ref recipe 'note))
         (output  (assoc-ref recipe 'primary-output))
         (active? (assoc-ref recipe 'active #t))
         (procs   (sorted-processes (assoc-ref recipe 'processes '())))
         (flows   (assoc-ref recipe 'flows '())))
    `(div (@ (class ,(string-append "rec-card"
                                    (if active? " rec-card-active" " rec-card-inactive"))))
          (div (@ (class "rec-card-head"))
               (div (@ (class "rec-card-name-wrap"))
                    (span (@ (class "rec-card-name")) ,name)
                    ,@(if output
                          (list `(span (@ (class "rec-card-output"))
                                       ,(spec-label output)))
                          '()))
               ,@(if show-toggle?
                     (list `(span (@ (class ,(string-append "rec-toggle-pill"
                                                            (if active? " rec-pill-on" "")))
                                     (click ,(lambda (e)
                                               (when on-toggle (on-toggle recipe)))))
                                  ,(if active? "ACTIVE" "INACTIVE")))
                     '()))
          ,@(if (and note (not (string=? note "")))
                (list `(div (@ (class "rec-card-note")) ,note))
                '())
          (div (@ (class "rec-proc-section"))
               ,@(map (lambda (p)
                        (let ((pid     (assoc-ref p 'id))
                              (pname   (assoc-ref p 'name))
                              (seq     (assoc-ref p 'sequence-group))
                              (dur     (assoc-ref p 'duration)))
                          `(div (@ (class "rec-proc-block"))
                                (div (@ (class "rec-proc-head"))
                                     ,@(if seq
                                           (list `(span (@ (class "rec-proc-seq"))
                                                        ,(n->s seq)))
                                           '())
                                     (span (@ (class "rec-proc-name")) ,pname)
                                     ,@(if (and dur (pair? dur))
                                           (list `(span (@ (class "rec-proc-dur"))
                                                        ,(qty-string dur)))
                                           '()))
                                ,@(map render-flow-row (flows-for-proc flows pid 'recipe-input-of))
                                ,@(map render-flow-row (flows-for-proc flows pid 'recipe-output-of)))))
                      procs)
               ,@(map (lambda (f)
                        `(div (@ (class "rec-flow-row rec-flow-orphan"))
                              ,(render-action-badge (assoc-ref f 'action))
                              (span (@ (class "rec-flow-spec"))
                                    ,(or (spec-label (assoc-ref f 'resource-conforms-to)) "—"))
                              ,(let ((rq (qty-string (assoc-ref f 'resource-qty)))
                                     (eq (qty-string (assoc-ref f 'effort))))
                                 (cond (rq `(span (@ (class "rec-flow-qty")) ,rq))
                                       (eq `(span (@ (class "rec-flow-qty")) ,eq))
                                       (else `(span))))))
                      (orphan-flows flows))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: LIBRARY (search + cards)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (recipe-matches? recipe q)
  "Does RECIPE match search query Q (substring on name / output / spec)?"
  (let ((name (assoc-ref recipe 'name ""))
        (out  (or (spec-label (assoc-ref recipe 'primary-output)) ""))
        (flow-specs (filter-map (lambda (f)
                                  (spec-label (assoc-ref f 'resource-conforms-to)))
                                (assoc-ref recipe 'flows '()))))
    (or (string-contains-ci? name q)
        (string-contains-ci? out  q)
        (any (lambda (s) (string-contains-ci? s q)) flow-specs))))

(define (render-library recipes search on-search-input)
  (let* ((q (or search ""))
         (filtered (if (string=? (or q "") "")
                       recipes
                       (filter (lambda (r) (recipe-matches? r q)) recipes))))
    `(div (@ (class "rec-library"))
          (div (@ (class "rec-search-area"))
               (input (@ (id "rec-search") (type "text") (class "rec-search-input")
                         (value ,q)
                         (placeholder "Search recipes, outputs, ingredients...")
                         (input ,(lambda (e) (when on-search-input (on-search-input))))))
               (span (@ (class "rec-search-count"))
                     ,(string-append (n->s (length filtered)) " recipe"
                                     (if (= (length filtered) 1) "" "s"))))
          (div (@ (class "rec-cards-area"))
               ,@(if (null? filtered)
                     (list `(div (@ (class "rec-empty"))
                                 "No recipes match. Try a different query, or generate one in the Workshop."))
                     (map (lambda (r) (render-recipe-card r #f #f)) filtered))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: WORKSHOP (prompt + examples + generated cards)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-workshop prompt generating? error-msg generated
                         on-generate on-pick-example on-toggle-active)
  `(div (@ (class "rec-workshop"))
        (div (@ (class "rec-prompt-area"))
             (div (@ (class "rec-examples-row"))
                  (span (@ (class "rec-examples-lbl")) "EXAMPLES")
                  ,@(map (lambda (ex)
                           `(span (@ (class "rec-chip")
                                     (click ,(lambda (e)
                                               (when on-pick-example
                                                 (on-pick-example ex)))))
                                  ,ex))
                         *example-prompts*))
             (div (@ (class "rec-input-row"))
                  (textarea (@ (id "rec-prompt") (class "rec-prompt-input")
                               (rows "3")
                               (placeholder "Describe a production process — inputs, outputs, steps..."))
                            ,(or prompt ""))
                  (span (@ (class ,(string-append "rec-generate-btn"
                                                  (if generating? " rec-generate-busy" "")))
                           (click ,(lambda (e)
                                     (when (and on-generate (not generating?))
                                       (on-generate)))))
                        ,(if generating? "GENERATING..." "GENERATE RECIPE")))
             ,@(if (and error-msg (not (string=? error-msg "")))
                   (list `(div (@ (class "rec-error-msg")) ,error-msg))
                   '()))
        (div (@ (class "rec-cards-area"))
             ,@(if (null? generated)
                   (list `(div (@ (class "rec-empty"))
                               "No recipes yet. Pick an example or type a prompt, then GENERATE."))
                   (map (lambda (r) (render-recipe-card r #t on-toggle-active))
                        generated)))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  COMPOSED PAGE
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (recipes-page #:key (tab 'library)
                             (search "")
                             (prompt "")
                             (generating? #f)
                             (error-msg "")
                             (library *starter-recipes*)
                             (generated '())
                             on-set-tab
                             on-search-input
                             on-generate
                             on-pick-example
                             on-toggle-active)
  "Compose the recipes page. TAB is 'library or 'workshop."
  `(div (@ (class "rec-page"))
        ;; Header
        (div (@ (class "rec-header"))
             (span (@ (class "rec-page-title")) "RECIPES")
             (div (@ (class "rec-tab-row"))
                  (span (@ (class ,(string-append "rec-tab-btn"
                                                  (if (eq? tab 'library) " rec-tab-active" "")))
                           (click ,(lambda (e)
                                     (when on-set-tab (on-set-tab 'library)))))
                        "LIBRARY "
                        (span (@ (class "rec-tab-count"))
                              ,(n->s (length library))))
                  (span (@ (class ,(string-append "rec-tab-btn"
                                                  (if (eq? tab 'workshop) " rec-tab-active" "")))
                           (click ,(lambda (e)
                                     (when on-set-tab (on-set-tab 'workshop)))))
                        "WORKSHOP"
                        ,@(if (null? generated) '()
                              (list `(span (@ (class "rec-tab-count"))
                                           ,(n->s (length generated))))))))
        ;; Body
        ,(case tab
           ((workshop) (render-workshop prompt generating? error-msg generated
                                        on-generate on-pick-example on-toggle-active))
           (else       (render-library library search on-search-input)))))
