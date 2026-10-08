#!/usr/bin/env python3
"""Watch StaccLadder pools for arbers. One line per event on stdout.

  python3 watch.py                 # JUSTTESTIN + ZERO families
  TOKENS="0x.. 0x.." python3 watch.py

Events: SWAP (any swap through a family pool, with the tx sender), HOOK (toll, re-lay,
quote mix, sweep, withdraw), NEWPOOL (someone else opens a v4 pool on a watched token),
and a STATUS heartbeat every HEARTBEAT seconds with each token's live reference and toll.
"""
import json, os, subprocess, sys, time, urllib.request

RPC = os.environ.get("RPC", "https://rpc.mainnet.chain.robinhood.com")
PM = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
HOOK = "0x3BDAd0B539F815eDE3ff89cF511F2C37f99215C7"
ETH = "0x0000000000000000000000000000000000000000"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
ME = "0x26E8134eCC3af5cCE32f34B03E7BD2f318B25158".lower()
TOKENS = os.environ.get(
    "TOKENS", "0xA0Fc5a405772Fc80e977e0C1E9D20B95FE956c9e 0x4cbCc4Eb02D7908B86627FBE434D09A506EC3522"
).split()
NAMES = {"0xa0fc5a405772fc80e977e0c1e9d20b95fe956c9e": "JUSTTESTIN", "0x4cbcc4eb02d7908b86627fbe434d09a506ec3522": "ZERO"}
FEES = {0: "0.3%", 1: "1%", 2: "3%", 3: "10%"}
POLL = int(os.environ.get("POLL", "30"))
HEARTBEAT = int(os.environ.get("HEARTBEAT", "900"))


def cast(*a):
    return subprocess.run(["cast", *a], capture_output=True, text=True).stdout.strip()


def rpc(method, params):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json", "User-Agent": "stacc-ladder-watch/1"})
    with urllib.request.urlopen(req, timeout=20) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def k(sig):
    return cast("keccak", sig)


SWAP = k("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
INIT = k("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")
HOOKEV = {k(s): s.split("(")[0] for s in [
    "Reference(bytes32,address,uint8,uint256,uint256,uint256)", "Rebalanced(address,address,uint256,uint256)",
    "Shielded(address,bytes32,uint8,int24,int24)", "QuotesRebalanced(address,address,address,uint256)",
    "TollSwept(address,uint256,uint256)", "Withdraw(address,address,uint256,address)", "Deposit(address,address,uint256)"]}

# family pool ids
pools = {}
for t in TOKENS:
    for q, qn in ((ETH, "ETH"), (USDG, "USDG")):
        for tier in range(4):
            key = cast("call", HOOK, "familyKey(address,address,uint8)((address,address,uint24,int24,address),bool)",
                       t, q, str(tier), "--rpc-url", RPC).splitlines()[0]
            parts = [x.strip().split(" ")[0] for x in key.strip("()").split(",")]
            enc = cast("abi-encode", "f(address,address,uint24,int24,address)", *parts)
            pools[k(enc).lower()] = (NAMES.get(t.lower(), t[:10]), qn, FEES[tier], t.lower() == parts[0].lower())


def s128(h):
    v = int(h, 16)  # int128 is sign-extended to a full word in the log data
    return v - (1 << 256) if v >= 1 << 255 else v


def label(addr):
    a = addr.lower()
    if a == ME:
        return "YOU"
    return a[:10]


def emit(line):
    print(line, flush=True)


def heartbeat():
    parts = []
    for t in TOKENS:
        name = NAMES.get(t.lower(), t[:10])
        tick = cast("call", HOOK, "pairTick(address,address)(int24,bool)", t, ETH, "--rpc-url", RPC).split()[0]
        toll = cast("call", HOOK, "tollOf(address)(uint256)", t, "--rpc-url", RPC).split()[0]
        parts.append(f"{name} ref tick {tick} toll {toll}")
    emit("STATUS " + " | ".join(parts))


last = int(rpc("eth_blockNumber", []), 16)
emit(f"WATCHING {len(pools)} pools from block {last}")
next_hb = time.time() + HEARTBEAT
ids = list(pools)
tok_topics = ["0x" + "0" * 24 + t[2:].lower() for t in TOKENS]
while True:
    try:
        n = int(rpc("eth_blockNumber", []), 16)
        if n > last:
            frm, to = hex(last + 1), hex(n)
            for l in rpc("eth_getLogs", [{"address": PM, "fromBlock": frm, "toBlock": to, "topics": [SWAP, ids]}]):
                name, qn, fee, tok0 = pools[l["topics"][1].lower()]
                d = l["data"][2:]
                a0, a1 = s128(d[0:64]), s128(d[64:128])
                tok_amt, q_amt = (a0, a1) if tok0 else (a1, a0)
                side = "BUY " if tok_amt > 0 else "SELL"  # PoolManager delta is the swapper's: + = received
                tx = rpc("eth_getTransactionByHash", [l["transactionHash"]])
                emit(f"SWAP {side} {name}/{qn} {fee}: token {abs(tok_amt)/1e18:,.0f} quote {abs(q_amt)/(1e6 if qn=='USDG' else 1e18):.6f} "
                     f"from {label(tx['from'])} via {label(tx['to'] or '')} tx {l['transactionHash'][:14]} blk {int(l['blockNumber'],16)}")
            for l in rpc("eth_getLogs", [{"address": HOOK, "fromBlock": frm, "toBlock": to}]):
                ev = HOOKEV.get(l["topics"][0])
                if ev in ("Reference",):
                    d = l["data"][2:]
                    kk = int(d[64:128], 16); t0 = int(d[128:192], 16); t1 = int(d[192:256], 16)
                    if t0 or t1:
                        emit(f"HOOK toll k={kk} amounts {t0} / {t1} tx {l['transactionHash'][:14]}")
                elif ev and ev != "Deposit":
                    emit(f"HOOK {ev} tx {l['transactionHash'][:14]} blk {int(l['blockNumber'],16)}")
            for pos in (2, 3):
                topics = [INIT, None, None, None]
                topics[pos] = tok_topics
                for l in rpc("eth_getLogs", [{"address": PM, "fromBlock": frm, "toBlock": to, "topics": topics}]):
                    d = l["data"][2:]
                    hooks = "0x" + d[152:192]
                    if hooks.lower() == HOOK.lower():
                        continue
                    tx = rpc("eth_getTransactionByHash", [l["transactionHash"]])
                    emit(f"NEWPOOL by {label(tx['from'])} fee {int(d[0:64],16)} hook {hooks[:10]} tx {l['transactionHash'][:14]}")
            last = n
        if time.time() >= next_hb:
            heartbeat()
            next_hb = time.time() + HEARTBEAT
    except Exception as e:  # keep watching through RPC hiccups
        emit(f"ERROR {type(e).__name__}: {str(e)[:120]}")
        time.sleep(POLL)
    time.sleep(POLL)
