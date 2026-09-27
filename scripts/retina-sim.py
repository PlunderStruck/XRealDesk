"""What reaches the eye: rebuilds, from a frame trace, where a world-fixed point lands on the retina.

Record a trace while moving your head (`post com.xrealdesk.set trace=10`), then:
    python3 scripts/retina-sim.py [~/Library/Logs/XRealDesk]

Model. The eye counter-rotates against the head to stay on the world (vestibulo-ocular reflex), so a
world-locked picture is steady on the retina exactly when each displayed frame shows the world where
the head really is while that frame is lit. Frame k is drawn for view v_k, shown from macOS's
presentedTime (plus the glasses' own delay) until the next frame replaces it, and lit the whole time.
So the retinal offset of a world point is e(t) = head(t) − v_k, sampled every 0.25 ms. The eye
integrates light over ~10 ms: what's seen is that average (its wobble after removing slow drift =
visible jitter) and its spread (smear).

Counterfactuals replay the same head motion with one cause removed each:
  ideal timing        frames shown exactly when they were aimed (no on-time/late surprises)
  flash display       each frame lit for 1 ms instead of held (no hold smear)
  perfect prediction  every frame drawn for exactly where the head is when it's shown
"""
import csv, os, sys
import numpy as np
from PIL import Image, ImageDraw

LOGS = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Library/Logs/XRealDesk")
PX_PER_DEG = 1920 / 46.0          # glasses pixels per degree (approx)
DT = 0.00025                      # simulation step (s)
EYE = 0.010                       # eye integration window (s)
GLASSES_DELAY = float(os.environ.get("GLASSES_DELAY_MS", "12")) / 1000   # inside the glasses (≈ prediction setting)
HOLD = 1 / 120

fr = list(csv.DictReader(open(os.path.join(LOGS, "frames.csv"))))
pr = list(csv.DictReader(open(os.path.join(LOGS, "presented.csv"))))
if "nowT" not in fr[0]:
    sys.exit("frames.csv has no measured-head columns: update the app, then record a new trace")
actual = {round(float(r["target"]), 4): float(r["actual"]) for r in pr if float(r["actual"]) > 0}

# Measured head (unpredicted), sampled once per frame at its sensor time.
hs = sorted({(float(r["nowT"]), float(r["nowYaw"]), float(r["nowPitch"])) for r in fr
             if r["nowT"] not in ("", "0.000000") and r["nowYaw"] != "nan"})
ht = np.array([h[0] for h in hs]); hy = np.unwrap(np.radians([h[1] for h in hs])); hp = np.array([h[2] for h in hs])
hy = np.degrees(hy)
def head(t):
    return np.interp(t, ht, hy), np.interp(t, ht, hp)

# Frames: drawn view, aimed time, actual time.
frames = []
for r in fr:
    if r["rendered"] != "1": continue
    tgt = float(r["present"]); a = actual.get(round(tgt, 4))
    if a is None: continue
    frames.append((a, tgt, float(r["viewYaw"]), float(r["viewPitch"])))
frames.sort()
fa = np.array([f[0] for f in frames]); ftg = np.array([f[1] for f in frames])
fvy = np.degrees(np.unwrap(np.radians([f[2] for f in frames]))); fvp = np.array([f[3] for f in frames])
# Align unwrapped view yaw with the head's unwrapped branch.
fvy += 360 * np.round((np.interp(fa[0], ht, hy) - fvy[0]) / 360)

t0 = max(fa[0], ht[0]) + GLASSES_DELAY + 0.05
t1 = min(fa[-1], ht[-1]) - 0.05
T = np.arange(t0, t1, DT)

def retina(show, vy, vp, lit=None):
    """Retinal offset (yaw, pitch) of a world point over T; NaN where nothing is lit."""
    start = show + GLASSES_DELAY
    k = np.searchsorted(start, T, side="right") - 1
    ok = k >= 0
    k = np.clip(k, 0, len(start) - 1)
    Hy, Hp = head(T)
    ey = np.where(ok, Hy - vy[k], np.nan); ep = np.where(ok, Hp - vp[k], np.nan)
    if lit is not None:
        dark = (T - start[k]) > lit
        ey[dark] = np.nan; ep[dark] = np.nan
    return ey, ep

def movavg(x, n):
    m = ~np.isnan(x); xs = np.where(m, x, 0)
    c = np.convolve(xs, np.ones(n), "same"); w = np.convolve(m.astype(float), np.ones(n), "same")
    return np.where(w > 0, c / np.maximum(w, 1e-9), np.nan)

n_eye = int(EYE / DT)
Hy, Hp = head(T)
speed = np.hypot(np.gradient(Hy, DT), np.gradient(Hp, DT))
speed = movavg(speed, int(0.03 / DT))

def metrics(ey, ep):
    py, pp = movavg(ey, n_eye), movavg(ep, n_eye)              # what the eye sees (10 ms)
    jy, jp = py - movavg(py, int(0.1 / DT)), pp - movavg(pp, int(0.1 / DT))   # minus slow drift/lag
    jitter = np.hypot(jy, jp)
    sy = np.sqrt(np.maximum(movavg(ey**2, n_eye) - py**2, 0)); sp = np.sqrt(np.maximum(movavg(ep**2, n_eye) - pp**2, 0))
    smear = np.hypot(sy, sp)
    return jitter, smear

bands = [("still  <5°/s", 0, 5), ("slow  5-20°/s", 5, 20), ("panning 20-60°/s", 20, 60), ("fast  >60°/s", 60, 1e9)]
cases = {
    "as shown": retina(fa, fvy, fvp),
    "ideal timing": retina(ftg, fvy, fvp),
    "flash display": retina(fa, fvy, fvp, lit=0.001),
    "perfect prediction": retina(fa, *head(fa + GLASSES_DELAY)),
    "perfect pred. + flash": retina(fa, *head(fa + GLASSES_DELAY), lit=0.001),
}
print(f"trace: {len(frames)} frames, {T[-1]-T[0]:.1f} s; glasses delay {GLASSES_DELAY*1000:.0f} ms; 1 px ≈ {1/PX_PER_DEG:.3f}°")
print("visible jitter / smear on the retina, in glasses pixels (rms):")
print(f"{'':24}" + "".join(f"{b[0]:>20}" for b in bands))
res = {}
for name, (ey, ep) in cases.items():
    jit, sm = metrics(ey, ep); res[name] = (jit, sm)
    row = f"{name:24}"
    for _, lo, hi in bands:
        m = (speed >= lo) & (speed < hi) & ~np.isnan(jit)
        row += f"{'':>4}" + (f"{np.sqrt(np.nanmean(jit[m]**2))*PX_PER_DEG:5.2f} / {np.sqrt(np.nanmean(sm[m]**2))*PX_PER_DEG:5.2f}" if m.sum() > 400 else f"{'-':>13}") + "  "
    print(row)
print("(each cell: jitter / smear. 'ideal timing' removes timing surprises, 'flash display' the hold smear,")
print(" 'perfect prediction' the prediction error; what each removes is that cause's share.)")

# Picture: 2 s of the fastest panning, a world-fixed vertical line as the retina receives it.
win = int(2.0 / DT)
score = np.convolve(np.clip(np.nan_to_num(speed), 0, 60), np.ones(win), "valid")
i0 = int(np.argmax(score)) if len(score) else 0
cols = [("as shown", cases["as shown"][0]), ("ideal timing", cases["ideal timing"][0]),
        ("perfect prediction", cases["perfect prediction"][0]), ("flash display", cases["flash display"][0])]
W, H, SPAN = 300, 800, 0.6        # px per panel, rows, ±degrees shown
img = Image.new("RGB", (W * len(cols) + 10 * (len(cols) - 1), H + 30), (12, 12, 14))
dr = ImageDraw.Draw(img)
for c, (name, ey) in enumerate(cols):
    x0 = c * (W + 10)
    seg = ey[i0:i0 + win]
    acc = np.zeros((H, W))
    rows = (np.arange(len(seg)) * H // max(len(seg), 1)).clip(0, H - 1)
    xs = ((seg + SPAN) / (2 * SPAN) * W)
    for r_, x in zip(rows, xs):
        if np.isnan(x) or x < 0 or x >= W: continue
        acc[r_, int(x)] += 1
    acc = acc / max(acc.max(), 1e-9)
    # A little horizontal spread, like the line's own width.
    acc = (acc + np.roll(acc, 1, 1) * 0.5 + np.roll(acc, -1, 1) * 0.5) / 2
    tile = (np.clip(acc * 3, 0, 1) * 255).astype(np.uint8)
    img.paste(Image.fromarray(np.stack([tile, tile, tile], -1)), (x0, 30))
    dr.line([(x0 + W // 2, 30), (x0 + W // 2, H + 30)], fill=(60, 60, 90))
    dr.text((x0 + 6, 8), name, fill=(220, 220, 230))
out = os.path.join(LOGS, "retina.png")
img.save(out)
print(f"picture: {out}  (2 s of your fastest panning, time downward; a perfectly steady screen is a straight vertical line; width ±{SPAN}°)")
