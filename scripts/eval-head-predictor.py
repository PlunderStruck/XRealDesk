"""Scores the current head predictor (argv[1]: its HeadPredictorWeights.swift) against a fresh fit
that never saw the newest calibration session, task by task on that session. Both are scored on
data neither was fitted to, so the comparison is fair. Error = prediction error, jitter = its
frame-to-frame change (what reads as shake), at the app's ~37 ms horizon."""
import numpy as np, re, sys, os, glob, csv, importlib.util

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fit", os.path.join(here, "fit-head-predictor.py"))
fit = importlib.util.module_from_spec(spec); spec.loader.exec_module(fit)
H = 37

def parse_swift(path):
    s = open(path).read()
    hs = [float(x) for x in re.search(r"horizonsMs: \[Float\] = \[([^\]]*)\]", s).group(1).split(",")]
    lo, hi = [float(x) for x in re.search(r"blendDegreesPerSecond[^=]*= \(([^)]*)\)", s).group(1).split(",")]
    def sets(name):
        body = s[s.index(f"static let {name}"):]
        body = body[:body.index("\n    ]")]
        return [np.array([[float(v) for v in m] for m in re.findall(r"SIMD3\(([^,]+), ([^,]+), ([^)]+)\)", row)])
                for row in body.split("\n")[1:] if "SIMD3" in row]
    return hs, (lo, hi), sets("weightsStill"), sets("weightsMoving")

def speed(X):
    w = (X[:, 0:3]*2 + X[:, 3:6]*2 + X[:, 6:9]*4 + X[:, 9:12]*8 + X[:, 12:15]*16) / 32
    return np.degrees(np.linalg.norm(w, axis=1))

def predict(X, model):
    hs, (lo, hi), still, moving = model
    k = max(i for i, h in enumerate(hs) if h <= H); t = (H - hs[k]) / (hs[k+1] - hs[k])
    Ws = still[k]*(1-t) + still[k+1]*t; Wm = moving[k]*(1-t) + moving[k+1]*t
    x = np.clip((speed(X) - lo) / (hi - lo), 0, 1); x = x*x*(3-2*x)
    return (X @ Ws) * (1-x)[:, None] + (X @ Wm) * x[:, None]

def score(X, Y):
    E = np.degrees(Y - X)[::8]
    return np.sqrt((np.linalg.norm(E, axis=1)**2).mean()), np.sqrt((np.linalg.norm(E[1:]-E[:-1], axis=1)**2).mean())

calibs = sorted(f for f in fit.files if f.startswith("cal-calib"))
if not calibs: sys.exit("no calibration sessions")
newest = calibs[-1]
current = parse_swift(sys.argv[1])
# Fresh fit without the newest session.
keep = [f for f in fit.files if f != newest]
fit.files = keep
fresh = (fit.HS, (fit.BLEND_START, fit.BLEND_FULL), [fit.fit(h, fit.MU_STILL) for h in fit.HS], [fit.fit(h, fit.MU_MOVING) for h in fit.HS])
X, Yall = fit.load(newest)
d = np.loadtxt(fit.S + newest, delimiter=",", skiprows=1, usecols=0)
t = d[fit.SLOW + 5: fit.SLOW + 5 + len(X)]
# Target at H ms from the loader's horizons (interpolate 30/40).
Y = Yall[30] + (Yall[40] - Yall[30]) * (H - 30) / 10
labels = [(r["label"], float(r["start_s"]), float(r["end_s"])) for r in csv.DictReader(open(fit.S + newest.replace("cal-calib", "labels-calib")))]
print(f"newest session: {newest}  (scored at {H} ms ahead)")
print(f"{'task':14} {'current err/jitter':>22} {'retrained err/jitter':>24}")
for lab, a, b in labels:
    m = (t >= a) & (t < b)
    if m.sum() < 500: continue
    c = score(predict(X[m], current), Y[m]); n = score(predict(X[m], fresh), Y[m])
    print(f"{lab:14} {c[0]:.4f}° / {c[1]:.4f}°   {n[0]:.4f}° / {n[1]:.4f}°   ({100*(n[0]/c[0]-1):+.0f}% / {100*(n[1]/c[1]-1):+.0f}%)")
