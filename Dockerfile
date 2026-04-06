# syntax=docker/dockerfile:1-labs
#
# Dockerfile — Guix-based development environment
#
# Installs GNU Guix from the official binary tarball, then uses the project's
# pinned channels.scm to provide the exact guile-next + guile-goblins toolchain.
#
# Build:  make docker-build
# Test:   make docker-test-planner
# REPL:   make docker-shell
#
# Requires BuildKit insecure mode (Guix needs setPersonality syscall):
#   make docker-setup   # one-time: creates the BuildKit builder
#
# Based on https://gitlab.com/debdistutils/guix/debian-with-guix-container
# (AGPL-3.0+, Simon Josefsson)

FROM debian:bookworm-slim

SHELL ["/bin/bash", "-c"]

# ── Install Guix from official binary tarball ─────────────────────────
RUN --security=insecure \
    set -eux \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         wget ca-certificates gnupg xz-utils netbase make git \
    && M=$(uname -m) \
    && wget -nv "https://ftp.gnu.org/gnu/guix/guix-binary-1.5.0.$M-linux.tar.xz" \
    && wget -nv -O guix-install.sh \
         "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh?h=v1.5.0" \
    && chmod +x guix-install.sh \
    && wget -q "https://sv.gnu.org/people/viewgpg.php?user_id=127547" -O - | gpg --import - \
    && wget -q "https://sv.gnu.org/people/viewgpg.php?user_id=15145" -O - | gpg --import - \
    && yes '' | env GUIX_BINARY_FILE_NAME="guix-binary-1.5.0.$M-linux.tar.xz" \
         ./guix-install.sh \
    && rm -f guix-install.sh "guix-binary-1.5.0.$M-linux.tar.xz" \
    && apt-get remove --purge -y wget gnupg xz-utils \
    && apt-get autoremove --purge -y \
    && rm -rf /var/cache/apt/* /var/lib/apt/lists/*

# ── Pull the project's pinned Guix channels ──────────────────────────
COPY deploy/guix/channels.scm /etc/guix/channels.scm

RUN --security=insecure \
    set -eux \
    && source /root/.config/guix/current/etc/profile \
    && guix-daemon --build-users-group=guixbuild &>/dev/null & \
    sleep 2 \
    && guix pull -C /etc/guix/channels.scm \
    && kill %1 2>/dev/null \
    && rm -rf /var/cache/apt/* /var/lib/apt/lists/*

# ── Pre-build the development profile ────────────────────────────────
# Downloads substitutes for guile-next + guile-goblins so container runs
# don't need to fetch anything.
RUN --security=insecure \
    set -eux \
    && source /root/.config/guix/current/etc/profile \
    && guix-daemon --build-users-group=guixbuild &>/dev/null & \
    sleep 2 \
    && guix shell guile-next guile-goblins guile-gcrypt guile-json -- \
         guile -c '(use-modules (goblins) (goblins utils hashmap) \
                                (goblins persistence-store memory) (json)) \
                   (display "guix profile ok\n")' \
    && kill %1 2>/dev/null || true

# ── Entrypoint ────────────────────────────────────────────────────────
WORKDIR /src

RUN printf '#!/bin/bash\n\
source /root/.config/guix/current/etc/profile\n\
guix-daemon --build-users-group=guixbuild &>/dev/null &\n\
sleep 1\n\
exec guix shell guile-next guile-goblins guile-gcrypt guile-json -- "$@"\n' \
  > /usr/local/bin/guix-env && chmod +x /usr/local/bin/guix-env

ENTRYPOINT ["/usr/local/bin/guix-env"]
CMD ["guile"]
