"""Backtest a single-sided ladder book against real Pons curve histories, arb-only flow.

Each historical curve trade is replayed (same quote in for buys, same tokens in for sells) on a
constant-product curve whose reserves we also move with every arb. After each trade, arbers
sweep the book while it pays: asks while ask_price*(1+f) < curve*(1-fp), bids while
bid_price*(1-f) > curve*(1+fp), each sweep moving the curve too. The book re-lays around the
curve every `interval` seconds. v2 'tip' = shield that, at swap time, lifts asks to at least
curve*(1-tip) and drops bids to at most curve*(1+tip).

Score: (book value - hold value) / starting value, both at the final curve price.
"""
import json, math, statistics, itertools, sys

D = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "data.json"))
SPB = D["secPerBlock"]


def paths():
    out = {}
    for tok, r in D["tokens"].items():
        q, t = r["q"] / 1e18, r["t"] / 1e18
        ev = r["events"]
        if len(ev) < 30:
            continue
        # walk back from the current reserves to the reserves before each trade
        steps = []
        ok = True
        for e in reversed(ev):
            a, c, fee, tax = e["a"] / 1e18, e["c"] / 1e18, e["fee"] / 1e18, e["tax"] / 1e18
            if e["buy"]:
                qb, tb = q - (a - fee - tax), t + c
                fp = (fee + tax) / a if a else 0
                steps.append((e["b"], True, a - fee - tax, fp))
            else:
                qb, tb = q + c + fee + tax, t - a
                fp = (fee + tax) / (c + fee + tax) if c else 0
                steps.append((e["b"], False, a, fp))
            q, t = qb, tb
            if q <= 0 or t <= 0:
                ok = False
                break
        if not ok:
            continue
        steps.reverse()
        fps = sorted(s[3] for s in steps if s[3] > 0)
        out[tok] = {"q0": q, "t0": t, "steps": steps, "fp": fps[len(fps) // 2] if fps else 0.0122}
    return out


def sim(p, f, a, w, interval, tip, size=0.5, token_share=0.8):
    Q, T = p["q0"], p["t0"]
    fp = p["fp"]
    steps = p["steps"]
    P = Q / T
    X0 = size * token_share / P  # tokens
    Y0 = size * (1 - token_share)  # quote (ETH)
    st = {"fees": 0.0, "arbs": 0, "vol": 0.0}
    book = {}

    def relay(P, X, Y):
        pa, pb = P * (1 + a), P * (1 + a) * math.exp(w)
        qb_, qa_ = P * (1 - a), P * (1 - a) * math.exp(-w)
        La = X / (1 / math.sqrt(pa) - 1 / math.sqrt(pb)) if X > 0 else 0.0
        Lb = Y / (math.sqrt(qb_) - math.sqrt(qa_)) if Y > 0 else 0.0
        book.update(pa=pa, pb=pb, pa_cur=pa, La=La, qa=qa_, qb=qb_, pb_cur=qb_, Lb=Lb,
                    xs=0.0, yr=0.0, xb=0.0, yb=0.0)

    def holdings():
        b = book
        xa = b["La"] * (1 / math.sqrt(b["pa_cur"]) - 1 / math.sqrt(b["pb"])) if b["La"] else 0.0
        ya = b["La"] * (math.sqrt(b["pa_cur"]) - math.sqrt(b["pa"])) if b["La"] else 0.0
        yb = b["Lb"] * (math.sqrt(b["pb_cur"]) - math.sqrt(b["qa"])) if b["Lb"] else 0.0
        xb = b["Lb"] * (1 / math.sqrt(b["pb_cur"]) - 1 / math.sqrt(b["qb"])) if b["Lb"] else 0.0
        return xa + xb + b["xs"], ya + yb + b["yr"]

    relay(P, X0, Y0)
    last = steps[0][0]
    for blk, isbuy, amt, _ in steps:
        # replay the retail trade on our curve
        k = Q * T
        if isbuy:
            Q += amt
            T = k / Q
        else:
            T += amt
            Q = k / T
        P = Q / T
        b = book
        # v2 shield: lift stale asks / drop stale bids to within `tip` of the curve
        if tip is not None:
            if b["La"] and b["pa_cur"] < P * (1 - tip):
                xa = b["La"] * (1 / math.sqrt(b["pa_cur"]) - 1 / math.sqrt(b["pb"]))
                ya = b["La"] * (math.sqrt(b["pa_cur"]) - math.sqrt(b["pa"]))
                ratio = b["pb"] / b["pa_cur"]
                b["yr"] += ya
                b["pa"] = b["pa_cur"] = P * (1 - tip)
                b["pb"] = b["pa"] * ratio
                b["La"] = xa / (1 / math.sqrt(b["pa"]) - 1 / math.sqrt(b["pb"])) if xa > 0 else 0.0
            if b["Lb"] and b["pb_cur"] > P * (1 + tip):
                yb = b["Lb"] * (math.sqrt(b["pb_cur"]) - math.sqrt(b["qa"]))
                xb = b["Lb"] * (1 / math.sqrt(b["pb_cur"]) - 1 / math.sqrt(b["qb"]))
                ratio = b["pb_cur"] / b["qa"]
                b["xs"] += xb
                b["qb"] = b["pb_cur"] = P * (1 + tip)
                b["qa"] = b["qb"] / ratio
                b["Lb"] = yb / (math.sqrt(b["qb"]) - math.sqrt(b["qa"])) if yb > 0 else 0.0
        # asks: arbers buy from us, sell on the curve
        if b["La"] and b["pa_cur"] < b["pb"] and b["pa_cur"] * (1 + f) < P * (1 - fp):
            pc, La, k = b["pa_cur"], b["La"], Q * T

            def g(x):
                dT = La * (1 / math.sqrt(pc) - 1 / math.sqrt(x))
                T2 = T + dT
                return x * (1 + f) - (k / T2) / T2 * (1 - fp)

            lo, hi = pc, b["pb"]
            if g(hi) < 0:
                ps = hi
            else:
                for _ in range(60):
                    mid = (lo + hi) / 2
                    if g(mid) < 0:
                        lo = mid
                    else:
                        hi = mid
                ps = lo
            dT = La * (1 / math.sqrt(pc) - 1 / math.sqrt(ps))
            dQ = La * (math.sqrt(ps) - math.sqrt(pc))
            if dT > 0:
                T += dT
                Q = k / T
                b["pa_cur"] = ps
                st["fees"] += f * dQ
                b["yr"] += f * dQ
                st["arbs"] += 1
                st["vol"] += dQ
            P = Q / T
        # bids: arbers buy on the curve, sell to us
        if b["Lb"] and b["pb_cur"] > b["qa"] and b["pb_cur"] * (1 - f) > P * (1 + fp):
            pc, Lb, k = b["pb_cur"], b["Lb"], Q * T

            def h(x):
                dT = Lb * (1 / math.sqrt(x) - 1 / math.sqrt(pc))
                T2 = T - dT
                if T2 <= 0:
                    return -1.0
                return x * (1 - f) - (k / T2) / T2 * (1 + fp)

            lo, hi = b["qa"], pc
            if h(lo) > 0:
                ps = lo
            else:
                for _ in range(60):
                    mid = (lo + hi) / 2
                    if h(mid) > 0:
                        hi = mid
                    else:
                        lo = mid
                ps = hi
            dT = Lb * (1 / math.sqrt(ps) - 1 / math.sqrt(pc))
            dQ = Lb * (math.sqrt(pc) - math.sqrt(ps))
            if dT > 0 and T - dT > 0:
                T -= dT
                Q = k / T
                b["pb_cur"] = ps
                st["fees"] += f * dT * ps
                b["xs"] += f * dT
                st["arbs"] += 1
                st["vol"] += dQ
            P = Q / T
        if interval is not None and (blk - last) * SPB >= interval:
            X, Y = holdings()
            relay(P, X, Y)
            last = blk
    X, Y = holdings()
    val, hold, start = X * P + Y, X0 * P + Y0, size
    return (val - hold) / start, st["fees"] / start, st["arbs"], st["vol"]


if __name__ == "__main__":
    P = paths()
    print(len(P), "token paths:", ", ".join(f"{k[:8]}({len(v['steps'])})" for k, v in P.items()))
    grid = []
    for f, a, w, iv, tip in itertools.product(
        [0.003, 0.01, 0.03, 0.05, 0.10],
        [0.0, 0.01],
        [0.03, 0.08, 0.20],
        [60, 300, None],
        [None, 0.02, 0.04, 0.08],
    ):
        rs = [sim(p, f, a, w, iv, tip) for p in P.values()]
        pnl = [r[0] for r in rs]
        grid.append({
            "f": f, "a": a, "w": w, "iv": iv, "tip": tip,
            "mean": statistics.mean(pnl), "median": statistics.median(pnl),
            "fees": statistics.mean(r[1] for r in rs), "arbs": sum(r[2] for r in rs),
            "vol": sum(r[3] for r in rs), "win": sum(1 for x in pnl if x > 0) / len(pnl),
        })
    grid.sort(key=lambda g: -g["mean"])
    fmt = lambda g: (f"fee {g['f']*100:>4g}% off {g['a']*100:g}% width {g['w']*100:>3g}% relay {str(g['iv']):>4} tip {str(g['tip']):>4}"
                     f" | vs hold mean {g['mean']*100:+.2f}% median {g['median']*100:+.2f}% win {g['win']*100:.0f}%"
                     f" | fees {g['fees']*100:.2f}% arbs {g['arbs']} vol {g['vol']:.2f} ETH")
    print("TOP 12"); [print(fmt(g)) for g in grid[:12]]
    print("CURRENT-LIKE (v1, fee .3-1%, off 1%, width 8%, relay 60, no shield)")
    [print(fmt(g)) for g in grid if g["a"] == 0.01 and g["w"] == 0.08 and g["iv"] == 60 and g["tip"] is None and g["f"] in (0.003, 0.01)]
    print("BEST v1 (no shield)"); [print(fmt(g)) for g in [x for x in grid if x["tip"] is None][:3]]
    print("BEST v2 (tip shield)"); [print(fmt(g)) for g in [x for x in grid if x["tip"] is not None][:3]]
    json.dump(grid, open("grid.json", "w"))
