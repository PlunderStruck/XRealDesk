"""Head predictor lab: fits candidates and scores them on the jitter the eye actually sees.

Score (what scripts/retina-sim.py showed matters): each frame is lit for a whole refresh while the
head keeps moving, so the eye receives the average error over the frame's hold; the eye integrates
~10 ms; visible jitter is what's left after removing slow drift (100 ms). Reported in glasses
pixels (rms) per calibration task, each scored on a session the candidate never saw.

Candidates:
  current      the shipped weights (argv[1]: a HeadPredictorWeights.swift)
  linear-mse   blended linear fit, error + frame-to-frame penalty (what ships)
  linear-eye   blended linear fit trained directly on eye-visible jitter (+ some plain error)
  mlp          small neural net (sklearn), plain error

    CALDIR=... python3 scripts/predictor-lab.py Sources/XRCore/HeadPredictorWeights.swift
"""
import numpy as np, os, sys, csv, glob, importlib.util

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fit", os.path.join(here, "fit-head-predictor.py"))
fit = importlib.util.module_from_spec(spec); spec.loader.exec_module(fit)
spec2 = importlib.util.spec_from_file_location("ev", os.path.join(here, "eval-head-predictor.py"))

PX_PER_DEG = 1920 / 46.0
H = 37            # ms from the pose to the middle of the frame's lit time
HOLD = 8          # ms a frame stays lit (120 Hz)
EYE = 10          # ms the eye integrates
DRIFT = 100       # ms: slower than this is lag/drift, not jitter
S = fit.S


def movavg(x, n):
    k = np.ones(n) / n
    return np.apply_along_axis(lambda c: np.convolve(c, k, "same"), 0, x)


def load(f):
    """Per-ms samples: features X, head speed, and the target = head rotation (rad, head frame)
    averaged over the hold window around H, i.e. what the frame should show."""
    X, Y = fit.D[f] if f in fit.D else fit.load(f)
    # Y has horizons 10..80 ms; build the hold-averaged target from 30/40/50 by interpolation.
    hs = np.array(fit.HS)
    ts = np.arange(H - HOLD // 2, H + HOLD // 2 + 1)
    def at(h):
        k = int(np.clip(np.searchsorted(hs, h) - 1, 0, len(hs) - 2)); a = (h - hs[k]) / (hs[k+1] - hs[k])
        return Y[hs[k]] * (1 - a) + Y[hs[k+1]] * a
    T = np.mean([at(h) for h in ts], axis=0)
    w = (X[:, 0:3]*2 + X[:, 3:6]*2 + X[:, 6:9]*4 + X[:, 9:12]*8 + X[:, 12:15]*16) / 32
    speed = np.degrees(np.linalg.norm(w, axis=1))
    return X, T, speed


def visible(err):
    """Eye-visible jitter per ms (degrees, 2D) from the per-ms prediction error (rad)."""
    e = np.degrees(err[:, :2])                    # yaw/pitch-ish components (roll barely moves the picture)
    seen = movavg(e, EYE)
    return np.linalg.norm(seen - movavg(seen, DRIFT), axis=1)


def band(x):
    s = movavg(x, EYE); return s - movavg(s, DRIFT)


def fit_linear(parts, mode, mu, alpha):
    A = np.concatenate([p[0] for p in parts]); B = np.concatenate([p[1] for p in parts])
    s = A.std(0) + 1e-12; nf = A.shape[1]
    M = (A/s).T @ (A/s); v = (A/s).T @ B
    if mode == "mse":
        dA = np.concatenate([p[0][8:] - p[0][:-8] for p in parts]); dB = np.concatenate([p[1][8:] - p[1][:-8] for p in parts])
        M += mu * (dA/s).T @ (dA/s); v += mu * (dA/s).T @ dB
    else:   # eye-visible jitter as the target, plus a little plain error to keep lag down
        bA = np.concatenate([band(p[0]) for p in parts]); bB = np.concatenate([band(p[1]) for p in parts])
        M = (1 / alpha) * M + (bA/s).T @ (bA/s); v = (1 / alpha) * v + (bA/s).T @ bB
    W = np.linalg.solve(M + fit.LAM * len(A) * np.eye(nf), v)
    return W / s[:, None]


def blended(parts, mode, mus, mum, alpha=None):
    return ("blend", fit_linear(parts, mode, mus, alpha), fit_linear(parts, mode, mum, alpha))


def predict(model, X, speed):
    if model[0] == "blend":
        _, Ws, Wm = model
        lo, hi = fit.BLEND_START, fit.BLEND_FULL
        x = np.clip((speed - lo) / (hi - lo), 0, 1); x = x*x*(3-2*x)
        return (X @ Ws) * (1 - x)[:, None] + (X @ Wm) * x[:, None]
    if model[0] == "mlp":
        _, sc, m = model; return np.radians(m.predict(sc.transform(X)))
    if model[0] == "hybrid":
        _, still, net = model
        lo, hi = float(os.environ.get("HYB_LO", fit.BLEND_START)), float(os.environ.get("HYB_HI", fit.BLEND_FULL))
        x = np.clip((speed - lo) / (hi - lo), 0, 1); x = x*x*(3-2*x)
        return predict(still, X, speed) * (1 - x)[:, None] + predict(net, X, speed) * x[:, None]
    if model[0] == "swift":
        _, still, moving, (lo, hi), hsw = model
        k = max(i for i, h in enumerate(hsw) if h <= H); a = (H - hsw[k]) / (hsw[k+1] - hsw[k])
        Ws = still[k]*(1-a) + still[k+1]*a; Wm = moving[k]*(1-a) + moving[k+1]*a
        x = np.clip((speed - lo) / (hi - lo), 0, 1); x = x*x*(3-2*x)
        return (X @ Ws) * (1 - x)[:, None] + (X @ Wm) * x[:, None]


def fit_mlp(parts):
    from sklearn.neural_network import MLPRegressor
    from sklearn.preprocessing import StandardScaler
    X = np.concatenate([p[0][::6] for p in parts]); Y = np.degrees(np.concatenate([p[1][::6] for p in parts]))
    sc = StandardScaler().fit(X)
    m = MLPRegressor(hidden_layer_sizes=(64, 64), activation="tanh", alpha=1e-3, early_stopping=True,
                     max_iter=300, random_state=0, learning_rate_init=1e-3)
    m.fit(sc.transform(X), Y)
    return ("mlp", sc, m)


def parse_swift(path):
    ev = importlib.util.module_from_spec(spec2)
    src = open(os.path.join(here, "eval-head-predictor.py")).read().split("calibs = sorted")[0]
    exec(compile(src, "eval", "exec"), ev.__dict__)
    hs, blend_, still, moving = ev.parse_swift(path)
    return ("swift", still, moving, blend_, hs)


if __name__ == "__main__":
    files = fit.files
    calibs = sorted(f for f in files if f.startswith("cal-calib"))
    data = {f: load(f) for f in files}
    current = parse_swift(sys.argv[1]) if len(sys.argv) > 1 else None
    bands = [("still <5", 0, 5), ("slow 5-20", 5, 20), ("pan 20-60", 20, 60), ("fast >60", 60, 1e9)]
    names = ["current", "linear-mse", "linear-eye", "mlp", "hybrid"]
    totals = {n: {b[0]: [] for b in bands} for n in names}
    # Sessions the shipped weights were fitted on can't be used to score them.
    seen = [x for x in os.environ.get("SEEN_BY_CURRENT", "").split(",") if x]
    for test in calibs:   # leave one calibration session out
        train = [(data[f][0], data[f][1]) for f in files if f != test for _ in range(fit.WEIGHT_CALIB if f.startswith("cal-calib") else 1)]
        models = {"current": current,
                  "linear-mse": blended(train, "mse", fit.MU_STILL, fit.MU_MOVING),
                  "linear-eye": blended(train, "eye", 0, 0, alpha=float(os.environ.get("ALPHA", "0.3"))),
                  "mlp": fit_mlp(train)}
        lm = models["linear-mse"]
        models["hybrid"] = ("hybrid", ("blend", lm[1], lm[1]), models["mlp"])   # linear still model, net when moving
        X, T, sp = data[test]
        print(f"\n### held out: {test}")
        for n in names:
            if models[n] is None: continue
            v = visible(T - predict(models[n], X, sp))
            row = f"{n:12}"
            for b, lo, hi in bands:
                m = (sp >= lo) & (sp < hi)
                if m.sum() > 300:
                    val = np.sqrt(np.mean(v[m]**2)) * PX_PER_DEG
                    if not any(x in test for x in seen): totals[n][b].append(val)
                    row += f"  {b}: {val:.2f} px"
            print(row, flush=True)
    print("\n### average over held-out sessions (eye-visible jitter, glasses px rms)")
    for n in names:
        print(f"{n:12}" + "".join(f"  {b}: {np.mean(v):.2f}" for b, v in totals[n].items() if v))
