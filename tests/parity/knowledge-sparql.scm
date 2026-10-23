;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/knowledge-sparql.scm — knowledge ↔ Jena parity.
;;; The corpus stays data; the query layer delegates to Fuseki. Invariant
;;; leg pins the SPARQL request the delegate emits for a fixture query;
;;; live leg answers real bindings.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(define fixture-query
  "SELECT ?s ?p WHERE { ?s a <http://playnet/Skill> ; <http://playnet/name> ?p }")

(let ((w (sparql-request fixture-query)))
  (check "sparql request is POST with the query as body, SPARQL-JSON accept"
         (and (equal? (cdr (assoc "method" w)) "POST")
              (equal? (cdr (assoc "accept" w)) "application/sparql-results+json")
              (equal? (cdr (assoc "body" w)) fixture-query)) #t))

(parity-live "PLAYNET_JENA_URL"
  "fuseki answers the fixture query"
  (lambda (endpoint)
    (let ((d (make-sparql-delegate
              "/ds/sparql"
              (%json-http-transport
               endpoint
               #:headers `((content-type . (application/sparql-query))
                           (accept . (,(cons 'application/sparql-results+json '()))))))))
      (let ((a (d fixture-query)))
        (and (pair? a) (< (car a) 300))))))

(test-summary!)
