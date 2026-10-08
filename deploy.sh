#!/usr/bin/env bash
# Deploy StaccLadder to Robinhood Chain (4663) and configure it.
#
#   KEY_FILE=~/staccoverflow.eth ./deploy.sh            # deploy + configure
#   KEY_FILE=~/staccoverflow.eth DRY=1 ./deploy.sh      # estimate only, send nothing
#
# The deployer becomes owner and toll beneficiary unless OWNER / BENEFICIARY are set.
# Idempotent: every step checks chain state first, so a re-run resumes where it stopped.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}
CREATE2=0x4e59b44847b379578588920cA78FbF26c0B4956C
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
PONS_FACTORY=0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e
ZERO_CURVE=0x5C8610B3225Dc9fe9671B549E3a88a01961C9b3D
ZERO=0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522
USDG_ETH_POOL="(0x0000000000000000000000000000000000000000,$USDG,460,9,0x0000000000000000000000000000000000000000)"
TIERS="[(3000,60),(10000,100),(30000,200),(100000,200)]"
#        tau horizon feePerVol widthMult minW maxW  maxDev minVol initVol interval drift slip shieldMax stepGas
PARAMS="(600,3600,20,300,600,60000,2000,50,1000,900,1000,100,16,8000000)"
SINK_BPS=${SINK_BPS:-0}
OUT=deployments/robinhood-4663.json

PK=$(tr -d ' \n\r' < "${KEY_FILE:?set KEY_FILE to the deployer key file}")
[[ $PK == 0x* ]] || PK=0x$PK
ME=$(cast wallet address --private-key "$PK")
OWNER=${OWNER:-$ME}
BENEFICIARY=${BENEFICIARY:-$ME}
echo "deployer $ME  owner $OWNER  beneficiary $BENEFICIARY  balance $(cast balance "$ME" --ether --rpc-url "$RPC") ETH"

send() { # to, calldata...
  if [[ -n ${DRY:-} ]]; then
    echo "  [dry] gas $(cast estimate --rpc-url "$RPC" --from "$ME" "$@")"
  else
    cast send --rpc-url "$RPC" --private-key "$PK" "$@" --json | python3 -c 'import json,sys;r=json.load(sys.stdin);print("  tx",r["transactionHash"],"status",r["status"],"gas",int(r["gasUsed"],16))'
  fi
}

create2_addr() { # salt, initcode
  local h; h=$(cast keccak "$2")
  python3 - "$CREATE2" "$1" "$h" <<'EOF'
import sys,subprocess
d,s,h=sys.argv[1:]
k=subprocess.run(["cast","keccak","0xff"+d[2:].lower()+s[2:]+h[2:]],capture_output=True,text=True).stdout.strip()
print(subprocess.run(["cast","to-check-sum-address","0x"+k[-40:]],capture_output=True,text=True).stdout.strip())
EOF
}

forge build --skip test >/dev/null

# 1. strategy library (no constructor, no links): CREATE2 salt 0
LIB_INIT=$(python3 -c 'import json;print(json.load(open("out/LadderLogic.sol/LadderLogic.json"))["bytecode"]["object"])')
LIB_SALT=0x0000000000000000000000000000000000000000000000000000000000000000
LIB=$(create2_addr $LIB_SALT "$LIB_INIT")
echo "1. LadderLogic -> $LIB"
if [[ $(cast codesize "$LIB" --rpc-url "$RPC") == 0 ]]; then
  send $CREATE2 "${LIB_SALT}${LIB_INIT#0x}"
else
  echo "  already deployed"
fi

# 2. hook: link the library, append constructor args, mine a salt whose address carries the flags
HOOK_CODE=$(python3 - "$LIB" <<'EOF'
import json,re,sys
b=json.load(open("out/StaccLadder.sol/StaccLadder.json"))["bytecode"]["object"]
print(re.sub(r"__\$[0-9a-f]{34}\$__", sys.argv[1][2:].lower(), b))
EOF
)
ARGS=$(cast abi-encode "f(address,address,address,uint16,(uint24,int24)[],(uint32,uint32,uint32,uint32,int24,int24,int24,int24,int24,uint32,uint16,uint16,uint8,uint32))" \
  $PM "$OWNER" "$BENEFICIARY" "$SINK_BPS" "$TIERS" "$PARAMS")
HOOK_INIT=${HOOK_CODE}${ARGS#0x}
HASH=$(cast keccak "$HOOK_INIT")
HOOK_SALT=$(cast create2 --deployer $CREATE2 --init-code-hash "$HASH" --ends-with 15c7 2>/dev/null | tail -1 | awk '{print $2}')
HOOK=$(create2_addr "$HOOK_SALT" "$HOOK_INIT")
echo "2. StaccLadder -> $HOOK (salt $HOOK_SALT)"
[[ ${HOOK: -4} =~ ^(15[cC]7)$ ]] || { echo "mined address does not carry the flags"; exit 1; }
if [[ $(cast codesize "$HOOK" --rpc-url "$RPC") == 0 ]]; then
  send $CREATE2 "${HOOK_SALT}${HOOK_INIT#0x}"
else
  echo "  already deployed"
fi

if [[ -n ${DRY:-} && $(cast codesize "$HOOK" --rpc-url "$RPC") == 0 ]]; then
  echo "dry run stops here (configuration needs the hook on chain)"; exit 0
fi

# 3. configuration (owner)
echo "3. list USDG (priced by its deepest ETH pool), allow the Pons factory"
listed=$(cast call "$HOOK" "quotes()(address[])" --rpc-url "$RPC")
[[ $listed == *"${USDG:2:8}"* || $listed == *"$(echo ${USDG:2:8} | tr A-F a-f)"* ]] \
  || send "$HOOK" "listQuote(address,(address,address,uint24,int24,address))" $USDG "$USDG_ETH_POOL"
send "$HOOK" "setPonsFactory(address,bool)" $PONS_FACTORY true

# 4. ZERO: Pons curve reference + its pool family
echo "4. ZERO reference and family"
kind=$(cast call "$HOOK" "ref(address)((uint8,address,(address,address,uint24,int24,address)))" $ZERO --rpc-url "$RPC" | cut -c2-2)
[[ $kind == 0 ]] && send "$HOOK" "listPons(address)" $ZERO_CURVE
send "$HOOK" "openFamily(address)" $ZERO

mkdir -p deployments
cat > "$OUT" <<EOF
{
  "chainId": 4663,
  "poolManager": "$PM",
  "ladderLogic": "$LIB",
  "staccLadder": "$HOOK",
  "hookSalt": "$HOOK_SALT",
  "owner": "$OWNER",
  "beneficiary": "$BENEFICIARY",
  "sinkBps": $SINK_BPS,
  "quotes": { "ETH": "0x0000000000000000000000000000000000000000", "USDG": "$USDG" },
  "usdgEthPool": { "fee": 460, "tickSpacing": 9, "hooks": "0x0000000000000000000000000000000000000000" },
  "ponsFactory": "$PONS_FACTORY",
  "tiers": $(echo "$TIERS" | sed 's/(/[/g; s/)/]/g'),
  "params": "tau,horizon,feePerVol,widthMult,minWidth,maxWidth,maxDev,minVol,initVol,interval,quoteDriftBps,maxSlipBps,shieldMax,stepGas = $PARAMS",
  "tokens": { "ZERO": { "token": "$ZERO", "ponsCurve": "$ZERO_CURVE" } }
}
EOF
echo "wrote $OUT"
