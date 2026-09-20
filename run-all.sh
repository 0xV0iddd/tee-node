#!/usr/bin/env bash
# ============================================================================
# run-all.sh — one-command reproduction of the tee-node vulnerability
# Target: flare-foundation/tee-node v0.0.26 (commit e1d5391)
#
# Runs the full chain:
#   Phase 0a-5: config-server takeover, suppression, exfiltration, capture
#   Phase 6 (D1-D4): policy capture, wallet mint, TEE signs XRPL payment
#   D5: funds move on a local XRPL ledger engine
#
# Prerequisites: Docker + Compose v2, git, python3, curl, internet access
# Ports needed free: 5500, 8080, 9000, 5005
# Expected duration: 8-15 minutes (first run, image pulls + forger build)
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

echo "============================================================"
echo "  tee-node v0.0.26 — vulnerability reproduction"
echo "  Full chain: config takeover -> policy capture -> XRPL funds"
echo "============================================================"
echo ""

# --- preflight: check dependencies ---
MISSING=""
for cmd in docker git python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
  echo "ERROR: missing commands:$MISSING"
  echo "Install them and re-run."
  exit 1
fi
docker compose version >/dev/null 2>&1 || {
  echo "ERROR: docker compose v2 required"
  exit 1
}

# --- check scripts exist ---
for f in poc.sh d5.sh; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found in $(pwd)"
    echo "Place run-all.sh, poc.sh, and d5.sh in the same directory."
    exit 1
  fi
done

# --- check ports are free (hostnet mode) ---
PORTS_BLOCKED=""
if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
  for p in 5500 8080 9000 5005; do
    if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]$p[[:space:]]" 2>/dev/null; then
      PORTS_BLOCKED="$PORTS_BLOCKED $p"
    fi
  done
fi
if [ -n "$PORTS_BLOCKED" ]; then
  echo "ERROR: ports in use:$PORTS_BLOCKED"
  echo "Free them and re-run."
  exit 1
fi

# --- clean any stale runs ---
echo "[preflight] cleaning stale runs..."
docker compose -p tee-node-poc down -v >/dev/null 2>&1 || true
docker rm -f poc-xrpld >/dev/null 2>&1 || true
rm -rf .poc-ws-* >/dev/null 2>&1 || true
echo "[preflight] clean."
echo ""

# --- step 1: main PoC ---
echo "============================================================"
echo "[1/2] Main PoC — phases 0a through D4"
echo "      (normal flow, attack, suppression, exfiltration,"
echo"       config capture, policy capture, wallet mint,"
echo "       TEE-signed XRPL payment verification)"
echo "============================================================"
echo ""
if ! ./poc.sh --keep --hostnet; then
  echo ""
  echo "============================================================"
  echo "ERROR: main PoC failed."
  echo "Evidence: $(ls -d poc-evidence-* 2>/dev/null | sort | tail -1)"
  echo "Containers may still be running for inspection (--keep)."
  echo "============================================================"
  exit 1
fi

echo ""

# --- step 2: D5 ---
echo "============================================================"
echo "[2/2] D5 — funds move on local XRPL ledger"
echo "      (local xrpld, SignerList, TEE-signed payment,"
echo "       submit_multisigned, balance verification)"
echo "============================================================"
echo ""
if ! bash d5.sh; then
  echo ""
  echo "============================================================"
  echo "NOTE: D5 failed, but the main PoC (phases 0a-D4) already"
  echo "passed above. D5 requires the main PoC containers to"
  echo "still be running (--keep is set)."
  echo "D5 evidence: $(ls -d poc-evidence-*/d5 2>/dev/null | sort | tail -1)"
  echo "============================================================"
  exit 1
fi

# --- done ---
echo ""
echo "============================================================"
echo "  COMPLETE: full vulnerability chain reproduced."
echo ""
echo "  1. ONE unauthenticated POST hijacked the trust anchor"
echo "  2. Legitimate proxy permanently silenced"
echo "  3. TEE-signed results exfiltrated"
echo "  4. Governance + initial owner captured"
echo "  5. Signing policy captured (root of trust)"
echo "  6. TEE minted a wallet under attacker policy"
echo "  7. TEE signed an attacker-directed XRPL payment"
echo "  8. Ledger engine executed it — FUNDS MOVED (500 XRP)"
echo ""
echo "  Evidence: $(ls -d poc-evidence-* | sort | tail -1)"
echo "  100% localnet — no external system touched"
echo "============================================================"
echo ""
echo "To clean up:"
echo "  docker compose -p tee-node-poc down -v"
echo "  docker rm -f poc-xrpld"
echo "  rm -rf .poc-ws-* poc-evidence-*"
