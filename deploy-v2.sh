#!/usr/bin/env bash
# Deploy StaccLadder v2 to Robinhood Chain (4663) and configure it.
#
#   KEY_FILE=~/staccoverflow.eth DRY=1 ./deploy-v2.sh   # estimate only
#   KEY_FILE=~/staccoverflow.eth ./deploy-v2.sh         # deploy + configure (idempotent)
#
# Order: LadderRefs, LadderRouter (links Refs), LadderLogic (links Refs, Router), then the hook
# (links all three) at a CREATE2 salt mined so its address carries the hook flags.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}
CREATE2=0x4e59b44847b379578588920cA78FbF26c0B4956C
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
PONS_FACTORY=0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e
ZERO=0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522
ZERO_CURVE=0x5C8610B3225Dc9fe9671B549E3a88a01961C9b3D
JT=0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e
JT_CURVE=0xb6B77aB627d476Db286B732B7359F552BBC694F4
USDG_ETH_POOL="(0x0000000000000000000000000000000000000000,$USDG,460,9,0x0000000000000000000000000000000000000000)"
TIERS="[(3000,60),(10000,100),(30000,200),(100000,200)]"
#        tau hor fpv wm  minW maxW maxDev minVol initVol interval drift slip shieldMax stepGas tip offset
PARAMS="(60,3600,5,300,2000,5000,2000,50,1000,86400,1000,100,16,3000000,300,0)"
RATCHET="(1000,1,1000000)"
BURN="($JT,10000,200000000000000)"
SINK_BPS=${SINK_BPS:-0}
OUT=deployments/robinhood-4663-v2.json

PK=$(tr -d ' \n\r' < "${KEY_FILE:?set KEY_FILE}")
[[ $PK == 0x* ]] || PK=0x$PK
ME=$(cast wallet address --private-key "$PK")
OWNER=${OWNER:-$ME}
BENEFICIARY=${BENEFICIARY:-$ME}
echo "deployer $ME  balance $(cast balance "$ME" --ether --rpc-url "$RPC") ETH"

send() {
  if [[ -n ${DRY:-} ]]; then echo "  [dry] gas $(cast estimate --rpc-url "$RPC" --from "$ME" "$@")"; return; fi
  cast send --rpc-url "$RPC" --private-key "$PK" "$@" --json | python3 -c 'import json,sys;r=json.load(sys.stdin);print("  tx",r["transactionHash"],"status",r["status"],"gas",int(r["gasUsed"],16));sys.exit(0 if r["status"]=="0x1" else 1)'
}
addr2() { # salt initcode
  python3 - "$CREATE2" "$1" "$(cast keccak "$2")" <<'EOF'
import sys,subprocess
d,s,h=sys.argv[1:]
k=subprocess.run(["cast","keccak","0xff"+d[2:].lower()+s[2:]+h[2:]],capture_output=True,text=True).stdout.strip()
print(subprocess.run(["cast","to-check-sum-address","0x"+k[-40:]],capture_output=True,text=True).stdout.strip())
EOF
}
linked() { # artifact name, then pairs "fqn=address"
  python3 - "$@" <<'EOF'
import json,sys,subprocess
name=sys.argv[1]; b=json.load(open(f"out/{name}.sol/{name}.json"))["bytecode"]["object"]
for pair in sys.argv[2:]:
    fqn,a=pair.split("=")
    h=subprocess.run(["cast","keccak",fqn],capture_output=True,text=True).stdout.strip()[2:36]
    b=b.replace("__$"+h+"$__",a[2:].lower())
assert "__$" not in b, "unlinked library left in "+name
print(b)
EOF
}
deploy_lib() { # name, initcode
  local salt=0x0000000000000000000000000000000000000000000000000000000000000002 a
  a=$(addr2 $salt "$2")
  echo "$1 -> $a" >&2
  if [[ $(cast codesize "$a" --rpc-url "$RPC") == 0 ]]; then send $CREATE2 "${salt}${2#0x}" >&2; else echo "  already deployed" >&2; fi
  echo "$a"
}

forge build --skip test >/dev/null
REFS=$(deploy_lib LadderRefs "$(linked LadderRefs)")
ROUTER=$(deploy_lib LadderRouter "$(linked LadderRouter src/LadderRefs.sol:LadderRefs=$REFS)")
LOGIC=$(deploy_lib LadderLogic "$(linked LadderLogic src/LadderRefs.sol:LadderRefs=$REFS src/LadderRouter.sol:LadderRouter=$ROUTER)")
CODE=$(linked StaccLadder src/LadderRefs.sol:LadderRefs=$REFS src/LadderRouter.sol:LadderRouter=$ROUTER src/LadderLogic.sol:LadderLogic=$LOGIC)
ARGS=$(cast abi-encode "f(address,address,address,uint16,(uint24,int24)[],(uint32,uint32,uint32,uint32,int24,int24,int24,int24,int24,uint32,uint16,uint16,uint8,uint32,int24,int24),(uint32,uint8,uint32),(address,uint16,uint128))" \
  $PM "$OWNER" "$BENEFICIARY" "$SINK_BPS" "$TIERS" "$PARAMS" "$RATCHET" "$BURN")
INIT=${CODE}${ARGS#0x}
SALT=$(cast create2 --deployer $CREATE2 --init-code-hash "$(cast keccak "$INIT")" --ends-with 15c7 2>/dev/null | tail -1 | awk '{print $2}')
HOOK=$(addr2 "$SALT" "$INIT")
echo "StaccLadder v2 -> $HOOK"
[[ ${HOOK: -4} =~ ^15[cC]7$ ]] || { echo "mined address lacks the flags"; exit 1; }
if [[ $(cast codesize "$HOOK" --rpc-url "$RPC") == 0 ]]; then send $CREATE2 "${SALT}${INIT#0x}"; else echo "  already deployed"; fi
if [[ -n ${DRY:-} ]]; then echo "dry run stops before configuration"; exit 0; fi

echo "configure"
send "$HOOK" "listQuote(address,(address,address,uint24,int24,address))" $USDG "$USDG_ETH_POOL"
send "$HOOK" "setPonsFactory(address,bool)" $PONS_FACTORY true
send "$HOOK" "listPons(address)" $JT_CURVE
send "$HOOK" "listPons(address)" $ZERO_CURVE
send "$HOOK" "openFamily(address)" $JT
send "$HOOK" "openFamily(address)" $ZERO

mkdir -p deployments
cat > "$OUT" <<EOF
{
  "chainId": 4663,
  "version": 2,
  "poolManager": "$PM",
  "staccLadder": "$HOOK",
  "hookSalt": "$SALT",
  "libraries": { "LadderRefs": "$REFS", "LadderRouter": "$ROUTER", "LadderLogic": "$LOGIC" },
  "owner": "$OWNER",
  "beneficiary": "$BENEFICIARY",
  "sinkBps": $SINK_BPS,
  "feeToken": "$JT",
  "quotes": { "ETH": "0x0000000000000000000000000000000000000000", "USDG": "$USDG", "JUSTTESTIN (fee token)": "$JT" },
  "ponsFactory": "$PONS_FACTORY",
  "tiers": $(echo "$TIERS" | sed 's/(/[/g; s/)/]/g'),
  "params": "tau,horizon,feePerVol,widthMult,minWidth,maxWidth,maxDev,minVol,initVol,interval,quoteDriftBps,maxSlipBps,shieldMax,stepGas,tipTicks,offsetTicks = $PARAMS",
  "ratchet": "floorPips,kFree,capPips = $RATCHET",
  "burn": "token,burnBps,minBurnWei = $BURN",
  "constructorArgs": "$ARGS",
  "tokens": { "ZERO": { "token": "$ZERO", "ponsCurve": "$ZERO_CURVE" }, "JUSTTESTIN": { "token": "$JT", "ponsCurve": "$JT_CURVE" } }
}
EOF
echo "wrote $OUT"
