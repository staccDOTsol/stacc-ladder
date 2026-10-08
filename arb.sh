#!/usr/bin/env bash
# Pons curve <-> Uniswap v4 arbitrage, flash-funded (no capital; you pay gas only).
#
#   KEY_FILE=~/staccoverflow.eth DRY=1 ./arb.sh          # scan + simulate, send nothing
#   KEY_FILE=~/staccoverflow.eth ./arb.sh                # take the best edge once
#   KEY_FILE=~/staccoverflow.eth WATCH=1 ./arb.sh        # keep scanning every INTERVAL seconds
#
# For each token (TOKENS, default JUSTTESTIN and ZERO) it finds every v4 pool on the token that
# is quoted in ETH or USDG (StaccLadder's, hookless ones, anyone's), simulates buying on the
# cheaper side and selling on the other at several sizes, both directions, and sends the best
# one only when profit beats gas by MIN_PROFIT. The PonsArb contract reverts any trade that
# would not pay, so a stale quote costs gas, never principal. First run deploys PonsArb for you.
#
# Options: TOKENS="0x.. 0x.." SIZES="0.0005 0.001 ..." (ETH) MIN_PROFIT=0.00001 (ETH)
#          INTERVAL=15 LOOKBACK=3000000 (blocks scanned for pools)
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
CREATE2=0x4e59b44847b379578588920cA78FbF26c0B4956C
FACTORY=0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
ETH=0x0000000000000000000000000000000000000000
BRIDGE="($ETH,$USDG,460,9,$ETH)"
NOBRIDGE="($ETH,$ETH,0,0,$ETH)"
TOKENS=${TOKENS:-"0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e 0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522"}
SIZES=${SIZES:-"0.0005 0.001 0.002 0.005 0.01 0.02 0.05"}
MIN_PROFIT=${MIN_PROFIT:-0.00001}
INTERVAL=${INTERVAL:-15}
LOOKBACK=${LOOKBACK:-3000000}
PLAN_T="(address,address,(address,address,uint24,int24,address),(address,address,uint24,int24,address),bool,bool,uint256)"

PK=$(tr -d ' \n\r' < "${KEY_FILE:?set KEY_FILE}")
[[ $PK == 0x* ]] || PK=0x$PK
ME=$(cast wallet address --private-key "$PK")

forge build --skip test >/dev/null
ARB_INIT=$(python3 -c 'import json;print(json.load(open("out/PonsArb.sol/PonsArb.json"))["bytecode"]["object"])')$(cast abi-encode "f(address,address)" $PM "$ME" | cut -c3-)
SALT=0x0000000000000000000000000000000000000000000000000000000000000000
ARB=$(python3 - "$CREATE2" "$SALT" "$(cast keccak "$ARB_INIT")" <<'EOF'
import sys,subprocess
d,s,h=sys.argv[1:]
k=subprocess.run(["cast","keccak","0xff"+d[2:].lower()+s[2:]+h[2:]],capture_output=True,text=True).stdout.strip()
print(subprocess.run(["cast","to-check-sum-address","0x"+k[-40:]],capture_output=True,text=True).stdout.strip())
EOF
)
echo "wallet $ME  PonsArb $ARB"
if [[ $(cast codesize "$ARB" --rpc-url "$RPC") == 0 ]]; then
  if [[ -n ${DRY:-} ]]; then
    echo "PonsArb not deployed yet; a real run deploys it first (dry run simulates nothing without it)"; exit 0
  fi
  echo "deploying PonsArb"
  cast send --rpc-url "$RPC" --private-key "$PK" $CREATE2 "${SALT}${ARB_INIT#0x}" >/dev/null
fi

lc() { echo "$1" | tr 'A-F' 'a-f'; }

pools_for() { # token -> lines "c0 c1 fee ts hooks"
  local t=$1 n; n=$(cast block-number --rpc-url "$RPC")
  local top=0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438
  local pt=0x000000000000000000000000${t#0x}
  { cast logs --json --rpc-url "$RPC" --address $PM --from-block $((n - LOOKBACK)) --to-block "$n" $top '' "$pt" ''
    cast logs --json --rpc-url "$RPC" --address $PM --from-block $((n - LOOKBACK)) --to-block "$n" $top '' '' "$pt"; } \
  | python3 -c '
import sys,json,re
txt=sys.stdin.read()
for chunk in re.findall(r"\[.*?\](?=\s*\[|\s*$)",txt,re.S):
    for l in json.loads(chunk):
        d=l["data"][2:]
        fee=int(d[0:64],16); ts=int(d[64:128],16); ts=ts-2**256 if ts>=2**255 else ts
        print("0x"+l["topics"][2][-40:],"0x"+l["topics"][3][-40:],fee,ts,"0x"+d[152:192])'
}

curve_for() {
  cast call $FACTORY "getLaunchedToken(address)" "$1" --rpc-url "$RPC" | python3 -c 'import sys;h=sys.stdin.read().strip()[2:];print("0x"+h[64+24:128])'
}

scan_once() {
  local best_profit=0 best_args="" best_desc=""
  for T in $TOKENS; do
    local C; C=$(curve_for "$T")
    [[ $C == "$ETH" ]] && { echo "  ${T:0:10}: not a Pons launch"; continue; }
    [[ $(cast call "$C" "graduated()(bool)" --rpc-url "$RPC") == true ]] && { echo "  ${T:0:10}: graduated, no curve"; continue; }
    while read -r c0 c1 fee ts hooks; do
      local other; [[ $(lc "$c0") == "$(lc "$T")" ]] && other=$c1 || other=$c0
      local bridge use
      if [[ $other == "$ETH" ]]; then bridge=$NOBRIDGE; use=false
      elif [[ $(lc "$other") == "$(lc "$USDG")" ]]; then bridge=$BRIDGE; use=true
      else continue; fi
      local key="($c0,$c1,$fee,$ts,$hooks)"
      for dir in true false; do
        for s in $SIZES; do
          local wei; wei=$(cast to-wei "$s")
          local plan="($C,$T,$key,$bridge,$use,$dir,$wei)"
          local p
          p=$(cast call --rpc-url "$RPC" --from "$ME" --gas-limit 30000000 "$ARB" "arb($PLAN_T,uint256)(uint256)" "$plan" 0 2>/dev/null | awk '{print $1}') || p=""
          [[ -z $p ]] && continue
          if python3 -c "import sys;sys.exit(0 if int('$p')>int('$best_profit') else 1)"; then
            best_profit=$p; best_args="$plan"
            best_desc="${T:0:10} pool(fee $fee hook ${hooks:0:10}) $([[ $dir == true ]] && echo 'buy pool/sell curve' || echo 'buy curve/sell pool') size $s ETH"
          fi
        done
      done
    done < <(pools_for "$T" | sort -u)
  done
  if [[ $best_profit == 0 ]]; then echo "  no profitable edge"; return; fi
  local gas gp cost min
  gas=$(cast estimate --rpc-url "$RPC" --from "$ME" "$ARB" "arb($PLAN_T,uint256)" "$best_args" 0 2>/dev/null || echo 2000000)
  gp=$(cast gas-price --rpc-url "$RPC")
  cost=$((gas * gp))
  min=$(cast to-wei "$MIN_PROFIT")
  echo "  best: $best_desc  profit $(cast from-wei "$best_profit") ETH  gas ~$(cast from-wei $cost) ETH"
  if (( best_profit < cost + min )); then echo "  below MIN_PROFIT after gas, skipping"; return; fi
  if [[ -n ${DRY:-} ]]; then echo "  [dry] would send"; return; fi
  local floor=$(( best_profit * 8 / 10 ))
  cast send --rpc-url "$RPC" --private-key "$PK" --gas-limit $(( gas * 3 / 2 + 8500000 )) "$ARB" "arb($PLAN_T,uint256)" "$best_args" "$floor" --json \
    | python3 -c 'import json,sys;r=json.load(sys.stdin);print("  tx",r["transactionHash"],"status",r["status"])'
}

while true; do
  echo "$(date -u +%H:%M:%S) scan"
  scan_once
  [[ -n ${WATCH:-} ]] || break
  sleep "$INTERVAL"
done
