#!/usr/bin/env bash
# End to end on Robinhood Chain: put a fresh Pons launch and ZERO into one StaccLadder book.
#
#   NEW_TOKEN=0x... KEY_FILE=~/staccoverflow.eth DRY=1 ./e2e.sh   # print the plan, send nothing
#   NEW_TOKEN=0x... KEY_FILE=~/staccoverflow.eth ./e2e.sh         # run it
#
# What it sends, from the key's wallet (it becomes the book):
#   1. listPons(curve of NEW_TOKEN)            the launch's Pons curve becomes its reference
#   2. openFamily(NEW_TOKEN)                   ETH and USDG pools at 0.3/1/3/10%
#   3. setBook([NEW_TOKEN, ZERO], [ETH, USDG]) one book, quotes shared by volatility
#   4. approve + deposit NEW_TOKEN, ZERO, USDG, and ETH minus ETH_RESERVE
#   5. rebalance(book, NEW_TOKEN), rebalance(book, ZERO)
#
# Both tokens start at the same assumed volatility, so each starts with half of the ETH and
# half of the USDG; after that the hook re-weights toward whichever trades more volatile.
# Every token is laid as asks; each token's quote share is laid as bids. With most of the
# value in tokens, both ladders come out heavily token-sided.
#
# Optional: NEW_AMOUNT / ZERO_AMOUNT / USDG_AMOUNT (raw units, default: whole balance),
#           ETH_RESERVE (wei kept for gas, default 0.01 ETH).
# ALPHA, unaudited: only deposit what you can afford to lose.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}
D=deployments/robinhood-4663.json
HOOK=$(python3 -c "import json;print(json.load(open('$D'))['staccLadder'])")
FACTORY=$(python3 -c "import json;print(json.load(open('$D'))['ponsFactory'])")
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
ZERO=0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522
ETH=0x0000000000000000000000000000000000000000
NEW=${NEW_TOKEN:?set NEW_TOKEN to the new Pons launch}
ETH_RESERVE=${ETH_RESERVE:-10000000000000000}

PK=$(tr -d ' \n\r' < "${KEY_FILE:?set KEY_FILE}")
[[ $PK == 0x* ]] || PK=0x$PK
ME=$(cast wallet address --private-key "$PK")

send() {
  if [[ -n ${DRY:-} ]]; then echo "  [dry] $*"; return; fi
  cast send --rpc-url "$RPC" --private-key "$PK" "$@" --json \
    | python3 -c 'import json,sys;r=json.load(sys.stdin);print("  tx",r["transactionHash"],"status",r["status"]);sys.exit(0 if r["status"]=="0x1" else 1)'
}
bal() { cast call "$1" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}'; }

CURVE=$(cast call "$FACTORY" "getLaunchedToken(address)" "$NEW" --rpc-url "$RPC" | python3 -c 'import sys;h=sys.stdin.read().strip()[2:];print("0x"+h[64+24:128])')
SYM=$(cast call "$NEW" "symbol()(string)" --rpc-url "$RPC" | tr -d '"')
echo "hook $HOOK  book $ME"
echo "new token $SYM $NEW  curve $CURVE"
[[ $CURVE != 0x0000000000000000000000000000000000000000 ]] || { echo "not a Pons launch from the allowed factory"; exit 1; }

NEW_AMT=${NEW_AMOUNT:-$(bal "$NEW")}
ZERO_AMT=${ZERO_AMOUNT:-$(bal $ZERO)}
USDG_AMT=${USDG_AMOUNT:-$(bal $USDG)}
ETH_BAL=$(cast balance "$ME" --rpc-url "$RPC")
ETH_AMT=$(python3 -c "print(max(0, $ETH_BAL - $ETH_RESERVE))")
echo "deposit: $SYM $(cast from-wei "$NEW_AMT")  ZERO $(cast from-wei "$ZERO_AMT")  USDG $(cast from-wei "$USDG_AMT" 6)  ETH $(cast from-wei "$ETH_AMT")  (keeping $(cast from-wei "$ETH_RESERVE") ETH for gas)"

echo "1. reference"
kind=$(cast call "$HOOK" "ref(address)((uint8,address,(address,address,uint24,int24,address)))" "$NEW" --rpc-url "$RPC" | cut -c2-2)
if [[ $kind == 0 ]]; then send "$HOOK" "listPons(address)" "$CURVE"; else echo "  already referenced"; fi

echo "2. family"
send "$HOOK" "openFamily(address)" "$NEW"

echo "3. book"
send "$HOOK" "setBook(address[],address[],address)" "[$NEW,$ZERO]" "[$ETH,$USDG]" $ETH

echo "4. deposits"
dep() { # token amount
  [[ $2 == 0 ]] && return
  send "$1" "approve(address,uint256)" "$HOOK" "$2"
  send "$HOOK" "deposit(address,uint256)" "$1" "$2"
}
dep "$NEW" "$NEW_AMT"
dep $ZERO "$ZERO_AMT"
dep $USDG "$USDG_AMT"
[[ $ETH_AMT == 0 ]] || send "$HOOK" "deposit(address,uint256)" $ETH "$ETH_AMT" --value "$ETH_AMT"

echo "5. lay the book"
send "$HOOK" "rebalance(address,address)" "$ME" "$NEW"
send "$HOOK" "rebalance(address,address)" "$ME" $ZERO

[[ -n ${DRY:-} ]] && exit 0
echo
echo "positions (side 0 = ask: token only, side 1 = bid: quote only)"
for T in "$NEW" $ZERO; do
  for Q in $ETH $USDG; do
    for TIER in 0 1 2 3; do
      KEY=$(cast call "$HOOK" "familyKey(address,address,uint8)((address,address,uint24,int24,address),bool)" "$T" "$Q" $TIER --rpc-url "$RPC" | head -1)
      ID=$(python3 - "$KEY" <<'EOF'
import sys,subprocess,re
k=re.findall(r"0x[0-9a-fA-F]{40}|-?\d+",re.sub(r"\[[^\]]*\]","",sys.argv[1]))
enc=subprocess.run(["cast","abi-encode","f(address,address,uint24,int24,address)",k[0],k[1],k[2],k[3],k[4]],capture_output=True,text=True).stdout.strip()
print(subprocess.run(["cast","keccak",enc],capture_output=True,text=True).stdout.strip())
EOF
)
      for SIDE in 0 1; do
        P=$(cast call "$HOOK" "position(bytes32,address,uint8)((int24,int24,uint128,uint128))" "$ID" "$ME" $SIDE --rpc-url "$RPC" | sed -E 's/ \[[^]]*\]//g')
        [[ $P == "(0, 0, 0, 0)" ]] || echo "  token ${T:0:10} quote ${Q:0:10} tier $TIER side $SIDE  (lo, hi, liq, placed) $P"
      done
    done
  done
done
for C in "$NEW" $ZERO $USDG $ETH; do
  echo "  free ${C:0:10}: $(cast call "$HOOK" "balanceOf(address,address)(uint256,uint256,int256)" "$ME" "$C" --rpc-url "$RPC" | tr '\n' ' ')"
done
