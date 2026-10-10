;;; root-lineage.scm — a root scope's AID across its own recompositions
;;;
;;; The OpenVTC layer asks one question of a deployment: which AIDs ARE this
;;; root across its history? ((playnet keri first-person predicates)'s
;;; set-root-lineage!.) Playnet's root is a scope, and a scope's merge / split
;;; mints a NEW group-inception AID, so the answer is the walk back over
;;; ratified scope-merger and scope-split credentials. Loading this module
;;; installs that walk.
;;;
;;; A module of (playnet governance); the umbrella imports it.

(define-module (playnet governance root-lineage)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet keri acdc-store) #:select (non-revoked-by-schema))
  #:use-module (playnet keri first-person predicates)
  #:use-module ((playnet governance credentials)
                #:select (*schema-playnet-scope-merger* *schema-playnet-scope-split*))
  #:export (%recomposition-ancestors recomposition-lineage))

(define (%recomposition-ancestors aid mergers splits)
  "Immediate ratified recomposition ancestors of AID: predecessors that
   merged INTO it, and the parent it split OUT OF."
  (append
   (append-map
    (lambda (c)
      (if (equal? (cred-claim c 'new-scope-aid) aid)
          (let ((ps (cred-claim c 'predecessors)))
            (if (pair? ps) ps
                (list (cred-claim c 'predecessor-a)
                      (cred-claim c 'predecessor-b))))
          '()))
    mergers)
   (append-map
    (lambda (c)
      (let ((subs (cred-claim c 'sub-scope-aids)))
        (if (and subs (member aid subs))
            (list (cred-claim c 'parent-scope-aid))
            '())))
    splits)))

(define (recomposition-lineage acdc-store root-aid)
  "ROOT-AID plus every ratified recomposition ancestor of it, transitively
   — the set of AIDs that *are* this root across its own history.

   A root is a scope, and merge/split mint a NEW group-inception AID, so a
   blessing issued before the root recomposed was signed by a predecessor
   AID. Matching the whole lineage keeps the personhood graph anchored
   across the root's own merges and splits. Only NON-REVOKED merger/split
   ACDCs extend the set (the same ratified lineage `recover-lineage`
   walks), so a schism with no valid recomposition ACDC does not inherit
   the trust domain. Callers pass the CURRENT root AID; the walk goes
   backward to cover pre-recomposition blessings."
  (if (not acdc-store)
      (list root-aid)
      (let ((mergers (non-revoked-by-schema acdc-store *schema-playnet-scope-merger*))
            (splits  (non-revoked-by-schema acdc-store *schema-playnet-scope-split*)))
        (let loop ((frontier (list root-aid)) (seen '()))
          (cond
           ((null? frontier) (reverse seen))
           ((member (car frontier) seen) (loop (cdr frontier) seen))
           (else
            (let ((ancs (filter (lambda (x) x)
                                (%recomposition-ancestors (car frontier)
                                                          mergers splits))))
              (loop (append (cdr frontier) ancs)
                    (cons (car frontier) seen)))))))))

(set-root-lineage! recomposition-lineage)
