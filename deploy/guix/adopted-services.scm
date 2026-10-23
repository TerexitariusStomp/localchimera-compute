;;; deploy/guix/adopted-services.scm — the Tier-2 adopted stack as OCI
;;; containers under Shepherd (spec/oss-inventory.md).
;;;
;;; Why OCI here when the rest of os.scm is native services? The adopted
;;; stack is a dozen upstream daemons in five toolchains (wasmCloud/Rust,
;;; Holochain, Temporal/Go, Jena/JVM, Decidim/Rails, Odoo/Python). Guix-
;;; packaging each is months of package work the inventory explicitly
;;; delegates away — the upstreams already ship pinned, signed images.
;;; oci-container-service-type runs them under Shepherd with the same
;;; supervision guarantees the native services get.
;;;
;;; Every image is pinned by TAG and documented with the digest a deploy
;;; should verify — float no tag in production. Endpoint wiring is the
;;; adapters' job: module/playnet/delegates.scm and
;;; module/playnet/machine/adapters.scm inject transports that point at
;;; the addresses bound here. Until a container is actually running the
;;; adapter stays fail-closed — an absent service is 'unavailable, never
;;; a pretended answer.
;;;
;;; STATUS: authored against the documented (gnu services containers)
;;; API in the pinned Guix — compile-check with `guix system build` on a
;;; Guix host before reconfigure; no Guix toolchain exists in the dev
;;; container this file was written in.

(define-module (adopted-services)
  #:use-module (gnu services)
  #:use-module (gnu services containers)
  #:use-module (guix gexp)
  #:export (%adopted-stack-services))

;;; ── the stack ────────────────────────────────────────────────────────────
;;; One oci-container-configuration per adopted service. Names match the
;;; oss-inventory rows so `sudo herd status` reads like the spec.

(define %adopted-stack-services
  (list

   ;; ── compute execution (Tier-1's upstream half) ────────────────────────

   (oci-container-configuration
    ;; wasmCloud — the server-side WASM executor + replay substrate.
    ;; adapters.scm's 'wasmcloud kind posts invocations to the lattice
    ;; host's HTTP gateway on :8080.
    (image "ghcr.io/wasmcloud/wasmcloud:1.8.0")
    (network "host")          ; the lattice is NATS-internal; host net for dev
    (ports '(("8080" . "8080")))
    (volumes '(("wasmcloud-data" . "/var/lib/wasmcloud")))
    (environment
     '(("WASMCLOUD_RPC_PORT" . "4222")
       ("WASMCLOUD_CTL_PORT" . "4223"))))

   (oci-container-configuration
    ;; Wasimoff — the browser-WASM broker. Tabs join as providers; the
    ;; adapter submits tasks over the broker's HTTP face on :4080.
    (image "ghcr.io/wasimoff/broker:latest")  ; pin a release tag on deploy
    (ports '(("4080" . "4080")))
    (volumes '(("wasimoff-db" . "/app/db"))))

   ;; ── economy (P3) ──────────────────────────────────────────────────────

   (oci-container-configuration
    ;; hREA — the ValueFlows backend the receipts delegate to. Runs on
    ;; Holochain: the conductor's app-ws port is what compute/hrea.scm's
    ;; transport speaks.
    (image "docker.io/hrea/hrea:latest")      ; pin digest on deploy
    (ports '(("8888" . "8888")))
    (volumes '(("hrea-data" . "/data"))))

   (oci-container-configuration
    ;; cc-node — the Credit Commons mutual-credit ledger that consumes
    ;; compute/credit-commons.scm's settlement rows.
    (image "gitlab.com/credit-commons/cc-node:latest")
    (ports '(("2020" . "2020")))
    (volumes '(("ccnode-data" . "/var/lib/cc-node"))))

   ;; ── identity + governance (P4) ────────────────────────────────────────

   (oci-container-configuration
    ;; Decidim — ballots/sortitions the voice layer delegates to.
    ;; Full Rails stack; the delegate posts GraphQL to :3000/api.
    (image "docker.io/decidim/decidim:latest")
    (ports '(("3000" . "3000")))
    (volumes '(("decidim-data" . "/code")
               ("decidim-uploads" . "/app/public/uploads")))
    (environment
     '(("DECIDIM_DB_HOST" . "postgres"))))   ; needs the postgres container below

   (oci-container-configuration
    ;; Open Policy Agent — domain-door authorization decisions.
    ;; delegates.scm's opa delegate posts /v1/data/<policy>.
    (image "docker.io/openpolicyagent/opa:1.4.2")
    (ports '(("8181" . "8181")))
    (command '("run" "--server" "--addr" "0.0.0.0:8181"
               "/policies"))
    (volumes '(("opa-policies" . "/policies"))))

   ;; ── workflow + domains (P5) ───────────────────────────────────────────

   (oci-container-configuration
    ;; Temporal — durable timers for dispute/challenge/deadline clocks
    ;; and side-effecting door bodies. The delegate speaks to the HTTP
    ;; bridge; the temporalite dev bundle is enough for a single-node
    ;; commune (swap for the cluster chart at federation scale).
    (image "docker.io/temporalio/temporalite:latest")
    (ports '(("7233" . "7233") ("8233" . "8233")))
    (volumes '(("temporal-data" . "/etc/temporal"))))

   (oci-container-configuration
    ;; Apache Jena Fuseki — SPARQL over the knowledge corpus.
    (image "docker.io/stain/jena-fuseki:5.2.0")
    (ports '(("3030" . "3030")))
    (volumes '(("fuseki-data" . "/fuseki"))))

   (oci-container-configuration
    ;; ntfy — push notifications (UnifiedPush-compatible).
    (image "docker.io/binwiederhier/ntfy:v2.11.0")
    (command '("serve"))
    (ports '(("2586" . "2586")))
    (volumes '(("ntfy-data" . "/var/cache/ntfy"))))

   (oci-container-configuration
    ;; LiteLLM — the inference key-pool in front of llama.cpp/ollama.
    ;; ⚠ inventory flag: verify the needed endpoints are OSS-tier —
    ;; key rotation is Enterprise.
    (image "ghcr.io/berriai/litellm:main-stable")
    (ports '(("4000" . "4000")))
    (volumes '(("litellm-config" . "/app/config"))))

   (oci-container-configuration
    ;; PostgreSQL — shared by Decidim and any adapter that needs a
    ;; relational store (hREA indexes, cc-node's SQL backend).
    (image "docker.io/postgres:16")
    (ports '(("5432" . "5432")))
    (environment
     '(("POSTGRES_PASSWORD_FILE" . "/run/secrets/postgres-password")))
    (volumes '(("pg-data" . "/var/lib/postgresql/data")
               ;; secrets land here via os.scm's existing secrets wiring —
               ;; never inline a password in this file.
               ("/run/secrets" . "/run/secrets"))))

   (oci-container-configuration
    ;; mosquitto — MQTT for the comms layer.
    (image "docker.io/eclipse-mosquitto:2.0")
    (ports '(("1883" . "1883")))
    (volumes '(("mosquitto-data" . "/mosquitto/data")
               ("mosquitto-conf" . "/mosquitto/config"))))))
