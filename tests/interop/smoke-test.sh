#!/usr/bin/env bash
# tests/interop/smoke-test.sh — deploy-time IPEX peer smoke test
#
# Verifies that a running playnet gateway exposes the expected IPEX
# peer surface to external clients. Driven by curl, no Node deps.
#
# What this checks:
#   - HTTP gateway is reachable
#   - /federation-status.json returns the expected JSON shape
#   - /universal-commune.json returns a real UC AID (if UC-deployed)
#   - The UC's OOBI at /oobi/{uc-aid} returns a non-empty CESR stream
#   - /pending-grants.json is well-formed
#   - /audit/{some-aid}.json returns 404 (no credential) or 200 (credential)
#
# What this DOESN'T check:
#   - signify-ts client interop (deferred — needs Node + KERIA boot;
#     a real signify-ts harness is task E2's deferred part)
#   - Cross-gateway federation end-to-end (deferred to task #47;
#     manual two-gateway recipe in BOOTSTRAP.md)
#
# Usage:
#   ./tests/interop/smoke-test.sh                 # default: http://localhost:8080
#   ./tests/interop/smoke-test.sh https://gw.example
#
# Exit code 0 = all checks pass; 1 = at least one failed.

set -euo pipefail

GATEWAY="${1:-http://localhost:8080}"
PASS=0
FAIL=0

say()  { printf '  %s\n' "$*"; }
ok()   { say "✓ $*"; PASS=$((PASS+1)); }
fail() { say "✗ $*"; FAIL=$((FAIL+1)); }

printf 'Smoke-testing playnet IPEX peer at %s\n\n' "$GATEWAY"

# ── /federation-status.json ───────────────────────────────────────────

printf '─ /federation-status.json ─\n'
status_body=$(curl -fsS "$GATEWAY/federation-status.json" 2>/dev/null \
              || echo '{"error":"unreachable"}')
if echo "$status_body" | grep -q '"boot-time"'; then
  ok "endpoint responds with valid JSON"
  uc_aid=$(echo "$status_body" | sed -n 's/.*"uc-aid":"\([^"]*\)".*/\1/p')
  peers=$(echo "$status_body" | sed -n 's/.*"peers":\([0-9]*\).*/\1/p')
  keri=$(echo "$status_body" | grep -c '"keri-connected":true' || true)
  say "  peers: $peers"
  say "  uc-aid: ${uc_aid:-<unset>}"
  say "  keri-connected: $([ "$keri" = 1 ] && echo true || echo false)"
else
  fail "endpoint did not return expected shape"
  say "  got: $status_body"
fi

# ── /universal-commune.json ──────────────────────────────────────────

printf '\n─ /universal-commune.json ─\n'
uc_body=$(curl -fsS "$GATEWAY/universal-commune.json" 2>/dev/null || echo '')
if echo "$uc_body" | grep -q '"aid"'; then
  uc_aid_from_json=$(echo "$uc_body" | sed -n 's/.*"aid":"\([^"]*\)".*/\1/p')
  ok "UC endpoint returns AID: $uc_aid_from_json"
elif [ -z "$uc_body" ]; then
  say "  ~ UC endpoint returned empty (no UC on this gateway — OK for federation-only deploys)"
else
  fail "UC endpoint returned unexpected shape: $uc_body"
fi

# ── /oobi/{uc-aid} ───────────────────────────────────────────────────

if [ -n "${uc_aid_from_json:-}" ]; then
  printf '\n─ /oobi/%s ─\n' "$uc_aid_from_json"
  oobi_body=$(curl -fsS "$GATEWAY/oobi/$uc_aid_from_json" 2>/dev/null || echo '')
  if [ -n "$oobi_body" ] && [ "${#oobi_body}" -gt 50 ]; then
    ok "UC OOBI returns CESR stream ($(echo -n "$oobi_body" | wc -c) bytes)"
    if echo "$oobi_body" | head -c 100 | grep -q '"t":"icp"'; then
      ok "OOBI begins with KERI icp event"
    else
      say "  ~ OOBI returned but icp event not at expected position"
    fi
  else
    fail "UC OOBI returned empty / too small"
  fi
fi

# ── /pending-grants.json ─────────────────────────────────────────────

printf '\n─ /pending-grants.json ─\n'
pending_body=$(curl -fsS "$GATEWAY/pending-grants.json" 2>/dev/null || echo '')
if echo "$pending_body" | grep -q '"count"'; then
  count=$(echo "$pending_body" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  ok "pending-grants endpoint reachable (count: $count)"
  if [ "${count:-0}" -gt 0 ]; then
    say "  ~ $count grant(s) pending delivery — investigate if not draining"
  fi
else
  fail "pending-grants endpoint returned unexpected shape"
fi

# ── /audit/{aid}.json — using UC AID if known ────────────────────────

if [ -n "${uc_aid_from_json:-}" ]; then
  printf '\n─ /audit/%s.json ─\n' "$uc_aid_from_json"
  audit_response=$(curl -sS -w '\n%{http_code}' "$GATEWAY/audit/$uc_aid_from_json.json" 2>/dev/null || echo '0')
  code=$(echo "$audit_response" | tail -1)
  case "$code" in
    200) ok "audit endpoint returns latest cycle (200)" ;;
    404) ok "audit endpoint returns 404 (no audit yet — auditor hasn't ticked)" ;;
    *)   fail "audit endpoint returned unexpected code: $code" ;;
  esac
fi

# ── /scopes ──────────────────────────────────────────────────────────

printf '\n─ /scopes ─\n'
scopes_body=$(curl -fsS "$GATEWAY/scopes" 2>/dev/null || echo '')
if [ -n "$scopes_body" ]; then
  ok "scopes endpoint reachable"
  scope_count=$(echo "$scopes_body" | grep -oE '"aid"' | wc -l)
  say "  $scope_count scope(s) advertised"
else
  fail "scopes endpoint unreachable"
fi

# ── Summary ──────────────────────────────────────────────────────────

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
