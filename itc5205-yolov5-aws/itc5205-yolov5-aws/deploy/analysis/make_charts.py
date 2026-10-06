"""Report charts for ITC5205 Assignment 2 - built from the measured CSVs in perf_results/."""
import csv
import statistics as st
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

R = Path("perf_results")
OUT = Path("charts"); OUT.mkdir(exist_ok=True)

SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BLUE, ORANGE = "#2a78d6", "#eb6834"          # categorical slots 1 and 2 (validated pair)
GOOD, CRITICAL = "#0ca30c", "#d03b3b"        # status colours (always with a text label)
GB_S, PER_REQ = 0.0000166667, 0.20            # Lambda x86 us-east-1 pricing

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True,
    "axes.titlesize": 11, "axes.titleweight": "bold", "axes.titlelocation": "left",
})


def rows(name):
    return list(csv.DictReader(open(R / name)))


def finish(fig, name, source):
    fig.text(0.01, 0.01, source, fontsize=8, color=INK2, ha="left", va="bottom")
    fig.savefig(OUT / name, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print("saved", OUT / name)


# ---------------------------------------------------------------- 1. memory sweep
mem = rows("memory_sweep.csv")
sizes = sorted({int(r["memory_mb"]) for r in mem})
handler = [st.mean(float(r["total_ms"]) for r in mem if int(r["memory_mb"]) == m) for m in sizes]
infer = [st.mean(float(r["inference_ms"]) for r in mem if int(r["memory_mb"]) == m) for m in sizes]
cost = [(h / 1000) * (m / 1024) * GB_S * 1e6 + PER_REQ for h, m in zip(handler, sizes)]
labels = [f"{m} MB" for m in sizes]

fig, (a, b) = plt.subplots(1, 2, figsize=(10, 3.8))
bars = a.bar(labels, handler, color=BLUE, width=0.55, edgecolor=SURFACE, linewidth=2)
for x, h, i in zip(range(3), handler, infer):
    a.text(x, h + 15, f"{h:.0f} ms", ha="center", fontsize=10, color=INK, weight="bold")
    a.text(x, h / 2, f"inference\n{i:.0f} ms", ha="center", va="center", fontsize=8, color="white")
a.set_title("Warm request time falls as memory (and CPU) rises")
a.set_ylabel("Avg handler time per request (ms)")
a.set_ylim(0, max(handler) * 1.18)
a.grid(axis="x", visible=False)

b.bar(labels, cost, color=BLUE, width=0.55, edgecolor=SURFACE, linewidth=2)
for x, c in enumerate(cost):
    b.text(x, c + 0.3, f"${c:.2f}", ha="center", fontsize=10, color=INK, weight="bold")
b.set_title("…but cost per request rises")
b.set_ylabel("Estimated cost per 1M requests (USD)")
b.set_ylim(0, max(cost) * 1.18)
b.grid(axis="x", visible=False)
fig.tight_layout(rect=(0, 0.05, 1, 1))
finish(fig, "chart_memory_sweep.png",
       "Source: 5 warm requests per setting (bus.jpg via API Gateway), Lambda pricing us-east-1 \\$0.0000166667/GB-s + \\$0.20/1M requests.")

# ---------------------------------------------------------------- 2. cold vs warm
v1, v2 = rows("coldstart_v1.csv"), rows("coldstart.csv")
cats, cold, warm = [], [], []
for tag, data in (("v1", v1), ("v2", v2)):
    for t in ("1", "2", "3"):
        c = next(r for r in data if r["trial"] == t and r["call"] == "cold")
        w = [float(r["client_s"]) for r in data if r["trial"] == t and r["call"] != "cold"]
        cats.append(f"{tag}\ntrial {t}")
        cold.append(float(c["client_s"])); warm.append(st.mean(w))

fig, ax = plt.subplots(figsize=(10, 4.2))
x = range(len(cats)); w_ = 0.36
ax.bar([i - w_ / 2 for i in x], cold, w_, color=ORANGE, edgecolor=SURFACE, linewidth=2, label="Cold start (new environment)")
ax.bar([i + w_ / 2 for i in x], warm, w_, color=BLUE, edgecolor=SURFACE, linewidth=2, label="Warm (avg of next 2 calls)")
for i, (c, w) in enumerate(zip(cold, warm)):
    ax.text(i - w_ / 2, c + 0.4, f"{c:.1f}s", ha="center", fontsize=9, color=INK, weight="bold")
    ax.text(i + w_ / 2, w + 0.4, f"{w:.2f}s", ha="center", fontsize=8, color=INK2)
ax.axhline(29, color=INK2, linewidth=1.2, linestyle=(0, (4, 3)))
ax.text(len(cats) - 0.5, 29.4, "API Gateway integration timeout (29 s)", ha="right", fontsize=8.5, color=INK2)
ax.annotate("first call after deploying\nthe new v2 image", xy=(3 - w_ / 2, cold[3]), xytext=(1.6, 22),
            fontsize=8.5, color=INK2, arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
ax.set_xticks(list(x)); ax.set_xticklabels(cats)
ax.set_ylabel("Client response time (s)")
ax.set_ylim(0, 32)
ax.set_title("Cold starts cost 7–8 s (19 s right after a deploy); warm calls take ~0.4 s")
ax.grid(axis="x", visible=False)
ax.legend(loc="upper left", bbox_to_anchor=(0.0, 0.86), frameon=False, fontsize=9)
fig.tight_layout(rect=(0, 0.05, 1, 1))
finish(fig, "chart_cold_vs_warm.png",
       "Source: perf_test.sh coldstart - each trial forces a new execution environment, 3008 MB, input/bus.jpg via API Gateway.")

# ---------------------------------------------------------------- 3. load tests
def load(name):
    return [(l.split()[0], float(l.split()[1])) for l in open(R / name) if l.strip()]

l40, l60 = load("load_40x8.txt"), load("load_60x20.txt")
fig, (a, b) = plt.subplots(1, 2, figsize=(10, 3.9), gridspec_kw={"width_ratios": [1.6, 1]})
lat = sorted(t for c, t in l40 if c == "200")
colors = [ORANGE if t > 3 else BLUE for t in lat]
a.bar(range(1, len(lat) + 1), lat, color=colors, width=0.8, edgecolor=SURFACE, linewidth=1)
a.set_title("40 requests, concurrency 8: 100% success")
a.set_xlabel("Requests, sorted by latency"); a.set_ylabel("Client latency (s)")
n_cold = sum(t > 3 for t in lat)
a.legend(handles=[Patch(color=BLUE, label=f"Warm environment ({len(lat) - n_cold})"),
                  Patch(color=ORANGE, label=f"New environment, cold start ({n_cold})")],
         loc="upper left", frameon=False, fontsize=8.5)
a.grid(axis="x", visible=False); a.set_xlim(0, len(lat) + 1)

ok = sum(c == "200" for c, _ in l60); thr = sum(c != "200" for c, _ in l60)
b.barh(["Throttled\n(HTTP 500)", "Succeeded\n(HTTP 200)"], [thr, ok], color=[CRITICAL, GOOD],
       height=0.55, edgecolor=SURFACE, linewidth=2)
for y, v in enumerate([thr, ok]):
    b.text(v + 0.8, y, f"{v} / {len(l60)}", va="center", fontsize=10, color=INK, weight="bold")
b.set_xlim(0, len(l60) * 0.75)
b.set_title("60 requests, concurrency 20")
b.set_xlabel("Requests")
b.grid(axis="y", visible=False)
fig.tight_layout(rect=(0, 0.11, 1, 1))
fig.text(0.62, 0.045, "Lambda account limit = 10 concurrent executions.\nCloudWatch: Throttles = 33, ConcurrentExecutions max = 10.",
         fontsize=8, color=INK2, ha="left", va="bottom")
finish(fig, "chart_load_tests.png",
       "Source: perf_test.sh load 40 8 and load 60 20 against /prod/detect (input/bus.jpg), 3008 MB.")

# ---------------------------------------------------------------- 4. batch dataset
bt = [r for r in rows("batch_v1.csv") if r["http"] == "200"]
bt.sort(key=lambda r: float(r["inference_ms"]))
names = [f"{r['file'].replace('.jpg', '')} ({r['objects']} obj)" for r in bt]
vals = [float(r["inference_ms"]) for r in bt]
fig, ax = plt.subplots(figsize=(8.5, 4.2))
ax.barh(names, vals, color=BLUE, height=0.6, edgecolor=SURFACE, linewidth=2)
for y, v in enumerate(vals):
    ax.text(v + 4, y, f"{v:.0f} ms", va="center", fontsize=8.5, color=INK2, zorder=5,
            bbox=dict(boxstyle="square,pad=0.15", fc=SURFACE, ec="none"))
avg = st.mean(vals)
ax.axvline(avg, color=INK2, linewidth=1, linestyle=(0, (4, 3)), zorder=1)
ax.text(avg + 3, len(vals) - 0.35, f"mean {avg:.0f} ms", fontsize=8.5, color=INK2)
ax.set_xlim(0, max(vals) * 1.18)
ax.set_xlabel("YOLOv5s inference time (ms, warm, 3008 MB)")
ax.set_title("Inference time per COCO val2017 image (10 images, all HTTP 200)")
ax.grid(axis="y", visible=False)
fig.tight_layout(rect=(0, 0.05, 1, 1))
finish(fig, "chart_batch_inference.png",
       "Source: perf_test.sh batch - 10 COCO val2017 images (Lin et al., 2014) sent through API Gateway.")

# summary numbers for the report
print("\nmemory:", [(m, round(h, 1), round(i, 1), round(c, 2)) for m, h, i, c in zip(sizes, handler, infer, cost)])
print("cold:", [round(c, 2) for c in cold], "warm:", [round(w, 3) for w in warm])
print("batch mean infer:", round(avg, 1), "range", min(vals), max(vals))
