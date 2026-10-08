#!/usr/bin/env bash
# Move your book from StaccLadder v1 to v2, all from your wallet.
#
#   KEY_FILE=~/staccoverflow.eth DRY=1 ./migrate.sh   # show balances and the plan, send nothing
#   KEY_FILE=~/staccoverflow.eth ./migrate.sh         # run it
#
# v1: sweep your toll, pull both tokens' positions, withdraw every currency to your wallet.
# v2: set the book (JUSTTESTIN + ZERO against ETH + USDG), deposit everything (ETH minus
#     ETH_RESERVE for gas), lay both tokens.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}
V1=$(python3 -c "import json;print(json.load(open('deployments/robinhood-4663.json'))['staccLadder'])")
V2=$(python3 -c "import json;print(json.load(open('deployments/robinhood-4663-v2.json'))['staccLadder'])")
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
ZERO=0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522
JT=0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e
ETH=0x0000000000000000000000000000000000000000
ETH_RESERVE=${ETH_RESERVE:-10000000000000000}

PK=$(tr -d ' \n\r' < "${KEY_FILE:?set KEY_FILE}")
[[ $PK == 0x* ]] || PK=0x$PK
ME=$(cast wallet address --private-key "$PK")
echo "book $ME   v1 $V1 -> v2 $V2"

send() {
  if [[ -n ${DRY:-} ]]; then echo "  [dry] $*"; return; fi
  cast send --rpc-url "$RPC" --private-key "$PK" "$@" --json | python3 -c 'import json,sys;r=json.load(sys.stdin);print("  tx",r["transactionHash"],"status",r["status"]);sys.exit(0 if r["status"]=="0x1" else 1)'
}
free_v1() { cast call "$V1" "balanceOf(address,address)(uint256,uint256,int256)" "$ME" "$1" --rpc-url "$RPC" | head -1 | awk '{print $1}'; }
bal() { [[ $1 == "$ETH" ]] && cast balance "$ME" --rpc-url "$RPC" || cast call "$1" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}'; }

echo "1. v1: sweep toll, unwind, withdraw"
for C in $JT $ZERO $USDG $ETH; do
  [[ $(cast call "$V1" "tollOf(address)(uint256)" "$C" --rpc-url "$RPC" | awk '{print $1}') != 0 ]] && send "$V1" "sweepToll(address)" "$C"
done
send "$V1" "unwind(address,address)" "$ME" $JT
send "$V1" "unwind(address,address)" "$ME" $ZERO
for C in $JT $ZERO $USDG $ETH; do
  A=$(free_v1 "$C"); echo "  v1 free ${C:0:10}: $A"
  [[ $A != 0 ]] && send "$V1" "withdraw(address,address,uint256,address)" "$ME" "$C" "$A" "$ME"
done

echo "2. v2: book, deposits, lay"
send "$V2" "setBook(address[],address[],address)" "[$JT,$ZERO]" "[$ETH,$USDG]" $ETH
for C in $JT $ZERO $USDG; do
  A=$(bal "$C"); echo "  wallet ${C:0:10}: $A"
  [[ $A == 0 ]] && continue
  send "$C" "approve(address,uint256)" "$V2" "$A"
  send "$V2" "deposit(address,uint256)" "$C" "$A"
done
E=$(python3 -c "print(max(0, $(bal $ETH) - $ETH_RESERVE))")
echo "  wallet ETH to deposit: $E"
[[ $E != 0 ]] && send "$V2" "deposit(address,uint256)" $ETH "$E" --value "$E"
send "$V2" "rebalance(address,address)" "$ME" $JT
send "$V2" "rebalance(address,address)" "$ME" $ZERO
echo "done"
