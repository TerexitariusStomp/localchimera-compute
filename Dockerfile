# Dockerfile — Guile + Goblins development environment
#
# Provides the same Guile + Goblins stack declared in guix.scm / manifest.scm,
# built from source so it works on any machine with Docker (including macOS).
#
# Build:  make docker-build
# Test:   make docker-test-planner
# REPL:   make docker-shell
#
# Pin versions below to match the Guix channels pin (deploy/guix/channels.scm).
# When you update channels.scm, verify these ARGs still match.

FROM debian:trixie-slim

# ── Build tools + Guile 3.0.10 ──────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      guile-3.0 guile-3.0-dev guile-gcrypt guile-gnutls \
      autoconf automake libtool texinfo gettext \
      pkg-config make git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── guile-fibers (concurrency, required by Goblins) ─────────────────────
ARG FIBERS_TAG=v1.3.1
RUN git clone --depth 1 --branch ${FIBERS_TAG} \
      https://github.com/wingo/fibers.git /tmp/fibers \
    && cd /tmp/fibers \
    && autoreconf -fiv \
    && ./configure --prefix=/usr \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /tmp/fibers

# ── guile-goblins (capability-secure actors) ─────────────────────────────
# Run configure to generate goblins/config.scm, then install source files
# directly. Full compilation fails on OCapN TLS/WebSocket netlayers (need
# guile-websocket), but the planner only uses core Goblins modules.
ARG GOBLINS_TAG=v0.16.1
RUN git clone --depth 1 --branch ${GOBLINS_TAG} \
      https://codeberg.org/spritely/goblins.git /tmp/goblins \
    && cd /tmp/goblins \
    && autoreconf -fiv \
    && ./configure --prefix=/usr \
    && SITE=/usr/share/guile/site/3.0 \
    && cp -r goblins "$SITE/goblins" \
    && cp goblins.scm "$SITE/goblins.scm" \
    && rm -rf /tmp/goblins

# ── Verify the core modules load ─────────────────────────────────────────
RUN guile --no-auto-compile -c '\
  (use-modules (goblins) (goblins utils hashmap) (goblins persistence-store memory)) \
  (display "goblins ok\n")'

WORKDIR /src
