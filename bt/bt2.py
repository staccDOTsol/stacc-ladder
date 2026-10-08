import itertools, statistics, json
from bt import paths, sim
P = paths()
rows = []
for f, w, iv, tip in itertools.product([0.005, 0.01, 0.02, 0.03], [0.10, 0.20, 0.35], [3600, 21600, None], [0.03, 0.04, 0.05, 0.06]):
    rs = [sim(p, f, 0.0, w, iv, tip) for p in P.values()]
    pn = [r[0] for r in rs]
    rows.append((statistics.mean(pn), statistics.median(pn), sum(x > 0 for x in pn) / len(pn), statistics.mean(r[1] for r in rs), sum(r[2] for r in rs), f, w, iv, tip))
rows.sort(reverse=True)
for r in rows[:10]:
    print(f"mean {r[0]*100:+.1f}% median {r[1]*100:+.1f}% win {r[2]*100:.0f}% fees {r[3]*100:.2f}% arbs {r[4]} | fee {r[5]*100:g}% width {r[6]*100:g}% relay {r[7]} tip {r[8]*100:g}%")
