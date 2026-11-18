#!/usr/bin/env python3
"""Offline test bench for Pulsar's kick detector (mirrors Sources/Pulsar/BeatEngine.swift).

Usage:
  .venv/bin/python harness.py SONG.(mp3|m4a|wav|aiff) [-o report.html] [--start S] [--dur S]
  .venv/bin/python harness.py --synthetic [-o report.html]

Any format that macOS `afconvert` reads is supported. Writes a self-contained HTML timeline.
"""
import argparse, html, json, os, subprocess, sys, tempfile
import numpy as np
from scipy.io import wavfile
from scipy.signal import lfilter, butter, sosfilt

TICK = 0.01  # 10 ms analysis hop, same as BeatEngine


# ---------------------------------------------------------------- audio io
def load_audio(path, start=0.0, dur=None):
    with tempfile.TemporaryDirectory() as td:
        wav = os.path.join(td, "a.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@48000", path, wav],
                       check=True, capture_output=True)
        sr, x = wavfile.read(wav)
    x = x.astype(np.float32)
    if x.ndim == 1:
        x = x[:, None]
    a = int(start * sr)
    b = len(x) if dur is None else min(len(x), a + int(dur * sr))
    return sr, x[a:b]


def synthetic(sr=48000, bpm=120, seconds=36, seed=1):
    """Kick track with three tricky sections; returns (sr, stereo, kick_times, sections)."""
    rng = np.random.default_rng(seed)
    n = int(sr * seconds)
    t = np.arange(n) / sr
    out = np.zeros(n, np.float32)
    beat = 60 / bpm
    kicks = np.arange(0.5, seconds - 0.5, beat)

    def kick(at, gain):
        m = int(0.35 * sr)
        tt = np.arange(m) / sr
        f = 50 + 90 * np.exp(-tt * 30)
        s = np.sin(2 * np.pi * np.cumsum(f) / sr) * np.exp(-tt * 9) * gain
        i = int(at * sr)
        out[i:i + m] += s[: max(0, min(m, n - i))]

    sections = [(0, 12, "Plain kick + hats"), (12, 24, "Kick over sustained 808 bass"),
                (24, 30, "Loud drop"), (30, 36, "Quiet bars after the drop")]
    for k in kicks:
        g = 1.0
        if 24 <= k < 30: g = 1.6
        if 30 <= k: g = 0.35
        kick(k, g)
    # hats on 8ths
    for h in np.arange(0.5 + beat / 2, seconds - 0.5, beat / 2):
        m = int(0.04 * sr); i = int(h * sr)
        out[i:i + m] += (rng.standard_normal(m) * np.exp(-np.arange(m) / sr * 120) * 0.08)[: max(0, min(m, n - i))]
    # sustained 808 / bassline in section 2 (long notes, 2 beats each)
    notes = [41.2, 41.2, 49.0, 36.7]
    for j, s0 in enumerate(np.arange(12, 24, 2 * beat)):
        i0, i1 = int(s0 * sr), int((s0 + 2 * beat) * sr)
        tt = np.arange(i1 - i0) / sr
        out[i0:i1] += 0.75 * np.sin(2 * np.pi * notes[j % 4] * tt) * np.minimum(1, tt * 40)
    # loud drop: add bass + pad
    seg = (t >= 24) & (t < 30)
    out[seg] += 0.5 * np.sin(2 * np.pi * 55 * t[seg]) + 0.1 * rng.standard_normal(seg.sum())
    # quiet pad throughout
    out += 0.02 * np.sin(2 * np.pi * 220 * t) * (1 + 0.5 * np.sin(2 * np.pi * 0.2 * t))
    out /= np.max(np.abs(out)) * 1.05
    st = np.stack([out, np.roll(out, 7)], 1)
    return sr, st, kicks, sections


# --------------------------------------------------------- onset detector
def onset_detector(sr, x, k=2.2, win=1.0, lo=40, hi=120):
    """Kick-band log-energy flux with adaptive median+MAD threshold. Causal, 10 ms hops."""
    mono = x.mean(1).astype(np.float64)
    sos = butter(2, [lo, hi], btype="bandpass", fs=sr, output="sos")
    kb = sosfilt(sos, mono)
    hop = int(round(TICK * sr))
    nt = len(kb) // hop
    E = (kb[: nt * hop].reshape(nt, hop) ** 2).mean(1)
    L = 10 * np.log10(E + 1e-10)
    flux = np.zeros(nt)
    for i in range(4, nt):
        flux[i] = max(0.0, L[i] - L[i - 4:i].mean())   # rise vs last 40 ms

    W = int(win / TICK)
    beats, last, interval = [], -1e9, 0.5
    thr_curve = np.zeros(nt)
    for i in range(W, nt - 1):
        hist = flux[i - W:i]
        med = np.median(hist)
        mad = np.median(np.abs(hist - med)) + 1e-6
        thr = max(med + k * 1.4826 * mad, 3.0)          # ≥3 dB rise required
        thr_curve[i] = thr
        now = (i + 1) * TICK
        refractory = max(0.2, 0.45 * interval)
        # local peak (1 hop lookahead = 10 ms latency) above threshold
        if flux[i] > thr and flux[i] >= flux[i - 1] and flux[i] >= flux[i + 1] and now - last > refractory:
            if now - last < 1.5:
                ivs = np.diff((beats + [now])[-10:])
                interval = float(np.clip(np.median(ivs), 0.3, 1.0)) if len(ivs) else interval
            last = now
            beats.append(now)
    norm = flux / (np.percentile(flux, 99.5) + 1e-9)
    return np.array(beats), np.clip(norm, 0, 1.2)


# ----------------------------------------------------------------- scoring
def score(det, truth, tol=0.06):
    if truth is None or len(truth) == 0:
        return None
    used, hits, lat = set(), 0, []
    for d in det:
        j = int(np.argmin(np.abs(truth - d)))
        if abs(truth[j] - d) <= tol and j not in used:
            used.add(j); hits += 1; lat.append(d - truth[j])
    p = hits / max(len(det), 1); r = hits / len(truth)
    return dict(hits=hits, detected=len(det), truth=len(truth), precision=p, recall=r,
                f1=2 * p * r / max(p + r, 1e-9), latency_ms=1000 * float(np.mean(lat)) if lat else None)


def per_section(det, truth, sections, tol=0.06):
    out = []
    for a, b, name in sections:
        tt = truth[(truth >= a) & (truth < b)]
        dd = det[(det >= a) & (det < b)]
        s = score(dd, tt, tol)
        out.append(dict(name=name, start=a, end=b, **s))
    return out


# ------------------------------------------------------------------ report
def report(path, title, dur, beats, flux, truth, sections, k, sweep):
    data = dict(title=title, dur=dur, beats=beats.round(3).tolist(), k=k,
                truth=None if truth is None else np.round(truth, 3).tolist(),
                sections=sections or [], flux=np.round(flux[::2], 3).tolist(), step=TICK * 2,
                score=score(beats, truth), sweep=sweep,
                sec=per_section(beats, truth, sections) if truth is not None and sections else None)
    tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "report_template.html")).read()
    open(path, "w").write(tpl.replace("__TITLE__", html.escape(title)).replace("/*__DATA__*/null", json.dumps(data)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", nargs="?")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("-o", "--out", default="report.html")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--dur", type=float, default=None)
    ap.add_argument("--k", type=float, default=2.2, help="onset threshold sensitivity (lower = more beats)")
    a = ap.parse_args()
    truth = sections = None
    if a.synthetic:
        sr, x, truth, sections = synthetic()
        title = "Synthetic test track (120 BPM)"
    elif a.audio:
        sr, x = load_audio(a.audio, a.start, a.dur)
        title = os.path.basename(a.audio)
    else:
        ap.error("give an audio file or --synthetic")
    beats, flux = onset_detector(sr, x, k=a.k)
    sweep = []
    if truth is not None:
        for kk in (1.4, 1.8, 2.2, 2.6, 3.0):
            sc = score(onset_detector(sr, x, k=kk)[0], truth)
            sweep.append(dict(k=kk, recall=sc["recall"], precision=sc["precision"], f1=sc["f1"]))
    report(a.out, title, len(x) / sr, beats, flux, truth, sections, a.k, sweep)
    print(f"{title}: {len(beats)} beats detected (k={a.k})")
    if truth is not None:
        s = score(beats, truth)
        print(f"  recall {s['recall']:.0%}  precision {s['precision']:.0%}  F1 {s['f1']:.2f}")
        for row in per_section(beats, truth, sections):
            print(f"     {row['name']:32s} {row['hits']}/{row['truth']}  extra {row['detected']-row['hits']}")
        print("  sensitivity sweep: " + "  ".join(f"k={r['k']}: F1 {r['f1']:.2f}" for r in sweep))
    print("wrote", a.out)


if __name__ == "__main__":
    main()
